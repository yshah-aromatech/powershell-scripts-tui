BeforeAll {
    foreach ($m in 'Core', 'Scripts', 'Deps', 'Runner', 'Cron', 'Tui') {
        Import-Module (Join-Path $PSScriptRoot "../src/$m.psm1") -Force -DisableNameChecking
    }
    $script:appDir = Join-Path ([IO.Path]::GetTempPath()) "pss-tui-tests-$(New-Guid)"
    New-Item -ItemType Directory -Path $script:appDir -Force | Out-Null
    @{ dataDir = (Join-Path $script:appDir 'data') } | ConvertTo-Json |
        Set-Content (Join-Path $script:appDir 'config.json')
    Initialize-Pss -AppDir $script:appDir

    $script:tui = Get-Module Tui

    # minimal UI state so the row renderers can run headless
    & $script:tui {
        $script:S = @{
            Quit = $false; W = 100; H = 30
            Scripts = @(); Visible = @(); Selected = 0; ListTop = 0
            Filter = ''; Statuses = @{}; Schedules = @{}; NextRunCache = @{}
            Lines = [System.Collections.Generic.List[string]]::new()
            Wrapped = [System.Collections.Generic.List[string]]::new()
            WrapWidth = 0; Scroll = 0; Follow = $true
            OutTitle = 'output'; Mode = 'list'
            Input = $null; Confirm = $null; Deps = $null; Env = $null; History = $null
            Run = $null; Queue = [System.Collections.Generic.List[object]]::new()
            AfterTask = $null; AfterTaskAlways = $null
            StatusMsg = ''; StatusMsgAt = [datetime]::MinValue
            Tick = 0; LastSample = [datetime]::MinValue
            AppVersion = 'abc1234'; Dirty = $true
        }
        $script:S.Visible = @(
            [pscustomobject]@{ Name = 'alpha'; Dir = '/x'; Entry = '/x/alpha/main.ps1'; Description = 'first script'; Args = @() },
            [pscustomobject]@{ Name = 'beta-日本語'; Dir = '/x'; Entry = '/x/beta/main.ps1'; Description = ''; Args = @() }
        )
        $script:S.Scripts = $script:S.Visible
        $script:S.Statuses['alpha'] = [pscustomobject]@{ Status = 'success'; At = (Get-Date).AddHours(-2); DurationSec = 12.5 }
        $script:S.Schedules['alpha'] = '*/15 * * * *'
    }
}

AfterAll {
    Remove-Item $script:appDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'list rows' {
    It 'renders one row per body line at the requested width' {
        $rows = & $script:tui { Get-TuiListRows -Count 5 -Width 30 }
        $rows.Count | Should -Be 5
        foreach ($r in $rows) {
            # strip ANSI, measure display cells
            $plain = [regex]::Replace($r, "`e\[[0-9;]*m", '')
            Get-PssDisplayWidth $plain | Should -Be 30
        }
    }

    It 'marks scheduled scripts and shows last-run age' {
        $rows = & $script:tui { Get-TuiListRows -Count 2 -Width 30 }
        $plain = [regex]::Replace($rows[0], "`e\[[0-9;]*m", '')
        $plain | Should -Match 'alpha'
        $plain | Should -Match '2h'
        $plain | Should -Match '@'
    }
}

Describe 'output wrapping' {
    It 'wraps at word boundaries' {
        $wrapped = & $script:tui {
            $script:S.W = 60
            Get-TuiWrappedLine 'aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll'
        }
        $wrapped.Count | Should -BeGreaterThan 1
        # no fragment should start mid-word after a space-break
        $wrapped[0] | Should -Match ' $|[a-z]$'
    }

    It 'hard-wraps unbreakable text without losing characters' {
        $long = 'x' * 100
        $wrapped = & $script:tui { param($l) Get-TuiWrappedLine $l } $long
        ($wrapped -join '') | Should -Be $long
    }
}

Describe 'help overlay' {
    It 'renders and includes the new keys' {
        $rows = & $script:tui { Get-TuiHelpRows -Count 25 -Width 80 }
        $all = [regex]::Replace(($rows -join "`n"), "`e\[[0-9;]*m", '')
        $all | Should -Match 'lint'
        $all | Should -Match 'git pull'
        $all | Should -Match 'queue'
    }
}

Describe 'history rows' {
    It 'renders selection and sparkline without errors' {
        $rows = & $script:tui {
            $script:S.History = @{
                Items = @([pscustomobject]@{
                        script = 'alpha'; status = 'success'; trigger = 'cron'
                        startedAt = '2026-07-03T10:00:00.000Z'; durationSec = 4.2
                        resources = [pscustomobject]@{ cpuMaxPercent = 50; memMaxMb = 100; cpuSeries = @(1, 5, 2, 8) }
                    })
                Sel = 0; FilterName = ''
            }
            Get-TuiHistoryRows -Count 5 -Width 110
        }
        $all = [regex]::Replace(($rows -join "`n"), "`e\[[0-9;]*m", '')
        $all | Should -Match 'alpha'
        $all | Should -Match '▁|▂|▃|▄|▅|▆|▇|█'
    }
}

Describe 'status line' {
    It 'shows the next scheduled run for the selected script' {
        $line = & $script:tui {
            $script:S.Mode = 'list'
            $script:S.Selected = 0
            Get-TuiStatusLine -Width 120
        }
        $plain = [regex]::Replace($line, "`e\[[0-9;]*m", '')
        $plain | Should -Match 'next in'
    }

    It 'shows the queue depth while running' {
        $line = & $script:tui {
            $script:S.Run = @{ Kind = 'task'; Name = 'sync' }
            $script:S.Queue.Add(@{ Script = $null; ExtraArgs = @() })
            $r = Get-TuiStatusLine -Width 120
            $script:S.Run = $null
            $script:S.Queue.Clear()
            $r
        }
        [regex]::Replace($line, "`e\[[0-9;]*m", '') | Should -Match '\+1 queued'
    }
}

Describe 'key hints footer' {
    It 'shows list keys in list mode' {
        $line = & $script:tui { $script:S.Mode = 'list'; Get-TuiKeyHints -Width 200 }
        $plain = [regex]::Replace($line, "`e\[[0-9;]*m", '')
        $plain | Should -Match 'enter run'
        $plain | Should -Match 'q quit'
    }

    It 'shows mode-specific keys in history and env modes' {
        $hist = & $script:tui { $script:S.Mode = 'history'; Get-TuiKeyHints -Width 200 }
        [regex]::Replace($hist, "`e\[[0-9;]*m", '') | Should -Match 'view log'
        $env = & $script:tui { $script:S.Mode = 'env'; Get-TuiKeyHints -Width 200 }
        [regex]::Replace($env, "`e\[[0-9;]*m", '') | Should -Match 'ctrl\+s save'
        & $script:tui { $script:S.Mode = 'list' }
    }

    It 'pads to the requested width' {
        $line = & $script:tui { $script:S.Mode = 'list'; Get-TuiKeyHints -Width 60 }
        $plain = [regex]::Replace($line, "`e\[[0-9;]*m", '')
        $plain.Length | Should -Be 60
    }
}

Describe 'sparkline' {
    It 'is empty-safe' {
        (& $script:tui { Get-TuiSparkline -Series @() -Width 5 }).Length | Should -Be 5
    }
    It 'scales to its own max' {
        $s = & $script:tui { Get-TuiSparkline -Series @(0.0, 10.0) -Width 2 }
        $s[1] | Should -Be ([char]'█')
    }
}
