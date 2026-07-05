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
    @(
        [ordered]@{
            name        = 'list_scripts'
            description = 'List every script this server can run, with description, last run status and cron schedule.'
            inputSchema = [ordered]@{ type = 'object'; properties = [ordered]@{} }
        },
        [ordered]@{
            name        = 'run_script'
            description = 'Run a script to completion and return its status, exit code and output. Long scripts block until done. A script that is already running elsewhere returns status "skipped".'
            inputSchema = [ordered]@{
                type       = 'object'
                required   = @('script')
                properties = [ordered]@{
                    script          = [ordered]@{ type = 'string'; description = 'Script name exactly as returned by list_scripts' }
                    args            = [ordered]@{ type = 'string'; description = "Extra command-line arguments, quote-aware, e.g. -DryRun -Role read" }
                    env             = [ordered]@{ type = 'object'; additionalProperties = [ordered]@{ type = 'string' }; description = "Extra environment variables for this run only; override the script's .env values" }
                    timeout_minutes = [ordered]@{ type = 'number'; description = 'Override the run timeout for this run (minutes)' }
                }
            }
        },
        [ordered]@{
            name        = 'get_history'
            description = 'Recent run history (newest first), optionally filtered to one script.'
            inputSchema = [ordered]@{
                type       = 'object'
                properties = [ordered]@{
                    script = [ordered]@{ type = 'string'; description = 'Only runs of this script' }
                    limit  = [ordered]@{ type = 'number'; description = 'Max entries to return (default 20, max 200)' }
                }
            }
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
        'run_script' { return Invoke-PssMcpRunScript -Arguments $Arguments }
        'get_history' { return Invoke-PssMcpGetHistory -Arguments $Arguments }
        default {
            $valid = (Get-PssMcpTools | ForEach-Object name) -join ', '
            return @{ Text = "unknown tool '$Name' — valid tools: $valid"; IsError = $true }
        }
    }
}

function Invoke-PssMcpListScripts {
    $statuses = Get-PssLastStatuses
    $schedules = @{}
    try { $schedules = Get-PssSchedules } catch { }
    $items = foreach ($s in @(Get-PssScripts)) {
        $st = $statuses[$s.Name]
        [ordered]@{
            name           = $s.Name
            description    = "$($s.Description)"
            entry          = [IO.Path]::GetFileName("$($s.Entry)")
            lastStatus     = if ($st) { $st.Status } else { 'never run' }
            lastRunAt      = if ($st -and $st.At) { $st.At.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
            schedule       = if ($schedules.ContainsKey($s.Name)) { $schedules[$s.Name] } else { $null }
            timeoutMinutes = $s.TimeoutMinutes
        }
    }
    @{ Text = ([ordered]@{ scripts = @($items) } | ConvertTo-Json -Depth 6 -Compress); IsError = $false }
}

function Invoke-PssMcpRunScript {
    param([hashtable]$Arguments)

    $name = "$($Arguments['script'])"
    if (-not $name) {
        return @{ Text = "missing required argument 'script'"; IsError = $true }
    }
    $target = Get-PssScripts | Where-Object Name -eq $name | Select-Object -First 1
    if (-not $target) {
        $valid = (@(Get-PssScripts) | ForEach-Object Name) -join ', '
        return @{ Text = "unknown script '$name' — valid scripts: $valid"; IsError = $true }
    }

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
        }
    }
    @{ Text = ([ordered]@{ runs = @($runs) } | ConvertTo-Json -Depth 4 -Compress); IsError = $false }
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
