#Requires -Version 5.1
<#
.SYNOPSIS
    Import PowerShell Universal Gallery modules for PSU NAS templates.

.DESCRIPTION
    Dot-source this script, then call Import-PSUGalleryModules. By default every listed
    module must import successfully or the function throws (fail fast). Set
    PSU_GALLERY_OPTIONAL=1 or pass -Optional to allow partial success (staged rollout only).

.NOTES
    Linux / NAS Docker: Windows-only modules are skipped unless -IncludeWindowsOnly.
    Bake modules: stacks/otspsu/Dockerfile or runtime PSU_GALLERY_INSTALL=1 + entrypoint.
    See stacks/otspsu/README.md.
#>

$ErrorActionPreference = "Continue"

function Get-NASGalleryModuleNames {
    [CmdletBinding()]
    param([switch]$IncludeWindowsOnly)

    $names = @(
        'Universal.Utilities.Apps',
        'Universal.Components.Loader',
        'Universal.Notifications',
        'PowerShellUniversal.Triggers.Email',
        'PowerShellUniversal.Triggers.Discord',
        'PowerShellUniversal.API.Monitoring',
        'PowerShellUniversal.API.System',
        'PowerShellUniversal.HealthCheck.InternetAccess',
        'PowerShellUniversal.HealthCheck.ExcessiveRunspaces',
        'Universal.Apps.NetworkUtilities',
        'PowerShellUniversal.Apps.NetworkUtilities',
        'PowerShellUniversal.Apps.LetsEncrypt',
        'PowerShellUniversal.API.dbatools',
        'PowerShellUniversal.Apps.Pester',
        'PowerShellUniversal.Scripts',
        'PowerShellUniversal.Apps.Tools',
        'PowerShellUniversal.API.PSResourceGet',
        'PowerShellUniversal.Plaster',   # canonical casing; duplicate 'PowershellUniversal.Plaster' removed
        'PowerShellUniversal.Apps.Cookbook',
        'PowerShellUniversal.Apps.Random'
        # Removed: Universal.Apps.ActiveDirectory, PowerShellUniversal.Roles.ActiveDirectory
        # Neither package exists in PSGallery — PSU_GALLERY_INSTALL_STRICT=1 caused abort before PSU started.
    ) | Select-Object -Unique

    if ($IncludeWindowsOnly) {
        $names = @(
            $names
            'PowerShellUniversal.Apps.TaskManager',
            'PowerShellUniversal.Apps.Services',
            'PowerShellUniversal.Apps.AutomatedLab',
            'Universal.Apps.WindowsSystemInformation'
        ) | Select-Object -Unique
    }

    return @($names)
}

function Import-PSUGalleryModules {
    [CmdletBinding()]
    param(
        [switch]$IncludeWindowsOnly,
        [switch]$Optional
    )

    $allowPartialFailure = $Optional -or ($env:PSU_GALLERY_OPTIONAL -eq '1')
    $global:NASGalleryModuleState = [ordered]@{}

    $names = Get-NASGalleryModuleNames -IncludeWindowsOnly:$IncludeWindowsOnly

    foreach ($name in $names) {
        try {
            Import-Module -Name $name -Scope Global -ErrorAction Stop | Out-Null
            $global:NASGalleryModuleState[$name] = @{ ok = $true; error = $null }
        }
        catch {
            $global:NASGalleryModuleState[$name] = @{ ok = $false; error = $_.Exception.Message }
        }
    }

    $loaded = [System.Collections.ArrayList]::new()
    $failed = [System.Collections.ArrayList]::new()
    foreach ($kv in $global:NASGalleryModuleState.GetEnumerator()) {
        if ($kv.Value.ok) { [void]$loaded.Add($kv.Key) }
        else { [void]$failed.Add($kv.Key) }
    }

    if (-not $allowPartialFailure -and $failed.Count -gt 0) {
        $detail = ($failed | ForEach-Object { "$_ -> $($global:NASGalleryModuleState[$_].error)" }) -join '; '
        throw "Import-PSUGalleryModules: required module(s) failed: $detail. Install modules (PSU Admin, Dockerfile, or PSU_GALLERY_INSTALL=1), or set PSU_GALLERY_OPTIONAL=1 only while staging."
    }

    return [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        moduleCount    = $names.Count
        loaded         = @($loaded)
        failed         = @($failed)
    }
}

function Test-PSUGalleryModuleLoaded {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not $global:NASGalleryModuleState.ContainsKey($Name)) { return $false }
    return [bool]$global:NASGalleryModuleState[$Name].ok
}

function Get-PSUGalleryModuleSummary {
    return @{
        state = $global:NASGalleryModuleState
    }
}
