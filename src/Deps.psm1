# Deps.psm1 — automatic module dependency detection (PowerShell AST) and
# per-script module directory management. The PowerShell analog of one venv
# per script: each script gets its own module dir prepended to PSModulePath.

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

# ---------------------------------------------------------------------------
# Scan a script's source for module dependencies:
#   - #Requires -Modules ...
#   - using module ...
#   - Import-Module / ipmo calls
# Local files (paths, .psm1/.psd1 in the script folder) and builtins excluded.
# ---------------------------------------------------------------------------
function Get-PssScriptDeps {
    param([Parameter(Mandatory)]$Script)

    $deps = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script.Entry, [ref]$tokens, [ref]$errors)
    if (-not $ast) { return @() }

    # #Requires -Modules
    if ($ast.ScriptRequirements -and $ast.ScriptRequirements.RequiredModules) {
        foreach ($m in $ast.ScriptRequirements.RequiredModules) { [void]$deps.Add($m.Name) }
    }

    # using module X
    if ($ast.UsingStatements) {
        foreach ($u in $ast.UsingStatements) {
            if ($u.UsingStatementKind -eq 'Module' -and $u.Name) { [void]$deps.Add($u.Name.Value) }
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
                foreach ($name in (Resolve-PssModuleElement $el)) { [void]$deps.Add($name) }
                $gotName = $true
            }
        }
    }

    # filter: local paths and builtins
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $deps) {
        if (-not $d) { continue }
        if ($d -match '[/\\]' -or $d -match '\.(psm1|psd1|dll)$') { continue }   # local/path import
        if ($script:BuiltinModules -contains $d) { continue }
        if (Test-Path (Join-Path $Script.Dir "$d.psm1")) { continue }            # local module next to script
        if (Test-Path (Join-Path $Script.Dir $d)) { continue }                   # local module folder
        $mapped = if ($script:ModuleNameMap.ContainsKey($d.ToLower())) { $script:ModuleNameMap[$d.ToLower()] } else { $d }
        if (-not $result.Contains($mapped)) { $result.Add($mapped) }
    }
    $result | Sort-Object
}

function Resolve-PssModuleElement {
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
# What's missing = declared deps minus (script module dir + system modules)
# ---------------------------------------------------------------------------
function Get-PssInstalledModules {
    param([Parameter(Mandatory)]$Script)
    $installed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path $Script.ModuleDir) {
        foreach ($d in (Get-ChildItem $Script.ModuleDir -Directory -ErrorAction SilentlyContinue)) {
            [void]$installed.Add($d.Name)
        }
    }
    foreach ($m in (Get-Module -ListAvailable -ErrorAction SilentlyContinue)) {
        [void]$installed.Add($m.Name)
    }
    $installed
}

function Get-PssMissingDeps {
    param([Parameter(Mandatory)]$Script)
    $deps = @(Get-PssScriptDeps -Script $Script)
    if (-not $deps) { return @() }
    $installed = Get-PssInstalledModules -Script $Script
    @($deps | Where-Object { -not $installed.Contains($_) })
}

# ---------------------------------------------------------------------------
# Build the pwsh -Command string that installs modules into the script's
# module dir. Run as a streamed task so the TUI shows live progress.
# ---------------------------------------------------------------------------
function Get-PssInstallCommand {
    param([Parameter(Mandatory)]$Script, [Parameter(Mandatory)][string[]]$Modules)
    if (-not (Test-Path $Script.ModuleDir)) {
        New-Item -ItemType Directory -Path $Script.ModuleDir -Force | Out-Null
    }
    $dir = $Script.ModuleDir
    $list = ($Modules | ForEach-Object { "'$($_ -replace "'","''")'" }) -join ','
    @"
`$ErrorActionPreference = 'Continue'
`$ok = `$true
foreach (`$m in @($list)) {
    Write-Host "installing `$m -> $dir"
    try {
        if (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
            Save-PSResource -Name `$m -Path '$dir' -Repository PSGallery -TrustRepository -ErrorAction Stop
        } else {
            Save-Module -Name `$m -Path '$dir' -Repository PSGallery -Force -ErrorAction Stop
        }
        Write-Host "`$m installed"
    } catch {
        Write-Host "FAILED to install `$m : `$(`$_.Exception.Message)"
        `$ok = `$false
    }
}
if (-not `$ok) { exit 1 }
"@
}

# pwsh -Command string that re-saves the latest version of every module in
# every per-script module dir (used by the system update action).
function Get-PssModuleUpgradeCommand {
    $paths = Get-PssPaths
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

Export-ModuleMember -Function Get-PssScriptDeps, Get-PssMissingDeps, Get-PssInstalledModules,
Get-PssInstallCommand, Get-PssModuleUpgradeCommand
