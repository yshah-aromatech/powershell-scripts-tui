# Cron.psm1 — cron scheduling via a managed block in the user crontab, plus
# natural-language -> cron conversion through OpenRouter.

$script:BlockStart = '# >>> psscripts managed block — do not edit by hand >>>'
$script:BlockEnd = '# <<< psscripts managed block <<<'

function Get-PssCrontabLines {
    try {
        $out = & crontab -l 2>$null
        if ($LASTEXITCODE -ne 0 -or $null -eq $out) { return @() }
        @($out)
    } catch { @() }
}

# script name -> cron expression
function Get-PssSchedules {
    $map = @{}
    $inBlock = $false
    foreach ($line in (Get-PssCrontabLines)) {
        if ($line -eq $script:BlockStart) { $inBlock = $true; continue }
        if ($line -eq $script:BlockEnd) { $inBlock = $false; continue }
        if (-not $inBlock) { continue }
        if ($line -match "--run '([^']+)'") {
            $name = $Matches[1]
            $expr = if ($line -match '^(@\S+|(?:\S+\s+){4}\S+)\s+cd ') { $Matches[1].Trim() } else { '' }
            if ($expr) { $map[$name] = $expr }
        }
    }
    $map
}

function Save-PssSchedules {
    param([Parameter(Mandatory)][hashtable]$Schedules)
    $cfg = Get-PssConfig
    $paths = Get-PssPaths
    $appDir = Get-PssAppDir
    $pwshBin = [string]$cfg.pwshBin

    # everything outside the managed block is preserved untouched
    $kept = [System.Collections.Generic.List[string]]::new()
    $inBlock = $false
    foreach ($line in (Get-PssCrontabLines)) {
        if ($line -eq $script:BlockStart) { $inBlock = $true; continue }
        if ($line -eq $script:BlockEnd) { $inBlock = $false; continue }
        if (-not $inBlock) { $kept.Add($line) }
    }

    $new = [System.Collections.Generic.List[string]]::new()
    $new.AddRange($kept)
    if ($Schedules.Count -gt 0) {
        $new.Add($script:BlockStart)
        foreach ($name in ($Schedules.Keys | Sort-Object)) {
            $expr = $Schedules[$name]
            $log = Join-Path $paths.LogsDir "cron-$name.log"
            $new.Add("$expr cd '$appDir' && '$pwshBin' -NoProfile -File psscripts.ps1 --run '$name' --cron >> '$log' 2>&1")
        }
        $new.Add($script:BlockEnd)
    }

    $text = ($new -join "`n")
    if ($text) { $text += "`n" }
    $text | & crontab - 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
}

function Set-PssSchedule {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Expression)
    $schedules = Get-PssSchedules
    $schedules[$Name] = $Expression
    Save-PssSchedules -Schedules $schedules
}

function Remove-PssSchedule {
    param([Parameter(Mandatory)][string]$Name)
    $schedules = Get-PssSchedules
    if ($schedules.ContainsKey($Name)) { $schedules.Remove($Name) }
    Save-PssSchedules -Schedules $schedules
}

# ---------------------------------------------------------------------------
# Next-occurrence calculation — used for the "next run in 2h14m" status hint
# ---------------------------------------------------------------------------
$script:CronKeywords = @{
    '@hourly'   = '0 * * * *'
    '@daily'    = '0 0 * * *'
    '@midnight' = '0 0 * * *'
    '@weekly'   = '0 0 * * 0'
    '@monthly'  = '0 0 1 * *'
    '@yearly'   = '0 0 1 1 *'
    '@annually' = '0 0 1 1 *'
}
$script:CronMonthNames = @{ jan = 1; feb = 2; mar = 3; apr = 4; may = 5; jun = 6
    jul = 7; aug = 8; sep = 9; oct = 10; nov = 11; dec = 12
}
$script:CronDowNames = @{ sun = 0; mon = 1; tue = 2; wed = 3; thu = 4; fri = 5; sat = 6 }

# Expand one cron field into a sorted int array; $null on parse failure.
function ConvertFrom-PssCronField {
    param([string]$Field, [int]$Min, [int]$Max, [hashtable]$Names = @{})
    $set = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($part in $Field.Split(',')) {
        $p = $part.Trim().ToLower()
        if (-not $p) { return $null }
        $step = 1
        $hasStep = $false
        if ($p -match '^(.+)/(\d+)$') {
            $p = $Matches[1]; $step = [int]$Matches[2]; $hasStep = $true
            if ($step -lt 1) { return $null }
        }
        $resolve = {
            param([string]$Tok)
            if ($Names.ContainsKey($Tok)) { return [int]$Names[$Tok] }
            if ($Tok -match '^\d+$') { return [int]$Tok }
            $null
        }
        if ($p -eq '*') {
            $lo = $Min; $hi = $Max
        } elseif ($p.Contains('-')) {
            $r = $p.Split('-', 2)
            $lo = & $resolve $r[0]; $hi = & $resolve $r[1]
            if ($null -eq $lo -or $null -eq $hi) { return $null }
        } else {
            $lo = & $resolve $p
            if ($null -eq $lo) { return $null }
            # "5/15" means: starting at 5, every 15 — range extends to Max
            $hi = if ($hasStep) { $Max } else { $lo }
        }
        if ($lo -lt $Min -or $hi -gt $Max -or $lo -gt $hi) { return $null }
        for ($v = $lo; $v -le $hi; $v += $step) { [void]$set.Add($v) }
    }
    if ($set.Count -eq 0) { return $null }
    @($set)
}

# Next time >= (From + 1 minute) the expression fires; $null when the
# expression can't be parsed or never fires (@reboot, impossible dates).
function Get-PssCronNext {
    param([Parameter(Mandatory)][string]$Expression, [datetime]$From = (Get-Date))
    $e = $Expression.Trim().ToLower()
    if ($e -eq '@reboot') { return $null }
    if ($script:CronKeywords.ContainsKey($e)) { $e = $script:CronKeywords[$e] }
    $f = $e -split '\s+'
    if ($f.Count -ne 5) { return $null }

    $minutes = ConvertFrom-PssCronField $f[0] 0 59
    $hours = ConvertFrom-PssCronField $f[1] 0 23
    $doms = ConvertFrom-PssCronField $f[2] 1 31
    $months = ConvertFrom-PssCronField $f[3] 1 12 $script:CronMonthNames
    $dows = ConvertFrom-PssCronField $f[4] 0 7 $script:CronDowNames
    if ($null -eq $minutes -or $null -eq $hours -or $null -eq $doms -or
        $null -eq $months -or $null -eq $dows) { return $null }
    $dows = @($dows | ForEach-Object { $_ % 7 } | Sort-Object -Unique)   # 7 == sunday

    # vixie-cron day rule: when BOTH dom and dow are restricted (don't start
    # with '*'), the day matches if EITHER matches; otherwise both must.
    $domRestricted = -not $f[2].StartsWith('*')
    $dowRestricted = -not $f[4].StartsWith('*')

    $t = $From.AddMinutes(1)
    $t = [datetime]::new($t.Year, $t.Month, $t.Day, $t.Hour, $t.Minute, 0, $From.Kind)

    for ($i = 0; $i -lt 1462; $i++) {   # 4 years covers every valid dom/month combo
        $d = $t.Date.AddDays($i)
        if ($months -notcontains $d.Month) { continue }
        $domOk = $doms -contains $d.Day
        $dowOk = $dows -contains [int]$d.DayOfWeek
        $dayOk = if ($domRestricted -and $dowRestricted) { $domOk -or $dowOk }
        elseif ($domRestricted) { $domOk }
        elseif ($dowRestricted) { $dowOk }
        else { $true }
        if (-not $dayOk) { continue }

        $startH = if ($i -eq 0) { $t.Hour } else { 0 }
        foreach ($h in $hours) {
            if ($h -lt $startH) { continue }
            $startM = if ($i -eq 0 -and $h -eq $t.Hour) { $t.Minute } else { 0 }
            foreach ($mi in $minutes) {
                if ($mi -lt $startM) { continue }
                return $d.AddHours($h).AddMinutes($mi)
            }
        }
    }
    $null
}

# ---------------------------------------------------------------------------
# Validation + natural language conversion
# ---------------------------------------------------------------------------
function Test-PssCronExpression {
    param([string]$Expression)
    $e = $Expression.Trim()
    if ($e -match '^@(hourly|daily|weekly|monthly|yearly|annually|reboot|midnight)$') { return $true }
    $fields = $e -split '\s+'
    if ($fields.Count -ne 5) { return $false }
    # parse every field with the same parser Get-PssCronNext uses — a charset
    # check isn't enough ("every day at five pm" is 5 fields of letters)
    $null -ne (ConvertFrom-PssCronField $fields[0] 0 59) -and
    $null -ne (ConvertFrom-PssCronField $fields[1] 0 23) -and
    $null -ne (ConvertFrom-PssCronField $fields[2] 1 31) -and
    $null -ne (ConvertFrom-PssCronField $fields[3] 1 12 $script:CronMonthNames) -and
    $null -ne (ConvertFrom-PssCronField $fields[4] 0 7 $script:CronDowNames)
}

# Returns @{ Expression; Source = 'literal'|'ai'; Error }
function Convert-PssToCron {
    param([Parameter(Mandatory)][string]$Text)
    $t = $Text.Trim()
    if (Test-PssCronExpression $t) {
        return @{ Expression = $t; Source = 'literal'; Error = $null }
    }
    $apiKey = $env:OPENROUTER_API_KEY
    if (-not $apiKey) {
        return @{ Expression = $null; Source = 'ai'; Error = 'not a cron expression, and OPENROUTER_API_KEY is not set for natural-language conversion' }
    }
    $cfg = Get-PssConfig
    try {
        $body = @{
            model    = [string]$cfg.openRouterModel
            messages = @(
                @{ role = 'system'; content = 'Convert the user''s scheduling request into a single standard 5-field cron expression. Reply with ONLY the cron expression, nothing else.' },
                @{ role = 'user'; content = $t }
            )
        } | ConvertTo-Json -Depth 5
        $resp = Invoke-RestMethod -Method Post -Uri 'https://openrouter.ai/api/v1/chat/completions' `
            -Headers @{ Authorization = "Bearer $apiKey" } -ContentType 'application/json' `
            -Body $body -TimeoutSec 30
        $raw = "$($resp.choices[0].message.content)" -replace '`', ''
        # models sometimes fence the answer or append prose — take the first
        # line that validates as a cron expression
        foreach ($line in ($raw -split '\r?\n')) {
            $expr = $line.Trim()
            if ($expr -and (Test-PssCronExpression $expr)) {
                return @{ Expression = $expr; Source = 'ai'; Error = $null }
            }
        }
        return @{ Expression = $null; Source = 'ai'; Error = "model returned something that isn't a cron expression: $($raw.Trim())" }
    } catch {
        return @{ Expression = $null; Source = 'ai'; Error = "OpenRouter request failed: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function Get-PssSchedules, Set-PssSchedule, Remove-PssSchedule,
Test-PssCronExpression, Convert-PssToCron, Get-PssCronNext, ConvertFrom-PssCronField
