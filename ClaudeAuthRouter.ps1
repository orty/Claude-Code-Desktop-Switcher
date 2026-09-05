<#
.SYNOPSIS
    Routes claude:// deep links to the correct Claude desktop profile.

.DESCRIPTION
    The claude:// scheme has one handler registration per user, so every OAuth
    callback lands in the Default profile no matter which instance started the
    sign-in. This script registers itself as that handler, then forwards the URL
    to whichever profile is currently expecting a login.

    Designed to sit next to ClaudeSwitcher.ps1 and share its profile layout
    (%LOCALAPPDATA%\ClaudeProfiles).

    Run -Status first. If your Claude install registers the scheme somewhere this
    script cannot override, -Status will show you that before you change anything.

.EXAMPLE
    .\ClaudeAuthRouter.ps1 -Status
    .\ClaudeAuthRouter.ps1 -Register
    .\ClaudeAuthRouter.ps1 -Expect Work     # then sign in
    .\ClaudeAuthRouter.ps1 -Unregister
#>
[CmdletBinding(DefaultParameterSetName = 'Route')]
param(
    # Populated by Windows when a claude:// link is opened.
    [Parameter(ParameterSetName = 'Route')][string]$Url,

    # Mark a profile as awaiting a sign-in callback.
    [Parameter(ParameterSetName = 'Expect', Mandatory)][string]$Expect,

    # Minutes before the marker expires, so a stale one cannot hijack a later link.
    [Parameter(ParameterSetName = 'Expect')][int]$Minutes = 15,

    # Keep re-asserting the registration until the callback arrives. Claude reclaims
    # the scheme every time it launches, so without this the ordering has to be exact.
    [Parameter(ParameterSetName = 'Expect')][switch]$Hold,

    [Parameter(ParameterSetName = 'Status')][switch]$Status,
    [Parameter(ParameterSetName = 'Register')][switch]$Register,
    [Parameter(ParameterSetName = 'Unregister')][switch]$Unregister,

    # Override if your build uses a different scheme than claude://.
    [string]$Scheme = 'claude',

    [string]$ClaudePath
)

$ErrorActionPreference = 'Stop'

$script:Root       = Join-Path $env:LOCALAPPDATA 'ClaudeProfiles'
$script:Marker     = Join-Path $script:Root 'pending-auth.json'
$script:Backup     = Join-Path $script:Root 'protocol-backup.json'
$script:Log        = Join-Path $script:Root 'auth-router.log'
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:KeyPath    = "HKCU:\Software\Classes\$Scheme"
$script:CmdPath    = "$($script:KeyPath)\shell\open\command"
$script:ChoicePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell\Associations\UrlAssociations\$Scheme\UserChoice"

function Write-Log {
    param([string]$Message)
    # Runs headless from a protocol activation, so there is nowhere else to report.
    try {
        New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
        Add-Content -LiteralPath $script:Log -Value ("[{0}] {1}" -f (Get-Date -Format 's'), $Message)
    } catch { }
}

function Resolve-ClaudeExe {
    if ($ClaudePath -and (Test-Path -LiteralPath $ClaudePath)) { return $ClaudePath }

    # Reuse the switcher's remembered path if it has one.
    $settings = Join-Path $script:Root 'settings.json'
    if (Test-Path -LiteralPath $settings) {
        try {
            $saved = (Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json).ClaudePath
            if ($saved -and (Test-Path -LiteralPath $saved)) { return $saved }
        } catch { }
    }

    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg -and $pkg.InstallLocation) {
        $exe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
        $found = Get-ChildItem -LiteralPath $pkg.InstallLocation -Filter 'Claude.exe' -Recurse -ErrorAction SilentlyContinue |
                 Select-Object -First 1 -ExpandProperty FullName
        if ($found) { return $found }
    }

    foreach ($dir in @(
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude'),
        (Join-Path $env:ProgramFiles 'Claude'))) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $exe = Get-ChildItem -LiteralPath $dir -Filter 'Claude.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        if ($exe) { return $exe }
    }

    throw 'Could not locate Claude.exe. Pass -ClaudePath once.'
}

function Get-PendingProfile {
    if (-not (Test-Path -LiteralPath $script:Marker)) { return $null }
    try {
        $m = Get-Content -LiteralPath $script:Marker -Raw | ConvertFrom-Json
        if ([datetime]$m.Expires -lt (Get-Date)) {
            Write-Log "Marker for '$($m.Profile)' expired; falling back to Default."
            return $null
        }
        return $m.Profile
    } catch { return $null }
}

function Clear-Pending {
    Remove-Item -LiteralPath $script:Marker -Force -ErrorAction SilentlyContinue
}

function Test-RouterActive {
    if (-not (Test-Path -LiteralPath $script:CmdPath)) { return $false }
    $cmd = (Get-ItemProperty $script:CmdPath).'(default)'
    return ($cmd -like '*ClaudeAuthRouter*')
}

function Set-RouterRegistration {
    if (-not $script:ScriptPath) { throw 'Run this from a saved .ps1 file, not pasted into a console.' }

    # Keep whatever was there so -Unregister can put it back. Never overwrite an
    # existing backup: the installer build re-registers itself on launch, so a
    # second call would otherwise save our own command as the "original".
    if ((Test-Path -LiteralPath $script:CmdPath) -and -not (Test-Path -LiteralPath $script:Backup)) {
        $existing = (Get-ItemProperty $script:CmdPath).'(default)'
        if ($existing -and $existing -notlike '*ClaudeAuthRouter*') {
            New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
            @{ Command = $existing } | ConvertTo-Json |
                Set-Content -LiteralPath $script:Backup -Encoding UTF8
        }
    }

    New-Item -Path $script:CmdPath -Force | Out-Null
    Set-ItemProperty -Path $script:KeyPath -Name '(default)'    -Value "URL:$Scheme"
    Set-ItemProperty -Path $script:KeyPath -Name 'URL Protocol' -Value ''

    $ps  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $cmd = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Url "%1"' -f $ps, $script:ScriptPath
    Set-ItemProperty -Path $script:CmdPath -Name '(default)' -Value $cmd
}

# ------------------------------------------------------------------ modes --

if ($Status) {
    Write-Host "Scheme:            $Scheme"
    Write-Host "Handler key:       $($script:CmdPath)"
    if (Test-Path -LiteralPath $script:CmdPath) {
        Write-Host "Current command:   $((Get-ItemProperty $script:CmdPath).'(default)')"
    } else {
        Write-Host "Current command:   <not set in HKCU>"
        Write-Host "                   The scheme may be registered by the MSIX package instead."
    }
    if (Test-Path -LiteralPath $script:ChoicePath) {
        Write-Host "UserChoice ProgId: $((Get-ItemProperty $script:ChoicePath).ProgId)"
        Write-Host "                   A UserChoice entry overrides the key above. If registering"
        Write-Host "                   has no effect, this is why."
    } else {
        Write-Host "UserChoice:        none (good - the handler key will be used)"
    }
    Write-Host "Router active:     $(if (Test-RouterActive) { 'yes' } else { 'NO - Claude owns the scheme' })"
    Write-Host "Claude.exe:        $(try { Resolve-ClaudeExe } catch { $_.Exception.Message })"
    $p = Get-PendingProfile
    Write-Host "Pending profile:   $(if ($p) { $p } else { '<none>' })"
    Write-Host "Router log:        $($script:Log)"
    return
}

if ($Register) {
    Set-RouterRegistration
    if (Test-Path -LiteralPath $script:Backup) {
        Write-Host "Original handler backed up to $($script:Backup)"
    }
    Write-Host "Registered. Now run:  .\ClaudeAuthRouter.ps1 -Expect <ProfileName>"
    Write-Host "then start the sign-in from that profile's window."
    return
}

if ($Unregister) {
    if (Test-Path -LiteralPath $script:Backup) {
        $saved = (Get-Content -LiteralPath $script:Backup -Raw | ConvertFrom-Json).Command
        New-Item -Path $script:CmdPath -Force | Out-Null
        Set-ItemProperty -Path $script:CmdPath -Name '(default)' -Value $saved
        Remove-Item -LiteralPath $script:Backup -Force
        Write-Host 'Restored the original handler.'
    } else {
        Remove-Item -LiteralPath $script:KeyPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed the HKCU handler key. Windows falls back to the package registration."
    }
    Clear-Pending
    return
}

if ($Expect) {
    # Claude re-registers the scheme when it starts, quietly replacing us. Re-assert
    # here so the marker is never set against a handler that no longer points at us.
    if (-not (Test-RouterActive)) {
        Set-RouterRegistration
        Write-Host 'Handler had been overwritten by Claude; re-registered.'
    }
    New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
    @{ Profile = $Expect; Expires = (Get-Date).AddMinutes($Minutes).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $script:Marker -Encoding UTF8
    Write-Host "Next claude:// callback within $Minutes minutes goes to '$Expect'."

    if ($Hold) {
        Write-Host 'Holding the registration. Launch Claude and sign in now; Ctrl+C to stop.'
        while ($true) {
            if (-not (Get-PendingProfile)) {
                Write-Host 'Marker cleared - callback routed, or it expired. Done.'
                break
            }
            if (-not (Test-RouterActive)) {
                Set-RouterRegistration
                Write-Host ("[{0}] Claude reclaimed the scheme; re-registered." -f (Get-Date -Format 'HH:mm:ss'))
            }
            Start-Sleep -Seconds 2
        }
    }
    return
}

# ----------------------------------------------------------------- routing --

if (-not $Url) { Write-Log 'Invoked with no URL; nothing to do.'; return }

try {
    $exe     = Resolve-ClaudeExe
    $profile = Get-PendingProfile

    # Only sign-in callbacks are routed by the marker. Any other claude:// link
    # (opening a chat, etc.) keeps its original behaviour and goes to Default.
    $isLogin = $Url -match '^claude://login/'

    if ($isLogin -and $profile -and $profile -ne 'Default') {
        $dir = Join-Path $script:Root $profile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # An instance already on this user-data-dir holds the single-instance lock,
        # so Electron forwards these arguments to the running window instead.
        $argline = '--user-data-dir="{0}" "{1}"' -f $dir, $Url
        Start-Process -FilePath $exe -ArgumentList $argline -WindowStyle Normal
        Write-Log "Routed to profile '$profile'."
        Clear-Pending
    } else {
        # No marker: behave exactly as before and let Default have it.
        Start-Process -FilePath $exe -ArgumentList ('"{0}"' -f $Url) -WindowStyle Normal
        Write-Log $(if ($isLogin) { 'Routed to Default (no pending profile).' } else { 'Non-login link; routed to Default.' })
    }
} catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    throw
}
