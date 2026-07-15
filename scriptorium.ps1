#!/usr/bin/env pwsh
# scriptorium.ps1 — Scriptorium entry point
#
#   scriptorium                 launch the TUI
#   scriptorium --list          list discovered scripts
#   scriptorium --run <name>    run one script headless (full pipeline)
#   scriptorium --run <name> --args "<extra args>"   pass extra arguments
#   scriptorium --run <name> --cron     same, marks the run as cron-triggered
#   scriptorium --sync          sync all scripts repos and exit
#   scriptorium --repos         list configured scripts repos
#   scriptorium --add-repo <url> [--name <n>] [--branch <b>]   add a scripts repo
#   scriptorium --history [name]        print recent runs (optionally one script)
#   scriptorium --mcp [--port <n>]      serve the MCP server (for n8n AI agents)
#   scriptorium --install-mcp-service   install + start the MCP server as a systemd service
#   scriptorium --help

$ErrorActionPreference = 'Stop'
$appDir = $PSScriptRoot

foreach ($m in 'Core', 'Scripts', 'Deps', 'Runner', 'Cron', 'Mcp', 'Tui') {
    Import-Module (Join-Path $appDir "src/$m.psm1") -Force -Global -DisableNameChecking
}

Initialize-Sto -AppDir $appDir

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
$runName = $null
$extraArgsRaw = ''
$isCron = $false
$listOnly = $false
$syncOnly = $false
$historyOnly = $false
$historyName = $null
$mcpOnly = $false
$mcpInstall = $false
$mcpPortOverride = 0
$addRepoUrl = $null
$addRepoName = ''
$addRepoBranch = 'main'
$listRepos = $false
$showHelp = $false
for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        '--run' { $runName = $args[$i + 1]; $i++ }
        '--args' { $extraArgsRaw = "$($args[$i + 1])"; $i++ }
        '--cron' { $isCron = $true }
        '--list' { $listOnly = $true }
        '--sync' { $syncOnly = $true }
        '--mcp' { $mcpOnly = $true }
        '--port' { $mcpPortOverride = [int]$args[$i + 1]; $i++ }
        '--repos' { $listRepos = $true }
        '--add-repo' { $addRepoUrl = "$($args[$i + 1])"; $i++ }
        '--name' { $addRepoName = "$($args[$i + 1])"; $i++ }
        '--branch' { $addRepoBranch = "$($args[$i + 1])"; $i++ }
        '--install-mcp-service' { $mcpInstall = $true }
        '--history' {
            $historyOnly = $true
            if ($i + 1 -lt $args.Count -and "$($args[$i + 1])" -notlike '--*') { $historyName = "$($args[$i + 1])"; $i++ }
        }
        { $_ -in '--help', '-h' } { $showHelp = $true }
    }
}

foreach ($w in (Get-StoConfigWarnings)) { Write-Warning $w }

if ($showHelp) {
    Get-Content $PSCommandPath | Select-Object -Skip 1 -First 15 | ForEach-Object { $_ -replace '^#\s?', '' }
    exit 0
}

if ($addRepoUrl) {
    $r = Add-StoRepoConfig -Url $addRepoUrl -Name $addRepoName -Branch $addRepoBranch
    Write-Host $r.Message
    if ($r.Ok) { Write-Host "run 'scriptorium --sync' to clone it" }
    exit $(if ($r.Ok) { 0 } else { 1 })
}

if ($listRepos) {
    foreach ($r in @(Get-StoRepos)) {
        $tag = if ($r.Legacy) { ' (legacy scriptsRepo)' } else { '' }
        $url = if ($r.Url) { $r.Url } else { '<no url configured>' }
        '{0,-15} {1,-8} {2}{3}' -f $r.Name, $r.Branch, $url, $tag
    }
    exit 0
}

if ($mcpInstall) {
    try {
        Install-StoMcpService
        exit 0
    } catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

if ($mcpOnly) {
    $token = $env:MCP_AUTH_TOKEN
    if (-not $token) {
        Write-Error 'MCP_AUTH_TOKEN is not set — add it to .env next to this script (see .env.example). Refusing to start an unauthenticated server.'
        exit 1
    }
    $cfg = Get-StoConfig
    $port = if ($mcpPortOverride -gt 0) { $mcpPortOverride } else { [int]$cfg.mcpPort }
    Start-StoMcpServer -Port $port -BindAddress ([string]$cfg.mcpBind) -Token $token
    exit 0
}

if ($listOnly) {
    $statuses = Get-StoLastStatuses
    $schedules = Get-StoSchedules
    foreach ($s in (Get-StoScripts)) {
        $st = if ($statuses.ContainsKey($s.Name)) { $statuses[$s.Name].Status } else { 'never run' }
        $sched = if ($schedules.ContainsKey($s.Name)) { "  [$($schedules[$s.Name])]" } else { '' }
        $rt = if ("$($s.Runtime)" -eq 'python') { 'py' } else { 'ps' }
        '{0,-30} {1,-3} {2,-10}{3}' -f $s.Name, $rt, $st, $sched
    }
    exit 0
}

if ($syncOnly) {
    $ok = Sync-StoRepo -OnOutput { param($line) Write-Host $line }
    exit $(if ($ok) { 0 } else { 1 })
}

if ($historyOnly) {
    $items = @(Get-StoHistory -Last 200)
    if ($historyName) { $items = @($items | Where-Object { "$($_.script)" -eq $historyName }) }
    if ($items.Count -eq 0) { Write-Host 'no runs recorded'; exit 0 }
    foreach ($h in $items) {
        $when = "$($h.startedAt)" -replace 'T', ' ' -replace '\.\d+Z$', 'Z'
        '{0}  {1,-9} {2,-25} {3,8}  cpu {4,5}%  mem {5,7}MB  [{6}]' -f
        $when, $h.status, $h.script, (Format-StoDuration ([double]$h.durationSec)),
        $h.resources.cpuMaxPercent, $h.resources.memMaxMb, $h.trigger
    }
    exit 0
}

# ---------------------------------------------------------------------------
# headless run: full pipeline, missing modules auto-installed, no prompts
# ---------------------------------------------------------------------------
if ($runName) {
    $target = Get-StoScripts | Where-Object Name -eq $runName | Select-Object -First 1
    if (-not $target) {
        Write-Error "script '$runName' not found — run 'scriptorium --list' (or sync first)"
        exit 2
    }

    $missing = @(Get-StoMissingDeps -Script $target)
    if ($missing.Count -gt 0) {
        Write-Host "installing missing modules: $(($missing | ForEach-Object Display) -join ', ')"
        $cfg = Get-StoConfig
        $cmd = Get-StoInstallCommand -Script $target -Modules $missing
        & ([string]$cfg.pwshBin) -NoProfile -NonInteractive -Command $cmd
    }

    $trigger = if ($isCron) { 'cron' } else { 'manual' }
    $extraArgs = @(Split-StoArguments $extraArgsRaw)
    $handle = Start-StoRun -Script $target -Trigger $trigger -ExtraArgs $extraArgs
    $result = Invoke-StoRunToCompletion -Handle $handle -OnLine { param($line) Write-Host $line }
    $r = $result.resources
    Write-Host ("-- {0}: {1} (exit {2}) in {3}s | cpu avg {4}% peak {5}% | mem avg {6}MB peak {7}MB" -f
        $result.script, $result.status, $result.exitCode, $result.durationSec,
        $r.cpuAvgPercent, $r.cpuMaxPercent, $r.memAvgMb, $r.memMaxMb)
    exit $(if ($result.success) { 0 } elseif ($result.status -eq 'skipped') { 3 } else { 1 })
}

# ---------------------------------------------------------------------------
# default: TUI
# ---------------------------------------------------------------------------
Start-StoTui
