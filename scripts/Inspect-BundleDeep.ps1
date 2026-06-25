<#
.SYNOPSIS
    Deep forensic comparison of two ESXi offline depots / bundles, including the
    contents of the nested metadata.zip (which the top-level index.xml only
    points at). Built to answer one question: does New-OfflineBundle produce the
    vLCM-required descriptor structure -- and if so, WHERE does it live?

.DESCRIPTION
    A vLCM offline depot nests its real descriptors:
        bundle.zip
          |- index.xml            (vendor list -> points at vendor-index.xml)
          |- vendor-index.xml     (productIds, version -> points at metadata.zip)
          |- <name>-metadata.zip  (THE descriptors vLCM validates: vmware.xml,
          |                         bulletins, per-VIB SHA-256 checksums)
          |- vib20\...\*.vib       (the payload)

    A shallow look at index.xml can mislead -- the substance is inside the
    metadata.zip. This script extracts BOTH bundles fully, extracts BOTH
    metadata.zips, dumps the full descriptors, and diffs what matters:
      * top-level index.xml / vendor-index.xml (raw, untruncated)
      * the file list inside each metadata.zip
      * the descriptor XML inside each metadata.zip (vmware.xml etc.)
      * presence of vcfVersion, vendor name/code, productId, content-type
      * a side-by-side summary table

    Everything is also written to a report file you can paste back in full.

.PARAMETER GoodBundle
    Path to a known vLCM-importable depot zip (the reference).

.PARAMETER OurBundle
    Path to the bundle we produced (New-OfflineBundle output).

.PARAMETER WorkDir
    Extraction dir. Default: .\bundle-deep

.PARAMETER ReportFile
    Where to write the full text report. Default: .\bundle-deep\REPORT.txt

.EXAMPLE
    .\Inspect-BundleDeep.ps1 `
        -GoodBundle ".\VMware-ESXi-9.0.2.0.25148076-depot.zip" `
        -OurBundle  ".\Synergy-9.0.2-lcm.zip"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string]$GoodBundle,
    [Parameter(Mandatory = $true)]  [string]$OurBundle,
    [Parameter(Mandatory = $false)] [string]$WorkDir = ".\bundle-deep",
    [Parameter(Mandatory = $false)] [string]$ReportFile
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

# --- Tee everything to a report file as well as the console ---------------
$GoodBundle = (Resolve-Path $GoodBundle).Path
$OurBundle  = (Resolve-Path $OurBundle).Path
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
$WorkDir = (Resolve-Path $WorkDir).Path
if (-not $ReportFile) { $ReportFile = Join-Path $WorkDir "REPORT.txt" }
if (Test-Path $ReportFile) { Remove-Item $ReportFile -Force }

function Log {
    param([string]$Text = "", [string]$Color = "Gray")
    Write-Host $Text -ForegroundColor $Color
    Add-Content -Path $ReportFile -Value $Text
}

function Section($t) { Log ""; Log ("=" * 78) "Cyan"; Log $t "Cyan"; Log ("=" * 78) "Cyan" }

# --- Extract a zip fresh ---------------------------------------------------
function Expand-Fresh($zip, $dest) {
    Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
}

$goodDir = Join-Path $WorkDir "good"
$ourDir  = Join-Path $WorkDir "ours"

Section "INPUTS"
Log "Good (reference): $GoodBundle"
Log "Ours  (tested)  : $OurBundle"
Log "Report          : $ReportFile"

Section "STEP 1: Extract both bundles"
Expand-Fresh $GoodBundle $goodDir
Expand-Fresh $OurBundle  $ourDir
Log "Extracted both." "Green"

# --- Top-level file lists --------------------------------------------------
function Get-RelFiles($root) {
    Get-ChildItem $root -Recurse -File |
        ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('\','/') } | Sort-Object
}

Section "STEP 2: Top-level file inventory"
$goodFiles = Get-RelFiles $goodDir
$ourFiles  = Get-RelFiles $ourDir
Log "GOOD bundle: $($goodFiles.Count) files" "Yellow"
Log "OURS bundle: $($ourFiles.Count) files" "Yellow"

Log "" 
Log "Top-level (non-VIB) files in GOOD:" "Yellow"
$goodFiles | Where-Object { $_ -notlike "vib20*" } | ForEach-Object { Log "  $_" }
Log ""
Log "Top-level (non-VIB) files in OURS:" "Yellow"
$ourFiles  | Where-Object { $_ -notlike "vib20*" } | ForEach-Object { Log "  $_" }

# --- Full raw index.xml / vendor-index.xml --------------------------------
function Dump-Xml($root, $name, $label) {
    $path = Join-Path $root $name
    Log ""
    Log "--- $label : $name (RAW, full) ---" "Yellow"
    if (Test-Path $path) {
        Get-Content $path -Raw | ForEach-Object { Log $_ }
    } else {
        Log "  (not present)" "DarkYellow"
    }
}

Section "STEP 3: Full top-level descriptors (untruncated)"
Dump-Xml $goodDir "index.xml"        "GOOD"
Dump-Xml $ourDir  "index.xml"        "OURS"
Dump-Xml $goodDir "vendor-index.xml" "GOOD"
Dump-Xml $ourDir  "vendor-index.xml" "OURS"

# --- Find + extract the metadata.zip in each (the real descriptor home) ---
function Get-MetadataZip($root) {
    # Could be metadata.zip or <name>-metadata.zip per vendor-index reference
    $cands = Get-ChildItem $root -Recurse -File -Filter *.zip |
        Where-Object { $_.Name -match 'metadata' }
    return $cands | Select-Object -First 1
}

function Inspect-Metadata($root, $label) {
    Section "STEP 4: $label -- inside the metadata.zip"
    $mz = Get-MetadataZip $root
    if (-not $mz) { Log "  No metadata zip found." "Red"; return }
    Log "metadata zip: $($mz.Name)" "Yellow"
    $mdir = Join-Path $root ("_meta_" + [System.IO.Path]::GetFileNameWithoutExtension($mz.Name))
    Expand-Fresh $mz.FullName $mdir

    Log ""
    Log "Files inside $($mz.Name):" "Yellow"
    Get-ChildItem $mdir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($mdir.Length).TrimStart('\','/')
        Log ("  {0}  ({1} bytes)" -f $rel, $_.Length)
    }

    # Dump the key descriptor XMLs (vmware.xml is the main one) -- but cap size
    $descriptors = Get-ChildItem $mdir -Recurse -File -Include *.xml
    foreach ($d in $descriptors) {
        $rel = $d.FullName.Substring($mdir.Length).TrimStart('\','/')
        $len = $d.Length
        Log ""
        Log "--- $label metadata: $rel ($len bytes) ---" "Yellow"
        if ($len -le 6000) {
            Get-Content $d.FullName -Raw | ForEach-Object { Log $_ }
        } else {
            # Large -- show the head where vendor/version/vcf tags live
            Log "  (large file; showing first 60 lines + any vendor/vcf/productId lines)" "DarkYellow"
            $lines = Get-Content $d.FullName
            $lines | Select-Object -First 60 | ForEach-Object { Log "  $_" }
            Log "  ... [vendor/vcf/productId matches across whole file] ..." "DarkYellow"
            $lines | Where-Object { $_ -match 'vcfVersion|vendor|productId|<code>|<name>|content|releaseID|softwareSpec' } |
                Select-Object -First 40 | ForEach-Object { Log "  $_" }
        }
    }
    return $mdir
}

$goodMeta = Inspect-Metadata $goodDir "GOOD"
$ourMeta  = Inspect-Metadata $ourDir  "OURS"

# --- Attribute presence matrix (the actual decision) ----------------------
function Test-Attr($root, $pattern) {
    $hit = Get-ChildItem $root -Recurse -File -Include *.xml -ErrorAction SilentlyContinue |
        Select-String -Pattern $pattern -SimpleMatch -ErrorAction SilentlyContinue |
        Select-Object -First 1
    return [bool]$hit
}

Section "STEP 5: ATTRIBUTE PRESENCE MATRIX (good vs ours, across ALL extracted xml)"
$attrs = @(
    @{ Name = "vcfVersion";              Pat = "vcfVersion" },
    @{ Name = "vendor <code>";           Pat = "<code>" },
    @{ Name = "vendor <name>";           Pat = "<name>" },
    @{ Name = "content type (depotmgmt)"; Pat = "depotmanagement" },
    @{ Name = "productId";               Pat = "productId" },
    @{ Name = "softwareSpec";            Pat = "softwareSpec" },
    @{ Name = "checksum (sha-256)";      Pat = "sha-256" },
    @{ Name = "checksum (checksum tag)"; Pat = "checksum" }
)
Log ("{0,-28} {1,-8} {2,-8}" -f "Attribute", "GOOD", "OURS") "White"
Log ("{0,-28} {1,-8} {2,-8}" -f ("-"*26), "----", "----")
foreach ($a in $attrs) {
    $g = if (Test-Attr $goodDir $a.Pat) { "YES" } else { "no" }
    $o = if (Test-Attr $ourDir  $a.Pat) { "YES" } else { "no" }
    $color = if ($g -ne $o) { "Red" } else { "Gray" }
    Log ("{0,-28} {1,-8} {2,-8}" -f $a.Name, $g, $o) $color
}

Section "STEP 6: VIB count + sample"
function Vibs($root) { (Get-ChildItem $root -Recurse -File -Filter *.vib).Count }
Log ("GOOD VIB count: {0}" -f (Vibs $goodDir)) "Yellow"
Log ("OURS VIB count: {0}" -f (Vibs $ourDir))  "Yellow"

Section "DONE"
Log "Full report written to: $ReportFile" "Green"
Log "Extracted trees under : $WorkDir" "Green"
Log ""
Log "Paste REPORT.txt back for analysis. The ATTRIBUTE MATRIX (Step 5) is the" "White"
Log "decision: any row where GOOD=YES and OURS=no is a real structural gap." "White"
