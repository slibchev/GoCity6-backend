[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [switch]$ProvisionFresh,

    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$InstanceName = 'city6_test_5433'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Security -ErrorAction Stop

$testPort = 5433
$testDatabase = 'city6_test'
$testRunner = 'city6_test_runner'
$testAdmin = 'city6_test_admin'
$projectRoot = Split-Path -Parent $PSScriptRoot
$migrationDirectory = Join-Path $projectRoot 'migrations'
$pgBin = Join-Path $env:ProgramFiles 'PostgreSQL\18\bin'
$initdb = Join-Path $pgBin 'initdb.exe'
$pgCtl = Join-Path $pgBin 'pg_ctl.exe'
$psql = Join-Path $pgBin 'psql.exe'
$pgDump = Join-Path $pgBin 'pg_dump.exe'
$pgRestore = Join-Path $pgBin 'pg_restore.exe'
$localCity6 = Join-Path $env:LOCALAPPDATA 'City6'
$secretDirectory = Join-Path $localCity6 'secrets'
$backupDirectory = Join-Path $localCity6 'backups'
$runnerSecretPath = Join-Path $secretDirectory 'city6_test_runner.secret'
$adminSecretPath = Join-Path $secretDirectory 'city6_test_admin.secret'
$instanceRoot = Join-Path (Join-Path $localCity6 'postgresql') $InstanceName
$dataDirectory = Join-Path $instanceRoot 'data'
$logPath = Join-Path $instanceRoot 'postgres-5433.log'

function Assert-PrivateFileAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $acl = Get-Acl -LiteralPath $Path
    foreach ($rule in $acl.Access) {
        $sid = $rule.IdentityReference.Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
        if ($sid -notin @($ownerSid, 'S-1-5-18')) {
            throw "Credential path has an unexpected ACL principal: $Path"
        }
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            throw "Credential path has an unexpected deny ACL: $Path"
        }
    }
}

function New-PrivateDirectorySecurity {
    $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($ownerSid)
    foreach ($sid in @($ownerSid, $systemSid)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule)
    }
    return $security
}

function Read-SecretFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required protected credential file is missing: $Path"
    }
    Assert-PrivateFileAcl -Path $Path
    $value = [IO.File]::ReadAllText($Path).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required protected credential file is empty: $Path"
    }
    return $value
}

function Get-ListeningPidsForPort {
    param([Parameter(Mandatory = $true)][int]$Port)

    $pattern = ":$Port\s+\S+\s+LISTENING\s+(\d+)\s*$"
    $pids = @()
    foreach ($line in (& "$env:SystemRoot\System32\netstat.exe" -ano -p tcp)) {
        if ($line -match $pattern) {
            $pids += [int]$Matches[1]
        }
    }
    return $pids | Sort-Object -Unique
}

function Invoke-TestPsqlQuery {
    param(
        [Parameter(Mandatory = $true)][string]$Database,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Sql,
        [switch]$HideDetailsOnFailure
    )

    $env:PGPASSWORD = $Password
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $psql -X --no-password --set=ON_ERROR_STOP=1 --tuples-only --no-align `
            --host=127.0.0.1 --port=$testPort --username=$Username `
            --dbname=$Database --command=$Sql 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            if ($HideDetailsOnFailure) {
                throw 'PostgreSQL bootstrap failed; output was withheld because it may contain credential-bearing SQL.'
            }
            throw "psql failed against the explicitly restricted test endpoint 127.0.0.1:$testPort/$Database."
        }
        return @($output | ForEach-Object { [string]$_ })
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }
}

if (-not $ProvisionFresh) {
    throw 'Pass -ProvisionFresh to create a new isolated test cluster. Existing data directories are never reused or deleted.'
}
if ($testPort -ne 5433 -or $testDatabase -ne 'city6_test') {
    throw 'Safety invariant failed: test provisioning is fixed to city6_test on port 5433.'
}
if (-not (Test-Path -LiteralPath $initdb -PathType Leaf) -or
    -not (Test-Path -LiteralPath $pgCtl -PathType Leaf) -or
    -not (Test-Path -LiteralPath $psql -PathType Leaf) -or
    -not (Test-Path -LiteralPath $pgDump -PathType Leaf) -or
    -not (Test-Path -LiteralPath $pgRestore -PathType Leaf)) {
    throw 'PostgreSQL 18 command-line tools are not all available.'
}
if (-not (Test-Path -LiteralPath $secretDirectory -PathType Container) -or
    -not (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
    throw 'The protected City6 secret and backup directories must exist.'
}
$backupDirectoryAcl = Get-Acl -LiteralPath $backupDirectory
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
foreach ($rule in $backupDirectoryAcl.Access) {
    $sid = $rule.IdentityReference.Translate(
        [Security.Principal.SecurityIdentifier]
    ).Value
    if ($sid -notin @($ownerSid, 'S-1-5-18') -or
        $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
        throw 'The backup directory ACL is not restricted to the current user and SYSTEM.'
    }
}
if (Test-Path -LiteralPath $instanceRoot) {
    throw "Refusing to overwrite an existing cluster path: $instanceRoot"
}
$existingListenerPids = @(Get-ListeningPidsForPort -Port $testPort)
if ($existingListenerPids.Count -gt 0) {
    throw "Port $testPort already has a listener; no cluster will be created or stopped."
}
$volumeRoot = [IO.Path]::GetPathRoot($instanceRoot)
$volume = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($volumeRoot.TrimEnd('\'))'"
if ($null -eq $volume -or $volume.FreeSpace -lt 1GB) {
    throw 'The target volume is unavailable or has less than 1 GiB free.'
}

$runnerPassword = Read-SecretFile -Path $runnerSecretPath
if (Test-Path -LiteralPath $adminSecretPath -PathType Leaf) {
    $adminPassword = Read-SecretFile -Path $adminSecretPath
}
else {
    $randomBytes = New-Object byte[] 48
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($randomBytes)
        $adminPassword = [Convert]::ToBase64String($randomBytes)
    }
    finally {
        $rng.Dispose()
        [Array]::Clear($randomBytes, 0, $randomBytes.Length)
    }
    [IO.File]::WriteAllText(
        $adminSecretPath,
        $adminPassword + [Environment]::NewLine,
        [Text.Encoding]::ASCII
    )
    Set-Acl -LiteralPath $adminSecretPath -AclObject (Get-Acl -LiteralPath $runnerSecretPath)
    Assert-PrivateFileAcl -Path $adminSecretPath
}

$migrationFiles = @(Get-ChildItem -LiteralPath $migrationDirectory -Filter '*.sql' -File | Sort-Object Name)
if ($migrationFiles.Count -ne 25) {
    throw "Expected exactly migrations 001-025; found $($migrationFiles.Count)."
}
for ($index = 0; $index -lt 25; $index++) {
    $expectedPrefix = '{0:D3}_' -f ($index + 1)
    if (-not $migrationFiles[$index].Name.StartsWith($expectedPrefix)) {
        throw "Migration sequence is incomplete or out of order at $expectedPrefix"
    }
}
foreach ($migration in $migrationFiles) {
    $contents = [IO.File]::ReadAllText($migration.FullName)
    if ($contents -match '(?im)\b(CREATE\s+INDEX\s+CONCURRENTLY|VACUUM|CREATE\s+DATABASE|ALTER\s+SYSTEM)\b') {
        throw "Migration is incompatible with the single-transaction batch: $($migration.Name)"
    }
}
Write-Output 'Preflight checks: PASS'

$directorySecurity = New-PrivateDirectorySecurity
[void][IO.Directory]::CreateDirectory($instanceRoot)
Set-Acl -LiteralPath $instanceRoot -AclObject $directorySecurity
$initArgs = @(
    '--pgdata', $dataDirectory,
    '--username', $testAdmin,
    '--pwfile', $adminSecretPath,
    '--auth-host=scram-sha-256',
    '--auth-local=scram-sha-256',
    '--locale=C',
    '--encoding=UTF8'
)
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $initOutput = & $initdb @initArgs 2>&1
    $initExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($initExitCode -ne 0) {
    throw "initdb failed with exit code $initExitCode; the new directory was retained for inspection."
}
Write-Output 'initdb: PASS'

$configuration = @(
    "listen_addresses = '127.0.0.1'",
    "port = $testPort",
    "password_encryption = 'scram-sha-256'"
)
Add-Content -LiteralPath (Join-Path $dataDirectory 'postgresql.conf') -Value $configuration -Encoding ASCII
$hba = @(
    'local all all scram-sha-256',
    "host $testDatabase $testRunner 127.0.0.1/32 scram-sha-256",
    "host $testDatabase $testRunner ::1/128 scram-sha-256",
    "host all $testAdmin 127.0.0.1/32 scram-sha-256",
    "host all $testAdmin ::1/128 scram-sha-256",
    'host all all 127.0.0.1/32 reject',
    'host all all ::1/128 reject'
)
[IO.File]::WriteAllLines((Join-Path $dataDirectory 'pg_hba.conf'), $hba, [Text.Encoding]::ASCII)

$pgCtlStdout = Join-Path $instanceRoot 'pgctl-start.stdout.log'
$pgCtlStderr = Join-Path $instanceRoot 'pgctl-start.stderr.log'
$pgCtlArguments = @(
    'start', '-D', $dataDirectory, '-l', $logPath,
    '-o', "`"-h 127.0.0.1 -p $testPort`"", '-w', '-t', '60'
)
$pgCtlProcess = Start-Process -FilePath $pgCtl -ArgumentList $pgCtlArguments `
    -WindowStyle Hidden -RedirectStandardOutput $pgCtlStdout `
    -RedirectStandardError $pgCtlStderr -PassThru
Wait-Process -Id $pgCtlProcess.Id -Timeout 60
$pgCtlProcess.Refresh()
if (-not $pgCtlProcess.HasExited) {
    throw 'pg_ctl start did not exit within 60 seconds; the isolated directory was retained.'
}
$startExitCode = $pgCtlProcess.ExitCode
if ($startExitCode -ne 0) {
    throw "pg_ctl start failed with exit code $startExitCode; the new directory was retained for inspection."
}
Write-Output 'pg_ctl start: PASS'
$listenerDeadline = [DateTime]::UtcNow.AddSeconds(30)
$listenerPids = @()
do {
    $listenerPids = @(Get-ListeningPidsForPort -Port $testPort)
    if ($listenerPids.Count -gt 1) {
        throw "More than one process is listening on port $testPort."
    }
    if ($listenerPids.Count -eq 1) {
        break
    }
    Start-Sleep -Milliseconds 250
} while ([DateTime]::UtcNow -lt $listenerDeadline)
if ($listenerPids.Count -ne 1) {
    throw "Expected exactly one listener on port $testPort; the new cluster remains available for inspection."
}
$netstatRows = @(& "$env:SystemRoot\System32\netstat.exe" -ano -p tcp)
$portRows = @($netstatRows | Where-Object {
    $_ -match "^\s*TCP\s+\S+:$testPort\s+\S+\s+LISTENING\s+\d+\s*$"
})
$loopbackPattern = "^\s*TCP\s+127\.0\.0\.1:$testPort\s+\S+\s+LISTENING\s+(\d+)\s*$"
if ($portRows.Count -ne 1) {
    throw 'The new test listener is not a single 127.0.0.1 socket owned by its PostgreSQL postmaster.'
}
$loopbackMatch = [regex]::Match($portRows[0], $loopbackPattern)
if (-not $loopbackMatch.Success) {
    throw 'The new test listener is not bound exclusively to 127.0.0.1.'
}
$socketPid = [int]$loopbackMatch.Groups[1].Value
$postmasterPid = [IO.File]::ReadAllLines((Join-Path $dataDirectory 'postmaster.pid'))[0]
if ($listenerPids[0].ToString() -ne $postmasterPid -or
    $socketPid.ToString() -ne $postmasterPid) {
    throw 'The new listener PID does not match the test cluster postmaster.pid.'
}
Write-Output 'Single loopback listener and postmaster PID: PASS'

$bootstrapPath = Join-Path $secretDirectory ('city6_test_bootstrap_' + [guid]::NewGuid().ToString('N') + '.sql')
$escapedRunnerPassword = $runnerPassword.Replace("'", "''")
$bootstrapSql = @"
CREATE ROLE $testRunner LOGIN PASSWORD '$escapedRunnerPassword' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE DATABASE $testDatabase OWNER $testRunner TEMPLATE template0 ENCODING 'UTF8';
"@
try {
    [IO.File]::WriteAllText($bootstrapPath, $bootstrapSql, [Text.Encoding]::UTF8)
    Set-Acl -LiteralPath $bootstrapPath -AclObject (Get-Acl -LiteralPath $runnerSecretPath)
    $env:PGPASSWORD = $adminPassword
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $bootstrapOutput = & $psql -X --no-password --set=ON_ERROR_STOP=1 --host=127.0.0.1 `
        --port=$testPort --username=$testAdmin --dbname=postgres `
        --file=$bootstrapPath 2>&1
    $bootstrapExit = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    if ($bootstrapExit -ne 0) {
        throw 'Role/database bootstrap failed; diagnostic output was withheld because it may contain credential-bearing SQL.'
    }
    Write-Output 'Test role/database bootstrap: PASS'
}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $bootstrapPath) {
        Remove-Item -LiteralPath $bootstrapPath -Force
    }
    $escapedRunnerPassword = $null
    $bootstrapSql = $null
}

$identitySql = "SELECT current_database() || '|' || current_user || '|' || inet_server_addr() || '|' || inet_server_port()"
$identity = @(Invoke-TestPsqlQuery -Database $testDatabase -Username $testRunner -Password $runnerPassword -Sql $identitySql)
if ($identity.Count -ne 1 -or $identity[0] -ne 'city6_test|city6_test_runner|127.0.0.1/32|5433') {
    throw 'Database identity verification failed; migrations were not applied.'
}

$migrationArgs = @(
    '-X', '--no-password', '--set=ON_ERROR_STOP=1', '--single-transaction',
    '--host=127.0.0.1', "--port=$testPort", "--username=$testRunner",
    "--dbname=$testDatabase"
)
foreach ($migration in $migrationFiles) {
    $migrationArgs += @('--file', $migration.FullName)
}
$env:PGPASSWORD = $runnerPassword
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $migrationOutput = & $psql @migrationArgs 2>&1
    $migrationExitCode = $LASTEXITCODE
    if ($migrationExitCode -ne 0) {
        throw 'The ordered 001-025 migration transaction failed; PostgreSQL rolled it back.'
    }
Write-Output 'Migrations 001-025 transaction: PASS'
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}

$catalogSql = @'
SELECT 'publication|' || count(*) FROM pg_catalog.pg_publication
UNION ALL SELECT 'db_role_setting|' || count(*) FROM pg_catalog.pg_db_role_setting
UNION ALL SELECT 'tablespace|' || count(*) FROM pg_catalog.pg_tablespace
UNION ALL SELECT 'statistic|' || count(*) FROM pg_catalog.pg_statistic
'@
$catalogHealth = @(Invoke-TestPsqlQuery -Database 'postgres' -Username $testAdmin -Password $adminPassword -Sql $catalogSql)
if ($catalogHealth.Count -ne 4) {
    throw 'System catalog health query did not return all four expected rows.'
}

$signatureSql = @'
SELECT 'column:' || table_name || '.' || column_name
FROM information_schema.columns
WHERE table_schema='public' AND (
    (table_name='rides' AND column_name IN ('pickup_display_address','destination_latitude','destination_longitude','manual_acceptance_shift_id')) OR
    (table_name='ride_offers' AND column_name IN ('dispatch_district_object_id','dispatch_district_entered_at','eta_seconds','distance_meters')) OR
    (table_name='driver_queue_states' AND column_name IN ('gps_fix_at','pending_break_request_id','active_break_request_id','has_customer_cancellation_priority','pending_district_last_seen_at')) OR
    (table_name='driver_offer_action_outbox' AND column_name IN ('ride_id','action','redispatch_status')) OR
    (table_name='passengers' AND column_name IN ('phone_e164','phone_verified_at'))
)
UNION ALL SELECT 'table:driver_break_requests' WHERE to_regclass('public.driver_break_requests') IS NOT NULL
UNION ALL SELECT 'table:passenger_phone_restrictions' WHERE to_regclass('public.passenger_phone_restrictions') IS NOT NULL
UNION ALL SELECT 'table:passenger_phone_restriction_audit' WHERE to_regclass('public.passenger_phone_restriction_audit') IS NOT NULL
UNION ALL SELECT 'table:passenger_phone_identity_audit' WHERE to_regclass('public.passenger_phone_identity_audit') IS NOT NULL
UNION ALL SELECT 'constraint:' || conname FROM pg_constraint WHERE conname IN (
    'driver_queue_states_pending_district_check',
    'driver_queue_states_pending_break_check',
    'ride_offers_route_metrics_pair_check',
    'ride_offers_dispatch_district_pair_check',
    'rides_manual_acceptance_queue_snapshot_check',
    'rides_destination_coordinates_pair_and_range_check'
)
UNION ALL SELECT 'index:' || c.relname
FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
WHERE c.relname IN (
    'driver_offer_action_outbox_initial_ride_unique_idx',
    'driver_offer_action_outbox_offer_id_unique_idx',
    'driver_offer_action_outbox_ready_idx',
    'passengers_phone_e164_unique_idx'
)
'@
$signatures = @(Invoke-TestPsqlQuery -Database $testDatabase -Username $testRunner -Password $runnerPassword -Sql $signatureSql)
$expectedSignatures = @(
    'column:rides.pickup_display_address',
    'column:rides.destination_latitude',
    'column:rides.destination_longitude',
    'column:rides.manual_acceptance_shift_id',
    'column:ride_offers.dispatch_district_object_id',
    'column:ride_offers.dispatch_district_entered_at',
    'column:driver_queue_states.gps_fix_at',
    'column:driver_queue_states.pending_break_request_id',
    'column:driver_queue_states.active_break_request_id',
    'column:driver_queue_states.has_customer_cancellation_priority',
    'column:driver_queue_states.pending_district_last_seen_at',
    'column:driver_offer_action_outbox.ride_id',
    'column:driver_offer_action_outbox.action',
    'column:driver_offer_action_outbox.redispatch_status',
    'column:passengers.phone_e164',
    'column:passengers.phone_verified_at',
    'table:driver_break_requests',
    'table:passenger_phone_restrictions',
    'table:passenger_phone_restriction_audit',
    'table:passenger_phone_identity_audit',
    'constraint:driver_queue_states_pending_district_check',
    'constraint:driver_queue_states_pending_break_check',
    'constraint:ride_offers_route_metrics_pair_check',
    'constraint:ride_offers_dispatch_district_pair_check',
    'constraint:rides_manual_acceptance_queue_snapshot_check',
    'constraint:rides_destination_coordinates_pair_and_range_check',
    'index:driver_offer_action_outbox_initial_ride_unique_idx',
    'index:driver_offer_action_outbox_offer_id_unique_idx',
    'index:driver_offer_action_outbox_ready_idx',
    'index:passengers_phone_e164_unique_idx'
)
$missingSignatures = @($expectedSignatures | Where-Object { $_ -notin $signatures })
if ($missingSignatures.Count -gt 0) {
    throw ('Schema signature check failed: ' + ($missingSignatures -join ', '))
}
Write-Output 'System catalogs and schema signatures: PASS'

$dumpName = 'city6_test_clean_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.dump'
$dumpPath = Join-Path $backupDirectory $dumpName
if (Test-Path -LiteralPath $dumpPath) {
    throw 'The clean-test backup destination already exists; refusing to overwrite.'
}
$env:PGPASSWORD = $runnerPassword
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    & $pgDump --format=custom --host=127.0.0.1 --port=$testPort `
        --username=$testRunner --dbname=$testDatabase --file=$dumpPath
    $dumpExitCode = $LASTEXITCODE
    if ($dumpExitCode -ne 0 -or -not (Test-Path -LiteralPath $dumpPath) -or
        (Get-Item -LiteralPath $dumpPath).Length -le 0) {
        throw 'pg_dump failed or produced an empty clean-test archive.'
    }
    Set-Acl -LiteralPath $dumpPath -AclObject (Get-Acl -LiteralPath $runnerSecretPath)
    Assert-PrivateFileAcl -Path $dumpPath
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $toc = & $pgRestore --list $dumpPath 2>&1
    $restoreListExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($restoreListExitCode -ne 0) {
    throw 'pg_restore --list could not read the clean-test archive.'
}
$tocItems = @($toc | Where-Object { $_ -match '^\s*\d+;' }).Count
if ($tocItems -lt 25) {
    throw 'The clean-test archive contains fewer TOC entries than expected.'
}
$dumpHash = (Get-FileHash -LiteralPath $dumpPath -Algorithm SHA256).Hash
Write-Output 'Clean test backup: PASS'

Write-Output "Test cluster ready: $instanceRoot"
Write-Output "Database identity: $($identity[0])"
Write-Output "System catalog checks: $($catalogHealth -join ', ')"
Write-Output "Migration schema signatures: PASS ($($signatures.Count) signatures)"
Write-Output "Clean schema archive: $dumpPath"
Write-Output "Archive bytes: $((Get-Item -LiteralPath $dumpPath).Length)"
Write-Output "pg_restore --list: PASS ($tocItems entries)"
Write-Output "Archive SHA-256: $dumpHash"
Write-Output "Admin credential is protected at: $adminSecretPath"
