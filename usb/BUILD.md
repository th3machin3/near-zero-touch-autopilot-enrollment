# WinPE Enrollment USB — Build Guide

Produces a bootable USB that prompts a technician for an enrollment code and
registers the device with Microsoft Autopilot. No credentials are stored on the
USB — the one-time code is the only authentication.

## Requirements

- A **Windows machine** (or VM) with internet access
- A USB drive **≥ 1 GB** (it will be fully erased)
- The [Windows ADK for Windows 11](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) — "Deployment Tools" component only
- The **WinPE add-on** for the ADK (separate download on the same page)

Install the ADK first, then the WinPE add-on. Both are free from Microsoft.

---

## Automated build (recommended)

Insert the USB drive, then double-click **`build.bat`** in this folder.
It will:
1. Locate the Windows ADK automatically
2. Download `Get-WindowsAutoPilotInfo.ps1` from PSGallery
3. Build and patch the WinPE image (adds PowerShell, WMI, networking)
4. Ask you to confirm which USB drive to erase
5. Write the bootable image

For ARM64 devices (Qualcomm laptops, ARM VMs):
```cmd
build.bat arm64
```

To specify the drive letter directly and skip the USB detection prompt:
```cmd
build.bat amd64 E
```

To create a bootable **ISO** instead of writing to USB (useful for VM testing):
```cmd
powershell -ExecutionPolicy Bypass -File build.ps1 -Iso
```

> The build takes roughly 3–5 minutes. The DISM optional-component steps are
> the slow part — this is normal.

---

## Manual build steps (reference / troubleshooting)

These are what `build.ps1` does under the hood, in case you need to run them
by hand.

Open **Deployment and Imaging Tools Environment** as Administrator
(Start → search "Deployment and Imaging Tools Environment").

```cmd
REM Adjust amd64 → arm64 if building for ARM devices
copype amd64 C:\WinPE_amd64

Dism /Mount-Image /ImageFile:C:\WinPE_amd64\media\sources\boot.wim /Index:1 /MountDir:C:\WinPE_amd64\mount
```

```cmd
set ADK=C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs

Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"%ADK%\WinPE-WMI.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"%ADK%\en-us\WinPE-WMI_en-us.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"%ADK%\WinPE-NetFX.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"%ADK%\en-us\WinPE-NetFX_en-us.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"%ADK%\WinPE-Scripting.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"%ADK%\en-us\WinPE-Scripting_en-us.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"%ADK%\WinPE-PowerShell.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"%ADK%\en-us\WinPE-PowerShell_en-us.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"%ADK%\WinPE-StorageWMI.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"%ADK%\en-us\WinPE-StorageWMI_en-us.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"%ADK%\WinPE-DismCmdlets.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"%ADK%\en-us\WinPE-DismCmdlets_en-us.cab"
```

```cmd
xcopy /E /I usb\Scripts C:\WinPE_amd64\mount\Scripts
copy /Y usb\startnet.cmd C:\WinPE_amd64\mount\Windows\System32\startnet.cmd
Dism /Unmount-Image /MountDir:C:\WinPE_amd64\mount /Commit
MakeWinPEMedia /UFD C:\WinPE_amd64 E:
```

---

## Test in a VM before using on real hardware

1. Build an ISO: `powershell -ExecutionPolicy Bypass -File build.ps1 -Iso`
2. Boot a VM from it (UTM on Mac: new VM → set boot disk to the ISO)
3. WinPE boots, `wpeinit` gets DHCP, `enroll.ps1` launches
4. Enter a valid code from the admin portal
5. Verify the device appears in Intune → Devices → Windows → Windows Enrollment → Devices

---

## Pre-loading an enrollment code (optional, no typing needed)

If you want a device to enroll with zero keyboard interaction, place a `code.txt`
file in the **root of the USB drive** after writing the WinPE image:

```
E:\code.txt   (E: = your USB drive letter on a normal Windows machine)
```

Contents — just the 12-character code, nothing else:

```
ABC1DEF2GH3J
```

On boot, `enroll.ps1` scans all drives (excluding the WinPE ramdisk `X:`) for
`code.txt`. If found and valid, it uses the code automatically and skips the
prompt. If the file is missing, empty, or contains an invalid code it falls
back to asking the technician to type one.

One file, one USB, one device. Reuse the same USB for the next device by
deleting the old `code.txt` and dropping a new one.

---

## BACKEND_URL

The enrollment portal URL is hardcoded in `usb/Scripts/enroll.ps1`:

```powershell
$BACKEND_URL = "https://ap.lamaquina.casa"
```

Update this before building if the portal URL changes.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|-------------|
| `Invoke-RestMethod is not recognized` | WinPE-PowerShell or WinPE-NetFX not added |
| `Get-WmiObject` fails | WinPE-WMI not added |
| Hash collection produces empty CSV | WinPE-StorageWMI not added |
| "Could not reach portal" at HTTP 0 | `wpeinit` didn't get DHCP; plug in ethernet or increase timeout in startnet.cmd |
| HTTP 404 on valid code | Code already used or expired; generate a new code from the portal |
| Script not found on boot | `xcopy` path was wrong; verify `dir X:\Scripts` from WinPE shell |

If the script crashes, WinPE drops to `cmd` (the `cmd /k` in startnet.cmd) so you
can debug interactively.
