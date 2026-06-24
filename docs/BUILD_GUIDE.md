# Building a Custom ESXi ISO with HPE Synergy Drivers

A complete walkthrough for combining a VMware base ESXi depot with an HPE Synergy AddOn depot using PowerCLI Image Builder, producing an installable ISO that includes the FC/storage drivers HPE Synergy blades need.

## Why this is necessary

HPE Synergy compute modules booting from SAN need Fibre Channel and storage drivers present in the ESXi installer to see their boot LUN. The generic VMware base ISO does not include these drivers. Historically, HPE published pre-built "Synergy Custom" ESXi ISOs that bundled them.

Two things changed that make the manual build the right approach:

1. **HPE deprecated pre-built Synergy custom ISOs.** Beginning with HPE Synergy Service Pack (SSP) version 2026.01.xx, HPE no longer creates and releases Synergy Custom ESXi Images or Certified Vendor Add-ons. The supported path is now to take the VMware base image and combine it with HPE drivers/management software from the SSP / HPE AddOn depot yourself. (Reference: HPE Customer Notice a00156316; Broadcom KB 436480.)

2. **Patch releases may not have a matching pre-built image.** Even before the deprecation, if you needed a specific ESXi patch level (e.g. 9.0.2) and HPE hadn't yet published a Synergy custom ISO for exactly that build, you'd be stuck. Combining the base patch depot with an existing HPE AddOn from the same major version is supported and gets you a current, driver-complete image.

## What "supported" means here

Per HPE's documentation, VMware ESXi patches obtained directly from Broadcom may be installed on HPE Synergy systems, provided they do not cross a VMware ESXi "update" boundary (for example, 8.0 Update 2 to 8.0 Update 3) and do not introduce drivers that conflict with the supported HPE Synergy software release. An HPE AddOn from the same major ESXi version can be combined with a newer base patch within that version. Always confirm against the current HPE VMware Recipe and your SSP for your specific environment.

> This repository is community tooling, not an HPE or Broadcom product. Validate support boundaries for your environment against HPE's official documentation before deploying to production.

## Required files

| File | Source |
|---|---|
| VMware base ESXi offline depot zip (e.g. `VMware-ESXi-9.0.2.0.25148076-depot.zip`) | Broadcom patches portal |
| HPE Synergy AddOn offline depot zip (e.g. `HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip`) | HPE / Broadcom support portal |

Both require valid entitlement to download. This repository does not redistribute either file.

For the current HPE AddOn and supported base-image mappings, see HPE's VMware ESXi images page:
<https://www.hpe.com/us/en/servers/hpe-esxi.html>

And the HPE Synergy OS support matrix:
<https://support.hpe.com/docs/display/public/synergy-sw-release/OS_Support.html>

## Dependencies

### PowerCLI

```powershell
Install-Module -Name VMware.PowerCLI -Scope CurrentUser -AllowClobber
Import-Module VMware.ImageBuilder
```

### Python 3.7–3.12

PowerCLI Image Builder shells out to Python for the actual image assembly.

```powershell
winget install Python.Python.3.12
```

Point PowerCLI at the Python executable:

```powershell
Set-PowerCLIConfiguration `
    -PythonPath "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe" `
    -Scope User -Confirm:$false
```

### Python modules

```powershell
& "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe" -m pip install six lxml psutil pyopenssl
```

## Build procedure

### 1. Query the base image version

```powershell
Get-DepotBaseImages "C:\path\to\VMware-ESXi-9.0.2.0.25148076-depot.zip"
```

Note the reported version (e.g. `9.0.2-0.25148076`) — you need it for the software spec.

### 2. Query the HPE AddOn details

```powershell
Get-DepotAddons "C:\path\to\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip"
```

Note the AddOn name and version (e.g. `HPE-Custom-Syn-AddOn`, `900.0.0.12.3.5-5`).

### 3. Create the software spec (JSON)

Use the helper script to write a BOM-free spec:

```powershell
.\scripts\Write-SoftwareSpec.ps1 `
    -OutFile "C:\path\to\synergy-custom.json" `
    -BaseVersion "9.0.2-0.25148076" `
    -AddonName "HPE-Custom-Syn-AddOn" `
    -AddonVersion "900.0.0.12.3.5-5"
```

Or copy `examples/synergy-custom.json.template`, edit the versions, and **save as UTF-8 without BOM** (this matters — see Gotchas).

### 4. Build the ISO

```powershell
.\scripts\Build-CustomEsxiIso.ps1 `
    -BaseDepot "C:\path\to\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
    -AddonDepot "C:\path\to\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
    -SoftwareSpec "C:\path\to\synergy-custom.json" `
    -Destination "C:\path\to\VMware-ESX-9.0.2-HPE-Synergy-Custom.iso"
```

The result is roughly a 700 MB ISO.

### 5. Validate the merge (before deploying)

```powershell
.\scripts\Validate-IsoVibs.ps1 `
    -BaseDepot "C:\path\to\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
    -AddonDepot "C:\path\to\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip"
```

Every AddOn VIB should report `OK`. Any `MISSING` means the merge dropped a driver — do not deploy that ISO.

### 6. Post-install validation (on the ESXi host)

After installing from the custom ISO, SSH to the host and confirm the drivers loaded:

```sh
esxcli software vib list | grep -i -E "qcnic|bnxt|storcli|amsd|ilo|ssacli|qlnativefc|smartpqi"
```

See `scripts/post-install-validation.sh` for a fuller check including storage adapter and FC HBA enumeration.

## Gotchas

These are the failures that actually cost time:

- **JSON spec must be UTF-8 without BOM.** `Out-File` and `Set-Content` add a BOM by default, and `New-IsoImage` rejects it with an unhelpful parse error. Use `[System.IO.File]::WriteAllText` (the `Write-SoftwareSpec.ps1` helper does this for you).

- **PowerCLI resolves relative paths from the user profile dir, not the current working directory.** Always pass full absolute paths to the cmdlets, or wrap with `Resolve-Path` (the build script does this).

- **Acceptance-level errors.** HPE VIBs are partner-signed, not VMware-certified. If `New-IsoImage` fails complaining about acceptance level, pass `-AcceptanceLevel PartnerSupported`.

- **FC driver version is load-bearing for SAN boot.** A custom image's FC driver can drop support for a specific HBA across revisions (HPE's own 7.0 U3 release notes document exactly this for the Synergy 3530C 16G FC HBA). Test on one host and confirm the boot LUN survives a reboot before rolling fleet-wide.

## References

- HPE VMware ESXi images: <https://www.hpe.com/us/en/servers/hpe-esxi.html>
- HPE Synergy OS support matrix: <https://support.hpe.com/docs/display/public/synergy-sw-release/OS_Support.html>
- HPE support for VMware ESXi images: <https://support.hpe.com/docs/display/public/synergy-sw-release/Vmware_HPE_ESXi_images.html>
- Broadcom KB 436480 (HPE Synergy custom image deprecation notice): <https://knowledge.broadcom.com/external/article/436480/notice-hpe-synergy-deprecating-delivery.html>
