<#
.SYNOPSIS
    Write the software spec JSON as UTF-8 WITHOUT a byte-order mark (BOM).

.DESCRIPTION
    New-IsoImage rejects a software spec that has a UTF-8 BOM at the start of the
    file. PowerShell's Out-File and Set-Content add a BOM by default, which is the
    single most common reason New-IsoImage fails with a cryptic parse error.

    This helper writes the spec using [System.IO.File]::WriteAllText, which does
    NOT add a BOM. Edit the $version values to match your depots (query them with
    Get-DepotBaseImages and Get-DepotAddons first).

.EXAMPLE
    .\Write-SoftwareSpec.ps1 -OutFile "C:\iso\synergy-custom.json" `
        -BaseVersion "9.0.2-0.25148076" `
        -AddonName "HPE-Custom-Syn-AddOn" `
        -AddonVersion "900.0.0.12.3.5-5"

.NOTES
    Author : Noah Farshad / essential.coach
    License : GPL-3.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutFile,

    [Parameter(Mandatory = $true)]
    [string]$BaseVersion,

    [Parameter(Mandatory = $true)]
    [string]$AddonName,

    [Parameter(Mandatory = $true)]
    [string]$AddonVersion
)

$ErrorActionPreference = "Stop"

$spec = @{
    base_image       = @{ version = $BaseVersion }
    add_on           = @{ name = $AddonName; version = $AddonVersion }
    components       = $null
    hardware_support = $null
    solutions        = $null
}

# ConvertTo-Json then strip to a compact form. Depth 5 is plenty for this shape.
$json = $spec | ConvertTo-Json -Depth 5

# Resolve the parent dir to an absolute path; PowerCLI/IO are picky about relative.
$parent = Split-Path $OutFile -Parent
if ($parent) {
    $parent = (Resolve-Path $parent).Path
    $OutFile = Join-Path $parent (Split-Path $OutFile -Leaf)
}

# CRITICAL: WriteAllText with UTF8Encoding($false) => NO BOM.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutFile, $json, $utf8NoBom)

Write-Host "Wrote software spec (UTF-8, no BOM): $OutFile" -ForegroundColor Green
Write-Host ""
Get-Content $OutFile
