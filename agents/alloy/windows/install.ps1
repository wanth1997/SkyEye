# Install or update the SkyEye Alloy config on a Windows host.
#
#   install.ps1 -Product github-runner -ServerId wans-windows                 # Check: changes nothing
#   install.ps1 -Product github-runner -ServerId wans-windows -Mode Install   # elevated
#   install.ps1 -Mode Rollback                                                # elevated; back to config.alloy.previous
#   install.ps1 -Product p -ServerId s -RenderOnly out.alloy                  # write the render and stop
#
# Runs under Windows PowerShell 5.1 and PowerShell 7, unattended: it never
# prompts. An elevated window closes when the script ends, so the outcome is in
# <ResultDir>\windows-agent-install-<run id>.json and .log; read those.
#
# No parameter carries a credential, and the script never opens the Cloudflare
# Access secret files. Alloy reads them itself at run time.
#
# Exit codes: 0 done, checked or already current; 1 refused or rolled back,
# with the host as it was found; 2 usage; 3 rollback incomplete.
#
# Steps, STOP and rollback points: agents/alloy/windows/README.md.
# Procedure: runbooks/windows-host-onboarding.md.
[CmdletBinding()]
param(
    [string]$Product = '',
    [string]$ServerId = '',
    [string]$PromPushUrl = 'https://prom-push.wanbrain.com/api/v1/write',
    [string]$LokiPushUrl = 'https://loki-push.wanbrain.com/loki/api/v1/push',
    [string]$RunnerDiagDir = '',
    [string]$SecretsDir = '',
    [string]$Mode = 'Check',
    [string]$ResultDir = '',
    [string]$RenderOnly = '',
    [string]$AlloyExe = '',
    [string]$AllowUntestedAlloyVersion = ''
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

if ($RenderOnly) {
    if (-not (Test-SkyEyeSlug $Product) -or -not (Test-SkyEyeSlug $ServerId) -or
        -not (Test-SkyEyePushUrl $PromPushUrl) -or -not (Test-SkyEyePushUrl $LokiPushUrl) -or
        -not (Test-SkyEyeDirectoryPath $SecretsDir) -or
        ($RunnerDiagDir -and -not (Test-SkyEyeDirectoryPath $RunnerDiagDir))) {
        Write-Host 'install.ps1 -RenderOnly: invalid -Product, -ServerId, push URL or directory.'
        exit 2
    }
    $text = New-SkyEyeConfigText -TemplateDir $PSScriptRoot -Product $Product -ServerId $ServerId `
        -PromPushUrl $PromPushUrl -LokiPushUrl $LokiPushUrl -SecretsDir $SecretsDir -RunnerDiagDir $RunnerDiagDir
    Write-SkyEyeTextFile $RenderOnly $text
    exit 0
}

# The version list sits one level up in the repository; a flat copy of this
# directory may carry it alongside instead.
$versionsFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'alloy-versions.env'
if (-not [System.IO.File]::Exists($versionsFile)) {
    $versionsFile = Join-Path $PSScriptRoot 'alloy-versions.env'
}

$bundle = @(
    (Join-Path $PSScriptRoot 'install.ps1'),
    (Join-Path $PSScriptRoot 'uninstall.ps1'),
    (Join-Path $PSScriptRoot 'SkyEyeAlloy.ps1'),
    (Join-Path $PSScriptRoot 'config.alloy.tmpl'),
    (Join-Path $PSScriptRoot 'config-runner-diag.alloy.tmpl'),
    $versionsFile
)

$result = $null
if (-not [System.IO.File]::Exists($versionsFile)) {
    $result = New-SkyEyeResult -Kind 'install' -Mode $Mode
    $result.status = 'usage_error'
    $result.stop_point = 'bundle'
    $result.exit_code = 2
    $result.message = 'alloy-versions.env is missing. Copy the whole agents/alloy directory.'
}
else {
    $result = Invoke-SkyEyeInstall @{
        Mode = $Mode; Product = $Product; ServerId = $ServerId
        PromPushUrl = $PromPushUrl; LokiPushUrl = $LokiPushUrl
        SecretsDir = $SecretsDir; RunnerDiagDir = $RunnerDiagDir
        TemplateDir = $PSScriptRoot; VersionsFile = $versionsFile
        WorkDir = ($dataRoot + '\work'); LockFile = ($dataRoot + '\alloy-install.lock')
        BundleFiles = $bundle; AlloyExe = $AlloyExe; AllowUntestedAlloyVersion = $AllowUntestedAlloyVersion
    }
}

$written = $null
try {
    $written = Write-SkyEyeResultFiles -Result $result -ResultDir $ResultDir
}
catch {
    # A reports directory this user cannot write to must not hide the outcome.
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
