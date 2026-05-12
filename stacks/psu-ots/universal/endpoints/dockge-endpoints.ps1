#Requires -Version 5.1
<#
.SYNOPSIS
    PSU HTTP endpoint entry — loads dockge-api.ps1 from the same directory.

.NOTES
    Copy into data/Repository/.universal/endpoints/ on the NAS.
#>

$ErrorActionPreference = "Stop"
$api = Join-Path $PSScriptRoot "dockge-api.ps1"
if (Test-Path -LiteralPath $api) {
    . $api
}
else {
    Write-Warning "dockge-endpoints.ps1: missing dockge-api.ps1 beside this file."
}
