#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Builds a WinPE enrollment USB (or ISO) in one step.
.PARAMETER Arch
    Target CPU architecture. amd64 (default) covers Intel/AMD laptops.
    Use arm64 for Qualcomm laptops or ARM virtual machines.
.PARAMETER DriveLetter
    Drive letter of the USB to write to (e.g. E). Auto-detected if omitted.
.PARAMETER Iso
    Build a bootable ISO file instead of writing to USB. Saved next to this
    script as AutopilotEnrollment.iso. Useful for VM testing before cutting USBs.
#>
param(
    [ValidateSet('amd64', 'arm64')]
    [string]$Arch = 'amd64',
    [string]$DriveLetter = '',
    [switch]$Iso
)

$ErrorActionPreference  = 'Stop'
$ProgressPreference     = 'SilentlyContinue'   # suppress Invoke-WebRequest progress bar
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step { param([string]$s) Write-Host "`n>> $s" -ForegroundColor Yellow }
function Write-OK   { param([string]$s) Write-Host "   [OK] $s" -ForegroundColor Green }
function Write-Fail { param([string]$s) Write-Host "   [FAIL] $s" -ForegroundColor Red }

Clear-Host
Write-Host ""
Write-Host "  ==========================================" -ForegroundColor Cyan
Write-Host "    WinPE Enrollment USB Builder" -ForegroundColor White
Write-Host "  ==========================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Locate Windows ADK — offer to install automatically if missing
# ---------------------------------------------------------------------------
Write-Step "Locating Windows ADK..."

function Find-ADKRoot {
    $root = $null
    try {
        # KitsRoot10 points to the Windows Kits root (e.g. C:\Program Files (x86)\Windows Kits\10\)
        # The ADK lives one level deeper in Assessment and Deployment Kit\
        $kitsRoot = (Get-ItemProperty `
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' `
            -ErrorAction SilentlyContinue).KitsRoot10
        if ($kitsRoot) {
            $candidate = Join-Path $kitsRoot "Assessment and Deployment Kit"
            if (Test-Path $candidate) { $root = $candidate }
        }
    } catch {}
    if (-not $root) {
        $root = @(
            'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit',
            'C:\Program Files\Windows Kits\10\Assessment and Deployment Kit'
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    return $root
}

function Install-ADK {
    $tmp = Join-Path $env:TEMP "adk_setup"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    Write-Host "  Downloading Windows ADK installer (~2 MB, installs ~300 MB)..." -ForegroundColor Cyan
    $adkExe = Join-Path $tmp "adksetup.exe"
    Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2243390" `
        -OutFile $adkExe -UseBasicParsing

    Write-Host "  Installing ADK (Deployment Tools only) - this takes a few minutes..." -ForegroundColor Cyan
    $p = Start-Process -FilePath $adkExe `
        -ArgumentList "/features OptionId.DeploymentTools /quiet /norestart" `
        -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "ADK installer exited with code $($p.ExitCode)" }
    Write-OK "ADK installed."

    Write-Host "  Downloading WinPE add-on installer (~2 MB, installs ~900 MB)..." -ForegroundColor Cyan
    $peExe = Join-Path $tmp "adkwinpesetup.exe"
    Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2243391" `
        -OutFile $peExe -UseBasicParsing

    Write-Host "  Installing WinPE add-on - this takes a few minutes..." -ForegroundColor Cyan
    $p = Start-Process -FilePath $peExe `
        -ArgumentList "/features OptionId.WindowsPreinstallationEnvironment /quiet /norestart" `
        -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "WinPE add-on installer exited with code $($p.ExitCode)" }
    Write-OK "WinPE add-on installed."

    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$adkRoot     = Find-ADKRoot
$installedAll = $false

if (-not $adkRoot) {
    Write-Host "  Windows ADK not found." -ForegroundColor Yellow
    Write-Host ""
    $answer = (Read-Host "  Install it automatically now? Requires ~1.2 GB and internet access. (Y/N)").Trim().ToUpper()
    if ($answer -ne 'Y') {
        Write-Host ""
        Write-Host "  Install manually from:" -ForegroundColor Red
        Write-Host "  https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install" -ForegroundColor Red
        exit 1
    }
    try {
        Install-ADK  # installs both ADK and WinPE add-on
        $installedAll = $true
    } catch {
        Write-Fail "Auto-install failed: $_"
        Write-Host "  Install manually from:" -ForegroundColor Red
        Write-Host "  https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install" -ForegroundColor Red
        exit 1
    }
    $adkRoot = Find-ADKRoot
    if (-not $adkRoot) {
        Write-Fail "ADK still not found after installation. Try restarting and re-running."
        exit 1
    }
}

$winPERoot = Join-Path $adkRoot "Windows Preinstallation Environment"
$copype    = Join-Path $winPERoot "copype.cmd"
$makeMedia = Join-Path $winPERoot "MakeWinPEMedia.cmd"
$ocDir     = Join-Path $winPERoot "$Arch\WinPE_OCs"

# Only check for WinPE add-on separately if Install-ADK didn't already handle it
if (-not $installedAll -and (-not (Test-Path $copype) -or -not (Test-Path $ocDir))) {
    Write-Host "  WinPE add-on not found. Looking for:" -ForegroundColor Yellow
    Write-Host "    $copype" -ForegroundColor DarkGray
    Write-Host "    $ocDir" -ForegroundColor DarkGray
    Write-Host ""
    $answer = (Read-Host "  Install WinPE add-on automatically now? Requires ~900 MB. (Y/N)").Trim().ToUpper()
    if ($answer -ne 'Y') {
        Write-Host "  Install manually from:" -ForegroundColor Red
        Write-Host "  https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install" -ForegroundColor Red
        exit 1
    }
    try {
        $tmp   = Join-Path $env:TEMP "adk_setup"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        Write-Host "  Downloading WinPE add-on installer..." -ForegroundColor Cyan
        $peExe = Join-Path $tmp "adkwinpesetup.exe"
        Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2243391" `
            -OutFile $peExe -UseBasicParsing
        Write-Host "  Installing - this takes a few minutes..." -ForegroundColor Cyan
        $p = Start-Process -FilePath $peExe `
            -ArgumentList "/features OptionId.WindowsPreinstallationEnvironment /quiet /norestart" `
            -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "Installer exited with code $($p.ExitCode)" }
        Write-OK "WinPE add-on installed."
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Fail "Auto-install failed: $_"
        exit 1
    }
}

Write-OK "ADK: $adkRoot"

# ---------------------------------------------------------------------------
# 2. Detect and confirm target (USB or ISO)
# ---------------------------------------------------------------------------
$isoPath   = $null
$usbLetter = $null

if ($Iso) {
    $isoPath = Join-Path $scriptDir "AutopilotEnrollment_$Arch.iso"
    Write-Step "ISO mode - will save to: $isoPath"
} else {
    Write-Step "Detecting USB drives..."

    $usbDrives = Get-CimInstance -ClassName Win32_LogicalDisk |
        Where-Object { $_.DriveType -eq 2 }  # 2 = Removable

    if ($DriveLetter) {
        $target = $usbDrives | Where-Object { $_.DeviceID -ieq "${DriveLetter}:" }
        if (-not $target) {
            Write-Fail "No removable drive at ${DriveLetter}:  (is it inserted?)"
            exit 1
        }
    } elseif ($usbDrives.Count -eq 0) {
        Write-Fail "No USB drive detected. Insert a USB drive and re-run."
        exit 1
    } elseif ($usbDrives.Count -eq 1) {
        $target = $usbDrives[0]
    } else {
        Write-Host "`n  Multiple USB drives found:" -ForegroundColor Cyan
        foreach ($d in $usbDrives) {
            $gb = if ($d.Size) { "$([math]::Round($d.Size/1GB,1)) GB" } else { "unknown size" }
            Write-Host "    $($d.DeviceID)  $($d.VolumeName)  ($gb)"
        }
        Write-Host ""
        $letter = (Read-Host "  Enter drive letter to use (e.g. E)").Trim().ToUpper().TrimEnd(':')
        $target = $usbDrives | Where-Object { $_.DeviceID -ieq "${letter}:" }
        if (-not $target) { Write-Fail "Drive ${letter}: not found."; exit 1 }
    }

    $usbLetter = $target.DeviceID.TrimEnd(':')
    $usbGB     = if ($target.Size) { "$([math]::Round($target.Size/1GB,1)) GB" } else { "unknown size" }
    Write-OK "Target: ${usbLetter}: - $($target.VolumeName) ($usbGB)"

    Write-Host ""
    Write-Host "  !! ALL DATA ON ${usbLetter}: WILL BE PERMANENTLY ERASED !!" -ForegroundColor Red
    Write-Host ""
    $confirm = (Read-Host "  Type YES to continue").Trim()
    if ($confirm -ne 'YES') { Write-Host "`n  Aborted.`n"; exit 0 }
}

# ---------------------------------------------------------------------------
# 3. Download Get-WindowsAutoPilotInfo (skip if already present)
# ---------------------------------------------------------------------------
$hashScript = Join-Path $scriptDir "Scripts\Get-WindowsAutoPilotInfo.ps1"

if (Test-Path $hashScript) {
    Write-Step "Get-WindowsAutoPilotInfo.ps1 already present - skipping download."
} else {
    Write-Step "Downloading Get-WindowsAutoPilotInfo from PSGallery..."
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge '2.8.5.201' })) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        }
        Save-Script -Name Get-WindowsAutoPilotInfo `
            -Path (Join-Path $scriptDir "Scripts") `
            -Force
        Write-OK "Downloaded to Scripts\"
    } catch {
        Write-Fail "PSGallery download failed: $_"
        Write-Host @"
  Manually download Get-WindowsAutoPilotInfo.ps1 from:
    https://www.powershellgallery.com/packages/Get-WindowsAutoPilotInfo
  Place it in the Scripts\ folder next to this script, then re-run.
"@ -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 4. Create WinPE working directory
# ---------------------------------------------------------------------------
$workDir  = Join-Path $env:TEMP "WinPE_enroll_$Arch"
$mountDir = Join-Path $workDir "mount"

Write-Step "Building WinPE base ($Arch)..."
if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }

$result = & cmd /c "`"$copype`" $Arch `"$workDir`"" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "copype failed."
    Write-Host $result
    exit 1
}
Write-OK "WinPE base created."

# ---------------------------------------------------------------------------
# 5. Mount WinPE image
# ---------------------------------------------------------------------------
Write-Step "Mounting WinPE image..."
$wimFile = Join-Path $workDir "media\sources\boot.wim"

& dism /Mount-Image /ImageFile:"$wimFile" /Index:1 /MountDir:"$mountDir" /Quiet
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to mount WinPE image."
    exit 1
}
Write-OK "Mounted at $mountDir"

# ---------------------------------------------------------------------------
# 6. Add optional components
# ---------------------------------------------------------------------------
function Add-WinPEPackage {
    param([string]$Name)
    $cab     = Join-Path $ocDir "$Name.cab"
    $langCab = Join-Path $ocDir "en-us\${Name}_en-us.cab"
    if (-not (Test-Path $cab)) { throw "Package not found: $cab" }

    & dism /Add-Package /Image:"$mountDir" /PackagePath:"$cab" /Quiet
    if ($LASTEXITCODE -ne 0) { throw "dism failed adding $Name" }

    if (Test-Path $langCab) {
        & dism /Add-Package /Image:"$mountDir" /PackagePath:"$langCab" /Quiet
        if ($LASTEXITCODE -ne 0) { throw "dism failed adding ${Name}_en-us" }
    }
}

Write-Step "Adding WinPE optional components (this takes a minute)..."
$packages = 'WinPE-WMI','WinPE-NetFX','WinPE-Scripting','WinPE-PowerShell','WinPE-StorageWMI','WinPE-DismCmdlets'

foreach ($pkg in $packages) {
    try {
        Add-WinPEPackage $pkg
        Write-OK $pkg
    } catch {
        Write-Fail "Failed: $_"
        Write-Host "  Rolling back - discarding mounted image..."
        & dism /Unmount-Image /MountDir:"$mountDir" /Discard /Quiet 2>&1 | Out-Null
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 7. Inject scripts and startnet.cmd
# ---------------------------------------------------------------------------
Write-Step "Injecting enrollment scripts..."

$destScripts = Join-Path $mountDir "Scripts"
New-Item -ItemType Directory -Path $destScripts -Force | Out-Null
Copy-Item (Join-Path $scriptDir "Scripts\*") $destScripts -Force
Write-OK "Scripts copied to X:\Scripts\"

Copy-Item (Join-Path $scriptDir "startnet.cmd") `
    (Join-Path $mountDir "Windows\System32\startnet.cmd") -Force
Write-OK "startnet.cmd replaced."

# ---------------------------------------------------------------------------
# 8. Commit image
# ---------------------------------------------------------------------------
Write-Step "Committing image..."
& dism /Unmount-Image /MountDir:"$mountDir" /Commit /Quiet
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to commit image."
    exit 1
}
Write-OK "Image committed."

# ---------------------------------------------------------------------------
# 9. Write to USB or ISO
# ---------------------------------------------------------------------------
if ($Iso) {
    Write-Step "Creating ISO: $isoPath ..."
    $result = & cmd /c "`"$makeMedia`" /ISO `"$workDir`" `"$isoPath`"" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "MakeWinPEMedia /ISO failed."
        Write-Host $result
        exit 1
    }
    Write-OK "ISO created: $isoPath"
} else {
    Write-Step "Writing to USB ${usbLetter}: (this will take a few minutes)..."
    # Pipe 'y' to accept MakeWinPEMedia's own format confirmation
    $result = "y" | cmd /c "`"$makeMedia`" /UFD `"$workDir`" ${usbLetter}:" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "MakeWinPEMedia failed."
        Write-Host $result
        exit 1
    }
    Write-OK "WinPE written."
}

# ---------------------------------------------------------------------------
# 10. Copy code.txt to USB root if present next to this script (USB only)
# ---------------------------------------------------------------------------
if (-not $Iso) {
    $codeTxt = Join-Path $scriptDir "code.txt"
    if (Test-Path $codeTxt) {
        Copy-Item $codeTxt "${usbLetter}:\code.txt" -Force
        Write-OK "code.txt copied to USB root (auto-enroll enabled)."
    } else {
        Write-Host "   (no code.txt found - USB will prompt for code on boot)" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# 11. Cleanup
# ---------------------------------------------------------------------------
Write-Step "Cleaning up temp files..."
Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
Write-OK "Done."

Write-Host ""
Write-Host "  ==========================================" -ForegroundColor Green
if ($Iso) {
    Write-Host "    ISO IS READY" -ForegroundColor Green
} else {
    Write-Host "    USB IS READY" -ForegroundColor Green
}
Write-Host "  ==========================================" -ForegroundColor Green
Write-Host ""
if ($Iso) {
    Write-Host "  ISO saved to: $isoPath" -ForegroundColor White
    Write-Host "  Boot a VM from this ISO to test enrollment." -ForegroundColor White
} else {
    Write-Host "  Boot a device from ${usbLetter}: to begin enrollment." -ForegroundColor White
}
Write-Host ""
