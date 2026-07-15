# Deps.psm1 — automatic dependency detection and per-script isolation for
# both runtimes: PowerShell scripts get AST-scanned module deps + a module
# dir prepended to PSModulePath; Python scripts get import-scanned pip deps
# + a per-script venv. Get-StoMissingDeps/Get-StoInstallCommand dispatch on
# Script.Runtime so callers don't care which is which.

# Modules that ship with PowerShell 7 / are always available — never installed.
$script:BuiltinModules = @(
    'Microsoft.PowerShell.Archive', 'Microsoft.PowerShell.Core',
    'Microsoft.PowerShell.Diagnostics', 'Microsoft.PowerShell.Host',
    'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Security',
    'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.PSResourceGet',
    'PSReadLine', 'PackageManagement', 'PowerShellGet', 'ThreadJob',
    'CimCmdlets', 'PSDiagnostics', 'Microsoft.WSMan.Management'
)

# Common "imported name" -> "gallery name" mismatches (cv2->opencv-python analog)
$script:ModuleNameMap = @{
    'pester'  = 'Pester'
    'az'      = 'Az'
    'awstools' = 'AWS.Tools.Common'
    'awspowershell' = 'AWSPowerShell.NetCore'
    'sqlps'   = 'SqlServer'
}

# A dependency is a small object: Name plus optional version constraints
# (RequiredVersion exact, MinimumVersion/MaximumVersion bounds — only
# #Requires -Modules hashtable syntax carries versions). Display is the
# human-readable form used in prompts and output.
function New-StoDep {
    param([string]$Name, [string]$RequiredVersion, [string]$MinimumVersion, [string]$MaximumVersion)
    $disp = $Name
    if ($RequiredVersion) { $disp = "$Name (=$RequiredVersion)" }
    elseif ($MinimumVersion -and $MaximumVersion) { $disp = "$Name (>=$MinimumVersion,<=$MaximumVersion)" }
    elseif ($MinimumVersion) { $disp = "$Name (>=$MinimumVersion)" }
    elseif ($MaximumVersion) { $disp = "$Name (<=$MaximumVersion)" }
    [pscustomobject]@{
        Name            = $Name
        RequiredVersion = $RequiredVersion
        MinimumVersion  = $MinimumVersion
        MaximumVersion  = $MaximumVersion
        Display         = $disp
    }
}

# ---------------------------------------------------------------------------
# Scan a script's source for module dependencies:
#   - #Requires -Modules ...   (versions honored)
#   - using module ...
#   - Import-Module / ipmo calls
# Local files (paths, .psm1/.psd1 in the script folder) and builtins excluded.
# ---------------------------------------------------------------------------
function Get-StoScriptDeps {
    param([Parameter(Mandatory)]$Script)

    # name(lower) -> version spec; a versioned mention wins over a bare one
    $deps = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $addDep = {
        param([string]$Name, [string]$Rv = '', [string]$MinV = '', [string]$MaxV = '')
        if (-not $Name) { return }
        $spec = @{ Name = $Name; Rv = $Rv; MinV = $MinV; MaxV = $MaxV }
        if (-not $deps.ContainsKey($Name) -or ($Rv -or $MinV -or $MaxV)) { $deps[$Name] = $spec }
    }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script.Entry, [ref]$tokens, [ref]$errors)
    if (-not $ast) { return @() }

    # #Requires -Modules (ModuleSpecification: Version = minimum)
    if ($ast.ScriptRequirements -and $ast.ScriptRequirements.RequiredModules) {
        foreach ($m in $ast.ScriptRequirements.RequiredModules) {
            & $addDep $m.Name "$($m.RequiredVersion)" "$($m.Version)" "$($m.MaximumVersion)"
        }
    }

    # using module X
    if ($ast.UsingStatements) {
        foreach ($u in $ast.UsingStatements) {
            if ($u.UsingStatementKind -eq 'Module' -and $u.Name) { & $addDep $u.Name.Value }
        }
    }

    # Import-Module X / Import-Module -Name X
    $calls = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -in @('Import-Module', 'ipmo')
        }, $true)
    # parameters that consume the following element as their value (so it must NOT
    # be mistaken for a module name). Includes Import-Module's own value parameters
    # plus the common parameters (and their aliases) — e.g. `-ErrorAction Stop`,
    # `-ErrorVariable e`, whose string values were being picked up as module names.
    $valueParams = @(
        'Function', 'Cmdlet', 'Variable', 'Alias', 'Prefix', 'MinimumVersion',
        'MaximumVersion', 'RequiredVersion', 'ArgumentList', 'Args', 'FullyQualifiedName',
        'Scope', 'PSSession', 'CimSession', 'CimResourceUri', 'CimNamespace',
        # common parameters that take a value
        'ErrorAction', 'ea', 'WarningAction', 'wa', 'InformationAction', 'infa',
        'ProgressAction', 'proga', 'ErrorVariable', 'ev', 'WarningVariable', 'wv',
        'InformationVariable', 'iv', 'OutVariable', 'ov', 'OutBuffer', 'ob',
        'PipelineVariable', 'pv'
    )
    foreach ($call in $calls) {
        $elements = $call.CommandElements
        $gotName = $false   # Import-Module's only positional is Name (position 0)
        for ($i = 1; $i -lt $elements.Count; $i++) {
            $el = $elements[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                if ($el.Argument) { continue }                       # -Param:value form
                if ($el.ParameterName -eq 'Name') { continue }       # next element is the name(s)
                if ($valueParams -contains $el.ParameterName) { $i++ } # skip this parameter's value
                continue                                             # switches consume nothing
            }
            # bare positional element — only the first one carries module name(s);
            # anything later is a stray value, not a second module to install.
            if (-not $gotName) {
                foreach ($name in (Resolve-StoModuleElement $el)) { & $addDep $name }
                $gotName = $true
            }
        }
    }

    # filter: local paths and builtins
    $result = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($spec in $deps.Values) {
        $d = [string]$spec.Name
        if (-not $d) { continue }
        if ($d -match '[/\\]' -or $d -match '\.(psm1|psd1|dll)$') { continue }   # local/path import
        if ($script:BuiltinModules -contains $d) { continue }
        if (Test-Path (Join-Path $Script.Dir "$d.psm1")) { continue }            # local module next to script
        if (Test-Path (Join-Path $Script.Dir $d)) { continue }                   # local module folder
        $mapped = if ($script:ModuleNameMap.ContainsKey($d.ToLower())) { $script:ModuleNameMap[$d.ToLower()] } else { $d }
        if ($seen.Add($mapped)) {
            $result.Add((New-StoDep -Name $mapped -RequiredVersion $spec.Rv -MinimumVersion $spec.MinV -MaximumVersion $spec.MaxV))
        }
    }
    $result | Sort-Object Name
}

function Resolve-StoModuleElement {
    param($Element)
    $names = @()
    if ($Element -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        $names += $Element.Value
    } elseif ($Element -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        foreach ($e in $Element.Elements) {
            if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $names += $e.Value }
        }
    }
    $names
}

# ---------------------------------------------------------------------------
# What's missing = declared deps minus (script module dir + system modules),
# with version constraints checked against the installed versions.
# ---------------------------------------------------------------------------
function Get-StoInstalledModules {
    # name(lower) -> list of installed [version]s (0.0 when unknown)
    param([Parameter(Mandatory)]$Script)
    $installed = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $add = {
        param([string]$Name, $Version)
        if (-not $installed.ContainsKey($Name)) { $installed[$Name] = [System.Collections.Generic.List[version]]::new() }
        $v = $Version -as [version]
        if ($null -eq $v) { $v = [version]'0.0' }
        $installed[$Name].Add($v)
    }
    if (Test-Path $Script.ModuleDir) {
        foreach ($d in (Get-ChildItem $Script.ModuleDir -Directory -ErrorAction SilentlyContinue)) {
            # Save-PSResource/Save-Module layout: <ModuleDir>/<Name>/<Version>/
            $verDirs = @(Get-ChildItem $d.FullName -Directory -ErrorAction SilentlyContinue |
                Where-Object { $null -ne ($_.Name -as [version]) })
            if ($verDirs) { foreach ($vd in $verDirs) { & $add $d.Name $vd.Name } }
            else { & $add $d.Name $null }
        }
    }
    foreach ($m in (Get-Module -ListAvailable -ErrorAction SilentlyContinue)) {
        & $add $m.Name $m.Version
    }
    $installed
}

function Test-StoDepSatisfied {
    param([Parameter(Mandatory)]$Dep, [Parameter(Mandatory)]$Installed)
    if (-not $Installed.ContainsKey($Dep.Name)) { return $false }
    $versions = $Installed[$Dep.Name]
    if ($Dep.RequiredVersion) {
        $rv = $Dep.RequiredVersion -as [version]
        if ($null -eq $rv) { return $true }   # unparseable constraint — assume ok
        return [bool]($versions | Where-Object { $_ -eq $rv })
    }
    $min = $Dep.MinimumVersion -as [version]
    $max = $Dep.MaximumVersion -as [version]
    if (-not $min -and -not $max) { return $true }
    [bool]($versions | Where-Object { (-not $min -or $_ -ge $min) -and (-not $max -or $_ -le $max) })
}

function Get-StoMissingDeps {
    param([Parameter(Mandatory)]$Script)
    if (Test-StoPythonScript $Script) { return @(Get-StoMissingPythonDeps -Script $Script) }
    $deps = @(Get-StoScriptDeps -Script $Script)
    if (-not $deps) { return @() }
    $installed = Get-StoInstalledModules -Script $Script
    @($deps | Where-Object { -not (Test-StoDepSatisfied -Dep $_ -Installed $installed) })
}

# ---------------------------------------------------------------------------
# Build the pwsh -Command string that installs modules into the script's
# module dir. Run as a streamed task so the TUI shows live progress.
# ---------------------------------------------------------------------------
function Get-StoInstallCommand {
    # $Modules: dep objects from Get-StoScriptDeps/Get-StoMissingDeps (plain
    # strings also accepted — treated as unversioned names)
    param([Parameter(Mandatory)]$Script, [Parameter(Mandatory)][object[]]$Modules)
    if (Test-StoPythonScript $Script) { return Get-StoPythonInstallCommand -Script $Script -Deps $Modules }
    if (-not (Test-Path $Script.ModuleDir)) {
        New-Item -ItemType Directory -Path $Script.ModuleDir -Force | Out-Null
    }
    $dir = $Script.ModuleDir
    $specs = ($Modules | ForEach-Object {
            $m = if ($_ -is [string]) { New-StoDep -Name $_ } else { $_ }
            $n = [string]$m.Name -replace "'", "''"
            "@{ Name='$n'; Rv='$($m.RequiredVersion)'; MinV='$($m.MinimumVersion)'; MaxV='$($m.MaximumVersion)' }"
        }) -join ', '
    @"
`$ErrorActionPreference = 'Continue'
`$ok = `$true
foreach (`$m in @($specs)) {
    Write-Host "installing `$(`$m.Name) `$(if (`$m.Rv) { `$m.Rv } elseif (`$m.MinV -or `$m.MaxV) { "(`$(`$m.MinV)-`$(`$m.MaxV))" }) -> $dir"
    try {
        if (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
            `$p = @{ Name = `$m.Name; Path = '$dir'; Repository = 'PSGallery'; TrustRepository = `$true; ErrorAction = 'Stop' }
            if (`$m.Rv) { `$p.Version = `$m.Rv }
            elseif (`$m.MinV -and `$m.MaxV) { `$p.Version = "[`$(`$m.MinV),`$(`$m.MaxV)]" }
            elseif (`$m.MinV) { `$p.Version = "[`$(`$m.MinV),)" }
            elseif (`$m.MaxV) { `$p.Version = "(,`$(`$m.MaxV)]" }
            Save-PSResource @p
        } else {
            `$p = @{ Name = `$m.Name; Path = '$dir'; Repository = 'PSGallery'; Force = `$true; ErrorAction = 'Stop' }
            if (`$m.Rv) { `$p.RequiredVersion = `$m.Rv }
            if (`$m.MinV) { `$p.MinimumVersion = `$m.MinV }
            if (`$m.MaxV) { `$p.MaximumVersion = `$m.MaxV }
            Save-Module @p
        }
        Write-Host "`$(`$m.Name) installed"
    } catch {
        Write-Host "FAILED to install `$(`$m.Name) : `$(`$_.Exception.Message)"
        `$ok = `$false
    }
}
if (-not `$ok) { exit 1 }
"@
}

# pwsh -Command string that re-saves the latest version of every module in
# every per-script module dir (used by the system update action).
function Get-StoModuleUpgradeCommand {
    $paths = Get-StoPaths
    @"
`$root = '$($paths.ModulesDir)'
if (-not (Test-Path `$root)) { Write-Host 'no module dirs yet'; exit 0 }
foreach (`$scriptDir in Get-ChildItem `$root -Directory) {
    foreach (`$mod in Get-ChildItem `$scriptDir.FullName -Directory) {
        Write-Host "upgrading `$(`$mod.Name) in `$(`$scriptDir.Name)"
        try {
            if (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
                Save-PSResource -Name `$mod.Name -Path `$scriptDir.FullName -Repository PSGallery -TrustRepository -ErrorAction Stop
            } else {
                Save-Module -Name `$mod.Name -Path `$scriptDir.FullName -Repository PSGallery -Force -ErrorAction Stop
            }
        } catch { Write-Host "  failed: `$(`$_.Exception.Message)" }
    }
}
Write-Host 'module upgrade complete'
"@
}

# ===========================================================================
# Python runtime: per-script venvs + import-scanned pip dependencies.
# Ported from python-scripts-tui (src/lib/imports.ts, venv.ts, system.ts).
# POSIX-only (venv at <VenvDir>/bin/python), same stance as /proc sampling.
# ===========================================================================

function Test-StoPythonScript {
    param($Script)
    $null -ne $Script.PSObject.Properties['Runtime'] -and "$($Script.Runtime)" -eq 'python'
}

# Import name -> pip package name, for the common cases where they differ.
# Anything not in this table is installed under its import name.
# Carried verbatim from python-scripts-tui — every entry was earned.
$script:PipNameMap = @{
    'cv2'         = 'opencv-python'
    'PIL'         = 'pillow'
    'sklearn'     = 'scikit-learn'
    'skimage'     = 'scikit-image'
    'bs4'         = 'beautifulsoup4'
    'yaml'        = 'pyyaml'
    'dotenv'      = 'python-dotenv'
    'dateutil'    = 'python-dateutil'
    'Crypto'      = 'pycryptodome'
    'nacl'        = 'pynacl'
    'serial'      = 'pyserial'
    'usb'         = 'pyusb'
    'psycopg2'    = 'psycopg2-binary'
    'MySQLdb'     = 'mysqlclient'
    'git'         = 'GitPython'
    'github'      = 'PyGithub'
    'jwt'         = 'PyJWT'
    'docx'        = 'python-docx'
    'pptx'        = 'python-pptx'
    'fitz'        = 'PyMuPDF'
    'magic'       = 'python-magic'
    'websocket'   = 'websocket-client'
    'websockets'  = 'websockets'
    'telegram'    = 'python-telegram-bot'
    'kafka'       = 'kafka-python'
    'zmq'         = 'pyzmq'
    'OpenSSL'     = 'pyopenssl'
    'Levenshtein' = 'python-Levenshtein'
    'gi'          = 'PyGObject'
    'cairo'       = 'pycairo'
    'win32api'    = 'pywin32'
    'attr'        = 'attrs'
    'google'      = 'google-api-python-client'
}

function Get-StoPipName {
    param([string]$Module)
    if ($script:PipNameMap.ContainsKey($Module)) { $script:PipNameMap[$Module] } else { $Module }
}

# Python scanner, executed with the script's venv interpreter so importlib
# reflects exactly what is installed inside that venv. Walks every .py file
# in the script folder, collects top-level imports via AST, filters stdlib
# and local modules, then checks availability. Verbatim SCANNER_PY port.
$script:PythonScanner = @'
import ast, json, os, sys, importlib.util

script_dir = sys.argv[1]
stdlib = set(getattr(sys, "stdlib_module_names", set())) | {"__future__"}

local, imports = set(), set()
for root, dirs, files in os.walk(script_dir):
    dirs[:] = [d for d in dirs if not d.startswith((".", "__"))]
    for d in dirs:
        local.add(d)
    for f in files:
        if f.endswith(".py"):
            local.add(os.path.splitext(f)[0])

for root, dirs, files in os.walk(script_dir):
    dirs[:] = [d for d in dirs if not d.startswith((".", "__"))]
    for f in files:
        if not f.endswith(".py"):
            continue
        try:
            with open(os.path.join(root, f), encoding="utf-8", errors="replace") as fh:
                tree = ast.parse(fh.read())
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for a in node.names:
                    imports.add(a.name.split(".")[0])
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                imports.add(node.module.split(".")[0])

third_party = sorted(m for m in imports if m and m not in stdlib and m not in local)
missing, installed = [], []
for m in third_party:
    try:
        spec = importlib.util.find_spec(m)
    except (ImportError, ValueError, ModuleNotFoundError):
        spec = None
    (installed if spec else missing).append(m)

print(json.dumps({"missing": missing, "installed": installed}))
'@

function Get-StoVenvPython {
    param([Parameter(Mandatory)]$Script)
    Join-Path $Script.VenvDir 'bin/python'
}

function Test-StoVenv {
    param([Parameter(Mandatory)]$Script)
    Test-Path (Get-StoVenvPython -Script $Script)
}

# Requirements.txt package names (comments/options/version specifiers stripped)
function Get-StoRequirementsFile {
    param([Parameter(Mandatory)]$Script)
    $p = Join-Path $Script.Dir 'requirements.txt'
    if (Test-Path $p) { $p } else { $null }
}

function Read-StoRequirements {
    param([Parameter(Mandatory)][string]$Path)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-Content $Path -ErrorAction SilentlyContinue)) {
        $t = "$line".Trim()
        if (-not $t -or $t.StartsWith('#') -or $t.StartsWith('-')) { continue }
        # strip environment markers, extras and version specifiers
        $name = ($t -split '[;\[<>=!~ ]')[0].Trim()
        if ($name) { $names.Add($name) }
    }
    $names
}

# Missing python deps as dep objects (Name = import/pip name, PipName = what
# to install). A missing venv means nothing is installed yet, so everything
# third-party is missing; the scanner still runs (with the system python) to
# FIND the imports, its installed/missing split is just ignored then.
function Get-StoMissingPythonDeps {
    param([Parameter(Mandatory)]$Script)
    $cfg = Get-StoConfig
    $hasVenv = Test-StoVenv -Script $Script

    $reqFile = Get-StoRequirementsFile -Script $Script
    if ($reqFile) {
        $wanted = @(Read-StoRequirements -Path $reqFile)
        if (-not $wanted) { return @() }
        $have = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if ($hasVenv) {
            try {
                $json = & (Get-StoVenvPython -Script $Script) -m pip list --format=json 2>$null
                foreach ($p in ("$json" | ConvertFrom-Json)) { [void]$have.Add(("$($p.name)" -replace '_', '-')) }
            } catch { }
        }
        return @($wanted | Where-Object { -not $have.Contains(($_ -replace '_', '-')) } | ForEach-Object {
                $d = New-StoDep -Name $_
                $d | Add-Member -NotePropertyName PipName -NotePropertyValue $_ -PassThru
            })
    }

    $py = if ($hasVenv) { Get-StoVenvPython -Script $Script } else { [string]$cfg.pythonBin }
    if (-not (Get-Command $py -ErrorAction SilentlyContinue) -and -not (Test-Path $py)) { return @() }
    $out = & $py -c $script:PythonScanner $Script.Dir 2>&1
    if ($LASTEXITCODE -ne 0) { return @() }
    $last = @($out)[-1]
    $scan = $null
    try { $scan = "$last" | ConvertFrom-Json } catch { return @() }

    $missing = if ($hasVenv) { @($scan.missing) } else { @($scan.missing) + @($scan.installed) }
    @($missing | Sort-Object | ForEach-Object {
            $pip = Get-StoPipName $_
            $d = New-StoDep -Name $_
            if ($pip -ne $_) { $d.Display = "$_ (pip: $pip)" }
            $d | Add-Member -NotePropertyName PipName -NotePropertyValue $pip -PassThru
        })
}

# pwsh -Command string that ensures the venv exists then pip-installs the
# packages (or requirements.txt when present) — same streamed-task calling
# convention as the module install command.
function Get-StoPythonInstallCommand {
    param([Parameter(Mandatory)]$Script, [object[]]$Deps = @())
    $cfg = Get-StoConfig
    $venv = $Script.VenvDir -replace "'", "''"
    $py = (Get-StoVenvPython -Script $Script) -replace "'", "''"
    $pythonBin = ([string]$cfg.pythonBin) -replace "'", "''"

    $reqFile = Get-StoRequirementsFile -Script $Script
    $installLine = if ($reqFile) {
        "& '$py' -m pip install -r '$($reqFile -replace "'", "''")'"
    } else {
        $pkgs = @($Deps | ForEach-Object {
                if ($_ -is [string]) { Get-StoPipName $_ }
                elseif ($null -ne $_.PSObject.Properties['PipName']) { [string]$_.PipName }
                else { Get-StoPipName ([string]$_.Name) }
            } | Select-Object -Unique)
        if ($pkgs.Count -eq 0) { 'Write-Host "nothing to install"' }
        else {
            $list = ($pkgs | ForEach-Object { "'$($_ -replace "'", "''")'" }) -join ', '
            "& '$py' -m pip install @($list)"
        }
    }

    @"
`$ErrorActionPreference = 'Continue'
if (-not (Test-Path '$py')) {
    Write-Host "creating venv -> $venv"
    & '$pythonBin' -m venv '$venv'
    if (`$LASTEXITCODE -ne 0) { Write-Host 'FAILED to create venv (is python3-venv installed?)'; exit 1 }
    & '$py' -m pip install --upgrade pip --quiet
}
$installLine
if (`$LASTEXITCODE -ne 0) { Write-Host 'pip install FAILED'; exit 1 }
Write-Host 'python deps installed'
"@
}

# pwsh -Command string that upgrades the system pip (PEP 668 aware), then
# pip + all outdated packages in every script venv (python counterpart of
# Get-StoModuleUpgradeCommand; port of python-scripts-tui system.ts).
function Get-StoVenvUpgradeCommand {
    $paths = Get-StoPaths
    $cfg = Get-StoConfig
    $pythonBin = ([string]$cfg.pythonBin) -replace "'", "''"
    @"
if (Get-Command '$pythonBin' -ErrorAction SilentlyContinue) {
    Write-Host 'upgrading system pip...'
    & '$pythonBin' -m pip install --upgrade pip --quiet 2>&1 | Out-Null
    if (`$LASTEXITCODE -ne 0) {
        # Ubuntu 23.04+ PEP 668 managed environment
        & '$pythonBin' -m pip install --upgrade pip --quiet --break-system-packages 2>&1 | Out-Null
        Write-Host `$(if (`$LASTEXITCODE -eq 0) { 'system pip upgraded (--break-system-packages)' } else { 'WARNING: system pip upgrade failed (non-fatal)' })
    } else { Write-Host 'system pip upgraded' }
}
`$root = '$($paths.VenvsDir -replace "'", "''")'
if (-not (Test-Path `$root)) { Write-Host 'no venvs yet'; exit 0 }
`$venvs = @(Get-ChildItem `$root -Directory | Where-Object { Test-Path (Join-Path `$_.FullName 'bin/python') })
if (`$venvs.Count -eq 0) { Write-Host 'no venvs to upgrade yet'; exit 0 }
`$broken = `$false
foreach (`$v in `$venvs) {
    `$py = Join-Path `$v.FullName 'bin/python'
    Write-Host "'`$(`$v.Name)': upgrading pip..."
    & `$py -m pip install --upgrade pip --quiet
    # --not-required: only TOP-LEVEL packages. Explicitly upgrading a
    # dependency (e.g. pydantic-core, which pydantic pins exactly) forces it
    # past its parent's pin and breaks the venv; upgrading the parents lets
    # the resolver pull matching dependency versions.
    `$outdated = & `$py -m pip list --outdated --not-required --format=json 2>`$null
    `$pkgs = @()
    try { `$pkgs = @(("`$outdated" | ConvertFrom-Json) | ForEach-Object name) } catch { }
    if (`$pkgs.Count -eq 0) { Write-Host "'`$(`$v.Name)': all packages up to date."; continue }
    Write-Host "'`$(`$v.Name)': upgrading `$(`$pkgs.Count) package(s): `$(`$pkgs -join ', ')"
    & `$py -m pip install --upgrade @pkgs
    # verify the venv is still consistent; report loudly if not
    `$check = & `$py -m pip check 2>&1
    if (`$LASTEXITCODE -ne 0) {
        `$broken = `$true
        Write-Host "'`$(`$v.Name)': WARNING — dependency conflict after upgrade:"
        `$check | ForEach-Object { Write-Host "  `$_" }
        Write-Host "  fix: delete `$(`$v.FullName) and re-run the script (venv is rebuilt automatically)"
    }
}
Write-Host 'venv upgrade complete'
if (`$broken) { exit 1 }
"@
}

Export-ModuleMember -Function Get-StoScriptDeps, Get-StoMissingDeps, Get-StoInstalledModules,
Test-StoDepSatisfied, Get-StoInstallCommand, Get-StoModuleUpgradeCommand, New-StoDep,
Test-StoPythonScript, Get-StoPipName, Get-StoVenvPython, Test-StoVenv, Read-StoRequirements,
Get-StoMissingPythonDeps, Get-StoPythonInstallCommand, Get-StoVenvUpgradeCommand
