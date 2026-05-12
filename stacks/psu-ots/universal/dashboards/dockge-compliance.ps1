#Requires -Version 5.1
<#
.SYNOPSIS
    Dockge NOC dashboard — JSON from /data/reports; requires PSU Gallery modules by default.

.DESCRIPTION
    Dot-sources Import-PSUGalleryModules.ps1 and calls Import-PSUGalleryModules (strict)
    unless PSU_GALLERY_OPTIONAL=1. Uses New-UDLoader, New-UDChartJS, Show-UDObject when
    those modules are present after import.

.NOTES
    Copy into data/Repository/.universal/dashboards/. Requires reports from dockge-jobs.ps1.
#>

$ErrorActionPreference = "Stop"

$script:DockgeGalleryInitPath = $null
foreach ($cand in @(
        (Join-Path $PSScriptRoot "..\scripts\Import-PSUGalleryModules.ps1"),
        (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\Import-PSUGalleryModules.ps1")
    )) {
    if (Test-Path -LiteralPath $cand) {
        $script:DockgeGalleryInitPath = $cand
        break
    }
}

if (-not $script:DockgeGalleryInitPath) {
    if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
        Write-Warning "dockge-compliance.ps1: Import-PSUGalleryModules.ps1 not found — gallery panels will be limited."
    }
    else {
        throw "dockge-compliance.ps1: Import-PSUGalleryModules.ps1 not found next to dashboards/scripts. Copy universal/ into data/Repository/.universal/."
    }
}
elseif ($script:DockgeGalleryInitPath) {
    . $script:DockgeGalleryInitPath
    if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
        try { Import-PSUGalleryModules -Optional | Out-Null } catch { Write-Warning "dockge-compliance.ps1: gallery import (optional): $($_.Exception.Message)" }
    }
    else {
        Import-PSUGalleryModules | Out-Null
    }
}

function Get-PSUReportsRoot {
    $r = $env:PSU_REPORTS_ROOT
    if ([string]::IsNullOrWhiteSpace($r)) { $r = "/data/reports" }
    return $r
}

function Get-DockgeLatestReportObject {
    param([Parameter(Mandatory = $true)][string]$Prefix)
    $root = Get-PSUReportsRoot
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $f = Get-ChildItem -LiteralPath $root -Filter ("$Prefix*.json") -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $f) { return $null }
    try { return (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop) }
    catch { return @{ parseError = $_.Exception.Message; file = $f.Name } }
}

function New-DockgeReportTable {
    param($Object)
    if ($null -eq $Object) { return @([ordered]@{ info = "no report yet" }) }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        return @($Object.PSObject.Properties | ForEach-Object {
                [ordered]@{ name = $_.Name; value = ($_.Value | Out-String).Trim() }
            })
    }
    if ($Object -is [hashtable] -or $Object -is [System.Collections.IDictionary]) {
        return @($Object.GetEnumerator() | ForEach-Object { [ordered]@{ name = $_.Name; value = ($_.Value | Out-String).Trim() } })
    }
    return @($Object)
}

function New-DockgeGalleryStatusRows {
    if (-not $global:DockgePSUGalleryModuleState -or $global:DockgePSUGalleryModuleState.Count -eq 0) {
        return @([ordered]@{ module = "(none)"; ok = $false; error = "Gallery initializer not loaded or no import attempted." })
    }
    return @($global:DockgePSUGalleryModuleState.GetEnumerator() | ForEach-Object {
            [ordered]@{ module = $_.Key; ok = $_.Value.ok; error = $_.Value.error }
        })
}

function New-DockgeOptionalChartForReport {
    param(
        [string]$Prefix,
        $ReportObject
    )
    if ($null -eq $ReportObject) { return $null }
    if ($Prefix -ne "image-drift") { return $null }
    if (-not (Get-Command New-UDChartJS -ErrorAction SilentlyContinue)) { return $null }
    $tags = @()
    try { $tags = @($ReportObject.floatingTags) } catch { return $null }
    if ($tags.Count -eq 0) { return $null }
    $grouped = @(
        $tags | Group-Object {
            $stk = ""
            try { $stk = [string]$_.stack } catch { }
            if ([string]::IsNullOrWhiteSpace($stk)) { "unknown" }
            else { $stk }
        } | ForEach-Object {
            [PSCustomObject]@{ Label = $_.Name; Value = $_.Count }
        }
    )
    if ($grouped.Count -eq 0) { return $null }
    try {
        return (New-UDChartJS -Type "bar" -Data $grouped -DataProperty Value -LabelProperty Label -Title "Floating / unpinned images by stack")
    }
    catch {
        return $null
    }
}

function New-DockgeCompliancePanel {
    param(
        [string]$Title,
        [string]$Prefix,
        [int]$RefreshSec
    )
    New-UDColumn -LargeSize 6 -Content {
        New-UDHeading -Text $Title
        New-UDDynamic -Content {
            $loaderElt = $null
            if (Get-Command New-UDLoader -ErrorAction SilentlyContinue) {
                $loaderElt = New-UDLoader -Pulse -SpeedMultiplier 1.2
            }
            $d = Get-DockgeLatestReportObject -Prefix $Prefix
            $chart = New-DockgeOptionalChartForReport -Prefix $Prefix -ReportObject $d
            $table = New-UDTable -Data (New-DockgeReportTable -Object $d) -Dense
            $extras = @()
            if (Get-Command Show-UDObject -ErrorAction SilentlyContinue) {
                $extras += New-UDButton -Text "Modal inspector (Show-UDObject)" -OnClick {
                    Show-UDObject -InputObject $d
                }
            }
            elseif (Get-Command New-UDExpansionPanel -ErrorAction SilentlyContinue) {
                $jsonSnippet = ""
                try { $jsonSnippet = ($d | ConvertTo-Json -Depth 6 -Compress) } catch { $jsonSnippet = "unavailable" }
                if ($jsonSnippet.Length -gt 8000) { $jsonSnippet = $jsonSnippet.Substring(0, 8000) + "…" }
                $extras += New-UDExpansionPanel -Title "Raw JSON (truncated)" -Content {
                    New-UDElement -Tag "pre" -Content { $jsonSnippet }
                }
            }
            $children = @()
            if ($null -ne $loaderElt) { $children += $loaderElt }
            if ($null -ne $chart) { $children += $chart }
            $children += $table
            if ($extras.Count -gt 0) { $children += $extras }
            New-UDColumn -LargeSize 12 -Content { $children }
        } -AutoRefresh -AutoRefreshInterval $RefreshSec
    }
}

if (Get-Command New-PSUDashboard -ErrorAction SilentlyContinue) {
    try {
        New-PSUDashboard -Name "DockgeCompliance" -BaseUrl "/dockge-compliance" -Framework "Universal" -Content {
            New-UDRow -Columns {
                New-UDColumn -LargeSize 12 -Content {
                    New-UDHeading -Text "PSU Gallery modules (best-effort import)"
                    New-UDDynamic -Content {
                        New-UDTable -Data (New-DockgeGalleryStatusRows) -Dense
                    } -AutoRefresh -AutoRefreshInterval 600
                }
            }
            New-UDRow -Columns {
                New-DockgeCompliancePanel -Title "Panel A — Image drift" -Prefix "image-drift" -RefreshSec 60
                New-DockgeCompliancePanel -Title "Panel B — NAS health" -Prefix "nas-health" -RefreshSec 60
            }
            New-UDRow -Columns {
                New-DockgeCompliancePanel -Title "Panel C — Ingress" -Prefix "ingress-validator" -RefreshSec 120
                New-DockgeCompliancePanel -Title "Panel D — Docker / Dockge latency" -Prefix "docker-latency" -RefreshSec 120
            }
            New-UDRow -Columns {
                New-DockgeCompliancePanel -Title "Panel E — PSU self-health" -Prefix "psu-self-health" -RefreshSec 120
                New-DockgeCompliancePanel -Title "Panel F — Stack dependencies" -Prefix "stack-dependencies" -RefreshSec 300
            }
            New-UDRow -Columns {
                New-UDColumn -LargeSize 12 -Content {
                    New-DockgeCompliancePanel -Title "Panel G — Security (trivy)" -Prefix "security-scanner" -RefreshSec 3600
                }
            }
        }
    }
    catch {
        Write-Warning "dockge-compliance.ps1: dashboard registration failed: $($_.Exception.Message)"
    }
}
else {
    Write-Output "dockge-compliance.ps1: Universal Dashboard cmdlets not present — use Get-DockgeLatestReportObject in custom PSU pages."
}
