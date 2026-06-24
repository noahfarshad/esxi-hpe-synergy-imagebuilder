<#
.SYNOPSIS
    Build a custom ESXi ISO that bundles a VMware base depot with an HPE Synergy
    AddOn depot using PowerCLI Image Builder.

.DESCRIPTION
    HPE has deprecated delivery of pre-built Synergy Custom ESXi Images beginning
    with HPE Synergy Service Pack (SSP) 2026.01.xx. The supported path forward is
    to take the VMware base ESXi image from Broadcom and combine it with the HPE
    drivers/management software delivered through the SSP / HPE AddOn depot.

    This script automates that combine using VMware.ImageBuilder. It was written
    to solve a real problem: the generic ESXi 9.0.2 ISO has no FC/storage drivers,
    so HPE Synergy blades booting from SAN see zero storage devices at install time.
    Combining the base depot with the HPE Synergy AddOn injects the QLogic/Marvell/
    Broadcom FC and storage drivers needed for the installer to see the boot LUN.

.PARAMETER BaseDepot
    Path to the VMware base ESXi offline depot zip
    (e.g. VMware-ESXi-9.0.2.0.25148076-depot.zip from the Broadcom patches portal).

.PARAMETER AddonDepot
    Path to the HPE Synergy AddOn offline depot zip
    (e.g. HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip from the HPE/Broadcom support portal).

.PARAMETER SoftwareSpec
    Path to the JSON software spec describing the base image version and AddOn name/version.
    See examples/synergy-custom.json.template. Must be UTF-8 WITHOUT BOM.

.PARAMETER Destination
    Output path for the generated ISO.

.PARAMETER AcceptanceLevel
    Optional. If New-IsoImage fails with an acceptance-level error, pass
    "PartnerSupported" (HPE VIBs are partner-signed, not VMware-certified).

.EXAMPLE
    .\Build-CustomEsxiIso.ps1 `
        -BaseDepot "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
        -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
        -SoftwareSpec "C:\iso\synergy-custom.json" `
        -Destination "C:\iso\VMware-ESX-9.0.2-HPE-Synergy-Custom.iso"

.NOTES
    Author : Noah Farshad / essential.coach
    License : GPL-3.0
    Tested  : ESXi 9.0.2-0.25148076 base + HPE-Custom-Syn-AddOn 900.0.0.12.3.5-5
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BaseDepot,

    [Parameter(Mandatory = $true)]
    [string]$AddonDepot,

    [Parameter(Mandatory = $true)]
    [string]$SoftwareSpec,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [Parameter(Mandatory = $false)]
    [ValidateSet("VMwareCertified", "VMwareAccepted", "PartnerSupported", "CommunitySupported")]
    [string]$AcceptanceLevel
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# PowerCLI resolves RELATIVE paths from the user profile dir, NOT the current
# working directory. Always resolve to absolute paths before passing to cmdlets.
# ---------------------------------------------------------------------------
$BaseDepot     = (Resolve-Path $BaseDepot).Path
$AddonDepot    = (Resolve-Path $AddonDepot).Path
$SoftwareSpec  = (Resolve-Path $SoftwareSpec).Path
# Destination may not exist yet; resolve its parent dir then re-append the filename.
$destDir       = (Resolve-Path (Split-Path $Destination -Parent)).Path
$Destination   = Join-Path $destDir (Split-Path $Destination -Leaf)

Write-Host "=== Build inputs ===" -ForegroundColor Cyan
Write-Host "  Base depot : $BaseDepot"
Write-Host "  AddOn depot: $AddonDepot"
Write-Host "  Spec       : $SoftwareSpec"
Write-Host "  Output     : $Destination"
Write-Host ""

# ---------------------------------------------------------------------------
# Step 0: Verify Image Builder module is available
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name VMware.ImageBuilder)) {
    Write-Error "VMware.ImageBuilder module not found. Install PowerCLI first:`n" +
                "  Install-Module -Name VMware.PowerCLI -Scope CurrentUser -AllowClobber"
    exit 1
}
Import-Module VMware.ImageBuilder

# ---------------------------------------------------------------------------
# Step 1: Report base image + addon versions (sanity echo before building)
# ---------------------------------------------------------------------------
Write-Host "=== Step 1: Querying depot metadata ===" -ForegroundColor Cyan

Write-Host "Base image versions:" -ForegroundColor Yellow
Get-DepotBaseImages $BaseDepot | Format-Table Version, ReleaseDate -AutoSize

Write-Host "AddOn details:" -ForegroundColor Yellow
Get-DepotAddons $AddonDepot | Format-Table Name, Version -AutoSize

# ---------------------------------------------------------------------------
# Step 2: Build the ISO
# ---------------------------------------------------------------------------
Write-Host "=== Step 2: Building ISO ===" -ForegroundColor Cyan

$isoArgs = @{
    SoftwareSpec = $SoftwareSpec
    Depots       = @($BaseDepot, $AddonDepot)
    Destination  = $Destination
}
if ($AcceptanceLevel) {
    $isoArgs.AcceptanceLevel = $AcceptanceLevel
    Write-Host "  Using acceptance level: $AcceptanceLevel" -ForegroundColor Yellow
}

New-IsoImage @isoArgs

if (Test-Path $Destination) {
    $sizeMB = [math]::Round((Get-Item $Destination).Length / 1MB, 1)
    Write-Host ""
    Write-Host "=== ISO built successfully ===" -ForegroundColor Green
    Write-Host "  $Destination ($sizeMB MB)" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next: validate the merge with Validate-IsoVibs.ps1 before deploying." -ForegroundColor Cyan
} else {
    Write-Error "New-IsoImage completed but the destination file is missing."
    exit 1
}
