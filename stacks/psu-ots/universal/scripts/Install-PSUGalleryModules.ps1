#Requires -Version 5.1
<#
.SYNOPSIS
    Download and install Dockge PSU Gallery dependencies (PSGallery / PSResourceGet).

.DESCRIPTION
    Used by container entrypoint (PSU_GALLERY_INSTALL=1) or Dockerfile RUN. Installs
    the same module set as Import-PSUGalleryModules.ps1, then optionally verifies import.
    Requires network access on first run. Non-zero exit on hard failure when
    PSU_GALLERY_INSTALL_STRICT=1 (default).

.NOTES
    Run: pwsh -NoProfile -File Install-PSUGalleryModules.ps1
#>

$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
$import = Join-Path $here "Import-PSUGalleryModules.ps1"
if (-not (Test-Path -LiteralPath $import)) {
    Write-Error "Import-PSUGalleryModules.ps1 not found beside this script."
    exit 2
}
. $import

$strict = ($env:PSU_GALLERY_INSTALL_STRICT -ne '0')
$includeWin = ($env:PSU_GALLERY_INCLUDE_WINDOWS -eq '1')
$names = Get-DockgePSUGalleryModuleNames -IncludeWindowsOnly:$includeWin

function Install-OneModule {
    param([string]$Name)
    if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
        try {
            Install-PSResource -Name $Name -Repository PSGallery -TrustRepository -Reinstall -ErrorAction Stop | Out-Null
            return $true
        }
        catch {
            Write-Warning "Install-PSResource ($Name): $($_.Exception.Message)"
        }
    }
    try {
        if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
            Write-Warning "Install-OneModule: Install-Module not available for $Name"
            return $false
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue | Out-Null
        Install-Module -Name $Name -Scope AllUsers -Repository PSGallery -Force -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Warning "Install-Module ($Name): $($_.Exception.Message)"
        return $false
    }
}

$failures = [System.Collections.ArrayList]::new()
foreach ($n in $names) {
    Write-Host "Installing $n ..."
    if (-not (Install-OneModule -Name $n)) {
        [void]$failures.Add($n)
    }
}

if ($strict -and $failures.Count -gt 0) {
    Write-Error "Install-PSUGalleryModules.ps1: failed packages: $($failures -join ', '). Set PSU_GALLERY_INSTALL_STRICT=0 to continue with partial install."
    exit 1
}

Write-Host "Verifying Import-PSUGalleryModules (strict)..."
try {
    $null = Import-PSUGalleryModules
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}


Write-Host "Gallery modules installed and import-verified OK."
exit 0
