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
    $gitOut = $null

    if (-not (Test-Path (Join-Path $dir '.git'))) {
        & $emit "cloning $repo (branch $branch)..."
        $gitOut = git clone --branch $branch $url $dir 2>&1
    } else {
        & $emit "syncing $repo (hard reset to origin/$branch)..."
        git -C $dir remote set-url origin $url 2>&1 | Out-Null  # refresh token
        $gitOut = @(
            git -C $dir fetch origin 2>&1
            git -C $dir checkout $branch 2>&1
            git -C $dir reset --hard "origin/$branch" 2>&1
            # clean untracked files but keep local .env files
            git -C $dir clean -fdx -e '.env' -e '**/.env' 2>&1
        )
    }
    foreach ($l in $gitOut) { if ("$l") { & $emit "$l" } }

    $ok = ($LASTEXITCODE -eq 0)
    & $emit $(if ($ok) { 'sync complete' } else { "sync FAILED (exit $LASTEXITCODE) — check GITHUB_TOKEN in .env" })
    $ok
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
        $candidates = @()
        if ($meta -and $meta.PSObject.Properties['entry'] -and $meta.entry) { $candidates += [string]$meta.entry }
        $candidates += 'main.ps1', "$($dir.Name).ps1", 'run.ps1'
        foreach ($c in $candidates) {
            $p = Join-Path $dir.FullName $c
            if (Test-Path $p) { $entry = $p; break }
        }
        if (-not $entry) { continue }

        $scriptArgs = @()
        if ($meta -and $meta.PSObject.Properties['args'] -and $meta.args) { $scriptArgs = @($meta.args | ForEach-Object { "$_" }) }
        $desc = ''
        if ($meta -and $meta.PSObject.Properties['description'] -and $meta.description) { $desc = [string]$meta.description }

        $scripts.Add([pscustomobject]@{
                Name        = $dir.Name
                Dir         = $dir.FullName
                Entry       = $entry
                Args        = $scriptArgs
                Description = $desc
                EnvFile     = Join-Path $dir.FullName '.env'
                EnvExample  = Join-Path $dir.FullName '.env.example'
                ModuleDir   = Join-Path $paths.ModulesDir $dir.Name
            })
    }

    # loose .ps1 files in the repo root
    foreach ($file in (Get-ChildItem $root -File -Filter '*.ps1' | Sort-Object Name)) {
        $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        $scripts.Add([pscustomobject]@{
                Name        = $name
                Dir         = $root
                Entry       = $file.FullName
                Args        = @()
                Description = ''
                EnvFile     = Join-Path $root "$name.env"
                EnvExample  = Join-Path $root "$name.env.example"
                ModuleDir   = Join-Path $paths.ModulesDir $name
            })
    }

    $scripts
}

Export-ModuleMember -Function Sync-PssRepo, Get-PssScripts
