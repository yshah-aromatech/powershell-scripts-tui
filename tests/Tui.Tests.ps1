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

Describe 'cron schedule flow' {
    It 'confirm callback resolves module-internal functions (GetNewClosure scope regression)' {
        # a .GetNewClosure() OnYes rebinds to a dynamic module where internal
        # functions like Set-TuiStatus do not resolve — this drives e → enter → y
        Mock -ModuleName Tui Set-PssSchedule { $true }
        Mock -ModuleName Tui Get-PssSchedules { @{} }
        $r = & $script:tui {
            $script:S.Mode = 'list'; $script:S.Selected = 0; $script:S.StatusMsg = ''
            Open-TuiCronInput
            & $script:S.Input.OnSubmit '*/5 * * * *'
            Invoke-TuiKeyConfirm ([ConsoleKeyInfo]::new('y', [ConsoleKey]::Y, $false, $false, $false))
            $res = @($script:S.Mode, $script:S.StatusMsg)
            $script:S.Input = $null; $script:S.Confirm = $null
            $script:S.Mode = 'list'; $script:S.StatusMsg = ''
            $script:S.Schedules = @{ alpha = '*/15 * * * *' }
            $res
        }
        $r[0] | Should -Be 'list'
        $r[1] | Should -Match ([regex]::Escape('scheduled alpha : */5 * * * *'))
    }

    It 'install-deps continuation reaches Start-TuiRun without closure scope errors' {
        Mock -ModuleName Tui Get-PssInstallCommand { 'noop' }
        Mock -ModuleName Tui Start-TuiTask { $script:CapturedAfter = $After }
        Mock -ModuleName Tui Start-TuiRun { }
        & $script:tui {
            $script:S.Deps = @{ Script = $script:S.Visible[0]; Missing = @(@{ Name = 'Az'; Display = 'Az' }); ExtraArgs = @('-X'); InstallOnly = $false }
            Invoke-TuiInstallDeps
        }
        & $script:CapturedAfter   # what Update-TuiRun does when the install task succeeds
        Should -Invoke Start-TuiRun -ModuleName Tui -Times 1 -Exactly
        (& $script:tui { $script:S.PendingRun }) | Should -BeNullOrEmpty
    }
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

    It 'marks the selected row with an accent bar, others with a space' {
        $rows = & $script:tui { $script:S.Selected = 0; Get-TuiListRows -Count 2 -Width 30 }
        $sel = [regex]::Replace($rows[0], "`e\[[0-9;]*m", '')
        $other = [regex]::Replace($rows[1], "`e\[[0-9;]*m", '')
        $sel | Should -Match '^▎'
        $other | Should -Match '^ '
        # accent bar must not change the row width
        Get-PssDisplayWidth $sel | Should -Be 30
    }

    It 'highlights the filter substring in matching rows' {
        $row = & $script:tui {
            $script:S.Filter = 'alp'
            $r = @(Get-TuiListRows -Count 1 -Width 30)[0]
            $script:S.Filter = ''
            $r
        }
        $t = & $script:tui { Get-PssTheme }
        $row | Should -Match ([regex]::Escape("$($t.BrCyan)alp"))
    }

    It 'shows a spinner on the running script and » on queued scripts' {
        $rows = & $script:tui {
            $script:S.Run = @{ Kind = 'run'; Name = 'alpha' }
            $script:S.Queue.Add(@{ Script = $script:S.Visible[1]; ExtraArgs = @() })
            $r = Get-TuiListRows -Count 2 -Width 30
            $script:S.Run = $null
            $script:S.Queue.Clear()
            $r
        }
        $alpha = [regex]::Replace($rows[0], "`e\[[0-9;]*m", '')
        $beta = [regex]::Replace($rows[1], "`e\[[0-9;]*m", '')
        $alpha | Should -Match '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'
        $beta | Should -Match '»'
    }
}

Describe 'detail rows' {
    It 'renders the requested number of rows at the pane width' {
        $rows = & $script:tui { $script:S.Selected = 0; Get-TuiDetailRows -Count 8 -Width 30 }
        $rows.Count | Should -Be 8
        foreach ($r in $rows) {
            $plain = [regex]::Replace($r, "`e\[[0-9;]*m", '')
            Get-PssDisplayWidth $plain | Should -Be 30
        }
    }

    It 'shows name, entry, schedule and last status for the highlighted script' {
        $plain = (& $script:tui { $script:S.Selected = 0; Get-TuiDetailRows -Count 8 -Width 34 }) |
            ForEach-Object { [regex]::Replace($_, "`e\[[0-9;]*m", '') }
        $text = $plain -join "`n"
        $text | Should -Match 'alpha'
        $text | Should -Match 'entry:'
        $text | Should -Match ([regex]::Escape('*/15'))
        $text | Should -Match '✓ success'
        $text | Should -Match '2h'
    }

    It 'says never run when there is no history for the script' {
        $plain = (& $script:tui { $script:S.Selected = 1; $r = Get-TuiDetailRows -Count 8 -Width 34; $script:S.Selected = 0; $r }) |
            ForEach-Object { [regex]::Replace($_, "`e\[[0-9;]*m", '') }
        ($plain -join "`n") | Should -Match 'never run'
    }

    It 'shows cpu/mem and start time when the last run recorded resources' {
        $rows = & $script:tui {
            $old = $script:S.Statuses['alpha']
            $script:S.Statuses['alpha'] = [pscustomobject]@{
                Status = 'success'; At = (Get-Date).AddMinutes(-5); DurationSec = 3
                Resources = [pscustomobject]@{ cpuAvgPercent = 1.5; cpuMaxPercent = 12; memAvgMb = 40; memMaxMb = 61 }
            }
            $r = Get-TuiDetailRows -Count 8 -Width 40
            $script:S.Statuses['alpha'] = $old
            $r
        }
        $text = ($rows | ForEach-Object { [regex]::Replace($_, "`e\[[0-9;]*m", '') }) -join "`n"
        $text | Should -Match 'cpu:\s+avg 1\.5% · max 12%'
        $text | Should -Match 'mem:\s+avg 40MB · max 61MB'
        $text | Should -Match 'at:'
    }

    It 'renders a placeholder when no script is selected' {
        $rows = & $script:tui {
            $old = $script:S.Visible
            $script:S.Visible = @()
            $r = Get-TuiDetailRows -Count 8 -Width 30
            $script:S.Visible = $old
            $r
        }
        $plain = [regex]::Replace($rows[0], "`e\[[0-9;]*m", '')
        $plain | Should -Match 'no script selected'
    }

    It 'splits the body into list + separator + card, and hides the card when short' {
        $tall = & $script:tui { @((Get-TuiListHeight), (Get-TuiDetailHeight), (Get-TuiBodyHeight)) }
        $tall[1] | Should -Be 8
        ($tall[0] + 1 + $tall[1]) | Should -Be $tall[2]
        $short = & $script:tui {
            $oldH = $script:S.H
            $script:S.H = 15
            $r = @((Get-TuiListHeight), (Get-TuiDetailHeight), (Get-TuiBodyHeight))
            $script:S.H = $oldH
            $r
        }
        $short[1] | Should -Be 0
        $short[0] | Should -Be $short[2]
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

    It 'shows a column header and compact absolute + relative times' {
        $rows = & $script:tui {
            $script:S.History = @{
                Items = @([pscustomobject]@{
                        script = 'alpha'; status = 'success'; trigger = 'cron'
                        startedAt = [datetime]::Now.AddHours(-3); durationSec = 4.2
                        resources = [pscustomobject]@{ cpuMaxPercent = 50; memMaxMb = 100; cpuSeries = @(1, 5) }
                    })
                Sel = 0; Top = 0; FilterName = ''
            }
            Get-TuiHistoryRows -Count 6 -Width 110
        }
        $all = [regex]::Replace(($rows -join "`n"), "`e\[[0-9;]*m", '')
        $all | Should -Match 'when\s+age\s+status\s+script\s+duration'
        $all | Should -Match '\d{2}-\d{2} \d{2}:\d{2}\s+3h'
    }

    It 'labels every column and keeps them aligned across name lengths' {
        $rows = & $script:tui {
            $mk = { param($n, $s) [pscustomobject]@{
                    script = $n; status = $s; trigger = 'manual'
                    startedAt = [datetime]::Now.AddHours(-1); durationSec = 95
                    resources = [pscustomobject]@{ cpuMaxPercent = 99.9; memMaxMb = 488.7; cpuSeries = @(1, 9) }
                } }
            $script:S.History = @{
                Items = @((& $mk 'short' 'success'), (& $mk 'enable_teams_transcriptions' 'failure'))
                Sel = 0; Top = 0; FilterName = ''
            }
            $r = Get-TuiHistoryRows -Count 8 -Width 120
            $script:S.History = $null
            $r
        }
        $plain = $rows | ForEach-Object { [regex]::Replace($_, "`e\[[0-9;]*m", '') }
        # header covers the resource columns too
        $plain[1] | Should -Match 'cpu\s+peak\s+trend\s+mem\s+peak\s+trigger'
        # 'cpu' starts at the same offset in both data rows despite name lengths
        $plain[2].IndexOf(' cpu ') | Should -BeGreaterThan 0
        $plain[2].IndexOf(' cpu ') | Should -Be ($plain[3].IndexOf(' cpu '))
        $plain[2].IndexOf(' mem ') | Should -Be ($plain[3].IndexOf(' mem '))
    }

    It 'r re-runs the selected entry through the normal run flow' {
        $r = & $script:tui {
            $script:S.Mode = 'history'
            $script:S.History = @{ Items = @([pscustomobject]@{ script = 'alpha'; status = 'failure' })
                Sel = 0; Top = 0; FilterName = '' }
            $script:S.Run = @{ Kind = 'task'; Name = 'busy' }   # forces the queue path (no real process)
            Invoke-TuiKeyHistory ([ConsoleKeyInfo]::new('r', [ConsoleKey]::R, $false, $false, $false))
            $res = @($script:S.Mode, $script:S.Queue.Count,
                $(if ($script:S.Queue.Count) { $script:S.Queue[0].Script.Name } else { '' }))
            $script:S.Run = $null; $script:S.Queue.Clear(); $script:S.History = $null; $script:S.Mode = 'list'
            $res
        }
        $r[0] | Should -Be 'list'
        $r[1] | Should -Be 1
        $r[2] | Should -Be 'alpha'
    }

    It 'mouse click selects the clicked history row' {
        $sel = & $script:tui {
            $script:S.Mode = 'history'
            $script:S.History = @{
                Items = @(0..9 | ForEach-Object { [pscustomobject]@{ script = "s$_"; status = 'success' } })
                Sel = 0; Top = 0; FilterName = ''
            }
            # body starts at screen row 3; +2 skips the title and header rows
            $lw = Get-TuiListWidth
            Invoke-TuiMouse -Button 0 -X ($lw + 5) -Y (3 + 2 + 4) -Press $true
            $r = $script:S.History.Sel
            $script:S.History = $null; $script:S.Mode = 'list'
            $r
        }
        $sel | Should -Be 4
    }

    It 'r on a script no longer in the repo reports it instead of crashing' {
        $r = & $script:tui {
            $script:S.Mode = 'history'
            $script:S.History = @{ Items = @([pscustomobject]@{ script = 'ghost'; status = 'failure' })
                Sel = 0; Top = 0; FilterName = '' }
            Invoke-TuiKeyHistory ([ConsoleKeyInfo]::new('r', [ConsoleKey]::R, $false, $false, $false))
            $res = @($script:S.Mode, $script:S.StatusMsg)
            $script:S.History = $null; $script:S.Mode = 'list'; $script:S.StatusMsg = ''
            $res
        }
        $r[0] | Should -Be 'history'
        $r[1] | Should -Match 'not found'
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

    It 'elides a long missing-module list to the row width' {
        $line = & $script:tui {
            $script:S.Mode = 'deps'
            $script:S.Deps = @{
                Script  = $script:S.Visible[0]
                Missing = @(1..15 | ForEach-Object { @{ Display = "Az.VeryLongModuleName$_" } })
                ExtraArgs = @(); InstallOnly = $false
            }
            $r = Get-TuiStatusLine -Width 80
            $script:S.Mode = 'list'; $script:S.Deps = $null
            $r
        }
        $plain = [regex]::Replace($line, "`e\[[0-9;]*m", '')
        (Get-PssDisplayWidth $plain) | Should -BeLessOrEqual 80
        $plain | Should -Match '…'
        $plain | Should -Match 'esc cancel'
    }

    It 'colors status messages by kind with an icon' {
        $lines = & $script:tui {
            Set-TuiStatus 'sync complete' -Kind ok
            $ok = Get-TuiStatusLine -Width 120
            Set-TuiStatus 'sync failed' -Kind err
            $err = Get-TuiStatusLine -Width 120
            $script:S.StatusMsg = ''; $script:S.StatusKind = 'info'
            @($ok, $err)
        }
        $t = & $script:tui { Get-PssTheme }
        $lines[0] | Should -Match ([regex]::Escape($t.Green))
        [regex]::Replace($lines[0], "`e\[[0-9;]*m", '') | Should -Match '✓ sync complete'
        $lines[1] | Should -Match ([regex]::Escape($t.Red))
        [regex]::Replace($lines[1], "`e\[[0-9;]*m", '') | Should -Match '✗ sync failed'
    }

    It 'shows elapsed time for a running task' {
        $line = & $script:tui {
            $script:S.Run = @{ Kind = 'task'; Name = 'sync scripts repo'
                StartedAt = (Get-Date).ToUniversalTime().AddSeconds(-90) }
            $r = Get-TuiStatusLine -Width 120
            $script:S.Run = $null
            $r
        }
        [regex]::Replace($line, "`e\[[0-9;]*m", '') | Should -Match 'sync scripts repo\s+1m30s'
    }
}

Describe 'banners' {
    It 'renders full-width rules colored by their icon' {
        $r = & $script:tui {
            $script:S.Lines.Clear(); $script:S.Wrapped.Clear()
            Add-TuiBanner '✓ alpha · success'
            Add-TuiBanner '✗ beta · failure'
            Add-TuiBanner '▶ gamma · started'
            $t = Get-PssTheme
            $rows = Get-TuiOutputRows -Count 3 -Width 40
            $res = @(
                ((Get-PssDisplayWidth $script:S.Wrapped[0]) -eq (Get-TuiWrapWidth)),
                $rows[0].StartsWith($t.Green),
                $rows[1].StartsWith($t.Red),
                $rows[2].StartsWith($t.Blue)
            )
            $script:S.Lines.Clear(); $script:S.Wrapped.Clear()
            $res
        }
        $r[0] | Should -BeTrue
        $r[1] | Should -BeTrue
        $r[2] | Should -BeTrue
        $r[3] | Should -BeTrue
    }
}

Describe 'output row coloring' {
    It 'paints real errors red but not lookalikes' {
        $flags = & $script:tui {
            $script:S.Lines.Clear(); $script:S.Wrapped.Clear()
            Add-TuiOutput @(
                'ERROR: something broke',
                'Unhandled exception at line 3',
                'found 0 errors in 12 files',
                'Invoke-Thing -ErrorAction Stop',
                'running error-report'
            )
            $t = Get-PssTheme
            $rows = Get-TuiOutputRows -Count 5 -Width 60
            $r = @($rows | ForEach-Object { $_.StartsWith($t.Red) })
            $script:S.Lines.Clear(); $script:S.Wrapped.Clear(); $script:S.Follow = $true
            $r
        }
        $flags[0] | Should -BeTrue    # ERROR: ...
        $flags[1] | Should -BeTrue    # exception
        $flags[2] | Should -BeFalse   # 0 errors
        $flags[3] | Should -BeFalse   # -ErrorAction
        $flags[4] | Should -BeFalse   # error-report (script name)
    }
}

Describe 'scrolled-back indicator' {
    It 'counts lines below the viewport only when not following' {
        $counts = & $script:tui {
            $script:S.Wrapped.Clear()
            1..50 | ForEach-Object { $script:S.Wrapped.Add("line $_") }
            $script:S.Scroll = 10
            $script:S.Follow = $false
            $notFollowing = Get-TuiMoreBelow -BodyHeight 20
            $script:S.Follow = $true
            $following = Get-TuiMoreBelow -BodyHeight 20
            $script:S.Wrapped.Clear(); $script:S.Scroll = 0
            @($notFollowing, $following)
        }
        $counts[0] | Should -Be 20
        $counts[1] | Should -Be 0
    }

    It 'is zero when the right pane is not showing output' {
        $n = & $script:tui {
            $script:S.Wrapped.Clear()
            1..50 | ForEach-Object { $script:S.Wrapped.Add("line $_") }
            $script:S.Follow = $false
            $script:S.Mode = 'history'
            $r = Get-TuiMoreBelow -BodyHeight 20
            $script:S.Mode = 'list'; $script:S.Follow = $true
            $script:S.Wrapped.Clear(); $script:S.Scroll = 0
            $r
        }
        $n | Should -Be 0
    }
}

Describe 'output search' {
    It 'jumps between matches with wrap-around and centers them' {
        $r = & $script:tui {
            $script:S.Wrapped.Clear()
            0..99 | ForEach-Object { $script:S.Wrapped.Add($(if ($_ -in 30, 60) { "has NEEDLE here" } else { "line $_" })) }
            $script:S.SearchTerm = 'needle'
            $script:S.Follow = $false; $script:S.Scroll = 0
            $scrolls = @()
            1..3 | ForEach-Object { Move-TuiSearch 1; $scrolls += $script:S.Scroll }
            $script:S.SearchTerm = ''; $script:S.Wrapped.Clear()
            $script:S.Scroll = 0; $script:S.Follow = $true
            $scrolls
        }
        # body height is 25 (H=30) → matches centered at target-12
        $r[0] | Should -Be 18   # line 30
        $r[1] | Should -Be 48   # line 60
        $r[2] | Should -Be 18   # wraps back to line 30
    }

    It 'highlights matches in the rendered rows' {
        $hasHl = & $script:tui {
            $script:S.Lines.Clear(); $script:S.Wrapped.Clear()
            Add-TuiOutput @('the needle is here')
            $script:S.SearchTerm = 'NEEDLE'
            $t = Get-PssTheme
            $rows = Get-TuiOutputRows -Count 3 -Width 40
            $r = $rows[0].Contains("$($t.SelBg)$($t.White)needle")
            $script:S.SearchTerm = ''; $script:S.Lines.Clear(); $script:S.Wrapped.Clear()
            $r
        }
        $hasHl | Should -BeTrue
    }
}

Describe 'pane focus' {
    It 'tab toggles focus and j scrolls the output pane when focused' {
        $r = & $script:tui {
            $script:S.Mode = 'list'; $script:S.FocusPane = 'list'
            Invoke-TuiKeyList ([ConsoleKeyInfo]::new([char]9, [ConsoleKey]::Tab, $false, $false, $false))
            $afterTab = $script:S.FocusPane
            $script:S.Wrapped.Clear()
            1..50 | ForEach-Object { $script:S.Wrapped.Add("l$_") }
            $script:S.Follow = $false; $script:S.Scroll = 0; $script:S.Selected = 0
            Invoke-TuiKeyList ([ConsoleKeyInfo]::new('j', [ConsoleKey]::J, $false, $false, $false))
            $res = @($afterTab, $script:S.Scroll, $script:S.Selected)
            $script:S.FocusPane = 'list'; $script:S.Wrapped.Clear()
            $script:S.Scroll = 0; $script:S.Follow = $true
            $res
        }
        $r[0] | Should -Be 'output'
        $r[1] | Should -Be 1      # output scrolled
        $r[2] | Should -Be 0      # selection untouched
    }

    It 'j moves the selection when the list pane is focused' {
        $r = & $script:tui {
            $script:S.Mode = 'list'; $script:S.FocusPane = 'list'; $script:S.Selected = 0
            Invoke-TuiKeyList ([ConsoleKeyInfo]::new('j', [ConsoleKey]::J, $false, $false, $false))
            $sel = $script:S.Selected
            $script:S.Selected = 0
            $sel
        }
        $r | Should -Be 1
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
