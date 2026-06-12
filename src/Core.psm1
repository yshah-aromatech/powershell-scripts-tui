# Core.psm1 — configuration, paths, .env handling, secret redaction, Night Owl theme

$script:AppDir = $null
$script:Config = $null
$script:Paths = $null
$script:Secrets = [System.Collections.Generic.List[string]]::new()

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

function ConvertTo-AnsiFg {
    param([string]$Hex)
    $h = $Hex.TrimStart('#')
    $r = [Convert]::ToInt32($h.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($h.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($h.Substring(4, 2), 16)
    "`e[38;2;$r;$g;${b}m"
}

function ConvertTo-AnsiBg {
    param([string]$Hex)
    $h = $Hex.TrimStart('#')
    $r = [Convert]::ToInt32($h.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($h.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($h.Substring(4, 2), 16)
    "`e[48;2;$r;$g;${b}m"
}

$script:Theme = $null

function Get-PssTheme {
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
    dataDir           = '~/.psscripts'
    n8nWebhookUrl     = ''
    pwshBin           = 'pwsh'
    monitorIntervalMs = 1000
    logTailKb         = 64
    runTimeoutMinutes = 0
    maxOutputLines    = 5000
    openRouterModel   = 'google/gemini-3.1-flash-lite'
}

function Initialize-Pss {
    param([Parameter(Mandatory)][string]$AppDir)

    $script:AppDir = $AppDir

    # config.json
    $cfg = [ordered]@{}
    foreach ($k in $script:ConfigDefaults.Keys) { $cfg[$k] = $script:ConfigDefaults[$k] }
    $cfgFile = Join-Path $AppDir 'config.json'
    if (Test-Path $cfgFile) {
        try {
            $user = Get-Content $cfgFile -Raw | ConvertFrom-Json
            foreach ($prop in $user.PSObject.Properties) {
                if ($cfg.Contains($prop.Name)) { $cfg[$prop.Name] = $prop.Value }
            }
        } catch {
            throw "config.json is not valid JSON: $($_.Exception.Message)"
        }
    }
    $script:Config = $cfg

    # app .env -> process environment (existing process env wins)
    $envFile = Join-Path $AppDir '.env'
    if (Test-Path $envFile) {
        foreach ($kv in (Read-PssEnvFile $envFile).GetEnumerator()) {
            if (-not (Test-Path "env:$($kv.Key)")) {
                Set-Item -Path "env:$($kv.Key)" -Value $kv.Value
            }
            Register-PssSecret -Name $kv.Key -Value $kv.Value
        }
    }
    # secrets that may come from the process environment directly
    foreach ($name in 'GITHUB_TOKEN', 'OPENROUTER_API_KEY', 'N8N_WEBHOOK_URL') {
        $v = [Environment]::GetEnvironmentVariable($name)
        if ($v) { Register-PssSecret -Name $name -Value $v }
    }

    # paths
    $dataDir = [string]$cfg.dataDir
    if ($dataDir.StartsWith('~')) { $dataDir = $dataDir -replace '^~', $HOME }
    $script:Paths = @{
        AppDir      = $AppDir
        DataDir     = $dataDir
        ScriptsDir  = Join-Path $dataDir 'scripts'
        ModulesDir  = Join-Path $dataDir 'modules'
        LogsDir     = Join-Path $dataDir 'logs'
        HistoryFile = Join-Path $dataDir 'history.jsonl'
    }
    foreach ($d in $script:Paths.DataDir, $script:Paths.ModulesDir, $script:Paths.LogsDir) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

function Get-PssConfig { $script:Config }

# scripts repo URL: SCRIPTS_REPO env var (e.g. via .env) overrides config.json
function Get-PssScriptsRepo {
    if ($env:SCRIPTS_REPO) { return [string]$env:SCRIPTS_REPO }
    [string]$script:Config.scriptsRepo
}
function Get-PssPaths { $script:Paths }
function Get-PssAppDir { $script:AppDir }

# ---------------------------------------------------------------------------
# .env files
# ---------------------------------------------------------------------------
function Read-PssEnvFile {
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

# ---------------------------------------------------------------------------
# Secret redaction — every secret value is replaced with *** in all output
# ---------------------------------------------------------------------------
function Register-PssSecret {
    param([string]$Name, [string]$Value)
    if (-not $Value -or $Value.Length -lt 8) { return }
    if ($Name -and $Name -notmatch 'TOKEN|KEY|SECRET|PASSWORD|PASSWD|PAT|CREDENTIAL|WEBHOOK') { return }
    if (-not $script:Secrets.Contains($Value)) { $script:Secrets.Add($Value) }
}

function Hide-PssSecret {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    foreach ($s in $script:Secrets) {
        if ($Text.Contains($s)) { $Text = $Text.Replace($s, '***') }
    }
    $Text
}

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------
function Format-PssDuration {
    param([double]$Seconds)
    if ($Seconds -lt 60) { return ('{0:n1}s' -f $Seconds) }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalHours -ge 1) { return ('{0}h{1:d2}m{2:d2}s' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds) }
    '{0}m{1:d2}s' -f $ts.Minutes, $ts.Seconds
}

function Copy-PssClipboard {
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

Export-ModuleMember -Function Initialize-Pss, Get-PssConfig, Get-PssScriptsRepo, Get-PssPaths, Get-PssAppDir,
Get-PssTheme, Read-PssEnvFile, Register-PssSecret, Hide-PssSecret,
Format-PssDuration, Copy-PssClipboard, ConvertTo-AnsiFg, ConvertTo-AnsiBg
