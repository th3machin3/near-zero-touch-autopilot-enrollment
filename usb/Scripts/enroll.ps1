# Autopilot enrollment script for WinPE USB
# Edit $BACKEND_URL to match your deployment before building the USB image.
$BACKEND_URL = "https://ap.lamaquina.casa"

$Host.UI.RawUI.WindowTitle = "Windows Autopilot Enrollment"

function Write-Banner {
    Clear-Host
    $logo = @'

                                             ....:+*+:
                                            .-+*****+:
                                    ..-+:  .=*****+::.
                                    +***:  .****:                    .........
                        ..:::...    +***:  .****.                   .:=******-..
                     .=+******+:    +***:  .****.           ..:-.  .=*********+.
                     :+*********:   +***:  .****.    ...   .****.  :****...=***+
                     :==-...=***-   +***:  .****.  .-=*+   .****.  -***=   :***+
                      ..    -***-   +***:  .****.  :***+   .****.  -***=   :***+
                           .-***-   +***:  .****.  :***+   .****.  -***=   :***+
                     ..:=*******-   +***:  .****.  :***+   .****.  -***=   :***+
                    .-**********-   +***:  .****.  :***+   .****.  -***=   :***+
                    :****+..-***-   +***:  .****.  :***+   .****.  -***=   :***+
                    +***-.  -***-   +***:  .****.  :***+   .****.  -***+...-***+
                    +***:   -***-   +***:  .****.  :***+   .****.  -***********:
                    +***:   -***-   +***:  .***-.  :***+   .****.  -*********=..
                    =***=...+***-   +***:  ...     :****...:***+.  -***=......
                    .+*********=.   --...          .-**********:   -***=
                    ..=******+:.                    .:+******=..   -***=
                       .......                         ......      -***=
                                                                   -***=
                                                                   -*+-.

'@
    Write-Host $logo -ForegroundColor Magenta
    Write-Host "                                   Windows Autopilot Enrollment" -ForegroundColor White
    Write-Host ""
}

function Write-Step {
    param([string]$Message)
    Write-Host "  >> $Message" -ForegroundColor Yellow
}

function Write-OK {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

Write-Banner

# --- Validate prerequisite script ---
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hashScript = Join-Path $scriptDir "Get-WindowsAutoPilotInfo.ps1"

if (-not (Test-Path $hashScript)) {
    Write-Fail "Get-WindowsAutoPilotInfo.ps1 is missing from this USB."
    Write-Host ""
    Write-Host "  Rebuild the USB with the script bundled." -ForegroundColor Red
    Write-Host "  See usb/BUILD.md in the enrollment portal repo." -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

# --- Try to read code from code.txt on the USB drive ---
# In WinPE, X: is the ramdisk — the physical USB gets a different drive letter.
# Scan all mounted drives (excluding X:) for a code.txt in the root.
$code = ""
$codeFile = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'X' } |
    ForEach-Object { Join-Path $_.Root "code.txt" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1

if ($codeFile) {
    $raw = (Get-Content $codeFile -Raw).Trim().ToUpper()
    if ($raw.Length -eq 12 -and $raw -match '^[A-Z0-9]+$') {
        $code = $raw
        Write-Host "  Found code.txt on USB — using code automatically." -ForegroundColor Cyan
        Write-Host ""
    } else {
        Write-Host "  code.txt found but contents are not a valid 12-char code ('$raw')." -ForegroundColor DarkYellow
        Write-Host "  Falling back to manual entry." -ForegroundColor DarkYellow
        Write-Host ""
    }
}

# --- Prompt if no valid code was found automatically ---
while ($code -eq "") {
    $raw = (Read-Host "  Enter enrollment code").Trim().ToUpper()
    if ($raw.Length -eq 12 -and $raw -match '^[A-Z0-9]+$') {
        $code = $raw
    } else {
        Write-Host "  Codes are 12 uppercase letters/digits (e.g. ABC1DEF2GH3J). Try again." -ForegroundColor Red
        Write-Host ""
    }
}

Write-Host ""
Write-Step "Collecting hardware information..."

# --- Model via WMI ---
$model = "Unknown"
try {
    $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) {
        $model = "$($cs.Manufacturer) $($cs.Model)".Trim()
    }
} catch {}

# --- Collect hardware hash ---
$tmpCsv = "$env:TEMP\autopilot_hash_$([System.IO.Path]::GetRandomFileName()).csv"

try {
    & $hashScript -OutputFile $tmpCsv -ErrorAction Stop
} catch {
    Write-Fail "Hash collection failed: $_"
    Write-Host "  Check that WinPE-WMI and WinPE-StorageWMI components are installed." -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

if (-not (Test-Path $tmpCsv)) {
    Write-Fail "Hash file was not created. Check WinPE optional components."
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

$device = Import-Csv $tmpCsv
$hardwareHash = $device.'Hardware Hash'
$serial = $device.'Device Serial Number'

try { Remove-Item $tmpCsv -Force -ErrorAction SilentlyContinue } catch {}

if (-not $hardwareHash -or $hardwareHash.Length -lt 100) {
    Write-Fail "Hardware hash is empty or too short — collection may have failed."
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

if (-not $serial) {
    Write-Fail "Could not read device serial number."
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

Write-OK "Serial : $serial"
Write-OK "Model  : $model"
Write-OK "Hash   : $($hardwareHash.Substring(0,32))... ($($hardwareHash.Length) chars)"
Write-Host ""

# --- Submit to Autopilot ---
Write-Step "Submitting to Autopilot enrollment portal..."

$body = @{
    hardwareHash = $hardwareHash
    serial       = $serial
    model        = $model
} | ConvertTo-Json

$headers = @{
    Authorization = "Bearer $code"
}

try {
    $response = Invoke-RestMethod `
        -Uri "$BACKEND_URL/api/e" `
        -Method POST `
        -Headers $headers `
        -Body $body `
        -ContentType "application/json" `
        -ErrorAction Stop

    Write-Host ""
    Write-Host "  ==============================================" -ForegroundColor Green
    Write-Host "    ENROLLMENT SUCCESSFUL" -ForegroundColor Green
    Write-Host "  ==============================================" -ForegroundColor Green
    Write-Host ""
    Write-OK "Device submitted to Microsoft Autopilot"
    Write-OK "Serial : $($response.serial)"
    Write-Host ""
    Write-Host "  The device will configure itself automatically on first boot." -ForegroundColor White
    Write-Host "  Remove the USB, then restart the device to begin setup." -ForegroundColor White
    Write-Host ""

} catch {
    $statusCode = 0
    try { $statusCode = $_.Exception.Response.StatusCode.value__ } catch {}

    Write-Host ""
    Write-Fail "Enrollment failed (HTTP $statusCode)"
    Write-Host ""
    switch ($statusCode) {
        401 { Write-Host "  The enrollment code is invalid." -ForegroundColor Red }
        404 { Write-Host "  Code not found, already used, or expired. Ask IT for a new code." -ForegroundColor Red }
        429 { Write-Host "  Too many failed attempts from this network. Contact IT." -ForegroundColor Red }
        502 { Write-Host "  Microsoft Autopilot API error. Try again or contact IT." -ForegroundColor Red }
        0   { Write-Host "  Could not reach $BACKEND_URL — check network cable/Wi-Fi." -ForegroundColor Red }
        default { Write-Host "  Unexpected error: $_" -ForegroundColor Red }
    }
    Write-Host ""
}

Read-Host "  Press Enter to return to shell"
