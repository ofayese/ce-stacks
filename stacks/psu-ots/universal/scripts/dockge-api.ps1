#Requires -Version 5.1
<#
.SYNOPSIS
    Legacy shim — canonical REST definitions live in ../endpoints/dockge-api.ps1.

.NOTES
    When copying templates to the NAS, prefer data/Repository/.universal/endpoints/dockge-api.ps1.
#>

$ErrorActionPreference = "Stop"
$canonical = Join-Path (Split-Path -Parent $PSScriptRoot) "endpoints/dockge-api.ps1"
if (Test-Path -LiteralPath $canonical) {
    . $canonical
}
else {
    Write-Warning "dockge-api.ps1 (scripts): ../endpoints/dockge-api.ps1 not found."
}
