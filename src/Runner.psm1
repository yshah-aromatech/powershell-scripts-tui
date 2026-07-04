# Runner.psm1 — non-blocking script execution with live output streaming,
# process-tree resource monitoring, timeouts, per-run log files, run history
# and n8n webhook reporting.
#
# A "run handle" is a mutable hashtable the caller polls with Update-PssRun
# each tick; when the process exits, Complete-PssRun finalizes history +
# webhook. The same machinery (Kind='task') runs system tasks (module
# installs, updates) with streaming but without history/webhook.

$script:ClkTck = 100
try { $script:ClkTck = [int](& getconf CLK_TCK 2>$null) } catch { }
if (-not $script:ClkTck) { $script:ClkTck = 100 }
$script:PageSize = 4096
try { $script:PageSize = [int](& getconf PAGESIZE 2>$null) } catch { }
if (-not $script:PageSize) { $script:PageSize = 4096 }
# resource sampling reads /proc — absent on non-Linux hosts, where runs
# still work but CPU/mem stats stay at 0
$script:HasProc = Test-Path '/proc/self/stat'
# cpu% is reported relative to the WHOLE machine (all cores = 100%), not one
# core — a multi-threaded tree must never read as >100%
$script:CpuCount = [Math]::Max(1, [Environment]::ProcessorCount)

# ---------------------------------------------------------------------------
# Per-script lock — prevents a cron run and a manual run (or two stacked cron
# runs) of the same script from executing concurrently. The lock file holds
# the owning process PID; a lock whose owner is dead is stale and reclaimed.
# ---------------------------------------------------------------------------
function Lock-PssScript {
    # returns @{ Acquired = $true; File = path } or @{ Acquired = $false; Pid = n }
    param([Parameter(Mandatory)][string]$Name)
    $paths = Get-PssPaths
    $file = Join-Path $paths.LocksDir "$Name.lock"
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $fs = [IO.File]::Open($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes("$PID")
                $fs.Write($bytes, 0, $bytes.Length)
            } finally { $fs.Dispose() }
            return @{ Acquired = $true; File = $file }
        } catch [IO.IOException] {
            $ownerPid = $null
            try { $ownerPid = [int](Get-Content $file -Raw -ErrorAction Stop).Trim() } catch { }
            $alive = $ownerPid -and (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)
            if ($alive) { return @{ Acquired = $false; Pid = $ownerPid } }
            # stale lock (owner died without cleanup) — reclaim and retry
            try { Remove-Item $file -Force -ErrorAction Stop } catch { return @{ Acquired = $false; Pid = $ownerPid } }
        }
    }
    @{ Acquired = $false; Pid = $null }
}

function Unlock-PssScript {
    param($Handle)
    if ($Handle.ContainsKey('LockFile') -and $Handle.LockFile) {
        try { Remove-Item $Handle.LockFile -Force -ErrorAction SilentlyContinue } catch { }
        $Handle.LockFile = $null
    }
}

# ---------------------------------------------------------------------------
# Start a script run (Kind='run') — full pipeline
# ---------------------------------------------------------------------------
function Start-PssRun {
    param(
        [Parameter(Mandatory)]$Script,
        [string]$Trigger = 'manual',
        [string[]]$ExtraArgs = @()
    )
    $cfg = Get-PssConfig
    $paths = Get-PssPaths

    $lock = Lock-PssScript -Name $Script.Name
    if (-not $lock.Acquired) {
        $who = if ($lock.Pid) { " (pid $($lock.Pid))" } else { '' }
        return @{
            Kind = 'run'; Name = $Script.Name; Trigger = $Trigger
            Status = 'skipped'; ExitCode = -1; Process = $null
            StartedAt = (Get-Date).ToUniversalTime(); FinishedAt = (Get-Date).ToUniversalTime()
            StartError = "skipped: $($Script.Name) is already running$who"
            LogFile = $null; LogWriter = $null; OutTask = $null; ErrTask = $null
            LastSample = $null; CpuSum = 0.0; CpuMax = 0.0; MemSum = 0.0; MemMax = 0.0
            Samples = 0; Completed = $false
        }
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ss-fffZ')
    $logFile = Join-Path $paths.LogsDir "$($Script.Name)-$stamp.log"

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = [string]$cfg.pwshBin
    [void]$psi.ArgumentList.Add('-NoProfile')
    [void]$psi.ArgumentList.Add('-NonInteractive')
    [void]$psi.ArgumentList.Add('-File')
    [void]$psi.ArgumentList.Add($Script.Entry)
    foreach ($a in @($Script.Args) + @($ExtraArgs)) { if ("$a") { [void]$psi.ArgumentList.Add("$a") } }
    $psi.WorkingDirectory = $Script.Dir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    # per-script .env -> child environment. Every value is registered as a
    # secret (-Force): these are exactly the values the user chose to keep
    # out of git, so none of them belong in logs or webhook payloads.
    foreach ($kv in (Read-PssEnvFile $Script.EnvFile).GetEnumerator()) {
        $psi.Environment[$kv.Key] = $kv.Value
        Register-PssSecret -Name $kv.Key -Value $kv.Value -Force
    }
    # per-script module dir gets first crack at module resolution
    $sep = [IO.Path]::PathSeparator
    $psi.Environment['PSModulePath'] = "$($Script.ModuleDir)$sep$($env:PSModulePath)"

    $handle = New-PssHandle -Psi $psi -Kind 'run' -Name $Script.Name -Trigger $Trigger -LogFile $logFile
    $handle.LockFile = $lock.File
    # per-script timeout wins over the global runTimeoutMinutes
    $handle.TimeoutMinutes = if ($null -ne $Script.PSObject.Properties['TimeoutMinutes'] -and $null -ne $Script.TimeoutMinutes) {
        [double]$Script.TimeoutMinutes
    } else { [double]$cfg.runTimeoutMinutes }
    $handle
}

# ---------------------------------------------------------------------------
# Start a system task (Kind='task') — streamed, no history/webhook
# ---------------------------------------------------------------------------
function Start-PssTask {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$Arguments = @()
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    New-PssHandle -Psi $psi -Kind 'task' -Name $Name -Trigger 'manual' -LogFile $null
}

function New-PssHandle {
    param($Psi, [string]$Kind, [string]$Name, [string]$Trigger, [string]$LogFile)

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $Psi
    $handle = @{
        Kind        = $Kind
        Name        = $Name
        Trigger     = $Trigger
        Process     = $proc
        LogFile     = $LogFile
        LogWriter   = $null
        StartedAt   = (Get-Date).ToUniversalTime()
        FinishedAt  = $null
        Status      = 'running'        # running|success|failure|killed|timeout
        ExitCode    = $null
        OutTask     = $null
        ErrTask     = $null
        # resources
        LastSample  = $null            # @{ Time; Jiffies }
        CpuSum      = 0.0; CpuMax = 0.0
        MemSum      = 0.0; MemMax = 0.0
        Samples     = 0
        Completed   = $false
    }

    try {
        [void]$proc.Start()
    } catch {
        $handle.Status = 'failure'
        $handle.ExitCode = -1
        $handle.FinishedAt = (Get-Date).ToUniversalTime()
        $handle.StartError = $_.Exception.Message
        return $handle
    }
    if ($LogFile) {
        $handle.LogWriter = [IO.StreamWriter]::new($LogFile, $false, [Text.Encoding]::UTF8)
        $handle.LogWriter.AutoFlush = $true
    }
    $handle.OutTask = $proc.StandardOutput.ReadLineAsync()
    $handle.ErrTask = $proc.StandardError.ReadLineAsync()
    $handle
}

# ---------------------------------------------------------------------------
# Poll: drain available output lines (redacted), enforce timeout.
# Returns the new output lines from this tick.
# ---------------------------------------------------------------------------
function Update-PssRun {
    param([Parameter(Mandatory)]$Handle)

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Handle.ContainsKey('StartError') -and $Handle.StartError) {
        if (-not $Handle.StartErrorEmitted) {
            $msg = if ($Handle.Status -eq 'skipped') { $Handle.StartError } else { "failed to start: $($Handle.StartError)" }
            $lines.Add($msg)
            $Handle.StartErrorEmitted = $true
        }
        return $lines
    }
    $proc = $Handle.Process

    foreach ($stream in 'Out', 'Err') {
        $taskKey = "${stream}Task"
        $reader = if ($stream -eq 'Out') { $proc.StandardOutput } else { $proc.StandardError }
        $guard = 0
        while ($Handle[$taskKey] -and $Handle[$taskKey].IsCompleted -and $guard -lt 500) {
            $guard++
            $line = $null
            try { $line = $Handle[$taskKey].GetAwaiter().GetResult() } catch { $line = $null }
            if ($null -eq $line) { $Handle[$taskKey] = $null; break }   # stream closed
            $line = Hide-PssSecret $line
            $lines.Add($line)
            if ($Handle.LogWriter) { $Handle.LogWriter.WriteLine($line) }
            $Handle[$taskKey] = $reader.ReadLineAsync()
        }
    }

    # timeout (per-script override, else global config)
    $cfg = Get-PssConfig
    $timeoutMin = if ($Handle.ContainsKey('TimeoutMinutes')) { [double]$Handle.TimeoutMinutes } else { [double]$cfg.runTimeoutMinutes }
    if ($Handle.Kind -eq 'run' -and $timeoutMin -gt 0 -and $Handle.Status -eq 'running' -and -not $proc.HasExited) {
        $elapsed = ((Get-Date).ToUniversalTime() - $Handle.StartedAt).TotalMinutes
        if ($elapsed -ge $timeoutMin) {
            $lines.Add("run exceeded ${timeoutMin}min timeout — killing")
            Stop-PssRun -Handle $Handle -Reason 'timeout'
        }
    }

    $lines
}

function Test-PssRunFinished {
    param([Parameter(Mandatory)]$Handle)
    if ($Handle.ContainsKey('StartError') -and $Handle.StartError) { return $true }
    $Handle.Process.HasExited -and ($null -eq $Handle.OutTask) -and ($null -eq $Handle.ErrTask)
}

# ---------------------------------------------------------------------------
# Resource sampling — whole process tree via /proc (CPU% and RSS MB)
# ---------------------------------------------------------------------------
function Get-PssTreePids {
    param([int]$RootPid)
    $children = @{}
    foreach ($dir in [IO.Directory]::EnumerateDirectories('/proc')) {
        $pidStr = [IO.Path]::GetFileName($dir)
        if ($pidStr -notmatch '^\d+$') { continue }
        try {
            $stat = [IO.File]::ReadAllText("$dir/stat")
            $after = $stat.Substring($stat.LastIndexOf(')') + 2)
            $ppid = [int]($after -split ' ')[1]
            if (-not $children.ContainsKey($ppid)) { $children[$ppid] = [System.Collections.Generic.List[int]]::new() }
            $children[$ppid].Add([int]$pidStr)
        } catch { }
    }
    $result = [System.Collections.Generic.List[int]]::new()
    $stack = [System.Collections.Generic.Stack[int]]::new()
    $stack.Push($RootPid)
    while ($stack.Count -gt 0) {
        $p = $stack.Pop()
        $result.Add($p)
        if ($children.ContainsKey($p)) { foreach ($c in $children[$p]) { $stack.Push($c) } }
    }
    $result
}

function Measure-PssResources {
    param([Parameter(Mandatory)]$Handle)
    if (-not $script:HasProc) { return }
    if ($Handle.ContainsKey('StartError') -and $Handle.StartError) { return }
    $proc = $Handle.Process
    if ($proc.HasExited) { return }

    $now = Get-Date
    $jiffies = [long]0
    $rssBytes = [long]0
    foreach ($p in (Get-PssTreePids -RootPid $proc.Id)) {
        try {
            $stat = [IO.File]::ReadAllText("/proc/$p/stat")
            $after = ($stat.Substring($stat.LastIndexOf(')') + 2)) -split ' '
            $jiffies += [long]$after[11] + [long]$after[12]     # utime + stime
            $rssBytes += [long]$after[21] * $script:PageSize    # rss pages
        } catch { }
    }

    $memMb = $rssBytes / 1MB
    if ($Handle.LastSample) {
        $dt = ($now - $Handle.LastSample.Time).TotalSeconds
        if ($dt -gt 0.2) {
            $cpu = (($jiffies - $Handle.LastSample.Jiffies) / $script:ClkTck) / $dt * 100.0 / $script:CpuCount
            if ($cpu -lt 0) { $cpu = 0 }
            if ($cpu -gt 100) { $cpu = 100 }   # jiffy-granularity rounding can overshoot
            $Handle.CpuSum += $cpu; $Handle.MemSum += $memMb
            if ($cpu -gt $Handle.CpuMax) { $Handle.CpuMax = $cpu }
            if ($memMb -gt $Handle.MemMax) { $Handle.MemMax = $memMb }
            $Handle.Samples++
            $Handle.CpuNow = $cpu; $Handle.MemNow = $memMb
            # full series kept for sparklines (downsampled into history on completion)
            if (-not $Handle.ContainsKey('CpuSeries')) {
                $Handle.CpuSeries = [System.Collections.Generic.List[double]]::new()
                $Handle.MemSeries = [System.Collections.Generic.List[double]]::new()
            }
            $Handle.CpuSeries.Add($cpu)
            $Handle.MemSeries.Add($memMb)
            $Handle.LastSample = @{ Time = $now; Jiffies = $jiffies }
        }
    } else {
        $Handle.LastSample = @{ Time = $now; Jiffies = $jiffies }
    }
}

# ---------------------------------------------------------------------------
# Kill the whole process tree (SIGTERM, then SIGKILL after a grace period)
# ---------------------------------------------------------------------------
function Stop-PssRun {
    param([Parameter(Mandatory)]$Handle, [string]$Reason = 'killed')
    $proc = $Handle.Process
    if (-not $proc -or $proc.HasExited) { return }
    $Handle.Status = $Reason
    if (-not $script:HasProc) {
        # no /proc to walk the tree — .NET can kill the whole tree itself
        try { $proc.Kill($true); $proc.WaitForExit(3000) | Out-Null } catch { }
        return
    }
    $pids = Get-PssTreePids -RootPid $proc.Id
    foreach ($p in $pids) { & /bin/kill -TERM $p 2>$null }
    $deadline = (Get-Date).AddSeconds(3)
    while (-not $proc.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not $proc.HasExited) {
        foreach ($p in (Get-PssTreePids -RootPid $proc.Id)) { & /bin/kill -KILL $p 2>$null }
        try { $proc.WaitForExit(2000) | Out-Null } catch { }
    }
}

# ---------------------------------------------------------------------------
# Finalize: status, history line, webhook. Returns the result object.
# ---------------------------------------------------------------------------
function Complete-PssRun {
    param([Parameter(Mandatory)]$Handle)
    if ($Handle.Completed) { return $Handle.Result }
    $Handle.Completed = $true
    $cfg = Get-PssConfig
    $paths = Get-PssPaths

    $Handle.FinishedAt = (Get-Date).ToUniversalTime()
    if ($Handle.ContainsKey('StartError') -and $Handle.StartError) {
        $Handle.ExitCode = -1
    } else {
        try { $Handle.ExitCode = $Handle.Process.ExitCode } catch { $Handle.ExitCode = -1 }
    }
    if ($Handle.Status -eq 'running') {
        $Handle.Status = if ($Handle.ExitCode -eq 0) { 'success' } else { 'failure' }
    }
    if ($Handle.LogWriter) { try { $Handle.LogWriter.Dispose() } catch { } ; $Handle.LogWriter = $null }
    Unlock-PssScript -Handle $Handle

    $duration = [Math]::Round(($Handle.FinishedAt - $Handle.StartedAt).TotalSeconds, 1)
    $n = [Math]::Max(1, $Handle.Samples)
    $resources = [ordered]@{
        cpuAvgPercent = [Math]::Round($Handle.CpuSum / $n, 1)
        cpuMaxPercent = [Math]::Round($Handle.CpuMax, 1)
        memAvgMb      = [Math]::Round($Handle.MemSum / $n, 1)
        memMaxMb      = [Math]::Round($Handle.MemMax, 1)
        samples       = $Handle.Samples
    }
    # downsampled per-run series — small enough for history, enough for a sparkline
    if ($Handle.ContainsKey('CpuSeries') -and $Handle.CpuSeries.Count -gt 0) {
        $resources.cpuSeries = Get-PssDownsampledSeries -Series $Handle.CpuSeries
        $resources.memSeries = Get-PssDownsampledSeries -Series $Handle.MemSeries
    }

    $result = [ordered]@{
        event       = 'script_run'
        script      = $Handle.Name
        trigger     = $Handle.Trigger
        status      = $Handle.Status
        success     = ($Handle.Status -eq 'success')
        exitCode    = $Handle.ExitCode
        startedAt   = $Handle.StartedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        finishedAt  = $Handle.FinishedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        durationSec = $duration
        host        = [Environment]::MachineName
        resources   = $resources
        logFile     = $Handle.LogFile
    }
    $Handle.Result = $result
    if ($Handle.Kind -ne 'run') { return $result }

    # history (without the log payload)
    try {
        ($result | ConvertTo-Json -Depth 6 -Compress) |
            Add-Content -Path $paths.HistoryFile -Encoding UTF8
    } catch { }

    # webhook gets a log tail
    $payload = [ordered]@{}
    foreach ($k in $result.Keys) { $payload[$k] = $result[$k] }
    $payload['log'] = Get-PssLogTail -LogFile $Handle.LogFile -TailKb ([int]$cfg.logTailKb)
    [void](Send-PssWebhook -Payload $payload)
    $result
}

# Max-of-bucket downsampling — peaks survive, which is what you look for
function Get-PssDownsampledSeries {
    param([Parameter(Mandatory)]$Series, [int]$MaxPoints = 60)
    $n = $Series.Count
    if ($n -le $MaxPoints) { return @($Series | ForEach-Object { [Math]::Round($_, 1) }) }
    $out = [System.Collections.Generic.List[double]]::new()
    for ($b = 0; $b -lt $MaxPoints; $b++) {
        $lo = [int][Math]::Floor($b * $n / $MaxPoints)
        $hi = [int][Math]::Max($lo, [Math]::Floor(($b + 1) * $n / $MaxPoints) - 1)
        $max = $Series[$lo]
        for ($i = $lo + 1; $i -le $hi; $i++) { if ($Series[$i] -gt $max) { $max = $Series[$i] } }
        $out.Add([Math]::Round($max, 1))
    }
    @($out)
}

function Get-PssLogTail {
    param([string]$LogFile, [int]$TailKb = 64)
    if (-not $LogFile -or -not (Test-Path $LogFile)) { return '' }
    try {
        $fs = [IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
        try {
            $max = $TailKb * 1KB
            if ($fs.Length -gt $max) { $fs.Seek(-$max, 'End') | Out-Null }
            $sr = [IO.StreamReader]::new($fs)
            return $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return '' }
}

# ---------------------------------------------------------------------------
# n8n webhook — with retry and a dead-letter queue. A run report that can't
# be delivered (n8n down, network blip) is appended to webhook-queue.jsonl
# and re-sent after the next successful delivery, so cron-run reports aren't
# silently lost.
# ---------------------------------------------------------------------------
function Send-PssWebhookRaw {
    param([Parameter(Mandatory)][string]$Body)
    $cfg = Get-PssConfig
    $url = if ($env:N8N_WEBHOOK_URL) { $env:N8N_WEBHOOK_URL } else { [string]$cfg.n8nWebhookUrl }
    if (-not $url) { return $false }
    try {
        Invoke-RestMethod -Method Post -Uri $url -Body $Body -ContentType 'application/json' `
            -TimeoutSec ([int]$cfg.webhookTimeoutSec) | Out-Null
        $true
    } catch {
        $false
    }
}

function Send-PssWebhook {
    param([Parameter(Mandatory)]$Payload, [switch]$NoQueue)
    $cfg = Get-PssConfig
    $url = if ($env:N8N_WEBHOOK_URL) { $env:N8N_WEBHOOK_URL } else { [string]$cfg.n8nWebhookUrl }
    if (-not $url) { return $false }

    $body = $Payload | ConvertTo-Json -Depth 6
    $ok = Send-PssWebhookRaw -Body $body
    if (-not $ok) {
        Start-Sleep -Seconds 2
        $ok = Send-PssWebhookRaw -Body $body
    }
    if ($ok) {
        Send-PssWebhookQueue
        return $true
    }
    # test events are interactive — the user sees the failure; don't queue them
    if (-not $NoQueue -and "$($Payload['event'])" -ne 'test') {
        try {
            ($Payload | ConvertTo-Json -Depth 6 -Compress) |
                Add-Content -Path (Get-PssPaths).WebhookQueueFile -Encoding UTF8
        } catch { }
    }
    $false
}

# Flush the dead-letter queue: resend in order, stop at the first failure,
# keep whatever couldn't be sent.
function Send-PssWebhookQueue {
    $paths = Get-PssPaths
    $qf = $paths.WebhookQueueFile
    if (-not (Test-Path $qf)) { return 0 }
    $lines = @(Get-Content $qf -ErrorAction SilentlyContinue | Where-Object { $_ })
    if ($lines.Count -eq 0) {
        Remove-Item $qf -Force -ErrorAction SilentlyContinue
        return 0
    }
    $sent = 0
    foreach ($line in $lines) {
        if (Send-PssWebhookRaw -Body $line) { $sent++ } else { break }
    }
    $remaining = $lines | Select-Object -Skip $sent
    if ($remaining) { $remaining | Set-Content -Path $qf -Encoding UTF8 }
    else { Remove-Item $qf -Force -ErrorAction SilentlyContinue }
    $sent
}

function Send-PssWebhookTest {
    $payload = [ordered]@{
        event = 'test'
        host  = [Environment]::MachineName
        at    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    }
    Send-PssWebhook -Payload $payload
}

# ---------------------------------------------------------------------------
# Run history
# ---------------------------------------------------------------------------
function Get-PssHistory {
    param([int]$Last = 100)
    $paths = Get-PssPaths
    if (-not (Test-Path $paths.HistoryFile)) { return @() }
    $lines = Get-Content $paths.HistoryFile -Tail $Last -ErrorAction SilentlyContinue
    $items = foreach ($l in $lines) {
        try { $l | ConvertFrom-Json } catch { }
    }
    @($items)
}

function Get-PssLastStatuses {
    # script name -> @{ Status; At (finish [datetime], local); DurationSec;
    # Resources (cpu/mem stats of that run) } of the most recent run
    $map = @{}
    foreach ($h in (Get-PssHistory -Last 500)) {
        if (-not $h -or -not $h.script) { continue }
        $at = $null
        try { $at = ([datetime]::Parse("$($h.finishedAt)", $null, [Globalization.DateTimeStyles]::AdjustToUniversal)).ToLocalTime() } catch { }
        $map[$h.script] = [pscustomobject]@{
            Status      = "$($h.status)"
            At          = $at
            DurationSec = [double]$h.durationSec
            Resources   = $h.resources
        }
    }
    $map
}

Export-ModuleMember -Function Start-PssRun, Start-PssTask, Update-PssRun, Test-PssRunFinished,
Measure-PssResources, Stop-PssRun, Complete-PssRun, Send-PssWebhook, Send-PssWebhookTest,
Send-PssWebhookQueue, Get-PssHistory, Get-PssLastStatuses, Get-PssLogTail,
Lock-PssScript, Unlock-PssScript, Get-PssDownsampledSeries
