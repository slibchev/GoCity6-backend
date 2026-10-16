
$ErrorActionPreference = "Stop"

$configPath = Join-Path $env:LOCALAPPDATA "City6\backend-secrets.xml"

if (-not (Test-Path $configPath)) {
    Write-Host "City6 configuration not found."
    exit 1
}

$secrets = Import-Clixml -Path $configPath

$env:CITY6_RIDE_STORAGE = "postgres"
$env:CITY6_DB_NAME = "city6"

$env:CITY6_DB_PASSWORD = (
    [System.Net.NetworkCredential]::new(
        "",
        $secrets.CITY6_DB_PASSWORD
    )
).Password

$env:CITY6_DRIVER_JWT_SECRET = (
    [System.Net.NetworkCredential]::new(
        "",
        $secrets.CITY6_DRIVER_JWT_SECRET
    )
).Password

Write-Host "Starting City6 Backend with PostgreSQL..."

dart run bin/server.dart
