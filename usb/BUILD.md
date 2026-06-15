# WinPE Enrollment USB — Build Guide

Produces a bootable USB that prompts a technician for an enrollment code and
registers the device with Microsoft Autopilot. No credentials are stored on
the USB — the one-time code is the only authentication.

## Requirements

- A **64-bit (x64) Windows machine** with internet access (~1.2 GB for ADK)
- A USB drive **>= 1 GB** (it will be fully erased)

> **ARM64 Windows machines (e.g. Surface Pro X, Qualcomm laptops) cannot build
> this image** due to ADK compatibility issues. Use a standard Intel/AMD Windows
> PC or VM.

That's it. The build script handles everything else automatically.

---

## Build a USB

Insert the USB drive, then double-click **`build.bat`**.

The script will:
1. Detect the Windows ADK — if missing, offer to download and install it
2. Download `Get-WindowsAutoPilotInfo.ps1` from PSGallery
3. Build and patch the WinPE image
4. Ask which USB drive to erase and confirm
5. Write the bootable image

If the WinPE add-on needs installing, an installer window will appear — click
through it and let it finish before the script continues.

**To specify the drive letter** and skip the detection prompt:
```cmd
build.bat amd64 E
```

> First run takes 10-15 minutes if ADK needs to be downloaded and installed.
> Subsequent builds take ~3-5 minutes.

---

## Build an ISO (for VM testing)

To get a bootable ISO file instead of writing to a USB:

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1 -Iso
```

This saves `AutopilotEnrollment_amd64.iso` in the `usb\` folder. Boot a VM from
it to test the full enrollment flow before cutting real USBs.

> Must be run on an x64 Windows machine — same requirement as USB builds.

---

## Test in a VM

1. Build an ISO (see above) on an x64 Windows machine
2. Copy the ISO to your Mac
3. UTM > New VM > Emulate > Other > select the ISO as boot disk
4. WinPE boots, `wpeinit` gets DHCP, the enrollment screen appears
5. Enter a valid code from the admin portal
6. Verify the device appears in Intune > Devices > Windows > Windows Enrollment > Devices

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
| `copype failed: architecture not found` | You are on an ARM64 Windows machine — use an x64 Windows PC instead |

If the script crashes, WinPE drops to a `cmd` shell (the `cmd /k` in `startnet.cmd`)
so you can debug interactively from the device.
