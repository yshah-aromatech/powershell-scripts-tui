# Mcp.psm1 — built-in MCP server so an AI agent (e.g. n8n's MCP Client Tool)
# can list and run scripts over the LAN.
#
# Speaks the MCP streamable-HTTP transport in its simplest legal form:
# stateless (no Mcp-Session-Id), no SSE stream, plain application/json
# response per POST, one JSON-RPC message per request. Auth is a shared
# Bearer token (MCP_AUTH_TOKEN); the server refuses to start without one.
#
# Layering: Invoke-PssMcpRequest / Invoke-PssMcpTool are pure functions
# (no sockets) so Pester covers the whole protocol; Start-PssMcpServer is a
# thin synchronous HttpListener loop around them. Tool calls execute inline —
# one at a time by design; the per-script lock still guards against stacking
# with TUI/cron runs of the same script.

$script:McpProtocolVersions = @('2025-06-18', '2025-03-26', '2024-11-05')
$script:McpDefaultProtocol = '2025-03-26'
$script:McpMaxBodyBytes = 1MB

# ---------------------------------------------------------------------------
# Tool registry
# ---------------------------------------------------------------------------
function Get-PssMcpTools {
    $readOnly = [ordered]@{ readOnlyHint = $true; idempotentHint = $true }
    $scriptArg = [ordered]@{ type = 'string'; description = 'Script name exactly as returned by list_scripts' }
    @(
        [ordered]@{
            name        = 'list_scripts'
            description = 'List every script this server can run, with runtime (powershell/python), repo, description, last run status/duration, whether it is currently running, and its cron schedule. Call get_script_details before running an unfamiliar script.'
            inputSchema = [ordered]@{ type = 'object'; properties = [ordered]@{} }
            annotations = $readOnly
        },
        [ordered]@{
            name        = 'get_script_details'
            description = "Everything needed to call a script correctly: its README, documented environment variables (.env.example), default args, and — for PowerShell — the full parameter list (names, types, mandatory, defaults, allowed values, per-parameter help) parsed from the script's param() block. Call this before run_script when unsure about arguments."
            inputSchema = [ordered]@{
                type       = 'object'
                required   = @('script')
                properties = [ordered]@{ script = $scriptArg }
            }
            annotations = $readOnly
        },
        [ordered]@{
            name        = 'run_script'
            description = 'Run a script to completion and return its status, exit code and output. Blocks until the script finishes — these scripts normally run in under a couple of minutes. A script that is already running elsewhere returns status "skipped". Use get_script_details first to learn the accepted arguments.'
            inputSchema = [ordered]@{
                type       = 'object'
                required   = @('script')
                properties = [ordered]@{
                    script          = $scriptArg
                    args            = [ordered]@{ type = 'string'; description = "Extra command-line arguments, quote-aware. PowerShell scripts: -ParamName value / bare -Switch (e.g. -DryRun -Role read); python: --flag value" }
                    env             = [ordered]@{ type = 'object'; additionalProperties = [ordered]@{ type = 'string' }; description = "Extra environment variables for this run only; override the script's .env values" }
                    timeout_minutes = [ordered]@{ type = 'number'; description = 'Override the run timeout for this run (minutes)' }
                }
            }
        },
        [ordered]@{
            name        = 'get_history'
            description = 'Recent run history (newest first), optionally filtered to one script. Each row has a logId usable with get_run_log.'
            inputSchema = [ordered]@{
                type       = 'object'
                properties = [ordered]@{
                    script = [ordered]@{ type = 'string'; description = 'Only runs of this script' }
                    limit  = [ordered]@{ type = 'number'; description = 'Max entries to return (default 20, max 200)' }
                }
            }
            annotations = $readOnly
        },
        [ordered]@{
            name        = 'get_run_log'
            description = "Fetch the (secret-redacted) log of a past run by its logId from get_history — use it to diagnose failures beyond the short output tail."
            inputSchema = [ordered]@{
                type       = 'object'
                required   = @('log_id')
                properties = [ordered]@{
                    log_id  = [ordered]@{ type = 'string'; description = 'logId value from a get_history row' }
                    tail_kb = [ordered]@{ type = 'number'; description = 'How much of the end of the log to return in KB (default 64, max 256)' }
                }
            }
            annotations = $readOnly
        },
        [ordered]@{
            name        = 'sync_repos'
            description = 'Sync (git pull/hard-reset) all configured scripts repos so the latest scripts are available. Run this before list_scripts if the repos may have changed.'
            inputSchema = [ordered]@{ type = 'object'; properties = [ordered]@{} }
            annotations = [ordered]@{ idempotentHint = $true }
        },
        [ordered]@{
            name        = 'get_schedules'
            description = 'All cron schedules currently configured, with each next fire time.'
            inputSchema = [ordered]@{ type = 'object'; properties = [ordered]@{} }
            annotations = $readOnly
        },
        [ordered]@{
            name        = 'set_schedule'
            description = "Create or replace a script's cron schedule. Accepts a 5-field cron expression (e.g. */30 * * * *) or @hourly/@daily/@weekly/@monthly/@reboot. The schedule is written to the server's crontab and runs through the full pipeline (deps, logs, webhook)."
            inputSchema = [ordered]@{
                type       = 'object'
                required   = @('script', 'cron')
                properties = [ordered]@{
                    script = $scriptArg
                    cron   = [ordered]@{ type = 'string'; description = '5-field cron expression or @hourly/@daily/@weekly/@monthly/@reboot' }
                }
            }
        },
        [ordered]@{
            name        = 'remove_schedule'
            description = "Remove a script's cron schedule."
            inputSchema = [ordered]@{
                type       = 'object'
                required   = @('script')
                properties = [ordered]@{ script = $scriptArg }
            }
        },
        [ordered]@{
            name        = 'install_deps'
            description = "Scan a script's dependencies (PowerShell modules or python packages) and install whatever is missing into its isolated module dir / venv. Safe to call repeatedly."
            inputSchema = [ordered]@{
                type       = 'object'
                required   = @('script')
                properties = [ordered]@{ script = $scriptArg }
            }
            annotations = [ordered]@{ idempotentHint = $true }
        },
        [ordered]@{
            name        = 'update_app'
            description = 'Update this app itself (git pull --ff-only). The MCP service must be restarted afterwards to apply.'
            inputSchema = [ordered]@{ type = 'object'; properties = [ordered]@{} }
            annotations = [ordered]@{ idempotentHint = $true }
        },
        [ordered]@{
            name        = 'update_packages'
            description = 'Upgrade every PowerShell module dir and python venv to latest package versions (plus apt packages when passwordless sudo is available). Can take several minutes — raise the tool timeout before calling.'
            inputSchema = [ordered]@{ type = 'object'; properties = [ordered]@{} }
            annotations = [ordered]@{ idempotentHint = $true }
        }
    )
}

# ---------------------------------------------------------------------------
# Tool implementations. Return @{ Text = <json string>; IsError = <bool> }.
# IsError marks tool-level failures (unknown script, bad arguments); a script
# that ran and failed is a NORMAL result with status='failure' — the agent
# reads the field.
# ---------------------------------------------------------------------------
function Invoke-PssMcpTool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Arguments = @{}
    )
    if ($null -eq $Arguments) { $Arguments = @{} }
    switch ($Name) {
        'list_scripts' { return Invoke-PssMcpListScripts }
        'get_script_details' { return Invoke-PssMcpScriptDetails -Arguments $Arguments }
        'run_script' { return Invoke-PssMcpRunScript -Arguments $Arguments }
        'get_history' { return Invoke-PssMcpGetHistory -Arguments $Arguments }
        'get_run_log' { return Invoke-PssMcpGetRunLog -Arguments $Arguments }
        'sync_repos' { return Invoke-PssMcpSyncRepos }
        'get_schedules' { return Invoke-PssMcpGetSchedules }
        'set_schedule' { return Invoke-PssMcpSetSchedule -Arguments $Arguments }
        'remove_schedule' { return Invoke-PssMcpRemoveSchedule -Arguments $Arguments }
        'install_deps' { return Invoke-PssMcpInstallDeps -Arguments $Arguments }
        'update_app' { return Invoke-PssMcpUpdateApp }
        'update_packages' { return Invoke-PssMcpUpdatePackages }
        default {
            $valid = (Get-PssMcpTools | ForEach-Object name) -join ', '
            return @{ Text = "unknown tool '$Name' — valid tools: $valid"; IsError = $true }
        }
    }
}

# shared script-by-name lookup: @{ Script } or @{ Error } with valid names
function Resolve-PssMcpScript {
    param([hashtable]$Arguments)
    $name = "$($Arguments['script'])"
    if (-not $name) { return @{ Error = "missing required argument 'script'" } }
    $target = Get-PssScripts | Where-Object Name -eq $name | Select-Object -First 1
    if (-not $target) {
        $valid = (@(Get-PssScripts) | ForEach-Object Name) -join ', '
        return @{ Error = "unknown script '$name' — valid scripts: $valid" }
    }
    @{ Script = $target }
}

function Invoke-PssMcpListScripts {
    $statuses = Get-PssLastStatuses
    $schedules = @{}
    try { $schedules = Get-PssSchedules } catch { }
    $items = foreach ($s in @(Get-PssScripts)) {
        $st = $statuses[$s.Name]
        [ordered]@{
            name            = $s.Name
            runtime         = "$($s.Runtime)"
            repo            = "$($s.Repo)"
            description     = "$($s.Description)"
            entry           = [IO.Path]::GetFileName("$($s.Entry)")
            running         = (Test-PssScriptLocked -Name $s.Name)
            lastStatus      = if ($st) { $st.Status } else { 'never run' }
            lastRunAt       = if ($st -and $st.At) { $st.At.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
            lastDurationSec = if ($st) { $st.DurationSec } else { $null }
            schedule        = if ($schedules.ContainsKey($s.Name)) { $schedules[$s.Name] } else { $null }
            timeoutMinutes  = $s.TimeoutMinutes
        }
    }
    @{ Text = ([ordered]@{ scripts = @($items) } | ConvertTo-Json -Depth 6 -Compress); IsError = $false }
}

function Invoke-PssMcpScriptDetails {
    param([hashtable]$Arguments)
    $r = Resolve-PssMcpScript -Arguments $Arguments
    if ($r.Error) { return @{ Text = $r.Error; IsError = $true } }
    $detail = Get-PssScriptDetail -Script $r.Script
    @{ Text = ($detail | ConvertTo-Json -Depth 8 -Compress); IsError = $false }
}

function Invoke-PssMcpRunScript {
    param([hashtable]$Arguments)

    $r = Resolve-PssMcpScript -Arguments $Arguments
    if ($r.Error) { return @{ Text = $r.Error; IsError = $true } }
    $target = $r.Script

    $extraArgs = @(Split-PssArguments "$($Arguments['args'])")
    $extraEnv = @{}
    if ($Arguments['env'] -is [System.Collections.IDictionary]) {
        foreach ($k in $Arguments['env'].Keys) { $extraEnv["$k"] = "$($Arguments['env'][$k])" }
    }
    $timeoutOverride = 0.0
    if ($null -ne ($Arguments['timeout_minutes'] -as [double])) { $timeoutOverride = [double]$Arguments['timeout_minutes'] }

    # same auto-install-without-prompt behavior as `psscripts --run`
    $installed = @()
    $missing = @(Get-PssMissingDeps -Script $target)
    if ($missing.Count -gt 0) {
        $cfg = Get-PssConfig
        $cmd = Get-PssInstallCommand -Script $target -Modules $missing
        & ([string]$cfg.pwshBin) -NoProfile -NonInteractive -Command $cmd | Out-Null
        $installed = @($missing | ForEach-Object Display)
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $handle = Start-PssRun -Script $target -Trigger 'mcp' -ExtraArgs $extraArgs `
        -ExtraEnv $extraEnv -TimeoutOverride $timeoutOverride
    $result = Invoke-PssRunToCompletion -Handle $handle -OnLine { param($l) $lines.Add($l) }.GetNewClosure()

    # prefer the log tail (bounded, already redacted); skipped runs have no log
    $cfg = Get-PssConfig
    $output = if ($result.logFile) { Get-PssLogTail -LogFile $result.logFile -TailKb ([int]$cfg.logTailKb) }
    else { ($lines -join "`n") }

    $out = [ordered]@{
        script      = $result.script
        status      = $result.status
        exitCode    = $result.exitCode
        durationSec = $result.durationSec
        startedAt   = $result.startedAt
        finishedAt  = $result.finishedAt
        logFile     = $result.logFile
        output      = $output
        resources   = [ordered]@{
            cpuAvgPercent = $result.resources.cpuAvgPercent
            cpuMaxPercent = $result.resources.cpuMaxPercent
            memAvgMb      = $result.resources.memAvgMb
            memMaxMb      = $result.resources.memMaxMb
        }
    }
    if ($result.status -eq 'skipped') { $out.note = 'already running (locked); try again later' }
    if ($installed.Count -gt 0) { $out.installedModules = $installed }
    @{ Text = ($out | ConvertTo-Json -Depth 6 -Compress); IsError = $false }
}

function Invoke-PssMcpGetHistory {
    param([hashtable]$Arguments)
    $limit = 20
    if ($null -ne ($Arguments['limit'] -as [int])) { $limit = [Math]::Min(200, [Math]::Max(1, [int]$Arguments['limit'])) }
    $name = "$($Arguments['script'])"

    $items = @(Get-PssHistory -Last 500)
    if ($name) { $items = @($items | Where-Object { "$($_.script)" -eq $name }) }
    $items = @($items | Select-Object -Last $limit)
    [array]::Reverse($items)   # newest first
    $runs = foreach ($h in $items) {
        [ordered]@{
            script      = "$($h.script)"
            trigger     = "$($h.trigger)"
            status      = "$($h.status)"
            exitCode    = $h.exitCode
            startedAt   = "$($h.startedAt)"
            durationSec = $h.durationSec
            logFile     = "$($h.logFile)"
            logId       = $(if ("$($h.logFile)") { [IO.Path]::GetFileName("$($h.logFile)") } else { $null })
        }
    }
    @{ Text = ([ordered]@{ runs = @($runs) } | ConvertTo-Json -Depth 4 -Compress); IsError = $false }
}

function Invoke-PssMcpGetRunLog {
    param([hashtable]$Arguments)
    $logId = "$($Arguments['log_id'])"
    # strict allow-list: a log basename only — no separators, no traversal
    if ($logId -notmatch '^[A-Za-z0-9._-]+\.log$' -or $logId.Contains('..')) {
        return @{ Text = "invalid log_id '$logId' — use the logId field from get_history"; IsError = $true }
    }
    $path = Join-Path (Get-PssPaths).LogsDir $logId
    if (-not (Test-Path $path)) {
        return @{ Text = "log '$logId' not found (rotated out after logRetentionDays?)"; IsError = $true }
    }
    $tailKb = 64
    if ($null -ne ($Arguments['tail_kb'] -as [int])) { $tailKb = [Math]::Min(256, [Math]::Max(1, [int]$Arguments['tail_kb'])) }
    $out = [ordered]@{
        logId = $logId
        log   = (Get-PssLogTail -LogFile $path -TailKb $tailKb)
    }
    @{ Text = ($out | ConvertTo-Json -Depth 3 -Compress); IsError = $false }
}

function Invoke-PssMcpSyncRepos {
    $lines = [System.Collections.Generic.List[string]]::new()
    $ok = Sync-PssRepo -OnOutput { param($l) $lines.Add($l) }.GetNewClosure()
    $out = [ordered]@{ ok = [bool]$ok; output = ($lines -join "`n") }
    @{ Text = ($out | ConvertTo-Json -Depth 3 -Compress); IsError = (-not $ok) }
}

function Invoke-PssMcpGetSchedules {
    $schedules = Get-PssSchedules
    $items = foreach ($k in ($schedules.Keys | Sort-Object)) {
        $next = $null
        try {
            $n = Get-PssCronNext -Expression $schedules[$k] -From (Get-Date)
            if ($n) { $next = $n.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        } catch { }
        [ordered]@{ script = $k; cron = $schedules[$k]; nextRun = $next }
    }
    @{ Text = ([ordered]@{ schedules = @($items) } | ConvertTo-Json -Depth 3 -Compress); IsError = $false }
}

function Invoke-PssMcpSetSchedule {
    param([hashtable]$Arguments)
    $r = Resolve-PssMcpScript -Arguments $Arguments
    if ($r.Error) { return @{ Text = $r.Error; IsError = $true } }
    $cron = "$($Arguments['cron'])".Trim()
    if (-not (Test-PssCronExpression $cron)) {
        return @{ Text = "invalid cron expression '$cron' — use 5 fields (min hour dom mon dow, e.g. */30 * * * *) or @hourly/@daily/@weekly/@monthly/@reboot"; IsError = $true }
    }
    Set-PssSchedule -Name $r.Script.Name -Expression $cron
    $next = $null
    try {
        $n = Get-PssCronNext -Expression $cron -From (Get-Date)
        if ($n) { $next = $n.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    } catch { }
    $out = [ordered]@{ script = $r.Script.Name; cron = $cron; nextRun = $next; note = 'schedule saved to crontab' }
    @{ Text = ($out | ConvertTo-Json -Depth 3 -Compress); IsError = $false }
}

function Invoke-PssMcpRemoveSchedule {
    param([hashtable]$Arguments)
    $r = Resolve-PssMcpScript -Arguments $Arguments
    if ($r.Error) { return @{ Text = $r.Error; IsError = $true } }
    $had = (Get-PssSchedules).ContainsKey($r.Script.Name)
    Remove-PssSchedule -Name $r.Script.Name
    $out = [ordered]@{
        script = $r.Script.Name
        note   = $(if ($had) { 'schedule removed' } else { 'no schedule was set' })
    }
    @{ Text = ($out | ConvertTo-Json -Depth 3 -Compress); IsError = $false }
}

function Invoke-PssMcpInstallDeps {
    param([hashtable]$Arguments)
    $r = Resolve-PssMcpScript -Arguments $Arguments
    if ($r.Error) { return @{ Text = $r.Error; IsError = $true } }
    $missing = @(Get-PssMissingDeps -Script $r.Script)
    if ($missing.Count -eq 0) {
        return @{ Text = ([ordered]@{ script = $r.Script.Name; upToDate = $true } | ConvertTo-Json -Compress); IsError = $false }
    }
    $cfg = Get-PssConfig
    $cmd = Get-PssInstallCommand -Script $r.Script -Modules $missing
    $output = & ([string]$cfg.pwshBin) -NoProfile -NonInteractive -Command $cmd 2>&1 | ForEach-Object { Hide-PssSecret "$_" }
    $failed = ($LASTEXITCODE -ne 0)
    $out = [ordered]@{
        script    = $r.Script.Name
        installed = @($missing | ForEach-Object Display)
        ok        = (-not $failed)
        output    = (@($output) -join "`n")
    }
    @{ Text = ($out | ConvertTo-Json -Depth 3 -Compress); IsError = $failed }
}

function Invoke-PssMcpUpdateApp {
    $app = Get-PssAppDir
    $output = & git -C $app pull --ff-only 2>&1 | ForEach-Object { Hide-PssSecret "$_" }
    $ok = ($LASTEXITCODE -eq 0)
    $out = [ordered]@{
        ok     = $ok
        output = (@($output) -join "`n")
        note   = 'restart the MCP service to apply: systemctl restart psscripts-mcp'
    }
    @{ Text = ($out | ConvertTo-Json -Depth 3 -Compress); IsError = (-not $ok) }
}

function Invoke-PssMcpUpdatePackages {
    $cfg = Get-PssConfig
    $lines = [System.Collections.Generic.List[string]]::new()

    & sudo -n true 2>$null
    if ($LASTEXITCODE -eq 0) {
        $lines.Add('== apt upgrade (powershell + python) ==')
        & bash -c 'sudo -n apt-get update -q && sudo -n apt-get install -y --only-upgrade powershell python3 python3-pip python3-venv' 2>&1 |
            ForEach-Object { $lines.Add("$_") }
    } else {
        $lines.Add('apt stage skipped: passwordless sudo unavailable — run manually: sudo apt-get update && sudo apt-get install -y --only-upgrade powershell python3 python3-pip python3-venv')
    }

    $lines.Add('== module dirs ==')
    & ([string]$cfg.pwshBin) -NoProfile -NonInteractive -Command (Get-PssModuleUpgradeCommand) 2>&1 |
        ForEach-Object { $lines.Add((Hide-PssSecret "$_")) }
    $lines.Add('== python venvs ==')
    & ([string]$cfg.pwshBin) -NoProfile -NonInteractive -Command (Get-PssVenvUpgradeCommand) 2>&1 |
        ForEach-Object { $lines.Add((Hide-PssSecret "$_")) }

    $out = [ordered]@{ ok = $true; output = ($lines -join "`n") }
    @{ Text = ($out | ConvertTo-Json -Depth 3 -Compress); IsError = $false }
}

# ---------------------------------------------------------------------------
# JSON-RPC dispatch — pure: string in, @{ StatusCode; Json } out.
# ---------------------------------------------------------------------------
function New-PssMcpError {
    param($Id, [int]$Code, [string]$Message)
    @{
        StatusCode = 200
        Json       = ([ordered]@{ jsonrpc = '2.0'; id = $Id; error = [ordered]@{ code = $Code; message = $Message } } |
                ConvertTo-Json -Depth 6 -Compress)
    }
}

function New-PssMcpResult {
    param($Id, $Result)
    @{
        StatusCode = 200
        Json       = ([ordered]@{ jsonrpc = '2.0'; id = $Id; result = $Result } |
                ConvertTo-Json -Depth 20 -Compress)
    }
}

function Invoke-PssMcpRequest {
    param(
        [string]$Body,
        [bool]$Authorized = $true
    )
    if (-not $Authorized) {
        return @{ StatusCode = 401; Json = '{"error":"unauthorized"}' }
    }

    $req = $null
    try { $req = $Body | ConvertFrom-Json -AsHashtable } catch { }
    if ($req -isnot [System.Collections.IDictionary]) {
        return New-PssMcpError -Id $null -Code -32700 -Message 'parse error: body is not a JSON object'
    }

    $method = "$($req['method'])"
    if (-not $method) {
        return New-PssMcpError -Id $req['id'] -Code -32600 -Message "invalid request: missing 'method'"
    }

    # notifications (no id) get 202 + empty body per streamable HTTP
    if (-not $req.ContainsKey('id')) {
        return @{ StatusCode = 202; Json = $null }
    }
    $id = $req['id']
    $params = if ($req['params'] -is [System.Collections.IDictionary]) { $req['params'] } else { @{} }

    switch ($method) {
        'initialize' {
            $clientVer = "$($params['protocolVersion'])"
            $ver = if ($clientVer -in $script:McpProtocolVersions) { $clientVer } else { $script:McpDefaultProtocol }
            return New-PssMcpResult -Id $id -Result ([ordered]@{
                    protocolVersion = $ver
                    capabilities    = [ordered]@{ tools = @{} }
                    serverInfo      = [ordered]@{ name = 'psscripts'; version = "$(Get-PssAppVersion)" }
                })
        }
        'ping' {
            return New-PssMcpResult -Id $id -Result @{}
        }
        'tools/list' {
            return New-PssMcpResult -Id $id -Result ([ordered]@{ tools = @(Get-PssMcpTools) })
        }
        'tools/call' {
            $toolName = "$($params['name'])"
            if (-not $toolName) {
                return New-PssMcpError -Id $id -Code -32602 -Message "invalid params: missing tool 'name'"
            }
            if ($toolName -notin @(Get-PssMcpTools | ForEach-Object name)) {
                $valid = (Get-PssMcpTools | ForEach-Object name) -join ', '
                return New-PssMcpError -Id $id -Code -32602 -Message "unknown tool '$toolName' — valid tools: $valid"
            }
            $toolArgs = if ($params['arguments'] -is [System.Collections.IDictionary]) { $params['arguments'] } else { @{} }
            try {
                $r = Invoke-PssMcpTool -Name $toolName -Arguments $toolArgs
            } catch {
                return New-PssMcpError -Id $id -Code -32603 -Message "internal error running tool '$toolName': $($_.Exception.Message)"
            }
            return New-PssMcpResult -Id $id -Result ([ordered]@{
                    content = @(, ([ordered]@{ type = 'text'; text = "$($r.Text)" }))
                    isError = [bool]$r.IsError
                })
        }
        default {
            return New-PssMcpError -Id $id -Code -32601 -Message "method not found: $method"
        }
    }
}

# ---------------------------------------------------------------------------
# The listener loop. Foreground; systemd (or the shell) owns the lifecycle.
# ---------------------------------------------------------------------------
function Start-PssMcpServer {
    param(
        [int]$Port,
        [string]$BindAddress = 'all',
        [Parameter(Mandatory)][string]$Token
    )
    if (-not $Token) { throw 'MCP_AUTH_TOKEN is empty — refusing to start an unauthenticated server' }

    $prefix = if ($BindAddress -eq 'localhost') { "http://localhost:$Port/" } else { "http://+:$Port/" }
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)
    $listener.Start()
    Write-Host ("{0:HH:mm:ss}  MCP server listening on {1} (endpoint POST /mcp, health GET /healthz)" -f (Get-Date), $prefix)

    try {
        while ($listener.IsListening) {
            $ctx = $listener.GetContext()
            $status = 500
            try {
                $status = Write-PssMcpResponse -Context $ctx -Token $Token
            } catch {
                try {
                    $ctx.Response.StatusCode = 500
                    $bytes = [Text.Encoding]::UTF8.GetBytes('{"error":"internal"}')
                    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                } catch { }
            } finally {
                try { $ctx.Response.Close() } catch { }
            }
            Write-Host ("{0:HH:mm:ss}  {1} {2} -> {3}" -f (Get-Date), $ctx.Request.HttpMethod, $ctx.Request.Url.AbsolutePath, $status)
        }
    } finally {
        try { $listener.Stop(); $listener.Close() } catch { }
    }
}

# ---------------------------------------------------------------------------
# systemd service install (`--install-mcp-service`) — so the server runs at
# boot without a terminal. Root gets a system unit; a normal user gets a user
# unit + lingering. Unit generation is pure for testability.
# ---------------------------------------------------------------------------
function Get-PssMcpServiceUnit {
    param(
        [Parameter(Mandatory)][string]$AppDir,
        [Parameter(Mandatory)][string]$PwshPath
    )
    @"
[Unit]
Description=psscripts MCP server
After=network.target

[Service]
ExecStart=$PwshPath -NoProfile -File $AppDir/psscripts.ps1 --mcp
WorkingDirectory=$AppDir
# system units without User= don't set HOME, and the app expands ~/.psscripts
# with it — %h is the service manager's home (/root for the system manager)
Environment=HOME=%h
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
"@
}

function Install-PssMcpService {
    if (-not $IsLinux) { throw '--install-mcp-service needs systemd (Linux only)' }
    if (-not $env:MCP_AUTH_TOKEN) {
        throw 'MCP_AUTH_TOKEN is not set — add it to .env next to the app first (the service would just crash-loop without it)'
    }
    $appDir = Get-PssAppDir
    $pwshPath = [Environment]::ProcessPath
    $unit = Get-PssMcpServiceUnit -AppDir $appDir -PwshPath $pwshPath

    $isRoot = (& id -u) -eq '0'
    if ($isRoot) {
        $unitFile = '/etc/systemd/system/psscripts-mcp.service'
        $unit | Set-Content -Path $unitFile -Encoding UTF8
        & systemctl daemon-reload
        & systemctl enable psscripts-mcp
        & systemctl restart psscripts-mcp   # restart (not enable --now) so re-runs apply changes
        Write-Host "installed + started system service: $unitFile"
        Write-Host 'check:   systemctl status psscripts-mcp'
        Write-Host 'logs:    journalctl -u psscripts-mcp -f'
    } else {
        $unitDir = Join-Path $HOME '.config/systemd/user'
        if (-not (Test-Path $unitDir)) { New-Item -ItemType Directory -Path $unitDir -Force | Out-Null }
        $unitFile = Join-Path $unitDir 'psscripts-mcp.service'
        $unit | Set-Content -Path $unitFile -Encoding UTF8
        & systemctl --user daemon-reload
        & systemctl --user enable psscripts-mcp
        & systemctl --user restart psscripts-mcp   # restart (not enable --now) so re-runs apply changes
        # keep the user manager (and the service) alive with no session open
        & loginctl enable-linger $env:USER
        Write-Host "installed + started user service: $unitFile"
        Write-Host 'check:   systemctl --user status psscripts-mcp'
        Write-Host 'logs:    journalctl --user -u psscripts-mcp -f'
    }
}

# Handles one HTTP exchange; returns the status code for the request log.
function Write-PssMcpResponse {
    param($Context, [string]$Token)
    $req = $Context.Request
    $res = $Context.Response
    $path = $req.Url.AbsolutePath.TrimEnd('/')

    $sendText = {
        param([int]$Code, [string]$Body, [string]$ContentType = 'application/json')
        $res.StatusCode = $Code
        if ($Body) {
            $res.ContentType = $ContentType
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        $Code
    }

    if ($req.HttpMethod -eq 'GET' -and $path -eq '/healthz') {
        return (& $sendText 200 'ok' 'text/plain')
    }
    if ($path -notin '', '/mcp') {
        return (& $sendText 404 '{"error":"not found"}')
    }
    if ($req.HttpMethod -ne 'POST') {
        # no SSE stream (GET) and no session to delete (DELETE) — stateless server
        return (& $sendText 405 '{"error":"method not allowed"}')
    }
    if ($req.ContentLength64 -gt $script:McpMaxBodyBytes) {
        return (& $sendText 413 '{"error":"payload too large"}')
    }

    $body = ''
    $reader = [IO.StreamReader]::new($req.InputStream, [Text.Encoding]::UTF8)
    try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }

    $auth = "$($req.Headers['Authorization'])"
    $authorized = ($auth -match '^\s*Bearer\s+(.+?)\s*$') -and ($Matches[1] -ceq $Token)

    $r = Invoke-PssMcpRequest -Body $body -Authorized $authorized
    & $sendText ([int]$r.StatusCode) $r.Json
}

Export-ModuleMember -Function Start-PssMcpServer, Invoke-PssMcpRequest, Get-PssMcpTools, Invoke-PssMcpTool,
Get-PssMcpServiceUnit, Install-PssMcpService
