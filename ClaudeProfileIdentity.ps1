<#
.SYNOPSIS
    Gives each Claude profile its own taskbar button and its own badged icon.

.DESCRIPTION
    Windows groups taskbar buttons by AppUserModelID (AUMID). Every Claude instance
    shares one, so all profiles collapse into a single button. This assigns a distinct
    AUMID per profile window and pushes a colour-badged icon onto it - the same
    mechanism Chrome uses for its profile windows.

    Per window it sets:
      System.AppUserModel.ID                      -> splits the taskbar grouping
      System.AppUserModel.RelaunchCommand         -> pinning relaunches the right profile
      System.AppUserModel.RelaunchDisplayNameResource -> pinned name, e.g. "Claude - Sukarth"
      System.AppUserModel.RelaunchIconResource    -> pinned icon
    and sends WM_SETICON so the live button shows the badge.

    Requires Windows PowerShell 5.1 (STA), which is what you already have.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\ClaudeProfileIdentity.ps1 -List
    powershell -ExecutionPolicy Bypass -File .\ClaudeProfileIdentity.ps1 -Apply
    powershell -ExecutionPolicy Bypass -File .\ClaudeProfileIdentity.ps1 -Watch
    powershell -ExecutionPolicy Bypass -File .\ClaudeProfileIdentity.ps1 -Icons
#>
[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')][switch]$Apply,
    [Parameter(ParameterSetName = 'List')][switch]$List,

    # Reapply as new windows appear. Electron creates windows after startup, and a
    # window created later comes up under the shared AUMID again.
    [Parameter(ParameterSetName = 'Watch')][switch]$Watch,
    [Parameter(ParameterSetName = 'Watch')][int]$IntervalSeconds = 3,

    # Only write the .ico files (for shortcuts) and exit.
    [Parameter(ParameterSetName = 'Icons')][switch]$Icons,

    # Point existing switcher shortcuts at the badged icons.
    [Parameter(ParameterSetName = 'Shortcuts')][switch]$UpdateShortcuts,

    [string]$ClaudePath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$script:Root     = Join-Path $env:LOCALAPPDATA 'ClaudeProfiles'
$script:IconDir  = Join-Path $script:Root '.icons'
$script:DefaultDir = Join-Path $env:APPDATA 'Claude'

# Chrome-ish profile palette. Index chosen by a stable hash of the profile name, so a
# profile keeps its colour across runs and across machines.
$script:Palette = @(
    '#1A73E8', '#D93025', '#188038', '#E37400', '#9334E6',
    '#00838F', '#C5221F', '#3949AB', '#00897B', '#F9AB00'
)

# --------------------------------------------------------------- interop --

if (-not ('ClaudeIdentity.Native' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudeIdentity
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey
    {
        public Guid fmtid;
        public uint pid;
        public PropertyKey(Guid g, uint p) { fmtid = g; pid = p; }
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore
    {
        int GetCount(out uint cProps);
        int GetAt(uint iProp, out PropertyKey pkey);
        int GetValue(ref PropertyKey key, IntPtr pv);
        int SetValue(ref PropertyKey key, IntPtr pv);
        int Commit();
    }

    [ComImport, Guid("56FDF342-FD6D-11d0-958A-006097C9A090"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ITaskbarList
    {
        int HrInit();
        int AddTab(IntPtr hwnd);
        int DeleteTab(IntPtr hwnd);
        int ActivateTab(IntPtr hwnd);
        int SetActiveAlt(IntPtr hwnd);
    }

    [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090")]
    public class TaskbarInstance { }

    public static class Native
    {
        // All four AppUserModel properties live under one format id.
        public static readonly Guid AppUserModel =
            new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        public const uint PID_ID          = 5;
        public const uint PID_RELAUNCHCMD = 2;
        public const uint PID_RELAUNCHICON = 3;
        public const uint PID_RELAUNCHNAME = 4;

        public const uint WM_SETICON = 0x0080;
        public const uint GW_OWNER   = 4;
        public const int  GWL_EXSTYLE = -20;
        public const long WS_EX_TOOLWINDOW = 0x00000080L;

        public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
        [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
        public static extern IntPtr GetWindowLongPtr64(IntPtr h, int i);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
        public static extern int GetWindowLong32(IntPtr h, int i);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int PrivateExtractIcons(string file, int index, int cx, int cy,
            IntPtr[] phicon, int[] piconid, int nIcons, int flags);

        [DllImport("shell32.dll", PreserveSig = false)]
        public static extern void SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid,
            [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

        // InitPropVariantFromString is an inline helper in propvarutil.h, not an
        // export, so the PROPVARIANT is built by hand: vt at offset 0, pointer at 8.
        const short VT_LPWSTR = 31;

        [DllImport("ole32.dll")] public static extern int PropVariantClear(IntPtr pvar);

        static long ExStyle(IntPtr h)
        {
            return IntPtr.Size == 8
                ? GetWindowLongPtr64(h, GWL_EXSTYLE).ToInt64()
                : (long)GetWindowLong32(h, GWL_EXSTYLE);
        }

        /// Top-level, visible, titled, un-owned, non-toolwindow windows for a pid.
        /// That filter is what separates a real taskbar window from Electron's
        /// many hidden helper windows.
        public static IntPtr[] WindowsForPid(uint pid)
        {
            var found = new List<IntPtr>();
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                uint wpid;
                GetWindowThreadProcessId(h, out wpid);
                if (wpid != pid) return true;
                if (!IsWindowVisible(h)) return true;
                if (GetWindow(h, GW_OWNER) != IntPtr.Zero) return true;
                if ((ExStyle(h) & WS_EX_TOOLWINDOW) != 0) return true;
                if (GetWindowTextLength(h) == 0) return true;
                found.Add(h);
                return true;
            }, IntPtr.Zero);
            return found.ToArray();
        }

        public static string TitleOf(IntPtr h)
        {
            int n = GetWindowTextLength(h);
            if (n == 0) return "";
            var sb = new StringBuilder(n + 1);
            GetWindowText(h, sb, sb.Capacity);
            return sb.ToString();
        }

        public static void SetWindowString(IntPtr hwnd, uint propId, string value)
        {
            Guid iid = typeof(IPropertyStore).GUID;
            IPropertyStore store;
            SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
            var key = new PropertyKey(AppUserModel, propId);
            IntPtr pv = Marshal.AllocCoTaskMem(32);
            for (int i = 0; i < 32; i++) Marshal.WriteByte(pv, i, 0);
            try
            {
                Marshal.WriteInt16(pv, 0, VT_LPWSTR);
                Marshal.WriteIntPtr(pv, 8, Marshal.StringToCoTaskMemUni(value));  // freed by PropVariantClear
                Marshal.ThrowExceptionForHR(store.SetValue(ref key, pv));
                Marshal.ThrowExceptionForHR(store.Commit());
            }
            finally
            {
                PropVariantClear(pv);
                Marshal.FreeCoTaskMem(pv);
                Marshal.ReleaseComObject(store);
            }
        }

        /// The AUMID is normally read when the taskbar button is created, so changing
        /// it on a live window does nothing until the button is rebuilt. Dropping and
        /// re-adding the tab forces that rebuild.
        public static void RebuildTaskbarButton(IntPtr hwnd)
        {
            var tb = (ITaskbarList)new TaskbarInstance();
            try { tb.HrInit(); tb.DeleteTab(hwnd); tb.AddTab(hwnd); }
            finally { Marshal.ReleaseComObject(tb); }
        }

        public static void ApplyIcon(IntPtr hwnd, IntPtr hIconSmall, IntPtr hIconBig)
        {
            SendMessage(hwnd, WM_SETICON, (IntPtr)0, hIconSmall);
            SendMessage(hwnd, WM_SETICON, (IntPtr)1, hIconBig);
        }

        public static IntPtr ExtractIconAt(string file, int size)
        {
            var h = new IntPtr[1];
            var ids = new int[1];
            int n = PrivateExtractIcons(file, 0, size, size, h, ids, 1, 0);
            return (n > 0) ? h[0] : IntPtr.Zero;
        }
    }
}
'@
}

# --------------------------------------------------------------- helpers --

function Resolve-ClaudeExe {
    if ($ClaudePath -and (Test-Path -LiteralPath $ClaudePath)) { return $ClaudePath }
    $settings = Join-Path $script:Root 'settings.json'
    if (Test-Path -LiteralPath $settings) {
        try {
            $saved = (Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json).ClaudePath
            if ($saved -and (Test-Path -LiteralPath $saved)) { return $saved }
        } catch { }
    }
    $base = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    if (Test-Path -LiteralPath $base) {
        $stub = Join-Path $base 'claude.exe'
        if (Test-Path -LiteralPath $stub) { return $stub }
    }
    throw 'Could not locate Claude.exe. Pass -ClaudePath.'
}

# Squirrel drops the app's icon as app.ico next to the stub; fall back to the exe.
function Resolve-IconSource {
    $base = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    $appIco = Join-Path $base 'app.ico'
    if (Test-Path -LiteralPath $appIco) { return $appIco }
    if (Test-Path -LiteralPath $base) {
        $app = Get-ChildItem -LiteralPath $base -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending | Select-Object -First 1
        if ($app) {
            $exe = Join-Path $app.FullName 'Claude.exe'
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }
    return (Resolve-ClaudeExe)
}

function Get-ProfileColor {
    param([string]$Name)
    # FNV-1a, so the colour is stable for a given name.
    # Held in uint64 throughout: a uint32 multiply silently promotes to Double in
    # PowerShell and loses precision. The mask must be 0xFFFFFFFFL, because the
    # literal 0xFFFFFFFF parses as Int32 -1.
    $h = [uint64]2166136261
    foreach ($c in $Name.ToCharArray()) {
        $h = ($h -bxor [uint64][int]$c)
        $h = (($h * [uint64]16777619) -band 0xFFFFFFFFL)
    }
    return $script:Palette[[int]([uint32]$h % [uint32]$script:Palette.Count)]
}

function Get-RunningProfiles {
    $rows = @()
    # Claude Code's CLI is also claude.exe (~\.local\bin), so match on where the
    # binary lives, not just its name.
    $installRoot = Split-Path (Resolve-ClaudeExe) -Parent
    $procs = Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.ExecutablePath -and
                            $_.ExecutablePath.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase) }
    foreach ($p in $procs) {
        $cmd = $p.CommandLine
        if (-not $cmd) { continue }
        $name = 'Default'
        $dir  = $script:DefaultDir
        if ($cmd -match '--user-data-dir="?([^"]+?)"?(\s|$)') {
            $dir = $matches[1].TrimEnd('\')
            $name = Split-Path $dir -Leaf
        }
        $wins = [ClaudeIdentity.Native]::WindowsForPid([uint32]$p.ProcessId)
        if ($wins.Count -eq 0) { continue }   # renderer/GPU child processes
        foreach ($w in $wins) {
            $rows += [pscustomobject]@{
                Profile = $name
                Pid     = $p.ProcessId
                Hwnd    = $w
                Title   = [ClaudeIdentity.Native]::TitleOf($w)
                Dir     = $dir
            }
        }
    }
    return $rows
}

function New-BadgedBitmap {
    param([string]$Profile, [int]$Size)

    $hex = Get-ProfileColor $Profile
    $col = [System.Drawing.ColorTranslator]::FromHtml($hex)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.Clear([System.Drawing.Color]::Transparent)

    # Base artwork: Claude's own icon at the closest available size.
    $src = Resolve-IconSource
    $hIcon = [ClaudeIdentity.Native]::ExtractIconAt($src, $Size)
    if ($hIcon -ne [IntPtr]::Zero) {
        $ico = [System.Drawing.Icon]::FromHandle($hIcon)
        $g.DrawImage($ico.ToBitmap(), 0, 0, $Size, $Size)
        $ico.Dispose()
        [void][ClaudeIdentity.Native]::DestroyIcon($hIcon)
    }

    # Default gets no badge, so the original profile still looks like plain Claude.
    if ($Profile -ne 'Default') {
        $d    = [int]($Size * 0.46)
        $x    = $Size - $d - [int]($Size * 0.02)
        $y    = $Size - $d - [int]($Size * 0.02)
        $ring = [Math]::Max(1, [int]($Size * 0.055))

        $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230,255,255,255))),
                       ($x - $ring), ($y - $ring), ($d + 2*$ring), ($d + 2*$ring))
        $g.FillEllipse((New-Object System.Drawing.SolidBrush($col)), $x, $y, $d, $d)

        if ($Size -ge 32) {
            $letter = $Profile.Substring(0,1).ToUpper()
            $fs = [float]($d * 0.68)
            $font = New-Object System.Drawing.Font('Segoe UI', $fs,
                        [System.Drawing.FontStyle]::Bold,
                        [System.Drawing.GraphicsUnit]::Pixel)
            $fmt = New-Object System.Drawing.StringFormat
            $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
            $rect = New-Object System.Drawing.RectangleF($x, $y, $d, $d)
            $g.DrawString($letter, $font, [System.Drawing.Brushes]::White, $rect, $fmt)
            $font.Dispose()
        }
    }

    $g.Dispose()
    return $bmp
}

# Writes a PNG-compressed .ico (Vista+). Simpler and sharper than a BMP-based one.
function Save-ProfileIco {
    param([string]$Profile, [string]$Path)

    $sizes = @(16, 32, 48, 256)
    $blobs = @()
    foreach ($s in $sizes) {
        $bmp = New-BadgedBitmap -Profile $Profile -Size $s
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $blobs += ,@{ Size = $s; Bytes = $ms.ToArray() }
        $ms.Dispose(); $bmp.Dispose()
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$blobs.Count)
        $offset = 6 + (16 * $blobs.Count)
        foreach ($b in $blobs) {
            $dim = if ($b.Size -ge 256) { 0 } else { $b.Size }   # 0 encodes 256
            $bw.Write([byte]$dim); $bw.Write([byte]$dim)
            $bw.Write([byte]0);    $bw.Write([byte]0)
            $bw.Write([uint16]1);  $bw.Write([uint16]32)
            $bw.Write([uint32]$b.Bytes.Length)
            $bw.Write([uint32]$offset)
            $offset += $b.Bytes.Length
        }
        foreach ($b in $blobs) { $bw.Write($b.Bytes) }
    } finally { $bw.Dispose(); $fs.Dispose() }
    return $Path
}

function Get-ProfileIcoPath {
    param([string]$Profile)
    $p = Join-Path $script:IconDir ("{0}.ico" -f ($Profile -replace '[^\w\-]', '_'))
    if (-not (Test-Path -LiteralPath $p)) { Save-ProfileIco -Profile $Profile -Path $p | Out-Null }
    return $p
}

# Live icon handles, kept so repeated -Apply runs do not leak GDI objects.
$script:IconCache = @{}

function Set-ProfileIdentity {
    param([string]$Profile, [IntPtr]$Hwnd, [string]$Dir)

    $aumid = "Anthropic.Claude.Profile.$($Profile -replace '[^\w\.]', '_')"
    $exe   = Resolve-ClaudeExe
    $ico   = Get-ProfileIcoPath -Profile $Profile

    $relaunch = if ($Profile -eq 'Default') {
        '"{0}"' -f $exe
    } else {
        '"{0}" --user-data-dir="{1}"' -f $exe, $Dir
    }

    [ClaudeIdentity.Native]::SetWindowString($Hwnd, [ClaudeIdentity.Native]::PID_ID, $aumid)
    [ClaudeIdentity.Native]::SetWindowString($Hwnd, [ClaudeIdentity.Native]::PID_RELAUNCHCMD, $relaunch)
    [ClaudeIdentity.Native]::SetWindowString($Hwnd, [ClaudeIdentity.Native]::PID_RELAUNCHNAME,
        $(if ($Profile -eq 'Default') { 'Claude' } else { "Claude - $Profile" }))
    [ClaudeIdentity.Native]::SetWindowString($Hwnd, [ClaudeIdentity.Native]::PID_RELAUNCHICON, "$ico,0")

    if (-not $script:IconCache.ContainsKey($Profile)) {
        $small = New-BadgedBitmap -Profile $Profile -Size 16
        $big   = New-BadgedBitmap -Profile $Profile -Size 32
        $script:IconCache[$Profile] = @{ Small = $small.GetHicon(); Big = $big.GetHicon() }
        $small.Dispose(); $big.Dispose()
    }
    $h = $script:IconCache[$Profile]
    [ClaudeIdentity.Native]::ApplyIcon($Hwnd, $h.Small, $h.Big)

    [ClaudeIdentity.Native]::RebuildTaskbarButton($Hwnd)
}

# ----------------------------------------------------------------- modes --

if ($List) {
    $rows = Get-RunningProfiles
    if (-not $rows) { Write-Host 'No Claude windows found.'; return }
    $rows | ForEach-Object {
        '{0,-14} pid {1,-8} hwnd 0x{2:X}  {3}' -f $_.Profile, $_.Pid, [int64]$_.Hwnd, $_.Title
    }
    return
}

if ($Icons) {
    $names = @('Default')
    if (Test-Path -LiteralPath $script:Root) {
        $names += Get-ChildItem -LiteralPath $script:Root -Directory |
                  Where-Object { $_.Name -notlike '.*' } |
                  Select-Object -ExpandProperty Name
    }
    foreach ($n in ($names | Select-Object -Unique)) {
        $p = Save-ProfileIco -Profile $n -Path (Join-Path $script:IconDir "$($n -replace '[^\w\-]','_').ico")
        Write-Host "  $n -> $p  ($(Get-ProfileColor $n))"
    }
    return
}

if ($UpdateShortcuts) {
    $sh = New-Object -ComObject WScript.Shell
    $targets = @(
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
    )
    $n = 0
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t)) { continue }
        foreach ($lnk in (Get-ChildItem -LiteralPath $t -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue)) {
            $s = $sh.CreateShortcut($lnk.FullName)
            if ($s.Arguments -notmatch '--user-data-dir') { continue }
            if ($s.Arguments -match '--user-data-dir="?([^"]+?)"?(\s|$)') {
                $profile = Split-Path $matches[1].TrimEnd('\') -Leaf
                $s.IconLocation = "$(Get-ProfileIcoPath -Profile $profile),0"
                $s.Save()
                Write-Host "  updated: $($lnk.Name) -> $profile"
                $n++
            }
        }
    }
    Write-Host "$n shortcut(s) updated."
    return
}

# Default action: apply to everything running right now.
$applied = @{}
function Invoke-ApplyPass {
    $rows = Get-RunningProfiles
    foreach ($r in $rows) {
        $key = '{0}:{1}' -f $r.Profile, [int64]$r.Hwnd
        if ($applied.ContainsKey($key)) { continue }
        try {
            Set-ProfileIdentity -Profile $r.Profile -Hwnd $r.Hwnd -Dir $r.Dir
            $applied[$key] = $true
            Write-Host ("  {0,-14} hwnd 0x{1:X}  {2}" -f $r.Profile, [int64]$r.Hwnd, (Get-ProfileColor $r.Profile))
        } catch {
            Write-Warning "  $($r.Profile) hwnd 0x$([int64]$r.Hwnd): $($_.Exception.Message)"
        }
    }
    return $rows.Count
}

if ($Watch) {
    Write-Host "Watching for Claude windows every $IntervalSeconds s. Ctrl+C to stop."
    while ($true) {
        Invoke-ApplyPass | Out-Null
        Start-Sleep -Seconds $IntervalSeconds
    }
}

Write-Host 'Applying profile identity:'
$count = Invoke-ApplyPass
if ($count -eq 0) { Write-Host '  no Claude windows found - launch your profiles first.' }
