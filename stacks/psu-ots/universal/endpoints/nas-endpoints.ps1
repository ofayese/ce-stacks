#Requires -Version 5.1
<#
.SYNOPSIS
    PSU HTTP endpoint entry — loads nas-api.ps1 from the same directory.

.NOTES
    Copy into data/Repository/.universal/endpoints/ on the NAS.
#>

$ErrorActionPreference = "Stop"
$api = Join-Path $PSScriptRoot "nas-api.ps1"
if (Test-Path -LiteralPath $api) {
    . $api
}
else {
    Write-Warning "nas-endpoints.ps1: missing nas-api.ps1 beside this file."
}
