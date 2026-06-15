# WinPE Enrollment USB — Build Guide

Produces a bootable USB that prompts a technician for an enrollment code and
registers the device with Microsoft Autopilot. No credentials are stored on
the USB — the one-time code is the only authentication.

## Requirements

- A **Windows machine** (or VM) with internet access (~1.2 GB for ADK)
- A USB drive **>= 1 GB** (it will be fully erased)

That's it. The build script handles everything else automatically.

---

## Build

Insert the USB drive, then double-click **`build.bat`**.

The script will:
1. Detect the Windows ADK — if missing, offer to download and install it silently
2. Download `Get-WindowsAutoPilotInfo.ps1` from PSGallery
3. Build and patch the WinPE image
4. Ask which USB drive to erase and confirm
5. Write the bootable image

**For ARM64 devices** (Qualcomm laptops, ARM VMs):
```cmd
build.bat arm64
```

**To specify the drive letter** and skip the detection prompt:
```cmd
build.bat amd64 E
```

**To build an ISO instead of writing to USB** (for VM testing):
```powershell
powershell -ExecutionPolicy Bypass -File build.ps1 -Iso -Arch arm64
```

> First run takes 10-15 minutes if ADK needs to be downloaded and installed.
> Subsequent builds take ~3-5 minutes.

---

## Test in a VM before cutting USBs

1. Build an ISO (see above)
2. Boot a VM from it (UTM on Mac: new VM > Other > select the ISO as boot disk)
3. WinPE boots, `wpeinit` gets DHCP, the enrollment screen appears
4. Enter a valid code from the admin portal
5. Verify the device appears in Intune > Devices > Windows > Windows Enrollment > Devices

---

## Pre-loading a code (optional, zero typing)

Drop a `code.txt` file in the root of the USB drive after writing it:

```
E:\code.txt
```

Contents — just the 12-character code, nothing else:

```
ABC1DEF2GH3J
```

The script reads it automatically on boot and skips the prompt. Falls back to
asking for a code if the file is missing or invalid.

To reuse the USB for a new device, delete the old `code.txt` and drop a new one.

If you place `code.txt` next to `build.bat` before running, the build script
copies it to the USB root automatically.

---

## BACKEND_URL

The enrollment portal URL is hardcoded at the top of `Scripts/enroll.ps1`:

```powershell
$BACKEND_URL = "https://ap.lamaquina.casa"
```

Update this before building if the portal URL ever changes.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|-------------|
| `Invoke-RestMethod is not recognized` | WinPE-PowerShell or WinPE-NetFX not added — rebuild |
| `Get-WmiObject` fails | WinPE-WMI not added — rebuild |
| Hash collection produces empty CSV | WinPE-StorageWMI not added — rebuild |
| Network unreachable (HTTP 0) | `wpeinit` did not get DHCP; plug in ethernet or increase the timeout in `startnet.cmd` |
| HTTP 404 on valid code | Code already used or expired; generate a new one from the portal |
| Script not found on boot | Scripts were not copied into the image; rebuild |
| ADK auto-install fails | Run `build.bat` again; or install manually from [learn.microsoft.com](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) |

If the script crashes, WinPE drops to a `cmd` shell (the `cmd /k` in `startnet.cmd`)
so you can debug interactively from the device.
