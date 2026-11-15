# SkyEye Alloy agent for Windows: everything install.ps1 and uninstall.ps1 share.
# Dot-source this file; do not run it.
#
# Keep it pure ASCII and free of PowerShell 7 syntax. Windows PowerShell 5.1
# reads a script without a BOM in the ANSI code page (Big5 on a zh-TW host),
# and it must run this file unchanged. Text files are read and written through
# .NET with an explicit encoding for the same reason; Get-Content, Set-Content
# and Out-File are not used. tests/windows/test-windows-installer.sh enforces
# all of this.
#
# Nothing here opens the Cloudflare Access secret files. Their existence, size
# and ACL are read from metadata only.
#
# Functions named *-SkyEyeHost* are the only ones that touch the machine
# (service, registry, processes, HTTP, ACL, Event Log, clock). The tests replace
# them with fakes; the rest is plain logic and file handling.

Set-StrictMode -Version 2.0

$script:SkyEyeStopMarker = 'skyeye-stop'
$script:SkyEyeQuiet = $false
$script:SkyEyeLogLines = New-Object System.Collections.ArrayList
$script:SkyEyeServiceName = 'Alloy'
$script:SkyEyeRegistryKey = 'HKLM:\SOFTWARE\GrafanaLabs\Alloy'
$script:SkyEyeAllowedSecretSids = @('S-1-5-18', 'S-1-5-32-544')
$script:SkyEyeClientIdBytes = 39
$script:SkyEyeCanarySource = 'SkyEye'
$script:SkyEyeCanaryEventId = 4242
$script:SkyEyeCanaryText = 'SkyEye installer canary: Windows Event Log to Loki delivery check. Safe to ignore.'
$script:SkyEyeDiscardProm = 'http://127.0.0.1:9/api/v1/write'
$script:SkyEyeDiscardLoki = 'http://127.0.0.1:9/loki/api/v1/push'
$script:SkyEyeStubMarker = '// SkyEye agent uninstalled'

# ------------------------------------------------------------------ logging

function Write-SkyEyeLog {
    param([string]$Message)
    $line = ('{0} {1}' -f [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'), $Message)
    [void]$script:SkyEyeLogLines.Add($line)
    if (-not $script:SkyEyeQuiet) {
        Write-Host $line
    }
}

# ------------------------------------------------------------------ files

function Read-SkyEyeTextFile {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-SkyEyeTextFile {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-SkyEyeSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $hash = $sha.ComputeHash($stream)
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-SkyEyeTextSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash((New-Object System.Text.UTF8Encoding($false)).GetBytes($Text))
    }
    finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Remove-SkyEyeFileQuietly {
    param([string]$Path)
    try {
        if ($Path -and [System.IO.File]::Exists($Path)) {
            [System.IO.File]::Delete($Path)
        }
    }
    catch {
        Write-SkyEyeLog ('could not delete ' + $Path)
    }
}

function Remove-SkyEyeDirectoryQuietly {
    param([string]$Path)
    try {
        if ($Path -and [System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::Delete($Path, $true)
        }
    }
    catch {
        Write-SkyEyeLog ('could not delete ' + $Path)
    }
}

# ------------------------------------------------------------------ input checks

function Test-SkyEyeSlug {
    param([string]$Value)
    return ($Value -cmatch '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$')
}

# https only, except loopback, which the smoke run and the tests use.
function Test-SkyEyePushUrl {
    param([string]$Value)
    if ($Value -cmatch '^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9/._-]*$') {
        return $true
    }
    return ($Value -cmatch '^http://127\.0\.0\.1(:[0-9]+)?/[A-Za-z0-9/._-]*$')
}

# An absolute directory that can stand inside an Alloy string and a glob.
function Test-SkyEyeDirectoryPath {
    param([string]$Value)
    if (-not $Value) {
        return $false
    }
    if ($Value -notmatch '^([A-Za-z]:[\\/]|/)') {
        return $false
    }
    return ($Value -notmatch '["''`*?<>|\[\]{}@\r\n]')
}

function ConvertTo-SkyEyeAlloyPath {
    param([string]$Path)
    return $Path.Replace('\', '/').TrimEnd('/')
}

# ------------------------------------------------------------------ render

function New-SkyEyeConfigText {
    param(
        [string]$TemplateDir,
        [string]$Product,
        [string]$ServerId,
        [string]$PromPushUrl,
        [string]$LokiPushUrl,
        [string]$SecretsDir,
        [string]$RunnerDiagDir
    )
    $text = Read-SkyEyeTextFile (Join-Path $TemplateDir 'config.alloy.tmpl')
    if ($RunnerDiagDir) {
        $text = $text + (Read-SkyEyeTextFile (Join-Path $TemplateDir 'config-runner-diag.alloy.tmpl'))
    }
    $values = [ordered]@{
        'PRODUCT'       = $Product
        'SERVER_ID'     = $ServerId
        'PROM_PUSH_URL' = $PromPushUrl
        'LOKI_PUSH_URL' = $LokiPushUrl
        'SECRETS_DIR'   = (ConvertTo-SkyEyeAlloyPath $SecretsDir)
    }
    if ($RunnerDiagDir) {
        $values['RUNNER_DIAG_GLOB'] = ((ConvertTo-SkyEyeAlloyPath $RunnerDiagDir) + '/Runner_*.log')
    }
    foreach ($name in $values.Keys) {
        $text = $text.Replace(('@@' + $name + '@@'), [string]$values[$name])
    }
    $text = $text.Replace("`r`n", "`n")
    if ($text.Contains('@@')) {
        throw 'the rendered config still contains an @@ placeholder'
    }
    return $text
}

# product and server_id of every external_labels block in a config.
function Get-SkyEyeExternalLabels {
    param([string]$ConfigText)
    $found = New-Object System.Collections.ArrayList
    foreach ($block in [regex]::Matches($ConfigText, 'external_labels\s*=\s*\{([^}]*)\}')) {
        $body = $block.Groups[1].Value
        $entry = @{ product = $null; server_id = $null }
        $product = [regex]::Match($body, '(?m)^\s*"?product"?\s*=\s*"([^"]*)"')
        if ($product.Success) {
            $entry.product = $product.Groups[1].Value
        }
        $server = [regex]::Match($body, '(?m)^\s*"?server_id"?\s*=\s*"([^"]*)"')
        if ($server.Success) {
            $entry.server_id = $server.Groups[1].Value
        }
        [void]$found.Add($entry)
    }
    return , $found.ToArray()
}

# Empty when the labels in ConfigText agree with the parameters, else why not.
function Get-SkyEyeLabelConflict {
    param([string]$ConfigText, [string]$Product, [string]$ServerId)
    foreach ($entry in (Get-SkyEyeExternalLabels $ConfigText)) {
        if ($null -ne $entry.product -and $entry.product -cne $Product) {
            return ('the live config sends product="' + $entry.product + '", this run was given "' + $Product + '"')
        }
        if ($null -ne $entry.server_id -and $entry.server_id -cne $ServerId) {
            return ('the live config sends server_id="' + $entry.server_id + '", this run was given "' + $ServerId + '"')
        }
    }
    return ''
}

function Get-SkyEyeConfigCapabilities {
    param([string]$ConfigText)
    return @{
        RemoteWrite = ($ConfigText -match '(?m)^\s*prometheus\.remote_write\s+"')
        EventLog    = (($ConfigText -match '(?m)^\s*loki\.source\.windowsevent\s+"') -and ($ConfigText -match '(?m)^\s*loki\.write\s+"'))
    }
}

# ------------------------------------------------------------------ Alloy facts

function Get-SkyEyeAlloyVersionFromBanner {
    param([string]$Banner)
    $first = ([string]$Banner -split "`n")[0].Trim()
    $match = [regex]::Match($first, '^alloy, version v?([0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?)(\s|$)')
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return ''
}

function Get-SkyEyeTestedVersions {
    param([string]$VersionsFile)
    $text = Read-SkyEyeTextFile $VersionsFile
    $match = [regex]::Match($text, '(?m)^SKYEYE_ALLOY_WINDOWS_VERSIONS="([^"]*)"')
    if (-not $match.Success) {
        return , @()
    }
    return , @($match.Groups[1].Value -split '\s+' | Where-Object { $_ })
}

# Config path, storage path and listen address from the service's argument list.
function Get-SkyEyeAlloyRunSettings {
    param([string[]]$Arguments, [string]$DefaultConfigPath)
    $config = ''
    $storage = ''
    $listen = '127.0.0.1:12345'
    $list = @($Arguments | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $index = 0
    while ($index -lt $list.Count) {
        $item = $list[$index]
        $index = $index + 1
        if ($item -ceq 'run') {
            continue
        }
        if ($item -match '^--storage\.path=(.+)$') {
            $storage = $Matches[1]
            continue
        }
        if ($item -match '^--server\.http\.listen-addr=(.+)$') {
            $listen = $Matches[1]
            continue
        }
        if (($item -ceq '--storage.path' -or $item -ceq '--server.http.listen-addr') -and $index -lt $list.Count) {
            if ($item -ceq '--storage.path') {
                $storage = $list[$index]
            }
            else {
                $listen = $list[$index]
            }
            $index = $index + 1
            continue
        }
        if ($item.StartsWith('-')) {
            continue
        }
        if (-not $config) {
            $config = $item
        }
    }
    if (-not $config) {
        $config = $DefaultConfigPath
    }
    if ($listen -match '^(0\.0\.0\.0)?:([0-9]+)$') {
        $listen = '127.0.0.1:' + $Matches[2]
    }
    return @{ ConfigPath = $config; StoragePath = $storage; ListenAddress = $listen }
}

# ------------------------------------------------------------------ metrics

function ConvertFrom-SkyEyeMetricsText {
    param([string]$Text)
    $samples = New-Object System.Collections.ArrayList
    foreach ($raw in ([string]$Text -split "`n")) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) {
            continue
        }
        $match = [regex]::Match($line, '^([A-Za-z_:][A-Za-z0-9_:]*)(\{.*\})?\s+(\S+)')
        if (-not $match.Success) {
            continue
        }
        $value = 0.0
        $parsed = [double]::TryParse($match.Groups[3].Value, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)
        if (-not $parsed) {
            continue
        }
        [void]$samples.Add(@{ Name = $match.Groups[1].Value; Labels = $match.Groups[2].Value; Value = $value })
    }
    return , $samples.ToArray()
}

function Get-SkyEyeMetricSum {
    param($Samples, [string]$Name, [string]$ExcludeLabelPattern = '')
    $sum = 0.0
    foreach ($sample in @($Samples)) {
        if ($sample.Name -cne $Name) {
            continue
        }
        if ($ExcludeLabelPattern -and $sample.Labels -match $ExcludeLabelPattern) {
            continue
        }
        $sum = $sum + $sample.Value
    }
    return $sum
}

function Get-SkyEyeMetricMax {
    param($Samples, [string]$Name)
    $max = 0.0
    foreach ($sample in @($Samples)) {
        if ($sample.Name -ceq $Name -and $sample.Value -gt $max) {
            $max = $sample.Value
        }
    }
    return $max
}

# What Alloy's own /metrics says about delivery.
#
# prometheus_remote_storage_samples_total counts attempts: it rises against a
# dead endpoint too. Proof that a batch arrived is the highest sent timestamp.
function Get-SkyEyeDeliverySnapshot {
    param([string]$MetricsText)
    $samples = ConvertFrom-SkyEyeMetricsText $MetricsText
    return @{
        PromAttempted   = (Get-SkyEyeMetricSum $samples 'prometheus_remote_storage_samples_total')
        PromFailed      = (Get-SkyEyeMetricSum $samples 'prometheus_remote_storage_samples_failed_total')
        PromRetried     = (Get-SkyEyeMetricSum $samples 'prometheus_remote_storage_samples_retried_total')
        PromHighestSent = (Get-SkyEyeMetricMax $samples 'prometheus_remote_storage_queue_highest_sent_timestamp_seconds')
        LokiSent        = (Get-SkyEyeMetricSum $samples 'loki_write_sent_entries_total')
        LokiDropped     = (Get-SkyEyeMetricSum $samples 'loki_write_dropped_entries_total')
        LokiNot2xx      = (Get-SkyEyeMetricSum $samples 'loki_write_request_duration_seconds_count' 'status_code="2[0-9][0-9]"')
    }
}

function New-SkyEyeZeroSnapshot {
    return @{ PromAttempted = 0.0; PromFailed = 0.0; PromRetried = 0.0; PromHighestSent = 0.0; LokiSent = 0.0; LokiDropped = 0.0; LokiNot2xx = 0.0 }
}

# ------------------------------------------------------------------ ACL

# Report is @{ Owner = <sid>; Rules = @(@{ Sid; Type }) }. Returns the problems.
function Get-SkyEyeAclProblems {
    param($Report, [string]$What)
    $problems = New-Object System.Collections.ArrayList
    if ($script:SkyEyeAllowedSecretSids -notcontains $Report.Owner) {
        [void]$problems.Add($What + ': owner is ' + $Report.Owner + ', expected SYSTEM or Administrators')
    }
    foreach ($rule in @($Report.Rules)) {
        if ($rule.Type -ne 'Allow') {
            continue
        }
        if ($script:SkyEyeAllowedSecretSids -notcontains $rule.Sid) {
            [void]$problems.Add($What + ': access is granted to ' + $rule.Sid)
        }
    }
    return , $problems.ToArray()
}

# ------------------------------------------------------------------ result

function New-SkyEyeResult {
    param([string]$Kind, [string]$Mode)
    $now = [DateTime]::UtcNow
    $runId = ('{0}-{1}' -f $now.ToString('yyyyMMddTHHmmssZ'), $PID)
    return [ordered]@{
        schema       = 'skyeye.windows-agent.v1'
        kind         = $Kind
        run_id       = $runId
        mode         = $Mode
        status       = 'internal_error'
        exit_code    = 1
        stop_point   = ''
        message      = ''
        started_utc  = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
        finished_utc = ''
        elevated     = $false
        powershell   = ('{0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
        params       = [ordered]@{}
        alloy        = [ordered]@{}
        bundle       = New-Object System.Collections.ArrayList
        config       = [ordered]@{}
        checks       = New-Object System.Collections.ArrayList
        delivery     = [ordered]@{}
        rollback     = [ordered]@{ attempted = $false; ok = $false; detail = '' }
        notes        = New-Object System.Collections.ArrayList
    }
}

# Outcome is passed, failed or skipped. A check that could not run for lack of
# rights is skipped, never passed.
function Add-SkyEyeCheck {
    param($Result, [string]$Name, [string]$Outcome, [string]$Detail = '')
    [void]$Result.checks.Add([ordered]@{ name = $Name; outcome = $Outcome; detail = $Detail })
    Write-SkyEyeLog ('check ' + $Name + ': ' + $Outcome + $(if ($Detail) { ' (' + $Detail + ')' } else { '' }))
}

function Stop-SkyEyeRun {
    param($Result, [string]$Status, [string]$StopPoint, [int]$ExitCode, [string]$Message)
    $Result.status = $Status
    $Result.stop_point = $StopPoint
    $Result.exit_code = $ExitCode
    $Result.message = $Message
    Write-SkyEyeLog ('STOP at ' + $StopPoint + ': ' + $Status + ': ' + $Message)
    throw (New-Object System.OperationCanceledException($script:SkyEyeStopMarker))
}

function Test-SkyEyeStop {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    return ($exception -is [System.OperationCanceledException] -and $exception.Message -ceq $script:SkyEyeStopMarker)
}

# Writes <kind>-<run id>.json and .log, then a "latest" pointer.
#
# The reports directory lets every user create files but only the creator or an
# administrator replace them. So the per-run file is the record, its name is
# never reused, and there is one pointer per privilege level: a non-admin Check
# never has to replace a file an elevated run wrote. A pointer that cannot be
# written is reported, not fatal.
function Write-SkyEyeResultFiles {
    param($Result, [string]$ResultDir)
    $written = @{ RunFile = ''; LogFile = ''; PointerFile = ''; PointerError = '' }
    $Result.finished_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    [void][System.IO.Directory]::CreateDirectory($ResultDir)
    $base = Join-Path $ResultDir ('windows-agent-' + $Result.kind + '-' + $Result.run_id)
    $written.RunFile = $base + '.json'
    $written.LogFile = $base + '.log'
    Write-SkyEyeTextFile $written.LogFile ((@($script:SkyEyeLogLines) -join "`n") + "`n")
    $json = ConvertTo-Json -InputObject $Result -Depth 8
    Write-SkyEyeTextFile $written.RunFile ($json + "`n")

    $level = 'user'
    if ($Result.elevated) {
        $level = 'admin'
    }
    $pointer = Join-Path $ResultDir ('windows-agent-' + $Result.kind + '-latest-' + $level + '.json')
    $temporary = $pointer + '.' + $Result.run_id + '.tmp'
    try {
        Write-SkyEyeTextFile $temporary ($json + "`n")
        if ([System.IO.File]::Exists($pointer)) {
            [System.IO.File]::Replace($temporary, $pointer, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($temporary, $pointer)
        }
        $written.PointerFile = $pointer
    }
    catch {
        $written.PointerError = ('could not update ' + $pointer + ': ' + $_.Exception.Message)
        Remove-SkyEyeFileQuietly $temporary
    }
    return $written
}

# ------------------------------------------------------------------ host: clock, rights, lock

function Get-SkyEyeHostNow {
    return [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Invoke-SkyEyeHostSleep {
    param([int]$Milliseconds)
    Start-Sleep -Milliseconds $Milliseconds
}

function Test-SkyEyeHostElevated {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# One install, rollback or uninstall at a time. The handle is the lock: it goes
# away with the process, so a killed run leaves nothing to clean up.
function Enter-SkyEyeHostLock {
    param([string]$Path)
    try {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
        return [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch {
        return $null
    }
}

function Exit-SkyEyeHostLock {
    param($Handle)
    if ($Handle) {
        $Handle.Dispose()
    }
}

function Test-SkyEyeHostPortFree {
    param([int]$Port)
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        $listener.Stop()
        return $true
    }
    catch {
        return $false
    }
}

# ------------------------------------------------------------------ host: Alloy service

function Get-SkyEyeHostAlloy {
    $info = @{
        ServiceExists = $false; State = ''; StartMode = ''; Account = ''; ProcessId = 0
        WrapperPath = ''; ExePath = ''; Arguments = @()
    }
    $filter = "Name='" + $script:SkyEyeServiceName + "'"
    $service = Get-CimInstance -ClassName Win32_Service -Filter $filter -ErrorAction SilentlyContinue
    if ($service) {
        $info.ServiceExists = $true
        $info.State = [string]$service.State
        $info.StartMode = [string]$service.StartMode
        $info.Account = [string]$service.StartName
        $info.ProcessId = [int]$service.ProcessId
        $info.WrapperPath = ([string]$service.PathName).Trim('"')
    }
    $key = Get-Item -LiteralPath $script:SkyEyeRegistryKey -ErrorAction SilentlyContinue
    if ($key) {
        $info.ExePath = [string]$key.GetValue('')
        $info.Arguments = @($key.GetValue('Arguments'))
    }
    return $info
}

function Restart-SkyEyeHostService {
    Restart-Service -Name $script:SkyEyeServiceName -Force -ErrorAction Stop
}

function Start-SkyEyeHostService {
    Start-Service -Name $script:SkyEyeServiceName -ErrorAction Stop
}

function Stop-SkyEyeHostService {
    Stop-Service -Name $script:SkyEyeServiceName -Force -ErrorAction Stop
}

function Set-SkyEyeHostServiceStartup {
    param([string]$StartupType)
    Set-Service -Name $script:SkyEyeServiceName -StartupType $StartupType -ErrorAction Stop
}

# ------------------------------------------------------------------ host: processes and HTTP

function Join-SkyEyeArguments {
    param([string[]]$ArgumentList)
    $parts = New-Object System.Collections.ArrayList
    foreach ($argument in @($ArgumentList)) {
        if ($argument -match '[\s"]') {
            [void]$parts.Add('"' + ($argument -replace '"', '\"') + '"')
        }
        else {
            [void]$parts.Add($argument)
        }
    }
    return ($parts.ToArray() -join ' ')
}

function Start-SkyEyeHostBackgroundProcess {
    param([string]$FilePath, [string[]]$ArgumentList)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $FilePath
    $start.Arguments = Join-SkyEyeArguments $ArgumentList
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    [void]$process.Start()
    return @{
        Process = $process
        Out     = $process.StandardOutput.ReadToEndAsync()
        Err     = $process.StandardError.ReadToEndAsync()
    }
}

function Test-SkyEyeHostBackgroundExited {
    param($Handle)
    return $Handle.Process.HasExited
}

# Ends the process if it still runs and returns its exit code and output.
function Stop-SkyEyeHostBackgroundProcess {
    param($Handle)
    $killed = $false
    if (-not $Handle.Process.HasExited) {
        try {
            $Handle.Process.Kill()
            $killed = $true
        }
        catch {
            Write-SkyEyeLog 'could not end the background process'
        }
    }
    [void]$Handle.Process.WaitForExit(15000)
    $output = ''
    if ($Handle.Out.Wait(5000)) {
        $output = $output + $Handle.Out.Result
    }
    if ($Handle.Err.Wait(5000)) {
        $output = $output + $Handle.Err.Result
    }
    $code = -1
    if ($Handle.Process.HasExited) {
        $code = $Handle.Process.ExitCode
    }
    return @{ ExitCode = $code; Killed = $killed; Output = $output }
}

function Invoke-SkyEyeHostProcess {
    param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds = 60)
    $handle = Start-SkyEyeHostBackgroundProcess -FilePath $FilePath -ArgumentList $ArgumentList
    $finished = $handle.Process.WaitForExit($TimeoutSeconds * 1000)
    $ended = Stop-SkyEyeHostBackgroundProcess $handle
    return @{ ExitCode = $ended.ExitCode; TimedOut = (-not $finished); Output = $ended.Output }
}

# Status 0 means no answer.
function Get-SkyEyeHostHttp {
    param([string]$Url, [int]$TimeoutSeconds = 5)
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutSeconds * 1000
        $request.Proxy = $null
        $response = $request.GetResponse()
        try {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            $body = $reader.ReadToEnd()
            $reader.Dispose()
            return @{ Status = [int]$response.StatusCode; Body = $body }
        }
        finally {
            $response.Close()
        }
    }
    catch {
        $exception = $_.Exception
        while ($exception -and -not ($exception -is [System.Net.WebException])) {
            $exception = $exception.InnerException
        }
        if ($exception -and $exception.Response) {
            return @{ Status = [int]$exception.Response.StatusCode; Body = '' }
        }
        return @{ Status = 0; Body = '' }
    }
}

# ------------------------------------------------------------------ host: secrets metadata, Event Log

# Size and existence only. The file is never opened.
function Get-SkyEyeHostFileFacts {
    param([string]$Path)
    try {
        $file = New-Object System.IO.FileInfo($Path)
        if (-not $file.Exists) {
            return @{ Exists = $false; Length = 0; Error = '' }
        }
        return @{ Exists = $true; Length = [int64]$file.Length; Error = '' }
    }
    catch {
        return @{ Exists = $false; Length = 0; Error = $_.Exception.Message }
    }
}

# By SID, so a localized Windows gives the same answer.
function Get-SkyEyeHostAclReport {
    param([string]$Path)
    $sidType = [System.Security.Principal.SecurityIdentifier]
    $acl = Get-Acl -LiteralPath $Path
    $rules = New-Object System.Collections.ArrayList
    foreach ($rule in $acl.GetAccessRules($true, $true, $sidType)) {
        [void]$rules.Add(@{ Sid = $rule.IdentityReference.Value; Type = [string]$rule.AccessControlType })
    }
    return @{ Owner = $acl.GetOwner($sidType).Value; Rules = $rules.ToArray() }
}

# A dedicated source, registered on first use and left in place by uninstall.
function Write-SkyEyeHostCanaryEvent {
    $source = $script:SkyEyeCanarySource
    if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
        [System.Diagnostics.EventLog]::CreateEventSource($source, 'Application')
    }
    [System.Diagnostics.EventLog]::WriteEntry($source, $script:SkyEyeCanaryText,
        [System.Diagnostics.EventLogEntryType]::Warning, $script:SkyEyeCanaryEventId)
}

# ------------------------------------------------------------------ shared steps

# Only warnings and errors, cut short. Alloy never logs a header value, and
# this keeps anything unexpected in its output out of the result files too.
function Get-SkyEyeAlloyOutputSummary {
    param([string]$Output)
    $kept = New-Object System.Collections.ArrayList
    foreach ($line in ([string]$Output -split "`n")) {
        $text = $line.Trim()
        if ($text -notmatch 'level=(error|warn)|^Error|validation failed') {
            continue
        }
        if ($text.Length -gt 300) {
            $text = $text.Substring(0, 300)
        }
        [void]$kept.Add($text)
        if ($kept.Count -ge 15) {
            break
        }
    }
    return ($kept.ToArray() -join ' | ')
}

# Fills Result.alloy and returns the facts the later steps need. Stops the run
# when Alloy is missing, not a tested version or not running as LocalSystem.
function Get-SkyEyeAlloyFacts {
    param($Result, [hashtable]$Options, [bool]$CheckVersion)
    $host_ = Get-SkyEyeHostAlloy
    if (-not $host_.ServiceExists) {
        Add-SkyEyeCheck $Result 'alloy_service' 'failed' 'no service named Alloy'
        Stop-SkyEyeRun $Result 'refused' 'alloy' 1 'Alloy is not installed. Install the pinned version first; see runbooks/windows-host-onboarding.md.'
    }
    $exe = [string]$Options.AlloyExe
    if (-not $exe) {
        $exe = $host_.ExePath
    }
    if (-not $exe -or -not [System.IO.File]::Exists($exe)) {
        Add-SkyEyeCheck $Result 'alloy_binary' 'failed' 'cannot find the Alloy binary'
        Stop-SkyEyeRun $Result 'refused' 'alloy' 1 'Cannot find the Alloy binary from the registry. Pass -AlloyExe.'
    }
    $defaultConfig = Join-Path ([System.IO.Path]::GetDirectoryName($exe)) 'config.alloy'
    $settings = Get-SkyEyeAlloyRunSettings -Arguments $host_.Arguments -DefaultConfigPath $defaultConfig
    $facts = @{
        Exe = $exe; ConfigPath = $settings.ConfigPath; StoragePath = $settings.StoragePath
        ListenAddress = $settings.ListenAddress; State = $host_.State; StartMode = $host_.StartMode
        Account = $host_.Account; Version = ''
    }
    $Result.alloy.exe = $exe
    $Result.alloy.config_path = $facts.ConfigPath
    $Result.alloy.storage_path = $facts.StoragePath
    $Result.alloy.listen_address = $facts.ListenAddress
    $Result.alloy.service_state_before = $facts.State
    $Result.alloy.service_start_mode_before = $facts.StartMode
    $Result.alloy.service_account = $facts.Account
    Add-SkyEyeCheck $Result 'alloy_service' 'passed' ('state ' + $facts.State)

    if (-not $CheckVersion) {
        return $facts
    }

    if ($facts.Account -notmatch '^(LocalSystem|NT AUTHORITY\\SYSTEM)$') {
        Add-SkyEyeCheck $Result 'alloy_service_account' 'failed' $facts.Account
        Stop-SkyEyeRun $Result 'refused' 'alloy' 1 'The Alloy service must run as LocalSystem: only SYSTEM and Administrators may read the secret files.'
    }
    Add-SkyEyeCheck $Result 'alloy_service_account' 'passed' $facts.Account

    $banner = Invoke-SkyEyeHostProcess -FilePath $exe -ArgumentList @('--version') -TimeoutSeconds 30
    $facts.Version = Get-SkyEyeAlloyVersionFromBanner $banner.Output
    $Result.alloy.version = $facts.Version
    if (-not $facts.Version) {
        Add-SkyEyeCheck $Result 'alloy_version' 'failed' 'cannot read a version from alloy --version'
        Stop-SkyEyeRun $Result 'refused' 'alloy' 1 'Cannot read a version from alloy --version.'
    }
    $tested = Get-SkyEyeTestedVersions $Options.VersionsFile
    if ($tested -contains $facts.Version) {
        Add-SkyEyeCheck $Result 'alloy_version' 'passed' $facts.Version
    }
    elseif ($Options.AllowUntestedAlloyVersion -and $Options.AllowUntestedAlloyVersion -ceq $facts.Version) {
        Add-SkyEyeCheck $Result 'alloy_version' 'passed' ($facts.Version + ' is not tested; allowed by -AllowUntestedAlloyVersion')
    }
    else {
        Add-SkyEyeCheck $Result 'alloy_version' 'failed' ($facts.Version + ' is not in ' + ($tested -join ' '))
        Stop-SkyEyeRun $Result 'refused' 'alloy' 1 ('Alloy ' + $facts.Version + ' is not a tested Windows version (' + ($tested -join ' ') + '). See agents/alloy/alloy-versions.env.')
    }
    return $facts
}

# Service on one process and /-/ready answering, within the timeout.
function Wait-SkyEyeServiceReady {
    param([string]$ListenAddress, [int]$TimeoutSeconds, [int]$PollMilliseconds)
    $deadline = (Get-SkyEyeHostNow) + $TimeoutSeconds
    while ($true) {
        $service = Get-SkyEyeHostAlloy
        if ($service.State -eq 'Running') {
            $ready = Get-SkyEyeHostHttp -Url ('http://' + $ListenAddress + '/-/ready')
            if ($ready.Status -eq 200) {
                return $true
            }
        }
        if ((Get-SkyEyeHostNow) -ge $deadline) {
            return $false
        }
        Invoke-SkyEyeHostSleep $PollMilliseconds
    }
}

# The health gate after a swap, or on a config that is already current.
#
# Restarted: the counters started at zero, so any failure counts. Otherwise the
# first reading is the baseline and only what happens during the gate counts.
function Invoke-SkyEyeHealthGate {
    param(
        [string]$ListenAddress,
        [bool]$Restarted,
        [bool]$RequireProm,
        [bool]$RequireLoki,
        [int]$TimeoutSeconds,
        [int]$PollMilliseconds
    )
    $since = Get-SkyEyeHostNow
    $deadline = $since + $TimeoutSeconds
    $gate = @{ Ok = $false; Reason = ''; Delivery = [ordered]@{}; Canaries = 0 }
    $firstPid = 0
    $pidSince = 0
    $baseline = $null
    if ($Restarted) {
        $baseline = New-SkyEyeZeroSnapshot
    }
    $previous = $null
    $canaryAt = 0
    $waitingFor = 'service'

    while ($true) {
        $now = Get-SkyEyeHostNow
        $service = Get-SkyEyeHostAlloy
        if ($service.State -eq 'Running' -and $service.ProcessId -gt 0) {
            if ($firstPid -eq 0) {
                $firstPid = $service.ProcessId
                $pidSince = $now
            }
            elseif ($service.ProcessId -ne $firstPid) {
                $gate.Reason = 'the Alloy process changed during the check: it is restarting'
                return $gate
            }
        }
        elseif ($firstPid -ne 0) {
            $gate.Reason = 'the Alloy service stopped after it had started'
            return $gate
        }

        if ($firstPid -ne 0) {
            $waitingFor = 'ready'
            $ready = Get-SkyEyeHostHttp -Url ('http://' + $ListenAddress + '/-/ready')
            $metrics = $null
            if ($ready.Status -eq 200) {
                $metrics = Get-SkyEyeHostHttp -Url ('http://' + $ListenAddress + '/metrics')
            }
            if ($metrics -and $metrics.Status -eq 200) {
                $snapshot = Get-SkyEyeDeliverySnapshot $metrics.Body
                if ($null -eq $baseline) {
                    $baseline = $snapshot
                }
                $promFailed = $snapshot.PromFailed - $baseline.PromFailed
                $lokiDropped = $snapshot.LokiDropped - $baseline.LokiDropped
                $lokiSent = $snapshot.LokiSent - $baseline.LokiSent
                $gate.Delivery = [ordered]@{
                    prom_samples_attempted = $snapshot.PromAttempted
                    prom_samples_failed    = $promFailed
                    prom_samples_retried   = $snapshot.PromRetried
                    prom_highest_sent_age  = $(if ($snapshot.PromHighestSent -gt 0) { [int64]($now - $snapshot.PromHighestSent) } else { -1 })
                    loki_entries_sent      = $lokiSent
                    loki_entries_dropped   = $lokiDropped
                    loki_requests_not_2xx  = ($snapshot.LokiNot2xx - $baseline.LokiNot2xx)
                    canary_events_written  = $gate.Canaries
                }
                if ($RequireProm -and $promFailed -gt 0) {
                    $gate.Reason = 'central Prometheus rejected samples (4xx): check the Access token and its policy on prom-push'
                    return $gate
                }
                if ($RequireLoki -and $lokiDropped -gt 0) {
                    $gate.Reason = 'Alloy dropped log entries: check the Access token policy on loki-push'
                    return $gate
                }

                $settled = ($null -ne $previous)
                $promOk = $true
                if ($RequireProm) {
                    $promOk = ($snapshot.PromHighestSent -ge $since -and $settled -and $snapshot.PromRetried -eq $previous.PromRetried)
                }
                $lokiOk = $true
                if ($RequireLoki) {
                    if ($promOk -and $gate.Canaries -lt 3 -and ($canaryAt -eq 0 -or ($now - $canaryAt) -ge 20) -and $lokiSent -lt 1) {
                        try {
                            Write-SkyEyeHostCanaryEvent
                            $gate.Canaries = $gate.Canaries + 1
                            $gate.Delivery.canary_events_written = $gate.Canaries
                            Write-SkyEyeLog 'wrote the canary event to the Application log'
                        }
                        catch {
                            Write-SkyEyeLog ('could not write the canary event: ' + $_.Exception.Message)
                        }
                        $canaryAt = $now
                    }
                    $lokiOk = ($lokiSent -ge 1 -and $settled -and $snapshot.LokiNot2xx -eq $previous.LokiNot2xx)
                }
                $stable = (($now - $pidSince) -ge 10)
                if ($promOk -and $lokiOk -and $stable) {
                    $gate.Ok = $true
                    return $gate
                }
                if (-not $promOk) {
                    $waitingFor = 'a batch acknowledged by central Prometheus'
                }
                elseif (-not $lokiOk) {
                    $waitingFor = 'a log entry acknowledged by central Loki'
                }
                else {
                    $waitingFor = 'ten seconds on one process'
                }
                $previous = $snapshot
            }
        }

        if ($now -ge $deadline) {
            $gate.Reason = ('timed out after ' + $TimeoutSeconds + 's waiting for ' + $waitingFor)
            return $gate
        }
        Invoke-SkyEyeHostSleep $PollMilliseconds
    }
}

# Puts the config from before this run back and returns the service to how it
# was found. Never throws; the outcome is in Result.rollback.
function Invoke-SkyEyeRestore {
    param($Result, [hashtable]$Context, [hashtable]$Options)
    $Result.rollback.attempted = $true
    Write-SkyEyeLog 'ROLLBACK: restoring the previous config'
    try {
        $failed = $Context.ConfigPath + '.failed-' + $Result.run_id
        [System.IO.File]::Copy($Context.ConfigPath, $failed, $true)
        $Result.config.failed_config_kept_at = $failed
        [System.IO.File]::Replace($Context.RollbackPath, $Context.ConfigPath, [NullString]::Value)
        if ($Context.WasRunning) {
            Restart-SkyEyeHostService
            if (-not (Wait-SkyEyeServiceReady -ListenAddress $Context.ListenAddress -TimeoutSeconds 60 -PollMilliseconds $Options.PollMilliseconds)) {
                throw 'Alloy did not come back on the previous config'
            }
        }
        else {
            $service = Get-SkyEyeHostAlloy
            if ($service.State -ne 'Stopped') {
                Stop-SkyEyeHostService
            }
        }
        $Result.rollback.ok = $true
        $Result.rollback.detail = 'previous config restored'
        Write-SkyEyeLog 'ROLLBACK: done'
    }
    catch {
        $Result.rollback.ok = $false
        $Result.rollback.detail = ('rollback did not finish: ' + $_.Exception.Message + '. By hand: compare ' +
            $Context.ConfigPath + ' with ' + $Context.RollbackPath + ' (the config from before this run, if it still exists), ' +
            'put the right one in place, then restart the Alloy service.')
        Write-SkyEyeLog ('CRITICAL: ' + $Result.rollback.detail)
    }
}

# Swaps StagedPath in, restarts, runs the health gate, and rolls back on any
# failure. Sets the final status.
function Invoke-SkyEyeSwapAndVerify {
    param($Result, [hashtable]$Context, [hashtable]$Options, [string]$StagedPath, [string]$DoneStatus)
    $swapped = $false
    $failure = ''
    try {
        [System.IO.File]::Replace($StagedPath, $Context.ConfigPath, $Context.RollbackPath)
        $swapped = $true
        Write-SkyEyeLog ('swapped the new config in; the old one is ' + $Context.RollbackPath)
        if ($Context.WasRunning) {
            Restart-SkyEyeHostService
        }
        else {
            Start-SkyEyeHostService
        }
        $capabilities = Get-SkyEyeConfigCapabilities (Read-SkyEyeTextFile $Context.ConfigPath)
        $gate = Invoke-SkyEyeHealthGate -ListenAddress $Context.ListenAddress -Restarted $true `
            -RequireProm $capabilities.RemoteWrite -RequireLoki $capabilities.EventLog `
            -TimeoutSeconds $Options.HealthTimeoutSeconds -PollMilliseconds $Options.PollMilliseconds
        $Result.delivery = $gate.Delivery
        if (-not $gate.Ok) {
            $failure = $gate.Reason
        }
    }
    catch {
        $failure = ('activation failed: ' + $_.Exception.Message)
    }

    if (-not $failure) {
        Add-SkyEyeCheck $Result 'health_gate' 'passed' ''
        try {
            Remove-SkyEyeFileQuietly $Context.PreviousPath
            [System.IO.File]::Move($Context.RollbackPath, $Context.PreviousPath)
            $Result.config.previous_config_kept_at = $Context.PreviousPath
        }
        catch {
            [void]$Result.notes.Add('could not rename ' + $Context.RollbackPath + ' to ' + $Context.PreviousPath + '; rename or delete it before the next run')
        }
        $Result.status = $DoneStatus
        $Result.exit_code = 0
        $Result.message = 'The new config is live and delivering.'
        return
    }

    Add-SkyEyeCheck $Result 'health_gate' 'failed' $failure
    if (-not $swapped) {
        Remove-SkyEyeFileQuietly $StagedPath
        $Result.status = 'refused'
        $Result.stop_point = 'swap'
        $Result.exit_code = 1
        $Result.message = ('Could not swap the config in; nothing was changed. ' + $failure)
        return
    }
    Invoke-SkyEyeRestore -Result $Result -Context $Context -Options $Options
    $Result.stop_point = 'health_gate'
    if ($Result.rollback.ok) {
        $Result.status = 'rolled_back'
        $Result.exit_code = 1
        $Result.message = ('The new config was rolled back: ' + $failure)
    }
    else {
        $Result.status = 'rollback_incomplete'
        $Result.exit_code = 3
        $Result.message = ('CRITICAL: ' + $failure + '. ' + $Result.rollback.detail)
    }
}

function Set-SkyEyeOptionDefaults {
    param([hashtable]$Options)
    $defaults = @{
        HealthTimeoutSeconds = 120; PollMilliseconds = 5000; SmokePort = 12399; SmokeTimeoutSeconds = 40
        SmokeHoldMilliseconds = 5000; AlloyExe = ''; AllowUntestedAlloyVersion = ''; RunnerDiagDir = ''
        RemoveSecrets = $false
    }
    foreach ($name in $defaults.Keys) {
        if (-not $Options.ContainsKey($name)) {
            $Options[$name] = $defaults[$name]
        }
    }
}

function Add-SkyEyeBundleHashes {
    param($Result, [string[]]$Files)
    foreach ($file in @($Files)) {
        if ($file -and [System.IO.File]::Exists($file)) {
            [void]$Result.bundle.Add([ordered]@{ name = [System.IO.Path]::GetFileName($file); sha256 = (Get-SkyEyeSha256 $file) })
        }
    }
}

# ------------------------------------------------------------------ install

# Options: Mode (Check, Install, Rollback), Product, ServerId, PromPushUrl,
# LokiPushUrl, SecretsDir, RunnerDiagDir, TemplateDir, VersionsFile, WorkDir,
# LockFile, BundleFiles, and the optional ones in Set-SkyEyeOptionDefaults.
# Returns the result; the caller writes it to disk.
function Invoke-SkyEyeInstall {
    param([hashtable]$Options)
    Set-SkyEyeOptionDefaults $Options
    $result = New-SkyEyeResult -Kind 'install' -Mode ([string]$Options.Mode)
    $lock = $null
    $runDir = ''
    $smoke = $null
    try {
        # 1. Parameters.
        if (@('Check', 'Install', 'Rollback') -cnotcontains $Options.Mode) {
            Stop-SkyEyeRun $result 'usage_error' 'parameters' 2 '-Mode must be Check, Install or Rollback.'
        }
        $mode = [string]$Options.Mode
        $result.params.product = [string]$Options.Product
        $result.params.server_id = [string]$Options.ServerId
        $result.params.prom_push_url = [string]$Options.PromPushUrl
        $result.params.loki_push_url = [string]$Options.LokiPushUrl
        $result.params.runner_diag_dir = [string]$Options.RunnerDiagDir
        if ($mode -ne 'Rollback') {
            if (-not (Test-SkyEyeSlug $Options.Product)) {
                Stop-SkyEyeRun $result 'usage_error' 'parameters' 2 '-Product must be lowercase letters, digits and hyphens.'
            }
            if (-not (Test-SkyEyeSlug $Options.ServerId)) {
                Stop-SkyEyeRun $result 'usage_error' 'parameters' 2 '-ServerId must be lowercase letters, digits and hyphens.'
            }
            if (-not (Test-SkyEyePushUrl $Options.PromPushUrl) -or -not (Test-SkyEyePushUrl $Options.LokiPushUrl)) {
                Stop-SkyEyeRun $result 'usage_error' 'parameters' 2 'The push URLs must be https URLs.'
            }
            if (-not (Test-SkyEyeDirectoryPath $Options.SecretsDir)) {
                Stop-SkyEyeRun $result 'usage_error' 'parameters' 2 '-SecretsDir must be an absolute directory path.'
            }
            if ($Options.RunnerDiagDir -and -not (Test-SkyEyeDirectoryPath $Options.RunnerDiagDir)) {
                Stop-SkyEyeRun $result 'usage_error' 'parameters' 2 '-RunnerDiagDir must be an absolute directory path without wildcards.'
            }
        }
        Add-SkyEyeCheck $result 'parameters' 'passed' ''
        Add-SkyEyeBundleHashes $result $Options.BundleFiles

        # 2. Rights.
        $elevated = [bool](Test-SkyEyeHostElevated)
        $result.elevated = $elevated
        if ($mode -ne 'Check' -and -not $elevated) {
            Add-SkyEyeCheck $result 'elevation' 'failed' 'not running as administrator'
            Stop-SkyEyeRun $result 'refused' 'elevation' 1 ('-Mode ' + $mode + ' must run elevated (Start-Process -Verb RunAs). Nothing was changed.')
        }
        Add-SkyEyeCheck $result 'elevation' 'passed' $(if ($elevated) { 'administrator' } else { 'not elevated; checks that need administrator rights are skipped' })

        # 3. Lock. A Check changes nothing and takes none.
        if ($mode -ne 'Check') {
            $lock = Enter-SkyEyeHostLock $Options.LockFile
            if (-not $lock) {
                Add-SkyEyeCheck $result 'lock' 'failed' $Options.LockFile
                Stop-SkyEyeRun $result 'refused' 'lock' 1 ('Another SkyEye Alloy run holds ' + $Options.LockFile + '. Nothing was changed.')
            }
            Add-SkyEyeCheck $result 'lock' 'passed' ''
        }

        # 4. Alloy.
        $alloy = Get-SkyEyeAlloyFacts -Result $result -Options $Options -CheckVersion $true
        $context = @{
            ConfigPath    = $alloy.ConfigPath
            RollbackPath  = ($alloy.ConfigPath + '.rollback')
            PreviousPath  = ($alloy.ConfigPath + '.previous')
            ListenAddress = $alloy.ListenAddress
            WasRunning    = ($alloy.State -eq 'Running')
        }
        if ([System.IO.Directory]::Exists($context.ConfigPath)) {
            Stop-SkyEyeRun $result 'refused' 'alloy' 1 ('The service loads a directory (' + $context.ConfigPath + '); this installer manages one config file.')
        }

        if ($mode -eq 'Rollback') {
            if (-not [System.IO.File]::Exists($context.PreviousPath)) {
                Stop-SkyEyeRun $result 'refused' 'rollback_source' 1 ('There is no ' + $context.PreviousPath + ' to go back to. Nothing was changed.')
            }
            if ([System.IO.File]::Exists($context.RollbackPath)) {
                Stop-SkyEyeRun $result 'refused' 'unfinished_run' 1 ($context.RollbackPath + ' exists: an earlier run did not finish. See the runbook. Nothing was changed.')
            }
            $staged = $context.ConfigPath + '.staged-' + $PID
            [System.IO.File]::Copy($context.PreviousPath, $staged, $true)
            $validate = Invoke-SkyEyeHostProcess -FilePath $alloy.Exe -ArgumentList @('validate', $staged) -TimeoutSeconds 60
            if ($validate.ExitCode -ne 0) {
                Remove-SkyEyeFileQuietly $staged
                Add-SkyEyeCheck $result 'alloy_validate' 'failed' (Get-SkyEyeAlloyOutputSummary $validate.Output)
                Stop-SkyEyeRun $result 'failed_validate' 'validate' 1 'alloy validate rejected the previous config. Nothing was changed.'
            }
            Add-SkyEyeCheck $result 'alloy_validate' 'passed' 'previous config'
            $result.config.previous_sha256 = Get-SkyEyeSha256 $context.ConfigPath
            $result.config.new_sha256 = Get-SkyEyeSha256 $staged
            Invoke-SkyEyeSwapAndVerify -Result $result -Context $context -Options $Options -StagedPath $staged -DoneStatus 'restored_previous'
            return $result
        }

        # 5. Secret files: existence, size and ACL. Never their content.
        if (-not $elevated) {
            Add-SkyEyeCheck $result 'secret_files' 'skipped' 'needs administrator rights'
            Add-SkyEyeCheck $result 'secret_acl' 'skipped' 'needs administrator rights'
        }
        else {
            $idFile = Join-Path $Options.SecretsDir 'cf-access-client-id'
            $secretFile = Join-Path $Options.SecretsDir 'cf-access-client-secret'
            $idFacts = Get-SkyEyeHostFileFacts $idFile
            $secretFacts = Get-SkyEyeHostFileFacts $secretFile
            if (-not $idFacts.Exists -or -not $secretFacts.Exists) {
                Add-SkyEyeCheck $result 'secret_files' 'failed' 'one or both files are missing'
                Stop-SkyEyeRun $result 'refused' 'secrets' 1 ('cf-access-client-id and cf-access-client-secret must exist in ' + $Options.SecretsDir + '. See token placement in the runbook. Nothing was changed.')
            }
            if ($idFacts.Length -ne $script:SkyEyeClientIdBytes -or $secretFacts.Length -le 0) {
                Add-SkyEyeCheck $result 'secret_files' 'failed' 'unexpected size'
                Stop-SkyEyeRun $result 'refused' 'secrets' 1 ('cf-access-client-id must be exactly ' + $script:SkyEyeClientIdBytes + ' bytes (ASCII, no BOM, no newline) and the secret must not be empty. Nothing was changed.')
            }
            Add-SkyEyeCheck $result 'secret_files' 'passed' 'both present; sizes plausible'
            $problems = New-Object System.Collections.ArrayList
            foreach ($target in @($Options.SecretsDir, $idFile, $secretFile)) {
                foreach ($problem in (Get-SkyEyeAclProblems (Get-SkyEyeHostAclReport $target) ([System.IO.Path]::GetFileName($target)))) {
                    [void]$problems.Add($problem)
                }
            }
            if ($problems.Count -gt 0) {
                Add-SkyEyeCheck $result 'secret_acl' 'failed' ($problems.ToArray() -join '; ')
                Stop-SkyEyeRun $result 'refused' 'secrets' 1 'The secret directory or files are open to more than SYSTEM and Administrators. Fix the ACL (see the runbook); this script does not change it. Nothing was changed.'
            }
            Add-SkyEyeCheck $result 'secret_acl' 'passed' 'SYSTEM and Administrators only'
        }

        # 6. What is live now.
        if ([System.IO.File]::Exists($context.RollbackPath)) {
            Add-SkyEyeCheck $result 'unfinished_run' 'failed' $context.RollbackPath
            Stop-SkyEyeRun $result 'refused' 'unfinished_run' 1 ($context.RollbackPath + ' exists: an earlier run did not finish. It holds the config from before that run. See the runbook. Nothing was changed.')
        }
        $liveText = $null
        try {
            $liveText = Read-SkyEyeTextFile $context.ConfigPath
        }
        catch {
            $liveText = $null
        }
        if ($null -eq $liveText) {
            if ($elevated) {
                Add-SkyEyeCheck $result 'live_config' 'failed' 'cannot read the live config'
                Stop-SkyEyeRun $result 'refused' 'live_config' 1 ('Cannot read ' + $context.ConfigPath + '. Nothing was changed.')
            }
            Add-SkyEyeCheck $result 'live_config' 'skipped' 'live config unreadable without admin'
            Add-SkyEyeCheck $result 'label_takeover' 'skipped' 'live config unreadable without admin'
        }
        else {
            $result.config.previous_sha256 = Get-SkyEyeTextSha256 $liveText
            Add-SkyEyeCheck $result 'live_config' 'passed' ''
            $conflict = Get-SkyEyeLabelConflict -ConfigText $liveText -Product $Options.Product -ServerId $Options.ServerId
            if ($conflict) {
                Add-SkyEyeCheck $result 'label_takeover' 'failed' $conflict
                Stop-SkyEyeRun $result 'refused' 'label_takeover' 1 ($conflict + '. Series labels must not change on takeover. Nothing was changed.')
            }
            Add-SkyEyeCheck $result 'label_takeover' 'passed' 'product and server_id match the live config, or it sets none'
        }

        # 7. Render and validate, in a directory of this run.
        $runDir = Join-Path $Options.WorkDir $result.run_id
        [void][System.IO.Directory]::CreateDirectory($runDir)
        $render = @{
            TemplateDir = $Options.TemplateDir; Product = $Options.Product; ServerId = $Options.ServerId
            PromPushUrl = $Options.PromPushUrl; LokiPushUrl = $Options.LokiPushUrl
            SecretsDir = $Options.SecretsDir; RunnerDiagDir = $Options.RunnerDiagDir
        }
        $newText = New-SkyEyeConfigText @render
        $result.config.new_sha256 = Get-SkyEyeTextSha256 $newText
        $rendered = Join-Path $runDir 'config.alloy'
        Write-SkyEyeTextFile $rendered $newText
        $validate = Invoke-SkyEyeHostProcess -FilePath $alloy.Exe -ArgumentList @('validate', $rendered) -TimeoutSeconds 60
        if ($validate.ExitCode -ne 0) {
            Add-SkyEyeCheck $result 'alloy_validate' 'failed' (Get-SkyEyeAlloyOutputSummary $validate.Output)
            Stop-SkyEyeRun $result 'failed_validate' 'validate' 1 'alloy validate rejected the rendered config. Nothing was changed.'
        }
        Add-SkyEyeCheck $result 'alloy_validate' 'passed' ''
        $current = ($null -ne $liveText -and $liveText -ceq $newText)
        $result.config.changed = (-not $current)

        # 8. Smoke run. `alloy validate` passes a config that cannot load, such
        # as a secret used as a header. Only a real run reads the secret files,
        # so only an elevated run can do this.
        if (-not $elevated) {
            Add-SkyEyeCheck $result 'smoke_run' 'skipped' 'needs administrator rights to read the secret files'
        }
        else {
            # Same render, but pushing to a closed local port: nothing reaches
            # central twice. Its own port and storage, so the live service, its
            # 127.0.0.1:12345 and its Event Log bookmarks are not touched.
            $render.PromPushUrl = $script:SkyEyeDiscardProm
            $render.LokiPushUrl = $script:SkyEyeDiscardLoki
            $smokeConfig = Join-Path $runDir 'smoke.alloy'
            Write-SkyEyeTextFile $smokeConfig (New-SkyEyeConfigText @render)
            $smokeData = Join-Path $runDir 'smoke-data'
            $livePort = ($alloy.ListenAddress -split ':')[-1]
            $port = 0
            foreach ($candidate in (($Options.SmokePort)..($Options.SmokePort + 20))) {
                if ([string]$candidate -ne $livePort -and (Test-SkyEyeHostPortFree $candidate)) {
                    $port = $candidate
                    break
                }
            }
            if ($port -eq 0) {
                Add-SkyEyeCheck $result 'smoke_run' 'failed' 'no free local port'
                Stop-SkyEyeRun $result 'failed_smoke' 'smoke' 1 'No free local port for the smoke run. Nothing was changed.'
            }
            $smokeListen = '127.0.0.1:' + $port
            $smoke = Start-SkyEyeHostBackgroundProcess -FilePath $alloy.Exe -ArgumentList @(
                'run', $smokeConfig, ('--storage.path=' + $smokeData),
                ('--server.http.listen-addr=' + $smokeListen), '--disable-reporting')
            $deadline = (Get-SkyEyeHostNow) + $Options.SmokeTimeoutSeconds
            $ready = $false
            while (-not $ready) {
                if (Test-SkyEyeHostBackgroundExited $smoke) {
                    break
                }
                $answer = Get-SkyEyeHostHttp -Url ('http://' + $smokeListen + '/-/ready')
                if ($answer.Status -eq 200) {
                    $ready = $true
                    break
                }
                if ((Get-SkyEyeHostNow) -ge $deadline) {
                    break
                }
                Invoke-SkyEyeHostSleep 1000
            }
            if ($ready) {
                Invoke-SkyEyeHostSleep $Options.SmokeHoldMilliseconds
            }
            $exitedEarly = [bool](Test-SkyEyeHostBackgroundExited $smoke)
            $ended = Stop-SkyEyeHostBackgroundProcess $smoke
            $smoke = $null
            $summary = Get-SkyEyeAlloyOutputSummary $ended.Output
            if (-not $ready -or $exitedEarly -or $ended.Output -match 'failed to evaluate config') {
                Add-SkyEyeCheck $result 'smoke_run' 'failed' $summary
                Stop-SkyEyeRun $result 'failed_smoke' 'smoke' 1 'Alloy could not run the rendered config. Nothing was changed.'
            }
            Add-SkyEyeCheck $result 'smoke_run' 'passed' ('ran on ' + $smokeListen)
        }

        if ($mode -eq 'Check') {
            $result.status = 'checked'
            $result.exit_code = 0
            $skipped = @($result.checks | Where-Object { $_.outcome -eq 'skipped' })
            if ($skipped.Count -gt 0) {
                $result.message = ('Check finished; ' + $skipped.Count + ' checks were skipped for lack of administrator rights. Nothing was changed.')
            }
            else {
                $result.message = 'Check finished; every check ran. Nothing was changed.'
            }
            return $result
        }

        # 9 and 10. Already current: no swap and no restart, but still prove
        # that it delivers.
        if ($current) {
            if (-not $context.WasRunning) {
                Start-SkyEyeHostService
            }
            $gate = Invoke-SkyEyeHealthGate -ListenAddress $context.ListenAddress -Restarted (-not $context.WasRunning) `
                -RequireProm $true -RequireLoki $true `
                -TimeoutSeconds $Options.HealthTimeoutSeconds -PollMilliseconds $Options.PollMilliseconds
            $result.delivery = $gate.Delivery
            if ($gate.Ok) {
                Add-SkyEyeCheck $result 'health_gate' 'passed' ''
                $result.status = 'already_current'
                $result.exit_code = 0
                $result.message = 'The live config already equals the render and is delivering. Nothing was changed.'
            }
            else {
                Add-SkyEyeCheck $result 'health_gate' 'failed' $gate.Reason
                $result.status = 'unhealthy_no_change'
                $result.stop_point = 'health_gate'
                $result.exit_code = 1
                $result.message = ('The live config already equals the render but is not delivering: ' + $gate.Reason)
            }
            return $result
        }

        $staged = $context.ConfigPath + '.staged-' + $PID
        [System.IO.File]::Copy($rendered, $staged, $true)
        if ((Get-SkyEyeSha256 $staged) -cne $result.config.new_sha256) {
            Remove-SkyEyeFileQuietly $staged
            Stop-SkyEyeRun $result 'refused' 'swap' 1 'The staged config does not match the validated render. Nothing was changed.'
        }
        Invoke-SkyEyeSwapAndVerify -Result $result -Context $context -Options $Options -StagedPath $staged -DoneStatus 'installed'
        return $result
    }
    catch {
        if (-not (Test-SkyEyeStop $_)) {
            $result.status = 'internal_error'
            $result.exit_code = 1
            $result.message = ('Unexpected error: ' + $_.Exception.Message)
            Write-SkyEyeLog ('ERROR: ' + $result.message)
        }
        return $result
    }
    finally {
        if ($smoke) {
            [void](Stop-SkyEyeHostBackgroundProcess $smoke)
        }
        Remove-SkyEyeDirectoryQuietly $runDir
        Exit-SkyEyeHostLock $lock
    }
}

# ------------------------------------------------------------------ uninstall

# Options: LockFile, SecretsDir, RemoveSecrets, BundleFiles.
function Invoke-SkyEyeUninstall {
    param([hashtable]$Options)
    Set-SkyEyeOptionDefaults $Options
    $result = New-SkyEyeResult -Kind 'uninstall' -Mode 'Uninstall'
    $lock = $null
    try {
        Add-SkyEyeBundleHashes $result $Options.BundleFiles
        $elevated = [bool](Test-SkyEyeHostElevated)
        $result.elevated = $elevated
        if (-not $elevated) {
            Add-SkyEyeCheck $result 'elevation' 'failed' 'not running as administrator'
            Stop-SkyEyeRun $result 'refused' 'elevation' 1 'uninstall.ps1 must run elevated (Start-Process -Verb RunAs). Nothing was changed.'
        }
        Add-SkyEyeCheck $result 'elevation' 'passed' 'administrator'
        $lock = Enter-SkyEyeHostLock $Options.LockFile
        if (-not $lock) {
            Add-SkyEyeCheck $result 'lock' 'failed' $Options.LockFile
            Stop-SkyEyeRun $result 'refused' 'lock' 1 ('Another SkyEye Alloy run holds ' + $Options.LockFile + '. Nothing was changed.')
        }
        $alloy = Get-SkyEyeAlloyFacts -Result $result -Options $Options -CheckVersion $false

        $changed = $false
        if ($alloy.State -ne 'Stopped') {
            Stop-SkyEyeHostService
            $changed = $true
            Write-SkyEyeLog 'stopped the Alloy service'
        }
        if ($alloy.StartMode -ne 'Disabled') {
            Set-SkyEyeHostServiceStartup 'Disabled'
            $changed = $true
            Write-SkyEyeLog 'disabled the Alloy service'
        }

        $liveText = ''
        if ([System.IO.File]::Exists($alloy.ConfigPath)) {
            $liveText = Read-SkyEyeTextFile $alloy.ConfigPath
        }
        if (-not $liveText.StartsWith($script:SkyEyeStubMarker)) {
            if ($liveText) {
                $kept = $alloy.ConfigPath + '.uninstalled-' + $result.run_id
                [System.IO.File]::Copy($alloy.ConfigPath, $kept, $true)
                $result.config.removed_config_kept_at = $kept
            }
            $stub = $script:SkyEyeStubMarker + ' by agents/alloy/windows/uninstall.ps1, run ' + $result.run_id + ".`n" +
                "// No pipeline: Alloy collects and sends nothing with this file.`n" +
                "logging {`n  level  = `"info`"`n  format = `"logfmt`"`n}`n"
            $temporary = $alloy.ConfigPath + '.staged-' + $PID
            Write-SkyEyeTextFile $temporary $stub
            if ($liveText) {
                [System.IO.File]::Replace($temporary, $alloy.ConfigPath, [NullString]::Value)
            }
            else {
                [System.IO.File]::Move($temporary, $alloy.ConfigPath)
            }
            $changed = $true
            Write-SkyEyeLog 'replaced the config with one that has no pipeline'
        }

        $result.config.secrets = 'left_in_place'
        if ($Options.RemoveSecrets) {
            foreach ($name in @('cf-access-client-id', 'cf-access-client-secret')) {
                $file = Join-Path $Options.SecretsDir $name
                if ([System.IO.File]::Exists($file)) {
                    [System.IO.File]::Delete($file)
                    $changed = $true
                }
            }
            $result.config.secrets = 'removed'
        }
        [void]$result.notes.Add('The SkyEye event source, the Alloy package, its data directory and logs already sent to central are left in place.')

        $result.exit_code = 0
        if ($changed) {
            $result.status = 'uninstalled'
            $result.message = 'Alloy is stopped and disabled, and its config has no pipeline.'
        }
        else {
            $result.status = 'already_uninstalled'
            $result.message = 'Nothing to do: Alloy was already stopped, disabled and without a pipeline.'
        }
        return $result
    }
    catch {
        if (-not (Test-SkyEyeStop $_)) {
            $result.status = 'internal_error'
            $result.exit_code = 1
            $result.message = ('Unexpected error: ' + $_.Exception.Message + '. Check the Alloy service and config by hand.')
            Write-SkyEyeLog ('ERROR: ' + $result.message)
        }
        return $result
    }
    finally {
        Exit-SkyEyeHostLock $lock
    }
}
