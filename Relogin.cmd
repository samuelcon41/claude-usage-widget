@echo off
set CLAUDE="%USERPROFILE%\.local\bin\claude.exe"
echo ============================================
echo   Claude re-login for the usage widget
echo ============================================
echo.
echo Step 1 of 2: signing out the old token...
%CLAUDE% auth logout
echo.
echo Step 2 of 2: sign in now.
echo   - Choose "Claude account with subscription"
echo   - Approve in the browser when it opens
echo.
%CLAUDE% auth login
echo.
echo Done. You can close this window.
pause
