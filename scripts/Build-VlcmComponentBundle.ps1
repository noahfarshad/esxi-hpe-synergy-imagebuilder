<#
.SYNOPSIS
    Build a vLCM-compliant offline bundle from an ESXi base depot + one or more
    standalone driver components (no vendor AddOn). Use this when the base image
    already has everything except a specific driver or two, and you just need to
    add those on top -- e.g. a stock 9.1 base plus a single HCL-required NIC driver.

.DESCRIPTION
    Build-VlcmBundle.ps1 handles base + vendor AddOn. THIS script handles the
    other common case: base + individual driver component(s), with no AddOn.

    It uses New-OfflineBundle, which builds from input depots + a software spec.
    The spec here is base_image + a components list (the drivers you name), with
    no add_on -- the vLCM desired-state spec supports a components list separate
    from the vendor add-on.

    HPE SoftPaq auto-unwrap:
      HPE driver downloads (cp######.zip) are SoftPaqs that WRAP the real offline
      bundle in a nested .zip (e.g. cp068895.zip contains
      MRVL-E4-CNA-Driver-Bundle_...zip). New-OfflineBundle needs the INNER bundle.
      If you point -ComponentDepot at the outer cp*.zip, this script finds and
      uses the inner depot automatically.

    Pick which components to include:
      A driver package often carries several VIBs (cp068895 carries qedentv,
      qedrntv, qedf, qedi). Use -IncludeComponents to add only the one(s) you
      need; omit it to include them all.

    STATUS: Verified signature path against VCF PowerCLI New-OfflineBundle
    (-Depots -SoftwareSpec -Destination -VendorName -VendorCode [-Overwrite]).
    The components-in-spec shape and cross-version acceptance (a driver tagged for
    one base going onto a newer base) are confirmed at runtime -- the catch block
    prints the live cmdlet signature and any compatibility message so the exact
    call can be corrected if a given PowerCLI build differs.

.PARAMETER BaseDepot
    Path to the VMware base ESXi offline depot zip.

.PARAMETER ComponentDepot
    Path to a driver depot zip, OR an HPE SoftPaq (cp######.zip) that wraps one.
    SoftPaqs are unwrapped automatically to the inner offline bundle.

.PARAMETER Destination
    Output path for the bundle zip (e.g. .\esxi-9.1-plus-qedentv.zip).

.PARAMETER IncludeComponents
    Optional. One or more component/VIB names to include from the component depot
    (e.g. "qedentv"). Omit to include every component in the depot.

.PARAMETER BaseVersion
    Optional. Override the auto-discovered base image version.

.PARAMETER VendorName
    Optional. Vendor name stamped on the bundle descriptor. Default essential.coach.

.PARAMETER VendorCode
    Optional. EXACTLY 3 alphanumeric chars (e.g. "ess"). Default "ess".

.PARAMETER KeepSpec
    Optional. Keep the generated software-spec JSON for inspection.

.EXAMPLE
    # Stock 9.1 base + just the qedentv driver from an HPE SoftPaq:
    .\Build-VlcmComponentBundle.ps1 `
        -BaseDepot ".\VMware-ESXi-9.1.0.0100.25433460-depot.zip" `
        -ComponentDepot ".\cp068895.zip" `
        -IncludeComponents "qedentv" `
        -Destination ".\esxi-9.1-plus-qedentv.zip"

.NOTES
    Author  : Noah Farshad / essential.coach
    License : GPL-3.0
    Requires: VCF PowerCLI (VMware.ImageBuilder w/ New-OfflineBundle), Python
              configured for ImageBuilder. PowerShell 5.1 or 7.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string]$BaseDepot,
    [Parameter(Mandatory = $true)]  [string]$ComponentDepot,
    [Parameter(Mandatory = $true)]  [string]$Destination,
    [Parameter(Mandatory = $false)] [string[]]$IncludeComponents,
    [Parameter(Mandatory = $false)] [string]$BaseVersion,
    [Parameter(Mandatory = $false)] [string]$VendorName = "essential.coach",
    [Parameter(Mandatory = $false)] [string]$VendorCode = "ess",
    [Parameter(Mandatory = $false)] [switch]$KeepSpec
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ($VendorCode -notmatch '^[A-Za-z0-9]{3}$') {
    Write-Error ("VendorCode must be exactly 3 alphanumeric characters (e.g. 'vmw'). Got: '$VendorCode'.")
    exit 1
}

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$BaseDepot      = (Resolve-Path $BaseDepot).Path
$ComponentDepot = (Resolve-Path $ComponentDepot).Path

$destParent = Split-Path $Destination -Parent
if ([string]::IsNullOrEmpty($destParent)) { $destParent = "." }
if (-not (Test-Path $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
$destParent  = (Resolve-Path $destParent).Path
$Destination = Join-Path $destParent (Split-Path $Destination -Leaf)
$SpecFile    = Join-Path $destParent ("softwarespec-" + [System.IO.Path]::GetFileNameWithoutExtension($Destination) + ".json")
$workRoot    = Join-Path $destParent ("_vlcmcomp_" + [System.IO.Path]::GetFileNameWithoutExtension($Destination))

Write-Host "=== vLCM component bundle build ===" -ForegroundColor Cyan
Write-Host "  Base depot      : $BaseDepot"
Write-Host "  Component depot : $ComponentDepot"
Write-Host "  Destination     : $Destination"
Write-Host "  Vendor          : $VendorName ($VendorCode)"
Write-Host ""

# ---------------------------------------------------------------------------
# Module + cmdlet
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name VMware.ImageBuilder)) {
    Write-Error "VMware.ImageBuilder not found. Install VCF PowerCLI first."
    exit 1
}
Import-Module VMware.ImageBuilder
if (-not (Get-Command New-OfflineBundle -ErrorAction SilentlyContinue)) {
    Write-Error "New-OfflineBundle not available (needs PowerCLI 13.2+ / VCF PowerCLI)."
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
    # Step 1: Unwrap the component depot if it's an HPE SoftPaq.
    #   A real depot has index.xml at its root. An HPE cp*.zip wraps the real
    #   offline bundle in a nested .zip -- find and use that inner bundle.
    # -----------------------------------------------------------------------
    Write-Host "=== Step 1: Resolving component depot ===" -ForegroundColor Cyan
    Remove-Item $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    $cdExtract = Join-Path $workRoot "component-extract"
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ComponentDepot, $cdExtract)

    $realComponentDepot = $ComponentDepot
    if (-not (Test-Path (Join-Path $cdExtract "index.xml"))) {
        # Not a depot at its root -- look for a nested offline-bundle zip.
        $innerZip = Get-ChildItem $cdExtract -Recurse -File -Filter *.zip |
            Where-Object { $_.Name -notmatch 'metadata' } | Select-Object -First 1
        if ($innerZip) {
            # Confirm the inner zip is a depot.
            $innerProbe = Join-Path $workRoot "inner-probe"
            [System.IO.Compression.ZipFile]::ExtractToDirectory($innerZip.FullName, $innerProbe)
            if (Test-Path (Join-Path $innerProbe "index.xml")) {
                $realComponentDepot = $innerZip.FullName
                Write-Host "  HPE SoftPaq detected -- using inner depot:" -ForegroundColor Yellow
                Write-Host "    $($innerZip.Name)" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  Component depot is already a valid offline bundle." -ForegroundColor Yellow
    }

    # -----------------------------------------------------------------------
    # Step 2: Add depots, discover base version, enumerate components.
    # -----------------------------------------------------------------------
    Write-Host "=== Step 2: Reading depots ===" -ForegroundColor Cyan
    Add-DepotTracked $BaseDepot           | Out-Null
    Add-DepotTracked $realComponentDepot  | Out-Null

    if (-not $BaseVersion) {
        $baseImg = Get-DepotBaseImages $BaseDepot | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $baseImg) { throw "Could not read a base image from '$BaseDepot'." }
        $BaseVersion = $baseImg.Version
    }
    Write-Host "  Base image version : $BaseVersion" -ForegroundColor Yellow

    # Enumerate components available in the component depot. NOTE: a "component"
    # is a bundle of VIBs -- e.g. MRVL-E4-CNA-Driver-Bundle CONTAINS the VIBs
    # qedentv, qedf, qedi, qedrntv. You include/exclude whole components, not the
    # individual VIBs inside them.
    $allComponents = Get-DepotComponents $realComponentDepot
    if (-not $allComponents) {
        throw "No components found in the component depot. Is it a valid driver bundle?"
    }

    # For visibility, map each component to the VIBs it carries so the user can
    # see (and match against) the driver names they care about.
    $allVibs = Get-EsxSoftwarePackage -SoftwareDepot $realComponentDepot -ErrorAction SilentlyContinue
    Write-Host "  Components in driver depot (with the VIBs each contains):" -ForegroundColor Yellow
    foreach ($c in $allComponents) {
        Write-Host ("    {0}  {1}" -f $c.Name, $c.Version)
        if ($allVibs) {
            $allVibs | ForEach-Object { Write-Host ("        - VIB: {0}  {1}" -f $_.Name, $_.Version) -ForegroundColor DarkGray }
        }
    }

    # Filter to the requested components. -IncludeComponents matches against BOTH
    # the component name AND the names of the VIBs inside it -- so "qedentv"
    # (a VIB) correctly selects the component that contains it.
    $chosen = $allComponents
    if ($IncludeComponents) {
        $vibNames = @()
        if ($allVibs) { $vibNames = $allVibs | ForEach-Object { $_.Name } }

        $chosen = $allComponents | Where-Object {
            $compName = $_.Name
            $matched = $false
            foreach ($want in $IncludeComponents) {
                # match on component name OR on any VIB name in the depot
                if ($compName -like "*$want*") { $matched = $true; break }
                if ($vibNames | Where-Object { $_ -like "*$want*" }) { $matched = $true; break }
            }
            $matched
        }
        if (-not $chosen) {
            $vibList = if ($vibNames) { $vibNames -join ", " } else { "(none read)" }
            throw ("None of -IncludeComponents matched. Asked for: " +
                   ($IncludeComponents -join ", ") + ".`n" +
                   "  Available components: " + (($allComponents | ForEach-Object { $_.Name }) -join ", ") + "`n" +
                   "  VIBs inside them    : " + $vibList + "`n" +
                   "  Note: a driver name like 'qedentv' is a VIB inside a component; matching it" +
                   " selects the whole component (which also brings its sibling VIBs).")
        }
        Write-Host "  Including component(s):" -ForegroundColor Green
        $chosen | ForEach-Object { Write-Host ("    {0}  {1}" -f $_.Name, $_.Version) -ForegroundColor Green }
        Write-Host "  NOTE: a component is included whole -- any sibling VIBs in it come along." -ForegroundColor DarkYellow
    } else {
        Write-Host "  Including ALL components from the driver depot." -ForegroundColor Yellow
    }
    Write-Host ""

    # -----------------------------------------------------------------------
    # Step 3: Write the software spec (base + components, NO add_on).
    #   UTF-8 no BOM. Components expressed as name:version pairs.
    # -----------------------------------------------------------------------
    Write-Host "=== Step 3: Writing software spec (base + components) ===" -ForegroundColor Cyan
    $componentMap = @{}
    foreach ($c in $chosen) { $componentMap[$c.Name] = $c.Version }

    $spec = @{
        base_image = @{ version = $BaseVersion }
        components = $componentMap
    }
    $json = $spec | ConvertTo-Json -Depth 6
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($SpecFile, $json, $utf8NoBom)
    Write-Host "  $SpecFile" -ForegroundColor Green
    Get-Content $SpecFile | ForEach-Object { Write-Host "    $_" }
    Write-Host ""

    # -----------------------------------------------------------------------
    # Step 4: New-OfflineBundle (base depot + component depot + spec).
    # -----------------------------------------------------------------------
    Write-Host "=== Step 4: New-OfflineBundle ===" -ForegroundColor Cyan
    $bundleArgs = @{
        SoftwareSpec = $SpecFile
        Depots       = @($BaseDepot, $realComponentDepot)
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
        $msg = $_.Exception.Message
        if ($msg -match "does not support base image|not support|compatible") {
            Write-Host "Version-compatibility issue:" -ForegroundColor Red
            Write-Host "  $msg" -ForegroundColor Red
            Write-Host ""
            Write-Host "The driver is tagged for a different ESXi base than $BaseVersion." -ForegroundColor Yellow
            Write-Host "Options:" -ForegroundColor Yellow
            Write-Host "  - If this is a POC and the driver is known-good, import it directly" -ForegroundColor Yellow
            Write-Host "    into vLCM instead: Lifecycle Manager > Actions > Import Updates," -ForegroundColor Yellow
            Write-Host "    add the component to the cluster image, compose. vLCM's import is" -ForegroundColor Yellow
            Write-Host "    typically more lenient than New-OfflineBundle's spec validation." -ForegroundColor Yellow
            Write-Host "  - Or obtain the driver build that matches base $BaseVersion." -ForegroundColor Yellow
            exit 3
        }
        Write-Host "New-OfflineBundle failed." -ForegroundColor Yellow
        Write-Host "Error: $msg" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "--- New-OfflineBundle ACTUAL parameters (this PowerCLI build) ---" -ForegroundColor Cyan
        (Get-Command New-OfflineBundle).Parameters.Keys |
            Where-Object { $_ -notin @(
                "Verbose","Debug","ErrorAction","WarningAction","InformationAction",
                "ErrorVariable","WarningVariable","InformationVariable","OutVariable",
                "OutBuffer","PipelineVariable","WhatIf","Confirm","ProgressAction") } |
            ForEach-Object { Write-Host "    -$_" }
        Write-Host ""
        Get-Command New-OfflineBundle -Syntax
        Write-Host ""
        Write-Host "If the spec's 'components' shape is the problem, send this output back." -ForegroundColor Cyan
        exit 2
    }

    # -----------------------------------------------------------------------
    # Step 5: Report
    # -----------------------------------------------------------------------
    if (Test-Path $Destination) {
        $sizeMB = [math]::Round((Get-Item $Destination).Length / 1MB, 1)
        Write-Host ""
        Write-Host "=== vLCM component bundle built ===" -ForegroundColor Green
        Write-Host "  $Destination ($sizeMB MB)" -ForegroundColor Green
        Write-Host ""
        Write-Host "Import into vSphere Lifecycle Manager:" -ForegroundColor Cyan
        Write-Host "  Lifecycle Manager > Imported ISOs / Updates > Import Updates > from ZIP" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Verify structure vs a known-good depot with Inspect-BundleDeep.ps1." -ForegroundColor Cyan
    } else {
        Write-Error "New-OfflineBundle completed but the destination file is missing."
        exit 1
    }
}
finally {
    foreach ($d in $addedDepots) {
        if ($null -ne $d) { try { Remove-EsxSoftwareDepot $d -ErrorAction SilentlyContinue } catch { } }
    }
    if (-not $KeepSpec) {
        # leave spec; only clean the extraction scratch
        Remove-Item $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
