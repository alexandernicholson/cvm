#Requires -Modules Pester
# Real loopback HTTP transfers exercise the shipped downloader without installing a version.
BeforeAll {
    $cvm = Join-Path $PSScriptRoot '..\..\cvm.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($cvm, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw $parseErrors[0] }
    foreach ($name in @('Save-CvmFile', 'Test-Checksum', 'Write-Err')) {
        $function = $ast.Find({ param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }

    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;

public sealed class CvmDownloadFixture : IDisposable
{
    private readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource cancel = new CancellationTokenSource();
    private readonly List<Task> requests = new List<Task>();
    private readonly Task accepting;
    private readonly TaskCompletionSource<bool> barrier = new TaskCompletionSource<bool>();
    public readonly byte[] Payload = new byte[12 * 1024 * 1024];
    public readonly string Mode;
    public string Url;
    public int RangeRequests, FullRequests, Active, Peak;

    public CvmDownloadFixture(string mode)
    {
        Mode = mode;
        for (int i = 0; i < Payload.Length; i++) Payload[i] = (byte)(i % 251);
        listener.Start();
        Url = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/binary";
        accepting = Accept();
    }
    private async Task Accept()
    {
        try {
            while (!cancel.IsCancellationRequested) {
                var client = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
                lock (requests) requests.Add(Serve(client));
            }
        } catch (ObjectDisposedException) {} catch (SocketException) {}
    }
    private async Task Serve(TcpClient client)
    {
        bool active = false;
        using (client)
        using (cancel.Token.Register(client.Close)) {
            try {
                var stream = client.GetStream();
                var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true);
                string line = await reader.ReadLineAsync().ConfigureAwait(false);
                long start = -1, end = -1;
                while (!String.IsNullOrEmpty(line = await reader.ReadLineAsync().ConfigureAwait(false))) {
                    if (line.StartsWith("Range: bytes=", StringComparison.OrdinalIgnoreCase)) {
                        var bounds = line.Substring(13).Split('-');
                        start = Int64.Parse(bounds[0]); end = Int64.Parse(bounds[1]);
                    }
                }
                if (Mode == "stall") await Task.Delay(30000, cancel.Token).ConfigureAwait(false);
                bool ranged = start >= 0;
                bool probe = ranged && start == 0 && end == 0;
                if (ranged) Interlocked.Increment(ref RangeRequests);
                else Interlocked.Increment(ref FullRequests);
                if (ranged && !probe) {
                    active = true;
                    int current = Interlocked.Increment(ref Active);
                    int peak;
                    do { peak = Peak; if (peak >= current) break; }
                    while (Interlocked.CompareExchange(ref Peak, current, peak) != peak);
                    if (current == 3) barrier.TrySetResult(true);
                    await Task.WhenAny(barrier.Task, Task.Delay(2000, cancel.Token)).ConfigureAwait(false);
                }
                if (!ranged || Mode == "ignore" || (!probe && Mode == "ignore-chunks")) {
                    ranged = false; start = 0; end = Payload.Length - 1;
                }
                long length = end - start + 1;
                string tag = (!probe && ranged && Mode == "changed") ? "\"changed\"" : "\"original\"";
                string headers = "HTTP/1.1 " + (ranged ? "206 Partial Content" : "200 OK") + "\r\nConnection: close\r\nETag: " + tag + "\r\nContent-Length: " + length + "\r\n";
                if (ranged) headers += "Content-Range: bytes " + ((!probe && Mode == "wrong-range") ? start + 1 : start) + "-" + end + "/" + Payload.Length + "\r\n";
                byte[] head = Encoding.ASCII.GetBytes(headers + "\r\n");
                await stream.WriteAsync(head, 0, head.Length, cancel.Token).ConfigureAwait(false);
                if (Mode == "body-stall") await Task.Delay(30000, cancel.Token).ConfigureAwait(false);
                if (!probe && ranged && Mode == "truncated") length--;
                await stream.WriteAsync(Payload, (int)start, (int)length, cancel.Token).ConfigureAwait(false);
            } catch (IOException) {} catch (OperationCanceledException) {} catch (ObjectDisposedException) {}
            finally { if (active) Interlocked.Decrement(ref Active); }
        }
    }
    public void Dispose()
    {
        cancel.Cancel(); listener.Stop(); accepting.GetAwaiter().GetResult();
        Task[] pending; lock (requests) pending = requests.ToArray();
        Task.WhenAll(pending).GetAwaiter().GetResult(); cancel.Dispose();
    }
}
'@
}

Describe 'HTTP downloads' {
    BeforeEach {
        $savedThreads = $env:CVM_DOWNLOAD_THREADS
        $env:CVM_DOWNLOAD_THREADS = '3'
        $server = $null
        $dest = Join-Path $TestDrive 'download'
        $expected = Join-Path $TestDrive 'expected'
    }
    AfterEach {
        if ($null -ne $server) { $server.Dispose() }
        $env:CVM_DOWNLOAD_THREADS = $savedThreads
        Remove-Item $dest, $expected -Force -ErrorAction SilentlyContinue
    }

    It 'assembles concurrent ranges into the exact artifact and removes chunks' {
        $server = New-Object CvmDownloadFixture 'ranges'
        [IO.File]::WriteAllBytes($expected, $server.Payload)
        Save-CvmFile $server.Url $dest 15
        (Get-FileHash $dest).Hash | Should -Be (Get-FileHash $expected).Hash
        $server.Peak | Should -BeGreaterThan 1
        $server.Peak | Should -BeLessOrEqual 3
        $server.FullRequests | Should -Be 0
        @(Get-ChildItem "$dest.parts-*").Count | Should -Be 0
    }

    It 'forces a single full response when configured with one thread' {
        $server = New-Object CvmDownloadFixture 'ranges'
        $env:CVM_DOWNLOAD_THREADS = '1'
        [IO.File]::WriteAllBytes($expected, $server.Payload)
        Save-CvmFile $server.Url $dest 15
        (Get-FileHash $dest).Hash | Should -Be (Get-FileHash $expected).Hash
        $server.RangeRequests | Should -Be 0
        $server.FullRequests | Should -Be 1
    }

    It 'safely retries a full transfer for <Mode>' -TestCases @(
        @{ Mode = 'ignore' }, @{ Mode = 'ignore-chunks' }, @{ Mode = 'wrong-range' },
        @{ Mode = 'truncated' }, @{ Mode = 'changed' }
    ) {
        param($Mode)
        $server = New-Object CvmDownloadFixture $Mode
        [IO.File]::WriteAllBytes($expected, $server.Payload)
        Save-CvmFile $server.Url $dest 15
        (Get-FileHash $dest).Hash | Should -Be (Get-FileHash $expected).Hash
        $server.FullRequests | Should -Be 1
        @(Get-ChildItem "$dest.parts-*").Count | Should -Be 0
    }

    It 'cancels <Mode> within the overall deadline without partial output' -TestCases @(
        @{ Mode = 'stall' }, @{ Mode = 'body-stall' }
    ) {
        param($Mode)
        $server = New-Object CvmDownloadFixture $Mode
        $clock = [Diagnostics.Stopwatch]::StartNew()
        { Save-CvmFile $server.Url $dest 1 } | Should -Throw
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
        Test-Path $dest | Should -BeFalse
        @(Get-ChildItem "$dest.parts-*").Count | Should -Be 0
    }

    It 'rejects invalid worker counts before starting any transfer' -TestCases @(
        @{ Value = '0' }, @{ Value = '33' }, @{ Value = '1.5' },
        @{ Value = '-1' }, @{ Value = 'abc' }, @{ Value = '99999999999999999999' }
    ) {
        param($Value)
        $env:CVM_DOWNLOAD_THREADS = $Value
        { Save-CvmFile 'http://127.0.0.1:1/binary' $dest 1 } | Should -Throw '*CVM_DOWNLOAD_THREADS*'
        Test-Path $dest | Should -BeFalse
    }

    It 'refuses missing and invalid manifest checksums rather than skipping verification' {
        Test-Checksum $dest '' | Should -BeFalse
        Test-Checksum $dest 'not-a-sha256' | Should -BeFalse
    }

    It 'accepts only the matching SHA256 for the downloaded bytes' {
        [IO.File]::WriteAllText($dest, 'downloaded artifact')
        $digest = (Get-FileHash $dest -Algorithm SHA256).Hash
        Test-Checksum $dest $digest | Should -BeTrue
        [IO.File]::WriteAllText($dest, 'corrupted artifact')
        Test-Checksum $dest $digest | Should -BeFalse
    }
}
