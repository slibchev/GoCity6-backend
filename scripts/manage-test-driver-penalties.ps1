param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ToolArguments
)

$ErrorActionPreference = 'Stop'
$settingsPath = Join-Path $env:LOCALAPPDATA 'City6\backend-secrets.xml'
$dartPath = 'C:\dev\flutter\bin\cache\dart-sdk\bin\dart.exe'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
  throw 'Protected City6 settings file is missing.'
}
if (-not (Test-Path -LiteralPath $dartPath -PathType Leaf)) {
  throw 'Dart SDK was not found.'
}
$settings = Import-Clixml -LiteralPath $settingsPath
$passwordValue = $settings.CITY6_DB_PASSWORD
if ($passwordValue -is [System.Security.SecureString]) {
  $env:CITY6_DB_PASSWORD = [System.Net.NetworkCredential]::new('', $passwordValue).Password
} else {
  $env:CITY6_DB_PASSWORD = [string]$passwordValue
}
try {
  & $dartPath run bin/manage_test_driver_penalties.dart @ToolArguments
  exit $LASTEXITCODE
} finally {
  Remove-Item Env:CITY6_DB_PASSWORD -ErrorAction SilentlyContinue
  $passwordValue = $null
  $settings = $null
}
