#!/usr/bin/env pwsh
# CVM - Claude (Code) Version Manager (Windows / PowerShell)
# https://github.com/alexandernicholson/cvm
#Requires -Version 5.1

[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Position=0)][string]$Command = "help",
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$CmdArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # suppress Invoke-WebRequest progress bars

# ── Constants ─────────────────────────────────────────────────────────────────
$script:CVM_SELF_VERSION = "0.1.0"
$script:CvmDir      = if ($env:CVM_DIR) { $env:CVM_DIR } else { Join-Path $HOME ".cvm" }
$script:CvmBin      = Join-Path $script:CvmDir "bin"
$script:CvmVersions = Join-Path $script:CvmDir "versions"
$script:CvmCache    = Join-Path $script:CvmDir "cache"
$script:CvmDefault  = Join-Path $script:CvmDir "version"

$CVM_DIST_BASE   = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
$CVM_NPM         = "https://registry.npmjs.org/@anthropic-ai/claude-code"
$CVM_GITHUB_TAGS = "https://api.github.com/repos/anthropics/claude-code/tags"
$CVM_GITHUB_RAW  = "https://raw.githubusercontent.com/alexandernicholson/cvm/main/cvm.ps1"

# ── Logging ───────────────────────────────────────────────────────────────────
function Write-Info([string]$msg) { Write-Host "-> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "v $msg"  -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "warn: $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)  { Write-Host "error: $msg" -ForegroundColor Red }
function Stop-Cvm([string]$msg)   { Write-Err $msg; exit 1 }

# ── Platform Detection ────────────────────────────────────────────────────────
function Get-CvmPlatform {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLower()
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        switch ($arch) {
            "x64"   { return "win32-x64" }
            "arm64" { return "win32-arm64" }
            default { Stop-Cvm "Unsupported Windows architecture: $arch" }
        }
    } elseif ($IsMacOS) {
        switch ($arch) {
            "arm64" { return "darwin-arm64" }
            "x64"   { return "darwin-x64" }
            default { Stop-Cvm "Unsupported macOS architecture: $arch" }
        }
    } elseif ($IsLinux) {
        $musl = ""
        try {
            if ((ldd /bin/sh 2>/dev/null) -match "musl") { $musl = "-musl" }
        } catch {}
        switch ($arch) {
            "x64"   { return "linux-x64$musl" }
            "arm64" { return "linux-arm64$musl" }
            default { Stop-Cvm "Unsupported Linux architecture: $arch" }
        }
    } else {
        Stop-Cvm "Unsupported operating system"
    }
}

function Get-BinaryName([string]$platform) {
    if ($platform -like "win32-*") { return "claude.exe" } else { return "claude" }
}

# ── HTTP helpers ──────────────────────────────────────────────────────────────
function Invoke-CvmGet([string]$url, [int]$timeout = 15) {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeout
        return [System.Text.Encoding]::UTF8.GetString($r.Content)
    } catch { return $null }
}

function Save-CvmFile([string]$url, [string]$dest, [int]$timeout = 300) {
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec $timeout
}

# ── JSON helpers ──────────────────────────────────────────────────────────────
function Get-ChecksumFromManifest([string]$platform, [string]$json) {
    try {
        $data = $json | ConvertFrom-Json
        return $data.platforms.$platform.checksum
    } catch { return $null }
}

function Get-VersionsFromGitHub([string]$json) {
    try {
        return @(($json | ConvertFrom-Json) |
            ForEach-Object { $_.name -replace '^v', '' } |
            Where-Object { $_ -match '^\d+\.\d+\.\d+$' })
    } catch { return @() }
}

function Get-VersionsFromNpm([string]$json) {
    try {
        $data = $json | ConvertFrom-Json
        return @($data.versions.PSObject.Properties.Name |
            Where-Object { $_ -match '^\d+\.\d+\.\d+$' })
    } catch { return @() }
}

function Sort-SemVer([string[]]$versions) {
    $uniq = @($versions | Where-Object { $_ -ne "" } | Sort-Object -Unique)
    return @($uniq | Sort-Object {
        $p = $_ -split '\.'
        try { [int]$p[0] * 1000000 + [int]$p[1] * 1000 + [int]$p[2] }
        catch { 0 }
    })
}

# ── Checksum Verification ─────────────────────────────────────────────────────
function Test-Checksum([string]$file, [string]$expected) {
    if (-not $expected) {
        Write-Warn "No checksum in manifest, skipping verification"
        return $true
    }
    $actual = (Get-FileHash -Path $file -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected.ToLower()) {
        Write-Err "Checksum mismatch for $(Split-Path $file -Leaf)"
        Write-Err "  expected: $expected"
        Write-Err "  actual:   $actual"
        return $false
    }
    return $true
}

# ── Link Management ───────────────────────────────────────────────────────────
function Update-CvmLink([string]$version) {
    $platform = Get-CvmPlatform
    $binName  = Get-BinaryName $platform
    $target   = Join-Path $script:CvmVersions $version $binName
    $link     = Join-Path $script:CvmBin $binName

    if (-not (Test-Path $target)) { Stop-Cvm "Version $version not installed at $target" }
    $null = New-Item -ItemType Directory -Path $script:CvmBin -Force
    if (Test-Path $link) { Remove-Item $link -Force }

    # Hard link (no admin required); fall back to copy
    try {
        $null = New-Item -ItemType HardLink -Path $link -Target $target
    } catch {
        Copy-Item -Path $target -Destination $link -Force
        Write-Warn "Hard links unavailable, copied binary instead"
    }
}

# ── Version Resolution ────────────────────────────────────────────────────────
function Resolve-Channel([string]$spec) {
    if ($spec -match '^(latest|stable)$') {
        $ver = Invoke-CvmGet "$CVM_DIST_BASE/$spec"
        if (-not $ver) { Stop-Cvm "Failed to resolve '$spec' channel" }
        return $ver.Trim()
    }
    return $spec.TrimStart('v')
}

function Get-ActiveVersion {
    # 1. Environment variable
    if ($env:CVM_VERSION) { return $env:CVM_VERSION.Trim() }

    # 2. Walk up directory tree
    $dir = (Get-Location).Path
    while ($true) {
        $f = Join-Path $dir ".claude-version"
        if (Test-Path $f) {
            $v = (Get-Content $f -Raw).Trim()
            if ($v) { return $v }
        }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }

    # 3. Global default
    if (Test-Path $script:CvmDefault) {
        $v = (Get-Content $script:CvmDefault -Raw).Trim()
        if ($v) { return $v }
    }
    return $null
}

# ── Directory Setup ───────────────────────────────────────────────────────────
function Initialize-Dirs {
    foreach ($d in @($script:CvmBin, $script:CvmVersions, $script:CvmCache)) {
        $null = New-Item -ItemType Directory -Path $d -Force
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Commands
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-Install([string]$spec = "latest") {
    Initialize-Dirs
    Write-Info "Resolving version: $spec"
    $version = Resolve-Channel $spec
    if (-not $version) { Stop-Cvm "Could not resolve version from spec: $spec" }

    $platform   = Get-CvmPlatform
    $binName    = Get-BinaryName $platform
    $versionDir = Join-Path $script:CvmVersions $version
    $binaryPath = Join-Path $versionDir $binName

    if (Test-Path $binaryPath) {
        Write-Ok "Claude Code $version already installed"
        if (-not (Test-Path $script:CvmDefault)) {
            $version | Set-Content $script:CvmDefault
            Update-CvmLink $version
            Write-Ok "Set $version as default"
        }
        return
    }

    Write-Info "Installing Claude Code $version for platform $platform"
    $manifestUrl = "$CVM_DIST_BASE/$version/manifest.json"
    Write-Info "Fetching manifest..."
    $manifest = Invoke-CvmGet $manifestUrl 15
    if (-not $manifest) { Stop-Cvm "Failed to fetch manifest for $version. Version may not exist." }

    $checksum  = Get-ChecksumFromManifest $platform $manifest
    $binaryUrl = "$CVM_DIST_BASE/$version/$platform/$binName"
    $tmpFile   = Join-Path $script:CvmCache "claude-$version-$([System.IO.Path]::GetRandomFileName())"

    Write-Info "Downloading claude $version..."
    try {
        Save-CvmFile $binaryUrl $tmpFile 300
    } catch {
        if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force }
        Stop-Cvm "Download failed: $binaryUrl"
    }

    Write-Info "Verifying checksum..."
    if (-not (Test-Checksum $tmpFile $checksum)) {
        Remove-Item $tmpFile -Force
        Stop-Cvm "Checksum verification failed. Aborting install."
    }

    $null = New-Item -ItemType Directory -Path $versionDir -Force
    Move-Item $tmpFile $binaryPath -Force
    Write-Ok "Installed Claude Code $version"

    if (-not (Test-Path $script:CvmDefault)) {
        $version | Set-Content $script:CvmDefault
        Update-CvmLink $version
        Write-Ok "Set $version as default"
    }
}

function Invoke-Use([string]$spec = "") {
    if (-not $spec) { Stop-Cvm "Usage: cvm use <version|latest|stable>" }
    $version    = Resolve-Channel $spec
    $versionDir = Join-Path $script:CvmVersions $version
    if (-not (Test-Path $versionDir)) {
        Stop-Cvm "Version $version is not installed. Run: cvm install $version"
    }
    Update-CvmLink $version
    $version | Set-Content $script:CvmDefault
    Write-Ok "Now using Claude Code $version (global)"
}

function Invoke-Local([string]$spec = "") {
    if (-not $spec) { Stop-Cvm "Usage: cvm local <version|latest|stable>" }
    $version    = Resolve-Channel $spec
    $versionDir = Join-Path $script:CvmVersions $version
    if (-not (Test-Path $versionDir)) {
        Write-Warn "Version $version is not installed. Install it with: cvm install $version"
    }
    $version | Set-Content ".claude-version"
    Write-Ok "Wrote .claude-version: $version"
}

function Invoke-Current {
    $v = Get-ActiveVersion
    if ($v) { Write-Output $v } else { Write-Output "none"; exit 1 }
}

function Invoke-Which {
    $version = Get-ActiveVersion
    if (-not $version) { Stop-Cvm "No version active. Run: cvm use <version>" }
    $platform = Get-CvmPlatform
    $binName  = Get-BinaryName $platform
    $binary   = Join-Path $script:CvmVersions $version $binName
    if (-not (Test-Path $binary)) {
        Stop-Cvm "Version $version is not installed. Run: cvm install $version"
    }
    Write-Output $binary
}

function Invoke-List {
    $current = Get-ActiveVersion
    if (-not (Test-Path $script:CvmVersions)) {
        Write-Output "No versions installed."
        Write-Output "Run: cvm install latest"
        return
    }
    $dirs = @(Get-ChildItem $script:CvmVersions -Directory)
    if ($dirs.Count -eq 0) {
        Write-Output "No versions installed."
        Write-Output "Run: cvm install latest"
        return
    }
    Write-Output "Installed versions:"
    foreach ($d in $dirs) {
        if ($d.Name -eq $current) {
            Write-Host "  -> $($d.Name)  (active)" -ForegroundColor Green
        } else {
            Write-Output "     $($d.Name)"
        }
    }
}

function Invoke-ListRemote([switch]$All) {
    Write-Info "Fetching available versions..."

    $ghVersions  = @()
    $npmVersions = @()

    $ghData = Invoke-CvmGet "${CVM_GITHUB_TAGS}?per_page=100" 10
    if ($ghData) { $ghVersions  = Get-VersionsFromGitHub $ghData }

    $npmData = Invoke-CvmGet $CVM_NPM 20
    if ($npmData) { $npmVersions = Get-VersionsFromNpm $npmData }

    if ($ghVersions.Count -eq 0 -and $npmVersions.Count -eq 0) {
        Stop-Cvm "Failed to fetch available versions (GitHub and npm registry both unavailable)"
    }

    $allVersions = Sort-SemVer (@($ghVersions) + @($npmVersions))

    $latest = (Invoke-CvmGet "$CVM_DIST_BASE/latest" 10)?.Trim()
    $stable = (Invoke-CvmGet "$CVM_DIST_BASE/stable" 10)?.Trim()

    $versions = $allVersions
    if (-not $All) {
        $versions = @($allVersions | Select-Object -Last 20)
        Write-Output "Available versions (last 20 of $($allVersions.Count), use --all to see all):"
    } else {
        Write-Output "Available versions:"
    }

    foreach ($ver in $versions) {
        $label = ""
        if ($ver -eq $latest) { $label += " <- latest" }
        if ($ver -eq $stable -and $stable -ne $latest) { $label += " <- stable" }
        if ($label) {
            Write-Host "  $ver$label" -ForegroundColor Cyan
        } else {
            Write-Output "  $ver"
        }
    }
}

function Invoke-Uninstall([string]$version = "") {
    if (-not $version) { Stop-Cvm "Usage: cvm uninstall <version>" }
    $version    = $version.TrimStart('v')
    $versionDir = Join-Path $script:CvmVersions $version
    if (-not (Test-Path $versionDir)) { Stop-Cvm "Version $version is not installed" }

    $current = Get-ActiveVersion
    if ($current -eq $version) {
        Write-Warn "Version $version is currently active"
        $platform = Get-CvmPlatform
        $binName  = Get-BinaryName $platform
        $link     = Join-Path $script:CvmBin $binName
        Remove-Item $link -Force -ErrorAction SilentlyContinue
        Remove-Item $script:CvmDefault -Force -ErrorAction SilentlyContinue
        Write-Warn "Active version cleared. Run 'cvm use <version>' to set another."
    }
    Remove-Item $versionDir -Recurse -Force
    Write-Ok "Uninstalled Claude Code $version"
}

function Invoke-SelfUpdate {
    $scriptPath = $PSCommandPath
    Write-Info "Updating CVM from $CVM_GITHUB_RAW"
    $tmp = Join-Path $script:CvmCache "cvm-update-$([System.IO.Path]::GetRandomFileName()).ps1"
    try {
        Save-CvmFile $CVM_GITHUB_RAW $tmp 30
    } catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force }
        Stop-Cvm "Failed to download CVM update"
    }
    $content = Get-Content $tmp -Raw
    if ($content -notmatch 'cvm|pwsh|PowerShell') {
        Remove-Item $tmp -Force
        Stop-Cvm "Downloaded file doesn't look like a CVM script"
    }
    Move-Item $tmp $scriptPath -Force
    Write-Ok "CVM updated to latest version"
    & $scriptPath version
}

function Invoke-SelfUninstall {
    Write-Host "This will remove CVM and all installed Claude Code versions." -ForegroundColor Yellow
    Write-Host "  Removing: $($script:CvmDir)"
    $confirm = Read-Host "Are you sure? [y/N]"
    if ($confirm -notmatch '^[Yy]$') { Write-Output "Aborted."; return }
    Remove-Item $script:CvmDir -Recurse -Force
    Write-Ok "CVM removed."
    Write-Output ""
    Write-Output "Remove the CVM PATH line from your PowerShell profile (`$PROFILE)."
}

function Invoke-Env([string]$shell = "") {
    if (-not $shell) {
        if ($env:SHELL -match 'fish')       { $shell = "fish" }
        elseif ($env:SHELL -match 'zsh')    { $shell = "zsh" }
        elseif ($env:SHELL -match 'bash')   { $shell = "bash" }
        else                                { $shell = "pwsh" }
    }
    $shell = $shell.TrimStart('-')
    switch ($shell) {
        "fish"                         { Write-Output "fish_add_path $($script:CvmBin)" }
        { $_ -in @("bash","sh") }      { Write-Output "export PATH=`"$($script:CvmDir)/bin:`$PATH`"" }
        "zsh"                          { Write-Output "export PATH=`"$($script:CvmDir)/bin:`$PATH`"" }
        { $_ -in @("pwsh","powershell") } {
            Write-Output "`$env:PATH = `"$($script:CvmBin);`$env:PATH`""
        }
        default { Stop-Cvm "Unknown shell: $shell. Supported: bash, zsh, fish, sh, pwsh" }
    }
}

function Invoke-Help {
    Write-Output @"
cvm v$($script:CVM_SELF_VERSION) -- Claude (Code) Version Manager

USAGE
  cvm <command> [args]

COMMANDS
  install <version>     Install a Claude Code version
                        (version: semver, latest, stable)
  use <version>         Set the global (system-wide) active version
  local <version>       Set per-directory version (writes .claude-version)
  current               Show the currently resolved version
  which                 Print path to the active claude binary
  ls, list              List installed versions
  ls-remote [--all]     List versions available for download
  uninstall <version>   Remove an installed version
  self-update           Update CVM itself
  self-uninstall        Remove CVM and all installed versions
  env [--pwsh|--bash|--zsh|--fish]
                        Print the PATH setup line for your shell
  version               Show CVM version

VERSION RESOLUTION ORDER
  1. `$env:CVM_VERSION environment variable
  2. .claude-version file (walks up directory tree)
  3. ~\.cvm\version (global default, set by cvm use)

SHELL SETUP (PowerShell -- add to `$PROFILE)
  `$env:PATH = "`$env:USERPROFILE\.cvm\bin;`$env:PATH"

  Or run: cvm env --pwsh

EXAMPLES
  cvm install latest          Install latest available version
  cvm install 2.1.58          Install a specific version
  cvm use 2.1.71              Switch global version
  cvm local 2.1.58            Pin this directory to 2.1.58
  cvm ls-remote --all         Show all available versions
"@
}

# ── Main Dispatch ─────────────────────────────────────────────────────────────
switch ($Command.ToLower()) {
    "install"     { Invoke-Install  ($CmdArgs | Select-Object -First 1) }
    { $_ -in @("use","default") }    { Invoke-Use     ($CmdArgs | Select-Object -First 1) }
    "local"       { Invoke-Local    ($CmdArgs | Select-Object -First 1) }
    "current"     { Invoke-Current }
    "which"       { Invoke-Which }
    { $_ -in @("ls","list") }        { Invoke-List }
    { $_ -in @("ls-remote","list-remote") } {
        Invoke-ListRemote -All:($CmdArgs -contains "--all")
    }
    { $_ -in @("uninstall","remove") } { Invoke-Uninstall ($CmdArgs | Select-Object -First 1) }
    "self-update"    { Invoke-SelfUpdate }
    "self-uninstall" { Invoke-SelfUninstall }
    "env"            { Invoke-Env ($CmdArgs | Select-Object -First 1) }
    { $_ -in @("version","--version","-v") } { Write-Output "cvm $($script:CVM_SELF_VERSION)" }
    { $_ -in @("help","--help","-h") }       { Invoke-Help }
    default {
        Write-Err "Unknown command: $Command"
        Write-Output ""
        Invoke-Help
        exit 1
    }
}
