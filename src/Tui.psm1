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
        Quit        = $false
        W           = 0; H = 0
        Scripts     = @(); Visible = @()
        Selected    = 0
        Filter      = ''
        Statuses    = @{}
        Schedules   = @{}
        Lines       = [System.Collections.Generic.List[string]]::new()
        Wrapped     = [System.Collections.Generic.List[string]]::new()
        WrapWidth   = 0
        Scroll      = 0
        Follow      = $true
        OutTitle    = 'output'
        Mode        = 'list'   # list|deps|input|confirm|env|history
        Input       = $null
        Confirm     = $null
        Deps        = $null
        Env         = $null
        History     = $null
        Run         = $null
        AfterTask   = $null
        StatusMsg   = ''
        StatusMsgAt = [datetime]::MinValue
        Tick        = 0
        LastSample  = [datetime]::MinValue
        Dirty       = $true
    }

    Update-TuiScripts
    if (-not $script:S.Scripts -or $script:S.Scripts.Count -eq 0) {
        Add-TuiOutput @('no scripts found yet — press s to sync the scripts repo', '')
    }
    Add-TuiOutput @("PowerShell Scripts TUI — $($script:S.Scripts.Count) script(s) discovered", 'select a script and press Enter to run it')

    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    [Console]::TreatControlCAsInput = $true
    [Console]::Write("`e[?1049h`e[?25l")   # alt screen, hide cursor
    try {
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
                Invoke-TuiKey $key
                $script:S.Dirty = $true
                if ($script:S.Quit) { break }
            }
            if ($script:S.Quit) { break }

            # active run/task
            if ($script:S.Run) { Update-TuiRun }

            if ($script:S.Dirty -or $script:S.Run) {
                Show-TuiFrame
                $script:S.Dirty = $false
            }
            Start-Sleep -Milliseconds 33
        }
    } finally {
        try {
            if ($script:S.Run -and -not $script:S.Run.StartError -and -not $script:S.Run.Process.HasExited) {
                Stop-PssRun -Handle $script:S.Run -Reason 'killed'
                Complete-PssRun -Handle $script:S.Run | Out-Null
            }
        } catch { }
        [Console]::Write("`e[0m`e[?25h`e[?1049l")
        [Console]::TreatControlCAsInput = $false
    }
}

# ===========================================================================
# Data refresh
# ===========================================================================
function Update-TuiScripts {
    $script:S.Scripts = @(Get-PssScripts)
    $script:S.Statuses = Get-PssLastStatuses
    $script:S.Schedules = Get-PssSchedules
    Update-TuiVisible
}

function Update-TuiVisible {
    $f = $script:S.Filter
    $script:S.Visible = @(
        if ($f) { $script:S.Scripts | Where-Object { $_.Name -like "*$f*" } }
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
    param([string]$Line)
    $width = Get-TuiWrapWidth
    if (-not $Line) { return @('') }
    $out = @()
    $i = 0
    while ($i -lt $Line.Length) {
        $len = [Math]::Min($width, $Line.Length - $i)
        $out += $Line.Substring($i, $len)
        $i += $len
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
    if ($script:S.Run) { Set-TuiStatus 'something is already running — x to kill it first'; return }
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
    param([string]$Name, [string]$FileName, [string[]]$Arguments, [scriptblock]$After = $null)
    if ($script:S.Run) { Set-TuiStatus 'something is already running — x to kill it first'; return }
    $script:S.OutTitle = $Name
    Add-TuiOutput @('', "── $Name ──")
    $script:S.Run = Start-PssTask -Name $Name -FileName $FileName -Arguments $Arguments
    $script:S.AfterTask = $After
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
            $script:S.Statuses[$result.script] = $result.status
            Set-TuiStatus "$($result.script): $($result.status)"
        } else {
            $ok = ($h.ExitCode -eq 0)
            Add-TuiOutput @("── $($h.Name): $(if ($ok) {'done'} else {"failed (exit $($h.ExitCode))"}) ──")
            $after = $script:S.AfterTask
            $script:S.AfterTask = $null
            if ($ok -and $after) { & $after }
        }
        $script:S.Dirty = $true
    }
}

# ===========================================================================
# Actions
# ===========================================================================
function Invoke-TuiSync {
    $script:S.OutTitle = 'sync'
    Add-TuiOutput @('', '── sync scripts repo ──')
    Show-TuiFrame
    $ok = Sync-PssRepo -OnOutput { param($l) Add-TuiOutput @($l); Show-TuiFrame }
    Update-TuiScripts
    Add-TuiOutput @("$($script:S.Scripts.Count) script(s) discovered")
    Set-TuiStatus $(if ($ok) { 'sync complete' } else { 'sync failed' })
}

function Invoke-TuiDepScan {
    $sel = Get-TuiSelected
    if (-not $sel) { return }
    $deps = @(Get-PssScriptDeps -Script $sel)
    $missing = @(Get-PssMissingDeps -Script $sel)
    $script:S.OutTitle = "deps: $($sel.Name)"
    Add-TuiOutput @('', "── dependency scan: $($sel.Name) ──",
        "declared/imported modules: $(if ($deps) { $deps -join ', ' } else { '(none)' })",
        "missing: $(if ($missing) { $missing -join ', ' } else { '(none)' })")
    if ($missing.Count -gt 0) {
        $script:S.Deps = @{ Script = $sel; Missing = $missing; ExtraArgs = @(); InstallOnly = $true }
        $script:S.Mode = 'deps'
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
    $cfg = Get-PssConfig
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
    $script:S.History = @{ Items = $items; Offset = 0 }
    $script:S.Mode = 'history'
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
        CX     = 0; CY = 0; ScrollY = 0
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
    $script:S.Input = @{ Prompt = $Prompt; Text = $Text; Cursor = $Text.Length; OnSubmit = $OnSubmit; Kind = $Kind }
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
        'r' { $sel = Get-TuiSelected; if ($sel) { Start-TuiRunFlow -Script $sel } }
        'a' {
            $sel = Get-TuiSelected
            if ($sel) {
                Open-TuiInput -Prompt "extra args for $($sel.Name)" -OnSubmit {
                    param($value)
                    $sel2 = Get-TuiSelected
                    if ($sel2) {
                        $extra = if ($value.Trim()) { @($value.Trim() -split '\s+') } else { @() }
                        Start-TuiRunFlow -Script $sel2 -ExtraArgs $extra
                    }
                }
            }
        }
        'e' { Open-TuiCronInput }
        'v' { Open-TuiEnvEditor }
        's' { Invoke-TuiSync }
        'i' { Invoke-TuiDepScan }
        'u' { Invoke-TuiUpdate }
        'h' { Open-TuiHistory }
        't' { Invoke-TuiWebhookTest }
        'x' {
            if ($script:S.Run) {
                Stop-PssRun -Handle $script:S.Run -Reason 'killed'
                Set-TuiStatus 'kill signal sent'
            } else { Set-TuiStatus 'nothing is running' }
        }
        'y' { Invoke-TuiCopy }
        'c' { Clear-TuiOutput }
        '/' {
            Open-TuiInput -Prompt 'filter scripts (empty = clear)' -Text $script:S.Filter -OnSubmit {
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
        'Escape' { $script:S.Input = $null; $script:S.Mode = 'list'; return }
        'Enter' {
            $script:S.Input = $null; $script:S.Mode = 'list'
            if ($in.OnSubmit) { & $in.OnSubmit $in.Text }
            return
        }
        'Backspace' {
            if ($in.Cursor -gt 0) {
                $in.Text = $in.Text.Remove($in.Cursor - 1, 1); $in.Cursor--
            }
            return
        }
        'Delete' { if ($in.Cursor -lt $in.Text.Length) { $in.Text = $in.Text.Remove($in.Cursor, 1) }; return }
        'LeftArrow' { if ($in.Cursor -gt 0) { $in.Cursor-- }; return }
        'RightArrow' { if ($in.Cursor -lt $in.Text.Length) { $in.Cursor++ }; return }
        'Home' { $in.Cursor = 0; return }
        'End' { $in.Cursor = $in.Text.Length; return }
    }
    if ($Key.KeyChar -and -not [char]::IsControl($Key.KeyChar)) {
        $in.Text = $in.Text.Insert($in.Cursor, $Key.KeyChar)
        $in.Cursor++
    }
}

function Invoke-TuiKeyEnv {
    param([ConsoleKeyInfo]$Key)
    $ed = $script:S.Env
    $ctrl = [bool]($Key.Modifiers -band [ConsoleModifiers]::Control)

    if ($Key.Key -eq 'Escape') { $script:S.Env = $null; $script:S.Mode = 'list'; Set-TuiStatus '.env edit cancelled'; return }
    if ($ctrl -and $Key.Key -eq 'S') {
        $target = $ed.Script.EnvFile
        ($ed.Lines -join "`n") + "`n" | Set-Content -Path $target -NoNewline -Encoding UTF8
        foreach ($kv in (Read-PssEnvFile $target).GetEnumerator()) { Register-PssSecret -Name $kv.Key -Value $kv.Value }
        $script:S.Env = $null; $script:S.Mode = 'list'
        Set-TuiStatus "saved $(Split-Path $target -Leaf) for $($ed.Script.Name)"
        return
    }

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
            return
        }
        'Backspace' {
            if ($ed.CX -gt 0) {
                $ed.Lines[$ed.CY] = $line.Remove($ed.CX - 1, 1); $ed.CX--
            } elseif ($ed.CY -gt 0) {
                $prev = $ed.Lines[$ed.CY - 1]
                $ed.CX = $prev.Length
                $ed.Lines[$ed.CY - 1] = $prev + $line
                $ed.Lines.RemoveAt($ed.CY)
                $ed.CY--
            }
            return
        }
        'Delete' {
            if ($ed.CX -lt $line.Length) { $ed.Lines[$ed.CY] = $line.Remove($ed.CX, 1) }
            elseif ($ed.CY -lt $ed.Lines.Count - 1) {
                $ed.Lines[$ed.CY] = $line + $ed.Lines[$ed.CY + 1]
                $ed.Lines.RemoveAt($ed.CY + 1)
            }
            return
        }
    }
    if ($Key.KeyChar -and -not [char]::IsControl($Key.KeyChar)) {
        $ed.Lines[$ed.CY] = $line.Insert($ed.CX, $Key.KeyChar)
        $ed.CX++
    }
}

function Invoke-TuiKeyHistory {
    param([ConsoleKeyInfo]$Key)
    $hi = $script:S.History
    $page = Get-TuiBodyHeight
    if ($Key.Key -in 'Escape', 'Q' -or $Key.KeyChar -in 'q', 'h') { $script:S.History = $null; $script:S.Mode = 'list'; return }
    switch ($Key.Key) {
        'UpArrow' { $hi.Offset = [Math]::Max(0, $hi.Offset - 1) }
        'DownArrow' { $hi.Offset = [Math]::Min([Math]::Max(0, $hi.Items.Count - $page), $hi.Offset + 1) }
        'PageUp' { $hi.Offset = [Math]::Max(0, $hi.Offset - $page) }
        'PageDown' { $hi.Offset = [Math]::Min([Math]::Max(0, $hi.Items.Count - $page), $hi.Offset + $page) }
        'Home' { $hi.Offset = 0 }
        'End' { $hi.Offset = [Math]::Max(0, $hi.Items.Count - $page) }
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
    param([string]$Text, [int]$Width)
    if ($Text.Length -gt $Width) {
        if ($Width -le 1) { return $Text.Substring(0, $Width) }
        return $Text.Substring(0, $Width - 1) + '…'
    }
    $Text.PadRight($Width)
}

function Show-TuiFrame {
    $t = Get-PssTheme
    $cfg = Get-PssConfig
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
    $right = " $repo · $([Environment]::MachineName) "
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
    [void]$sb.Append("$reset$($t.Muted)┌")
    [void]$sb.Append("$($t.Blue)$listTitle$($t.Muted)")
    [void]$sb.Append(('─' * [Math]::Max(0, $lw - $listTitle.Length)))
    [void]$sb.Append('┬')
    [void]$sb.Append("$($t.Blue)$outTitle$($t.Muted)")
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
    [void]$sb.Append("$reset$($t.Muted)└$('─' * $lw)┴$('─' * $rw)┘$reset`e[K`n")

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

    for ($i = 0; $i -lt $Count; $i++) {
        $idx = $top + $i
        if ($idx -ge $items.Count) { $rows += (' ' * $Width); continue }
        $scr = $items[$idx]
        $status = if ($script:S.Statuses.ContainsKey($scr.Name)) { $script:S.Statuses[$scr.Name] } else { '' }
        $badge = switch ($status) {
            'success' { "$($t.Green)✓" }
            'failure' { "$($t.Red)✗" }
            'killed' { "$($t.BrYellow)⊘" }
            'timeout' { "$($t.BrYellow)◷" }
            default { "$($t.Muted)·" }
        }
        $sched = if ($script:S.Schedules.ContainsKey($scr.Name)) { "$($t.Cyan)@" } else { ' ' }
        $name = Format-TuiPad -Text $scr.Name -Width ($Width - 5)
        $rowFg = $t.Fg
        $rowBg = ''
        if ($idx -eq $sel) { $rowBg = $t.SelBg; $rowFg = $t.White }
        $rows += "$rowBg $badge$rowBg $rowFg$name$sched$rowBg "
    }
    $rows
}

function Get-TuiOutputRows {
    param([int]$Count, [int]$Width)
    $t = Get-PssTheme
    switch ($script:S.Mode) {
        'env' { return Get-TuiEnvRows -Count $Count -Width $Width }
        'history' { return Get-TuiHistoryRows -Count $Count -Width $Width }
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
        elseif ($text -match 'FAILED|failed|error|Error|exception|Exception') { $color = $t.Red }
        elseif ($text -match ': success ') { $color = $t.Green }
        $bar = if ($thumbPos -ge 0) {
            if ($i -ge $thumbPos -and $i -lt ($thumbPos + $thumbLen)) { "$($t.Blue)█" } else { "$($t.Muted)│" }
        } else { ' ' }
        $rows += "$color$(Format-TuiPad -Text $text -Width $textW)$bar"
    }
    $rows
}

function Get-TuiEnvRows {
    param([int]$Count, [int]$Width)
    $t = Get-PssTheme
    $ed = $script:S.Env
    $rows = @()
    $header = Format-TuiPad -Text " editing $(Split-Path $ed.Script.EnvFile -Leaf) — $($ed.Script.Name)   (ctrl+s save · esc cancel)" -Width $Width
    $rows += "$($t.SelBg)$($t.White)$header"

    $visible = $Count - 1
    if ($ed.CY -lt $ed.ScrollY) { $ed.ScrollY = $ed.CY }
    if ($ed.CY -ge $ed.ScrollY + $visible) { $ed.ScrollY = $ed.CY - $visible + 1 }

    for ($i = 0; $i -lt $visible; $i++) {
        $idx = $ed.ScrollY + $i
        if ($idx -ge $ed.Lines.Count) { $rows += "$($t.Muted)$(Format-TuiPad -Text '~' -Width $Width)"; continue }
        $line = $ed.Lines[$idx]
        if ($line.Length -gt $Width - 1) { $line = $line.Substring(0, $Width - 1) }
        if ($idx -eq $ed.CY) {
            # draw cursor as inverse cell
            $cx = [Math]::Min($ed.CX, $line.Length)
            $pre = $line.Substring(0, $cx)
            $cur = if ($cx -lt $line.Length) { $line[$cx] } else { ' ' }
            $post = if ($cx + 1 -le $line.Length -and $cx -lt $line.Length) { $line.Substring($cx + 1) } else { '' }
            $plain = "$pre$cur$post"
            $pad = [Math]::Max(0, $Width - $plain.Length)
            $rows += "$($t.Fg)$pre$($t.SelBg)$($t.White)$cur$($t.Reset)$($t.Bg)$($t.Fg)$post$(' ' * $pad)"
        } else {
            $color = if ($line.TrimStart().StartsWith('#')) { $t.Muted } else { $t.Fg }
            $rows += "$color$(Format-TuiPad -Text $line -Width $Width)"
        }
    }
    $rows
}

function Get-TuiHistoryRows {
    param([int]$Count, [int]$Width)
    $t = Get-PssTheme
    $hi = $script:S.History
    $rows = @()
    $rows += "$($t.SelBg)$($t.White)$(Format-TuiPad -Text ' run history (newest first) — esc to close' -Width $Width)"
    $visible = $Count - 1
    for ($i = 0; $i -lt $visible; $i++) {
        $idx = $hi.Offset + $i
        if ($idx -ge $hi.Items.Count) {
            $text = if ($hi.Items.Count -eq 0 -and $i -eq 0) { ' (no runs yet)' } else { '' }
            $rows += "$($t.Muted)$(Format-TuiPad -Text $text -Width $Width)"
            continue
        }
        $h = $hi.Items[$idx]
        $color = switch ("$($h.status)") {
            'success' { $t.Green } 'failure' { $t.Red } default { $t.BrYellow }
        }
        $when = "$($h.startedAt)" -replace 'T', ' ' -replace '\.\d+Z$', 'Z'
        $res = $h.resources
        $line = ' {0}  {1,-9} {2,-22} {3,8}  cpu {4,5}%  mem {5,7}MB  [{6}]' -f
        $when, $h.status, $h.script, (Format-PssDuration ([double]$h.durationSec)),
        $res.cpuMaxPercent, $res.memMaxMb, $h.trigger
        $rows += "$color$(Format-TuiPad -Text $line -Width $Width)"
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
            $plain = " ▲ missing modules for $($d.Script.Name): $($d.Missing -join ', ')  —  y $verb  n $alt  esc cancel"
            $pad = [Math]::Max(0, $Width - $plain.Length)
            return " $($t.BrYellow)▲ missing modules for $($d.Script.Name): $($d.Missing -join ', ')$($t.Fg)  —  $($t.Green)y$($t.Fg) $verb  $($t.Yellow)n$($t.Fg) $alt  $($t.Muted)esc cancel$(' ' * $pad)"
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
    $left = ''
    if ($script:S.Run -and $script:S.Run.Kind -eq 'run') {
        $h = $script:S.Run
        $el = ((Get-Date).ToUniversalTime() - $h.StartedAt).TotalSeconds
        $cpu = if ($h.ContainsKey('CpuNow')) { '{0:n1}' -f $h.CpuNow } else { '—' }
        $mem = if ($h.ContainsKey('MemNow')) { '{0:n0}' -f $h.MemNow } else { '—' }
        $left = " running $($h.Name)  $(Format-PssDuration $el)  cpu $cpu%  mem ${mem}MB"
    } elseif ($script:S.Run) {
        $left = " running: $($script:S.Run.Name)"
    } elseif (((Get-Date) - $script:S.StatusMsgAt).TotalSeconds -lt 6 -and $script:S.StatusMsg) {
        $left = " $($script:S.StatusMsg)"
    } else {
        $sel = Get-TuiSelected
        if ($sel) {
            $desc = if ($sel.Description) { $sel.Description } else { $sel.Entry.Replace($HOME, '~') }
            $schedTxt = if ($script:S.Schedules.ContainsKey($sel.Name)) { "  ⏲ $($script:S.Schedules[$sel.Name])" } else { '' }
            $left = " $($sel.Name): $desc$schedTxt"
        }
    }
    $color = if ($script:S.Run) { (Get-PssTheme).BrCyan } else { (Get-PssTheme).Muted }
    "$color$(Format-TuiPad -Text $left -Width $Width)"
}

function Get-TuiKeyHints {
    param([int]$Width)
    $t = Get-PssTheme
    $pairs = @(
        @('enter', 'run'), @('a', 'args'), @('e', 'schedule'), @('v', '.env'), @('s', 'sync'),
        @('i', 'deps'), @('u', 'update'), @('h', 'history'), @('t', 'webhook'), @('x', 'kill'),
        @('y', 'copy'), @('c', 'clear'), @('/', 'filter'), @('q', 'quit')
    )
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
