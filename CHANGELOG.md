# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-06-24

### Changed

- **`docs/BUILD_GUIDE.md`** — Clarified the ESXi version-boundary rule: 8.0-and-older
  uses an "update" release boundary, 9.0-and-newer uses a stricter "minor" release
  boundary. A 9.0.x-validated AddOn on a 9.1 base crosses that boundary and is
  unsupported even though Image Builder will build it.
- Added guidance on validating the HCL by device ID (VID/DID/SVID/SSID) when near a
  version boundary, with the Synergy 3830C 16Gb FC HBA / ESXi 9.x example.
- Documented that HPE's direction is for driver components to ship inside the SSP
  rather than as standalone AddOn downloads, following the SSP 2026.01.02 deprecation.

## [1.0.0] - 2026-06-24

### Initial Release

PowerCLI Image Builder tooling to combine a VMware base ESXi depot with an HPE
Synergy AddOn depot into an installable custom ISO. Emerged from a real
boot-from-SAN HPE Synergy deployment where the generic ESXi 9.0.2 ISO showed
zero storage devices at install time.

### Added

- **`scripts/Build-CustomEsxiIso.ps1`** — Parameterized build script. Resolves
  absolute paths, queries base/AddOn versions, runs `New-IsoImage`, supports
  optional `-AcceptanceLevel PartnerSupported`.

- **`scripts/Validate-IsoVibs.ps1`** — Loads both source depots and confirms every
  VIB in the HPE AddOn is present in the combined image. Guards against silent
  partial merges that would leave a SAN-boot host unable to see its LUN.

- **`scripts/Write-SoftwareSpec.ps1`** — Writes the JSON software spec as UTF-8
  *without* a BOM via `[System.IO.File]::WriteAllText`, avoiding the most common
  `New-IsoImage` failure mode.

- **`scripts/post-install-validation.sh`** — Run on the ESXi host after install to
  confirm HPE drivers loaded and storage adapters / FC HBAs are visible.

- **`examples/synergy-custom.json.template`** — Software spec template.

- **`docs/BUILD_GUIDE.md`** — Full step-by-step: dependency setup (PowerCLI, Python,
  Python modules), build procedure, validation, gotchas, and references.

- **`docs/VIB_Reference.md`** — Documents the multi-vendor VIBs in the HPE Synergy
  AddOn (QLogic, Marvell, Broadcom, Microsemi, Intel, HPE) and explains why the FC
  drivers are essential for SAN boot. Includes the HPE 7.0 U3 `lpfc`/3530C HBA
  cautionary note.

### Tested Against

- VMware ESXi base image `9.0.2-0.25148076` (Broadcom patches portal)
- `HPE-Custom-Syn-AddOn` version `900.0.0.12.3.5-5` (HPE Synergy AddOn, Oct 2025)
- VMware.PowerCLI / VMware.ImageBuilder
- Python 3.12

### Context

Created for a federal services integrator's proof-of-concept upgrade where HPE had
not yet published a Synergy custom ISO for the required ESXi patch level. Published
with all customer-identifying information removed. The approach applies broadly to
any HPE Synergy boot-from-SAN environment, and is now the HPE-supported path forward
following the deprecation of pre-built Synergy custom ISOs (HPE Customer Notice
a00156316, SSP 2026.01.xx).

[1.0.1]: https://github.com/noahfarshad/esxi-hpe-synergy-imagebuilder/releases/tag/v1.0.1
[1.0.0]: https://github.com/noahfarshad/esxi-hpe-synergy-imagebuilder/releases/tag/v1.0.0
