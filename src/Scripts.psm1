# Scripts.psm1 — scripts repo sync (clone / hard-reset) and script discovery

# ---------------------------------------------------------------------------
# Repo sync: clone if missing, otherwise hard-reset to origin/<branch>.
# Local per-script .env files survive the reset/clean.
# ---------------------------------------------------------------------------
function Sync-PssRepo {
    [CmdletBinding()]
    param([scriptblock]$OnOutput = { param($line) })

    $cfg = Get-PssConfig
    $paths = Get-PssPaths
    $emit = { param($l) & $OnOutput (Hide-PssSecret $l) }

    $repo = Get-PssScriptsRepo
    if (-not $repo) {
        & $emit 'scripts repo is not set — set SCRIPTS_REPO in .env or scriptsRepo in config.json'
        return $false
    }

    $url = $repo
    $token = $env:GITHUB_TOKEN
    if ($token -and $url -match '^https://' -and $url -notmatch '@') {
        $url = $url -replace '^https://', "https://x-access-token:$token@"
    }

    $dir = $paths.ScriptsDir
    $branch = [string]$cfg.branch

    if (-not (Test-Path (Join-Path $dir '.git'))) {
        & $emit "cloning $repo (branch $branch)..."
        $gitOut = git clone --branch $branch $url $dir 2>&1
        foreach ($l in $gitOut) { if ("$l") { & $emit "$l" } }
        $ok = ($LASTEXITCODE -eq 0)
    } else {
        & $emit "syncing $repo (hard reset to origin/$branch)..."
        git -C $dir remote set-url origin $url 2>&1 | Out-Null  # refresh token
        # each step's exit code is checked individually — a failed fetch (e.g.
        # expired token) must fail the sync, not be masked by a later step
        $steps = @(
            , @('fetch', 'origin')
            , @('checkout', $branch)
            , @('reset', '--hard', "origin/$branch")
            # clean untracked files but keep local .env files
            , @('clean', '-fdx', '-e', '.env', '-e', '**/.env')
        )
        $ok = $true
        foreach ($step in $steps) {
            $gitOut = git -C $dir @step 2>&1
            foreach ($l in $gitOut) { if ("$l") { & $emit "$l" } }
            if ($LASTEXITCODE -ne 0) {
                & $emit "git $($step[0]) failed (exit $LASTEXITCODE)"
                $ok = $false
                break
            }
        }
    }

    & $emit $(if ($ok) { 'sync complete' } else { 'sync FAILED — check GITHUB_TOKEN in .env' })
    $ok
}

# When the scripts clone was last synced: FETCH_HEAD is touched by every
# fetch; a fresh clone (no fetch yet) falls back to the .git dir itself.
# Reflects syncs from any process (TUI, --sync, cron), not just this one.
function Get-PssLastSyncTime {
    $dir = (Get-PssPaths).ScriptsDir
    foreach ($p in (Join-Path $dir '.git/FETCH_HEAD'), (Join-Path $dir '.git')) {
        if (Test-Path $p) { return (Get-Item $p).LastWriteTime }
    }
    $null
}

# ---------------------------------------------------------------------------
# Discovery — one folder per script (entry: script.json "entry", main.ps1,
# <folder>.ps1 or run.ps1), plus loose .ps1 files in the repo root.
# ---------------------------------------------------------------------------
function Get-PssScripts {
    $paths = Get-PssPaths
    $scripts = [System.Collections.Generic.List[object]]::new()
    $root = $paths.ScriptsDir
    if (-not (Test-Path $root)) { return $scripts }

    foreach ($dir in (Get-ChildItem $root -Directory | Where-Object Name -notin '.git', '.github' | Sort-Object Name)) {
        $meta = $null
        $metaFile = Join-Path $dir.FullName 'script.json'
        if (Test-Path $metaFile) {
            try { $meta = Get-Content $metaFile -Raw | ConvertFrom-Json } catch { }
        }
        $entry = $null

        # explicit entry from script.json wins (may be a relative path with subfolders)
        if ($meta -and $meta.PSObject.Properties['entry'] -and $meta.entry) {
            $p = Join-Path $dir.FullName ([string]$meta.entry)
            if (Test-Path $p) { $entry = (Resolve-Path -LiteralPath $p).Path }
        }

        # all .ps1 files in this folder (one level), used for matching + fallback.
        # matched/compared case-insensitively because the server FS is case-sensitive.
        $ps1Files = @(Get-ChildItem $dir.FullName -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -ieq '.ps1' } | Sort-Object Name)

        if (-not $entry) {
            foreach ($c in 'main.ps1', "$($dir.Name).ps1", 'run.ps1') {
                $match = $ps1Files | Where-Object { $_.Name -ieq $c } | Select-Object -First 1
                if ($match) { $entry = $match.FullName; break }
            }
        }

        # fallback: no conventional entry — use the sole .ps1 in the folder.
        # if several exist and none is conventional, take the first alphabetically
        # (set "entry" in script.json to disambiguate).
        if (-not $entry -and $ps1Files.Count -gt 0) { $entry = $ps1Files[0].FullName }

        if (-not $entry) { continue }

        $scriptArgs = @()
        if ($meta -and $meta.PSObject.Properties['args'] -and $meta.args) { $scriptArgs = @($meta.args | ForEach-Object { "$_" }) }
        $desc = ''
        if ($meta -and $meta.PSObject.Properties['description'] -and $meta.description) { $desc = [string]$meta.description }
        # optional per-script timeout — overrides the global runTimeoutMinutes
        $timeout = $null
        if ($meta -and $meta.PSObject.Properties['timeoutMinutes'] -and $null -ne ($meta.timeoutMinutes -as [double])) {
            $timeout = [double]$meta.timeoutMinutes
        }

        $scripts.Add([pscustomobject]@{
                Name           = $dir.Name
                Dir            = $dir.FullName
                Entry          = $entry
                Args           = $scriptArgs
                Description    = $desc
                TimeoutMinutes = $timeout
                EnvFile        = Join-Path $dir.FullName '.env'
                EnvExample     = Join-Path $dir.FullName '.env.example'
                ModuleDir      = Join-Path $paths.ModulesDir $dir.Name
            })
    }

    # loose .ps1 files in the repo root
    foreach ($file in (Get-ChildItem $root -File -Filter '*.ps1' | Sort-Object Name)) {
        $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        $scripts.Add([pscustomobject]@{
                Name           = $name
                Dir            = $root
                Entry          = $file.FullName
                Args           = @()
                Description    = ''
                TimeoutMinutes = $null
                EnvFile        = Join-Path $root "$name.env"
                EnvExample     = Join-Path $root "$name.env.example"
                ModuleDir      = Join-Path $paths.ModulesDir $name
            })
    }

    $scripts
}

Export-ModuleMember -Function Sync-PssRepo, Get-PssScripts, Get-PssLastSyncTime
