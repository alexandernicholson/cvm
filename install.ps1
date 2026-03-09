#!/usr/bin/env pwsh
# CVM Windows Installer
# Usage (PowerShell): irm https://raw.githubusercontent.com/alexandernicholson/cvm/main/install.ps1 | iex
#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$CVM_DIR        = if ($env:CVM_DIR) { $env:CVM_DIR } else { Join-Path $HOME ".cvm" }
$CVM_BIN        = Join-Path $CVM_DIR "bin"
$CVM_SCRIPT_URL = "https://raw.githubusercontent.com/alexandernicholson/cvm/main/cvm.ps1"

Write-Host "Installing CVM..." -ForegroundColor Cyan
$null = New-Item -ItemType Directory -Path $CVM_BIN -Force

# ── Download cvm.ps1 ──────────────────────────────────────────────────────────
$cvmScript = Join-Path $CVM_BIN "cvm.ps1"
Write-Host "-> Downloading cvm.ps1 to $cvmScript"
Invoke-WebRequest -Uri $CVM_SCRIPT_URL -OutFile $cvmScript -UseBasicParsing

# ── Create cvm.cmd wrapper (enables `cvm` from CMD and PowerShell on PATH) ────
$cvmCmd = Join-Path $CVM_BIN "cvm.cmd"
Set-Content -Path $cvmCmd -Value "@echo off`r`npwsh -NoLogo -NonInteractive -File `"%~dp0cvm.ps1`" %*" -NoNewline:$false

# ── Add CVM_BIN to user PATH (persistent) ────────────────────────────────────
$userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($userPath -notlike "*$CVM_BIN*") {
    [Environment]::SetEnvironmentVariable("PATH", "$CVM_BIN;$userPath", "User")
    Write-Host "v Added $CVM_BIN to user PATH" -ForegroundColor Green
} else {
    Write-Host "  $CVM_BIN is already in PATH" -ForegroundColor Gray
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "v CVM installed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Reload your terminal to pick up the PATH change, then:" -ForegroundColor Cyan
Write-Host "  cvm install latest"
Write-Host "  claude --version"
Write-Host ""
Write-Host "For the current session only (no terminal reload needed):"
Write-Host "  `$env:PATH = `"$CVM_BIN;`$env:PATH`""
Write-Host ""
Write-Host "To add CVM to your PowerShell profile permanently, run:"
Write-Host "  Add-Content `$PROFILE `"`n`$env:PATH = \`"`$env:USERPROFILE\.cvm\bin;`$env:PATH\`"`""
