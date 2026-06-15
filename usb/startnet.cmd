@echo off
mode con cols=120 lines=45
wpeinit
echo.
echo Waiting for network...
timeout /t 8 /nobreak >nul
powershell -ExecutionPolicy Bypass -File X:\Scripts\enroll.ps1
cmd /k
