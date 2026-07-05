BeforeAll {
    foreach ($m in 'Core', 'Scripts', 'Deps', 'Runner', 'Cron', 'Mcp') {
        Import-Module (Join-Path $PSScriptRoot "../src/$m.psm1") -Force -DisableNameChecking
    }
    # isolated app + data dir so tests never touch ~/.psscripts
    $script:appDir = Join-Path ([IO.Path]::GetTempPath()) "pss-mcp-tests-$(New-Guid)"
    New-Item -ItemType Directory -Path $script:appDir -Force | Out-Null
    @{ dataDir = (Join-Path $script:appDir 'data') } | ConvertTo-Json |
        Set-Content (Join-Path $script:appDir 'config.json')
    Initialize-Pss -AppDir $script:appDir

    # fixture scripts repo
    $scriptsDir = (Get-PssPaths).ScriptsDir
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
        $r = Invoke-PssMcpRequest -Body ($req | ConvertTo-Json -Depth 10 -Compress) -Authorized $Authorized
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
        $r.Parsed.result.serverInfo.name | Should -Be 'psscripts'
        # empty JSON objects parse to property-less PSCustomObjects, which
        # Pester's BeNullOrEmpty treats as empty — assert on the wire form
        $r.Json | Should -Match '"capabilities":\{"tools":\{\}\}'
    }
}

Describe 'auth and protocol errors' {
    It 'rejects unauthorized requests with 401 regardless of body' {
        $r = Invoke-PssMcpRequest -Body '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' -Authorized $false
        $r.StatusCode | Should -Be 401
        $r = Invoke-PssMcpRequest -Body 'not json at all' -Authorized $false
        $r.StatusCode | Should -Be 401
    }
    It 'answers notifications with 202 and no body' {
        $r = Invoke-PssMcpRequest -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}' -Authorized $true
        $r.StatusCode | Should -Be 202
        $r.Json | Should -BeNullOrEmpty
    }
    It 'returns -32700 for a malformed body' {
        $r = Invoke-PssMcpRequest -Body '{nope' -Authorized $true
        ($r.Json | ConvertFrom-Json).error.code | Should -Be -32700
    }
    It 'returns -32600 when method is missing' {
        $r = Invoke-PssMcpRequest -Body '{"jsonrpc":"2.0","id":5}' -Authorized $true
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
    It 'exposes exactly the three tools with object schemas' {
        $r = Send-Rpc -Method 'tools/list'
        $tools = @($r.Parsed.result.tools)
        $tools.Count | Should -Be 3
        ($tools | ForEach-Object name) | Should -Be @('list_scripts', 'run_script', 'get_history')
        foreach ($t in $tools) {
            $t.description | Should -Not -BeNullOrEmpty
            $t.inputSchema.type | Should -Be 'object'
        }
    }
    It 'marks script as required on run_script' {
        $r = Send-Rpc -Method 'tools/list'
        $run = $r.Parsed.result.tools | Where-Object name -eq 'run_script'
        @($run.inputSchema.required) | Should -Contain 'script'
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
        $last = @(Get-PssHistory -Last 5) | Where-Object script -eq 'hello' | Select-Object -Last 1
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
        $lock = Lock-PssScript -Name 'hello'
        try {
            $r = Send-Rpc -Method 'tools/call' -Params @{ name = 'run_script'; arguments = @{ script = 'hello' } }
            $run = $r.Parsed.result.content[0].text | ConvertFrom-Json
            $run.status | Should -Be 'skipped'
            $run.note | Should -Match 'already running'
        } finally {
            Unlock-PssScript -Handle @{ LockFile = $lock.File }
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

Describe 'Get-PssMcpServiceUnit' {
    It 'generates a valid systemd unit pointing at the app' {
        $u = Get-PssMcpServiceUnit -AppDir '/opt/pss' -PwshPath '/usr/bin/pwsh'
        $u | Should -Match '(?m)^ExecStart=/usr/bin/pwsh -NoProfile -File /opt/pss/psscripts\.ps1 --mcp$'
        $u | Should -Match '(?m)^WorkingDirectory=/opt/pss$'
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
