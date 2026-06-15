@echo off
:: Launches build.ps1 as Administrator. Double-click this to build the USB.
:: To target ARM64 devices: build.bat arm64
:: To specify a drive letter:  build.bat amd64 E

set ARCH=%~1
if "%ARCH%"=="" set ARCH=amd64

set DRIVE=%~2
if "%DRIVE%"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0build.ps1\" -Arch %ARCH%' -Wait"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0build.ps1\" -Arch %ARCH% -DriveLetter %DRIVE%' -Wait"
)
