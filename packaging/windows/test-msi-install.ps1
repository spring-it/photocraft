<#
.SYNOPSIS
  Install the real MSI silently, verify the installed app, launch it, then uninstall it.
.DESCRIPTION
  Runs on a clean GitHub-hosted Windows runner. It does not modify default file associations
  and refuses to run if a PhotoCraft installation is already present for this account.
#>
param(
  [Parameter(Mandatory = $true)] [string] $MsiPath,
  [Parameter(Mandatory = $true)] [ValidateSet('x64', 'x86')] [string] $Arch
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Msi = (Resolve-Path -LiteralPath $MsiPath).Path
$LogRoot = Join-Path $env:RUNNER_TEMP "photocraft-msi-install-$Arch"
[void](New-Item -ItemType Directory -Force -Path $LogRoot)
$InstallLog = Join-Path $LogRoot 'install.log'
$UninstallLog = Join-Path $LogRoot 'uninstall.log'
$ExpectedInstallDir = Join-Path $env:LOCALAPPDATA 'Programs\ArtCraft\PhotoCraft'
$Shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\PhotoCraft.lnk'
$AppRegistry = 'Software\PhotoCraft'
$AppPathsRegistry = 'Software\Microsoft\Windows\CurrentVersion\App Paths\photocraft.exe'
$FriendlyNameRegistry = 'Software\Classes\Applications\photocraft.exe'

function Get-UserRegistryValue([string] $SubKey, [string] $ValueName) {
  foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $view)
    try {
      $key = $base.OpenSubKey($SubKey, $false)
      if ($null -ne $key) {
        try {
          $value = $key.GetValue($ValueName, $null)
          if ($null -ne $value) { return [string]$value }
        } finally {
          $key.Dispose()
        }
      }
    } finally {
      $base.Dispose()
    }
  }
  return $null
}

function Get-MachineRegistryValue([string] $SubKey, [string] $ValueName) {
  foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
    try {
      $key = $base.OpenSubKey($SubKey, $false)
      if ($null -ne $key) {
        try {
          $value = $key.GetValue($ValueName, $null)
          if ($null -ne $value) { return [string]$value }
        } finally {
          $key.Dispose()
        }
      }
    } finally {
      $base.Dispose()
    }
  }
  return $null
}

function Invoke-Msi([ValidateSet('i', 'x')] [string] $Operation, [string] $Log) {
  $arguments = '/' + $Operation + ' "' + $Msi + '" /qn /norestart /L*v "' + $Log + '"'
  $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $arguments -Wait -PassThru
  if ($process.ExitCode -notin @(0, 3010)) {
    throw "msiexec /$Operation failed with exit code $($process.ExitCode); see $Log"
  }
  Write-Host "msiexec /$Operation completed with exit code $($process.ExitCode)"
}

function Get-PeMachine([string] $Path) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 256) { throw "Invalid PE file: $Path" }
  $pe = [BitConverter]::ToInt32($bytes, 0x3C)
  if ($pe -lt 0 -or $pe + 6 -gt $bytes.Length) { throw "Invalid PE header: $Path" }
  return [BitConverter]::ToUInt16($bytes, $pe + 4)
}

$ExpectedMachine = if ($Arch -eq 'x64') { 0x8664 } else { 0x014c }
$ExistingInstall = Get-UserRegistryValue $AppRegistry 'InstallDir'
$ExistingMachineInstall = Get-MachineRegistryValue $AppRegistry 'InstallDir'
if ($ExistingInstall -or $ExistingMachineInstall -or (Test-Path -LiteralPath (Join-Path $ExpectedInstallDir 'photocraft.exe'))) {
  throw 'A pre-existing PhotoCraft installation would invalidate this clean-runner test.'
}

$InstallSucceeded = $false
$AppProcess = $null
try {
  Invoke-Msi 'i' $InstallLog
  $InstallSucceeded = $true

  $InstalledDir = Get-UserRegistryValue $AppRegistry 'InstallDir'
  if (-not $InstalledDir) { throw 'The per-user PhotoCraft InstallDir registry value was not created.' }
  $ActualPath = [System.IO.Path]::GetFullPath($InstalledDir).TrimEnd('\')
  $ExpectedPath = [System.IO.Path]::GetFullPath($ExpectedInstallDir).TrimEnd('\')
  if ($ActualPath -ine $ExpectedPath) {
    throw "Unexpected per-user install path '$ActualPath'; expected '$ExpectedPath'."
  }

  $AppExe = Join-Path $InstalledDir 'photocraft.exe'
  $CliExe = Join-Path $InstalledDir 'photocraft-cli.exe'
  foreach ($file in @($AppExe, $CliExe, (Join-Path $InstalledDir 'NOTICE'), (Join-Path $InstalledDir 'ATTRIBUTION.md'))) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
      throw "Installed payload is missing: $file"
    }
  }
  foreach ($file in @($AppExe, $CliExe)) {
    $machine = Get-PeMachine $file
    if ($machine -ne $ExpectedMachine) {
      throw "Installed binary '$file' has PE machine 0x$('{0:X4}' -f $machine), expected 0x$('{0:X4}' -f $ExpectedMachine)."
    }
  }

  if (-not (Test-Path -LiteralPath $Shortcut -PathType Leaf)) {
    throw "Start Menu shortcut is missing: $Shortcut"
  }
  $FriendlyName = Get-UserRegistryValue $FriendlyNameRegistry 'FriendlyAppName'
  if ($FriendlyName -ne 'PhotoCraft') {
    throw "Windows Open with label must be 'PhotoCraft', got '$FriendlyName'."
  }
  $AppPath = Get-UserRegistryValue $AppPathsRegistry ''
  if ($AppPath -ine $AppExe) {
    throw "Windows App Paths registration '$AppPath' does not point to '$AppExe'."
  }

  $CliOutput = & $CliExe --version 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Installed photocraft-cli --version failed ($LASTEXITCODE): $($CliOutput -join ' ')"
  }
  Write-Host "Installed CLI: $($CliOutput -join ' ')"

  # Exercise the installed GUI binary with the software-rendering recovery path. The process must
  # survive its initial GPU/window setup; stop it afterward so the MSI can uninstall cleanly.
  $AppProcess = Start-Process -FilePath $AppExe -ArgumentList '--safe-gpu' -PassThru
  if ($AppProcess.WaitForExit(15000)) {
    throw "PhotoCraft exited during its startup smoke test (exit code $($AppProcess.ExitCode))."
  }
  Write-Host 'PASS PhotoCraft GUI stayed alive through the 15-second safe-GPU startup smoke test.'
} finally {
  if ($null -ne $AppProcess) {
    try {
      $AppProcess.Refresh()
      if (-not $AppProcess.HasExited) {
        Stop-Process -Id $AppProcess.Id -Force -ErrorAction SilentlyContinue
        [void]$AppProcess.WaitForExit(10000)
      }
    } catch {
      Write-Warning "Could not stop the PhotoCraft startup-test process cleanly: $_"
    }
  }
  if ($InstallSucceeded -or (Get-UserRegistryValue $AppRegistry 'InstallDir')) {
    Invoke-Msi 'x' $UninstallLog
  }
}

if (Test-Path -LiteralPath (Join-Path $ExpectedInstallDir 'photocraft.exe')) {
  throw 'Silent uninstall left photocraft.exe behind.'
}
if (Test-Path -LiteralPath $Shortcut) {
  throw 'Silent uninstall left the Start Menu shortcut behind.'
}
if (Get-UserRegistryValue $AppRegistry 'InstallDir') {
  throw 'Silent uninstall left the PhotoCraft InstallDir registration behind.'
}
if (Get-UserRegistryValue $FriendlyNameRegistry 'FriendlyAppName') {
  throw 'Silent uninstall left the Windows Open with registration behind.'
}
if (Get-UserRegistryValue $AppPathsRegistry '') {
  throw 'Silent uninstall left the Windows App Paths registration behind.'
}
Write-Output "PASS $Arch real MSI silent install, payload/registry checks, GUI startup and silent uninstall."
