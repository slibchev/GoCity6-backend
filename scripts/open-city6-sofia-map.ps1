[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8766
)

$ErrorActionPreference = 'Stop'
$serverScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'open-sofiaplan-map.ps1'))
if (-not (Test-Path -LiteralPath $serverScript -PathType Leaf)) {
    throw "Shared local map server was not found: $serverScript"
}

& $serverScript -Port $Port -City6SofiaMap
