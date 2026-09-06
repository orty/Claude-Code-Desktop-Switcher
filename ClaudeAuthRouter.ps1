<#
.SYNOPSIS
    Forwards claude:// login callbacks to the Claude profile that is signing in.

.DESCRIPTION
    Windows keeps one handler per user for claude:// links, so after a browser sign-in
    the callback always lands in the Default profile. ClaudeSwitcher.ps1 registers this
    script as the handler; on each callback it picks a target in this order:

      1. a profile explicitly marked as expecting a login (-Expect, or set by the
         switcher when it launches a signed-out profile)
      2. the one running profile that is currently signed out
      3. the running profile whose window was most recently in front
      4. Default, exactly as before

    Only claude://login/... links are routed. Anything else goes to Default untouched.
    Claude re-registers itself as the handler every time it starts; the switcher takes
    the slot back whenever it launches a profile.

.EXAMPLE
    .\ClaudeAuthRouter.ps1 -Status
    .\ClaudeAuthRouter.ps1 -Expect Work
#>
[CmdletBinding(DefaultParameterSetName = 'Route')]
param(
    [Parameter(ParameterSetName = 'Route')][string]$Url,
    [Parameter(ParameterSetName = 'Expect', Mandatory)][string]$Expect,
    [Parameter(ParameterSetName = 'Expect')][int]$Minutes = 15,
    [Parameter(ParameterSetName = 'Status')][switch]$Status,
    [Parameter(ParameterSetName = 'Register')][switch]$Register,
    [Parameter(ParameterSetName = 'Unregister')][switch]$Unregister
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeProfileLib.ps1')

try { Initialize-ClaudeLib } catch { Write-RouterLog "FAILED to locate Claude: $($_.Exception.Message)"; throw }

if ($Status) {
    Write-Host "Handler key:     $($script:CmdPath)"
    Write-Host "Current command: $(if (Test-Path -LiteralPath $script:CmdPath) { (Get-ItemProperty $script:CmdPath).'(default)' } else { '<none>' })"
    Write-Host "Router active:   $(if (Test-RouterActive) { 'yes' } else { 'no - Claude owns the scheme until a profile is launched' })"
    Write-Host "Backup saved:    $(Test-Path -LiteralPath $script:BackupPath)"
    Write-Host "Pending login:   $(if ($p = Get-PendingLogin) { $p } else { '<none>' })"
    Write-Host "Log:             $($script:RouterLog)"
    Write-Host ''
    Write-Host 'Running profiles:'
    foreach ($pr in (Get-ProfileList | Where-Object Pid)) {
        Write-Host ("  {0,-20} pid {1,-7} {2}" -f $pr.Label, $pr.Pid, $(if ($pr.SignedIn) { 'signed in' } elseif ($pr.SignedIn -eq $false) { 'SIGNED OUT' } else { 'unknown' }))
    }
    return
}

if ($Register)   { Set-RouterRegistration; Write-Host 'Registered as the claude:// handler.'; return }
if ($Unregister) { Write-Host (Restore-RouterRegistration); Clear-PendingLogin; return }

if ($Expect) {
    Set-PendingLogin -Name $Expect -Minutes $Minutes
    if (-not (Test-RouterActive)) { Set-RouterRegistration }
    Write-Host "Next login callback within $Minutes minutes goes to '$Expect'."
    return
}

# ----------------------------------------------------------------- routing --

if (-not $Url) { Write-RouterLog 'Invoked with no URL.'; return }

function Start-ClaudeWithUrl {
    param([string]$ProfileDir, [string]$Link)
    # If that profile is already running, Electron's single-instance lock hands the URL
    # to the existing window instead of starting a second copy.
    $args = if ($ProfileDir) { '--user-data-dir="{0}" "{1}"' -f $ProfileDir, $Link } else { '"{0}"' -f $Link }
    Start-Process -FilePath $script:ClaudeExe -ArgumentList $args -WindowStyle Normal
}

try {
    if ($Url -notmatch '^claude://login/') {
        Start-ClaudeWithUrl -Link $Url
        Write-RouterLog 'Non-login link; passed to Default.'
        return
    }

    $target = $null; $why = ''
    $running = Get-ProfileList | Where-Object { $_.Pid -and -not $_.IsDefault }

    $pending = Get-PendingLogin
    if ($pending -and $pending -ne $script:DefaultName) {
        $target = $pending; $why = 'explicitly expected'
    }
    if (-not $target) {
        $signedOut = @($running | Where-Object { $_.SignedIn -eq $false })
        if ($signedOut.Count -eq 1) { $target = $signedOut[0].Name; $why = 'only signed-out profile' }
    }
    if (-not $target -and $running) {
        $front = [ClaudeProfiles.Native]::FrontmostPid([uint32[]]@((Get-RunningProfileMap).Values))
        $hit = $running | Where-Object { $_.Pid -eq $front } | Select-Object -First 1
        if ($hit) { $target = $hit.Name; $why = 'most recently used window' }
    }

    if ($target) {
        Start-ClaudeWithUrl -ProfileDir (Get-ProfilePath -Name $target) -Link $Url
        Write-RouterLog "Login routed to '$target' ($why)."
    } else {
        Start-ClaudeWithUrl -Link $Url
        Write-RouterLog 'Login routed to Default (no other candidate).'
    }
    Clear-PendingLogin

    # Claude re-registers the scheme as it starts; take it back so the next login works too.
    Start-Sleep -Seconds 4
    try { if (-not (Test-RouterActive)) { Set-RouterRegistration } } catch { }
} catch {
    Write-RouterLog "FAILED: $($_.Exception.Message)"
    throw
}
