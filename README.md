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
│   ├── Build-CustomEsxiIso.ps1      # main build: combine depots → ISO and/or bundle
│   ├── Build-VlcmBundle.ps1         # vLCM-compliant bundle via New-OfflineBundle
│   ├── Build-VlcmComponentBundle.ps1 # vLCM bundle: base + a standalone driver component
│   ├── Inspect-BundleDeep.ps1       # forensic compare of two depots (descriptor + metadata)
│   ├── Validate-IsoVibs.ps1         # confirm all AddOn VIBs merged
│   ├── Write-SoftwareSpec.ps1       # (optional) write a BOM-free JSON spec
│   └── post-install-validation.sh   # run on the ESXi host after install
├── examples/
│   └── synergy-custom.json.template # software spec template (optional path)
├── docs/
│   ├── BUILD_GUIDE.md               # full step-by-step walkthrough
│   └── VIB_Reference.md             # what's in the HPE AddOn + why FC matters
├── README.md
├── CHANGELOG.md
└── LICENSE
```

## Quick start

**One-time setup** — install PowerCLI and point it at Python (Image Builder needs it):

```powershell
Install-Module -Name VMware.PowerCLI -Scope CurrentUser -AllowClobber
# See docs/BUILD_GUIDE.md for the one-line Python path config Image Builder requires.
```

Then pick the example that matches what you need. Every example uses the same two depot zips you provide (see "You provide the depots" below). `-Destination` is a path **without** an extension — the script adds `.iso` and/or `.zip` for you.

**1. The common case — build both a bootable ISO and a vLCM bundle:**

```powershell
.\scripts\Build-CustomEsxiIso.ps1 `
    -BaseDepot  "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
    -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
    -Destination "C:\iso\Synergy-9.0.2-Custom" `
    -AcceptanceLevel PartnerSupported
```

Produces `Synergy-9.0.2-Custom.iso` (boot it to install) **and** `Synergy-9.0.2-Custom.zip` (import into vSphere Lifecycle Manager).

**2. Just the bootable ISO** (fresh installs / SAN boot only):

```powershell
.\scripts\Build-CustomEsxiIso.ps1 `
    -BaseDepot  "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
    -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
    -Destination "C:\iso\Synergy-9.0.2-Custom" `
    -OutputFormat Iso `
    -AcceptanceLevel PartnerSupported
```

**3. Just the offline bundle** (for importing into vLCM, no ISO):

```powershell
.\scripts\Build-CustomEsxiIso.ps1 `
    -BaseDepot  "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
    -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
    -Destination "C:\iso\Synergy-9.0.2-lcm" `
    -OutputFormat Bundle `
    -AcceptanceLevel PartnerSupported
```

**4. Add extra drivers from an SPP** (using the companion [spp-esxi-vib-extractor](https://github.com/noahfarshad/spp-esxi-vib-extractor) output):

```powershell
.\scripts\Build-CustomEsxiIso.ps1 `
    -BaseDepot  "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
    -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
    -ExtraVibsFolder "C:\spp-extract\esxi-9.0" `
    -Destination "C:\iso\Synergy-9.0.2-Custom" `
    -AcceptanceLevel PartnerSupported
```

`-ExtraVibsFolder` adds every `*.zip` offline bundle in that folder. Keep extra VIBs to a **single OEM vendor** — mixing vendors can silently produce an image that builds but doesn't work.

**5. Exclude specific VIBs** (e.g. an HCL check shows a driver isn't needed or compatible):

```powershell
.\scripts\Build-CustomEsxiIso.ps1 `
    -BaseDepot  "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
    -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
    -ExcludeVibs "qedf","qedi" `
    -Destination "C:\iso\Synergy-9.0.2-Custom" `
    -AcceptanceLevel PartnerSupported
```

Removes the named VIBs by name. If a removal fails because another VIB depends on it, the script tells you which — exclude the dependent one too, or leave it in.

**6. Validate the merge** before you deploy (always do this):

```powershell
.\scripts\Validate-IsoVibs.ps1 `
    -BaseDepot  "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
    -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip"
```

### Parameter reference

| Parameter | Required | What it does |
|---|---|---|
| `-BaseDepot` | yes | Path to the VMware base ESXi depot zip |
| `-AddonDepot` | yes | Path to the HPE Synergy AddOn depot zip |
| `-Destination` | yes | Output path **without** extension; script adds `.iso`/`.zip` |
| `-OutputFormat` | no | `Iso`, `Bundle`, or `Both` (default `Both`) |
| `-ExtraVibsFolder` | no | Folder of extra offline-bundle zips to add (single OEM) |
| `-ExcludeVibs` | no | One or more VIB names to remove, e.g. `"qedf","qedi"` |
| `-AcceptanceLevel` | no | Use `PartnerSupported` for HPE's partner-signed VIBs |
| `-ProfileName` | no | Custom image-profile name (auto-generated otherwise) |
| `-Vendor` | no | Vendor stamp on the profile (default `essential.coach`) |

Full walkthrough with dependency setup, gotchas, and references: [docs/BUILD_GUIDE.md](docs/BUILD_GUIDE.md).

## vSphere Lifecycle Manager (vLCM) bundles — read this before importing

There are two kinds of "offline bundle," and they are not interchangeable:

- **An esxcli / Update Manager depot** — what `Build-CustomEsxiIso.ps1 -OutputFormat Bundle` produces (via `Export-EsxImageProfile`). Fine for `esxcli software` installs and classic Update Manager.
- **A vLCM-importable depot** — what vSphere Lifecycle Manager's image management requires. This carries a fuller depot descriptor (vendor block, content-type, productId entries, and per-component metadata) that `Export-EsxImageProfile` does **not** emit.

If you import an `Export-EsxImageProfile` bundle into vLCM (especially on 9.x) you may hit:

> A depot is inaccessible or has invalid contents. Make sure an official depot source is used...

This is a known limitation (see Broadcom KB 424708 re: the `vcfVersion` attribute on recent 9.x depots). The fix is to build the bundle with `New-OfflineBundle`, which generates the full vLCM descriptor from depots + a software spec.

### `Build-VlcmBundle.ps1` — the vLCM-compliant path

```powershell
# Auto-discovers base/AddOn versions from the depots; just point at the two zips.
.\scripts\Build-VlcmBundle.ps1 `
    -BaseDepot  ".\VMware-ESXi-9.1.0...-depot.zip" `
    -AddonDepot ".\HPE-910...-Synergy-Addon-depot.zip" `
    -Destination ".\Synergy-9.1-lcm.zip"
```

The base and AddOn must be a **matched pair** (a 9.1 base needs the 910-series AddOn, not 900); `New-OfflineBundle` enforces this and the script reports a clear message if they don't match. You can override the vendor stamp with `-VendorName` / `-VendorCode` (the code must be exactly 3 alphanumeric characters, e.g. `ess`).

> **Validation status:** the output has been verified to match a known-good depot's descriptor structure (vendor block, content-type, productId, per-VIB SHA-256 checksums) at ESXi 9.0.2. The actual vLCM **9.1** import — where the `vcfVersion` attribute applies — is still being confirmed against a live vLCM 9.1 environment. Use `scripts/Inspect-BundleDeep.ps1` to compare your bundle against a known-good depot and confirm the structure on your version.

### Add a single driver to a stock base — `Build-VlcmComponentBundle.ps1`

Common case: the base image already has every driver you need *except one* (e.g. an HCL check flags a NIC driver that isn't inbox). You don't need a full vendor AddOn — just the base plus that one driver component, as a vLCM-importable bundle.

```powershell
# Point at the base + an HPE driver SoftPaq (cp######.zip); name the driver you need.
.\scripts\Build-VlcmComponentBundle.ps1 `
    -BaseDepot ".\VMware-ESXi-9.1.0...-depot.zip" `
    -ComponentDepot ".\cp068895.zip" `
    -IncludeComponents "qedentv" `
    -Destination ".\esxi-9.1-plus-qedentv.zip"
```

- **HPE SoftPaq auto-unwrap:** HPE `cp######.zip` driver downloads wrap the real offline bundle in a nested zip. Point `-ComponentDepot` at the outer SoftPaq and the script finds and uses the inner depot.
- **Components vs VIBs:** a *component* is a bundle of VIBs. `cp068895` ships one component (`MRVL-E4-CNA-Driver-Bundle`) carrying four VIBs (`qedentv`, `qedf`, `qedi`, `qedrntv`). `-IncludeComponents "qedentv"` matches the VIB name and pulls in the component that contains it — so the three sibling VIBs come along too. You include/exclude whole components, not individual VIBs.
- Omit `-IncludeComponents` to include every component in the driver depot.

> **Validation status:** verified to build, and the output matches a known-good ESXi 9.1 base depot's descriptor structure on every measured attribute (vendor block, content-type, productId, softwareSpec, per-VIB SHA-256 checksums). A driver built for the 9.0 OEM line was accepted onto a 9.1 base (the base component declares both 9.0 and 9.1 platform support). The actual vLCM **9.1 import** is still being confirmed against a live environment. Verify your own output with `scripts/Inspect-BundleDeep.ps1` against a known-good depot.

### Already have a stock image?

HPE publishes prebuilt ProLiant/Synergy custom images **and** vLCM offline bundles on the Broadcom portal. If you need the **stock** HPE image (no exclusions or extra drivers), download that bundle and import it directly — no build required. This tool is for when you need a **custom** image.

For a single extra driver, you can also skip the build entirely: import the driver `cp######.zip` directly in **Lifecycle Manager → Actions → Import Updates**, then add the component to the cluster image and compose. For a POC that's often the simplest path.

## You provide the depots

This repo does **not** redistribute VMware or HPE binaries. You download the two depot zips yourself (both require valid entitlement):

- **VMware base ESXi depot** — Broadcom patches portal
- **HPE Synergy AddOn depot** — HPE / Broadcom support portal

For current AddOn/base-image mappings: <https://www.hpe.com/us/en/servers/hpe-esxi.html>

## The biggest time-wasters (read these before you start)

- **PowerCLI needs Python for Image Builder.** If you see "Could not initialize the VMware.ImageBuilder PowerCLI module," set the Python path once with `Set-PowerCLIConfiguration -PythonPath`. See [docs/BUILD_GUIDE.md](docs/BUILD_GUIDE.md).
- **PowerCLI resolves relative paths from your user profile dir, not CWD.** The script resolves everything to absolute paths for you, but if you call the cmdlets directly, use absolute paths.
- **Acceptance-level error?** Add `-AcceptanceLevel PartnerSupported` (HPE VIBs are partner-signed, not VMware-certified).
- **Mixing OEM vendors in `-ExtraVibsFolder`** can silently produce an image that builds but doesn't work. Keep extra VIBs to one hardware vendor per build.
- **FC driver version is load-bearing for SAN boot.** A custom image can drop support for a specific HBA across revisions. Test one host, confirm the boot LUN survives a reboot, then go fleet-wide.

## Disclaimer

Community tooling, not an HPE or Broadcom product. Validate support boundaries for your environment against HPE's official documentation before deploying to production. See [docs/BUILD_GUIDE.md](docs/BUILD_GUIDE.md) for the "what supported means" details.

## Companion tool: getting the drivers out of the SPP

This repo merges a VMware base depot with HPE driver content into an ISO — but with HPE retiring standalone AddOn depots, those drivers increasingly live inside the HPE Service Pack (SPP), mixed in with every other OS and with no per-release grouping in the SPP content list.

[**spp-esxi-vib-extractor**](https://github.com/noahfarshad/spp-esxi-vib-extractor) is the front-half of the workflow: point it at an extracted SPP and it pulls out the ESXi VIBs, groups them by release (`esxi-9.0/`, `esxi-8.0/`, …), and emits a manifest with the OS-release column the SPP report lacks. Feed its grouped output straight into the build script here.

```
HPE SPP ──► spp-esxi-vib-extractor ──► grouped VIBs by release ──► (this repo) ──► custom ESXi ISO
```

## Story

The full background on why this exists and how it came together is written up at [essential.coach](https://essential.coach/custom-esxi-iso-hpe-synergy/).

## License

GPL-3.0. See [LICENSE](LICENSE).
