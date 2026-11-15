# Logic tests for agents/alloy/windows, run by tests/windows/test-windows-installer.sh
# with pwsh on macOS. The functions that touch a Windows machine are replaced by
# fakes, so every STOP and rollback path of the installer runs here against a
# throwaway directory. Nothing in this file is a real credential.
param(
    [Parameter(Mandatory = $true)][string]$AgentDir,
    [Parameter(Mandatory = $true)][string]$WorkDir
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Checks = 0
$script:Failures = 0

function Assert-True {
    param([bool]$Condition, [string]$What)
    $script:Checks = $script:Checks + 1
    if (-not $Condition) {
        $script:Failures = $script:Failures + 1
        Write-Host ('FAIL: ' + $What)
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$What)
    Assert-True ($Actual -ceq $Expected) ($What + ' (got "' + $Actual + '", want "' + $Expected + '")')
}

# ============================================================ static checks

$scripts = @('install.ps1', 'uninstall.ps1', 'SkyEyeAlloy.ps1')
$allParameters = New-Object System.Collections.ArrayList
foreach ($name in $scripts) {
    $path = Join-Path $AgentDir $name
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-True (@($errors).Count -eq 0) ($name + ' parses without errors: ' + (@($errors | ForEach-Object { $_.Message }) -join '; '))

    # Syntax Windows PowerShell 5.1 does not have. PowerShell 7 parses it, so a
    # slip would first show on the host.
    $modern = @($ast.FindAll({
                param($node)
                $type = $node.GetType().Name
                if ($type -eq 'TernaryExpressionAst' -or $type -eq 'PipelineChainAst') {
                    return $true
                }
                if ($node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                    [string]$node.Operator -match 'QuestionQuestion') {
                    return $true
                }
                if ($node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    [string]$node.Operator -match 'QuestionQuestion') {
                    return $true
                }
                if ($node -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    $node.PSObject.Properties['NullConditional'] -and $node.NullConditional) {
                    return $true
                }
                return $false
            }, $true))
    Assert-True ($modern.Count -eq 0) ($name + ' uses no PowerShell 7 only syntax: ' + (@($modern | ForEach-Object { $_.Extent.Text }) -join '; '))

    # Commands that prompt, that read or write text in the session's default
    # encoding, or that behave differently between 5.1 and 7.
    $denied = @('Get-Content', 'Set-Content', 'Add-Content', 'Out-File', 'Tee-Object', 'Export-Csv',
        'Read-Host', 'Get-Credential', 'Pause', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Invoke-Expression',
        'ConvertFrom-Json', 'Start-Transcript', 'Get-WmiObject', 'cat', 'type', 'curl', 'wget', 'iex', 'gc', 'sc')
    $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    $used = @($commands | Where-Object { $denied -contains $_ } | Sort-Object -Unique)
    Assert-True ($used.Count -eq 0) ($name + ' calls no denied command: ' + ($used -join ', '))

    $redirections = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FileRedirectionAst] }, $true))
    Assert-True ($redirections.Count -eq 0) ($name + ' writes no file through a redirection')

    $automatic = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                @('IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR') -contains $node.VariablePath.UserPath
            }, $true))
    Assert-True ($automatic.Count -eq 0) ($name + ' reads no variable that only PowerShell 7 defines')

    if ($ast.ParamBlock) {
        foreach ($parameter in $ast.ParamBlock.Parameters) {
            [void]$allParameters.Add($parameter.Name.VariablePath.UserPath)
        }
    }
}

# A credential on a command line ends up in process listings, transcripts and
# the UAC prompt. SecretsDir is a directory path and the one allowed name.
$secretLike = @($allParameters | Where-Object {
        $_ -ne 'SecretsDir' -and $_ -ne 'RemoveSecrets' -and
        $_ -match '(?i)secret|token|password|passphrase|credential|apikey|clientid|key$'
    })
Assert-True ($secretLike.Count -eq 0) ('no script parameter takes a credential: ' + ($secretLike -join ', '))
Assert-True ($allParameters -contains 'Product' -and $allParameters -contains 'ServerId') 'install.ps1 takes -Product and -ServerId'

# ============================================================ load and fake the host

. (Join-Path $AgentDir 'SkyEyeAlloy.ps1')
$script:SkyEyeQuiet = $true

$FakeId = 'FAKEID00000000000000000000000000.access'
$FakeSecret = 'FAKE-CF-SECRET-VALUE-THAT-MUST-NEVER-APPEAR-0001'
$script:Fake = $null
$script:Case = 0

$InterimConfig = @'
prometheus.exporter.windows "default" {
  enabled_collectors = ["cpu", "logical_disk", "memory", "net", "os", "system", "time"]
}
prometheus.remote_write "central" {
  endpoint {
    url = "https://prom-push.wanbrain.com/api/v1/write"
  }
  external_labels = {
    product   = "github-runner",
    server_id = "wans-windows",
  }
}
'@

function New-FakeHost {
    $script:Case = $script:Case + 1
    $root = Join-Path $WorkDir ('case-' + $script:Case)
    $program = Join-Path $root 'Alloy'
    $secrets = Join-Path $root 'secrets'
    foreach ($dir in @($program, $secrets, (Join-Path $root 'reports'))) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    $config = Join-Path $program 'config.alloy'
    Write-SkyEyeTextFile $config $InterimConfig
    $exe = Join-Path $program 'alloy-windows-amd64.exe'
    Write-SkyEyeTextFile $exe 'not a real binary'
    Write-SkyEyeTextFile (Join-Path $secrets 'cf-access-client-id') $FakeId
    Write-SkyEyeTextFile (Join-Path $secrets 'cf-access-client-secret') $FakeSecret
    $good = @{ Owner = 'S-1-5-32-544'; Rules = @(@{ Sid = 'S-1-5-18'; Type = 'Allow' }, @{ Sid = 'S-1-5-32-544'; Type = 'Allow' }) }
    $script:Fake = @{
        Root = $root; Config = $config; Exe = $exe; Secrets = $secrets
        Now = [int64]1794700000; Elevated = $true
        ServiceExists = $true; State = 'Running'; StartMode = 'Auto'; Account = 'LocalSystem'; ProcessId = 100
        Arguments = @('run', $config, ('--storage.path=' + (Join-Path $root 'data')))
        Version = '1.18.1'; ValidateRc = 0; ValidateCalls = 0
        SmokeStarts = 0; SmokeArguments = @(); SmokeReady = $true; SmokeExited = $false; SmokeOutput = 'level=info msg="now listening"'
        Acl = @{}; DefaultAcl = $good
        Restarts = 0; Starts = 0; Stops = 0; StartedAt = [int64]0
        RestartFailsOnce = $false; RestartThrowsAfter = 99
        NewConfigCrashLoops = $false; NewConfigNeverReady = $false
        PromDelivers = $true; PromFailed = 0; PromRetriedGrows = $false
        LokiDelivers = $true; LokiDropped = 0; Canaries = 0; CanaryThrows = $false
        StartupType = ''
    }
    return $script:Fake
}

function New-Options {
    param([string]$Mode = 'Install')
    return @{
        Mode = $Mode; Product = 'github-runner'; ServerId = 'wans-windows'
        PromPushUrl = 'https://prom-push.wanbrain.com/api/v1/write'
        LokiPushUrl = 'https://loki-push.wanbrain.com/loki/api/v1/push'
        SecretsDir = $script:Fake.Secrets; RunnerDiagDir = ''
        TemplateDir = $AgentDir; VersionsFile = (Join-Path (Split-Path -Parent $AgentDir) 'alloy-versions.env')
        WorkDir = (Join-Path $script:Fake.Root 'work'); LockFile = (Join-Path $script:Fake.Root 'alloy-install.lock')
        BundleFiles = @((Join-Path $AgentDir 'install.ps1'))
        PollMilliseconds = 5000; HealthTimeoutSeconds = 120
    }
}

function Test-NewConfigLive {
    return ((Read-SkyEyeTextFile $script:Fake.Config) -cne $InterimConfig)
}
function Get-SkyEyeHostNow { return $script:Fake.Now }
function Invoke-SkyEyeHostSleep {
    param([int]$Milliseconds)
    $script:Fake.Now = $script:Fake.Now + [int64][Math]::Ceiling($Milliseconds / 1000.0)
}
function Test-SkyEyeHostElevated { return $script:Fake.Elevated }
function Test-SkyEyeHostPortFree { param([int]$Port) return $true }
function Get-SkyEyeHostAlloy {
    $f = $script:Fake
    $processId = $f.ProcessId
    if ($f.NewConfigCrashLoops -and (Test-NewConfigLive)) {
        $processId = $f.ProcessId + [int]($f.Now - $f.StartedAt)
    }
    return @{
        ServiceExists = $f.ServiceExists; State = $f.State; StartMode = $f.StartMode; Account = $f.Account
        ProcessId = $(if ($f.State -eq 'Running') { $processId } else { 0 })
        WrapperPath = 'wrapper'; ExePath = $f.Exe; Arguments = $f.Arguments
    }
}
function Restart-SkyEyeHostService {
    $f = $script:Fake
    $f.Restarts = $f.Restarts + 1
    if (($f.RestartFailsOnce -and $f.Restarts -eq 1) -or $f.Restarts -gt $f.RestartThrowsAfter) {
        throw 'the service did not restart'
    }
    $f.State = 'Running'
    $f.ProcessId = $f.ProcessId + 1
    $f.StartedAt = $f.Now
    $f.Canaries = 0
}
function Start-SkyEyeHostService {
    $f = $script:Fake
    $f.Starts = $f.Starts + 1
    $f.State = 'Running'
    $f.ProcessId = $f.ProcessId + 1
    $f.StartedAt = $f.Now
}
function Stop-SkyEyeHostService {
    $script:Fake.Stops = $script:Fake.Stops + 1
    $script:Fake.State = 'Stopped'
}
function Set-SkyEyeHostServiceStartup {
    param([string]$StartupType)
    $script:Fake.StartupType = $StartupType
    $script:Fake.StartMode = $StartupType
}
function Invoke-SkyEyeHostProcess {
    param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds = 60)
    if ($ArgumentList[0] -eq '--version') {
        return @{ ExitCode = 0; TimedOut = $false; Output = ('alloy, version v' + $script:Fake.Version + ' (branch: HEAD, revision: fake)') }
    }
    if ($ArgumentList[0] -eq 'validate') {
        $script:Fake.ValidateCalls = $script:Fake.ValidateCalls + 1
        return @{ ExitCode = $script:Fake.ValidateRc; TimedOut = $false; Output = 'Error: validation failed' }
    }
    throw ('unexpected process: ' + ($ArgumentList -join ' '))
}
function Start-SkyEyeHostBackgroundProcess {
    param([string]$FilePath, [string[]]$ArgumentList)
    $script:Fake.SmokeStarts = $script:Fake.SmokeStarts + 1
    $script:Fake.SmokeArguments = $ArgumentList
    # What a real run would create, to prove the installer removes it.
    $storage = ($ArgumentList | Where-Object { $_ -like '--storage.path=*' }) -replace '^--storage\.path=', ''
    [void][System.IO.Directory]::CreateDirectory($storage)
    Write-SkyEyeTextFile (Join-Path $storage 'bookmark.xml') '<BookmarkList/>'
    return @{ Fake = $true }
}
function Test-SkyEyeHostBackgroundExited { param($Handle) return $script:Fake.SmokeExited }
function Stop-SkyEyeHostBackgroundProcess {
    param($Handle)
    return @{ ExitCode = $(if ($script:Fake.SmokeExited) { 1 } else { -1 }); Killed = (-not $script:Fake.SmokeExited); Output = $script:Fake.SmokeOutput }
}
function Get-SkyEyeHostHttp {
    param([string]$Url, [int]$TimeoutSeconds = 5)
    $f = $script:Fake
    if ($Url -notlike 'http://127.0.0.1:12345/*') {
        # The smoke run's own port.
        return @{ Status = $(if ($f.SmokeReady) { 200 } else { 0 }); Body = '' }
    }
    if ($f.State -ne 'Running' -or ($f.NewConfigNeverReady -and (Test-NewConfigLive))) {
        return @{ Status = 0; Body = '' }
    }
    if ($Url -like '*/-/ready') {
        return @{ Status = 200; Body = 'Alloy is ready.' }
    }
    $up = $f.Now - $f.StartedAt
    $highest = 0
    if ($f.PromDelivers -and $up -ge 5) {
        $highest = $f.Now - 2
    }
    $retried = 0
    if ($f.PromRetriedGrows) {
        $retried = $up * 10
    }
    $sent = 0
    if ($f.LokiDelivers) {
        $sent = $f.Canaries
    }
    $lines = @(
        '# TYPE prometheus_remote_storage_samples_total counter',
        ('prometheus_remote_storage_samples_total{component_id="prometheus.remote_write.central",url="x"} ' + ($up * 50)),
        ('prometheus_remote_storage_samples_failed_total{component_id="prometheus.remote_write.central",url="x"} ' + $f.PromFailed),
        ('prometheus_remote_storage_samples_retried_total{component_id="prometheus.remote_write.central",url="x"} ' + $retried),
        ('prometheus_remote_storage_queue_highest_sent_timestamp_seconds{component_id="prometheus.remote_write.central",url="x"} ' + $highest),
        ('loki_write_sent_entries_total{component_id="loki.write.central",host="x"} ' + $sent),
        ('loki_write_dropped_entries_total{component_id="loki.write.central",host="x",reason="ingester_error"} ' + $f.LokiDropped),
        'loki_write_dropped_entries_total{component_id="loki.write.central",host="x",reason="rate_limited"} 0',
        ('loki_write_request_duration_seconds_count{component_id="loki.write.central",host="x",status_code="204"} ' + $sent)
    )
    return @{ Status = 200; Body = ($lines -join "`n") }
}
function Get-SkyEyeHostAclReport {
    param([string]$Path)
    $leaf = [System.IO.Path]::GetFileName($Path)
    if ($script:Fake.Acl.ContainsKey($leaf)) {
        return $script:Fake.Acl[$leaf]
    }
    return $script:Fake.DefaultAcl
}
function Write-SkyEyeHostCanaryEvent {
    if ($script:Fake.CanaryThrows) {
        throw 'cannot register the event source'
    }
    $script:Fake.Canaries = $script:Fake.Canaries + 1
}

function Get-Outcome {
    param($Result, [string]$Name)
    $check = @($Result.checks | Where-Object { $_.name -eq $Name })
    if ($check.Count -eq 0) {
        return ''
    }
    return $check[-1].outcome
}

function Get-Render {
    param([hashtable]$Options)
    return New-SkyEyeConfigText -TemplateDir $Options.TemplateDir -Product $Options.Product -ServerId $Options.ServerId `
        -PromPushUrl $Options.PromPushUrl -LokiPushUrl $Options.LokiPushUrl -SecretsDir $Options.SecretsDir `
        -RunnerDiagDir $Options.RunnerDiagDir
}

# The host is as it was found: same config, no restart, no leftovers.
function Assert-Untouched {
    param([string]$What)
    $f = $script:Fake
    Assert-Equal (Read-SkyEyeTextFile $f.Config) $InterimConfig ($What + ': live config unchanged')
    Assert-True ($f.Restarts -eq 0 -and $f.Starts -eq 0 -and $f.Stops -eq 0) ($What + ': service not restarted, started or stopped')
    $extra = @([System.IO.Directory]::GetFiles([System.IO.Path]::GetDirectoryName($f.Config)) |
            ForEach-Object { [System.IO.Path]::GetFileName($_) } |
            Where-Object { $_ -ne 'config.alloy' -and $_ -ne 'alloy-windows-amd64.exe' })
    Assert-True ($extra.Count -eq 0) ($What + ': no file left beside the config: ' + ($extra -join ', '))
    Assert-True ($f.Canaries -eq 0) ($What + ': no canary event written')
    $work = Join-Path $f.Root 'work'
    $left = @()
    if ([System.IO.Directory]::Exists($work)) {
        $left = @([System.IO.Directory]::GetFileSystemEntries($work))
    }
    Assert-True ($left.Count -eq 0) ($What + ': work directory cleaned')
}

# ============================================================ pure functions

Assert-True (Test-SkyEyeSlug 'github-runner') 'slug accepts kebab-case'
Assert-True (-not (Test-SkyEyeSlug 'GitHub')) 'slug rejects upper case'
Assert-True (-not (Test-SkyEyeSlug 'a"b')) 'slug rejects a quote'
Assert-True (-not (Test-SkyEyeSlug '')) 'slug rejects empty'
Assert-True (Test-SkyEyePushUrl 'https://prom-push.wanbrain.com/api/v1/write') 'https URL accepted'
Assert-True (-not (Test-SkyEyePushUrl 'http://prom-push.wanbrain.com/api/v1/write')) 'plain http refused'
Assert-True (Test-SkyEyePushUrl 'http://127.0.0.1:9/api/v1/write') 'loopback http accepted'
Assert-True (-not (Test-SkyEyePushUrl 'https://x/"}')) 'URL with a quote refused'
Assert-True (Test-SkyEyeDirectoryPath 'C:\actions-runner\_diag') 'Windows directory accepted'
Assert-True (-not (Test-SkyEyeDirectoryPath 'C:\runner\*')) 'wildcard directory refused'
Assert-True (-not (Test-SkyEyeDirectoryPath 'relative\dir')) 'relative directory refused'
Assert-Equal (ConvertTo-SkyEyeAlloyPath 'C:\ProgramData\SkyEye\secrets\') 'C:/ProgramData/SkyEye/secrets' 'path uses forward slashes'

Assert-Equal (Get-SkyEyeAlloyVersionFromBanner 'alloy, version v1.18.1 (branch: HEAD, revision: 6012ec4)') '1.18.1' 'version from banner'
Assert-Equal (Get-SkyEyeAlloyVersionFromBanner "otelcol, version v1.18.1") '' 'another program is not Alloy'
Assert-Equal (Get-SkyEyeAlloyVersionFromBanner 'alloy, version v1.18 (x)') '' 'partial version refused'

$run = Get-SkyEyeAlloyRunSettings -Arguments @('run', 'C:\Program Files\GrafanaLabs\Alloy\config.alloy', '--storage.path=C:\ProgramData\GrafanaLabs\Alloy\data') -DefaultConfigPath 'x'
Assert-Equal $run.ConfigPath 'C:\Program Files\GrafanaLabs\Alloy\config.alloy' 'config path from the registry arguments'
Assert-Equal $run.StoragePath 'C:\ProgramData\GrafanaLabs\Alloy\data' 'storage path from the registry arguments'
Assert-Equal $run.ListenAddress '127.0.0.1:12345' 'default listen address'
$run = Get-SkyEyeAlloyRunSettings -Arguments @('run', 'c.alloy', '--server.http.listen-addr', '0.0.0.0:9999') -DefaultConfigPath 'x'
Assert-Equal $run.ListenAddress '127.0.0.1:9999' 'listen address given as two arguments, reached over loopback'
$run = Get-SkyEyeAlloyRunSettings -Arguments @() -DefaultConfigPath 'default.alloy'
Assert-Equal $run.ConfigPath 'default.alloy' 'default config path without arguments'

$snapshot = Get-SkyEyeDeliverySnapshot @"
# HELP x y
prometheus_remote_storage_samples_total{url="a"} 3474
prometheus_remote_storage_samples_failed_total{url="a"} 2
prometheus_remote_storage_queue_highest_sent_timestamp_seconds{url="a"} 1.794747718e+09
loki_write_sent_entries_total{host="a"} 7
loki_write_dropped_entries_total{reason="a"} 1
loki_write_dropped_entries_total{reason="b"} 2
loki_write_request_duration_seconds_count{status_code="204"} 5
loki_write_request_duration_seconds_count{status_code="403"} 3
loki_write_request_duration_seconds_count{status_code="-1"} 4
"@
Assert-True ($snapshot.PromAttempted -eq 3474 -and $snapshot.PromFailed -eq 2) 'remote_write counters parsed'
Assert-True ($snapshot.PromHighestSent -eq 1794747718) 'exponent notation parsed'
Assert-True ($snapshot.LokiSent -eq 7 -and $snapshot.LokiDropped -eq 3) 'loki counters summed over labels'
Assert-True ($snapshot.LokiNot2xx -eq 7) 'loki requests that were not 2xx'

$bad = Get-SkyEyeAclProblems @{ Owner = 'S-1-5-21-1-2-3-1001'; Rules = @(@{ Sid = 'S-1-5-32-545'; Type = 'Allow' }, @{ Sid = 'S-1-1-0'; Type = 'Deny' }) } 'secrets'
Assert-True (@($bad).Count -eq 2) 'ACL: a foreign owner and a Users grant are two problems; a Deny is none'

New-FakeHost | Out-Null
$options = New-Options
$first = Get-Render $options
Assert-Equal (Get-Render $options) $first 'two renders are byte-identical'
Assert-True (-not $first.Contains('@@')) 'render has no placeholder left'
Assert-True (-not $first.Contains("`r")) 'render has LF line endings'
Assert-True (-not $first.Contains('runner_diag')) 'no runner fragment without -RunnerDiagDir'
Assert-True (-not $first.Contains($FakeSecret) -and -not $first.Contains($FakeId)) 'render holds no secret value'
$options.RunnerDiagDir = 'C:\actions-runner\_diag'
Assert-True ((Get-Render $options).Contains('"C:/actions-runner/_diag/Runner_*.log"')) 'runner fragment with a forward-slash glob'
Assert-Equal (Get-SkyEyeLabelConflict $InterimConfig 'github-runner' 'wans-windows') '' 'interim labels match'
Assert-True ((Get-SkyEyeLabelConflict $InterimConfig 'github-runner' 'other-host') -ne '') 'a different server_id is a conflict'
Assert-Equal (Get-SkyEyeLabelConflict 'logging { }' 'a' 'b') '' 'a config without external labels has no conflict'

# ============================================================ Check mode

New-FakeHost | Out-Null
$script:Fake.Elevated = $false
$r = Invoke-SkyEyeInstall (New-Options 'Check')
Assert-True ($r -is [System.Collections.IDictionary]) 'the engine returns one result object'
Assert-Equal $r.status 'checked' 'non-admin Check: status'
Assert-Equal $r.exit_code 0 'non-admin Check: exit code'
foreach ($name in @('secret_files', 'secret_acl', 'smoke_run')) {
    Assert-Equal (Get-Outcome $r $name) 'skipped' ('non-admin Check: ' + $name + ' is skipped, not passed')
}
Assert-Equal (Get-Outcome $r 'alloy_validate') 'passed' 'non-admin Check: validate still runs'
Assert-True ($r.message -match 'skipped') 'non-admin Check: the message says checks were skipped'
Assert-True ($script:Fake.SmokeStarts -eq 0) 'non-admin Check: no smoke run'
Assert-Untouched 'non-admin Check'

New-FakeHost | Out-Null
$script:Fake.Elevated = $false
# The live config on WANS-WINDOWS cannot be read without administrator rights.
# A file that is not there fails the same way: the read throws.
[System.IO.File]::Delete($script:Fake.Config)
$r = Invoke-SkyEyeInstall (New-Options 'Check')
Assert-Equal (Get-Outcome $r 'live_config') 'skipped' 'non-admin Check: an unreadable live config is skipped'
Assert-Equal (Get-Outcome $r 'label_takeover') 'skipped' 'non-admin Check: the takeover guard is skipped with it'
Assert-Equal $r.status 'checked' 'non-admin Check with an unreadable config still finishes'

New-FakeHost | Out-Null
$r = Invoke-SkyEyeInstall (New-Options 'Check')
Assert-Equal $r.status 'checked' 'elevated Check: status'
Assert-Equal (Get-Outcome $r 'smoke_run') 'passed' 'elevated Check: smoke run passes'
Assert-True (@($r.checks | Where-Object { $_.outcome -eq 'skipped' }).Count -eq 0) 'elevated Check: nothing skipped'
Assert-Untouched 'elevated Check'

# The smoke run must not share anything with the live service.
$smokeArguments = $script:Fake.SmokeArguments
$smokeListen = ($smokeArguments | Where-Object { $_ -like '--server.http.listen-addr=*' })
$smokeStorage = ($smokeArguments | Where-Object { $_ -like '--storage.path=*' }) -replace '^--storage\.path=', ''
Assert-True ($smokeListen -and $smokeListen -notlike '*:12345') 'smoke run: not the live listen port'
Assert-True ($smokeStorage -and $smokeStorage -ne (Join-Path $script:Fake.Root 'data') -and
    -not $smokeStorage.StartsWith((Join-Path $script:Fake.Root 'data'))) 'smoke run: not the live storage path'
Assert-True (-not [System.IO.Directory]::Exists($smokeStorage)) 'smoke run: its storage directory is deleted'
Assert-True ($smokeArguments -contains '--disable-reporting') 'smoke run: reporting disabled'

# ============================================================ Install

New-FakeHost | Out-Null
$options = New-Options
$expected = Get-Render $options
$r = Invoke-SkyEyeInstall $options
Assert-Equal $r.status 'installed' 'install: status'
Assert-Equal $r.exit_code 0 'install: exit code'
Assert-Equal (Read-SkyEyeTextFile $script:Fake.Config) $expected 'install: live config is the render'
Assert-Equal (Read-SkyEyeTextFile ($script:Fake.Config + '.previous')) $InterimConfig 'install: the interim config is kept as .previous'
Assert-True (-not [System.IO.File]::Exists($script:Fake.Config + '.rollback')) 'install: no .rollback left'
Assert-True ($script:Fake.Restarts -eq 1) 'install: one restart'
Assert-True ($script:Fake.Canaries -ge 1) 'install: canary event written'
Assert-True ($r.delivery.loki_entries_sent -ge 1 -and $r.delivery.prom_samples_failed -eq 0) 'install: delivery recorded'
$installedFake = $script:Fake
$installedOptions = $options

$written = Write-SkyEyeResultFiles -Result $r -ResultDir (Join-Path $script:Fake.Root 'reports')
$resultText = (Read-SkyEyeTextFile $written.RunFile) + (Read-SkyEyeTextFile $written.LogFile)
Assert-True (-not $resultText.Contains($FakeSecret) -and -not $resultText.Contains($FakeId)) 'install: result and log hold no secret value'
Assert-True ($resultText -notmatch 'convert\.nonsensitive') 'install: result holds no config body'
Assert-True ($written.PointerFile -like '*-latest-admin.json') 'install: elevated pointer'
Assert-True (@($r.bundle).Count -eq 1 -and $r.bundle[0].sha256.Length -eq 64) 'install: bundle hashes recorded'

# Run again: nothing to do.
$r = Invoke-SkyEyeInstall $installedOptions
Assert-Equal $r.status 'already_current' 're-run: status'
Assert-True ($script:Fake.Restarts -eq 1) 're-run: no second restart'
Assert-Equal (Read-SkyEyeTextFile ($script:Fake.Config + '.previous')) $InterimConfig 're-run: .previous still the interim config'

# Rollback mode goes back to the interim config, and again forward.
$r = Invoke-SkyEyeInstall (New-Options 'Rollback')
Assert-Equal $r.status 'restored_previous' 'Rollback mode: status'
Assert-Equal (Read-SkyEyeTextFile $script:Fake.Config) $InterimConfig 'Rollback mode: the interim config is live'
Assert-Equal (Read-SkyEyeTextFile ($script:Fake.Config + '.previous')) $expected 'Rollback mode: the replaced config is now .previous'
Assert-True ($script:Fake.Canaries -eq 0) 'Rollback mode: no canary for a config without the Event Log'

New-FakeHost | Out-Null
$script:Fake.Elevated = $false
$r = Invoke-SkyEyeInstall (New-Options 'Rollback')
Assert-Equal $r.stop_point 'elevation' 'Rollback mode needs elevation'
New-FakeHost | Out-Null
$r = Invoke-SkyEyeInstall (New-Options 'Rollback')
Assert-Equal $r.stop_point 'rollback_source' 'Rollback mode without .previous refuses'
Assert-Untouched 'Rollback without .previous'

# ============================================================ every STOP leaves the host untouched

function Test-Stop {
    param([string]$What, [scriptblock]$Arrange, [string]$Status, [string]$StopPoint, [int]$ExitCode)
    New-FakeHost | Out-Null
    $options = New-Options
    & $Arrange $script:Fake $options
    $r = Invoke-SkyEyeInstall $options
    Assert-Equal $r.status $Status ($What + ': status')
    Assert-Equal $r.stop_point $StopPoint ($What + ': stop point')
    Assert-Equal $r.exit_code $ExitCode ($What + ': exit code')
    Assert-Untouched $What
}

Test-Stop 'bad mode' { param($f, $o) $o.Mode = 'Go' } 'usage_error' 'parameters' 2
Test-Stop 'bad product' { param($f, $o) $o.Product = 'Git Hub' } 'usage_error' 'parameters' 2
Test-Stop 'bad server id' { param($f, $o) $o.ServerId = 'a"b' } 'usage_error' 'parameters' 2
Test-Stop 'http push URL' { param($f, $o) $o.LokiPushUrl = 'http://example.com/x' } 'usage_error' 'parameters' 2
Test-Stop 'runner dir with a wildcard' { param($f, $o) $o.RunnerDiagDir = 'C:\r\*' } 'usage_error' 'parameters' 2
Test-Stop 'not elevated' { param($f, $o) $f.Elevated = $false } 'refused' 'elevation' 1
Test-Stop 'no Alloy service' { param($f, $o) $f.ServiceExists = $false } 'refused' 'alloy' 1
Test-Stop 'Alloy binary missing' { param($f, $o) [System.IO.File]::Delete($f.Exe); $f.Exe = $f.Exe + '.gone' } 'refused' 'alloy' 1
Test-Stop 'service account' { param($f, $o) $f.Account = '.\wan' } 'refused' 'alloy' 1
Test-Stop 'untested version' { param($f, $o) $f.Version = '1.17.0' } 'refused' 'alloy' 1
Test-Stop 'override naming another version' { param($f, $o) $f.Version = '1.17.0'; $o.AllowUntestedAlloyVersion = '1.17.1' } 'refused' 'alloy' 1
Test-Stop 'secret file missing' { param($f, $o) [System.IO.File]::Delete((Join-Path $f.Secrets 'cf-access-client-secret')) } 'refused' 'secrets' 1
Test-Stop 'client id with a newline' { param($f, $o) Write-SkyEyeTextFile (Join-Path $f.Secrets 'cf-access-client-id') ($FakeId + "`n") } 'refused' 'secrets' 1
Test-Stop 'empty secret' { param($f, $o) Write-SkyEyeTextFile (Join-Path $f.Secrets 'cf-access-client-secret') '' } 'refused' 'secrets' 1
Test-Stop 'secret readable by Users' {
    param($f, $o)
    $f.Acl['cf-access-client-secret'] = @{ Owner = 'S-1-5-18'; Rules = @(@{ Sid = 'S-1-5-18'; Type = 'Allow' }, @{ Sid = 'S-1-5-32-545'; Type = 'Allow' }) }
} 'refused' 'secrets' 1
Test-Stop 'secrets directory owned by a user' {
    param($f, $o)
    $f.Acl['secrets'] = @{ Owner = 'S-1-5-21-1-2-3-1001'; Rules = @(@{ Sid = 'S-1-5-18'; Type = 'Allow' }) }
} 'refused' 'secrets' 1
Test-Stop 'label change on takeover' { param($f, $o) $o.ServerId = 'other-host' } 'refused' 'label_takeover' 1
Test-Stop 'alloy validate fails' { param($f, $o) $f.ValidateRc = 1 } 'failed_validate' 'validate' 1
Test-Stop 'smoke run exits' { param($f, $o) $f.SmokeExited = $true; $f.SmokeReady = $false; $f.SmokeOutput = 'level=error msg="failed to evaluate config" err="secrets may not be converted into strings"' } 'failed_smoke' 'smoke' 1
Test-Stop 'smoke run never ready' { param($f, $o) $f.SmokeReady = $false } 'failed_smoke' 'smoke' 1
Test-Stop 'smoke run logs a load error' { param($f, $o) $f.SmokeOutput = 'level=error msg="failed to evaluate config" node=x' } 'failed_smoke' 'smoke' 1

New-FakeHost | Out-Null
$options = New-Options
$held = Enter-SkyEyeHostLock $options.LockFile
$r = Invoke-SkyEyeInstall $options
Exit-SkyEyeHostLock $held
Assert-Equal $r.stop_point 'lock' 'a held lock refuses the run'
[System.IO.File]::Delete($options.LockFile)
Assert-Untouched 'held lock'

New-FakeHost | Out-Null
Write-SkyEyeTextFile ($script:Fake.Config + '.rollback') 'left by a killed run'
$r = Invoke-SkyEyeInstall (New-Options)
Assert-Equal $r.stop_point 'unfinished_run' 'a leftover .rollback refuses the run'
Assert-Equal (Read-SkyEyeTextFile $script:Fake.Config) $InterimConfig 'leftover .rollback: live config unchanged'
Assert-True ($script:Fake.Restarts -eq 0) 'leftover .rollback: no restart'

New-FakeHost | Out-Null
$script:Fake.Version = '1.17.0'
$options = New-Options
$options.AllowUntestedAlloyVersion = '1.17.0'
$r = Invoke-SkyEyeInstall $options
Assert-Equal $r.status 'installed' 'an exact version override is accepted'

# ============================================================ failures after the swap roll back

function Test-Rollback {
    param([string]$What, [scriptblock]$Arrange, [string]$Reason)
    New-FakeHost | Out-Null
    $options = New-Options
    & $Arrange $script:Fake $options
    $r = Invoke-SkyEyeInstall $options
    $f = $script:Fake
    Assert-Equal $r.status 'rolled_back' ($What + ': status')
    Assert-Equal $r.exit_code 1 ($What + ': exit code')
    Assert-True ($r.rollback.attempted -and $r.rollback.ok) ($What + ': rollback recorded as done')
    Assert-Equal (Read-SkyEyeTextFile $f.Config) $InterimConfig ($What + ': the interim config is live again')
    Assert-True (-not [System.IO.File]::Exists($f.Config + '.rollback')) ($What + ': no .rollback left')
    Assert-True (-not [System.IO.File]::Exists($f.Config + '.previous')) ($What + ': no .previous created')
    Assert-True ([System.IO.File]::Exists([string]$r.config.failed_config_kept_at)) ($What + ': the rejected config is kept for diagnosis')
    Assert-True ($f.State -eq 'Running') ($What + ': the service runs again')
    Assert-True ($r.message -match $Reason) ($What + ': the reason is reported (' + $r.message + ')')
}

Test-Rollback 'restart fails' { param($f, $o) $f.RestartFailsOnce = $true } 'activation failed'
Test-Rollback 'nothing reaches Prometheus' { param($f, $o) $f.PromDelivers = $false } 'central Prometheus'
Test-Rollback 'Prometheus rejects samples' { param($f, $o) $f.PromFailed = 40 } 'rejected samples'
Test-Rollback 'remote_write keeps retrying' { param($f, $o) $f.PromRetriedGrows = $true } 'central Prometheus'
Test-Rollback 'nothing reaches Loki' { param($f, $o) $f.LokiDelivers = $false } 'central Loki'
Test-Rollback 'Loki drops entries' { param($f, $o) $f.LokiDropped = 3 } 'dropped log entries'
Test-Rollback 'canary event cannot be written' { param($f, $o) $f.CanaryThrows = $true } 'central Loki'
Test-Rollback 'Alloy never becomes ready' { param($f, $o) $f.NewConfigNeverReady = $true } 'timed out'
Test-Rollback 'Alloy restarts in a loop' { param($f, $o) $f.NewConfigCrashLoops = $true } 'restarting'

# The rollback itself fails: exit 3 and a clear record.
New-FakeHost | Out-Null
$script:Fake.PromDelivers = $false
$script:Fake.RestartThrowsAfter = 1
$r = Invoke-SkyEyeInstall (New-Options)
Assert-Equal $r.status 'rollback_incomplete' 'failed rollback: status'
Assert-Equal $r.exit_code 3 'failed rollback: exit code'
Assert-True ($r.rollback.attempted -and -not $r.rollback.ok) 'failed rollback: recorded'
Assert-True ($r.message -match 'CRITICAL') 'failed rollback: marked CRITICAL'

# A stopped service is started for the check and stopped again on rollback.
New-FakeHost | Out-Null
$script:Fake.State = 'Stopped'
$script:Fake.PromDelivers = $false
$r = Invoke-SkyEyeInstall (New-Options)
Assert-Equal $r.status 'rolled_back' 'stopped service: rolled back'
Assert-Equal $script:Fake.State 'Stopped' 'stopped service: stopped again after the rollback'
Assert-Equal (Read-SkyEyeTextFile $script:Fake.Config) $InterimConfig 'stopped service: interim config restored'

# ============================================================ result files and ownership

New-FakeHost | Out-Null
$reports = Join-Path $script:Fake.Root 'reports'
$adminPointer = Join-Path $reports 'windows-agent-install-latest-admin.json'
Write-SkyEyeTextFile $adminPointer 'written by an elevated run'
$script:Fake.Elevated = $false
$r = Invoke-SkyEyeInstall (New-Options 'Check')
$written = Write-SkyEyeResultFiles -Result $r -ResultDir $reports
Assert-Equal (Read-SkyEyeTextFile $adminPointer) 'written by an elevated run' 'a non-admin Check leaves the elevated pointer alone'
Assert-True ($written.PointerFile -like '*-latest-user.json' -and [System.IO.File]::Exists($written.PointerFile)) 'a non-admin Check writes its own pointer'
Assert-True ([System.IO.File]::Exists($written.RunFile) -and [System.IO.File]::Exists($written.LogFile)) 'per-run result and log exist'
Assert-True ((Read-SkyEyeTextFile $written.RunFile) -match '"schema":\s*"skyeye\.windows-agent\.v1"') 'result is JSON with the schema name'

# A pointer this run cannot replace (here: a directory in its place) is
# reported and the per-run file is still written.
New-FakeHost | Out-Null
$reports = Join-Path $script:Fake.Root 'reports'
[void][System.IO.Directory]::CreateDirectory((Join-Path $reports 'windows-agent-install-latest-user.json'))
$script:Fake.Elevated = $false
$r = Invoke-SkyEyeInstall (New-Options 'Check')
$written = Write-SkyEyeResultFiles -Result $r -ResultDir $reports
Assert-True ($written.PointerError -ne '' -and $written.PointerFile -eq '') 'a pointer that cannot be replaced is reported'
Assert-True ([System.IO.File]::Exists($written.RunFile)) 'the per-run result is written anyway'
Assert-True (@([System.IO.Directory]::GetFiles($reports, '*.tmp')).Count -eq 0) 'no temporary file left in the reports directory'

# ============================================================ uninstall

function New-UninstallOptions {
    return @{ LockFile = (Join-Path $script:Fake.Root 'alloy-install.lock'); SecretsDir = $script:Fake.Secrets; BundleFiles = @() }
}

New-FakeHost | Out-Null
$script:Fake.Elevated = $false
$r = Invoke-SkyEyeUninstall (New-UninstallOptions)
Assert-Equal $r.stop_point 'elevation' 'uninstall needs elevation'
Assert-Untouched 'uninstall without elevation'

New-FakeHost | Out-Null
$r = Invoke-SkyEyeUninstall (New-UninstallOptions)
Assert-Equal $r.status 'uninstalled' 'uninstall: status'
Assert-Equal $script:Fake.State 'Stopped' 'uninstall: service stopped'
Assert-Equal $script:Fake.StartupType 'Disabled' 'uninstall: service disabled'
$stub = Read-SkyEyeTextFile $script:Fake.Config
Assert-True ($stub.StartsWith('// SkyEye agent uninstalled') -and $stub -notmatch 'remote_write|loki\.') 'uninstall: the config has no pipeline'
Assert-Equal (Read-SkyEyeTextFile ([string]$r.config.removed_config_kept_at)) $InterimConfig 'uninstall: the old config is kept beside it'
Assert-True ([System.IO.File]::Exists((Join-Path $script:Fake.Secrets 'cf-access-client-secret'))) 'uninstall: secret files kept by default'
Assert-Equal $r.config.secrets 'left_in_place' 'uninstall: says the secrets were left'
$r = Invoke-SkyEyeUninstall (New-UninstallOptions)
Assert-Equal $r.status 'already_uninstalled' 'uninstall twice: nothing to do'
Assert-True ($script:Fake.Stops -eq 1) 'uninstall twice: no second stop'
$options = New-UninstallOptions
$options.RemoveSecrets = $true
$r = Invoke-SkyEyeUninstall $options
Assert-True (-not [System.IO.File]::Exists((Join-Path $script:Fake.Secrets 'cf-access-client-secret')) -and
    -not [System.IO.File]::Exists((Join-Path $script:Fake.Secrets 'cf-access-client-id'))) 'uninstall -RemoveSecrets deletes both files'
Assert-Equal $r.config.secrets 'removed' 'uninstall -RemoveSecrets: recorded'

if ($script:Failures -gt 0) {
    Write-Host ('FAIL: Windows installer logic: ' + $script:Failures + ' of ' + $script:Checks + ' checks failed')
    exit 1
}
Write-Host ('PASS: Windows installer logic: ' + $script:Checks + ' checks')
exit 0
