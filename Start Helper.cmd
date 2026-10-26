@echo off
setlocal
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0helper\Start-Helper.ps1"
if errorlevel 1 (
  echo.
  echo The helper stopped. Please share the error above.
  echo Do not disable Windows security policy to make it run.
  pause
  exit /b 1
)
