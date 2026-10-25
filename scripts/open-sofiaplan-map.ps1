[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8765
)

$ErrorActionPreference = 'Stop'
$mapPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\data\geography\sofiaplan\districts_map.html'))
if (-not (Test-Path -LiteralPath $mapPath -PathType Leaf)) {
    throw "Map file was not found: $mapPath"
}

$mapBytes = [System.IO.File]::ReadAllBytes($mapPath)
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try {
    $listener.Start()
} catch {
    throw "Could not start the local map server on 127.0.0.1:$Port. Choose another port with -Port. $($_.Exception.Message)"
}

$url = "http://127.0.0.1:$Port/"
Write-Host "City6 SofiaPlan map: $url"
Write-Host 'The server listens only on this computer. Press Ctrl+C here to stop it.'

$edgeCandidates = [System.Collections.Generic.List[string]]::new()
$programFilesX86 = [System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
$programFiles = [System.Environment]::GetEnvironmentVariable('ProgramFiles')
$localAppData = [System.Environment]::GetEnvironmentVariable('LOCALAPPDATA')
if ($programFilesX86) { $edgeCandidates.Add((Join-Path $programFilesX86 'Microsoft\Edge\Application\msedge.exe')) }
if ($programFiles) { $edgeCandidates.Add((Join-Path $programFiles 'Microsoft\Edge\Application\msedge.exe')) }
if ($localAppData) { $edgeCandidates.Add((Join-Path $localAppData 'Microsoft\Edge\Application\msedge.exe')) }
$edgeCommand = Get-Command msedge.exe -ErrorAction SilentlyContinue
if ($edgeCommand) { $edgeCandidates.Add($edgeCommand.Source) }
$edgePath = $edgeCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

try {
    if ($edgePath) {
        Start-Process -FilePath $edgePath -ArgumentList $url | Out-Null
    } else {
        Start-Process -FilePath "microsoft-edge:$url" | Out-Null
    }
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $reader = $null
        try {
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
            $requestLine = $reader.ReadLine()
            if (-not $requestLine) { continue }
            while ($true) {
                $headerLine = $reader.ReadLine()
                if ([string]::IsNullOrEmpty($headerLine)) { break }
            }

            $requestParts = $requestLine.Split(' ', 3)
            $method = $requestParts[0]
            $requestPath = if ($requestParts.Count -gt 1) { ([System.Uri]::new("http://localhost$($requestParts[1])")).AbsolutePath } else { '' }
            $status = '404 Not Found'
            $contentType = 'text/plain; charset=utf-8'
            $body = [System.Text.Encoding]::UTF8.GetBytes('Not found')

            if ($requestPath -in @('/', '/districts_map.html') -and $method -in @('GET', 'HEAD')) {
                $status = '200 OK'
                $contentType = 'text/html; charset=utf-8'
                $body = $mapBytes
            } elseif ($requestPath -eq '/favicon.ico') {
                $status = '204 No Content'
                $body = [byte[]]::new(0)
            }

            $headers = "HTTP/1.1 $status`r`nContent-Type: $contentType`r`nContent-Length: $($body.Length)`r`nConnection: close`r`nX-Content-Type-Options: nosniff`r`n`r`n"
            $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            if ($method -ne 'HEAD' -and $body.Length -gt 0) {
                $stream.Write($body, 0, $body.Length)
            }
            $stream.Flush()
        } catch {
            Write-Warning "Local map request failed: $($_.Exception.GetType().Name)"
        } finally {
            if ($reader) { $reader.Dispose() }
            $client.Dispose()
        }
    }
} finally {
    $listener.Stop()
}
