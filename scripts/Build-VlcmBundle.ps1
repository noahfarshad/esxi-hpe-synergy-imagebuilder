<#
.SYNOPSIS
    Build a vLCM-compliant offline bundle from a VMware base depot + an HPE
    Synergy AddOn depot, using New-OfflineBundle. Auto-discovers the version
    strings from the depots so you don't have to look them up.

.DESCRIPTION
    WHY THIS EXISTS
    ---------------
    A bundle produced by Export-EsxImageProfile -ExportToBundle builds fine but
    FAILS to import into vSphere Lifecycle Manager (vLCM) 9.x with:
        "A depot is inaccessible or has invalid contents..."

    Comparing a working depot against an Export-EsxImageProfile bundle shows the
    difference is structural: the working depot's index.xml carries a full vendor
    descriptor (vendor name + code + a <content><type>...depotmanagement/esx</type>
    declaration) and its vendor-index.xml declares productIds (embeddedEsx, esxio)
    and references a named, versioned metadata zip. The Export-EsxImageProfile
    bundle emits a thinner descriptor without those, so vLCM's import validator
    rejects it. (Aligns with Broadcom KB 424708 re: the vcfVersion attribute.)

    New-OfflineBundle is documented as creating a "vLCM-compliant offline bundle
    based on input depots and a software specification" -- it builds the full
    descriptor natively. This script uses it, and auto-discovers the base/AddOn
    versions from the depots so the call is as simple as pointing at two zips.

    SCOPE: This builds the BUNDLE only (for vLCM import). For a bootable ISO, use
    Build-CustomEsxiIso.ps1 -- its ISO path is unaffected by this vLCM issue.

    STATUS: Signature verified against VCF PowerCLI (New-OfflineBundle -Depots
    -SoftwareSpec -Destination -VendorName -VendorCode [-Overwrite]). Builds a 9.1
    bundle locally; the remaining validation is confirming the result imports into
    vLCM 9.1. The catch block prints the live cmdlet signature if it differs on
    other PowerCLI versions.

.PARAMETER BaseDepot
    Path to the VMware base ESXi offline depot zip.

.PARAMETER AddonDepot
    Path to the HPE Synergy AddOn offline depot zip.

.PARAMETER Destination
    Output path for the bundle zip (e.g. .\Synergy-9.1-lcm.zip).

.PARAMETER BaseVersion
    Optional. Override the auto-discovered base image version.

.PARAMETER AddonName
    Optional. Override the auto-discovered AddOn name.

.PARAMETER AddonVersion
    Optional. Override the auto-discovered AddOn version.

.PARAMETER KeepSpec
    Optional switch. Keep the generated software-spec JSON next to the output
    (default: written to a temp file and left in place for inspection).

.EXAMPLE
    # Simplest: point at the two depots, let it discover versions
    .\Build-VlcmBundle.ps1 `
        -BaseDepot  ".\VMware-ESXi-9.1.0.0100.25433460-depot.zip" `
        -AddonDepot ".\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip" `
        -Destination ".\Synergy-9.1-lcm.zip"

.NOTES
    Author  : Noah Farshad / essential.coach
    License : GPL-3.0
    Requires: VCF PowerCLI (VMware.ImageBuilder w/ New-OfflineBundle), Python
              configured for ImageBuilder. PowerShell 5.1 or 7.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string]$BaseDepot,
    [Parameter(Mandatory = $true)]  [string]$AddonDepot,
    [Parameter(Mandatory = $true)]  [string]$Destination,
    [Parameter(Mandatory = $false)] [string]$BaseVersion,
    [Parameter(Mandatory = $false)] [string]$AddonName,
    [Parameter(Mandatory = $false)] [string]$AddonVersion,
    [Parameter(Mandatory = $false)] [string]$VendorName = "essential.coach",
    [Parameter(Mandatory = $false)] [string]$VendorCode = "ess",
    [Parameter(Mandatory = $false)] [switch]$KeepSpec
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# New-OfflineBundle requires a vendor code of EXACTLY 3 alphanumeric characters
# (e.g. "vmw"). Validate up front with a clear message rather than failing late.
# ---------------------------------------------------------------------------
if ($VendorCode -notmatch '^[A-Za-z0-9]{3}$') {
    Write-Error ("VendorCode must be exactly 3 alphanumeric characters (e.g. 'vmw'). " +
                 "Got: '$VendorCode'. Pass a valid -VendorCode.")
    exit 1
}

# ---------------------------------------------------------------------------
# Resolve paths (PowerCLI resolves relative paths from the user profile dir).
# ---------------------------------------------------------------------------
$BaseDepot  = (Resolve-Path $BaseDepot).Path
$AddonDepot = (Resolve-Path $AddonDepot).Path

$destParent = Split-Path $Destination -Parent
if ([string]::IsNullOrEmpty($destParent)) { $destParent = "." }
if (-not (Test-Path $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
$destParent  = (Resolve-Path $destParent).Path
$Destination = Join-Path $destParent (Split-Path $Destination -Leaf)
$SpecFile    = Join-Path $destParent ("softwarespec-" + [System.IO.Path]::GetFileNameWithoutExtension($Destination) + ".json")

Write-Host "=== vLCM bundle build ===" -ForegroundColor Cyan
Write-Host "  Base depot  : $BaseDepot"
Write-Host "  AddOn depot : $AddonDepot"
Write-Host "  Destination : $Destination"
Write-Host "  Vendor      : $VendorName ($VendorCode)"
Write-Host ""

# ---------------------------------------------------------------------------
# Module + cmdlet availability
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name VMware.ImageBuilder)) {
    Write-Error ("VMware.ImageBuilder module not found. Install VCF PowerCLI first:`n" +
                 "  Install-Module -Name VCF.PowerCLI -Scope CurrentUser -AllowClobber")
    exit 1
}
Import-Module VMware.ImageBuilder

if (-not (Get-Command New-OfflineBundle -ErrorAction SilentlyContinue)) {
    Write-Error ("New-OfflineBundle not available in this PowerCLI version (needs 13.2+ / VCF PowerCLI).")
    exit 1
}

$addedDepots = @()
function Add-DepotTracked {
    param([string]$Path)
    try {
        $d = Add-EsxSoftwareDepot $Path -ErrorAction Stop
        $script:addedDepots += $d
        return $d
    } catch {
        if ($_.Exception.Message -match "unequal values|already") {
            Write-Host "    (depot already loaded -- continuing)" -ForegroundColor DarkYellow
            return $null
        }
        throw
    }
}

try {
    # -----------------------------------------------------------------------
    # Step 1: Add depots and AUTO-DISCOVER the version strings.
    # -----------------------------------------------------------------------
    Write-Host "=== Step 1: Reading depot metadata ===" -ForegroundColor Cyan
    Add-DepotTracked $BaseDepot  | Out-Null
    Add-DepotTracked $AddonDepot | Out-Null

    if (-not $BaseVersion) {
        $baseImg = Get-DepotBaseImages $BaseDepot | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $baseImg) { throw "Could not read a base image from '$BaseDepot'." }
        $BaseVersion = $baseImg.Version
    }
    if (-not $AddonName -or -not $AddonVersion) {
        $addon = Get-DepotAddons $AddonDepot | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $addon) { throw "Could not read an AddOn from '$AddonDepot'." }
        if (-not $AddonName)    { $AddonName    = $addon.Name }
        if (-not $AddonVersion) { $AddonVersion = $addon.Version }
    }

    Write-Host "  Base image version : $BaseVersion"  -ForegroundColor Yellow
    Write-Host "  AddOn              : $AddonName $AddonVersion" -ForegroundColor Yellow
    Write-Host ""

    # -----------------------------------------------------------------------
    # Step 2: Write the software spec (UTF-8, NO BOM -- the cmdlet rejects a BOM).
    # -----------------------------------------------------------------------
    Write-Host "=== Step 2: Writing software spec ===" -ForegroundColor Cyan
    $spec = @{
        base_image = @{ version = $BaseVersion }
        add_on     = @{ name = $AddonName; version = $AddonVersion }
    }
    $json = $spec | ConvertTo-Json -Depth 5
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($SpecFile, $json, $utf8NoBom)
    Write-Host "  $SpecFile" -ForegroundColor Green
    Get-Content $SpecFile | ForEach-Object { Write-Host "    $_" }
    Write-Host ""

    # -----------------------------------------------------------------------
    # Step 3: Build the vLCM-compliant bundle via New-OfflineBundle.
    #   Verified signature: -Depots -SoftwareSpec -Destination -VendorName
    #   -VendorCode [-Overwrite] [-NoSignatureCheck]. VendorName/VendorCode are
    #   what populate the vendor descriptor block in index.xml that vLCM requires
    #   (the exact block the Export-EsxImageProfile bundle was missing). The catch
    #   block still prints the live signature if anything differs across versions.
    # -----------------------------------------------------------------------
    Write-Host "=== Step 3: New-OfflineBundle ===" -ForegroundColor Cyan
    $bundleArgs = @{
        SoftwareSpec = $SpecFile
        Depots       = @($BaseDepot, $AddonDepot)
        Destination  = $Destination
        VendorName   = $VendorName
        VendorCode   = $VendorCode
        Overwrite    = $true
    }

    try {
        New-OfflineBundle @bundleArgs
    }
    catch {
        Write-Host ""
        # Friendly handling for the common base/AddOn version-mismatch case.
        if ($_.Exception.Message -match "does not support base image") {
            Write-Host "Base / AddOn version mismatch:" -ForegroundColor Red
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ""
            Write-Host "The HPE AddOn you supplied is validated for a different ESXi base than" -ForegroundColor Yellow
            Write-Host "the one in -BaseDepot. New-OfflineBundle enforces this (which is part of" -ForegroundColor Yellow
            Write-Host "why its output is vLCM-valid). Pair a base + AddOn that match:" -ForegroundColor Yellow
            Write-Host "  - 9.0.x base  <-> 900-series Synergy AddOn" -ForegroundColor Yellow
            Write-Host "  - 9.1.x base  <-> 910-series Synergy AddOn" -ForegroundColor Yellow
            Write-Host "Check HPE's current base/AddOn mapping: https://www.hpe.com/us/en/servers/hpe-esxi.html" -ForegroundColor Yellow
            exit 3
        }
        Write-Host "New-OfflineBundle failed with the assumed parameters." -ForegroundColor Yellow
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "--- New-OfflineBundle ACTUAL parameters (this PowerCLI build) ---" -ForegroundColor Cyan
        (Get-Command New-OfflineBundle).Parameters.Keys |
            Where-Object { $_ -notin @(
                "Verbose","Debug","ErrorAction","WarningAction","InformationAction",
                "ErrorVariable","WarningVariable","InformationVariable","OutVariable",
                "OutBuffer","PipelineVariable","WhatIf","Confirm","ProgressAction") } |
            ForEach-Object { Write-Host "    -$_" }
        Write-Host ""
        Write-Host "Full syntax:" -ForegroundColor Cyan
        Get-Command New-OfflineBundle -Syntax
        Write-Host ""
        Write-Host "Send that parameter list back and the call can be corrected exactly." -ForegroundColor Cyan
        exit 2
    }

    # -----------------------------------------------------------------------
    # Step 4: Report
    # -----------------------------------------------------------------------
    if (Test-Path $Destination) {
        $sizeMB = [math]::Round((Get-Item $Destination).Length / 1MB, 1)
        Write-Host ""
        Write-Host "=== vLCM-compliant bundle built ===" -ForegroundColor Green
        Write-Host "  $Destination ($sizeMB MB)" -ForegroundColor Green
        Write-Host ""
        Write-Host "Import into vSphere Lifecycle Manager:" -ForegroundColor Cyan
        Write-Host "  Lifecycle Manager > Imported ISOs / Updates > Import Updates > from ZIP" -ForegroundColor Cyan
        if (-not $KeepSpec) {
            Write-Host ""
            Write-Host "(software spec left at $SpecFile for reference)" -ForegroundColor DarkYellow
        }
    } else {
        Write-Error "New-OfflineBundle completed but the destination file is missing."
        exit 1
    }
}
finally {
    foreach ($d in $addedDepots) {
        if ($null -ne $d) { try { Remove-EsxSoftwareDepot $d -ErrorAction SilentlyContinue } catch { } }
    }
}
