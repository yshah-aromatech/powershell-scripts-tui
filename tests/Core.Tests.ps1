BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Core.psm1') -Force -DisableNameChecking
}

Describe 'Read-StoEnvFile' {
    BeforeEach {
        $script:envFile = Join-Path ([IO.Path]::GetTempPath()) "pss-test-$(New-Guid).env"
    }
    AfterEach {
        Remove-Item $script:envFile -Force -ErrorAction SilentlyContinue
    }

    It 'parses KEY=VALUE lines' {
        "A=1`nB=two words" | Set-Content $script:envFile
        $r = Read-StoEnvFile $script:envFile
        $r['A'] | Should -Be '1'
        $r['B'] | Should -Be 'two words'
    }

    It 'skips comments and blank lines' {
        "# comment`n`nA=1" | Set-Content $script:envFile
        (Read-StoEnvFile $script:envFile).Count | Should -Be 1
    }

    It 'strips matched quotes' {
        "A='quoted'`nB=`"dquoted`"" | Set-Content $script:envFile
        $r = Read-StoEnvFile $script:envFile
        $r['A'] | Should -Be 'quoted'
        $r['B'] | Should -Be 'dquoted'
    }

    It 'keeps = signs inside values' {
        'A=x=y' | Set-Content $script:envFile
        (Read-StoEnvFile $script:envFile)['A'] | Should -Be 'x=y'
    }

    It 'returns empty for a missing file' {
        (Read-StoEnvFile "$script:envFile-nope").Count | Should -Be 0
    }
}

Describe 'Register-StoSecret / Hide-StoSecret' {
    It 'redacts values whose names look secret-ish' {
        Register-StoSecret -Name 'MY_API_TOKEN' -Value 'supersecret123'
        Hide-StoSecret 'the value is supersecret123 ok' | Should -Be 'the value is *** ok'
    }

    It 'ignores non-secret-looking names without -Force' {
        Register-StoSecret -Name 'GREETING' -Value 'hello-world-value'
        Hide-StoSecret 'hello-world-value' | Should -Be 'hello-world-value'
    }

    It 'registers any name with -Force' {
        Register-StoSecret -Name 'GREETING' -Value 'forced-secret-value' -Force
        Hide-StoSecret 'x forced-secret-value y' | Should -Be 'x *** y'
    }

    It 'ignores short values' {
        Register-StoSecret -Name 'SHORT_TOKEN' -Value 'abc' -Force
        Hide-StoSecret 'abc' | Should -Be 'abc'
    }

    It 'matches broadened name patterns (PASS, CONN, DSN, AUTH)' {
        Register-StoSecret -Name 'DB_CONN' -Value 'connstring-value-1'
        Register-StoSecret -Name 'SMTP_PASS' -Value 'smtppass-value-22'
        Hide-StoSecret 'connstring-value-1 smtppass-value-22' | Should -Be '*** ***'
    }
}

Describe 'Split-StoArguments' {
    It 'splits on whitespace' {
        Split-StoArguments 'a b  c' | Should -Be @('a', 'b', 'c')
    }

    It 'keeps double-quoted groups together' {
        Split-StoArguments '-Message "hello world" -Flag' | Should -Be @('-Message', 'hello world', '-Flag')
    }

    It 'keeps single-quoted groups together' {
        Split-StoArguments "-Msg 'a b'" | Should -Be @('-Msg', 'a b')
    }

    It 'supports empty quoted tokens' {
        Split-StoArguments 'a "" b' | Should -Be @('a', '', 'b')
    }

    It 'returns an empty array for blank input' {
        @(Split-StoArguments '   ').Count | Should -Be 0
        @(Split-StoArguments $null).Count | Should -Be 0
    }

    It 'handles adjacent quoted and unquoted text' {
        Split-StoArguments "pre'mid dle'post" | Should -Be @('premid dlepost')
    }
}

Describe 'Get-StoDisplayWidth / Format-StoCell' {
    It 'counts ASCII as 1 cell each' {
        Get-StoDisplayWidth 'hello' | Should -Be 5
    }

    It 'counts CJK as 2 cells each' {
        Get-StoDisplayWidth '日本語' | Should -Be 6
    }

    It 'counts emoji as 2 cells' {
        Get-StoDisplayWidth '🎉ok' | Should -Be 4
    }

    It 'counts combining marks as 0 cells' {
        Get-StoDisplayWidth "e$([char]0x0301)" | Should -Be 1
    }

    It 'pads to exact width' {
        (Format-StoCell -Text 'ab' -Width 5).Length | Should -Be 5
    }

    It 'truncates wide chars without splitting cells' {
        $r = Format-StoCell -Text '日本語' -Width 5
        Get-StoDisplayWidth $r | Should -Be 5
        $r | Should -Be '日本 '
    }

    It 'adds an ellipsis when truncating with -Ellipsis' {
        Format-StoCell -Text 'abcdef' -Width 4 -Ellipsis | Should -Be 'abc…'
    }
}

Describe 'Format-StoDuration / Format-StoRelativeTime' {
    It 'formats seconds' { Format-StoDuration 5.26 | Should -Be '5.3s' }
    It 'formats minutes' { Format-StoDuration 90 | Should -Be '1m30s' }
    It 'formats hours' { Format-StoDuration 3725 | Should -Be '1h02m05s' }
    It 'formats relative times compactly' {
        Format-StoRelativeTime 45 | Should -Be '45s'
        Format-StoRelativeTime 300 | Should -Be '5m'
        Format-StoRelativeTime 90000 | Should -Be '1d'
    }
}

Describe 'ConvertTo-Ansi256Index' {
    It 'maps pure gray to the gray ramp' {
        $idx = ConvertTo-Ansi256Index 128 128 128
        $idx | Should -BeGreaterOrEqual 232
    }
    It 'maps saturated colors into the cube' {
        $idx = ConvertTo-Ansi256Index 255 0 0
        $idx | Should -Be 196
    }
}

Describe 'Initialize-Sto config handling' {
    BeforeEach {
        $script:appDir = Join-Path ([IO.Path]::GetTempPath()) "pss-app-$(New-Guid)"
        $script:dataDir = Join-Path $script:appDir 'data'
        New-Item -ItemType Directory -Path $script:appDir -Force | Out-Null
    }
    AfterEach {
        Remove-Item $script:appDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'warns about unknown config keys' {
        @{ dataDir = $script:dataDir; notAKey = 1 } | ConvertTo-Json | Set-Content (Join-Path $script:appDir 'config.json')
        Initialize-Sto -AppDir $script:appDir
        @(Get-StoConfigWarnings)[0] | Should -Match 'notAKey'
    }

    It 'warns and keeps the default when a numeric key is not numeric' {
        @{ dataDir = $script:dataDir; runTimeoutMinutes = 'lots' } | ConvertTo-Json | Set-Content (Join-Path $script:appDir 'config.json')
        Initialize-Sto -AppDir $script:appDir
        @(Get-StoConfigWarnings).Count | Should -Be 1
        (Get-StoConfig).runTimeoutMinutes | Should -Be 0
    }

    It 'creates the data directories including locks' {
        @{ dataDir = $script:dataDir } | ConvertTo-Json | Set-Content (Join-Path $script:appDir 'config.json')
        Initialize-Sto -AppDir $script:appDir
        Test-Path (Get-StoPaths).LocksDir | Should -BeTrue
    }

    It 'prunes old logs and caps history at startup' {
        @{ dataDir = $script:dataDir; logRetentionDays = 7; historyMaxLines = 5 } | ConvertTo-Json |
            Set-Content (Join-Path $script:appDir 'config.json')
        Initialize-Sto -AppDir $script:appDir
        $paths = Get-StoPaths

        $old = Join-Path $paths.LogsDir 'old.log'
        $new = Join-Path $paths.LogsDir 'new.log'
        'x' | Set-Content $old; 'x' | Set-Content $new
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-30)
        1..20 | ForEach-Object { "{""script"":""s$_""}" } | Set-Content $paths.HistoryFile

        Clear-StoOldData
        Test-Path $old | Should -BeFalse
        Test-Path $new | Should -BeTrue
        @(Get-Content $paths.HistoryFile).Count | Should -Be 5
        (Get-Content $paths.HistoryFile | Select-Object -Last 1) | Should -Match 's20'
    }
}

Describe 'Add-StoRepoConfig' {
    BeforeEach {
        $script:repoAppDir = Join-Path ([IO.Path]::GetTempPath()) "pss-addrepo-tests-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:repoAppDir -Force | Out-Null
        @{
            dataDir = (Join-Path $script:repoAppDir 'data')
            scriptsRepo = 'https://github.com/org/powershell-scripts'
        } | ConvertTo-Json | Set-Content (Join-Path $script:repoAppDir 'config.json')
        Initialize-Sto -AppDir $script:repoAppDir
    }
    AfterEach {
        Remove-Item $script:repoAppDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'converts a legacy scriptsRepo and appends the new repo' {
        $r = Add-StoRepoConfig -Url 'https://github.com/org/python-scripts' -Name 'python'
        $r.Ok | Should -BeTrue
        $cfg = Get-Content (Join-Path $script:repoAppDir 'config.json') -Raw | ConvertFrom-Json
        @($cfg.repos).Count | Should -Be 2
        $cfg.repos[0].url | Should -Be 'https://github.com/org/powershell-scripts'
        $cfg.repos[1].name | Should -Be 'python'
        # reload and confirm Get-StoRepos sees both, non-legacy
        Initialize-Sto -AppDir $script:repoAppDir
        $repos = @(Get-StoRepos)
        $repos.Count | Should -Be 2
        $repos[0].Legacy | Should -BeFalse
    }

    It 'derives the name from the URL when not given' {
        $r = Add-StoRepoConfig -Url 'https://github.com/org/python-scripts.git'
        $r.Ok | Should -BeTrue
        $r.Name | Should -Be 'python-scripts'
    }

    It 'rejects a duplicate name and a duplicate URL' {
        (Add-StoRepoConfig -Url 'https://github.com/org/a' -Name 'x').Ok | Should -BeTrue
        (Add-StoRepoConfig -Url 'https://github.com/org/b' -Name 'x').Ok | Should -BeFalse
        (Add-StoRepoConfig -Url 'https://github.com/org/a.git' -Name 'y').Ok | Should -BeFalse
    }

    It 'rejects invalid names' {
        (Add-StoRepoConfig -Url 'https://github.com/org/c' -Name 'bad name!').Ok | Should -BeFalse
    }
}
