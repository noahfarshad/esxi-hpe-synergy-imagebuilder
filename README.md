# esxi-hpe-synergy-imagebuilder

Build a custom VMware ESXi ISO that bundles a VMware base depot with an HPE Synergy AddOn depot using PowerCLI Image Builder — so HPE Synergy compute modules booting from SAN can actually see their boot LUN at install time.

## The problem this solves

HPE Synergy blades in a boot-from-SAN configuration need Fibre Channel and storage drivers present in the ESXi installer. The generic VMware base ISO doesn't include them, so the installer enumerates **zero storage devices** and you can't pick an install target. The boot LUN is invisible.

Historically, HPE shipped pre-built "Synergy Custom" ESXi ISOs that bundled those drivers. Two things changed:

1. **HPE deprecated pre-built Synergy custom ISOs** beginning with HPE Synergy Service Pack (SSP) 2026.01.xx. The supported path forward is to combine the VMware base image with HPE drivers/management software yourself. (HPE Customer Notice a00156316.)
2. **A specific patch level you need may not have a matching pre-built image** — for example, when you need ESXi 9.0.2 specifically but no Synergy custom ISO exists for that exact build.

This repo automates the manual combine: VMware base depot + HPE Synergy AddOn depot → installable custom ISO with all the FC/storage drivers merged in.

## What's here

```
esxi-hpe-synergy-imagebuilder/
├── scripts/
│   ├── Build-CustomEsxiIso.ps1      # main build: combine depots → ISO
│   ├── Validate-IsoVibs.ps1         # confirm all AddOn VIBs merged
│   ├── Write-SoftwareSpec.ps1       # write the JSON spec WITHOUT a BOM
│   └── post-install-validation.sh   # run on the ESXi host after install
├── examples/
│   └── synergy-custom.json.template # software spec template
├── docs/
│   ├── BUILD_GUIDE.md               # full step-by-step walkthrough
│   └── VIB_Reference.md             # what's in the HPE AddOn + why FC matters
├── README.md
├── CHANGELOG.md
└── LICENSE
```

## Quick start

```powershell
# 1. Install PowerCLI + point it at Python (see docs/BUILD_GUIDE.md for Python setup)
Install-Module -Name VMware.PowerCLI -Scope CurrentUser -AllowClobber

# 2. Write the software spec (BOM-free)
.\scripts\Write-SoftwareSpec.ps1 `
    -OutFile "C:\iso\synergy-custom.json" `
    -BaseVersion "9.0.2-0.25148076" `
    -AddonName "HPE-Custom-Syn-AddOn" `
    -AddonVersion "900.0.0.12.3.5-5"

# 3. Build the ISO
.\scripts\Build-CustomEsxiIso.ps1 `
    -BaseDepot "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
    -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
    -SoftwareSpec "C:\iso\synergy-custom.json" `
    -Destination "C:\iso\VMware-ESX-9.0.2-HPE-Synergy-Custom.iso"

# 4. Validate every AddOn VIB merged before deploying
.\scripts\Validate-IsoVibs.ps1 `
    -BaseDepot "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
    -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip"
```

Full walkthrough with dependency setup, gotchas, and references: [docs/BUILD_GUIDE.md](docs/BUILD_GUIDE.md).

## You provide the depots

This repo does **not** redistribute VMware or HPE binaries. You download the two depot zips yourself (both require valid entitlement):

- **VMware base ESXi depot** — Broadcom patches portal
- **HPE Synergy AddOn depot** — HPE / Broadcom support portal

For current AddOn/base-image mappings: <https://www.hpe.com/us/en/servers/hpe-esxi.html>

## The biggest time-wasters (read these before you start)

- **JSON spec needs UTF-8 *without* BOM.** PowerShell's `Out-File` adds a BOM; `New-IsoImage` rejects it with a cryptic error. Use the `Write-SoftwareSpec.ps1` helper.
- **PowerCLI resolves relative paths from your user profile dir, not CWD.** Use absolute paths.
- **Acceptance-level error?** Add `-AcceptanceLevel PartnerSupported` (HPE VIBs are partner-signed).
- **FC driver version is load-bearing for SAN boot.** A custom image can drop support for a specific HBA across revisions. Test one host, confirm the boot LUN survives a reboot, then go fleet-wide.

## Disclaimer

Community tooling, not an HPE or Broadcom product. Validate support boundaries for your environment against HPE's official documentation before deploying to production. See [docs/BUILD_GUIDE.md](docs/BUILD_GUIDE.md) for the "what supported means" details.

## Story

The full background on why this exists and how it came together is written up at [essential.coach](https://essential.coach/custom-esxi-iso-hpe-synergy/).

## License

GPL-3.0. See [LICENSE](LICENSE).
