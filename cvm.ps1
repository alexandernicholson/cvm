#!/usr/bin/env pwsh
# CVM - Claude (Code) Version Manager (Windows / PowerShell)
# https://github.com/alexandernicholson/cvm
#Requires -Version 5.1

# Parse arguments from $args so that dash-prefixed values like --version,
# --help, --pwsh are received as plain strings rather than being interpreted
# as named parameters by PowerShell's CmdletBinding binder.
$Command = if ($args.Count -gt 0) { $args[0] } else { "help" }
$CmdArgs = if ($args.Count -gt 1) { @($args[1..($args.Count - 1)]) } else { @() }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # suppress Invoke-WebRequest progress bars

# ── Constants ─────────────────────────────────────────────────────────────────
$script:CVM_SELF_VERSION = "0.2.3"
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
    $threads = 8
    if ($env:CVM_DOWNLOAD_THREADS) {
        if ($env:CVM_DOWNLOAD_THREADS -notmatch '^([1-9]|[12][0-9]|3[0-2])$' -or
            -not [int]::TryParse($env:CVM_DOWNLOAD_THREADS, [ref]$threads) -or
            $threads -lt 1 -or $threads -gt 32) {
            throw "CVM_DOWNLOAD_THREADS must be an integer from 1 to 32."
        }
    }
    if (-not ("CvmRangeDownloader" -as [type])) {
        Add-Type -AssemblyName System.Net.Http
        # C# 5 and .NET 4.5 APIs keep this single-file distribution usable on
        # Windows PowerShell 5.1 without jobs, runspaces, or child processes.
        $downloadSource = @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading;
using System.Threading.Tasks;

public static class CvmRangeDownloader
{
    private const long MinChunk = 4L * 1024 * 1024;

    private static HttpRequestMessage Request(string url, long start, long end, string identity)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("Accept-Encoding", "identity");
        if (start >= 0) {
            request.Headers.Range = new RangeHeaderValue(start, end);
            if (identity != null) request.Headers.TryAddWithoutValidation("If-Range", identity);
        }
        return request;
    }

    private static string Identity(HttpResponseMessage response)
    {
        if (response.Headers.ETag != null && !response.Headers.ETag.IsWeak)
            return response.Headers.ETag.ToString();
        if (response.Content.Headers.LastModified.HasValue)
            return response.Content.Headers.LastModified.Value.ToString("R");
        return null;
    }

    private static bool IsRange(HttpResponseMessage response, long start, long end, long total)
    {
        var range = response.Content.Headers.ContentRange;
        return response.StatusCode == HttpStatusCode.PartialContent &&
            range != null && range.Unit == "bytes" && range.From == start &&
            range.To == end && range.Length == total &&
            response.Content.Headers.ContentLength == end - start + 1 &&
            response.Content.Headers.ContentEncoding.Count == 0;
    }

    private static async Task Copy(Stream input, Stream output, long expected, CancellationToken token)
    {
        // Framework network streams may ignore cancellation of a pending read.
        // Closing the response stream also interrupts those reads at the deadline.
        using (token.Register(input.Dispose)) {
            var buffer = new byte[81920];
            long copied = 0;
            int count;
            while ((count = await input.ReadAsync(buffer, 0, buffer.Length, token).ConfigureAwait(false)) != 0) {
                copied += count;
                if (expected >= 0 && copied > expected) throw new IOException("Unexpected download length.");
                await output.WriteAsync(buffer, 0, count, token).ConfigureAwait(false);
            }
            if (expected >= 0 && copied != expected) throw new IOException("Incomplete download.");
        }
    }

    private static async Task Range(HttpClient client, string url, string path, long start,
        long end, long total, string identity, CancellationTokenSource group)
    {
        try {
            using (var request = Request(url, start, end, identity))
            using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, group.Token).ConfigureAwait(false)) {
                if (!IsRange(response, start, end, total) || Identity(response) != identity ||
                    response.RequestMessage.RequestUri.AbsoluteUri != url)
                    throw new IOException("Server changed or refused a byte range.");
                using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true))
                    await Copy(input, output, end - start + 1, group.Token).ConfigureAwait(false);
            }
        } catch {
            group.Cancel();
            throw;
        }
    }

    private static async Task<bool> Parallel(HttpClient client, string url, string dest, int threads, CancellationToken token)
    {
        long total;
        string identity;
        using (var request = Request(url, 0, 0, null))
        using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false)) {
            var range = response.Content.Headers.ContentRange;
            if (range == null || !range.Length.HasValue) return false;
            total = range.Length.Value;
            identity = Identity(response);
            if (!IsRange(response, 0, 0, total) || identity == null) return false;
            threads = (int)Math.Min(threads, total / MinChunk);
            if (threads < 2) return false;
            using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                await Copy(input, Stream.Null, 1, token).ConfigureAwait(false);
            url = response.RequestMessage.RequestUri.AbsoluteUri;
        }
        string chunks = dest + ".parts-" + Guid.NewGuid().ToString("N");
        Directory.CreateDirectory(chunks);
        try {
            using (var group = CancellationTokenSource.CreateLinkedTokenSource(token)) {
                var tasks = new Task[threads];
                long chunkSize = total / threads;
                for (int i = 0; i < threads; i++) {
                    long start = i * chunkSize;
                    long end = i == threads - 1 ? total - 1 : start + chunkSize - 1;
                    tasks[i] = Range(client, url, Path.Combine(chunks, i.ToString()),
                        start, end, total, identity, group);
                }
                await Task.WhenAll(tasks).ConfigureAwait(false);
            }
            using (var output = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None, 81920, true)) {
                for (int i = 0; i < threads; i++) {
                    using (var input = new FileStream(Path.Combine(chunks, i.ToString()), FileMode.Open, FileAccess.Read, FileShare.Read, 81920, true))
                        await Copy(input, output, input.Length, token).ConfigureAwait(false);
                }
            }
            return true;
        } finally {
            Directory.Delete(chunks, true);
        }
    }

    public static async Task Download(string url, string dest, int threads, CancellationToken token)
    {
#if CVM_FRAMEWORK
        // Framework HttpClient otherwise limits each origin to two connections.
        int previousLimit = ServicePointManager.DefaultConnectionLimit;
        ServicePointManager.DefaultConnectionLimit = Math.Max(previousLimit, threads);
        var origin = ServicePointManager.FindServicePoint(new Uri(url));
        int previousOriginLimit = origin.ConnectionLimit;
        origin.ConnectionLimit = Math.Max(previousOriginLimit, threads);
#endif
        try {
            using (var handler = new HttpClientHandler { AutomaticDecompression = DecompressionMethods.None })
            using (var client = new HttpClient(handler)) {
#if !CVM_FRAMEWORK
                handler.MaxConnectionsPerServer = threads;
#endif
                client.Timeout = Timeout.InfiniteTimeSpan;
                if (threads > 1) {
                    try {
                        if (await Parallel(client, url, dest, threads, token).ConfigureAwait(false)) return;
                    } catch {
                        token.ThrowIfCancellationRequested();
                        // Retry as one response, never concatenate invalid or changed ranges.
                    }
                }
                token.ThrowIfCancellationRequested();
                using (var request = Request(url, -1, -1, null))
                using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false)) {
                    if (response.StatusCode != HttpStatusCode.OK || response.Content.Headers.ContentEncoding.Count != 0)
                        throw new IOException("Download request failed.");
                    using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                    using (var output = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None, 81920, true))
                        await Copy(input, output, response.Content.Headers.ContentLength ?? -1, token).ConfigureAwait(false);
                }
            }
        } catch {
            if (File.Exists(dest)) File.Delete(dest);
            throw;
        } finally {
#if CVM_FRAMEWORK
            ServicePointManager.DefaultConnectionLimit = previousLimit;
            origin.ConnectionLimit = previousOriginLimit;
            #endif
        }
    }
}
'@
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            $downloadSource = "#define CVM_FRAMEWORK`n" + $downloadSource
            Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition $downloadSource
        } else {
            Add-Type -TypeDefinition $downloadSource
        }
    }
    $cancel = New-Object System.Threading.CancellationTokenSource
    $transfer = $null
    try {
        $cancel.CancelAfter([TimeSpan]::FromSeconds($timeout))
        $transfer = [CvmRangeDownloader]::Download($url, $dest, $threads, $cancel.Token)
        # Short waits let PowerShell service Ctrl-C; finally cancels and drains
        # all streams before the install caller can remove its temporary file.
        while (-not $transfer.IsCompleted) { Start-Sleep -Milliseconds 50 }
        [void]$transfer.GetAwaiter().GetResult()
    } finally {
        $cancel.Cancel()
        if ($null -ne $transfer) {
            try { [void]$transfer.GetAwaiter().GetResult() } catch {}
        }
        $cancel.Dispose()
    }
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
    if ($expected -notmatch '^[a-fA-F0-9]{64}$') {
        Write-Err "Missing or invalid SHA256 checksum in manifest"
        return $false
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
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) { break }
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
