#Requires -Modules Pester
# CVM PowerShell test suite (Pester v5)
# Tests cvm.ps1 as a black-box subprocess, matching the bats test strategy.
# HTTP-dependent commands (install, ls-remote) are excluded; those paths
# are exercised by the bats suite via mock curl.

BeforeAll {
    $script:CvmScript = (Resolve-Path (Join-Path $PSScriptRoot "..\..\cvm.ps1")).Path

    # ── Helper functions ───────────────────────────────────────────────────────
    # Defined inside BeforeAll so they are in scope during test execution.

    function global:Invoke-Cvm {
        param(
            [Parameter(ValueFromRemainingArguments=$true)]
            [string[]]$Arguments = @()
        )
        # Use Start-Process so that:
        #   1. $proc.ExitCode reliably reflects exit N in cvm.ps1 (not $LASTEXITCODE ambiguity)
        #   2. Each argument is passed as a discrete token (no dash-prefix mis-parsing by pwsh)
        #   3. stdout/stderr are captured via temp files (no 2>&1 interference)
        $tmpOut = [System.IO.Path]::GetTempFileName()
        $tmpErr = [System.IO.Path]::GetTempFileName()
        try {
            $procArgs = @("-NoLogo", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                          "-File", $script:CvmScript) + $Arguments
            $proc = Start-Process pwsh `
                        -ArgumentList $procArgs `
                        -Wait -PassThru -NoNewWindow `
                        -RedirectStandardOutput $tmpOut `
                        -RedirectStandardError  $tmpErr `
                        -WorkingDirectory (Get-Location).Path
            $script:LastExitCode = $proc.ExitCode
            $outText = if ((Get-Item $tmpOut).Length -gt 0) { Get-Content $tmpOut -Raw } else { "" }
            $errText = if ((Get-Item $tmpErr).Length -gt 0) { Get-Content $tmpErr -Raw } else { "" }
            $combined = "$outText$errText"
            return $combined
        } finally {
            Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
            Remove-Item $tmpErr -Force -ErrorAction SilentlyContinue
        }
    }

    function global:New-FakeVersion([string]$Version) {
        $dir = Join-Path $env:CVM_DIR "versions" $Version
        $null = New-Item -ItemType Directory -Path $dir -Force
        $bin = Join-Path $dir "claude.exe"
        Set-Content -Path $bin -Value "fake" -NoNewline
        return $bin
    }

    function global:Set-GlobalDefault([string]$Version) {
        $src = New-FakeVersion $Version
        $binDir = Join-Path $env:CVM_DIR "bin"
        $null = New-Item -ItemType Directory -Path $binDir -Force
        $link = Join-Path $binDir "claude.exe"
        if (Test-Path $link) { Remove-Item $link -Force }
        try   { $null = New-Item -ItemType HardLink -Path $link -Target $src }
        catch { Copy-Item $src $link -Force }
        $Version | Set-Content (Join-Path $env:CVM_DIR "version")
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# All tests live inside this outer Describe so BeforeEach/AfterEach are scoped.
# ═══════════════════════════════════════════════════════════════════════════════

Describe "CVM" {

    BeforeEach {
        # Fresh isolated CVM_DIR per test (mirrors bats setup())
        $env:CVM_DIR = Join-Path ([System.IO.Path]::GetTempPath()) "cvm-test-$([System.IO.Path]::GetRandomFileName())"
        Remove-Item Env:\CVM_VERSION -ErrorAction SilentlyContinue

        $script:TestWorkdir = Join-Path ([System.IO.Path]::GetTempPath()) "cvm-wd-$([System.IO.Path]::GetRandomFileName())"
        $null = New-Item -ItemType Directory -Path $script:TestWorkdir -Force
        Push-Location $script:TestWorkdir
    }

    AfterEach {
        Pop-Location
        if ($env:CVM_DIR -and (Test-Path $env:CVM_DIR)) {
            Remove-Item $env:CVM_DIR -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:TestWorkdir -and (Test-Path $script:TestWorkdir)) {
            Remove-Item $script:TestWorkdir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item Env:\CVM_DIR     -ErrorAction SilentlyContinue
        Remove-Item Env:\CVM_VERSION -ErrorAction SilentlyContinue
    }

    # ── Basic commands ────────────────────────────────────────────────────────

    Describe "Basic commands" {
        It "version prints version number" {
            $out = Invoke-Cvm "version"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match 'cvm \d+\.\d+\.\d+'
        }

        It "--version flag works" {
            $out = Invoke-Cvm "--version"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match 'cvm'
        }

        It "help shows USAGE and COMMANDS" {
            $out = Invoke-Cvm "help"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match 'USAGE'
            $out | Should -Match 'COMMANDS'
        }

        It "--help flag works" {
            $out = Invoke-Cvm "--help"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match 'USAGE'
        }

        It "unknown command exits non-zero" {
            Invoke-Cvm "notacommand" | Out-Null
            $script:LastExitCode | Should -Not -Be 0
        }

        It "no args defaults to help" {
            $out = Invoke-Cvm
            $script:LastExitCode | Should -Be 0
            $out | Should -Match 'USAGE'
        }
    }

    # ── Platform detection ────────────────────────────────────────────────────

    Describe "Platform detection" {
        It "runs on Windows and detects win32-x64 binary name" {
            # Pre-populate a win32-x64 style version and verify 'which' returns .exe
            Set-GlobalDefault "2.1.71"
            $out = Invoke-Cvm "which"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match 'claude\.exe'
        }
    }

    # ── env command ───────────────────────────────────────────────────────────

    Describe "env command" {
        It "env --pwsh outputs PowerShell PATH syntax" {
            $out = Invoke-Cvm "env" "--pwsh"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match '\$env:PATH'
        }

        It "env --powershell outputs PowerShell PATH syntax" {
            $out = Invoke-Cvm "env" "--powershell"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match '\$env:PATH'
        }

        It "env --bash outputs export PATH syntax" {
            $out = Invoke-Cvm "env" "--bash"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match 'export PATH'
        }

        It "env output contains CVM_DIR path" {
            $out = Invoke-Cvm "env" "--pwsh"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match ([regex]::Escape($env:CVM_DIR))
        }

        It "env unknown shell exits non-zero" {
            Invoke-Cvm "env" "--notashell" | Out-Null
            $script:LastExitCode | Should -Not -Be 0
        }
    }

    # ── Version resolution ────────────────────────────────────────────────────

    Describe "Version resolution" {
        It "current with no config prints 'none' and exits non-zero" {
            $out = Invoke-Cvm "current"
            $script:LastExitCode | Should -Not -Be 0
            $out | Should -Match 'none'
        }

        It "current with global default prints that version" {
            Set-GlobalDefault "2.1.71"
            $out = Invoke-Cvm "current"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match '2\.1\.71'
        }

        It "current with CVM_VERSION env var uses it" {
            $env:CVM_VERSION = "2.1.55"
            $out = Invoke-Cvm "current"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match '2\.1\.55'
        }

        It "current with .claude-version in cwd uses it" {
            "2.1.58" | Set-Content ".claude-version"
            $out = Invoke-Cvm "current"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match '2\.1\.58'
        }

        It "CVM_VERSION env overrides .claude-version" {
            "2.1.58" | Set-Content ".claude-version"
            $env:CVM_VERSION = "2.1.99"
            $out = Invoke-Cvm "current"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match '2\.1\.99'
        }

        It ".claude-version overrides global default" {
            Set-GlobalDefault "2.1.71"
            "2.1.58" | Set-Content ".claude-version"
            $out = Invoke-Cvm "current"
            $out | Should -Match '2\.1\.58'
        }
    }

    # ── which command ─────────────────────────────────────────────────────────

    Describe "which command" {
        It "which with no version exits non-zero" {
            Invoke-Cvm "which" | Out-Null
            $script:LastExitCode | Should -Not -Be 0
        }

        It "which with global default prints path" {
            Set-GlobalDefault "2.1.71"
            $out = Invoke-Cvm "which"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match '2\.1\.71'
            $out | Should -Match 'claude\.exe'
        }

        It "which path exists as a file" {
            Set-GlobalDefault "2.1.71"
            $path = (Invoke-Cvm "which").Trim()
            Test-Path $path | Should -Be $true
        }

        It "which with CVM_VERSION env" {
            Set-GlobalDefault "2.1.71"
            New-FakeVersion "2.1.58" | Out-Null
            $env:CVM_VERSION = "2.1.58"
            $out = Invoke-Cvm "which"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match '2\.1\.58'
        }
    }

    # ── ls command ────────────────────────────────────────────────────────────

    Describe "ls command" {
        It "ls with no versions shows helpful message" {
            $out = Invoke-Cvm "ls"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match 'No versions'
        }

        It "ls shows installed versions" {
            New-FakeVersion "2.1.58" | Out-Null
            New-FakeVersion "2.1.71" | Out-Null
            $out = Invoke-Cvm "ls"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match '2\.1\.58'
            $out | Should -Match '2\.1\.71'
        }

        It "ls marks active version" {
            Set-GlobalDefault "2.1.71"
            New-FakeVersion "2.1.58" | Out-Null
            $out = Invoke-Cvm "ls"
            ($out -split "`n") | Where-Object { $_ -match '2\.1\.71' } |
                Should -Match '(active|->|→)'
        }

        It "list is an alias for ls" {
            New-FakeVersion "2.1.71" | Out-Null
            $out = Invoke-Cvm "list"
            $script:LastExitCode | Should -Be 0
            $out | Should -Match '2\.1\.71'
        }
    }

    # ── use command ───────────────────────────────────────────────────────────

    Describe "use command" {
        It "use sets global default" {
            New-FakeVersion "2.1.58" | Out-Null
            New-FakeVersion "2.1.71" | Out-Null
            Set-GlobalDefault "2.1.58"

            Invoke-Cvm "use" "2.1.71" | Out-Null
            $script:LastExitCode | Should -Be 0

            $ver = (Get-Content (Join-Path $env:CVM_DIR "version") -Raw).Trim()
            $ver | Should -Be "2.1.71"
        }

        It "use creates claude.exe link in bin" {
            New-FakeVersion "2.1.71" | Out-Null
            Invoke-Cvm "use" "2.1.71" | Out-Null
            Test-Path (Join-Path $env:CVM_DIR "bin" "claude.exe") | Should -Be $true
        }

        It "use prints confirmation" {
            New-FakeVersion "2.1.71" | Out-Null
            $out = Invoke-Cvm "use" "2.1.71"
            $out | Should -Match '2\.1\.71'
        }

        It "use non-installed version exits non-zero" {
            Invoke-Cvm "use" "9.9.99" | Out-Null
            $script:LastExitCode | Should -Not -Be 0
        }

        It "use without args exits non-zero" {
            Invoke-Cvm "use" | Out-Null
            $script:LastExitCode | Should -Not -Be 0
        }
    }

    # ── local command ─────────────────────────────────────────────────────────

    Describe "local command" {
        It "local writes .claude-version" {
            New-FakeVersion "2.1.58" | Out-Null
            Invoke-Cvm "local" "2.1.58" | Out-Null
            $script:LastExitCode | Should -Be 0
            Test-Path ".claude-version" | Should -Be $true
            (Get-Content ".claude-version" -Raw).Trim() | Should -Be "2.1.58"
        }

        It "local strips leading v" {
            New-FakeVersion "2.1.58" | Out-Null
            Invoke-Cvm "local" "v2.1.58" | Out-Null
            (Get-Content ".claude-version" -Raw).Trim() | Should -Be "2.1.58"
        }

        It "local without arg exits non-zero" {
            Invoke-Cvm "local" | Out-Null
            $script:LastExitCode | Should -Not -Be 0
        }

        It "local warns when version not installed" {
            $out = Invoke-Cvm "local" "9.9.99"
            $out | Should -Match '(warn|not installed|install)'
        }
    }

    # ── uninstall command ─────────────────────────────────────────────────────

    Describe "uninstall command" {
        It "uninstall removes version directory" {
            New-FakeVersion "2.1.71" | Out-Null
            Set-GlobalDefault "2.1.58"

            Invoke-Cvm "uninstall" "2.1.71" | Out-Null
            $script:LastExitCode | Should -Be 0
            Test-Path (Join-Path $env:CVM_DIR "versions" "2.1.71") | Should -Be $false
        }

        It "uninstall prints confirmation" {
            New-FakeVersion "2.1.71" | Out-Null
            $out = Invoke-Cvm "uninstall" "2.1.71"
            $out | Should -Match 'Uninstalled'
        }

        It "uninstall without args exits non-zero" {
            Invoke-Cvm "uninstall" | Out-Null
            $script:LastExitCode | Should -Not -Be 0
        }

        It "uninstall non-installed version exits non-zero" {
            Invoke-Cvm "uninstall" "9.9.99" | Out-Null
            $script:LastExitCode | Should -Not -Be 0
        }

        It "uninstall active version clears default file" {
            Set-GlobalDefault "2.1.71"
            Invoke-Cvm "uninstall" "2.1.71" | Out-Null
            Test-Path (Join-Path $env:CVM_DIR "version") | Should -Be $false
        }

        It "remove is an alias for uninstall" {
            New-FakeVersion "2.1.71" | Out-Null
            Set-GlobalDefault "2.1.58"
            Invoke-Cvm "remove" "2.1.71" | Out-Null
            $script:LastExitCode | Should -Be 0
            Test-Path (Join-Path $env:CVM_DIR "versions" "2.1.71") | Should -Be $false
        }
    }

    # ── CVM_DIR isolation ─────────────────────────────────────────────────────

    Describe "CVM_DIR isolation" {
        It "CVM_DIR env var controls install location" {
            $altDir = Join-Path ([System.IO.Path]::GetTempPath()) "cvm-alt-$([System.IO.Path]::GetRandomFileName())"
            try {
                $env:CVM_DIR = $altDir
                New-FakeVersion "2.1.71" | Out-Null
                $out = Invoke-Cvm "ls"
                $out | Should -Match '2\.1\.71'
                Test-Path (Join-Path $altDir "versions" "2.1.71") | Should -Be $true
            } finally {
                if (Test-Path $altDir) { Remove-Item $altDir -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }

} # end Describe "CVM"
