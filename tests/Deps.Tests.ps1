BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Core.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '../src/Deps.psm1') -Force -DisableNameChecking

    function New-TestScript {
        param([string]$Source)
        $dir = Join-Path ([IO.Path]::GetTempPath()) "pss-deps-$(New-Guid)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $entry = Join-Path $dir 'main.ps1'
        $Source | Set-Content $entry
        [pscustomobject]@{
            Name = 'test'; Dir = $dir; Entry = $entry
            ModuleDir = Join-Path $dir 'mods'
        }
    }
}

Describe 'Get-StoScriptDeps' {
    It 'finds Import-Module by name' {
        $s = New-TestScript 'Import-Module Az.Accounts'
        @(Get-StoScriptDeps -Script $s).Name | Should -Be 'Az.Accounts'
        Remove-Item $s.Dir -Recurse -Force
    }

    It 'does not mistake parameter values for module names' {
        $s = New-TestScript 'Import-Module PSSQLite -ErrorAction Stop -ErrorVariable ev'
        @(Get-StoScriptDeps -Script $s).Name | Should -Be 'PSSQLite'
        Remove-Item $s.Dir -Recurse -Force
    }

    It 'finds #Requires modules with version constraints' {
        $s = New-TestScript "#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }`nWrite-Host hi"
        $deps = @(Get-StoScriptDeps -Script $s)
        $deps.Name | Should -Be 'Pester'
        $deps[0].MinimumVersion | Should -Be '5.0'
        $deps[0].Display | Should -Be 'Pester (>=5.0)'
        Remove-Item $s.Dir -Recurse -Force
    }

    It 'finds using module statements' {
        $s = New-TestScript "using module dbatools`nWrite-Host hi"
        @(Get-StoScriptDeps -Script $s).Name | Should -Be 'dbatools'
        Remove-Item $s.Dir -Recurse -Force
    }

    It 'excludes builtins and local files' {
        $s = New-TestScript "Import-Module Microsoft.PowerShell.Utility`nImport-Module ./local.psm1`nImport-Module Helper"
        'x' | Set-Content (Join-Path $s.Dir 'Helper.psm1')
        @(Get-StoScriptDeps -Script $s).Count | Should -Be 0
        Remove-Item $s.Dir -Recurse -Force
    }

    It 'maps common name mismatches' {
        $s = New-TestScript 'Import-Module sqlps'
        @(Get-StoScriptDeps -Script $s).Name | Should -Be 'SqlServer'
        Remove-Item $s.Dir -Recurse -Force
    }

    It 'handles array imports' {
        $s = New-TestScript 'Import-Module ModA, ModB'
        @(Get-StoScriptDeps -Script $s).Name | Should -Be @('ModA', 'ModB')
        Remove-Item $s.Dir -Recurse -Force
    }
}

Describe 'Test-StoDepSatisfied' {
    It 'is satisfied by presence when unversioned' {
        $installed = @{ 'ModA' = [System.Collections.Generic.List[version]]@([version]'1.0') }
        Test-StoDepSatisfied -Dep (New-StoDep -Name 'ModA') -Installed $installed | Should -BeTrue
    }
    It 'is unsatisfied when absent' {
        Test-StoDepSatisfied -Dep (New-StoDep -Name 'ModB') -Installed @{} | Should -BeFalse
    }
    It 'checks exact RequiredVersion' {
        $installed = @{ 'ModA' = [System.Collections.Generic.List[version]]@([version]'1.0') }
        Test-StoDepSatisfied -Dep (New-StoDep -Name 'ModA' -RequiredVersion '1.0') -Installed $installed | Should -BeTrue
        Test-StoDepSatisfied -Dep (New-StoDep -Name 'ModA' -RequiredVersion '2.0') -Installed $installed | Should -BeFalse
    }
    It 'checks minimum/maximum bounds' {
        $installed = @{ 'ModA' = [System.Collections.Generic.List[version]]@([version]'1.5') }
        Test-StoDepSatisfied -Dep (New-StoDep -Name 'ModA' -MinimumVersion '1.0') -Installed $installed | Should -BeTrue
        Test-StoDepSatisfied -Dep (New-StoDep -Name 'ModA' -MinimumVersion '2.0') -Installed $installed | Should -BeFalse
        Test-StoDepSatisfied -Dep (New-StoDep -Name 'ModA' -MaximumVersion '1.0') -Installed $installed | Should -BeFalse
    }
}

Describe 'Get-StoInstallCommand' {
    It 'embeds version constraints in the generated command' {
        $s = New-TestScript 'Write-Host hi'
        $cmd = Get-StoInstallCommand -Script $s -Modules @((New-StoDep -Name 'Pester' -RequiredVersion '5.8.0'))
        $cmd | Should -Match "Rv='5\.8\.0'"
        $cmd | Should -Match "Name='Pester'"
        Remove-Item $s.Dir -Recurse -Force
    }

    It 'accepts plain strings for backward compatibility' {
        $s = New-TestScript 'Write-Host hi'
        $cmd = Get-StoInstallCommand -Script $s -Modules @('SomeModule')
        $cmd | Should -Match "Name='SomeModule'"
        Remove-Item $s.Dir -Recurse -Force
    }
}

Describe 'python dependency pipeline' {
    BeforeAll {
        # this file has no shared app dir — python deps need config/paths
        $script:pyAppDir = Join-Path ([IO.Path]::GetTempPath()) "pss-pydeps-tests-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:pyAppDir -Force | Out-Null
        @{ dataDir = (Join-Path $script:pyAppDir 'data') } | ConvertTo-Json |
            Set-Content (Join-Path $script:pyAppDir 'config.json')
        Initialize-Sto -AppDir $script:pyAppDir

        $script:pyDir = Join-Path $script:pyAppDir 'pyscript'
        New-Item -ItemType Directory -Path $script:pyDir -Force | Out-Null
        $script:pyScript = [pscustomobject]@{
            Name = 'pyscript'; Dir = $script:pyDir
            Entry = (Join-Path $script:pyDir 'main.py')
            Runtime = 'python'; Repo = 'scripts'; Args = @()
            EnvFile = (Join-Path $script:pyDir '.env')
            ModuleDir = (Join-Path $script:pyAppDir 'data/modules/pyscript')
            VenvDir = (Join-Path $script:pyAppDir 'data/venvs/pyscript')
        }
        $script:hasPython = [bool](Get-Command python3 -ErrorAction SilentlyContinue)
    }
    AfterAll {
        Remove-Item $script:pyAppDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'maps import names to pip names' {
        Get-StoPipName 'cv2' | Should -Be 'opencv-python'
        Get-StoPipName 'PIL' | Should -Be 'pillow'
        Get-StoPipName 'dotenv' | Should -Be 'python-dotenv'
        Get-StoPipName 'requests' | Should -Be 'requests'
    }

    It 'parses requirements.txt names, stripping specifiers and comments' {
        $req = Join-Path $script:pyDir 'requirements.txt'
        @'
# comment
requests>=2.31
python-dotenv==1.0.0
pyyaml
-r other.txt
msal[broker]>=1.20 ; python_version >= "3.8"
'@ | Set-Content $req
        $names = @(Read-StoRequirements -Path $req)
        $names | Should -Be @('requests', 'python-dotenv', 'pyyaml', 'msal')
        Remove-Item $req
    }

    It 'prefers requirements.txt in the install command' {
        $req = Join-Path $script:pyDir 'requirements.txt'
        'requests' | Set-Content $req
        $cmd = Get-StoInstallCommand -Script $script:pyScript -Modules @('whatever')
        $cmd | Should -Match 'pip install -r'
        $cmd | Should -Match 'requirements\.txt'
        Remove-Item $req
    }

    It 'builds a venv-create + pip install command with mapped names' {
        $deps = @(New-StoDep -Name 'cv2' | Add-Member -NotePropertyName PipName -NotePropertyValue 'opencv-python' -PassThru)
        $cmd = Get-StoInstallCommand -Script $script:pyScript -Modules $deps
        $cmd | Should -Match '-m venv'
        $cmd | Should -Match "pip install @\('opencv-python'\)"
        $cmd | Should -Match 'python3-venv'   # failure hint present
    }

    It 'venv upgrade command upgrades only top-level packages and pip-checks after' {
        $cmd = Get-StoVenvUpgradeCommand
        $cmd | Should -Match 'bin/python'
        # dependencies (pydantic-core etc.) must never be force-upgraded past
        # their parents' exact pins — that broke a real venv
        $cmd | Should -Match '--outdated --not-required'
        $cmd | Should -Match 'pip check'
    }

    It 'scans imports and reports third-party modules as missing without a venv' -Skip:(-not (Get-Command python3 -ErrorAction SilentlyContinue)) {
        @'
import os, sys
import requests
from dotenv import load_dotenv
import localhelper
'@ | Set-Content (Join-Path $script:pyDir 'main.py')
        'x = 1' | Set-Content (Join-Path $script:pyDir 'localhelper.py')
        $missing = @(Get-StoMissingDeps -Script $script:pyScript)
        ($missing | ForEach-Object Name) | Should -Contain 'requests'
        ($missing | ForEach-Object Name) | Should -Contain 'dotenv'
        ($missing | ForEach-Object Name) | Should -Not -Contain 'os'
        ($missing | ForEach-Object Name) | Should -Not -Contain 'localhelper'
        ($missing | Where-Object Name -eq 'dotenv').PipName | Should -Be 'python-dotenv'
    }
}
