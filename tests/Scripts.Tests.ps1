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
