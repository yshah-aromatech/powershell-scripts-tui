# Core.psm1 — configuration, paths, .env handling, secret redaction, Night Owl theme

$script:AppDir = $null
$script:Config = $null
$script:Paths = $null
$script:Secrets = [System.Collections.Generic.List[string]]::new()
$script:ConfigWarnings = [System.Collections.Generic.List[string]]::new()
$script:ColorMode = 'truecolor'   # truecolor | 256

# ---------------------------------------------------------------------------
# Night Owl (dark) palette — https://terminalcolors.com/themes/night-owl/dark/
# ---------------------------------------------------------------------------
$script:NightOwl = [ordered]@{
    Bg       = '#011627'
    Fg       = '#cccccc'
    SelBg    = '#093b5e'
    Black    = '#011627'
    Red      = '#ef5350'
    Green    = '#22da6e'
    Yellow   = '#c5e478'
    Blue     = '#82aaff'
    Magenta  = '#c792ea'
    Cyan     = '#21c7a8'
    White    = '#ffffff'
    BrBlack  = '#575656'
    BrYellow = '#ffeb95'
    BrCyan   = '#7fdbca'
}

# Nearest xterm-256 index for a 24-bit color (6x6x6 cube + grayscale ramp),
# used when the terminal doesn't advertise truecolor.
function ConvertTo-Ansi256Index {
    param([int]$R, [int]$G, [int]$B)
    $steps = 0, 95, 135, 175, 215, 255
    $q = { param($v) $best = 0; for ($i = 1; $i -lt 6; $i++) { if ([Math]::Abs($steps[$i] - $v) -lt [Math]::Abs($steps[$best] - $v)) { $best = $i } }; $best }
    $qr = & $q $R; $qg = & $q $G; $qb = & $q $B
    $cubeIdx = 16 + 36 * $qr + 6 * $qg + $qb
    $cubeDist = [Math]::Pow($steps[$qr] - $R, 2) + [Math]::Pow($steps[$qg] - $G, 2) + [Math]::Pow($steps[$qb] - $B, 2)

    $avg = [int](($R + $G + $B) / 3)
    $gi = [Math]::Min(23, [Math]::Max(0, [int][Math]::Round(($avg - 8) / 10.0)))
    $gv = 8 + 10 * $gi
    $grayIdx = 232 + $gi
    $grayDist = [Math]::Pow($gv - $R, 2) + [Math]::Pow($gv - $G, 2) + [Math]::Pow($gv - $B, 2)

    if ($grayDist -lt $cubeDist) { $grayIdx } else { $cubeIdx }
}

function ConvertFrom-StoHex {
    param([string]$Hex)
    $h = $Hex.TrimStart('#')
    @([Convert]::ToInt32($h.Substring(0, 2), 16),
        [Convert]::ToInt32($h.Substring(2, 2), 16),
        [Convert]::ToInt32($h.Substring(4, 2), 16))
}

function ConvertTo-AnsiFg {
    param([string]$Hex)
    $r, $g, $b = ConvertFrom-StoHex $Hex
    if ($script:ColorMode -eq '256') { return "`e[38;5;$(ConvertTo-Ansi256Index $r $g $b)m" }
    "`e[38;2;$r;$g;${b}m"
}

function ConvertTo-AnsiBg {
    param([string]$Hex)
    $r, $g, $b = ConvertFrom-StoHex $Hex
    if ($script:ColorMode -eq '256') { return "`e[48;5;$(ConvertTo-Ansi256Index $r $g $b)m" }
    "`e[48;2;$r;$g;${b}m"
}

$script:Theme = $null

function Get-StoTheme {
    if (-not $script:Theme) {
        $p = $script:NightOwl
        $script:Theme = @{
            Reset    = "`e[0m"
            Bold     = "`e[1m"
            Dim      = "`e[2m"
            Bg       = ConvertTo-AnsiBg $p.Bg
            Fg       = ConvertTo-AnsiFg $p.Fg
            SelBg    = ConvertTo-AnsiBg $p.SelBg
            Red      = ConvertTo-AnsiFg $p.Red
            Green    = ConvertTo-AnsiFg $p.Green
            Yellow   = ConvertTo-AnsiFg $p.Yellow
            Blue     = ConvertTo-AnsiFg $p.Blue
            Magenta  = ConvertTo-AnsiFg $p.Magenta
            Cyan     = ConvertTo-AnsiFg $p.Cyan
            White    = ConvertTo-AnsiFg $p.White
            Muted    = ConvertTo-AnsiFg $p.BrBlack
            BrYellow = ConvertTo-AnsiFg $p.BrYellow
            BrCyan   = ConvertTo-AnsiFg $p.BrCyan
            BlueBg   = ConvertTo-AnsiBg $p.Blue
            BlackFg  = ConvertTo-AnsiFg $p.Black
            Palette  = $p
        }
    }
    $script:Theme
}

# ---------------------------------------------------------------------------
# Config / paths
# ---------------------------------------------------------------------------
$script:ConfigDefaults = [ordered]@{
    scriptsRepo       = ''
    branch            = 'main'
    repos             = @()        # multi-repo: [{name, url, branch}] — overrides scriptsRepo/branch
    pythonBin         = 'python3'  # interpreter used to CREATE venvs (scripts run on the venv's python)
    dataDir           = '~/.scriptorium'
    n8nWebhookUrl     = ''
    pwshBin           = 'pwsh'
    monitorIntervalMs = 1000
    logTailKb         = 64
    runTimeoutMinutes = 0
    maxOutputLines    = 5000
    openRouterModel   = 'google/gemini-3.1-flash-lite'
    syncOnLaunch      = $false
    logRetentionDays  = 30
    historyMaxLines   = 5000
    webhookTimeoutSec = 15
    colorMode         = 'auto'      # auto | truecolor | 256
    mcpPort           = 8765
    mcpBind           = 'all'       # all (LAN-reachable) | localhost
}
# keys whose values must parse as numbers — a typo'd string here would
# otherwise silently disable the feature
$script:ConfigNumericKeys = @('monitorIntervalMs', 'logTailKb', 'runTimeoutMinutes',
    'maxOutputLines', 'logRetentionDays', 'historyMaxLines', 'webhookTimeoutSec', 'mcpPort')

function Initialize-Sto {
    param([Parameter(Mandatory)][string]$AppDir)

    $script:AppDir = $AppDir

    # config.json
    $cfg = [ordered]@{}
    foreach ($k in $script:ConfigDefaults.Keys) { $cfg[$k] = $script:ConfigDefaults[$k] }
    $cfgFile = Join-Path $AppDir 'config.json'
    $script:ConfigWarnings.Clear()
    if (Test-Path $cfgFile) {
        try {
            $user = Get-Content $cfgFile -Raw | ConvertFrom-Json
            foreach ($prop in $user.PSObject.Properties) {
                if (-not $cfg.Contains($prop.Name)) {
                    $script:ConfigWarnings.Add("config.json: unknown key '$($prop.Name)' — ignored (typo?)")
                    continue
                }
                if ($prop.Name -in $script:ConfigNumericKeys -and $null -eq ($prop.Value -as [double])) {
                    $script:ConfigWarnings.Add("config.json: '$($prop.Name)' must be a number, got '$($prop.Value)' — using default $($cfg[$prop.Name])")
                    continue
                }
                $cfg[$prop.Name] = $prop.Value
            }
        } catch {
            throw "config.json is not valid JSON: $($_.Exception.Message)"
        }
    }
    $script:Config = $cfg

    # color mode: honor config, else detect truecolor support
    $script:ColorMode = switch ([string]$cfg.colorMode) {
        'truecolor' { 'truecolor' }
        '256' { '256' }
        default {
            if ($env:COLORTERM -match 'truecolor|24bit') { 'truecolor' } else { '256' }
        }
    }

    # app .env -> process environment (existing process env wins)
    $envFile = Join-Path $AppDir '.env'
    if (Test-Path $envFile) {
        foreach ($kv in (Read-StoEnvFile $envFile).GetEnumerator()) {
            if (-not (Test-Path "env:$($kv.Key)")) {
                Set-Item -Path "env:$($kv.Key)" -Value $kv.Value
            }
            Register-StoSecret -Name $kv.Key -Value $kv.Value
        }
    }
    # secrets that may come from the process environment directly
    foreach ($name in 'GITHUB_TOKEN', 'OPENROUTER_API_KEY', 'N8N_WEBHOOK_URL', 'MCP_AUTH_TOKEN') {
        $v = [Environment]::GetEnvironmentVariable($name)
        if ($v) { Register-StoSecret -Name $name -Value $v }
    }

    # paths
    $dataDir = [string]$cfg.dataDir
    if ($dataDir.StartsWith('~')) { $dataDir = $dataDir -replace '^~', $HOME }

    # one-time migration from the pre-rename data dir (~/.psscripts). Only when
    # dataDir is the default — an explicit dataDir is never second-guessed.
    # Venvs survive the move: pip runs as `<venv>/bin/python -m pip`, and the
    # venv's python resolves pyvenv.cfg relative to itself.
    if ([string]$cfg.dataDir -eq [string]$script:ConfigDefaults.dataDir -and -not (Test-Path $dataDir)) {
        $legacyDataDir = Join-Path $HOME '.psscripts'
        if (Test-Path $legacyDataDir) {
            try {
                Move-Item -Path $legacyDataDir -Destination $dataDir -ErrorAction Stop
                $script:ConfigWarnings.Add("migrated data dir: $legacyDataDir -> $dataDir")
            } catch {
                $script:ConfigWarnings.Add("could not migrate $legacyDataDir to ${dataDir}: $($_.Exception.Message) — using the new (empty) dir")
            }
        }
    }

    $script:Paths = @{
        AppDir      = $AppDir
        DataDir     = $dataDir
        ScriptsDir  = Join-Path $dataDir 'scripts'
        ModulesDir  = Join-Path $dataDir 'modules'
        LogsDir     = Join-Path $dataDir 'logs'
        HistoryFile = Join-Path $dataDir 'history.jsonl'
    }
    $script:Paths.LocksDir = Join-Path $dataDir 'locks'
    $script:Paths.VenvsDir = Join-Path $dataDir 'venvs'
    $script:Paths.WebhookQueueFile = Join-Path $dataDir 'webhook-queue.jsonl'
    foreach ($d in $script:Paths.DataDir, $script:Paths.ModulesDir, $script:Paths.LogsDir, $script:Paths.LocksDir, $script:Paths.VenvsDir) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # multi-repo config sanity (the entries themselves are normalized lazily
    # by Get-StoRepos so env overrides loaded just above apply)
    foreach ($r in @($cfg.repos)) {
        if (-not ("$($r.url)")) { $script:ConfigWarnings.Add("config.json: repos entry missing 'url' — skipped") }
        $rName = "$($r.name)"
        if ($rName -and $rName -notmatch '^[A-Za-z0-9_-]+$') {
            $script:ConfigWarnings.Add("config.json: repos entry name '$rName' must match [A-Za-z0-9_-]+ — skipped")
        }
    }

    Clear-StoOldData
}

# ---------------------------------------------------------------------------
# Retention: prune old run logs and cap the history file so a long-lived
# server never fills its disk. Runs at every startup (TUI and headless).
# ---------------------------------------------------------------------------
function Clear-StoOldData {
    $cfg = $script:Config
    $paths = $script:Paths
    try {
        $days = [double]$cfg.logRetentionDays
        if ($days -gt 0 -and (Test-Path $paths.LogsDir)) {
            $cutoff = (Get-Date).AddDays(-$days)
            Get-ChildItem $paths.LogsDir -File -Filter '*.log' -ErrorAction SilentlyContinue |
                Where-Object LastWriteTime -lt $cutoff |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    try {
        $max = [int]$cfg.historyMaxLines
        if ($max -gt 0 -and (Test-Path $paths.HistoryFile)) {
            $lines = @(Get-Content $paths.HistoryFile -ErrorAction SilentlyContinue)
            if ($lines.Count -gt $max) {
                $lines[($lines.Count - $max)..($lines.Count - 1)] |
                    Set-Content -Path $paths.HistoryFile -Encoding UTF8
            }
        }
    } catch { }
}

function Get-StoConfig { $script:Config }
function Get-StoConfigWarnings { @($script:ConfigWarnings) }

# scripts repo URL: SCRIPTS_REPO env var (e.g. via .env) overrides config.json
function Get-StoScriptsRepo {
    if ($env:SCRIPTS_REPO) { return [string]$env:SCRIPTS_REPO }
    [string]$script:Config.scriptsRepo
}

# Normalized repo list: @{ Name; Url; Branch; Root; Legacy }. With `repos`
# configured, each repo clones into ScriptsDir/<Name>; with only the legacy
# scriptsRepo/branch keys, the single repo stays at ScriptsDir itself (Legacy)
# so existing installs keep working with zero migration.
function Get-StoRepos {
    $cfg = $script:Config
    $paths = $script:Paths
    $repos = [System.Collections.Generic.List[object]]::new()

    $entries = @($cfg.repos)
    if ($entries.Count -gt 0) {
        foreach ($e in $entries) {
            $url = "$($e.url)"
            if (-not $url) { continue }
            $name = "$($e.name)"
            if (-not $name) { $name = ([IO.Path]::GetFileNameWithoutExtension(($url -replace '/+$', ''))) }
            if ($name -notmatch '^[A-Za-z0-9_-]+$') { continue }
            $branch = if ("$($e.branch)") { "$($e.branch)" } else { 'main' }
            $repos.Add([pscustomobject]@{
                    Name   = $name
                    Url    = $url
                    Branch = $branch
                    Root   = Join-Path $paths.ScriptsDir $name
                    Legacy = $false
                })
        }
        return $repos
    }

    # legacy single-repo entry — present even with no URL configured so
    # discovery still reads a hand-populated ScriptsDir (sync reports the
    # missing URL itself)
    $repos.Add([pscustomobject]@{
            Name   = 'scripts'
            Url    = (Get-StoScriptsRepo)
            Branch = [string]$cfg.branch
            Root   = $paths.ScriptsDir
            Legacy = $true
        })
    $repos
}

function Get-StoPaths { $script:Paths }
function Get-StoAppDir { $script:AppDir }

# Add a repo to config.json's `repos` array (used by `scriptorium --add-repo`).
# A legacy scriptsRepo config is converted to a repos entry first, so the
# existing repo keeps syncing (its clone is migrated on the next sync).
# Returns @{ Ok; Message; Name }.
function Add-StoRepoConfig {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Name = '',
        [string]$Branch = 'main'
    )
    if (-not $Name) {
        $Name = [IO.Path]::GetFileNameWithoutExtension(($Url -replace '/+$', '')) -replace '[^A-Za-z0-9_-]', '-'
    }
    if ($Name -notmatch '^[A-Za-z0-9_-]+$') {
        return @{ Ok = $false; Message = "invalid repo name '$Name' — use letters/digits/dash/underscore"; Name = $Name }
    }

    $cfgFile = Join-Path $script:AppDir 'config.json'
    $cfg = [ordered]@{}
    if (Test-Path $cfgFile) {
        $user = Get-Content $cfgFile -Raw | ConvertFrom-Json
        foreach ($prop in $user.PSObject.Properties) { $cfg[$prop.Name] = $prop.Value }
    }

    $repos = [System.Collections.Generic.List[object]]::new()
    foreach ($e in @($cfg.repos)) { if ("$($e.url)") { $repos.Add($e) } }

    # first --add-repo on a legacy config: carry the old scriptsRepo over as
    # its own entry so it keeps syncing alongside the new repo
    if ($repos.Count -eq 0 -and "$($cfg.scriptsRepo)") {
        $legacyName = [IO.Path]::GetFileNameWithoutExtension(("$($cfg.scriptsRepo)" -replace '/+$', '')) -replace '[^A-Za-z0-9_-]', '-'
        if ($legacyName -eq $Name) { $legacyName = "$legacyName-legacy" }
        $repos.Add([pscustomobject]@{
                name   = $legacyName
                url    = "$($cfg.scriptsRepo)"
                branch = $(if ("$($cfg.branch)") { "$($cfg.branch)" } else { 'main' })
            })
    }

    foreach ($e in $repos) {
        if ("$($e.name)" -ieq $Name) { return @{ Ok = $false; Message = "a repo named '$Name' already exists — pass --name to pick another"; Name = $Name } }
        $norm = { param($u) ("$u" -replace '//[^@/]+@', '//') -replace '\.git/?$', '' -replace '/+$', '' }
        if ((& $norm $e.url) -eq (& $norm $Url)) { return @{ Ok = $false; Message = "repo already configured as '$($e.name)': $($e.url)"; Name = "$($e.name)" } }
    }

    $repos.Add([pscustomobject]@{ name = $Name; url = $Url; branch = $Branch })
    $cfg.repos = @($repos)
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $cfgFile -Encoding UTF8
    @{ Ok = $true; Message = "added repo '$Name' ($Url, branch $Branch) — $($repos.Count) repo(s) configured"; Name = $Name }
}

# ---------------------------------------------------------------------------
# .env files
# ---------------------------------------------------------------------------
function Read-StoEnvFile {
    param([Parameter(Mandatory)][string]$Path)
    $result = [ordered]@{}
    if (-not (Test-Path $Path)) { return $result }
    foreach ($line in (Get-Content $Path -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $idx = $t.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $t.Substring(0, $idx).Trim()
        $val = $t.Substring($idx + 1).Trim()
        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
            ($val.StartsWith("'") -and $val.EndsWith("'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $result[$key] = $val
    }
    $result
}

# Documentation-preserving .env.example reader: unlike Read-StoEnvFile, keeps
# the comment block above each KEY=VALUE as that key's description. Returns
# a list of @{ Key; Default; Comment }.
function Read-StoEnvDoc {
    param([Parameter(Mandatory)][string]$Path)
    $entries = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path $Path)) { return $entries }
    $pending = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-Content $Path -ErrorAction SilentlyContinue)) {
        $t = "$line".Trim()
        if (-not $t) { $pending.Clear(); continue }
        if ($t.StartsWith('#')) {
            $pending.Add(($t -replace '^#\s?', ''))
            continue
        }
        $idx = $t.IndexOf('=')
        if ($idx -lt 1) { $pending.Clear(); continue }
        $key = $t.Substring(0, $idx).Trim()
        $val = $t.Substring($idx + 1).Trim().Trim('"', "'")
        $entries.Add([pscustomobject]@{
                Key     = $key
                Default = $val
                Comment = ($pending -join ' ')
            })
        $pending.Clear()
    }
    $entries
}

# ---------------------------------------------------------------------------
# Secret redaction — every secret value is replaced with *** in all output
# ---------------------------------------------------------------------------
function Register-StoSecret {
    # -Force registers the value regardless of the variable name — used for
    # per-script .env values, which are by definition config the user chose
    # to keep out of git and out of logs/webhooks.
    param([string]$Name, [string]$Value, [switch]$Force)
    if (-not $Value -or $Value.Length -lt 8) { return }
    if (-not $Force -and $Name -and
        $Name -notmatch 'TOKEN|KEY|SECRET|PASSWORD|PASSWD|PASS|PAT|CREDENTIAL|WEBHOOK|AUTH|CONN|DSN|BEARER') { return }
    if (-not $script:Secrets.Contains($Value)) { $script:Secrets.Add($Value) }
}

function Hide-StoSecret {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    foreach ($s in $script:Secrets) {
        if ($Text.Contains($s)) { $Text = $Text.Replace($s, '***') }
    }
    $Text
}

# ---------------------------------------------------------------------------
# Display width — terminal cells, not UTF-16 code units. Emoji/CJK are 2
# cells, combining marks/ZWJ/variation selectors are 0; everything the TUI
# pads or wraps must go through these or wide characters shear the layout.
# ---------------------------------------------------------------------------
function Get-StoCodepointWidth {
    param([int]$Cp)
    if ($Cp -eq 0x200D -or ($Cp -ge 0x0300 -and $Cp -le 0x036F) -or
        ($Cp -ge 0xFE00 -and $Cp -le 0xFE0F) -or ($Cp -ge 0x20D0 -and $Cp -le 0x20FF)) { return 0 }
    if (($Cp -ge 0x1100 -and $Cp -le 0x115F) -or
        ($Cp -ge 0x2E80 -and $Cp -le 0xA4CF) -or
        ($Cp -ge 0xAC00 -and $Cp -le 0xD7A3) -or
        ($Cp -ge 0xF900 -and $Cp -le 0xFAFF) -or
        ($Cp -ge 0xFE30 -and $Cp -le 0xFE4F) -or
        ($Cp -ge 0xFF00 -and $Cp -le 0xFF60) -or
        ($Cp -ge 0xFFE0 -and $Cp -le 0xFFE6) -or
        ($Cp -ge 0x1F300 -and $Cp -le 0x1FAFF) -or
        ($Cp -ge 0x20000 -and $Cp -le 0x3FFFD)) { return 2 }
    1
}

function Get-StoDisplayWidth {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    # ASCII fast path — the overwhelmingly common case in the render loop
    if ($Text -match '^[\x20-\x7e]*$') { return $Text.Length }
    $w = 0
    $i = 0
    while ($i -lt $Text.Length) {
        $cp = [char]::ConvertToUtf32($Text, $i)
        $w += Get-StoCodepointWidth $cp
        $i += [char]::IsSurrogatePair($Text, $i) ? 2 : 1
    }
    $w
}

# Truncate to at most $Width display cells and pad with spaces to exactly
# $Width. $Ellipsis appends … when truncation happens.
function Format-StoCell {
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$Width, [switch]$Ellipsis)
    if ($Width -le 0) { return '' }
    if ($null -eq $Text) { $Text = '' }
    # ASCII fast path
    if ($Text -match '^[\x20-\x7e]*$') {
        if ($Text.Length -le $Width) { return $Text.PadRight($Width) }
        if ($Ellipsis -and $Width -ge 2) { return $Text.Substring(0, $Width - 1) + '…' }
        return $Text.Substring(0, $Width)
    }
    $w = 0
    $i = 0
    $fit = $Text.Length
    while ($i -lt $Text.Length) {
        $cp = [char]::ConvertToUtf32($Text, $i)
        $cw = Get-StoCodepointWidth $cp
        if ($w + $cw -gt $Width) { $fit = $i; break }
        $w += $cw
        $i += [char]::IsSurrogatePair($Text, $i) ? 2 : 1
        $fit = $i
    }
    if ($fit -lt $Text.Length) {
        if ($Ellipsis -and $Width -ge 2) {
            return (Format-StoCell -Text $Text -Width ($Width - 1)) + '…'
        }
        $Text = $Text.Substring(0, $fit)
        $w = Get-StoDisplayWidth $Text
    }
    $Text + (' ' * [Math]::Max(0, $Width - $w))
}

# ---------------------------------------------------------------------------
# Quote-aware argument splitting — `-Message "hello world"` is two tokens,
# not three. Used by the TUI extra-args prompt and the --args CLI flag.
# ---------------------------------------------------------------------------
function Split-StoArguments {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $result = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $cur = [Text.StringBuilder]::new()
    $quote = [char]0
    $hasToken = $false
    foreach ($ch in $Text.ToCharArray()) {
        if ($quote -ne [char]0) {
            if ($ch -eq $quote) { $quote = [char]0 } else { [void]$cur.Append($ch) }
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; $hasToken = $true; continue }
        if ([char]::IsWhiteSpace($ch)) {
            if ($cur.Length -gt 0 -or $hasToken) { $result.Add($cur.ToString()); [void]$cur.Clear(); $hasToken = $false }
            continue
        }
        [void]$cur.Append($ch)
    }
    if ($cur.Length -gt 0 -or $hasToken) { $result.Add($cur.ToString()) }
    $result.ToArray()
}

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------
function Get-StoAppVersion {
    # short commit of the app checkout — shown in the header, '' if unknown
    try {
        $v = git -C $script:AppDir rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { return "$v".Trim() }
    } catch { }
    ''
}

function Format-StoDuration {
    param([double]$Seconds)
    if ($Seconds -lt 60) { return ('{0:n1}s' -f $Seconds) }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalHours -ge 1) { return ('{0}h{1:d2}m{2:d2}s' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds) }
    '{0}m{1:d2}s' -f $ts.Minutes, $ts.Seconds
}

# Compact age/eta: 45s, 12m, 3h, 5d — used in the script list and "next run"
function Format-StoRelativeTime {
    param([double]$Seconds)
    $s = [Math]::Abs($Seconds)
    if ($s -lt 60) { return ('{0}s' -f [int]$s) }
    if ($s -lt 3600) { return ('{0}m' -f [int][Math]::Floor($s / 60)) }
    if ($s -lt 86400) {
        $h = [int][Math]::Floor($s / 3600)
        $m = [int][Math]::Floor(($s % 3600) / 60)
        return $(if ($m -gt 0 -and $h -lt 10) { "${h}h${m}m" } else { "${h}h" })
    }
    '{0}d' -f [int][Math]::Floor($s / 86400)
}

function Copy-StoClipboard {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    foreach ($tool in @(
            @{ Cmd = 'wl-copy'; Args = @() },
            @{ Cmd = 'xclip'; Args = @('-selection', 'clipboard') },
            @{ Cmd = 'xsel'; Args = @('--clipboard', '--input') })) {
        if (Get-Command $tool.Cmd -ErrorAction SilentlyContinue) {
            try {
                $Text | & $tool.Cmd @($tool.Args) 2>$null
                if ($LASTEXITCODE -eq 0) { return "copied via $($tool.Cmd)" }
            } catch { }
        }
    }
    # OSC 52 — works over SSH if the terminal supports it
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
    [Console]::Write("`e]52;c;$b64`a")
    'copied via OSC 52'
}

Export-ModuleMember -Function Initialize-Sto, Get-StoConfig, Get-StoConfigWarnings, Get-StoScriptsRepo, Get-StoRepos, Add-StoRepoConfig,
Get-StoPaths, Get-StoAppDir, Get-StoAppVersion, Get-StoTheme, Read-StoEnvFile, Read-StoEnvDoc, Register-StoSecret,
Hide-StoSecret, Format-StoDuration, Format-StoRelativeTime, Copy-StoClipboard,
ConvertTo-AnsiFg, ConvertTo-AnsiBg, ConvertTo-Ansi256Index,
Get-StoDisplayWidth, Get-StoCodepointWidth, Format-StoCell, Split-StoArguments, Clear-StoOldData
