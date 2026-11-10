$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$projectRoot = Split-Path -Parent $PSScriptRoot
$penaltyTool = Join-Path $PSScriptRoot 'manage-test-driver-penalties.ps1'
$window = New-Object System.Windows.Forms.Form
$window.Text = 'City6 Test Controls'
$window.StartPosition = 'CenterScreen'
$window.ClientSize = New-Object System.Drawing.Size(440, 330)
$window.MinimumSize = New-Object System.Drawing.Size(456, 369)
$window.MaximizeBox = $false

$heading = New-Object System.Windows.Forms.Label
$heading.Text = 'CITY6 TEST CONTROLS'
$heading.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$heading.Location = New-Object System.Drawing.Point(20, 18)
$heading.Size = New-Object System.Drawing.Size(390, 32)
$window.Controls.Add($heading)

$target = New-Object System.Windows.Forms.Label
$target.Text = 'LOCAL DATABASE  city6  ·  localhost:5432'
$target.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$target.Location = New-Object System.Drawing.Point(22, 60)
$target.Size = New-Object System.Drawing.Size(390, 24)
$window.Controls.Add($target)

$accounts = New-Object System.Windows.Forms.Label
$accounts.Text = "Driver 1  ·  driver-e2e-001`r`nDriver 2  ·  driver-city6-test-2-48966f02-c34b-4c4c-9ca3-f0411d5ea457"
$accounts.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$accounts.Location = New-Object System.Drawing.Point(22, 91)
$accounts.Size = New-Object System.Drawing.Size(400, 46)
$window.Controls.Add($accounts)

$resetButton = New-Object System.Windows.Forms.Button
$resetButton.Text = 'RESET'
$resetButton.Font = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
$resetButton.BackColor = [System.Drawing.Color]::FromArgb(177, 36, 36)
$resetButton.ForeColor = [System.Drawing.Color]::White
$resetButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$resetButton.Location = New-Object System.Drawing.Point(22, 147)
$resetButton.Size = New-Object System.Drawing.Size(390, 82)
$window.Controls.Add($resetButton)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Ready'
$status.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$status.Location = New-Object System.Drawing.Point(22, 238)
$status.Size = New-Object System.Drawing.Size(390, 26)
$window.Controls.Add($status)

$details = New-Object System.Windows.Forms.TextBox
$details.Multiline = $true
$details.ReadOnly = $true
$details.ScrollBars = 'Vertical'
$details.Font = New-Object System.Drawing.Font('Consolas', 8)
$details.Location = New-Object System.Drawing.Point(22, 267)
$details.Size = New-Object System.Drawing.Size(390, 42)
$window.Controls.Add($details)

$script:resetProcess = $null
$script:stdoutPath = $null
$script:stderrPath = $null
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
  if ($null -eq $script:resetProcess -or -not $script:resetProcess.HasExited) {
    return
  }
  $timer.Stop()
  $stdout = if (Test-Path -LiteralPath $script:stdoutPath) {
    Get-Content -LiteralPath $script:stdoutPath -Raw -ErrorAction SilentlyContinue
  } else { '' }
  $stderr = if (Test-Path -LiteralPath $script:stderrPath) {
    Get-Content -LiteralPath $script:stderrPath -Raw -ErrorAction SilentlyContinue
  } else { '' }
  $details.Text = (($stdout + "`r`n" + $stderr).Trim())
  if ($script:resetProcess.ExitCode -eq 0 -and $stdout -match '(?m)^RESET OK') {
    $status.Text = 'RESET OK'
    $status.ForeColor = [System.Drawing.Color]::DarkGreen
  } else {
    $status.Text = 'RESET FAILED — see details'
    $status.ForeColor = [System.Drawing.Color]::DarkRed
  }
  $resetButton.Enabled = $true
  $script:resetProcess.Dispose()
  $script:resetProcess = $null
  Remove-Item -LiteralPath $script:stdoutPath, $script:stderrPath -Force -ErrorAction SilentlyContinue
  $script:stdoutPath = $null
  $script:stderrPath = $null
})

$resetButton.Add_Click({
  if ($script:resetProcess -ne $null) { return }
  if (-not (Test-Path -LiteralPath $penaltyTool -PathType Leaf)) {
    $status.Text = 'RESET FAILED — tool script not found'
    $status.ForeColor = [System.Drawing.Color]::DarkRed
    return
  }
  $outDir = Join-Path $env:TEMP 'City6-Test-Controls'
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  $runId = [Guid]::NewGuid().ToString('N')
  $script:stdoutPath = Join-Path $outDir ($runId + '.out')
  $script:stderrPath = Join-Path $outDir ($runId + '.err')
  $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $penaltyTool + '" ' +
    '--action=FULL_RESET_BOTH --apply --confirm=both-test-drivers'
  try {
    $script:resetProcess = Start-Process -FilePath $powershell `
      -ArgumentList $arguments `
      -WorkingDirectory $projectRoot `
      -WindowStyle Hidden `
      -RedirectStandardOutput $script:stdoutPath `
      -RedirectStandardError $script:stderrPath `
      -PassThru
    $resetButton.Enabled = $false
    $status.Text = 'RESET running…'
    $status.ForeColor = [System.Drawing.Color]::DarkGoldenrod
    $details.Clear()
    $timer.Start()
  } catch {
    $status.Text = 'RESET FAILED — could not start tool'
    $status.ForeColor = [System.Drawing.Color]::DarkRed
    $details.Text = $_.Exception.Message
    $script:resetProcess = $null
  }
})

[void]$window.ShowDialog()
