# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`Build-VlcmBundle.ps1`** — builds a vLCM-compliant offline bundle via
  `New-OfflineBundle`, which emits the full depot descriptor (vendor block,
  content-type, productId, per-VIB metadata) that vSphere Lifecycle Manager
  requires. Auto-discovers base/AddOn versions from the depots. Use this when an
  `Export-EsxImageProfile` bundle fails to import into vLCM 9.x (Broadcom KB 424708).
- **`Build-VlcmComponentBundle.ps1`** — builds a vLCM-compliant bundle from a
  base depot + one or more standalone driver components (no vendor AddOn), for the
  common case of adding a single HCL-required driver to a stock base. Auto-unwraps
  HPE SoftPaqs (cp######.zip) to the inner offline bundle, and lets you pick which
  component(s) to include by VIB name. Verified at ESXi 9.1: builds, and the output
  matches a known-good 9.1 depot's descriptor structure; live vLCM 9.1 import pending.
- **`Inspect-BundleDeep.ps1`** — forensic comparison of two depots/bundles,
  including the contents of the nested metadata zip, with an attribute-presence
  matrix (vendor code/name, content-type, productId, checksums). Useful to confirm
  a bundle's structure matches a known-good depot before import.

### Notes

- The `New-OfflineBundle` output has been verified to match a known-good depot's
  descriptor structure at ESXi 9.0.2. The actual vLCM **9.1** import (where the
  `vcfVersion` attribute applies) is still being confirmed against a live vLCM 9.1
  environment.

## [1.1.0] - 2026-06-25

### Added

- **Dual output: ISO and/or offline ZIP bundle.** New `-OutputFormat Iso|Bundle|Both`
  parameter (default `Both`). The bundle is an offline depot ZIP for `esxcli` /
  Update Manager workflows. Note: for importing into vSphere Lifecycle Manager
  (vLCM), use `Build-VlcmBundle.ps1` — the `Export-EsxImageProfile` bundle this
  produces lacks the descriptor metadata vLCM 9.x requires (see Unreleased / KB 424708).
  Both ISO and bundle are exported from the same image profile in one run.
- **`-ExtraVibsFolder`** — add extra/optional VIBs from a folder on top of the
  base + AddOn. Designed to take a per-release folder from the companion
  [spp-esxi-vib-extractor](https://github.com/noahfarshad/spp-esxi-vib-extractor)
  (e.g. `esxi-9.0\`). Every `*.zip` in the folder is added and merged.
- **`-ExcludeVibs`** — remove specific VIBs by name from the final image (e.g. when
  an HCL check shows a driver isn't needed or isn't compatible on your hardware).
  Reports a clear message and guidance when a removal fails due to a dependency.
- **`-ProfileName` / `-Vendor`** — optional control over the cloned image profile
  name and vendor stamp.

### Changed

- **Reworked around the image-profile model.** The build now clones the base image
  profile, merges the AddOn (and any extra) packages, applies exclusions, then
  exports — replacing the previous one-shot `New-IsoImage` call. This is what makes
  the add/exclude/dual-export features possible. The PowerCLI session depots are
  cleaned up in a `finally` block so re-runs start fresh.
- Still PowerShell 5.1-compatible (no PS7-only syntax); requires PowerCLI /
  VMware.ImageBuilder with Python configured.

### Compatibility

- Existing callers: the script no longer takes `-SoftwareSpec`, and `-Destination`
  is now a path WITHOUT extension (the script appends `.iso`/`.zip`). See the updated
  examples in the script header and README. `Write-SoftwareSpec.ps1` remains for
  reference but is no longer required by the default build path.

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

[1.1.0]: https://github.com/noahfarshad/esxi-hpe-synergy-imagebuilder/releases/tag/v1.1.0
[1.0.1]: https://github.com/noahfarshad/esxi-hpe-synergy-imagebuilder/releases/tag/v1.0.1
[1.0.0]: https://github.com/noahfarshad/esxi-hpe-synergy-imagebuilder/releases/tag/v1.0.0
