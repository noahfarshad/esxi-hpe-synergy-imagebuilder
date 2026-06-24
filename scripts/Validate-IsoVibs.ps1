<#
.SYNOPSIS
    Validate that every VIB from the HPE AddOn depot made it into the combined image.

.DESCRIPTION
    After building a custom ISO, confirm all the HPE AddOn VIBs were merged. A
    silent partial merge is the worst failure mode: the ISO builds fine but is
    missing the very FC/storage driver that the Synergy blade needs to see its
    boot LUN, and you don't find out until the installer shows "no storage devices."

    This loads both source depots into a PowerCLI session, enumerates the AddOn's
    VIBs, and confirms each one is present in the combined VIB set.

.PARAMETER BaseDepot
    Path to the VMware base ESXi offline depot zip.

.PARAMETER AddonDepot
    Path to the HPE Synergy AddOn offline depot zip.

.EXAMPLE
    .\Validate-IsoVibs.ps1 `
        -BaseDepot "C:\iso\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
        -AddonDepot "C:\iso\HPE-900.0.0.12.3.5.5-Oct2025-Synergy-Addon-depot.zip"

.NOTES
    Author : Noah Farshad / essential.coach
    License : GPL-3.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BaseDepot,

    [Parameter(Mandatory = $true)]
    [string]$AddonDepot
)

$ErrorActionPreference = "Stop"

$BaseDepot  = (Resolve-Path $BaseDepot).Path
$AddonDepot = (Resolve-Path $AddonDepot).Path

Import-Module VMware.ImageBuilder

# ---------------------------------------------------------------------------
# Load both depots into the session
# ---------------------------------------------------------------------------
Write-Host "Loading depots..." -ForegroundColor Cyan
Add-EsxSoftwareDepot $BaseDepot   | Out-Null
Add-EsxSoftwareDepot $AddonDepot  | Out-Null

# ---------------------------------------------------------------------------
# Enumerate the AddOn's VIBs by reading the addon depot's index directly
# ---------------------------------------------------------------------------
$addonDepotSpec = "zip:$AddonDepot`?index.xml"

Write-Host ""
Write-Host "=== HPE AddOn VIBs ===" -ForegroundColor Cyan
$addonPackages = Get-EsxSoftwarePackage -SoftwareDepot $addonDepotSpec
$addonPackages | Format-Table Name, Version, Vendor -AutoSize

$addonVibs = $addonPackages.Name
$allVibs   = (Get-EsxSoftwarePackage).Name

# ---------------------------------------------------------------------------
# Compare: confirm each AddOn VIB exists in the combined set
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Merge validation ===" -ForegroundColor Cyan

$missing = @()
foreach ($vib in $addonVibs) {
    if ($vib -notin $allVibs) {
        Write-Host "  MISSING: $vib" -ForegroundColor Red
        $missing += $vib
    } else {
        Write-Host "  OK:      $vib" -ForegroundColor Green
    }
}

Write-Host ""
if ($missing.Count -eq 0) {
    Write-Host "All $($addonVibs.Count) AddOn VIBs are present in the combined image." -ForegroundColor Green
} else {
    Write-Host "$($missing.Count) of $($addonVibs.Count) AddOn VIBs are MISSING!" -ForegroundColor Red
    Write-Host "Do NOT deploy this ISO. Rebuild and re-validate." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Cleanup: remove depots from session
# ---------------------------------------------------------------------------
Remove-EsxSoftwareDepot $addonDepotSpec -ErrorAction SilentlyContinue
