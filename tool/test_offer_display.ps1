
param(
    [Parameter(Mandatory = $true)]
    [string]$Token
)

$ErrorActionPreference = "Stop"
$psql = "C:\Program Files\PostgreSQL\18\bin\psql.exe"
$database = "city6_test"

$rideId = [guid]::NewGuid().ToString()
$offerId = [guid]::NewGuid().ToString()

# Database safety check.
$dbName = & $psql -X -t -A -U city6_app -d $database -c "SELECT current_database();"

if ($LASTEXITCODE -ne 0 -or $dbName.Trim() -ne "city6_test") {
    throw "Database safety check failed."
}

# Create the offer with a 15-second lifetime.
$sql = @"
BEGIN;

INSERT INTO rides (
    id, pickup, destination,
    passengers, requested_at, status
)
VALUES (
    '$rideId', 'Test pickup', 'Test destination',
    2, NOW(), 'pending'
);

INSERT INTO ride_offers (
    id, ride_id, driver_id, vehicle_id,
    eta_seconds, distance_meters,
    offered_at, expires_at,
    status, dispatch_round, bonus_minor
)
VALUES (
    '$offerId', '$rideId',
    'driver-display-test-001',
    'vehicle-display-test-001',
    120, 1000,
    NOW(), NOW() + INTERVAL '15 seconds',
    'pending', 1, 0
);

COMMIT;
"@

$sql | & $psql -X -v ON_ERROR_STOP=1 -U city6_app -d $database

if ($LASTEXITCODE -ne 0) {
    Write-Host "PostgreSQL failed. Checking test records..."

    & $psql -X -U city6_app -d $database -c "SELECT id, status FROM ride_offers WHERE id = '$offerId';"

    throw "Test offer creation failed. See PostgreSQL error above."
}

$uri = "http://localhost:8081/driver/offers/$offerId/displayed"
$headers = @{ Authorization = "Bearer $Token" }

try {
    $first = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers
    $second = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers

    Write-Host "First ACK:" $first.acknowledged
    Write-Host "Duplicate ACK:" $second.acknowledged
    Write-Host "Timestamp preserved:" ($first.displayedAt -eq $second.displayedAt)

    & $psql -X -U city6_app -d $database -c "SELECT id, displayed_at FROM ride_offers WHERE id = '$offerId';"
}
catch {
    Write-Host "HTTP test failed."
    Write-Host $_.Exception.Message
    Write-Host $_.ErrorDetails.Message
}
finally {
    # Delete only the records created by this run.
    & $psql -X -v ON_ERROR_STOP=1 -U city6_app -d $database -c "DELETE FROM ride_offers WHERE id = '$offerId';"
    & $psql -X -v ON_ERROR_STOP=1 -U city6_app -d $database -c "DELETE FROM rides WHERE id = '$rideId';"
}
