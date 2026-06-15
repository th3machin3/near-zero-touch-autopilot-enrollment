@echo off
wpeinit
echo.
echo Waiting for network...
timeout /t 8 /nobreak >nul
powershell -ExecutionPolicy Bypass -NonInteractive -File X:\Scripts\enroll.ps1
cmd /k
