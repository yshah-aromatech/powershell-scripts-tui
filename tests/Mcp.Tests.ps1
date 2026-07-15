BeforeAll {
    foreach ($m in 'Core', 'Scripts', 'Deps', 'Runner', 'Cron', 'Mcp') {
        Import-Module (Join-Path $PSScriptRoot "../src/$m.psm1") -Force -DisableNameChecking
    }
    # isolated app + data dir so tests never touch ~/.scriptorium
    $script:appDir = Join-Path ([IO.Path]::GetTempPath()) "pss-mcp-tests-$(New-Guid)"
    New-Item -ItemType Directory -Path $script:appDir -Force | Out-Null
    @{ dataDir = (Join-Path $script:appDir 'data') } | ConvertTo-Json |
        Set-Content (Join-Path $script:appDir 'config.json')
    Initialize-Sto -AppDir $script:appDir

    # fixture scripts repo
    $scriptsDir = (Get-StoPaths).ScriptsDir
    foreach ($f in 'hello', 'envtest', 'sleeper') {
        New-Item -ItemType Directory -Path (Join-Path $scriptsDir $f) -Force | Out-Null
    }
    'Write-Output "hello out"; exit 0' | Set-Content (Join-Path $scriptsDir 'hello/main.ps1')
    '{"description": "says hello"}' | Set-Content (Join-Path $scriptsDir 'hello/script.json')
    @'
Write-Output "var=$env:MCP_TEST_VAR"
if ($env:MCP_TEST_VAR -eq 'supersecretvalue') { exit 0 } else { exit 1 }
'@ | Set-Content (Join-Path $scriptsDir 'envtest/main.ps1')
    'Start-Sleep -Seconds 60' | Set-Content (Join-Path $scriptsDir 'sleeper/main.ps1')

    function Send-Rpc {
        param([string]$Method, $Params = $null, $Id = 1, [bool]$Authorized = $true)
        $req = [ordered]@{ jsonrpc = '2.0'; id = $Id; method = $Method }
        if ($null -ne $Params) { $req.params = $Params }
        $r = Invoke-StoMcpRequest -Body ($req | ConvertTo-Json -Depth 10 -Compress) -Authorized $Authorized
        if ($r.Json) { $r.Parsed = $r.Json | ConvertFrom-Json }
        $r
    }
}

AfterAll {
    Remove-Item $script:appDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'initialize' {
    It 'echoes a known protocol version' {
        $r = Send-Rpc -Method 'initialize' -Params @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 't'; version = '0' } }
        $r.StatusCode | Should -Be 200
        $r.Parsed.result.protocolVersion | Should -Be '2025-06-18'
    }
    It 'falls back to the default for an unknown version' {
        $r = Send-Rpc -Method 'initialize' -Params @{ protocolVersion = '1999-01-01' }
        $r.Parsed.result.protocolVersion | Should -Be '2025-03-26'
    }
    It 'reports serverInfo and tools capability' {
        $r = Send-Rpc -Method 'initialize' -Params @{ protocolVersion = '2025-03-26' }
        $r.Parsed.result.serverInfo.name | Should -Be 'scriptorium'
        # empty JSON objects parse to property-less PSCustomObjects, which
        # Pester's BeNullOrEmpty treats as empty — assert on the wire form
        $r.Json | Should -Match '"capabilities":\{"tools":\{\}\}'
    }
}

Describe 'auth and protocol errors' {
    It 'rejects unauthorized requests with 401 regardless of body' {
        $r = Invoke-StoMcpRequest -Body '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' -Authorized $false
        $r.StatusCode | Should -Be 401
        $r = Invoke-StoMcpRequest -Body 'not json at all' -Authorized $false
        $r.StatusCode | Should -Be 401
    }
    It 'answers notifications with 202 and no body' {
        $r = Invoke-StoMcpRequest -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}' -Authorized $true
        $r.StatusCode | Should -Be 202
        $r.Json | Should -BeNullOrEmpty
    }
    It 'returns -32700 for a malformed body' {
        $r = Invoke-StoMcpRequest -Body '{nope' -Authorized $true
        ($r.Json | ConvertFrom-Json).error.code | Should -Be -32700
    }
    It 'returns -32600 when method is missing' {
        $r = Invoke-StoMcpRequest -Body '{"jsonrpc":"2.0","id":5}' -Authorized $true
        ($r.Json | ConvertFrom-Json).error.code | Should -Be -32600
    }
    It 'returns -32601 for an unknown method' {
        (Send-Rpc -Method 'resources/list').Parsed.error.code | Should -Be -32601
    }
    It 'returns -32602 for an unknown tool, listing valid ones' {
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'nope'; arguments = @{} }
        $r.Parsed.error.code | Should -Be -32602
        $r.Parsed.error.message | Should -Match 'run_script'
    }
    It 'answers ping with an empty result' {
        (Send-Rpc -Method 'ping').Json | Should -Match '"result":\{\}'
    }
}

Describe 'tools/list' {
    It 'exposes all twelve tools with object schemas' {
        $r = Send-Rpc -Method 'tools/list'
        $tools = @($r.Parsed.result.tools)
        $tools.Count | Should -Be 12
        ($tools | ForEach-Object name) | Should -Be @(
            'list_scripts', 'get_script_details', 'run_script', 'get_history', 'get_run_log',
            'sync_repos', 'get_schedules', 'set_schedule', 'remove_schedule',
            'install_deps', 'update_app', 'update_packages')
        foreach ($t in $tools) {
            $t.description | Should -Not -BeNullOrEmpty
            $t.inputSchema.type | Should -Be 'object'
        }
    }
    It 'marks script as required on run_script and cron on set_schedule' {
        $r = Send-Rpc -Method 'tools/list'
        $run = $r.Parsed.result.tools | Where-Object name -eq 'run_script'
        @($run.inputSchema.required) | Should -Contain 'script'
        $set = $r.Parsed.result.tools | Where-Object name -eq 'set_schedule'
        @($set.inputSchema.required) | Should -Contain 'cron'
    }
    It 'annotates read-only tools' {
        $r = Send-Rpc -Method 'tools/list'
        ($r.Parsed.result.tools | Where-Object name -eq 'list_scripts').annotations.readOnlyHint | Should -BeTrue
        ($r.Parsed.result.tools | Where-Object name -eq 'get_run_log').annotations.readOnlyHint | Should -BeTrue
    }
}

Describe 'list_scripts tool' {
    It 'returns the fixture scripts with descriptions' {
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'list_scripts'; arguments = @{} }
        $r.Parsed.result.isError | Should -BeFalse
        $list = ($r.Parsed.result.content[0].text | ConvertFrom-Json).scripts
        @($list | ForEach-Object name) | Should -Contain 'hello'
        ($list | Where-Object name -eq 'hello').description | Should -Be 'says hello'
        ($list | Where-Object name -eq 'hello').lastStatus | Should -Be 'never run'
    }
}

Describe 'run_script tool' {
    It 'rejects a missing script argument as a tool error' {
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'run_script'; arguments = @{} }
        $r.Parsed.result.isError | Should -BeTrue
        $r.Parsed.result.content[0].text | Should -Match "missing required argument"
    }
    It 'rejects an unknown script, listing valid names' {
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'run_script'; arguments = @{ script = 'nope' } }
        $r.Parsed.result.isError | Should -BeTrue
        $r.Parsed.result.content[0].text | Should -Match 'hello'
    }
    It 'runs a script end-to-end and records history with trigger=mcp' {
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'run_script'; arguments = @{ script = 'hello' } }
        $r.Parsed.result.isError | Should -BeFalse
        $run = $r.Parsed.result.content[0].text | ConvertFrom-Json
        $run.status | Should -Be 'success'
        $run.exitCode | Should -Be 0
        $run.output | Should -Match 'hello out'
        $last = @(Get-StoHistory -Last 5) | Where-Object script -eq 'hello' | Select-Object -Last 1
        $last.trigger | Should -Be 'mcp'
    }
    It 'passes env vars through and redacts their values in the output' {
        $r = Send-Rpc -Method 'tools/call' -Params @{
            name = 'run_script'
            arguments = @{ script = 'envtest'; env = @{ MCP_TEST_VAR = 'supersecretvalue' } }
        }
        $run = $r.Parsed.result.content[0].text | ConvertFrom-Json
        $run.status | Should -Be 'success'          # script exits 0 only if the var arrived
        $run.output | Should -Not -Match 'supersecretvalue'
        $run.output | Should -Match '\*\*\*'
    }
    It 'reports skipped when the script is already running (locked)' {
        $lock = Lock-StoScript -Name 'hello'
        try {
            $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'run_script'; arguments = @{ script = 'hello' } }
            $run = $r.Parsed.result.content[0].text | ConvertFrom-Json
            $run.status | Should -Be 'skipped'
            $run.note | Should -Match 'already running'
        } finally {
            Unlock-StoScript -Handle @{ LockFile = $lock.File }
        }
    }
    It 'honors the timeout_minutes override' {
        $r = Send-Rpc -Method 'tools/call' -Params @{
            name = 'run_script'
            arguments = @{ script = 'sleeper'; timeout_minutes = 0.02 }
        }
        $run = $r.Parsed.result.content[0].text | ConvertFrom-Json
        $run.status | Should -Be 'timeout'
    }
}

Describe 'Get-StoMcpServiceUnit' {
    It 'generates a valid systemd unit pointing at the app' {
        $u = Get-StoMcpServiceUnit -AppDir '/opt/pss' -PwshPath '/usr/bin/pwsh'
        $u | Should -Match '(?m)^ExecStart=/usr/bin/pwsh -NoProfile -File /opt/pss/scriptorium\.ps1 --mcp$'
        $u | Should -Match '(?m)^WorkingDirectory=/opt/pss$'
        $u | Should -Match '(?m)^Environment=HOME=%h$'
        $u | Should -Match '(?m)^Restart=on-failure$'
        $u | Should -Match '(?m)^WantedBy=default\.target$'
    }
}

Describe 'get_history tool' {
    It 'returns recent runs newest-first and honors the script filter' {
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'get_history'; arguments = @{ script = 'hello'; limit = 5 } }
        $r.Parsed.result.isError | Should -BeFalse
        $runs = ($r.Parsed.result.content[0].text | ConvertFrom-Json).runs
        @($runs).Count | Should -BeGreaterThan 0
        foreach ($x in $runs) { $x.script | Should -Be 'hello' }
    }
}

Describe 'get_script_details tool' {
    It 'returns parsed parameters for a PowerShell script' {
        $d = Join-Path (Get-StoPaths).ScriptsDir 'detailed'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        "param([Parameter(Mandatory)][string]`$Who, [switch]`$DryRun)`nWrite-Output hi" |
            Set-Content (Join-Path $d 'main.ps1')
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'get_script_details'; arguments = @{ script = 'detailed' } }
        $r.Parsed.result.isError | Should -BeFalse
        $detail = $r.Parsed.result.content[0].text | ConvertFrom-Json
        @($detail.parameters | ForEach-Object name) | Should -Be @('Who', 'DryRun')
        ($detail.parameters | Where-Object name -eq 'Who').mandatory | Should -BeTrue
        ($detail.parameters | Where-Object name -eq 'DryRun').isSwitch | Should -BeTrue
        $detail.argsHint | Should -Match 'PowerShell'
    }
    It 'rejects an unknown script' {
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'get_script_details'; arguments = @{ script = 'nope' } }
        $r.Parsed.result.isError | Should -BeTrue
    }
}

Describe 'list_scripts enrichment' {
    It 'reports runtime, repo and running state' {
        $lock = Lock-StoScript -Name 'hello'
        try {
            $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'list_scripts'; arguments = @{} }
            $list = ($r.Parsed.result.content[0].text | ConvertFrom-Json).scripts
            $hello = $list | Where-Object name -eq 'hello'
            $hello.running | Should -BeTrue
            $hello.runtime | Should -Be 'powershell'
            $hello.repo | Should -Be 'scripts'
        } finally {
            Unlock-StoScript -Handle @{ LockFile = $lock.File }
        }
    }
}

Describe 'get_run_log tool' {
    It 'returns a past run log via the logId from get_history' {
        # 'hello' ran in an earlier Describe — chain history -> log. Newer
        # rows may be lock-skipped runs (no log), so take the first WITH one.
        $h = Send-Rpc -Method 'tools/call' -Params @{ name = 'get_history'; arguments = @{ script = 'hello'; limit = 10 } }
        $run = @(($h.Parsed.result.content[0].text | ConvertFrom-Json).runs |
            Where-Object { $_.logId }) | Select-Object -First 1
        $run.logId | Should -Match '\.log$'
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'get_run_log'; arguments = @{ log_id = $run.logId } }
        $r.Parsed.result.isError | Should -BeFalse
        ($r.Parsed.result.content[0].text | ConvertFrom-Json).log | Should -Match 'hello out'
    }
    It 'rejects traversal-shaped and unknown ids' {
        foreach ($bad in '../../etc/passwd.log', '/etc/passwd.log', 'x/y.log', 'no-extension') {
            $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'get_run_log'; arguments = @{ log_id = $bad } }
            $r.Parsed.result.isError | Should -BeTrue
        }
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'get_run_log'; arguments = @{ log_id = 'ghost-run.log' } }
        $r.Parsed.result.isError | Should -BeTrue
        $r.Parsed.result.content[0].text | Should -Match 'not found'
    }
}

Describe 'sync_repos tool' {
    It 'reports failure with output when no repo is configured' {
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'sync_repos'; arguments = @{} }
        $r.Parsed.result.isError | Should -BeTrue
        ($r.Parsed.result.content[0].text | ConvertFrom-Json).output | Should -Match 'repo'
    }
}

Describe 'schedule tools' {
    BeforeAll {
        # never touch the real crontab from tests
        Mock Set-StoSchedule { } -ModuleName Mcp
        Mock Remove-StoSchedule { } -ModuleName Mcp
        Mock Get-StoSchedules { @{ hello = '*/30 * * * *' } } -ModuleName Mcp
    }
    It 'lists schedules with next fire times' {
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'get_schedules'; arguments = @{} }
        $s = (($r.Parsed.result.content[0].text | ConvertFrom-Json).schedules)[0]
        $s.script | Should -Be 'hello'
        $s.cron | Should -Be '*/30 * * * *'
        # ConvertFrom-Json parses the ISO string into [datetime] — stringify
        "$($s.nextRun)" | Should -Not -BeNullOrEmpty
    }
    It 'sets a valid schedule and reports the next run' {
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'set_schedule'; arguments = @{ script = 'hello'; cron = '@daily' } }
        $r.Parsed.result.isError | Should -BeFalse
        $out = $r.Parsed.result.content[0].text | ConvertFrom-Json
        $out.cron | Should -Be '@daily'
        Should -Invoke Set-StoSchedule -ModuleName Mcp -Times 1 -Exactly
    }
    It 'rejects an invalid cron expression without writing' {
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'set_schedule'; arguments = @{ script = 'hello'; cron = 'every tuesday' } }
        $r.Parsed.result.isError | Should -BeTrue
        $r.Parsed.result.content[0].text | Should -Match '@hourly'
        Should -Invoke Set-StoSchedule -ModuleName Mcp -Times 0 -Exactly
    }
    It 'removes a schedule' {
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'remove_schedule'; arguments = @{ script = 'hello' } }
        $r.Parsed.result.isError | Should -BeFalse
        Should -Invoke Remove-StoSchedule -ModuleName Mcp -Times 1 -Exactly
    }
}

Describe 'install_deps tool' {
    It 'reports upToDate for a script with no third-party deps' {
        $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'install_deps'; arguments = @{ script = 'hello' } }
        $r.Parsed.result.isError | Should -BeFalse
        ($r.Parsed.result.content[0].text | ConvertFrom-Json).upToDate | Should -BeTrue
    }
}
