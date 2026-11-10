$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolPath = Join-Path $PSScriptRoot 'City6-Test-Controls.ps1'
if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
  throw 'City6 Test Controls script was not found.'
}

$desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
if ([string]::IsNullOrWhiteSpace($desktop) -or
    -not (Test-Path -LiteralPath $desktop -PathType Container)) {
  throw 'The current Windows desktop folder is unavailable.'
}

$shortcutPath = Join-Path $desktop 'City6 Test Controls.lnk'
$shell = New-Object -ComObject WScript.Shell
if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
  $existing = $shell.CreateShortcut($shortcutPath)
  $expectedTarget = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $expectedArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $toolPath + '"'
  if ($existing.TargetPath -eq $expectedTarget -and
      $existing.Arguments -eq $expectedArguments) {
    Write-Output "Shortcut already points to City6 Test Controls: $shortcutPath"
    return
  }
  throw 'A different desktop shortcut already uses the City6 Test Controls name.'
}
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $toolPath + '"'
$shortcut.WorkingDirectory = $projectRoot
$shortcut.IconLocation = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe,0'
$shortcut.Description = 'Reset penalties for the two allowlisted City6 test Drivers.'
$shortcut.Save()
Write-Output "Shortcut created: $shortcutPath"
