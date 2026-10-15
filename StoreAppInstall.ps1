<#
.SYNOPSIS
  Silently installs Microsoft Store apps for the current user from a GPO
  logon script, using winget. No admin rights, no Intune/MDM.

.DESCRIPTION
  Made by SkylFlow for our own apps, and works the same way for any app from
  the Microsoft Store - just add it to $Apps below:
    OneMount  - https://onemount.app  - mounts SharePoint/OneDrive libraries
                as Windows network drives.
    PostMount - https://postmount.app - IMAP/POP3/SMTP relay so mail apps,
                scanners and ERP systems can still reach Microsoft 365.

  Every logon:
    1. One `winget export` call lists which Store apps this user already has.
    2. Apps already installed are skipped - never updated (the Store updates
       them on its own).
    3. Missing apps are installed silently, checked again, and opened once.

  GPO: User Configuration -> Windows Settings -> Scripts (Logon/Logoff) ->
  Logon -> "Scripts" tab:
    Script Name:       powershell.exe
    Script Parameters: -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden
                       -File "\\<domain>\SYSVOL\<domain>\scripts\StoreAppInstall.ps1"
  User logon only - winget does not work as a computer startup/SYSTEM script.
  The logon script itself returns in about a second; the work continues in a
  hidden background process (see -Foreground).

  Log: %LOCALAPPDATA%\StoreAppInstall\install.log
#>
[CmdletBinding()]
param(
  # ==========================================================================
  # APPS TO INSTALL - one line per app.
  #   Name    - any label, used in the log and to find the app to open.
  #   StoreId - the code from the app's page URL on apps.microsoft.com
  #             (last URL segment), or the Id column of `winget search "name"`.
  #   Launch  - optional, default $true. $false = install only, don't open.
  #
  # Apps marked "exe installer" are Store listings that run the publisher's own
  # setup program; some of them ask for admin rights, which a regular user
  # can't approve (the log says so). True Store apps (msstore) installed
  # without admin rights in all our tests.
  # ==========================================================================
  [object[]]$Apps = @(
    @{ Name = 'OneMount';  StoreId = '9P68LJCNCHND' }
    @{ Name = 'PostMount'; StoreId = '9PN0511DJX9K' }
    # Tested examples:
    # @{ Name = 'Telegram Desktop'; StoreId = '9NZTWSQNTD0S' }
    # @{ Name = 'WhatsApp';         StoreId = '9NKSQGP7F2NH' }
    # @{ Name = 'ChatGPT';          StoreId = '9PLM9XGG6VKS' }
    # @{ Name = 'Pinterest';        StoreId = '9PFHDSF91B9R' }
    # @{ Name = 'Microsoft Teams';  StoreId = 'XP8BT8DW290MPQ' }   # exe installer, no admin needed
    # @{ Name = 'Zoom Workplace';   StoreId = 'XP99J3KP4XZ4VV' }   # exe installer, no admin needed
    # @{ Name = 'Adobe Acrobat';    StoreId = 'XPDP273C0XHQH2' }   # exe installer, NEEDS admin
  ),

  # Never open any app after installing it.
  [switch]$NoLaunch,
  # Run in this window instead of handing off to a hidden background process
  # (for testing by hand). Without it, the logon script starts a copy of itself
  # in the background and exits at once, so it never delays logon and isn't
  # cut off by the Group Policy script time limit (10 minutes by default).
  [switch]$Foreground,
  # Max time for one app's install. Some Store apps take several minutes on a
  # first install (WhatsApp: 5 min in testing). A download stuck as pending in
  # Microsoft Store > Library never finishes - it is cut off here and retried
  # on the next logon.
  [int]$InstallTimeoutMin = 20,
  # Max time for the whole run; apps not reached are installed on the next logon.
  [int]$MaxRunMin = 60,
  # Max wait for winget on a brand-new profile (it appears a little after the
  # first logon).
  [int]$WingetWaitMin = 3,
  # Clear the log once it grows past this size.
  [int]$LogMaxKB = 100
)

$ScriptVersion = '2026.10.14.22'

$StateDir = Join-Path $env:LOCALAPPDATA 'StoreAppInstall'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$LogPath = Join-Path $StateDir 'install.log'
if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt ($LogMaxKB * 1KB))) {
  Clear-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue
}

function Write-Raw([string]$Line) {
  try { Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8 } catch {}
}
function Write-Log([string]$Message, [string]$Level = 'INFO') {
  Write-Raw ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message)
}
$Separator = '=' * 70

# Per user, across sessions (console + RDP at once).
$Script:LockMutex = $null
function Enter-SingleInstance {
  try {
    $Script:LockMutex = New-Object System.Threading.Mutex($false, "Global\StoreAppInstall_$($env:USERDOMAIN)_$($env:USERNAME)")
    return $Script:LockMutex.WaitOne([TimeSpan]::FromSeconds(3))
  } catch [System.Threading.AbandonedMutexException] {
    return $true
  } catch {
    return $false
  }
}
function Exit-SingleInstance {
  if ($Script:LockMutex) {
    try { $Script:LockMutex.ReleaseMutex() } catch {}
    $Script:LockMutex.Dispose()
  }
}

function Find-Winget {
  $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
  if (Test-Path -LiteralPath $alias) { return $alias }
  return $null
}

# Output goes to a temp file via cmd.exe rather than a pipe, and every call has
# a hard timeout. On timeout, taskkill /T takes down winget.exe too - killing
# only cmd.exe would leave it running.
function Invoke-Winget([string]$Winget, [string]$Arguments, [int]$TimeoutSec) {
  $tempOut = [System.IO.Path]::GetTempFileName()
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/c `"`"$Winget`" $Arguments > `"$tempOut`" 2>&1`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
      try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch {}
      return [PSCustomObject]@{ TimedOut = $true; Rc = $null; Lines = @() }
    }
    $lines = @(Get-Content -LiteralPath $tempOut -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { "$_".Trim() })
    return [PSCustomObject]@{ TimedOut = $false; Rc = $proc.ExitCode; Lines = $lines }
  } finally {
    Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
  }
}

# Every Store app this user has installed, as StoreIds, in one call. Covers
# both true Store packages and Store listings with an exe installer. Ok=$false
# means "unknown" - never treat that as "nothing installed", or every app
# would get an install attempt (and winget upgrades apps it finds installed).
function Get-InstalledStoreIds([string]$Winget) {
  $exportFile = Join-Path ([System.IO.Path]::GetTempPath()) ("storeappinstall-{0}.json" -f [guid]::NewGuid())
  try {
    $r = Invoke-Winget $Winget "export -o `"$exportFile`" --source msstore --accept-source-agreements --disable-interactivity" 60
    if ($r.TimedOut -or -not (Test-Path -LiteralPath $exportFile)) {
      return [PSCustomObject]@{ Ok = $false; Ids = @() }
    }
    $json = Get-Content -LiteralPath $exportFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $ids = @($json.Sources | ForEach-Object { $_.Packages } | ForEach-Object { $_.PackageIdentifier } | Where-Object { $_ })
    return [PSCustomObject]@{ Ok = $true; Ids = $ids }
  } catch {
    return [PSCustomObject]@{ Ok = $false; Ids = @() }
  } finally {
    Remove-Item -LiteralPath $exportFile -Force -ErrorAction SilentlyContinue
  }
}

$TraditionalInstallerTypes = @('exe', 'msi', 'inno', 'nullsoft', 'wix', 'burn', 'portable', 'zip')
function Get-InstallerType([string]$Winget, [string]$StoreId) {
  $r = Invoke-Winget $Winget "show --id $StoreId --source msstore --exact --accept-source-agreements --disable-interactivity" 30
  if ($r.TimedOut) { return $null }
  $line = $r.Lines | Where-Object { $_ -match 'Installer Type:\s*(\S+)' } | Select-Object -First 1
  if ($line -and $line -match 'Installer Type:\s*(\S+)') { return $Matches[1] }
  return $null
}

# Start menu entries (AppID -> Name). AppID works with shell:AppsFolder for
# both Store and exe apps.
function Get-StartEntries {
  $map = @{}
  try { Get-StartApps | ForEach-Object { $map[$_.AppID] = $_.Name } } catch {}
  return $map
}

# Opens the Start menu entry that appeared with this install. Uninstall
# shortcuts are ignored; if several entries are left, the one matching the
# app's Name is used; if it's still ambiguous, nothing is opened.
function Start-NewApp([hashtable]$Before, [string]$AppName) {
  $after = Get-StartEntries
  $new = @($after.Keys | Where-Object { -not $Before.ContainsKey($_) -and $after[$_] -notlike 'Uninstall*' })
  if ($new.Count -gt 1) { $new = @($new | Where-Object { $after[$_] -like "*$AppName*" }) }
  if ($new.Count -ne 1) {
    Write-Log "[$AppName] Installed, but couldn't tell which Start menu entry to open - not opening it." 'WARN'
    return
  }
  try {
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($new[0])"
    Write-Log "[$AppName] Opened ($($after[$new[0]]))." 'OK'
  } catch {
    Write-Log "[$AppName] Could not open it: $($_.Exception.Message)" 'WARN'
  }
}

function Format-Rc($Rc) { if ($null -eq $Rc) { 'none' } else { '0x{0:X8}' -f $Rc } }

function Get-FailureHint($Rc, [string]$InstallerType) {
  switch ($Rc) {
    -1978335212 { return 'StoreId not found in the Microsoft Store catalog - check it. Some listings (e.g. Microsoft 365) are only a web page, not an installable package.' }
    -2147023673 { return 'Canceled - an admin (UAC) prompt was closed or declined. This app needs admin rights to install.' }
    -1978335138 { return 'Certificate pinning mismatch. Run once as admin: winget source reset --force. If that does not help, check for a TLS-inspecting proxy.' }
  }
  if ($InstallerType -in $TraditionalInstallerTypes) {
    return "This listing runs the publisher's own '$InstallerType' installer, which may need admin rights."
  }
  return 'Install failed - will retry on next logon.'
}

function Invoke-Main {
  Write-Raw $Separator
  Write-Raw ('RUN START  {0:yyyy-MM-dd HH:mm:ss}  User: {1}\{2}  Host: {3}  Script: {4}' -f (Get-Date), $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME, $ScriptVersion)
  Write-Raw $Separator
  $deadline = (Get-Date).AddMinutes($MaxRunMin)

  # @(...) everywhere: a one-item result would otherwise unwrap to a bare
  # hashtable, and .Count on a hashtable counts its keys.
  $valid = @()
  $seen = @{}
  foreach ($app in $Apps) {
    if (-not $app.Name -or "$($app.StoreId)" -notmatch '^[A-Za-z0-9]{10,16}$') {
      Write-Log "Config error: entry '$($app.Name)' / StoreId '$($app.StoreId)' is invalid - skipped." 'ERROR'
      continue
    }
    $key = "$($app.StoreId)".ToUpperInvariant()
    if ($seen.ContainsKey($key)) {
      Write-Log "Config error: StoreId '$($app.StoreId)' is listed twice ('$($seen[$key])' and '$($app.Name)') - second one skipped." 'ERROR'
      continue
    }
    $seen[$key] = $app.Name
    $valid += $app
  }
  $configErrors = $Apps.Count - $valid.Count
  $ok = 0; $failed = 0; $postponed = 0

  $winget = Find-Winget
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not $winget -and $sw.Elapsed.TotalMinutes -lt $WingetWaitMin) {
    Start-Sleep -Seconds 10
    $winget = Find-Winget
  }

  if (-not $winget) {
    Write-Log "winget not available after $WingetWaitMin min - nothing done, will retry on next logon." 'ERROR'
    $failed = $valid.Count
  } else {
    $inventory = Get-InstalledStoreIds $winget
    if (-not $inventory.Ok) {
      Write-Log 'Could not list installed Store apps (winget export failed) - nothing done, will retry on next logon.' 'ERROR'
      $failed = $valid.Count
    } else {
      $pending = @()
      foreach ($app in $valid) {
        if ($inventory.Ids -contains $app.StoreId) {
          Write-Log "[$($app.Name)] Already installed - skipping." 'OK'
          $ok++
        } else {
          $pending += $app
        }
      }

      foreach ($app in $pending) {
        $remainingSec = [int]($deadline - (Get-Date)).TotalSeconds
        if ($remainingSec -lt 60) {
          Write-Log "[$($app.Name)] Out of time for this logon - will install on the next one." 'WARN'
          $postponed++
          continue
        }
        Write-Raw "--- $($app.Name) ($($app.StoreId)) ---"
        try {
          $type = Get-InstallerType $winget $app.StoreId
          if ($type -in $TraditionalInstallerTypes) {
            Write-Log "[$($app.Name)] Installer type '$type': the publisher's own setup program, not a Store package. It may ask for admin rights." 'WARN'
          }
          $launch = ($app.Launch -ne $false) -and -not $NoLaunch
          $startBefore = if ($launch) { Get-StartEntries } else { @{} }

          $timeoutSec = [Math]::Min($InstallTimeoutMin * 60, $remainingSec - 30)
          Write-Log "[$($app.Name)] Installing (time limit $([int]($timeoutSec / 60)) min)..."
          $r = Invoke-Winget $winget "install --id $($app.StoreId) --source msstore --exact --accept-package-agreements --accept-source-agreements --disable-interactivity --silent" $timeoutSec
          if ($r.TimedOut) {
            Write-Log "[$($app.Name)] Install did not finish in $([int]($timeoutSec / 60)) min - stopped. Usually a Store download stuck as 'pending' (Microsoft Store > Library). Will retry on next logon." 'ERROR'
            $failed++
            continue
          }
          $r.Lines | Where-Object { $_ -notmatch '^[\s\-\\|/]+$|\d+\s*%|[\u2580-\u259F]|[KMG]B\s*/\s*[\d.]+\s*[KMG]B' } |
            ForEach-Object { Write-Log "  winget> $($_.Trim())" }

          $check = Get-InstalledStoreIds $winget
          $installed = if ($check.Ok) { $check.Ids -contains $app.StoreId } else { $r.Rc -eq 0 }
          if ($installed) {
            Write-Log "[$($app.Name)] Installed." 'OK'
            $ok++
            if ($launch) { Start-NewApp $startBefore $app.Name }
          } else {
            Write-Log "[$($app.Name)] Not installed (winget exit $(Format-Rc $r.Rc)). $(Get-FailureHint $r.Rc $type)" 'ERROR'
            $failed++
          }
        } catch {
          # Never let one app's unexpected error take down the whole logon script.
          Write-Log "[$($app.Name)] Unexpected error, skipped: $($_.Exception.Message)" 'ERROR'
          $failed++
        }
      }
    }
  }

  Write-Raw $Separator
  Write-Raw ('RUN END    {0:yyyy-MM-dd HH:mm:ss}  RESULT: {1} OK, {2} FAILED, {3} POSTPONED, {4} CONFIG_ERRORS' -f (Get-Date), $ok, $failed, $postponed, $configErrors)
  Write-Raw $Separator
  if ($failed -gt 0) { return 2 }
  if ($configErrors -gt 0) { return 4 }
  return 0
}

if (-not $Foreground -and -not $PSBoundParameters.ContainsKey('Apps')) {
  $argList = "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$PSCommandPath`" -Foreground"
  if ($NoLaunch) { $argList += ' -NoLaunch' }
  foreach ($p in 'InstallTimeoutMin', 'MaxRunMin', 'WingetWaitMin', 'LogMaxKB') {
    if ($PSBoundParameters.ContainsKey($p)) { $argList += " -$p $($PSBoundParameters[$p])" }
  }
  try {
    $bg = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
    Write-Log "Logon script handed off to background process (PID $($bg.Id))."
    exit 0
  } catch {
    Write-Log "Could not start background process ($($_.Exception.Message)) - running here instead." 'WARN'
  }
}

if (-not (Enter-SingleInstance)) {
  Write-Log 'Another instance is already running for this user - exiting.' 'WARN'
  exit 0
}
$exitCode = 1
try {
  $exitCode = Invoke-Main
} catch {
  Write-Log "Unexpected error: $($_.Exception.Message)" 'ERROR'
} finally {
  Exit-SingleInstance
}
exit $exitCode
