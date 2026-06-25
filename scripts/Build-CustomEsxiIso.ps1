<#
.SYNOPSIS
    Build a custom ESXi image from a VMware base depot + an HPE Synergy AddOn
    depot, with optional extra VIBs and exclusions. Exports a bootable ISO and/or
    an offline ZIP bundle (for vSphere Lifecycle Manager import).

.DESCRIPTION
    HPE deprecated pre-built Synergy Custom ESXi Images beginning with HPE Synergy
    Service Pack (SSP) 2026.01.xx. The supported path forward is to take the VMware
    base ESXi image and combine it with the HPE drivers/management software from
    the SSP / HPE AddOn depot.

    This script automates that combine using VMware.ImageBuilder. The generic ESXi
    9.0.2 ISO has no FC/storage drivers, so HPE Synergy blades booting from SAN see
    zero storage devices at install time. Merging the base depot with the HPE
    Synergy AddOn injects the QLogic/Marvell/Broadcom FC and storage drivers the
    installer needs to see the boot LUN.

    v1.1.0 builds on a cloned image profile (rather than a one-shot New-IsoImage)
    so it can additionally:
      - export BOTH a bootable ISO and an offline ZIP bundle from one build
        (the bundle imports into a vSphere 9.x vLCM depot)
      - pull in extra/optional VIBs from a folder (e.g. the per-release folder the
        companion spp-esxi-vib-extractor produces)
      - exclude specific VIBs by name (e.g. when an HCL check shows a driver isn't
        needed or isn't compatible on your hardware)

.PARAMETER BaseDepot
    Path to the VMware base ESXi offline depot zip
    (e.g. VMware-ESXi-9.0.2.0.25148076-depot.zip from the Broadcom patches portal).

.PARAMETER AddonDepot
    Path to the HPE Synergy AddOn offline depot zip
    (e.g. HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip).

.PARAMETER Destination
    Output path for the generated artifact(s), WITHOUT extension
    (e.g. C:\iso\VMware-ESX-9.0.2-HPE-Synergy-Custom). The script appends .iso
    and/or .zip depending on -OutputFormat.

.PARAMETER OutputFormat
    Which artifact(s) to produce: Iso, Bundle, or Both. Default: Both.
      - Iso    : bootable installer ISO (fresh installs / SAN boot)
      - Bundle : offline depot ZIP (import into vSphere Lifecycle Manager)
      - Both   : both, from the same image profile (recommended)

.PARAMETER ExtraVibsFolder
    Optional. Path to a folder of additional offline bundles / VIBs to add on top
    of the base + AddOn (e.g. an esxi-9.0\ folder from spp-esxi-vib-extractor).
    Every *.zip in the folder is added as a software depot and all its packages
    are merged into the profile.

.PARAMETER ExcludeVibs
    Optional. One or more VIB names to remove from the final image
    (e.g. "qedf","qedi"). Removed AFTER the base/AddOn/extra packages are added.
    Dependency order matters -- if a removal fails because another VIB depends on
    it, exclude the dependent VIB too, or leave it in.

.PARAMETER ProfileName
    Optional. Name for the cloned image profile. Default: auto-generated from the
    base profile name + "-HPE-Synergy-Custom".

.PARAMETER Vendor
    Optional. Vendor string stamped on the image profile. Default: "essential.coach".

.PARAMETER AcceptanceLevel
    Optional. HPE VIBs are partner-signed. If the build complains about acceptance
    level, pass "PartnerSupported".

.EXAMPLE
    # The common case: build BOTH a bootable ISO and a vLCM offline bundle.
    .\Build-CustomEsxiIso.ps1 `
        -BaseDepot  "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
        -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
        -Destination "C:\iso\Synergy-9.0.2-Custom" `
        -AcceptanceLevel PartnerSupported

.EXAMPLE
    # Just the bootable ISO (fresh installs / SAN boot only).
    .\Build-CustomEsxiIso.ps1 `
        -BaseDepot  "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
        -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
        -Destination "C:\iso\Synergy-9.0.2-Custom" `
        -OutputFormat Iso `
        -AcceptanceLevel PartnerSupported

.EXAMPLE
    # Just the offline bundle, to import into vSphere Lifecycle Manager.
    .\Build-CustomEsxiIso.ps1 `
        -BaseDepot  "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
        -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
        -Destination "C:\iso\Synergy-9.0.2-lcm" `
        -OutputFormat Bundle `
        -AcceptanceLevel PartnerSupported

.EXAMPLE
    # Add extra drivers from a folder (e.g. spp-esxi-vib-extractor output).
    .\Build-CustomEsxiIso.ps1 `
        -BaseDepot  "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
        -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
        -ExtraVibsFolder "C:\spp-extract\esxi-9.0" `
        -Destination "C:\iso\Synergy-9.0.2-Custom" `
        -AcceptanceLevel PartnerSupported

.EXAMPLE
    # Exclude specific VIBs (e.g. an HCL check shows they aren't needed/compatible),
    # producing only the vLCM bundle.
    .\Build-CustomEsxiIso.ps1 `
        -BaseDepot  "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
        -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
        -ExcludeVibs "qedf","qedi" `
        -Destination "C:\iso\Synergy-9.0.2-lcm" `
        -OutputFormat Bundle `
        -AcceptanceLevel PartnerSupported

.NOTES
    Author  : Noah Farshad / essential.coach
    License : GPL-3.0
    Tested  : ESXi 9.0.2-0.25148076 base + HPE-Custom-Syn-AddOn 900.0.0.12.3.5-5
    Requires: VMware.PowerCLI (VMware.ImageBuilder) on PowerShell 5.1 or 7,
              with Python configured for ImageBuilder (Set-PowerCLIConfiguration -PythonPath).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BaseDepot,

    [Parameter(Mandatory = $true)]
    [string]$AddonDepot,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Iso", "Bundle", "Both")]
    [string]$OutputFormat = "Both",

    [Parameter(Mandatory = $false)]
    [string]$ExtraVibsFolder,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeVibs,

    [Parameter(Mandatory = $false)]
    [string]$ProfileName,

    [Parameter(Mandatory = $false)]
    [string]$Vendor = "essential.coach",

    [Parameter(Mandatory = $false)]
    [ValidateSet("VMwareCertified", "VMwareAccepted", "PartnerSupported", "CommunitySupported")]
    [string]$AcceptanceLevel
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# PowerCLI resolves RELATIVE paths from the user profile dir, NOT the current
# working directory. Always resolve to absolute paths before passing to cmdlets.
# ---------------------------------------------------------------------------
$BaseDepot  = (Resolve-Path $BaseDepot).Path
$AddonDepot = (Resolve-Path $AddonDepot).Path
if ($ExtraVibsFolder) {
    $ExtraVibsFolder = (Resolve-Path $ExtraVibsFolder).Path
}
# Destination is a path WITHOUT extension. Create its parent dir if needed, then
# resolve to absolute. (Split-Path returns '' when only a filename is given, in
# which case the parent is the current directory.)
$destParent = Split-Path $Destination -Parent
if ([string]::IsNullOrEmpty($destParent)) {
    $destParent = "."
}
if (-not (Test-Path $destParent)) {
    New-Item -ItemType Directory -Path $destParent -Force | Out-Null
}
$destDir  = (Resolve-Path $destParent).Path
$destLeaf = Split-Path $Destination -Leaf
$destBase = Join-Path $destDir $destLeaf
$isoPath    = "$destBase.iso"
$bundlePath = "$destBase.zip"

Write-Host "=== Build inputs ===" -ForegroundColor Cyan
Write-Host "  Base depot   : $BaseDepot"
Write-Host "  AddOn depot  : $AddonDepot"
if ($ExtraVibsFolder) { Write-Host "  Extra VIBs   : $ExtraVibsFolder" }
if ($ExcludeVibs)     { Write-Host "  Exclude VIBs : $($ExcludeVibs -join ', ')" }
Write-Host "  Output format: $OutputFormat"
Write-Host "  Output base  : $destBase"
Write-Host ""

# ---------------------------------------------------------------------------
# Step 0: Verify Image Builder module is available
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name VMware.ImageBuilder)) {
    Write-Error ("VMware.ImageBuilder module not found. Install PowerCLI first:`n" +
                 "  Install-Module -Name VMware.PowerCLI -Scope CurrentUser -AllowClobber")
    exit 1
}
Import-Module VMware.ImageBuilder

# Track the depot OBJECTS we add (not paths) so we can cleanly remove them at the
# end. Add-EsxSoftwareDepot returns a depot object that Remove-EsxSoftwareDepot
# accepts directly; trying to remove by file path fails ("could not be found in
# existing depots") because depots are registered under an internal URL.
$addedDepots = @()

function Add-DepotTracked {
    param([string]$Path)
    # Adding a depot that's already loaded in the session throws a confusing
    # "unequal values of the 'vibs' attribute" fault. That just means the depot
    # (or one with the same image-profile name) is already present -- which is
    # fine. Catch it and carry on rather than crashing the build.
    try {
        $depot = Add-EsxSoftwareDepot $Path -ErrorAction Stop
        $script:addedDepots += $depot
        return $depot
    } catch {
        if ($_.Exception.Message -match "unequal values|already" ) {
            Write-Host "    (depot already loaded in session -- skipping re-add)" -ForegroundColor DarkYellow
            return $null
        }
        throw
    }
}

try {
    # -----------------------------------------------------------------------
    # Step 1: Add the base + AddOn depots
    # -----------------------------------------------------------------------
    Write-Host "=== Step 1: Adding base + AddOn depots ===" -ForegroundColor Cyan
    Add-DepotTracked $BaseDepot | Out-Null
    Add-DepotTracked $AddonDepot | Out-Null

    # Echo the base image profiles (the read-only stock VMware ones we can clone).
    Write-Host "Base image profiles found:" -ForegroundColor Yellow
    $baseProfiles = Get-EsxImageProfile | Where-Object { $_.ReadOnly } | Sort-Object Name
    if (-not $baseProfiles) {
        # Fallback: if ReadOnly isn't populated, show all.
        $baseProfiles = Get-EsxImageProfile | Sort-Object Name
    }
    $baseProfiles | Format-Table Name, Vendor, @{N = "VIBs"; E = { $_.VibList.Count } } -AutoSize

    # -----------------------------------------------------------------------
    # Step 2: Pick the base profile to clone
    #   Prefer a "-standard" profile (has VMware Tools); fall back to the first.
    # -----------------------------------------------------------------------
    $sourceProfile = $baseProfiles | Where-Object { $_.Name -like "*-standard" } | Select-Object -First 1
    if (-not $sourceProfile) {
        $sourceProfile = $baseProfiles | Select-Object -First 1
    }
    if (-not $sourceProfile) {
        throw "No image profile found in the base depot. Is '$BaseDepot' a valid ESXi base depot?"
    }
    Write-Host "Cloning base profile: $($sourceProfile.Name)" -ForegroundColor Yellow

    if (-not $ProfileName) {
        $ProfileName = "$($sourceProfile.Name)-HPE-Synergy-Custom"
    }

    # Idempotency: if a profile with this name is already registered in the
    # session (e.g. left over from an interrupted previous run), remove it first
    # so the clone doesn't fail with "the name is already taken."
    $existing = Get-EsxImageProfile -Name $ProfileName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  (removing stale profile '$ProfileName' from session)" -ForegroundColor DarkYellow
        Remove-EsxImageProfile -ImageProfile $ProfileName -ErrorAction SilentlyContinue
    }

    # Clone so we never mutate the read-only stock profile.
    $null = New-EsxImageProfile -CloneProfile $sourceProfile.Name -Name $ProfileName -Vendor $Vendor
    if ($AcceptanceLevel) {
        Set-EsxImageProfile -ImageProfile $ProfileName -AcceptanceLevel $AcceptanceLevel | Out-Null
        Write-Host "  Acceptance level set to: $AcceptanceLevel" -ForegroundColor Yellow
    }

    # -----------------------------------------------------------------------
    # Step 3: Add the HPE AddOn packages to the profile
    #   Add-EsxSoftwarePackage replaces an existing VIB only if the incoming one
    #   is a different version. VIBs already present at the SAME version report
    #   "already in ImageProfile" -- that's expected (the base ESXi depot ships
    #   its own copy of some drivers), not an error. We surface those quietly and
    #   only flag genuine problems.
    # -----------------------------------------------------------------------
    Write-Host "=== Step 2: Merging HPE AddOn packages ===" -ForegroundColor Cyan
    $addonPkgs = Get-EsxSoftwarePackage -SoftwareDepot $AddonDepot |
        Sort-Object Name -Unique
    Write-Host "  $($addonPkgs.Count) AddOn package(s) to merge" -ForegroundColor Yellow
    $merged = 0; $already = 0
    foreach ($pkg in $addonPkgs) {
        try {
            Add-EsxSoftwarePackage -ImageProfile $ProfileName -SoftwarePackage $pkg -Force -ErrorAction Stop | Out-Null
            $merged++
        } catch {
            if ($_.Exception.Message -match "already in ImageProfile") {
                $already++
            } else {
                Write-Host "  ! skipped $($pkg.Name) $($pkg.Version): $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }
    }
    Write-Host "  merged: $merged, already present at same version: $already" -ForegroundColor Yellow

    # -----------------------------------------------------------------------
    # Step 4: Optionally add extra VIBs from a folder
    #   (e.g. an esxi-9.0\ folder from spp-esxi-vib-extractor)
    #
    #   CAUTION: VMware's guidance is to install VIBs from only ONE OEM vendor
    #   at a time. Mixing components from multiple OEMs in one image can produce
    #   a profile that builds without error but doesn't work. If your extra-VIBs
    #   folder spans more than one hardware vendor, split the builds.
    # -----------------------------------------------------------------------
    if ($ExtraVibsFolder) {
        Write-Host "=== Step 3: Adding extra VIBs from folder ===" -ForegroundColor Cyan
        Write-Host "  NOTE: keep extra VIBs to a single OEM vendor -- mixing OEMs can" -ForegroundColor DarkYellow
        Write-Host "        silently produce an image that builds but doesn't work." -ForegroundColor DarkYellow
        $extraZips = Get-ChildItem -Path $ExtraVibsFolder -Filter *.zip -File -Recurse
        if (-not $extraZips) {
            Write-Host "  (no *.zip found in $ExtraVibsFolder -- nothing to add)" -ForegroundColor DarkYellow
        }
        # The spp-esxi-vib-extractor copies whole source depots into its release
        # folders. If the base or AddOn depot itself shows up here, it's already
        # loaded -- skip it rather than re-adding the same depot.
        $alreadyLoadedNames = @(
            (Split-Path $BaseDepot -Leaf),
            (Split-Path $AddonDepot -Leaf)
        )
        $extraMerged = 0; $extraAlready = 0
        foreach ($zip in $extraZips) {
            if ($alreadyLoadedNames -contains $zip.Name) {
                Write-Host "  (skipping $($zip.Name) -- already loaded as base/AddOn depot)" -ForegroundColor DarkYellow
                continue
            }
            Write-Host "  + depot: $($zip.Name)" -ForegroundColor Yellow
            $added = Add-DepotTracked $zip.FullName
            if ($null -eq $added) { continue }  # depot was already loaded
            $extraPkgs = Get-EsxSoftwarePackage -SoftwareDepot $zip.FullName | Sort-Object Name -Unique
            foreach ($pkg in $extraPkgs) {
                try {
                    Add-EsxSoftwarePackage -ImageProfile $ProfileName -SoftwarePackage $pkg -Force -ErrorAction Stop | Out-Null
                    $extraMerged++
                } catch {
                    if ($_.Exception.Message -match "already in ImageProfile") {
                        $extraAlready++
                    } else {
                        Write-Host "    ! skipped $($pkg.Name) $($pkg.Version): $($_.Exception.Message)" -ForegroundColor DarkYellow
                    }
                }
            }
        }
        Write-Host "  extra merged: $extraMerged, already present: $extraAlready" -ForegroundColor Yellow
    }

    # -----------------------------------------------------------------------
    # Step 5: Optionally exclude specific VIBs (e.g. HCL says not needed/compatible)
    # -----------------------------------------------------------------------
    if ($ExcludeVibs) {
        Write-Host "=== Step 4: Excluding VIBs ===" -ForegroundColor Cyan
        foreach ($name in $ExcludeVibs) {
            $present = (Get-EsxImageProfile -Name $ProfileName).VibList |
                Where-Object { $_.Name -eq $name }
            if (-not $present) {
                Write-Host "  - $name (not in image -- nothing to remove)" -ForegroundColor DarkYellow
                continue
            }
            try {
                Remove-EsxSoftwarePackage -ImageProfile $ProfileName -SoftwarePackage $name -ErrorAction Stop | Out-Null
                Write-Host "  - removed $name" -ForegroundColor Yellow
            } catch {
                Write-Host "  ! could not remove $name (likely a dependency): $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "    If another VIB depends on it, exclude that one too, or leave $name in." -ForegroundColor DarkYellow
            }
        }
    }

    # Final VIB count for the record.
    $finalProfile = Get-EsxImageProfile -Name $ProfileName
    Write-Host ""
    Write-Host "Final image profile: $ProfileName ($($finalProfile.VibList.Count) VIBs)" -ForegroundColor Green

    # -----------------------------------------------------------------------
    # Step 6: Export -- ISO and/or offline bundle, from the SAME profile
    #   (Export-EsxImageProfile only allows one of -ExportToIso/-ExportToBundle
    #    per call, so "Both" is two calls.)
    # -----------------------------------------------------------------------
    Write-Host "=== Step 5: Exporting ===" -ForegroundColor Cyan
    # Note: acceptance level is a property of the image profile (set earlier via
    # Set-EsxImageProfile). Export-EsxImageProfile has no -AcceptanceLevel param,
    # so we do NOT pass it here.
    $exportArgs = @{ ImageProfile = $ProfileName; Force = $true }

    if ($OutputFormat -in @("Iso", "Both")) {
        Write-Host "  Exporting ISO -> $isoPath" -ForegroundColor Yellow
        Export-EsxImageProfile @exportArgs -ExportToIso -FilePath $isoPath
    }
    if ($OutputFormat -in @("Bundle", "Both")) {
        Write-Host "  Exporting bundle -> $bundlePath" -ForegroundColor Yellow
        Export-EsxImageProfile @exportArgs -ExportToBundle -FilePath $bundlePath
    }

    # -----------------------------------------------------------------------
    # Step 7: Report results
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== Build complete ===" -ForegroundColor Green
    if ($OutputFormat -in @("Iso", "Both") -and (Test-Path $isoPath)) {
        $isoMB = [math]::Round((Get-Item $isoPath).Length / 1MB, 1)
        Write-Host "  ISO    : $isoPath ($isoMB MB)" -ForegroundColor Green
    }
    if ($OutputFormat -in @("Bundle", "Both") -and (Test-Path $bundlePath)) {
        $zipMB = [math]::Round((Get-Item $bundlePath).Length / 1MB, 1)
        Write-Host "  Bundle : $bundlePath ($zipMB MB)" -ForegroundColor Green
        Write-Host "           Import this ZIP into vSphere Lifecycle Manager:" -ForegroundColor Cyan
        Write-Host "           Lifecycle Manager > Imported ISOs / Updates > Import" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "Next: validate the merge with Validate-IsoVibs.ps1 before deploying." -ForegroundColor Cyan
}
finally {
    # -----------------------------------------------------------------------
    # Always clean the PowerCLI session depots so re-runs start fresh.
    # Wrapped so a cleanup hiccup can never mask a successful build or a real
    # build error -- cleanup is best-effort only.
    # -----------------------------------------------------------------------
    foreach ($d in $addedDepots) {
        if ($null -ne $d) {
            try { Remove-EsxSoftwareDepot $d -ErrorAction SilentlyContinue } catch { }
        }
    }
}
