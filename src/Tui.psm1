# Tui.psm1 — the Night Owl themed terminal UI.
# Layout mirrors python-scripts-tui: header bar, script list (left) with
# status badges, live output panel (right) with scrollbar + sticky follow,
# status line and keybinding footer.

$script:S = $null          # UI state
$script:SpinnerFrames = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
$script:AnsiRegex = [regex]'\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\a]*\a'

# ===========================================================================
# Entry point
# ===========================================================================
function Start-PssTui {
    $cfg = Get-PssConfig
    $script:S = @{
        Quit         = $false
        W            = 0; H = 0
        Scripts      = @(); Visible = @()
        Selected     = 0
        ListTop      = 0
        FocusPane    = 'list'   # list|output — tab toggles; j/k etc. follow it
        Filter       = ''
        Statuses     = @{}
        Schedules    = @{}
        NextRunCache = @{}
        LastSync     = $null
        Lines        = [System.Collections.Generic.List[string]]::new()
        Wrapped      = [System.Collections.Generic.List[string]]::new()
        WrapWidth    = 0
        Scroll       = 0
        Follow       = $true
        SearchTerm   = ''
        OutTitle     = 'output'
        Mode         = 'list'   # list|deps|input|confirm|env|history|help
        Input        = $null
        Confirm      = $null
        Deps         = $null
        Env          = $null
        History      = $null
        Run          = $null
        Queue        = [System.Collections.Generic.List[object]]::new()
        AfterTask    = $null
        AfterTaskAlways = $null
        StatusMsg    = ''
        StatusMsgAt  = [datetime]::MinValue
        Tick         = 0
        LastSample   = [datetime]::MinValue
        AppVersion   = (Get-PssAppVersion)
        Dirty        = $true
    }

    Update-TuiScripts
    foreach ($w in (Get-PssConfigWarnings)) { Add-TuiOutput @("⚠ $w") }
    if (-not $script:S.Scripts -or $script:S.Scripts.Count -eq 0) {
        Add-TuiOutput @('no scripts found yet — press s to sync the scripts repo', '')
    }
    Add-TuiOutput @("PowerShell Scripts TUI — $($script:S.Scripts.Count) script(s) discovered", 'select a script and press Enter to run it — ? shows all keys')

    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    [Console]::TreatControlCAsInput = $true
    [Console]::Write("`e[?1049h`e[?25l`e[?1000;1006h")   # alt screen, hide cursor, SGR mouse
    try {
        if ([bool]$cfg.syncOnLaunch) { Invoke-TuiSync }
        while (-not $script:S.Quit) {
            $script:S.Tick++

            # resize?
            $w = [Console]::WindowWidth; $h = [Console]::WindowHeight
            if ($w -ne $script:S.W -or $h -ne $script:S.H) {
                $script:S.W = $w; $script:S.H = $h
                Reset-TuiWrap
                $script:S.Dirty = $true
            }

            # input
            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Escape -and [Console]::KeyAvailable) {
                    # escape sequence the runtime didn't parse (mouse, focus, …)
                    Read-TuiEscapeSequence -EscKey $key
                } else {
                    Invoke-TuiKey $key
                }
                $script:S.Dirty = $true
                if ($script:S.Quit) { break }
            }
            if ($script:S.Quit) { break }

            # active run/task
            if ($script:S.Run) { Update-TuiRun }

            # drain the run queue
            if (-not $script:S.Run -and $script:S.Queue.Count -gt 0 -and $script:S.Mode -eq 'list') {
                $next = $script:S.Queue[0]
                $script:S.Queue.RemoveAt(0)
                Start-TuiRunFlow -Script $next.Script -ExtraArgs $next.ExtraArgs
                $script:S.Dirty = $true
            }

            if ($script:S.Dirty -or $script:S.Run) {
                Show-TuiFrame
                $script:S.Dirty = $false
            }
            Start-Sleep -Milliseconds 33
        }
    } finally {
        try {
            if ($script:S.Run -and -not $script:S.Run.StartError -and
                $script:S.Run.Process -and -not $script:S.Run.Process.HasExited) {
                Stop-PssRun -Handle $script:S.Run -Reason 'killed'
                Complete-PssRun -Handle $script:S.Run | Out-Null
            }
        } catch { }
        [Console]::Write("`e[?1000;1006l`e[0m`e[?25h`e[?1049l")
        [Console]::TreatControlCAsInput = $false
    }
}

# ===========================================================================
# Mouse — SGR sequences arrive as raw chars after an Escape the runtime
# couldn't parse. Wheel scrolls the output panel, click selects a script.
# A bare Esc keypress has no pending input, so this never fires for it.
# ===========================================================================
function Read-TuiEscapeSequence {
    param([ConsoleKeyInfo]$EscKey)
    $first = [Console]::ReadKey($true)
    if ($first.KeyChar -ne '[') {
        # not a CSI sequence: process both keys normally
        Invoke-TuiKey $EscKey
        Invoke-TuiKey $first
        return
    }
    $buf = [Text.StringBuilder]::new()
    $guard = 0
    while ([Console]::KeyAvailable -and $guard -lt 32) {
        $guard++
        $c = [Console]::ReadKey($true).KeyChar
        [void]$buf.Append($c)
        if ($c -match '[A-Za-z~]') { break }
    }
    $seq = $buf.ToString()
    if ($seq -match '^<(\d+);(\d+);(\d+)([Mm])$') {
        Invoke-TuiMouse -Button ([int]$Matches[1]) -X ([int]$Matches[2]) -Y ([int]$Matches[3]) -Press ($Matches[4] -ceq 'M')
    }
    # anything else (focus events, unknown CSI) is ignored
}

function Invoke-TuiMouse {
    param([int]$Button, [int]$X, [int]$Y, [bool]$Press)
    if ($script:S.Mode -notin 'list', 'history') { return }
    if (($Button -band 0x40) -ne 0) {
        # wheel: 64 = up, 65 = down
        $delta = if (($Button -band 1) -eq 0) { -3 } else { 3 }
        if ($script:S.Mode -eq 'history') {
            $hi = $script:S.History
            $items = Get-TuiHistoryItems
            $hi.Sel = [Math]::Min([Math]::Max(0, $hi.Sel + $delta), [Math]::Max(0, $items.Count - 1))
        } else {
            Move-TuiScroll $delta
        }
        return
    }
    if ($script:S.Mode -eq 'list' -and $Press -and $Button -eq 0) {
        # left click (body starts at row 3)
        $lw = Get-TuiListWidth
        $row = $Y - 3
        if ($row -lt 0 -or $row -ge (Get-TuiBodyHeight)) { return }
        if ($X -le ($lw + 1)) {
            # list pane: select that row (and focus the pane)
            $script:S.FocusPane = 'list'
            $idx = $script:S.ListTop + $row
            if ($idx -lt $script:S.Visible.Count) { $script:S.Selected = $idx }
        }
        elseif ($X -ge ($lw + 3)) {
            # output pane: focus it; clicking a device-login code copies it
            $script:S.FocusPane = 'output'
            Copy-TuiCodeAt -Row $row -Cell ($X - $lw - 3)
        }
    }
}

# Click-to-copy for device-login codes (e.g. Microsoft "enter the code
# ABC123XYZ" sign-ins): if the clicked word in the output panel is 8-10
# uppercase letters/digits, copy it to the clipboard.
function Copy-TuiCodeAt {
    param([int]$Row, [int]$Cell)
    $idx = $script:S.Scroll + $Row
    if ($idx -ge $script:S.Wrapped.Count) { return }
    $line = $script:S.Wrapped[$idx]
    # clicked display cell -> char index (wide chars occupy 2 cells)
    $pos = -1; $cells = 0; $i = 0
    while ($i -lt $line.Length) {
        $len = if ([char]::IsHighSurrogate($line[$i]) -and ($i + 1) -lt $line.Length) { 2 } else { 1 }
        $cells += Get-PssDisplayWidth ($line.Substring($i, $len))
        if ($Cell -lt $cells) { $pos = $i; break }
        $i += $len
    }
    if ($pos -lt 0 -or "$($line[$pos])" -match '\s') { return }
    $start = $pos; while ($start -gt 0 -and "$($line[$start - 1])" -notmatch '\s') { $start-- }
    $end = $pos; while ($end -lt ($line.Length - 1) -and "$($line[$end + 1])" -notmatch '\s') { $end++ }
    $word = $line.Substring($start, $end - $start + 1).Trim('.', ',', ':', ';', '"', "'", '(', ')')
    if ($word -cmatch '^[A-Z0-9]{8,10}$') {
        $how = Copy-PssClipboard -Text $word
        Set-TuiStatus "code $word $how"
    }
}

# ===========================================================================
# Data refresh
# ===========================================================================
function Update-TuiScripts {
    $script:S.Scripts = @(Get-PssScripts)
    $script:S.Statuses = Get-PssLastStatuses
    $script:S.Schedules = Get-PssSchedules
    $script:S.LastSync = Get-PssLastSyncTime
    Update-TuiVisible
}

function Update-TuiVisible {
    $f = $script:S.Filter
    $script:S.Visible = @(
        # substring match, not -like: filter text must never be wildcard syntax
        if ($f) { $script:S.Scripts | Where-Object { $_.Name.Contains($f, [StringComparison]::OrdinalIgnoreCase) } }
        else { $script:S.Scripts }
    )
    if ($script:S.Selected -ge $script:S.Visible.Count) {
        $script:S.Selected = [Math]::Max(0, $script:S.Visible.Count - 1)
    }
}

function Get-TuiSelected {
    if ($script:S.Visible.Count -eq 0) { return $null }
    $script:S.Visible[$script:S.Selected]
}

# ===========================================================================
# Output buffer (raw lines + wrap cache)
# ===========================================================================
function Add-TuiOutput {
    param([string[]]$Lines)
    $cfg = Get-PssConfig
    foreach ($l in $Lines) {
        $clean = $script:AnsiRegex.Replace("$l", '')
        $script:S.Lines.Add($clean)
        foreach ($w in (Get-TuiWrappedLine $clean)) { $script:S.Wrapped.Add($w) }
    }
    $max = [int]$cfg.maxOutputLines
    if ($script:S.Lines.Count -gt $max) {
        $script:S.Lines.RemoveRange(0, $script:S.Lines.Count - $max)
        Reset-TuiWrap
    }
    $script:S.Dirty = $true
}

function Get-TuiWrapWidth {
    $lw = Get-TuiListWidth
    [Math]::Max(10, $script:S.W - $lw - 3 - 1)   # borders + scrollbar column
}

function Get-TuiWrappedLine {
    # word-aware wrap at display-cell width (wide chars count as 2 cells)
    param([string]$Line)
    $width = Get-TuiWrapWidth
    if (-not $Line) { return @('') }
    $out = @()
    $s = $Line
    while ($true) {
        if ((Get-PssDisplayWidth $s) -le $width) { $out += $s; break }
        # largest prefix that fits $width cells
        $w = 0; $i = 0; $cut = $s.Length
        while ($i -lt $s.Length) {
            $cw = Get-PssCodepointWidth ([char]::ConvertToUtf32($s, $i))
            if ($w + $cw -gt $width) { $cut = $i; break }
            $w += $cw
            $i += [char]::IsSurrogatePair($s, $i) ? 2 : 1
        }
        if ($cut -le 0) { $cut = 1 }
        $seg = $s.Substring(0, $cut)
        # prefer breaking at a space when one falls in the second half
        $break = $seg.LastIndexOf(' ')
        if ($break -gt [int]($cut / 2)) {
            $out += $seg.Substring(0, $break)
            $s = $s.Substring($break + 1)
        } else {
            $out += $seg
            $s = $s.Substring($cut)
        }
    }
    $out
}

function Reset-TuiWrap {
    $script:S.Wrapped = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $script:S.Lines) {
        foreach ($w in (Get-TuiWrappedLine $l)) { $script:S.Wrapped.Add($w) }
    }
}

function Clear-TuiOutput {
    $script:S.Lines.Clear(); $script:S.Wrapped.Clear()
    $script:S.Scroll = 0; $script:S.Follow = $true
    $script:S.Dirty = $true
}

function Set-TuiStatus {
    param([string]$Msg)
    $script:S.StatusMsg = $Msg
    $script:S.StatusMsgAt = Get-Date
    $script:S.Dirty = $true
}

# ===========================================================================
# Run lifecycle inside the TUI
# ===========================================================================
function Start-TuiRunFlow {
    param($Script, [string[]]$ExtraArgs = @())
    if ($script:S.Run) {
        # busy — queue it instead of refusing
        $script:S.Queue.Add(@{ Script = $Script; ExtraArgs = $ExtraArgs })
        Set-TuiStatus "queued $($Script.Name) (position $($script:S.Queue.Count)) — X clears the queue"
        return
    }
    $missing = @(Get-PssMissingDeps -Script $Script)
    if ($missing.Count -gt 0) {
        $script:S.Deps = @{ Script = $Script; Missing = $missing; ExtraArgs = $ExtraArgs }
        $script:S.Mode = 'deps'
        return
    }
    Start-TuiRun -Script $Script -ExtraArgs $ExtraArgs
}

function Start-TuiRun {
    param($Script, [string[]]$ExtraArgs = @())
    $script:S.OutTitle = "run: $($Script.Name)"
    Add-TuiOutput @('', ('─' * 8) + " $($Script.Name) — started $((Get-Date).ToString('HH:mm:ss')) " + ('─' * 8))
    $script:S.Run = Start-PssRun -Script $Script -Trigger 'manual' -ExtraArgs $ExtraArgs
    $script:S.Follow = $true
}

function Start-TuiTask {
    # After runs only on success; AfterAlways runs regardless and receives $ok
    param([string]$Name, [string]$FileName, [string[]]$Arguments,
        [scriptblock]$After = $null, [scriptblock]$AfterAlways = $null)
    if ($script:S.Run) { Set-TuiStatus 'something is already running — x to kill it first'; return }
    $script:S.OutTitle = $Name
    Add-TuiOutput @('', "── $Name ──")
    $script:S.Run = Start-PssTask -Name $Name -FileName $FileName -Arguments $Arguments
    $script:S.AfterTask = $After
    $script:S.AfterTaskAlways = $AfterAlways
    $script:S.Follow = $true
}

function Update-TuiRun {
    $h = $script:S.Run
    $new = @(Update-PssRun -Handle $h)
    if ($new.Count -gt 0) { Add-TuiOutput $new }

    $cfg = Get-PssConfig
    if (((Get-Date) - $script:S.LastSample).TotalMilliseconds -ge [int]$cfg.monitorIntervalMs) {
        Measure-PssResources -Handle $h
        $script:S.LastSample = Get-Date
    }

    if (Test-PssRunFinished -Handle $h) {
        $result = Complete-PssRun -Handle $h
        $script:S.Run = $null
        if ($h.Kind -eq 'run') {
            $r = $result.resources
            Add-TuiOutput @(
                "── $($result.script): $($result.status) (exit $($result.exitCode)) in $(Format-PssDuration $result.durationSec) ──",
                "   cpu avg $($r.cpuAvgPercent)% / peak $($r.cpuMaxPercent)%   mem avg $($r.memAvgMb)MB / peak $($r.memMaxMb)MB",
                "   log: $($result.logFile)"
            )
            $script:S.Statuses[$result.script] = [pscustomobject]@{
                Status      = $result.status
                At          = (Get-Date)
                DurationSec = [double]$result.durationSec
            }
            Set-TuiStatus "$($result.script): $($result.status)"
        } else {
            $ok = ($h.ExitCode -eq 0)
            Add-TuiOutput @("── $($h.Name): $(if ($ok) {'done'} else {"failed (exit $($h.ExitCode))"}) ──")
            $after = $script:S.AfterTask
            $always = $script:S.AfterTaskAlways
            $script:S.AfterTask = $null
            $script:S.AfterTaskAlways = $null
            if ($ok -and $after) { & $after }
            if ($always) { & $always $ok }
        }
        $script:S.Dirty = $true
    }
}

# ===========================================================================
# Actions
# ===========================================================================
function Invoke-TuiSync {
    # runs in a child pwsh via the task machinery so the UI stays responsive
    # during slow clones/fetches (spinner, kill key, scrolling all work)
    if ($script:S.Run) { Set-TuiStatus 'something is already running — x to kill it first'; return }
    $app = Get-PssAppDir
    $cfg = Get-PssConfig
    $cmd = @"
Import-Module '$app/src/Core.psm1', '$app/src/Scripts.psm1' -DisableNameChecking | Out-Null
Initialize-Pss -AppDir '$app'
`$ok = Sync-PssRepo -OnOutput { param(`$l) Write-Host `$l }
exit ([int](-not `$ok))
"@
    Start-TuiTask -Name 'sync scripts repo' -FileName ([string]$cfg.pwshBin) `
        -Arguments @('-NoProfile', '-NonInteractive', '-Command', $cmd) -AfterAlways {
        param($ok)
        Update-TuiScripts
        Add-TuiOutput @("$($script:S.Scripts.Count) script(s) discovered")
        Set-TuiStatus $(if ($ok) { 'sync complete' } else { 'sync failed' })
    }
}

function Invoke-TuiDepScan {
    $sel = Get-TuiSelected
    if (-not $sel) { return }
    $deps = @(Get-PssScriptDeps -Script $sel)
    $missing = @(Get-PssMissingDeps -Script $sel)
    $script:S.OutTitle = "deps: $($sel.Name)"
    Add-TuiOutput @('', "── dependency scan: $($sel.Name) ──",
        "declared/imported modules: $(if ($deps) { ($deps | ForEach-Object Display) -join ', ' } else { '(none)' })",
        "missing: $(if ($missing) { ($missing | ForEach-Object Display) -join ', ' } else { '(none)' })")
    if ($missing.Count -gt 0) {
        $script:S.Deps = @{ Script = $sel; Missing = $missing; ExtraArgs = @(); InstallOnly = $true }
        $script:S.Mode = 'deps'
    }
}

function Invoke-TuiLint {
    # PSScriptAnalyzer gate — analyzer is saved into <dataDir>/tools on first use
    $sel = Get-TuiSelected
    if (-not $sel) { return }
    $toolsDir = Join-Path (Get-PssPaths).DataDir 'tools'
    $entryEsc = $sel.Entry -replace "'", "''"
    $cfg = Get-PssConfig
    $cmd = @"
`$tools = '$toolsDir'
`$env:PSModulePath = "`$tools$([IO.Path]::PathSeparator)`$env:PSModulePath"
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Write-Host 'installing PSScriptAnalyzer (first use)...'
    New-Item -ItemType Directory -Path `$tools -Force | Out-Null
    if (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
        Save-PSResource -Name PSScriptAnalyzer -Path `$tools -Repository PSGallery -TrustRepository -ErrorAction Stop
    } else {
        Save-Module -Name PSScriptAnalyzer -Path `$tools -Repository PSGallery -Force -ErrorAction Stop
    }
}
`$results = @(Invoke-ScriptAnalyzer -Path '$entryEsc' -Severity Information, Warning, Error)
if (`$results.Count -eq 0) { Write-Host 'no findings — clean'; exit 0 }
foreach (`$r in `$results) {
    Write-Host ('{0,-11} L{1,-4} {2}: {3}' -f `$r.Severity, `$r.Line, `$r.RuleName, `$r.Message)
}
Write-Host "`$(`$results.Count) finding(s)"
exit ([int](@(`$results | Where-Object Severity -eq 'Error').Count -gt 0))
"@
    Start-TuiTask -Name "lint: $($sel.Name)" -FileName ([string]$cfg.pwshBin) `
        -Arguments @('-NoProfile', '-NonInteractive', '-Command', $cmd)
}

function Invoke-TuiSelfUpdate {
    if ($script:S.Run) { Set-TuiStatus 'something is already running — x to kill it first'; return }
    $app = Get-PssAppDir
    Start-TuiTask -Name 'update app (git pull --ff-only)' -FileName 'git' `
        -Arguments @('-C', $app, 'pull', '--ff-only') -AfterAlways {
        param($ok)
        Set-TuiStatus $(if ($ok) { 'app updated — restart psscripts to apply' } else { 'app update failed' })
    }
}

function Invoke-TuiInstallDeps {
    $d = $script:S.Deps
    $script:S.Deps = $null
    $cfg = Get-PssConfig
    $cmd = Get-PssInstallCommand -Script $d.Script -Modules $d.Missing
    $after = $null
    if (-not $d.InstallOnly) {
        $target = $d.Script; $extra = $d.ExtraArgs
        $after = { Start-TuiRun -Script $target -ExtraArgs $extra }.GetNewClosure()
    }
    Start-TuiTask -Name "install deps: $($d.Script.Name)" -FileName ([string]$cfg.pwshBin) `
        -Arguments @('-NoProfile', '-NonInteractive', '-Command', $cmd) -After $after
}

function Invoke-TuiUpdate {
    & sudo -n true 2>$null
    $sudoOk = ($LASTEXITCODE -eq 0)
    $moduleStage = {
        $cfg2 = Get-PssConfig
        Start-TuiTask -Name 'upgrade script modules' -FileName ([string]$cfg2.pwshBin) `
            -Arguments @('-NoProfile', '-NonInteractive', '-Command', (Get-PssModuleUpgradeCommand))
    }
    if ($sudoOk) {
        Start-TuiTask -Name 'update PowerShell (apt)' -FileName 'bash' `
            -Arguments @('-c', 'sudo -n apt-get update && sudo -n apt-get install -y --only-upgrade powershell') `
            -After $moduleStage
    } else {
        Add-TuiOutput @('', '── system update ──',
            'sudo requires a password here. Run manually:',
            '  sudo apt-get update && sudo apt-get install -y --only-upgrade powershell',
            'or allow it without a password:',
            "  echo `"`$USER ALL=(root) NOPASSWD: /usr/bin/apt-get`" | sudo tee /etc/sudoers.d/psscripts-apt",
            'continuing with module upgrades...')
        & $moduleStage
    }
}

function Invoke-TuiCopy {
    $text = ($script:S.Lines -join "`n")
    $how = Copy-PssClipboard -Text $text
    Set-TuiStatus "output $how"
}

function Invoke-TuiWebhookTest {
    Set-TuiStatus 'sending test event...'
    Show-TuiFrame
    $ok = Send-PssWebhookTest
    Set-TuiStatus $(if ($ok) { 'webhook test event sent ✓' } else { 'webhook test FAILED — check n8nWebhookUrl' })
}

function Open-TuiHistory {
    $items = @(Get-PssHistory -Last 200)
    [array]::Reverse($items)
    $script:S.History = @{ Items = $items; Sel = 0; Top = 0; FilterName = '' }
    $script:S.Mode = 'history'
}

# current history items honoring the per-script filter (f key)
function Get-TuiHistoryItems {
    $hi = $script:S.History
    if ($hi.FilterName) { return @($hi.Items | Where-Object { "$($_.script)" -eq $hi.FilterName }) }
    @($hi.Items)
}

# load a past run's log file into the output panel
function Open-TuiHistoryLog {
    $items = Get-TuiHistoryItems
    $hi = $script:S.History
    if ($items.Count -eq 0 -or $hi.Sel -ge $items.Count) { return }
    $item = $items[$hi.Sel]
    if (-not $item.logFile -or -not (Test-Path "$($item.logFile)")) {
        Set-TuiStatus "log file not found: $($item.logFile)"
        return
    }
    $cfg = Get-PssConfig
    $content = @(Get-Content "$($item.logFile)" -Tail ([int]$cfg.maxOutputLines) -ErrorAction SilentlyContinue)
    $script:S.History = $null
    $script:S.Mode = 'list'
    $script:S.OutTitle = "log: $($item.script)"
    Add-TuiOutput (@('', "── log: $($item.script) @ $($item.startedAt) ($($item.status)) ──") + $content)
    $script:S.Follow = $true
}

function Open-TuiEnvEditor {
    $sel = Get-TuiSelected
    if (-not $sel) { return }
    $text = @()
    if (Test-Path $sel.EnvFile) { $text = @(Get-Content $sel.EnvFile) }
    elseif (Test-Path $sel.EnvExample) { $text = @(Get-Content $sel.EnvExample) }
    if ($text.Count -eq 0) { $text = @('') }
    $script:S.Env = @{
        Script = $sel
        Lines  = [System.Collections.Generic.List[string]]::new([string[]]$text)
        CX     = 0; CY = 0; ScrollY = 0; ScrollX = 0
        Dirty  = $false; EscArmed = $false
    }
    $script:S.Mode = 'env'
}

function Open-TuiCronInput {
    $sel = Get-TuiSelected
    if (-not $sel) { return }
    $current = if ($script:S.Schedules.ContainsKey($sel.Name)) { $script:S.Schedules[$sel.Name] } else { '' }
    Open-TuiInput -Prompt "schedule for $($sel.Name) (cron / @daily / plain English; empty = remove)" -Text $current -OnSubmit {
        param($value)
        $sel2 = Get-TuiSelected
        if (-not $sel2) { return }
        if (-not $value.Trim()) {
            if (Remove-PssSchedule -Name $sel2.Name) { Set-TuiStatus "schedule removed for $($sel2.Name)" }
            else { Set-TuiStatus 'failed to update crontab' }
            $script:S.Schedules = Get-PssSchedules
            return
        }
        $conv = Convert-PssToCron -Text $value
        if (-not $conv.Expression) { Set-TuiStatus "cron: $($conv.Error)"; return }
        $expr = $conv.Expression
        $name = $sel2.Name
        Open-TuiConfirm -Message "schedule '$name' as:  $expr  ?" -OnYes {
            if (Set-PssSchedule -Name $name -Expression $expr) { Set-TuiStatus "scheduled $name : $expr" }
            else { Set-TuiStatus 'failed to update crontab' }
            $script:S.Schedules = Get-PssSchedules
        }.GetNewClosure()
    }
}

function Open-TuiInput {
    param([string]$Prompt, [string]$Text = '', [scriptblock]$OnSubmit, [string]$Kind = 'generic')
    $script:S.Input = @{ Prompt = $Prompt; Text = $Text; Cursor = $Text.Length; OnSubmit = $OnSubmit; Kind = $Kind; Original = $Text }
    $script:S.Mode = 'input'
}

function Open-TuiConfirm {
    param([string]$Message, [scriptblock]$OnYes)
    $script:S.Confirm = @{ Message = $Message; OnYes = $OnYes }
    $script:S.Mode = 'confirm'
}

# ===========================================================================
# Key handling
# ===========================================================================
function Invoke-TuiKey {
    param([ConsoleKeyInfo]$Key)
    switch ($script:S.Mode) {
        'list' { Invoke-TuiKeyList $Key }
        'deps' { Invoke-TuiKeyDeps $Key }
        'input' { Invoke-TuiKeyInput $Key }
        'confirm' { Invoke-TuiKeyConfirm $Key }
        'env' { Invoke-TuiKeyEnv $Key }
        'history' { Invoke-TuiKeyHistory $Key }
        'help' { $script:S.Mode = 'list' }   # any key closes the help overlay
    }
}

function Invoke-TuiKeyList {
    param([ConsoleKeyInfo]$Key)
    $ctrlC = ($Key.Key -eq 'C' -and $Key.Modifiers -band [ConsoleModifiers]::Control)
    if ($ctrlC -or $Key.KeyChar -eq 'q') {
        if ($script:S.Run) {
            Open-TuiConfirm -Message 'a script is running — kill it and quit?' -OnYes { $script:S.Quit = $true }
        } else { $script:S.Quit = $true }
        return
    }
    if ($Key.Key -eq [ConsoleKey]::F -and ($Key.Modifiers -band [ConsoleModifiers]::Control)) {
        Open-TuiInput -Prompt 'search output (empty = clear)' -Text $script:S.SearchTerm -OnSubmit {
            param($value)
            $script:S.SearchTerm = $value.Trim()
            if ($script:S.SearchTerm) { Move-TuiSearch 1 } else { Set-TuiStatus 'search cleared' }
        }
        return
    }
    if ($Key.Key -eq [ConsoleKey]::Tab) {
        $script:S.FocusPane = if ($script:S.FocusPane -eq 'output') { 'list' } else { 'output' }
        Set-TuiStatus "focus: $($script:S.FocusPane) pane (j/k scroll it — tab switches back)"
        return
    }
    # with the output pane focused, navigation keys scroll it instead
    if ($script:S.FocusPane -eq 'output') {
        switch ($Key.Key) {
            'UpArrow' { Move-TuiScroll -1; return }
            'DownArrow' { Move-TuiScroll 1; return }
        }
        switch -CaseSensitive ($Key.KeyChar) {
            'k' { Move-TuiScroll -1; return }
            'j' { Move-TuiScroll 1; return }
            'g' { $script:S.Scroll = 0; $script:S.Follow = $false; $script:S.Dirty = $true; return }
            'G' { $script:S.Follow = $true; $script:S.Dirty = $true; return }
        }
    }
    switch ($Key.Key) {
        'UpArrow' { Move-TuiSelection -1; return }
        'DownArrow' { Move-TuiSelection 1; return }
        'Enter' { $sel = Get-TuiSelected; if ($sel) { Start-TuiRunFlow -Script $sel }; return }
        'PageUp' { Move-TuiScroll (-(Get-TuiBodyHeight)); return }
        'PageDown' { Move-TuiScroll (Get-TuiBodyHeight); return }
        'Home' { $script:S.Scroll = 0; $script:S.Follow = $false; $script:S.Dirty = $true; return }
        'End' { $script:S.Follow = $true; $script:S.Dirty = $true; return }
    }
    switch -CaseSensitive ($Key.KeyChar) {
        'k' { Move-TuiSelection -1 }
        'j' { Move-TuiSelection 1 }
        'g' { $script:S.Selected = 0; $script:S.Dirty = $true }
        'G' { $script:S.Selected = [Math]::Max(0, $script:S.Visible.Count - 1); $script:S.Dirty = $true }
        'r' { $sel = Get-TuiSelected; if ($sel) { Start-TuiRunFlow -Script $sel } }
        'a' {
            $sel = Get-TuiSelected
            if ($sel) {
                Open-TuiInput -Prompt "extra args for $($sel.Name) (quotes group words)" -OnSubmit {
                    param($value)
                    $sel2 = Get-TuiSelected
                    if ($sel2) {
                        Start-TuiRunFlow -Script $sel2 -ExtraArgs @(Split-PssArguments $value)
                    }
                }
            }
        }
        'e' { Open-TuiCronInput }
        'v' { Open-TuiEnvEditor }
        's' { Invoke-TuiSync }
        'i' { Invoke-TuiDepScan }
        'l' { Invoke-TuiLint }
        'u' { Invoke-TuiUpdate }
        'U' { Invoke-TuiSelfUpdate }
        'h' { Open-TuiHistory }
        't' { Invoke-TuiWebhookTest }
        'x' {
            if ($script:S.Run) {
                Stop-PssRun -Handle $script:S.Run -Reason 'killed'
                Set-TuiStatus 'kill signal sent'
            } else { Set-TuiStatus 'nothing is running' }
        }
        'X' {
            if ($script:S.Queue.Count -gt 0) {
                $n = $script:S.Queue.Count
                $script:S.Queue.Clear()
                Set-TuiStatus "cleared $n queued run(s)"
            } else { Set-TuiStatus 'queue is empty' }
        }
        'n' { Move-TuiSearch 1 }
        'N' { Move-TuiSearch -1 }
        'y' { Invoke-TuiCopy }
        'c' { Clear-TuiOutput }
        '?' { $script:S.Mode = 'help' }
        '/' {
            # live filter: applied on every keystroke, esc restores
            Open-TuiInput -Prompt 'filter scripts (empty = clear)' -Text $script:S.Filter -Kind 'filter' -OnSubmit {
                param($value)
                $script:S.Filter = $value.Trim()
                Update-TuiVisible
            }
        }
    }
}

function Move-TuiSelection {
    param([int]$Delta)
    if ($script:S.Visible.Count -eq 0) { return }
    $script:S.Selected = [Math]::Min([Math]::Max(0, $script:S.Selected + $Delta), $script:S.Visible.Count - 1)
    $script:S.Dirty = $true
}

function Move-TuiScroll {
    param([int]$Delta)
    $maxScroll = [Math]::Max(0, $script:S.Wrapped.Count - (Get-TuiBodyHeight))
    $cur = if ($script:S.Follow) { $maxScroll } else { $script:S.Scroll }
    $script:S.Scroll = [Math]::Min([Math]::Max(0, $cur + $Delta), $maxScroll)
    $script:S.Follow = ($script:S.Scroll -ge $maxScroll)
    $script:S.Dirty = $true
}

# jump to the next (+1) / previous (-1) output line matching SearchTerm.
# Matches are recomputed each call so new output is always searchable.
function Move-TuiSearch {
    param([int]$Dir)
    $term = $script:S.SearchTerm
    if (-not $term) { Set-TuiStatus 'no search term — ctrl+f to search the output'; return }
    $wrapped = $script:S.Wrapped
    $hits = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $wrapped.Count; $i++) {
        if ($wrapped[$i].Contains($term, [StringComparison]::OrdinalIgnoreCase)) { $hits.Add($i) }
    }
    if ($hits.Count -eq 0) { Set-TuiStatus "no matches for '$term'"; return }
    $body = Get-TuiBodyHeight
    $maxScroll = [Math]::Max(0, $wrapped.Count - $body)
    $cur = if ($script:S.Follow) { $maxScroll } else { $script:S.Scroll }
    $anchor = $cur + [int]($body / 2)   # the centered line; jumps land matches here
    $target = -1
    if ($Dir -gt 0) {
        foreach ($h in $hits) { if ($h -gt $anchor) { $target = $h; break } }
        if ($target -lt 0) { $target = $hits[0] }   # wrap to the first match
    } else {
        for ($k = $hits.Count - 1; $k -ge 0; $k--) { if ($hits[$k] -lt $anchor) { $target = $hits[$k]; break } }
        if ($target -lt 0) { $target = $hits[$hits.Count - 1] }
    }
    $script:S.Scroll = [Math]::Min([Math]::Max(0, $target - [int]($body / 2)), $maxScroll)
    $script:S.Follow = $false
    $script:S.Dirty = $true
    Set-TuiStatus "match $($hits.IndexOf($target) + 1)/$($hits.Count) for '$term' — n next · N prev"
}

function Invoke-TuiKeyDeps {
    param([ConsoleKeyInfo]$Key)
    if ($Key.Key -eq 'Escape') { $script:S.Deps = $null; $script:S.Mode = 'list'; Set-TuiStatus 'cancelled'; return }
    switch ($Key.KeyChar) {
        'y' { $script:S.Mode = 'list'; Invoke-TuiInstallDeps }
        'n' {
            $d = $script:S.Deps; $script:S.Deps = $null; $script:S.Mode = 'list'
            if (-not $d.InstallOnly) { Start-TuiRun -Script $d.Script -ExtraArgs $d.ExtraArgs }
        }
    }
}

function Invoke-TuiKeyConfirm {
    param([ConsoleKeyInfo]$Key)
    if ($Key.Key -eq 'Escape' -or $Key.KeyChar -eq 'n') {
        $script:S.Confirm = $null; $script:S.Mode = 'list'; Set-TuiStatus 'cancelled'; return
    }
    if ($Key.KeyChar -eq 'y' -or $Key.Key -eq 'Enter') {
        $c = $script:S.Confirm; $script:S.Confirm = $null; $script:S.Mode = 'list'
        if ($c.OnYes) { & $c.OnYes }
    }
}

function Invoke-TuiKeyInput {
    param([ConsoleKeyInfo]$Key)
    $in = $script:S.Input
    switch ($Key.Key) {
        'Escape' {
            $script:S.Input = $null; $script:S.Mode = 'list'
            if ($in.Kind -eq 'filter') {
                # live filter: esc restores what was there before
                $script:S.Filter = $in.Original
                Update-TuiVisible
            }
            return
        }
        'Enter' {
            $script:S.Input = $null; $script:S.Mode = 'list'
            if ($in.OnSubmit) { & $in.OnSubmit $in.Text }
            return
        }
        'Backspace' {
            if ($in.Cursor -gt 0) {
                $in.Text = $in.Text.Remove($in.Cursor - 1, 1); $in.Cursor--
                Update-TuiInputLive $in
            }
            return
        }
        'Delete' {
            if ($in.Cursor -lt $in.Text.Length) {
                $in.Text = $in.Text.Remove($in.Cursor, 1)
                Update-TuiInputLive $in
            }
            return
        }
        'LeftArrow' { if ($in.Cursor -gt 0) { $in.Cursor-- }; return }
        'RightArrow' { if ($in.Cursor -lt $in.Text.Length) { $in.Cursor++ }; return }
        'Home' { $in.Cursor = 0; return }
        'End' { $in.Cursor = $in.Text.Length; return }
    }
    if ($Key.KeyChar -and -not [char]::IsControl($Key.KeyChar)) {
        $in.Text = $in.Text.Insert($in.Cursor, $Key.KeyChar)
        $in.Cursor++
        Update-TuiInputLive $in
    }
}

# filter-as-you-type: apply the filter on every edit
function Update-TuiInputLive {
    param($In)
    if ($In.Kind -ne 'filter') { return }
    $script:S.Filter = $In.Text.Trim()
    Update-TuiVisible
}

function Invoke-TuiKeyEnv {
    param([ConsoleKeyInfo]$Key)
    $ed = $script:S.Env
    $ctrl = [bool]($Key.Modifiers -band [ConsoleModifiers]::Control)

    if ($Key.Key -eq 'Escape') {
        if ($ed.Dirty -and -not $ed.EscArmed) {
            # unsaved-changes guard: first esc warns, second discards
            $ed.EscArmed = $true
            Set-TuiStatus 'unsaved changes — esc again to discard, ctrl+s to save'
            return
        }
        $script:S.Env = $null; $script:S.Mode = 'list'; Set-TuiStatus '.env edit cancelled'; return
    }
    if ($ctrl -and $Key.Key -eq 'S') {
        $target = $ed.Script.EnvFile
        ($ed.Lines -join "`n") + "`n" | Set-Content -Path $target -NoNewline -Encoding UTF8
        foreach ($kv in (Read-PssEnvFile $target).GetEnumerator()) { Register-PssSecret -Name $kv.Key -Value $kv.Value -Force }
        $script:S.Env = $null; $script:S.Mode = 'list'
        Set-TuiStatus "saved $(Split-Path $target -Leaf) for $($ed.Script.Name)"
        return
    }
    $ed.EscArmed = $false

    $line = $ed.Lines[$ed.CY]
    switch ($Key.Key) {
        'UpArrow' { if ($ed.CY -gt 0) { $ed.CY--; $ed.CX = [Math]::Min($ed.CX, $ed.Lines[$ed.CY].Length) }; return }
        'DownArrow' { if ($ed.CY -lt $ed.Lines.Count - 1) { $ed.CY++; $ed.CX = [Math]::Min($ed.CX, $ed.Lines[$ed.CY].Length) }; return }
        'LeftArrow' {
            if ($ed.CX -gt 0) { $ed.CX-- }
            elseif ($ed.CY -gt 0) { $ed.CY--; $ed.CX = $ed.Lines[$ed.CY].Length }
            return
        }
        'RightArrow' {
            if ($ed.CX -lt $line.Length) { $ed.CX++ }
            elseif ($ed.CY -lt $ed.Lines.Count - 1) { $ed.CY++; $ed.CX = 0 }
            return
        }
        'Home' { $ed.CX = 0; return }
        'End' { $ed.CX = $line.Length; return }
        'Enter' {
            $before = $line.Substring(0, $ed.CX); $after = $line.Substring($ed.CX)
            $ed.Lines[$ed.CY] = $before
            $ed.Lines.Insert($ed.CY + 1, $after)
            $ed.CY++; $ed.CX = 0
            $ed.Dirty = $true
            return
        }
        'Backspace' {
            if ($ed.CX -gt 0) {
                $ed.Lines[$ed.CY] = $line.Remove($ed.CX - 1, 1); $ed.CX--
                $ed.Dirty = $true
            } elseif ($ed.CY -gt 0) {
                $prev = $ed.Lines[$ed.CY - 1]
                $ed.CX = $prev.Length
                $ed.Lines[$ed.CY - 1] = $prev + $line
                $ed.Lines.RemoveAt($ed.CY)
                $ed.CY--
                $ed.Dirty = $true
            }
            return
        }
        'Delete' {
            if ($ed.CX -lt $line.Length) { $ed.Lines[$ed.CY] = $line.Remove($ed.CX, 1); $ed.Dirty = $true }
            elseif ($ed.CY -lt $ed.Lines.Count - 1) {
                $ed.Lines[$ed.CY] = $line + $ed.Lines[$ed.CY + 1]
                $ed.Lines.RemoveAt($ed.CY + 1)
                $ed.Dirty = $true
            }
            return
        }
    }
    if ($Key.KeyChar -and -not [char]::IsControl($Key.KeyChar)) {
        $ed.Lines[$ed.CY] = $line.Insert($ed.CX, $Key.KeyChar)
        $ed.CX++
        $ed.Dirty = $true
    }
}

function Invoke-TuiKeyHistory {
    param([ConsoleKeyInfo]$Key)
    $hi = $script:S.History
    $page = Get-TuiBodyHeight
    $items = Get-TuiHistoryItems
    $max = [Math]::Max(0, $items.Count - 1)
    if ($Key.Key -in 'Escape', 'Q' -or $Key.KeyChar -in 'q', 'h') { $script:S.History = $null; $script:S.Mode = 'list'; return }
    if ($Key.Key -eq 'Enter') { Open-TuiHistoryLog; return }
    if ($Key.KeyChar -ceq 'f') {
        # toggle: filter history to the selected run's script
        if ($hi.FilterName) { $hi.FilterName = '' }
        elseif ($items.Count -gt 0 -and $hi.Sel -le $max) { $hi.FilterName = "$($items[$hi.Sel].script)" }
        $hi.Sel = 0
        return
    }
    switch ($Key.Key) {
        'UpArrow' { $hi.Sel = [Math]::Max(0, $hi.Sel - 1) }
        'DownArrow' { $hi.Sel = [Math]::Min($max, $hi.Sel + 1) }
        'PageUp' { $hi.Sel = [Math]::Max(0, $hi.Sel - $page) }
        'PageDown' { $hi.Sel = [Math]::Min($max, $hi.Sel + $page) }
        'Home' { $hi.Sel = 0 }
        'End' { $hi.Sel = $max }
    }
    switch -CaseSensitive ($Key.KeyChar) {
        'k' { $hi.Sel = [Math]::Max(0, $hi.Sel - 1) }
        'j' { $hi.Sel = [Math]::Min($max, $hi.Sel + 1) }
    }
}

# ===========================================================================
# Rendering
# ===========================================================================
function Get-TuiListWidth {
    [Math]::Max(24, [Math]::Min(34, [int]($script:S.W / 3)))
}

function Get-TuiBodyHeight {
    [Math]::Max(3, $script:S.H - 5)   # header + top/bottom borders + status + keys
}

function Format-TuiPad {
    # display-cell aware pad/truncate (wide chars are 2 cells)
    param([string]$Text, [int]$Width)
    Format-PssCell -Text $Text -Width $Width -Ellipsis
}

function Show-TuiFrame {
    $t = Get-PssTheme
    $W = $script:S.W; $H = $script:S.H
    if ($W -lt 40 -or $H -lt 10) {
        [Console]::Write("`e[2J`e[Hterminal too small")
        return
    }
    $lw = Get-TuiListWidth
    $rw = $W - $lw - 3
    $body = Get-TuiBodyHeight
    $sb = [Text.StringBuilder]::new(64KB)
    [void]$sb.Append("`e[?2026h`e[H")   # synchronized update, home

    $bg = $t.Bg; $fg = $t.Fg; $reset = "$($t.Reset)$bg$fg"

    # ---- header -----------------------------------------------------------
    $title = ' PowerShell Scripts TUI '
    $repoUrl = Get-PssScriptsRepo
    $repo = if ($repoUrl) { ($repoUrl -replace '^https://(x-access-token:[^@]+@)?', '') } else { 'no scripts repo configured' }
    $ver = if ($script:S.AppVersion) { " · $($script:S.AppVersion)" } else { '' }
    $sync = ''
    if ($script:S.ContainsKey('LastSync') -and $script:S.LastSync) {
        $sync = " · synced $(Format-PssRelativeTime ((Get-Date) - $script:S.LastSync).TotalSeconds) ago"
    }
    $right = " $repo$sync · $([Environment]::MachineName)$ver "
    if ($title.Length + $right.Length -gt $W) {
        $right = Format-TuiPad -Text $right -Width ([Math]::Max(0, $W - $title.Length))
    }
    $mid = [Math]::Max(0, $W - $title.Length - $right.Length)
    [void]$sb.Append("$($t.BlueBg)$($t.BlackFg)$($t.Bold)$title$(' ' * $mid)$right$($t.Reset)")
    [void]$sb.Append("$reset`e[K`n")

    # ---- panel top border --------------------------------------------------
    $listTitle = if ($script:S.Filter) { " scripts /$($script:S.Filter) " } else { ' scripts ' }
    $spin = ''
    if ($script:S.Run) { $spin = $script:SpinnerFrames[$script:S.Tick % $script:SpinnerFrames.Count] + ' ' }
    $outTitle = " $spin$($script:S.OutTitle) "
    if ($listTitle.Length -gt $lw) { $listTitle = $listTitle.Substring(0, $lw) }
    if ($outTitle.Length -gt $rw) { $outTitle = $outTitle.Substring(0, $rw) }
    # focused pane's title is highlighted (tab switches)
    $listTitleColor = if ($script:S.FocusPane -eq 'output') { $t.Blue } else { $t.BrCyan }
    $outTitleColor = if ($script:S.FocusPane -eq 'output') { $t.BrCyan } else { $t.Blue }
    [void]$sb.Append("$reset$($t.Muted)┌")
    [void]$sb.Append("$listTitleColor$listTitle$($t.Muted)")
    [void]$sb.Append(('─' * [Math]::Max(0, $lw - $listTitle.Length)))
    [void]$sb.Append('┬')
    [void]$sb.Append("$outTitleColor$outTitle$($t.Muted)")
    [void]$sb.Append(('─' * [Math]::Max(0, $rw - $outTitle.Length)))
    [void]$sb.Append("┐$reset`e[K`n")

    # ---- body rows ----------------------------------------------------------
    $leftRows = Get-TuiListRows -Count $body -Width $lw
    $rightRows = Get-TuiOutputRows -Count $body -Width $rw
    for ($i = 0; $i -lt $body; $i++) {
        [void]$sb.Append("$reset$($t.Muted)│$reset")
        [void]$sb.Append($leftRows[$i])
        [void]$sb.Append("$reset$($t.Muted)│$reset")
        [void]$sb.Append($rightRows[$i])
        [void]$sb.Append("$reset$($t.Muted)│$reset`e[K`n")
    }

    # ---- bottom border -----------------------------------------------------
    # scrolled back? say so — new output otherwise accumulates invisibly below
    $more = Get-TuiMoreBelow -BodyHeight $body
    $note = if ($more -gt 0) { " ▼ $more more — End follows " } else { '' }
    if ($note -and ($note.Length + 2) -gt $rw) { $note = '' }
    [void]$sb.Append("$reset$($t.Muted)└$('─' * $lw)┴$('─' * ($rw - $note.Length - $(if ($note) { 1 } else { 0 })))")
    if ($note) { [void]$sb.Append("$($t.BrYellow)$note$($t.Muted)─") }
    [void]$sb.Append("┘$reset`e[K`n")

    # ---- status line -------------------------------------------------------
    [void]$sb.Append($reset)
    [void]$sb.Append((Get-TuiStatusLine -Width $W))
    [void]$sb.Append("$reset`e[K`n")

    # ---- key hints ---------------------------------------------------------
    [void]$sb.Append($reset)
    [void]$sb.Append((Get-TuiKeyHints -Width $W))
    [void]$sb.Append("$reset`e[K")

    [void]$sb.Append("`e[?2026l")
    [Console]::Write($sb.ToString())
}

# coarse age for the list column, always <= 3 chars ('12m', '3h', '99d')
function Get-TuiAge {
    param($At)
    if (-not $At) { return '' }
    $s = ((Get-Date) - $At).TotalSeconds
    if ($s -lt 0) { return '' }
    if ($s -lt 3600) { return ('{0}m' -f [int][Math]::Floor($s / 60)) }
    if ($s -lt 86400) { return ('{0}h' -f [int][Math]::Floor($s / 3600)) }
    $d = [int][Math]::Floor($s / 86400)
    if ($d -gt 99) { return '99d' }
    "${d}d"
}

function Get-TuiListRows {
    param([int]$Count, [int]$Width)
    $t = Get-PssTheme
    $rows = @()
    $items = $script:S.Visible
    $sel = $script:S.Selected

    # keep selection in view
    $top = 0
    if ($items.Count -gt $Count) {
        $top = [Math]::Min([Math]::Max(0, $sel - [int]($Count / 2)), $items.Count - $Count)
    }
    $script:S.ListTop = $top   # mouse clicks map row -> index through this

    # live state trumps last status: spinner on the running script, » on queued
    $runningName = if ($script:S.Run -and $script:S.Run.Kind -eq 'run') { $script:S.Run.Name } else { $null }
    $queuedNames = @($script:S.Queue | ForEach-Object { "$($_.Script.Name)" })

    for ($i = 0; $i -lt $Count; $i++) {
        $idx = $top + $i
        if ($idx -ge $items.Count) { $rows += (' ' * $Width); continue }
        $scr = $items[$idx]
        $last = if ($script:S.Statuses.ContainsKey($scr.Name)) { $script:S.Statuses[$scr.Name] } else { $null }
        $badge = switch ("$(if ($last) { $last.Status })") {
            'success' { "$($t.Green)✓" }
            'failure' { "$($t.Red)✗" }
            'killed' { "$($t.BrYellow)⊘" }
            'timeout' { "$($t.BrYellow)◷" }
            'skipped' { "$($t.BrYellow)◇" }
            default { "$($t.Muted)·" }
        }
        if ($scr.Name -eq $runningName) {
            $badge = "$($t.BrCyan)$($script:SpinnerFrames[$script:S.Tick % $script:SpinnerFrames.Count])"
        } elseif ($scr.Name -in $queuedNames) {
            $badge = "$($t.Cyan)»"
        }
        $sched = if ($script:S.Schedules.ContainsKey($scr.Name)) { "$($t.Cyan)@" } else { ' ' }
        $age = Get-TuiAge $(if ($last) { $last.At })
        $ageCol = "$($t.Muted)$($age.PadLeft(3))"
        $rowFg = $t.Fg
        $rowBg = ''
        if ($idx -eq $sel) { $rowBg = $t.SelBg; $rowFg = $t.White }
        $name = Format-TuiPad -Text $scr.Name -Width ($Width - 9)
        # show why a filtered row matched: highlight the filter substring
        if ($script:S.Filter) {
            $name = [regex]::Replace($name, '(' + [regex]::Escape($script:S.Filter) + ')',
                "$($t.BrCyan)" + '$1' + $rowFg, 'IgnoreCase')
        }
        $rows += "$rowBg $badge$rowBg $rowFg$name$rowBg$ageCol$rowBg $sched$rowBg "
    }
    $rows
}

# wrapped output lines below the current viewport; 0 while following or when
# the right pane isn't showing the output buffer
function Get-TuiMoreBelow {
    param([int]$BodyHeight)
    if ($script:S.Follow -or $script:S.Mode -in 'env', 'history', 'help') { return 0 }
    [Math]::Max(0, $script:S.Wrapped.Count - ($script:S.Scroll + $BodyHeight))
}

function Get-TuiOutputRows {
    param([int]$Count, [int]$Width)
    $t = Get-PssTheme
    switch ($script:S.Mode) {
        'env' { return Get-TuiEnvRows -Count $Count -Width $Width }
        'history' { return Get-TuiHistoryRows -Count $Count -Width $Width }
        'help' { return Get-TuiHelpRows -Count $Count -Width $Width }
    }

    $textW = $Width - 1
    $wrapped = $script:S.Wrapped
    $maxScroll = [Math]::Max(0, $wrapped.Count - $Count)
    $offset = if ($script:S.Follow) { $maxScroll } else { [Math]::Min($script:S.Scroll, $maxScroll) }
    $script:S.Scroll = $offset

    # scrollbar geometry
    $thumbPos = -1; $thumbLen = 0
    if ($wrapped.Count -gt $Count) {
        $thumbLen = [Math]::Max(1, [int]($Count * $Count / $wrapped.Count))
        $thumbPos = [int](($Count - $thumbLen) * $offset / [Math]::Max(1, $maxScroll))
    }

    $rows = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $idx = $offset + $i
        $text = if ($idx -lt $wrapped.Count) { $wrapped[$idx] } else { '' }
        $color = $t.Fg
        if ($text -match '^──|^────') { $color = $t.Blue }
        elseif ($text -match '^WARNING:') { $color = $t.Muted }   # advisory noise — keep it quiet
        # whole words only, no hyphenated names: "ErrorAction", "0 errors" and
        # a script called "error-report" must not paint the line red
        elseif ($text -match '(?i)\b(error|exception|failed|failure|fatal)\b(?!-)') { $color = $t.Red }
        elseif ($text -match ': success ') { $color = $t.Green }
        $bar = if ($thumbPos -ge 0) {
            if ($i -ge $thumbPos -and $i -lt ($thumbPos + $thumbLen)) { "$($t.Blue)█" } else { "$($t.Muted)│" }
        } else { ' ' }
        $padded = Format-TuiPad -Text $text -Width $textW
        # inverse-highlight search matches; ANSI-only insertion, width unchanged
        $term = $script:S.SearchTerm
        if ($term -and $text) {
            $padded = [regex]::Replace($padded, '(' + [regex]::Escape($term) + ')',
                "$($t.SelBg)$($t.White)" + '$1' + "$($t.Reset)$($t.Bg)$color", 'IgnoreCase')
        }
        $rows += "$color$padded$bar"
    }
    $rows
}

function Get-TuiEnvRows {
    param([int]$Count, [int]$Width)
    $t = Get-PssTheme
    $ed = $script:S.Env
    $rows = @()
    $dirtyMark = if ($ed.Dirty) { ' *' } else { '' }
    $header = Format-TuiPad -Text " editing $(Split-Path $ed.Script.EnvFile -Leaf) — $($ed.Script.Name)$dirtyMark   (ctrl+s save · esc cancel)" -Width $Width
    $rows += "$($t.SelBg)$($t.White)$header"

    $visible = $Count - 1
    if ($ed.CY -lt $ed.ScrollY) { $ed.ScrollY = $ed.CY }
    if ($ed.CY -ge $ed.ScrollY + $visible) { $ed.ScrollY = $ed.CY - $visible + 1 }

    # horizontal scroll: keep the cursor column visible
    $textW = $Width - 1
    if ($ed.CX -lt $ed.ScrollX) { $ed.ScrollX = [Math]::Max(0, $ed.CX - 8) }
    if ($ed.CX -gt $ed.ScrollX + $textW - 1) { $ed.ScrollX = $ed.CX - $textW + 1 }

    for ($i = 0; $i -lt $visible; $i++) {
        $idx = $ed.ScrollY + $i
        if ($idx -ge $ed.Lines.Count) { $rows += "$($t.Muted)$(Format-TuiPad -Text '~' -Width $Width)"; continue }
        $full = $ed.Lines[$idx]
        $sx = if ($idx -eq $ed.CY) { $ed.ScrollX } else { 0 }
        $line = if ($sx -lt $full.Length) { $full.Substring($sx) } else { '' }
        if ($line.Length -gt $textW) { $line = $line.Substring(0, $textW - 1) + '›' }
        if ($idx -eq $ed.CY) {
            # draw cursor as inverse cell (cursor column relative to the window)
            $cx = [Math]::Min([Math]::Max(0, $ed.CX - $sx), $line.Length)
            $pre = $line.Substring(0, $cx)
            $cur = if ($cx -lt $line.Length) { $line[$cx] } else { ' ' }
            $post = if ($cx -lt $line.Length) { $line.Substring($cx + 1) } else { '' }
            $plain = "$pre$cur$post"
            $pad = [Math]::Max(0, $Width - $plain.Length)
            $rows += "$($t.Fg)$pre$($t.SelBg)$($t.White)$cur$($t.Reset)$($t.Bg)$($t.Fg)$post$(' ' * $pad)"
        } else {
            $color = if ($full.TrimStart().StartsWith('#')) { $t.Muted } else { $t.Fg }
            $rows += "$color$(Format-TuiPad -Text $line -Width $Width)"
        }
    }
    $rows
}

# unicode sparkline from a numeric series (relative to its own max)
function Get-TuiSparkline {
    param($Series, [int]$Width = 12)
    if (-not $Series -or @($Series).Count -eq 0) { return ''.PadRight($Width) }
    $vals = @($Series | ForEach-Object { [double]$_ })
    $blocks = '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'
    $max = ($vals | Measure-Object -Maximum).Maximum
    if ($max -le 0) { $max = 1 }
    $n = $vals.Count
    $w = [Math]::Min($Width, $n)
    $sb = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $w; $i++) {
        $v = $vals[[int][Math]::Floor($i * $n / $w)]
        $level = [Math]::Min(7, [int][Math]::Floor($v / $max * 8))
        [void]$sb.Append($blocks[$level])
    }
    $sb.ToString().PadRight($Width)
}

function Get-TuiHistoryRows {
    param([int]$Count, [int]$Width)
    $t = Get-PssTheme
    $hi = $script:S.History
    $items = Get-TuiHistoryItems
    $rows = @()
    $filterTxt = if ($hi.FilterName) { " · filtered: $($hi.FilterName) (f clears)" } else { '' }
    $rows += "$($t.SelBg)$($t.White)$(Format-TuiPad -Text " run history (newest first)$filterTxt — enter view log · f filter · esc close" -Width $Width)"

    $fmt = ' {0,-11} {1,4}  {2,-9} {3,-22} {4,8}  cpu {5,5}% {6}  mem {7,7}MB  [{8}]'
    $rows += "$($t.Muted)$(Format-TuiPad -Text (' {0,-11} {1,4}  {2,-9} {3,-22} {4,8}' -f 'when', 'age', 'status', 'script', 'duration') -Width $Width)"

    $visible = $Count - 2
    $hi.Sel = [Math]::Min($hi.Sel, [Math]::Max(0, $items.Count - 1))
    # keep selection in view
    $top = 0
    if ($items.Count -gt $visible) {
        $top = [Math]::Min([Math]::Max(0, $hi.Sel - [int]($visible / 2)), $items.Count - $visible)
    }
    $hi.Top = $top   # mouse clicks map row -> item index through this
    for ($i = 0; $i -lt $visible; $i++) {
        $idx = $top + $i
        if ($idx -ge $items.Count) {
            $text = if ($items.Count -eq 0 -and $i -eq 0) { ' (no runs yet)' } else { '' }
            $rows += "$($t.Muted)$(Format-TuiPad -Text $text -Width $Width)"
            continue
        }
        $h = $items[$idx]
        $color = switch ("$($h.status)") {
            'success' { $t.Green } 'failure' { $t.Red } default { $t.BrYellow }
        }
        # ConvertFrom-Json turns ISO strings into [datetime] — format both a
        # compact absolute time and a glanceable age from that
        $started = $h.startedAt -as [datetime]
        $when = if ($started) { $started.ToString('MM-dd HH:mm') } else { "$($h.startedAt)" }
        $age = if ($started) { Format-PssRelativeTime ((Get-Date) - $started).TotalSeconds } else { '' }
        $res = $h.resources
        $spark = Get-TuiSparkline -Series $res.cpuSeries -Width 10
        $line = $fmt -f
        $when, $age, $h.status, $h.script, (Format-PssDuration ([double]$h.durationSec)),
        $res.cpuMaxPercent, $spark, $res.memMaxMb, $h.trigger
        $bg = if ($idx -eq $hi.Sel) { $t.SelBg } else { '' }
        $rows += "$bg$color$(Format-TuiPad -Text $line -Width $Width)"
    }
    $rows
}

function Get-TuiHelpRows {
    param([int]$Count, [int]$Width)
    $t = Get-PssTheme
    $entries = @(
        @('', ''),
        @('enter / r', 'run the selected script (deps checked; queued if busy)'),
        @('a', 'run with extra arguments (quotes group words)'),
        @('e', 'set/edit/remove the cron schedule'),
        @('v', 'edit the script''s .env (ctrl+s save, esc cancel)'),
        @('s', 'sync the scripts repo'),
        @('i', 'scan imports, install missing modules'),
        @('l', 'lint the script with PSScriptAnalyzer'),
        @('u', 'update PowerShell (apt) + upgrade script modules'),
        @('U', 'update this app (git pull), restart to apply'),
        @('h', 'run history: ↑/↓ select · enter view log · f filter by script'),
        @('t', 'send a test event to the n8n webhook'),
        @('x / X', 'kill the running script / clear the run queue'),
        @('y / c', 'copy output to clipboard / clear the output panel'),
        @('/', 'filter the script list (live, esc restores)'),
        @('ctrl+f', 'search the output — n / N jump to next / prev match'),
        @('g / G', 'jump to the top / bottom of the list'),
        @('j / k', 'navigate the list (vim-style)'),
        @('tab', 'switch pane focus — j/k/g/G scroll the focused pane'),
        @('pgup/pgdn', 'scroll output (end re-engages follow)'),
        @('mouse', 'wheel scrolls output · click selects a script · click an auth code to copy it'),
        @('?', 'this help'),
        @('q', 'quit'),
        @('', ''),
        @('', 'any key closes this help')
    )
    $rows = @()
    $rows += "$($t.SelBg)$($t.White)$(Format-TuiPad -Text ' keybindings' -Width $Width)"
    for ($i = 0; $i -lt ($Count - 1); $i++) {
        if ($i -ge $entries.Count) { $rows += (' ' * $Width); continue }
        $e = $entries[$i]
        $line = Format-TuiPad -Text "  $($e[0].PadRight(11)) $($e[1])" -Width $Width
        # key part magenta, description default
        $rows += "$($t.Magenta)$($line.Substring(0, 13))$($t.Fg)$($line.Substring(13))"
    }
    $rows
}

function Get-TuiStatusLine {
    param([int]$Width)
    $t = Get-PssTheme

    switch ($script:S.Mode) {
        'deps' {
            $d = $script:S.Deps
            $verb = if ($d.InstallOnly) { 'install' } else { 'install & run' }
            $alt = if ($d.InstallOnly) { 'skip' } else { 'run anyway' }
            $names = ($d.Missing | ForEach-Object Display) -join ', '
            # elide the module list so a long one can't overflow the row
            $prefix = " ▲ missing modules for $($d.Script.Name): "
            $suffix = "  —  y $verb  n $alt  esc cancel"
            $avail = $Width - (Get-PssDisplayWidth $prefix) - $suffix.Length
            if ($avail -gt 1 -and (Get-PssDisplayWidth $names) -gt $avail) {
                $names = (Format-PssCell -Text $names -Width $avail -Ellipsis).TrimEnd()
            }
            $plain = "$prefix$names$suffix"
            $pad = [Math]::Max(0, $Width - (Get-PssDisplayWidth $plain))
            return " $($t.BrYellow)▲ missing modules for $($d.Script.Name): $names$($t.Fg)  —  $($t.Green)y$($t.Fg) $verb  $($t.Yellow)n$($t.Fg) $alt  $($t.Muted)esc cancel$(' ' * $pad)"
        }
        'input' {
            $in = $script:S.Input
            $pre = $in.Text.Substring(0, $in.Cursor)
            $cur = if ($in.Cursor -lt $in.Text.Length) { $in.Text[$in.Cursor] } else { ' ' }
            $post = if ($in.Cursor -lt $in.Text.Length) { $in.Text.Substring($in.Cursor + 1) } else { '' }
            $plainLen = " $($in.Prompt): $($in.Text) ".Length + 1
            $pad = [Math]::Max(0, $Width - $plainLen)
            return " $($t.Cyan)$($in.Prompt):$($t.Fg) $pre$($t.SelBg)$($t.White)$cur$($t.Reset)$($t.Bg)$($t.Fg)$post$(' ' * $pad)"
        }
        'confirm' {
            $c = $script:S.Confirm
            $plain = " $($c.Message)  y confirm · esc cancel"
            $pad = [Math]::Max(0, $Width - $plain.Length)
            return " $($t.BrYellow)$($c.Message)$($t.Fg)  $($t.Green)y$($t.Fg) confirm · $($t.Muted)esc cancel$(' ' * $pad)"
        }
    }

    # default status line: run stats or transient message
    $queueTxt = if ($script:S.Queue.Count -gt 0) { "  (+$($script:S.Queue.Count) queued)" } else { '' }
    $left = ''
    if ($script:S.Run -and $script:S.Run.Kind -eq 'run') {
        $h = $script:S.Run
        $el = ((Get-Date).ToUniversalTime() - $h.StartedAt).TotalSeconds
        $cpu = if ($h.ContainsKey('CpuNow')) { '{0:n1}' -f $h.CpuNow } else { '—' }
        $mem = if ($h.ContainsKey('MemNow')) { '{0:n0}' -f $h.MemNow } else { '—' }
        $left = " running $($h.Name)  $(Format-PssDuration $el)  cpu $cpu%  mem ${mem}MB$queueTxt"
    } elseif ($script:S.Run) {
        $h = $script:S.Run
        $el = ''
        if ($h.ContainsKey('StartedAt')) {
            $el = "  $(Format-PssDuration ((Get-Date).ToUniversalTime() - $h.StartedAt).TotalSeconds)"
        }
        $left = " running: $($h.Name)$el$queueTxt"
    } elseif (((Get-Date) - $script:S.StatusMsgAt).TotalSeconds -lt 6 -and $script:S.StatusMsg) {
        $left = " $($script:S.StatusMsg)"
    } else {
        $sel = Get-TuiSelected
        if ($sel) {
            $desc = if ($sel.Description) { $sel.Description } else { $sel.Entry.Replace($HOME, '~') }
            $schedTxt = ''
            if ($script:S.Schedules.ContainsKey($sel.Name)) {
                $expr = $script:S.Schedules[$sel.Name]
                $schedTxt = "  ⏲ $expr$(Get-TuiNextRunHint -Name $sel.Name -Expression $expr)"
            }
            $left = " $($sel.Name): $desc$schedTxt$queueTxt"
        }
    }
    $color = if ($script:S.Run) { (Get-PssTheme).BrCyan } else { (Get-PssTheme).Muted }
    "$color$(Format-TuiPad -Text $left -Width $Width)"
}

# "· next in 2h14m" — cached so the cron math doesn't run every frame
function Get-TuiNextRunHint {
    param([string]$Name, [string]$Expression)
    $now = Get-Date
    $c = $script:S.NextRunCache[$Name]
    if (-not $c -or $c.Expr -ne $Expression -or ($c.At -and $c.At -le $now) -or (-not $c.At -and $c.ComputedAt.AddMinutes(1) -le $now)) {
        $c = @{ Expr = $Expression; At = (Get-PssCronNext -Expression $Expression -From $now); ComputedAt = $now }
        $script:S.NextRunCache[$Name] = $c
    }
    if (-not $c.At) { return '' }
    " · next in $(Format-PssRelativeTime (($c.At) - $now).TotalSeconds)"
}

function Get-TuiKeyHints {
    param([int]$Width)
    $t = Get-PssTheme
    # footer follows the active mode — showing list keys while e.g. the env
    # editor is open would advertise bindings that don't work there
    $pairs = switch ($script:S.Mode) {
        'history' {
            @(@('enter', 'view log'), @('f', 'filter script'), @('j/k', 'navigate'),
                @('pgup/pgdn', 'page'), @('esc', 'close'))
        }
        'env' {
            @(@('ctrl+s', 'save'), @('esc', 'cancel'), @('arrows', 'move'))
        }
        'input' {
            @(@('enter', 'submit'), @('esc', 'cancel'))
        }
        'confirm' {
            @(@('y/enter', 'confirm'), @('n/esc', 'cancel'))
        }
        'deps' {
            $alt = if ($script:S.Deps -and $script:S.Deps.InstallOnly) { 'skip' } else { 'run anyway' }
            @(@('y', 'install'), @('n', $alt), @('esc', 'cancel'))
        }
        'help' {
            @(@('any key', 'close help'))
        }
        default {
            @(
                @('enter', 'run'), @('a', 'args'), @('e', 'schedule'), @('v', '.env'), @('s', 'sync'),
                @('i', 'deps'), @('l', 'lint'), @('u', 'update'), @('h', 'history'), @('x', 'kill'),
                @('y', 'copy'), @('/', 'filter'), @('tab', 'pane'), @('?', 'help'), @('q', 'quit')
            )
        }
    }
    $out = ' '
    $plain = ' '
    foreach ($p in $pairs) {
        $piece = "$($p[0]) $($p[1])  "
        if (($plain.Length + $piece.Length) -gt $Width) { break }
        $out += "$($t.Magenta)$($p[0])$($t.Muted) $($p[1])  "
        $plain += $piece
    }
    $pad = [Math]::Max(0, $Width - $plain.Length)
    "$out$(' ' * $pad)"
}

Export-ModuleMember -Function Start-PssTui
