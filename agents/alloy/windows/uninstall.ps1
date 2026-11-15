# Take a Windows host off SkyEye: stop and disable the Alloy service and leave
# it a config with no pipeline. Must run elevated. Safe to run twice.
#
#   uninstall.ps1                  # keeps the Cloudflare Access secret files
#   uninstall.ps1 -RemoveSecrets   # also deletes them; only Wan can put them back
#
# Left in place: the Alloy package (remove it with winget, see the runbook), its
# data directory, the SkyEye event source, and logs already sent to central.
# The config that was live is kept beside it as config.alloy.uninstalled-<run id>.
#
# Runs under Windows PowerShell 5.1 and PowerShell 7 and never prompts. The
# outcome is in <ResultDir>\windows-agent-uninstall-<run id>.json and .log.
#
# Exit codes: 0 uninstalled or already uninstalled; 1 refused or failed.
[CmdletBinding()]
param(
    [switch]$RemoveSecrets,
    [string]$SecretsDir = '',
    [string]$ResultDir = '',
    [string]$AlloyExe = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'SkyEyeAlloy.ps1')

$dataRoot = 'C:\ProgramData\SkyEye'
if ($env:ProgramData) {
    $dataRoot = $env:ProgramData.TrimEnd('\') + '\SkyEye'
}
if (-not $SecretsDir) {
    $SecretsDir = ($dataRoot + '\secrets')
}
if (-not $ResultDir) {
    $ResultDir = ($dataRoot + '\reports')
}

$result = Invoke-SkyEyeUninstall @{
    LockFile = ($dataRoot + '\alloy-install.lock'); SecretsDir = $SecretsDir
    RemoveSecrets = [bool]$RemoveSecrets; AlloyExe = $AlloyExe
    BundleFiles = @((Join-Path $PSScriptRoot 'uninstall.ps1'), (Join-Path $PSScriptRoot 'SkyEyeAlloy.ps1'))
}

$written = $null
try {
    $written = Write-SkyEyeResultFiles -Result $result -ResultDir $ResultDir
}
catch {
    $fallback = Join-Path ([System.IO.Path]::GetTempPath()) 'SkyEye-reports'
    Write-Host ('cannot write to ' + $ResultDir + '; using ' + $fallback)
    $written = Write-SkyEyeResultFiles -Result $result -ResultDir $fallback
}
if ($written.PointerError) {
    Write-Host $written.PointerError
}
Write-Host ('status: ' + $result.status + ' (exit ' + $result.exit_code + ')')
Write-Host $result.message
Write-Host ('result: ' + $written.RunFile)
exit $result.exit_code
