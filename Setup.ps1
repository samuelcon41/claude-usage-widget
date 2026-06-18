# Setup.ps1 - installs the Claude Usage Widget on this computer.
#
# What it does:
#   1. Copies the widget to %USERPROFILE%\ClaudeUsageWidget
#   2. Creates a desktop shortcut and adds it to Startup (runs at sign-in)
#   3. If this PC has no Claude login yet: installs the Claude Code CLI
#      and walks you through a one-time browser sign-in (needed for the
#      exact limit percentages)
#   4. Starts the widget

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '=== Claude Usage Widget setup ===' -ForegroundColor Cyan
Write-Host ''

# 1. Copy widget files
$dest = Join-Path $env:USERPROFILE 'ClaudeUsageWidget'
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'ClaudeUsageWidget.ps1') (Join-Path $dest 'ClaudeUsageWidget.ps1') -Force
Write-Host "Installed to $dest" -ForegroundColor Green

# 2. Shortcuts (desktop + startup)
$ws = New-Object -ComObject WScript.Shell
foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Startup'))) {
    $lnk = $ws.CreateShortcut((Join-Path $folder 'Claude Usage Widget.lnk'))
    $lnk.TargetPath  = 'powershell.exe'
    $lnk.Arguments   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\ClaudeUsageWidget.ps1`""
    $lnk.IconLocation = 'shell32.dll,167'
    $lnk.Description = 'Floating Claude usage widget'
    $lnk.Save()
}
Write-Host 'Desktop shortcut created; widget will auto-start at sign-in.' -ForegroundColor Green

# 3. Claude login (gives the widget exact limit percentages)
$credFile = Join-Path $env:USERPROFILE '.claude\.credentials.json'
if (Test-Path $credFile) {
    Write-Host 'Claude login already present - live mode will work.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host 'No Claude login found on this PC. Setting it up (one time only)...' -ForegroundColor Yellow

    # find or install the Claude Code CLI
    $claude = $null
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) { $claude = $cmd.Source }
    if (-not $claude -and (Test-Path "$env:USERPROFILE\.local\bin\claude.exe")) {
        $claude = "$env:USERPROFILE\.local\bin\claude.exe"
    }
    if (-not $claude) {
        Write-Host 'Installing the Claude Code CLI (official installer)...' -ForegroundColor Yellow
        Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
        if (Test-Path "$env:USERPROFILE\.local\bin\claude.exe") {
            $claude = "$env:USERPROFILE\.local\bin\claude.exe"
        } else {
            $cmd = Get-Command claude -ErrorAction SilentlyContinue
            if ($cmd) { $claude = $cmd.Source }
        }
    }

    if ($claude) {
        Write-Host ''
        Write-Host 'Claude will now start. Sign in with "Claude account with subscription"' -ForegroundColor Yellow
        Write-Host 'and approve in your browser. When you see the Claude prompt, type /exit' -ForegroundColor Yellow
        Write-Host '(or just close that window) and setup will continue.' -ForegroundColor Yellow
        Write-Host ''
        Read-Host 'Press Enter to open the sign-in'
        Start-Process cmd -ArgumentList '/k', "`"$claude`"" -Wait:$false

        # wait for the login to land (up to 10 minutes)
        $deadline = (Get-Date).AddMinutes(10)
        while ((Get-Date) -lt $deadline -and -not (Test-Path $credFile)) { Start-Sleep -Seconds 5 }
        if (Test-Path $credFile) {
            Write-Host 'Signed in - live mode enabled.' -ForegroundColor Green
        } else {
            Write-Host 'No sign-in detected. The widget will run in estimate mode;' -ForegroundColor Yellow
            Write-Host 'run this setup again any time to add the sign-in.' -ForegroundColor Yellow
        }
    } else {
        Write-Host 'Could not install the Claude CLI. The widget will run in estimate mode.' -ForegroundColor Yellow
    }
}

# 4. Start the widget (replace any running copy)
$me = $PID
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like '*-File*ClaudeUsageWidget.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -Confirm:$false -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"$dest\ClaudeUsageWidget.ps1"

Write-Host ''
Write-Host 'Done! The widget is on your screen - drag it wherever you like.' -ForegroundColor Green
Write-Host ''
Read-Host 'Press Enter to close'
