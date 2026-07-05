BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Core.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '../src/Scripts.psm1') -Force -DisableNameChecking

    # isolated data dir with a fake scripts tree
    $script:appDir = Join-Path ([IO.Path]::GetTempPath()) "pss-scripts-tests-$(New-Guid)"
    New-Item -ItemType Directory -Path $script:appDir -Force | Out-Null
    @{ dataDir = (Join-Path $script:appDir 'data') } | ConvertTo-Json |
        Set-Content (Join-Path $script:appDir 'config.json')
    Initialize-Pss -AppDir $script:appDir
    $script:root = (Get-PssPaths).ScriptsDir
    New-Item -ItemType Directory -Path $script:root -Force | Out-Null
}

AfterAll {
    Remove-Item $script:appDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-PssScripts discovery' {
    BeforeEach {
        Get-ChildItem $script:root -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    }

    It 'uses main.ps1 by convention' {
        New-Item -ItemType Directory -Path (Join-Path $script:root 'a') | Out-Null
        'x' | Set-Content (Join-Path $script:root 'a/main.ps1')
        $s = @(Get-PssScripts)
        $s.Count | Should -Be 1
        $s[0].Entry | Should -Match 'main\.ps1$'
    }

    It 'prefers script.json entry over conventions' {
        $d = Join-Path $script:root 'b'
        New-Item -ItemType Directory -Path $d | Out-Null
        'x' | Set-Content (Join-Path $d 'main.ps1')
        'x' | Set-Content (Join-Path $d 'custom.ps1')
        '{"entry": "custom.ps1", "description": "desc", "timeoutMinutes": 15}' | Set-Content (Join-Path $d 'script.json')
        $s = @(Get-PssScripts)[0]
        $s.Entry | Should -Match 'custom\.ps1$'
        $s.Description | Should -Be 'desc'
        $s.TimeoutMinutes | Should -Be 15
    }

    It 'falls back to the sole ps1 in a folder' {
        $d = Join-Path $script:root 'c'
        New-Item -ItemType Directory -Path $d | Out-Null
        'x' | Set-Content (Join-Path $d 'whatever.ps1')
        @(Get-PssScripts)[0].Entry | Should -Match 'whatever\.ps1$'
    }

    It 'ignores non-numeric timeoutMinutes' {
        $d = Join-Path $script:root 'd'
        New-Item -ItemType Directory -Path $d | Out-Null
        'x' | Set-Content (Join-Path $d 'main.ps1')
        '{"timeoutMinutes": "soon"}' | Set-Content (Join-Path $d 'script.json')
        @(Get-PssScripts)[0].TimeoutMinutes | Should -Be $null
    }

    It 'discovers loose ps1 files in the repo root' {
        'x' | Set-Content (Join-Path $script:root 'loose.ps1')
        $s = @(Get-PssScripts)
        $s.Count | Should -Be 1
        $s[0].Name | Should -Be 'loose'
    }

    It 'skips folders with no entry point' {
        New-Item -ItemType Directory -Path (Join-Path $script:root 'empty') | Out-Null
        @(Get-PssScripts).Count | Should -Be 0
    }
}

Describe 'Get-PssLastSyncTime' {
    It 'is null when the clone does not exist yet' {
        Remove-Item (Join-Path $script:root '.git') -Recurse -Force -ErrorAction SilentlyContinue
        Get-PssLastSyncTime | Should -Be $null
    }

    It 'uses FETCH_HEAD mtime when present' {
        $git = Join-Path $script:root '.git'
        New-Item -ItemType Directory -Path $git -Force | Out-Null
        $fh = Join-Path $git 'FETCH_HEAD'
        'x' | Set-Content $fh
        $stamp = (Get-Date).AddMinutes(-42)
        (Get-Item $fh).LastWriteTime = $stamp
        $got = Get-PssLastSyncTime
        [Math]::Abs(($got - $stamp).TotalSeconds) | Should -BeLessThan 2
        Remove-Item $git -Recurse -Force
    }
}

Describe 'python script discovery' {
    BeforeEach {
        Get-ChildItem $script:root -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    }

    It 'uses main.py by convention and sets Runtime/VenvDir' {
        $d = Join-Path $script:root 'pya'
        New-Item -ItemType Directory -Path $d | Out-Null
        'print(1)' | Set-Content (Join-Path $d 'main.py')
        $s = @(Get-PssScripts)[0]
        $s.Entry | Should -Match 'main\.py$'
        $s.Runtime | Should -Be 'python'
        $s.VenvDir | Should -Be (Join-Path (Get-PssPaths).VenvsDir 'pya')
    }

    It 'resolves __main__.py and the sole .py fallback' {
        $d = Join-Path $script:root 'pyb'
        New-Item -ItemType Directory -Path $d | Out-Null
        'print(1)' | Set-Content (Join-Path $d '__main__.py')
        @(Get-PssScripts)[0].Entry | Should -Match '__main__\.py$'
        Remove-Item (Join-Path $d '__main__.py')
        'print(1)' | Set-Content (Join-Path $d 'oddname.py')
        @(Get-PssScripts)[0].Entry | Should -Match 'oddname\.py$'
    }

    It 'prefers a conventional ps1 over python in a mixed folder' {
        $d = Join-Path $script:root 'mixed'
        New-Item -ItemType Directory -Path $d | Out-Null
        'x' | Set-Content (Join-Path $d 'main.ps1')
        'print(1)' | Set-Content (Join-Path $d 'main.py')
        $s = @(Get-PssScripts)[0]
        $s.Runtime | Should -Be 'powershell'
    }

    It 'honors script.json entry pointing at a .py' {
        $d = Join-Path $script:root 'pyc'
        New-Item -ItemType Directory -Path $d | Out-Null
        'x' | Set-Content (Join-Path $d 'main.ps1')
        'print(1)' | Set-Content (Join-Path $d 'actual.py')
        '{"entry": "actual.py"}' | Set-Content (Join-Path $d 'script.json')
        $s = @(Get-PssScripts)[0]
        $s.Runtime | Should -Be 'python'
        $s.Entry | Should -Match 'actual\.py$'
    }

    It 'skips __pycache__/.venv dirs and discovers loose .py files' {
        foreach ($skip in '__pycache__', '.venv', 'node_modules') {
            New-Item -ItemType Directory -Path (Join-Path $script:root $skip) | Out-Null
            'print(1)' | Set-Content (Join-Path $script:root "$skip/main.py")
        }
        'print(1)' | Set-Content (Join-Path $script:root 'loosepy.py')
        $s = @(Get-PssScripts)
        $s.Count | Should -Be 1
        $s[0].Name | Should -Be 'loosepy'
        $s[0].Runtime | Should -Be 'python'
        $s[0].EnvFile | Should -Match 'loosepy\.env$'
    }
}

Describe 'multi-repo config' {
    BeforeAll {
        $script:appDir2 = Join-Path ([IO.Path]::GetTempPath()) "pss-multirepo-tests-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:appDir2 -Force | Out-Null
        @{
            dataDir = (Join-Path $script:appDir2 'data')
            repos   = @(
                @{ name = 'psrepo'; url = 'https://github.com/org/ps-scripts' },
                @{ name = 'pyrepo'; url = 'https://github.com/org/py-scripts'; branch = 'dev' }
            )
        } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $script:appDir2 'config.json')
        Initialize-Pss -AppDir $script:appDir2
        $script:sroot = (Get-PssPaths).ScriptsDir
    }
    AfterAll {
        Remove-Item $script:appDir2 -Recurse -Force -ErrorAction SilentlyContinue
        Initialize-Pss -AppDir $script:appDir   # restore for any later files
    }

    It 'normalizes repo entries with per-repo roots and branches' {
        $repos = @(Get-PssRepos)
        $repos.Count | Should -Be 2
        $repos[0].Root | Should -Be (Join-Path $script:sroot 'psrepo')
        $repos[0].Branch | Should -Be 'main'
        $repos[1].Branch | Should -Be 'dev'
        $repos[0].Legacy | Should -BeFalse
    }

    It 'discovers across repos, tags Repo, and qualifies duplicate names' {
        foreach ($p in 'psrepo/foo', 'pyrepo/foo', 'pyrepo/bar') {
            New-Item -ItemType Directory -Path (Join-Path $script:sroot $p) -Force | Out-Null
        }
        'x' | Set-Content (Join-Path $script:sroot 'psrepo/foo/main.ps1')
        'print(1)' | Set-Content (Join-Path $script:sroot 'pyrepo/foo/main.py')
        'print(1)' | Set-Content (Join-Path $script:sroot 'pyrepo/bar/main.py')
        $s = @(Get-PssScripts)
        ($s | ForEach-Object Name) | Should -Be @('foo', 'bar', 'pyrepo-foo')
        ($s | Where-Object Name -eq 'foo').Repo | Should -Be 'psrepo'
        ($s | Where-Object Name -eq 'pyrepo-foo').Runtime | Should -Be 'python'
    }

    It 'migrates a legacy root-level clone into the first repo subdir' {
        Get-ChildItem $script:sroot | Remove-Item -Recurse -Force
        New-Item -ItemType Directory -Path (Join-Path $script:sroot '.git') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:sroot 'oldscript') -Force | Out-Null
        'x' | Set-Content (Join-Path $script:sroot 'oldscript/main.ps1')
        Update-PssRepoLayout
        Test-Path (Join-Path $script:sroot 'psrepo/.git') | Should -BeTrue
        Test-Path (Join-Path $script:sroot 'psrepo/oldscript/main.ps1') | Should -BeTrue
        Test-Path (Join-Path $script:sroot '.git') | Should -BeFalse
    }
}
