BeforeAll {
    foreach ($m in 'Core', 'Scripts', 'Deps', 'Runner') {
        Import-Module (Join-Path $PSScriptRoot "../src/$m.psm1") -Force -DisableNameChecking
    }
    # isolated app + data dir so tests never touch ~/.psscripts
    $script:appDir = Join-Path ([IO.Path]::GetTempPath()) "pss-runner-tests-$(New-Guid)"
    New-Item -ItemType Directory -Path $script:appDir -Force | Out-Null
    @{ dataDir = (Join-Path $script:appDir 'data') } | ConvertTo-Json |
        Set-Content (Join-Path $script:appDir 'config.json')
    Initialize-Pss -AppDir $script:appDir
}

AfterAll {
    Remove-Item $script:appDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Lock-PssScript / Unlock-PssScript' {
    It 'acquires and blocks a second acquire' {
        $l1 = Lock-PssScript -Name 'lock-a'
        $l1.Acquired | Should -BeTrue
        (Lock-PssScript -Name 'lock-a').Acquired | Should -BeFalse
        Unlock-PssScript -Handle @{ LockFile = $l1.File }
    }

    It 'reports the owning pid' {
        $l1 = Lock-PssScript -Name 'lock-b'
        (Lock-PssScript -Name 'lock-b').Pid | Should -Be $PID
        Unlock-PssScript -Handle @{ LockFile = $l1.File }
    }

    It 'reclaims a stale lock whose owner is dead' {
        $stale = Join-Path (Get-PssPaths).LocksDir 'lock-c.lock'
        '999999' | Set-Content $stale
        $l = Lock-PssScript -Name 'lock-c'
        $l.Acquired | Should -BeTrue
        Unlock-PssScript -Handle @{ LockFile = $l.File }
    }

    It 'can re-acquire after unlock' {
        $l1 = Lock-PssScript -Name 'lock-d'
        Unlock-PssScript -Handle @{ LockFile = $l1.File }
        (Lock-PssScript -Name 'lock-d').Acquired | Should -BeTrue
    }
}

Describe 'Start-PssRun skip behavior' {
    It 'returns a finished skipped handle when the lock is held' {
        $s = [pscustomobject]@{
            Name = 'skiptest'; Dir = $script:appDir; Entry = (Join-Path $script:appDir 'none.ps1')
            Args = @(); EnvFile = (Join-Path $script:appDir '.env')
            ModuleDir = (Join-Path $script:appDir 'mods'); TimeoutMinutes = $null
        }
        $lock = Lock-PssScript -Name 'skiptest'
        try {
            $h = Start-PssRun -Script $s
            $h.Status | Should -Be 'skipped'
            Test-PssRunFinished -Handle $h | Should -BeTrue
            $result = Complete-PssRun -Handle $h
            $result.status | Should -Be 'skipped'
            $result.success | Should -BeFalse
        } finally {
            Unlock-PssScript -Handle @{ LockFile = $lock.File }
        }
    }
}

Describe 'run pipeline' {
    It 'runs a script, records history, releases the lock' {
        $dir = Join-Path $script:appDir 'scripts-src'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        'Write-Output "out line"' | Set-Content (Join-Path $dir 'ok.ps1')
        $s = [pscustomobject]@{
            Name = 'ok'; Dir = $dir; Entry = (Join-Path $dir 'ok.ps1')
            Args = @(); EnvFile = (Join-Path $dir '.env')
            ModuleDir = (Join-Path $dir 'mods'); TimeoutMinutes = 2
        }
        $h = Start-PssRun -Script $s
        $h.TimeoutMinutes | Should -Be 2
        $lines = [System.Collections.Generic.List[string]]::new()
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-PssRunFinished -Handle $h) -and (Get-Date) -lt $deadline) {
            foreach ($l in (Update-PssRun -Handle $h)) { $lines.Add($l) }
            Start-Sleep -Milliseconds 50
        }
        foreach ($l in (Update-PssRun -Handle $h)) { $lines.Add($l) }
        $result = Complete-PssRun -Handle $h

        $result.status | Should -Be 'success'
        $lines | Should -Contain 'out line'
        Test-Path (Join-Path (Get-PssPaths).LocksDir 'ok.lock') | Should -BeFalse
        (Get-PssLastStatuses)['ok'].Status | Should -Be 'success'
        (Get-PssLastStatuses)['ok'].At | Should -BeOfType [datetime]
    }
}

Describe 'Get-PssDownsampledSeries' {
    It 'passes short series through' {
        Get-PssDownsampledSeries -Series @(1.0, 2.0) -MaxPoints 60 | Should -Be @(1.0, 2.0)
    }
    It 'downsamples to MaxPoints keeping bucket maxima' {
        $r = @(Get-PssDownsampledSeries -Series @(1..100 | ForEach-Object { [double]$_ }) -MaxPoints 10)
        $r.Count | Should -Be 10
        $r[9] | Should -Be 100
        $r[0] | Should -Be 10
    }
}

Describe 'webhook dead-letter queue' {
    It 'flushes nothing when the queue file is absent' {
        Send-PssWebhookQueue | Should -Be 0
    }
}

Describe 'python run pipeline' {
    It 'runs a python script through the full pipeline' -Skip:(-not (Get-Command python3 -ErrorAction SilentlyContinue)) {
        $dir = Join-Path $script:appDir 'pyscripts-src'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        "import os`nprint('py out', os.environ.get('PSS_PY_TEST', ''))" | Set-Content (Join-Path $dir 'main.py')
        $s = [pscustomobject]@{
            Name = 'pyok'; Dir = $dir; Entry = (Join-Path $dir 'main.py')
            Runtime = 'python'; Repo = 'pyrepo'
            Args = @(); EnvFile = (Join-Path $dir '.env')
            ModuleDir = (Join-Path $dir 'mods'); TimeoutMinutes = 3
            VenvDir = (Join-Path (Get-PssPaths).VenvsDir 'pyok')
        }
        $h = Start-PssRun -Script $s -ExtraEnv @{ PSS_PY_TEST = 'hello-from-env' }
        $result = Invoke-PssRunToCompletion -Handle $h
        $result.status | Should -Be 'success'
        $result.runtime | Should -Be 'python'
        $result.repo | Should -Be 'pyrepo'
        # the env value arrived (non-empty output after 'py out') and, being
        # an ExtraEnv-supplied secret, was redacted in the log
        $log = Get-Content $result.logFile -Raw
        $log | Should -Match 'py out \*\*\*'
        $log | Should -Not -Match 'hello-from-env'
        Test-Path (Join-Path (Get-PssPaths).LocksDir 'pyok.lock') | Should -BeFalse
    }
}
