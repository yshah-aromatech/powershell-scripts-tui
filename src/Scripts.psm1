# Scripts.psm1 — scripts repo sync (clone / hard-reset) and script discovery.
# Supports multiple repos (config `repos`) and two runtimes: PowerShell (.ps1)
# and Python (.py), detected per script from the entry file extension.

# ---------------------------------------------------------------------------
# One-time layout migration: the legacy layout keeps the single clone at
# ScriptsDir itself; multi-repo clones live at ScriptsDir/<repoName>. When
# `repos` is configured and an old root-level clone exists, move it into the
# subdir of the repo it matches (by remote URL), else the first repo.
# ---------------------------------------------------------------------------
function Update-PssRepoLayout {
    param([scriptblock]$OnOutput = { param($line) })
    $paths = Get-PssPaths
    $repos = @(Get-PssRepos)
    if ($repos.Count -eq 0 -or $repos[0].Legacy) { return }
    if (-not (Test-Path (Join-Path $paths.ScriptsDir '.git'))) { return }

    $target = $repos[0]
    $remote = ''
    try { $remote = "$(git -C $paths.ScriptsDir remote get-url origin 2>$null)" } catch { }
    $normalize = { param($u) ($u -replace '//[^@/]+@', '//') -replace '\.git/?$', '' -replace '/+$', '' }
    foreach ($r in $repos) {
        if ((& $normalize $remote) -eq (& $normalize $r.Url)) { $target = $r; break }
    }

    & $OnOutput "migrating scripts clone to multi-repo layout: scripts/ -> scripts/$($target.Name)/"
    $tmp = "$($paths.ScriptsDir).migrating"
    try {
        Move-Item -LiteralPath $paths.ScriptsDir -Destination $tmp -Force
        New-Item -ItemType Directory -Path $paths.ScriptsDir -Force | Out-Null
        Move-Item -LiteralPath $tmp -Destination (Join-Path $paths.ScriptsDir $target.Name) -Force
    } catch {
        & $OnOutput "layout migration FAILED: $($_.Exception.Message) — sync will re-clone instead"
    }
}

# ---------------------------------------------------------------------------
# Repo sync: clone if missing, otherwise hard-reset to origin/<branch>.
# Local per-script .env files survive the reset/clean.
# ---------------------------------------------------------------------------
function Sync-PssOneRepo {
    param(
        [Parameter(Mandatory)]$Repo,
        [scriptblock]$OnOutput = { param($line) }
    )
    $emit = { param($l) & $OnOutput (Hide-PssSecret $l) }

    $url = $Repo.Url
    $token = $env:GITHUB_TOKEN
    if ($token -and $url -match '^https://' -and $url -notmatch '@') {
        $url = $url -replace '^https://', "https://x-access-token:$token@"
    }

    $dir = $Repo.Root
    $branch = $Repo.Branch

    if (-not (Test-Path (Join-Path $dir '.git'))) {
        & $emit "[$($Repo.Name)] cloning $($Repo.Url) (branch $branch)..."
        $gitOut = git clone --branch $branch $url $dir 2>&1
        foreach ($l in $gitOut) { if ("$l") { & $emit "$l" } }
        $ok = ($LASTEXITCODE -eq 0)
    } else {
        & $emit "[$($Repo.Name)] syncing $($Repo.Url) (hard reset to origin/$branch)..."
        git -C $dir remote set-url origin $url 2>&1 | Out-Null  # refresh token
        # each step's exit code is checked individually — a failed fetch (e.g.
        # expired token) must fail the sync, not be masked by a later step
        $steps = @(
            , @('fetch', 'origin')
            , @('checkout', $branch)
            , @('reset', '--hard', "origin/$branch")
            # clean untracked files but keep local .env files and python cruft
            # that regenerates on every run
            , @('clean', '-fdx', '-e', '.env', '-e', '**/.env', '-e', '__pycache__', '-e', '*.pyc')
        )
        $ok = $true
        foreach ($step in $steps) {
            $gitOut = git -C $dir @step 2>&1
            foreach ($l in $gitOut) { if ("$l") { & $emit "$l" } }
            if ($LASTEXITCODE -ne 0) {
                & $emit "[$($Repo.Name)] git $($step[0]) failed (exit $LASTEXITCODE)"
                $ok = $false
                break
            }
        }
    }

    & $emit $(if ($ok) { "[$($Repo.Name)] sync complete" } else { "[$($Repo.Name)] sync FAILED — check GITHUB_TOKEN in .env (the PAT needs Contents:Read on $($Repo.Url))" })
    $ok
}

function Sync-PssRepo {
    [CmdletBinding()]
    param([scriptblock]$OnOutput = { param($line) })

    $repos = @(Get-PssRepos | Where-Object Url)
    if ($repos.Count -eq 0) {
        & $OnOutput 'no scripts repo configured — set `repos` (or scriptsRepo) in config.json, or SCRIPTS_REPO in .env'
        return $false
    }
    Update-PssRepoLayout -OnOutput $OnOutput

    $allOk = $true
    foreach ($repo in $repos) {
        if (-not (Sync-PssOneRepo -Repo $repo -OnOutput $OnOutput)) { $allOk = $false }
    }
    $allOk
}

# When the scripts clones were last synced: FETCH_HEAD is touched by every
# fetch; a fresh clone (no fetch yet) falls back to the .git dir itself.
# Reflects syncs from any process (TUI, --sync, cron), not just this one.
function Get-PssLastSyncTime {
    $latest = $null
    foreach ($repo in @(Get-PssRepos)) {
        foreach ($p in (Join-Path $repo.Root '.git/FETCH_HEAD'), (Join-Path $repo.Root '.git')) {
            if (Test-Path $p) {
                $t = (Get-Item -Force $p).LastWriteTime
                if (-not $latest -or $t -gt $latest) { $latest = $t }
                break
            }
        }
    }
    $latest
}

# ---------------------------------------------------------------------------
# Discovery — one folder per script, plus loose .ps1/.py files in each repo
# root. Runtime is detected from the entry file extension. Entry resolution:
# script.json "entry" wins; else conventional PowerShell names, else
# conventional Python names, else the sole/first script file of either kind.
# ---------------------------------------------------------------------------
$script:SkipDirs = @('.git', '.github', '__pycache__', '.venv', 'node_modules')

function Resolve-PssEntry {
    # returns the entry file's full path, or $null
    param([string]$DirPath, [string]$DirName, $Meta)

    if ($Meta -and $Meta.PSObject.Properties['entry'] -and $Meta.entry) {
        $p = Join-Path $DirPath ([string]$Meta.entry)
        if (Test-Path $p) { return (Resolve-Path -LiteralPath $p).Path }
    }

    # matched/compared case-insensitively because the server FS is case-sensitive
    $files = @(Get-ChildItem $DirPath -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $ps1 = @($files | Where-Object { $_.Extension -ieq '.ps1' })
    $py = @($files | Where-Object { $_.Extension -ieq '.py' })

    foreach ($c in 'main.ps1', "$DirName.ps1", 'run.ps1') {
        $m = $ps1 | Where-Object { $_.Name -ieq $c } | Select-Object -First 1
        if ($m) { return $m.FullName }
    }
    foreach ($c in 'main.py', "$DirName.py", 'run.py', '__main__.py') {
        $m = $py | Where-Object { $_.Name -ieq $c } | Select-Object -First 1
        if ($m) { return $m.FullName }
    }
    # no conventional entry — sole (or first alphabetical) file of either kind,
    # PowerShell preferred; set "entry" in script.json to disambiguate
    if ($ps1.Count -gt 0) { return $ps1[0].FullName }
    if ($py.Count -gt 0) { return $py[0].FullName }
    $null
}

function Get-PssRuntime {
    param([string]$Entry)
    if ([IO.Path]::GetExtension($Entry) -ieq '.py') { 'python' } else { 'powershell' }
}

function New-PssScriptInfo {
    param([string]$Name, [string]$Dir, [string]$Entry, $Meta, [string]$RepoName, [string]$EnvBase)
    $paths = Get-PssPaths

    $scriptArgs = @()
    if ($Meta -and $Meta.PSObject.Properties['args'] -and $Meta.args) { $scriptArgs = @($Meta.args | ForEach-Object { "$_" }) }
    $desc = ''
    if ($Meta -and $Meta.PSObject.Properties['description'] -and $Meta.description) { $desc = [string]$Meta.description }
    # optional per-script timeout — overrides the global runTimeoutMinutes
    $timeout = $null
    if ($Meta -and $Meta.PSObject.Properties['timeoutMinutes'] -and $null -ne ($Meta.timeoutMinutes -as [double])) {
        $timeout = [double]$Meta.timeoutMinutes
    }

    [pscustomobject]@{
        Name           = $Name
        Dir            = $Dir
        Entry          = $Entry
        Runtime        = Get-PssRuntime $Entry
        Repo           = $RepoName
        Args           = $scriptArgs
        Description    = $desc
        TimeoutMinutes = $timeout
        # folder scripts use '<dir>/.env'; loose files use '<name>.env' beside them
        EnvFile        = Join-Path $Dir $(if ($EnvBase) { "$EnvBase.env" } else { '.env' })
        EnvExample     = Join-Path $Dir $(if ($EnvBase) { "$EnvBase.env.example" } else { '.env.example' })
        ModuleDir      = Join-Path $paths.ModulesDir $Name
        VenvDir        = Join-Path $paths.VenvsDir $Name
    }
}

function Get-PssScripts {
    $scripts = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($repo in @(Get-PssRepos)) {
        $root = $repo.Root
        if (-not (Test-Path $root)) { continue }

        foreach ($dir in (Get-ChildItem $root -Directory | Where-Object Name -notin $script:SkipDirs | Sort-Object Name)) {
            $meta = $null
            $metaFile = Join-Path $dir.FullName 'script.json'
            if (Test-Path $metaFile) {
                try { $meta = Get-Content $metaFile -Raw | ConvertFrom-Json } catch { }
            }
            $entry = Resolve-PssEntry -DirPath $dir.FullName -DirName $dir.Name -Meta $meta
            if (-not $entry) { continue }

            # identity is the folder name; a cross-repo duplicate gets a stable
            # qualified name (locks/history/cron/log files all key on Name)
            $name = $dir.Name
            if (-not $seen.Add($name)) {
                $name = "$($repo.Name)-$($dir.Name)"
                [void]$seen.Add($name)
                Write-Verbose "duplicate script folder '$($dir.Name)' — qualified as '$name'"
            }
            $scripts.Add((New-PssScriptInfo -Name $name -Dir $dir.FullName -Entry $entry -Meta $meta -RepoName $repo.Name -EnvBase ''))
        }

        # loose .ps1/.py files in the repo root
        foreach ($file in (Get-ChildItem $root -File | Where-Object { $_.Extension -in '.ps1', '.py' } | Sort-Object Name)) {
            $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
            if (-not $seen.Add($name)) {
                $name = "$($repo.Name)-$([IO.Path]::GetFileNameWithoutExtension($file.Name))"
                [void]$seen.Add($name)
            }
            $scripts.Add((New-PssScriptInfo -Name $name -Dir $root -Entry $file.FullName -Meta $null -RepoName $repo.Name -EnvBase ([IO.Path]::GetFileNameWithoutExtension($file.Name))))
        }
    }

    $scripts
}

# ---------------------------------------------------------------------------
# Script detail — everything an agent (or human) needs to call a script:
# README, documented .env keys, and — for PowerShell — the param() block
# parsed from the AST (never executed).
# ---------------------------------------------------------------------------
function Get-PssScriptParameters {
    # PowerShell entry -> list of @{ Name; Type; Mandatory; Default;
    # ValidateSet; IsSwitch; Description }, plus Help/Warnings via -Detail
    param([Parameter(Mandatory)][string]$Entry)
    $params = [System.Collections.Generic.List[object]]::new()
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Entry, [ref]$tokens, [ref]$errors)
    $help = $null
    try { $help = $ast.GetHelpContent() } catch { }

    if ($ast.ParamBlock) {
        foreach ($p in @($ast.ParamBlock.Parameters)) {
            $name = $p.Name.VariablePath.UserPath
            $type = "$($p.StaticType.Name)"
            $default = if ($p.DefaultValue) { $p.DefaultValue.Extent.Text } else { $null }
            $mandatory = $false
            $validateSet = @()
            foreach ($attr in $p.Attributes) {
                if ($attr -isnot [System.Management.Automation.Language.AttributeAst]) { continue }
                if ($attr.TypeName.Name -match '^Parameter') {
                    foreach ($na in @($attr.NamedArguments)) {
                        if ($na.ArgumentName -eq 'Mandatory' -and
                            ($na.ExpressionOmitted -or "$($na.Argument.Extent.Text)" -match '\$true|^1$')) {
                            $mandatory = $true
                        }
                    }
                } elseif ($attr.TypeName.Name -match '^ValidateSet') {
                    $validateSet = @($attr.PositionalArguments |
                            Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] } |
                            ForEach-Object Value)
                }
            }
            $desc = ''
            if ($help -and $help.Parameters -and $help.Parameters.ContainsKey($name.ToUpperInvariant())) {
                $desc = ("$($help.Parameters[$name.ToUpperInvariant()])").Trim()
            }
            $params.Add([pscustomobject]@{
                    Name        = $name
                    Type        = $type
                    Mandatory   = $mandatory
                    Default     = $default
                    ValidateSet = $validateSet
                    IsSwitch    = ($type -eq 'SwitchParameter')
                    Description = $desc
                })
        }
    }
    [pscustomobject]@{
        Parameters    = $params
        Synopsis      = $(if ($help -and $help.Synopsis) { "$($help.Synopsis)".Trim() } else { '' })
        Help          = $(if ($help -and $help.Description) { "$($help.Description)".Trim() } else { '' })
        ParseWarnings = @($errors).Count
    }
}

function Get-PssScriptDetail {
    param([Parameter(Mandatory)]$Script)
    $isPython = ("$($Script.Runtime)" -eq 'python')

    # README.md (case-insensitive; server FS is case-sensitive), capped 16KB
    $readme = ''
    $readmeFile = Get-ChildItem $Script.Dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq 'readme.md' } | Select-Object -First 1
    if ($readmeFile) {
        $readme = Get-Content $readmeFile.FullName -Raw -ErrorAction SilentlyContinue
        if ($readme.Length -gt 16KB) { $readme = $readme.Substring(0, 16KB) + "`n[truncated]" }
    }

    # documented env vars from .env.example; configured = key NAMES only
    $envExample = @(Read-PssEnvDoc -Path $Script.EnvExample | ForEach-Object {
            [ordered]@{ key = $_.Key; default = $_.Default; comment = $_.Comment }
        })
    $envConfigured = @((Read-PssEnvFile $Script.EnvFile).Keys)

    $detail = [ordered]@{
        name           = $Script.Name
        description    = "$($Script.Description)"
        runtime        = "$($Script.Runtime)"
        repo           = "$($Script.Repo)"
        entry          = [IO.Path]::GetFileName("$($Script.Entry)")
        timeoutMinutes = $Script.TimeoutMinutes
        defaultArgs    = @($Script.Args)
        readme         = "$readme"
        envExample     = $envExample
        envConfigured  = $envConfigured
    }

    if ($isPython) {
        $detail.parameters = @()
        $detail.parameterSource = 'none — see readme'
        $detail.argsHint = 'Python: pass args as e.g. --flag value; see readme for supported options'
    } else {
        $scan = Get-PssScriptParameters -Entry $Script.Entry
        $detail.parameters = @($scan.Parameters | ForEach-Object {
                [ordered]@{
                    name        = $_.Name
                    type        = $_.Type
                    mandatory   = $_.Mandatory
                    default     = $_.Default
                    validateSet = @($_.ValidateSet)
                    isSwitch    = $_.IsSwitch
                    description = $_.Description
                }
            })
        $detail.parameterSource = 'param() block (PowerShell AST)'
        if ($scan.Synopsis -or $scan.Help) {
            $detail.help = [ordered]@{ synopsis = $scan.Synopsis; description = $scan.Help }
        }
        if ($scan.ParseWarnings) { $detail.parseWarnings = $scan.ParseWarnings }
        $detail.argsHint = 'PowerShell: -ParamName value, switches as bare -SwitchName; quote values with spaces'
    }
    $detail
}

Export-ModuleMember -Function Sync-PssRepo, Sync-PssOneRepo, Update-PssRepoLayout, Get-PssScripts, Get-PssLastSyncTime,
Get-PssScriptDetail, Get-PssScriptParameters
