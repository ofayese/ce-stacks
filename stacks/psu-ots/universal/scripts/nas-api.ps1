#Requires -Version 5.1
<#
.SYNOPSIS
    Legacy shim — canonical REST definitions live in ../endpoints/nas-api.ps1.

.NOTES
    When copying templates to the NAS, prefer data/Repository/.universal/endpoints/nas-api.ps1.
#>

$ErrorActionPreference = "Stop"
$canonical = Join-Path (Split-Path -Parent $PSScriptRoot) "endpoints/nas-api.ps1"
if (Test-Path -LiteralPath $canonical) {
    . $canonical
}
else {
    Write-Warning "nas-api.ps1 (scripts): ../endpoints/nas-api.ps1 not found."
}
