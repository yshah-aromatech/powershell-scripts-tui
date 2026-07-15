BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Core.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '../src/Cron.psm1') -Force -DisableNameChecking
    $script:from = [datetime]::new(2026, 7, 3, 14, 30, 45)   # Friday
}

Describe 'Test-PssCronExpression' {
    It 'accepts 5-field expressions' { Test-PssCronExpression '*/15 * * * *' | Should -BeTrue }
    It 'accepts @keywords' { Test-PssCronExpression '@daily' | Should -BeTrue }
    It 'accepts month/dow names' { Test-PssCronExpression '0 8 * * mon-fri' | Should -BeTrue }
    It 'rejects wrong field counts' { Test-PssCronExpression '* * * *' | Should -BeFalse }
    It 'rejects free text' { Test-PssCronExpression 'every day at 8' | Should -BeFalse }
    It 'rejects 5-word free text' { Test-PssCronExpression 'every day at five pm' | Should -BeFalse }
    It 'rejects out-of-range values' { Test-PssCronExpression '99 * * * *' | Should -BeFalse }
    It 'rejects names in numeric fields' { Test-PssCronExpression '* * * * banana' | Should -BeFalse }
}

Describe 'Convert-PssToCron' {
    It 'passes literal cron through without the AI' {
        $r = Convert-PssToCron '*/5 * * * *'
        $r.Expression | Should -Be '*/5 * * * *'
        $r.Source | Should -Be 'literal'
    }
    It 'routes 5-word English to the AI path (errors without a key)' {
        $saved = $env:OPENROUTER_API_KEY
        try {
            $env:OPENROUTER_API_KEY = ''
            $r = Convert-PssToCron 'every day at five pm'
            $r.Expression | Should -Be $null
            $r.Source | Should -Be 'ai'
            $r.Error | Should -Match 'OPENROUTER_API_KEY'
        } finally { $env:OPENROUTER_API_KEY = $saved }
    }
}

Describe 'ConvertFrom-PssCronField' {
    It 'expands *' { ConvertFrom-PssCronField '*' 0 3 | Should -Be @(0, 1, 2, 3) }
    It 'expands steps' { ConvertFrom-PssCronField '*/15' 0 59 | Should -Be @(0, 15, 30, 45) }
    It 'expands ranges' { ConvertFrom-PssCronField '2-4' 0 59 | Should -Be @(2, 3, 4) }
    It 'expands lists' { ConvertFrom-PssCronField '1,5,9' 0 59 | Should -Be @(1, 5, 9) }
    It 'expands value/step to value..max' { ConvertFrom-PssCronField '50/5' 0 59 | Should -Be @(50, 55) }
    It 'resolves names' { ConvertFrom-PssCronField 'mon-wed' 0 7 @{ mon = 1; tue = 2; wed = 3 } | Should -Be @(1, 2, 3) }
    It 'returns null for out-of-range values' { ConvertFrom-PssCronField '99' 0 59 | Should -Be $null }
    It 'returns null for garbage' { ConvertFrom-PssCronField 'nope' 0 59 | Should -Be $null }
}

Describe 'Get-PssCronNext' {
    It 'finds the next step boundary' {
        Get-PssCronNext '*/15 * * * *' $from | Should -Be ([datetime]::new(2026, 7, 3, 14, 45, 0))
    }
    It 'rolls to the next day for @daily' {
        Get-PssCronNext '@daily' $from | Should -Be ([datetime]::new(2026, 7, 4, 0, 0, 0))
    }
    It 'honors day-of-week names' {
        Get-PssCronNext '0 20 * * sat' $from | Should -Be ([datetime]::new(2026, 7, 4, 20, 0, 0))
    }
    It 'honors day-of-month' {
        Get-PssCronNext '30 8 1 * *' $from | Should -Be ([datetime]::new(2026, 8, 1, 8, 30, 0))
    }
    It 'finds leap-year Feb 29' {
        Get-PssCronNext '0 0 29 2 *' $from | Should -Be ([datetime]::new(2028, 2, 29, 0, 0, 0))
    }
    It 'applies the vixie dom/dow union rule' {
        # next monday (jul 6) comes before the 15th
        Get-PssCronNext '0 12 1,15 * mon' $from | Should -Be ([datetime]::new(2026, 7, 6, 12, 0, 0))
    }
    It 'fires this minute + 1 at the earliest' {
        (Get-PssCronNext '* * * * *' $from) | Should -Be ([datetime]::new(2026, 7, 3, 14, 31, 0))
    }
    It 'returns null for @reboot' {
        Get-PssCronNext '@reboot' $from | Should -Be $null
    }
    It 'returns null for unparseable expressions' {
        Get-PssCronNext 'not a cron' $from | Should -Be $null
    }
    It 'returns null for impossible dates' {
        Get-PssCronNext '0 0 31 2 *' $from | Should -Be $null
    }
    It 'treats 7 as sunday' {
        Get-PssCronNext '0 9 * * 7' $from | Should -Be ([datetime]::new(2026, 7, 5, 9, 0, 0))
    }
}
