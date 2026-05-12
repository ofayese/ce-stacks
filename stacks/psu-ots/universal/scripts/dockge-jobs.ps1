#Requires -Version 5.1
<#
.SYNOPSIS
    Dockge / NAS compliance jobs for PowerShell Universal (Phase 2 — fire-and-forget).

.DESCRIPTION
    Each Invoke-PSUJob_* queues a background job that writes one timestamped JSON file
    under /data/reports (48h retention). Jobs avoid docker.sock inside the PSU container.
    Auto-remediation uses optional SSH to the NAS host (NAS_HOST_IP, NAS_SSH_USER, SSH_KEY_PATH)
    for docker compose / image prune; otherwise filesystem + HTTP reads only.

.NOTES
    Copy into data/Repository/.universal/scripts/ on the NAS. Register schedules in PSU.
    Environment: DOCKGE_REPO_ROOT, PSU_STACK_ROOT, DOCKGE_BASE_URL, DOCKGE_USERNAME, DOCKGE_PASSWORD,
    NAS_HOST_IP, NAS_SSH_USER, SSH_KEY_PATH, NAS_HOST_STACKS_ROOT (see stacks/psu-ots/NAS_HOST_SSH_SETUP.md).
#>

$ErrorActionPreference = "Stop"

function Get-PSUReportsRoot {
    $r = $env:PSU_REPORTS_ROOT
    if ([string]::IsNullOrWhiteSpace($r)) { $r = "/data/reports" }
    return $r
}

function Initialize-PSUReportsRoot {
    $root = Get-PSUReportsRoot
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    return $root
}

function Clear-PSUReportRetention {
    param(
        [int]$RetentionHours = 48
    )
    $root = Get-PSUReportsRoot
    if (-not (Test-Path -LiteralPath $root)) { return }
    $cutoff = (Get-Date).AddHours(-1 * $RetentionHours)
    Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq ".json" -and $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Get-RepoRoot {
    $p = $env:DOCKGE_REPO_ROOT
    if ([string]::IsNullOrWhiteSpace($p)) { $p = "/nas-repo" }
    return $p
}

function Get-StackRoot {
    $p = $env:PSU_STACK_ROOT
    if ([string]::IsNullOrWhiteSpace($p)) { $p = (Join-Path (Get-RepoRoot) "stacks") }
    return $p
}

function Invoke-Sh {
    param([string]$Command)
    & bash -lc $Command 2>&1
}

function Start-PSUJsonReportJob {
    param(
        [string]$ReportBaseName,
        [scriptblock]$Worker
    )
    Initialize-PSUReportsRoot | Out-Null
    Clear-PSUReportRetention | Out-Null
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $root = Get-PSUReportsRoot
    $outPath = Join-Path $root ("{0}-{1}.json" -f $ReportBaseName, $ts)
    $repo = Get-RepoRoot
    $stacks = Get-StackRoot
    $dockge = $env:DOCKGE_BASE_URL
    $du = $env:DOCKGE_USERNAME
    $dp = $env:DOCKGE_PASSWORD
    $galleryInit = Join-Path $PSScriptRoot "Import-PSUGalleryModules.ps1"
    if (-not (Test-Path -LiteralPath $galleryInit)) {
        if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
            $galleryInit = ""
        }
        else {
            throw "dockge-jobs.ps1: Import-PSUGalleryModules.ps1 not found at '$galleryInit'. Copy universal/scripts into this folder, use PSU_GALLERY_INSTALL=1 / Dockerfile, or set PSU_GALLERY_OPTIONAL=1 only while staging."
        }
    }
    $null = Start-Job -ScriptBlock $Worker -ArgumentList @($outPath, $repo, $stacks, $dockge, $du, $dp, $galleryInit)
    return @{ queued = $true; reportPath = $outPath; timestampUnix = $ts }
}

function Invoke-PSUJob_ImageDrift {
    $worker = {
        param($OutPath, $Repo, $Stacks, $DockgeBase, $DockgeUser, $DockgePass, $GalleryInit)
        $galLoaded = @()
        if (-not [string]::IsNullOrWhiteSpace($GalleryInit) -and (Test-Path -LiteralPath $GalleryInit)) {
            . $GalleryInit
            if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
                try { $null = Import-PSUGalleryModules -Optional } catch { }
            }
            else {
                $null = Import-PSUGalleryModules
            }
            if ($null -ne $global:DockgePSUGalleryModuleState) {
                foreach ($kv in $global:DockgePSUGalleryModuleState.GetEnumerator()) {
                    if ($kv.Value.ok) { $galLoaded += $kv.Key }
                }
            }
        }
        elseif ($env:PSU_GALLERY_OPTIONAL -ne '1') {
            throw "Dockge PSU job: gallery init path missing."
        }
        $ErrorActionPreference = "Continue"
        $obj = [ordered]@{
            job            = "image-drift"
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            stacks         = @()
            floatingTags   = @()
            dockgeApi      = $null
            notes          = @()
        }
        try {
            if (Test-Path -LiteralPath $Stacks) {
                Get-ChildItem -LiteralPath $Stacks -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    $compose = Join-Path $_.FullName "compose.yaml"
                    if (-not (Test-Path -LiteralPath $compose)) { $compose = Join-Path $_.FullName "docker-compose.yaml" }
                    if (-not (Test-Path -LiteralPath $compose)) { return }
                    $txt = Get-Content -LiteralPath $compose -Raw -ErrorAction SilentlyContinue
                    if ($null -eq $txt) { return }
                    foreach ($m in [regex]::Matches($txt, '(?m)^\s*image:\s*([^\s#]+)')) {
                        $img = $m.Groups[1].Value.Trim('"''')
                        if ($img -match ':latest$' -or $img -notmatch ':') {
                            $obj.floatingTags += [ordered]@{ stack = $_.Name; image = $img }
                        }
                    }
                    $obj.stacks += [ordered]@{ name = $_.Name; compose = $compose }
                }
            }
        }
        catch { $obj.notes += $_.Exception.Message }
        if (-not [string]::IsNullOrWhiteSpace($DockgeBase) -and -not [string]::IsNullOrWhiteSpace($DockgeUser)) {
            try {
                $pair = "{0}:{1}" -f $DockgeUser, $DockgePass
                $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
                $uri = ($DockgeBase.TrimEnd("/") + "/api/stacks")
                $obj.dockgeApi = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Basic $b64" } -TimeoutSec 20 -ErrorAction Stop
            }
            catch { $obj.notes += ("dockge api: " + $_.Exception.Message) }
        }
        else { $obj.notes += "Dockge credentials not set; filesystem scan only." }
        $obj.galleryModulesLoaded = @($galLoaded)
        ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $OutPath -Encoding UTF8
    }
    return (Start-PSUJsonReportJob -ReportBaseName "image-drift" -Worker $worker)
}

function Invoke-PSUJob_NasHealth {
    $worker = {
        param($OutPath, $Repo, $Stacks, $DockgeBase, $DockgeUser, $DockgePass, $GalleryInit)
        $galLoaded = @()
        if (-not [string]::IsNullOrWhiteSpace($GalleryInit) -and (Test-Path -LiteralPath $GalleryInit)) {
            . $GalleryInit
            if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
                try { $null = Import-PSUGalleryModules -Optional } catch { }
            }
            else {
                $null = Import-PSUGalleryModules
            }
            if ($null -ne $global:DockgePSUGalleryModuleState) {
                foreach ($kv in $global:DockgePSUGalleryModuleState.GetEnumerator()) {
                    if ($kv.Value.ok) { $galLoaded += $kv.Key }
                }
            }
        }
        elseif ($env:PSU_GALLERY_OPTIONAL -ne '1') {
            throw "Dockge PSU job: gallery init path missing."
        }
        $obj = [ordered]@{
            job            = "nas-health"
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            diskFree       = $null
            mdstat         = $null
            loadavg        = $null
            btrfs          = $null
            notes          = @()
        }
        try { $obj.diskFree = (Invoke-Sh "df -hP 2>/dev/null | head -n 30") } catch { $obj.notes += $_.Exception.Message }
        try { $obj.mdstat = (Invoke-Sh "cat /proc/mdstat 2>/dev/null") } catch { }
        try { $obj.loadavg = (Invoke-Sh "cat /proc/loadavg 2>/dev/null") } catch { }
        try { $obj.btrfs = (Invoke-Sh "btrfs scrub status / 2>/dev/null | head -n 20") } catch { }
        try { $obj.memorySummary = (Invoke-Sh "free -m 2>/dev/null | head -n 6") } catch { }
        $obj.galleryModulesLoaded = @($galLoaded)
        ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $OutPath -Encoding UTF8
    }
    return (Start-PSUJsonReportJob -ReportBaseName "nas-health" -Worker $worker)
}

function Invoke-PSUJob_IngressValidator {
    $worker = {
        param($OutPath, $Repo, $Stacks, $DockgeBase, $DockgeUser, $DockgePass, $GalleryInit)
        $galLoaded = @()
        if (-not [string]::IsNullOrWhiteSpace($GalleryInit) -and (Test-Path -LiteralPath $GalleryInit)) {
            . $GalleryInit
            if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
                try { $null = Import-PSUGalleryModules -Optional } catch { }
            }
            else {
                $null = Import-PSUGalleryModules
            }
            if ($null -ne $global:DockgePSUGalleryModuleState) {
                foreach ($kv in $global:DockgePSUGalleryModuleState.GetEnumerator()) {
                    if ($kv.Value.ok) { $galLoaded += $kv.Key }
                }
            }
        }
        elseif ($env:PSU_GALLERY_OPTIONAL -ne '1') {
            throw "Dockge PSU job: gallery init path missing."
        }
        $obj = [ordered]@{
            job            = "ingress-validator"
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            traefikPingMs  = $null
            haproxyLines   = 0
            notes          = @()
        }
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $null = Invoke-WebRequest -Uri "http://127.0.0.1:5000/" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
            $sw.Stop()
            $obj.traefikPingMs = [int]$sw.ElapsedMilliseconds
        }
        catch { $obj.notes += ("local psu: " + $_.Exception.Message) }
        $cfg = Join-Path $Repo "stacks/_haproxy/haproxy.cfg"
        if (Test-Path -LiteralPath $cfg) {
            $obj.haproxyLines = (Get-Content -LiteralPath $cfg | Measure-Object -Line).Lines
        }
        $obj.galleryModulesLoaded = @($galLoaded)
        ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $OutPath -Encoding UTF8
    }
    return (Start-PSUJsonReportJob -ReportBaseName "ingress-validator" -Worker $worker)
}

function Invoke-PSUJob_DockerLatency {
    $worker = {
        param($OutPath, $Repo, $Stacks, $DockgeBase, $DockgeUser, $DockgePass, $GalleryInit)
        $galLoaded = @()
        if (-not [string]::IsNullOrWhiteSpace($GalleryInit) -and (Test-Path -LiteralPath $GalleryInit)) {
            . $GalleryInit
            if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
                try { $null = Import-PSUGalleryModules -Optional } catch { }
            }
            else {
                $null = Import-PSUGalleryModules
            }
            if ($null -ne $global:DockgePSUGalleryModuleState) {
                foreach ($kv in $global:DockgePSUGalleryModuleState.GetEnumerator()) {
                    if ($kv.Value.ok) { $galLoaded += $kv.Key }
                }
            }
        }
        elseif ($env:PSU_GALLERY_OPTIONAL -ne '1') {
            throw "Dockge PSU job: gallery init path missing."
        }
        $obj = [ordered]@{
            job            = "docker-latency"
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            dockgeMs       = $null
            notes          = @()
        }
        if (-not [string]::IsNullOrWhiteSpace($DockgeBase)) {
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $pair = "{0}:{1}" -f $DockgeUser, $DockgePass
                $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
                $null = Invoke-WebRequest -Uri ($DockgeBase.TrimEnd("/") + "/") -Headers @{ Authorization = "Basic $b64" } -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
                $sw.Stop()
                $obj.dockgeMs = [int]$sw.ElapsedMilliseconds
            }
            catch { $obj.notes += $_.Exception.Message }
        }
        else { $obj.notes += "DOCKGE_BASE_URL unset" }
        $obj.galleryModulesLoaded = @($galLoaded)
        ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $OutPath -Encoding UTF8
    }
    return (Start-PSUJsonReportJob -ReportBaseName "docker-latency" -Worker $worker)
}

function Invoke-PSUJob_PSUSelfHealth {
    $worker = {
        param($OutPath, $Repo, $Stacks, $DockgeBase, $DockgeUser, $DockgePass, $GalleryInit)
        $galLoaded = @()
        if (-not [string]::IsNullOrWhiteSpace($GalleryInit) -and (Test-Path -LiteralPath $GalleryInit)) {
            . $GalleryInit
            if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
                try { $null = Import-PSUGalleryModules -Optional } catch { }
            }
            else {
                $null = Import-PSUGalleryModules
            }
            if ($null -ne $global:DockgePSUGalleryModuleState) {
                foreach ($kv in $global:DockgePSUGalleryModuleState.GetEnumerator()) {
                    if ($kv.Value.ok) { $galLoaded += $kv.Key }
                }
            }
        }
        elseif ($env:PSU_GALLERY_OPTIONAL -ne '1') {
            throw "Dockge PSU job: gallery init path missing."
        }
        $dataRoot = "/data"
        $obj = [ordered]@{
            job            = "psu-self-health"
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            dataDiskUsage  = $null
            gitQuick       = $null
            notes          = @()
        }
        try { $obj.dataDiskUsage = (Invoke-Sh "du -sh $dataRoot 2>/dev/null") } catch { $obj.notes += $_.Exception.Message }
        try {
            $obj.gitQuick = (Invoke-Sh "git -C `"$Repo`" status -sb --porcelain 2>/dev/null | head -n 40")
        }
        catch { }
        $obj.galleryModulesLoaded = @($galLoaded)
        ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $OutPath -Encoding UTF8
    }
    return (Start-PSUJsonReportJob -ReportBaseName "psu-self-health" -Worker $worker)
}

function Invoke-PSUJob_StackDependencies {
    $worker = {
        param($OutPath, $Repo, $Stacks, $DockgeBase, $DockgeUser, $DockgePass, $GalleryInit)
        $galLoaded = @()
        if (-not [string]::IsNullOrWhiteSpace($GalleryInit) -and (Test-Path -LiteralPath $GalleryInit)) {
            . $GalleryInit
            if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
                try { $null = Import-PSUGalleryModules -Optional } catch { }
            }
            else {
                $null = Import-PSUGalleryModules
            }
            if ($null -ne $global:DockgePSUGalleryModuleState) {
                foreach ($kv in $global:DockgePSUGalleryModuleState.GetEnumerator()) {
                    if ($kv.Value.ok) { $galLoaded += $kv.Key }
                }
            }
        }
        elseif ($env:PSU_GALLERY_OPTIONAL -ne '1') {
            throw "Dockge PSU job: gallery init path missing."
        }
        $graph = [ordered]@{ nodes = @(); edges = @(); cycles = @(); orphans = @(); notes = @("Cycle detection: use inventory analyzer dependency graph on repo host for authoritative results.") }
        $adj = @{}
        if (-not (Test-Path -LiteralPath $Stacks)) {
            $graph.galleryModulesLoaded = @($galLoaded)
            ($graph | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $OutPath -Encoding UTF8
            return
        }
        Get-ChildItem -LiteralPath $Stacks -Directory | ForEach-Object {
            $name = $_.Name
            if ($name.StartsWith("_")) { return }
            $graph.nodes += $name
            $adj[$name] = New-Object "System.Collections.Generic.List[string]"
            $compose = Join-Path $_.FullName "compose.yaml"
            if (-not (Test-Path -LiteralPath $compose)) { $compose = Join-Path $_.FullName "docker-compose.yaml" }
            if (-not (Test-Path -LiteralPath $compose)) { return }
            $lines = Get-Content -LiteralPath $compose -ErrorAction SilentlyContinue
            $inDepends = $false
            foreach ($line in $lines) {
                if ($line -match '^\s*depends_on:\s*$') { $inDepends = $true; continue }
                if ($inDepends) {
                    if ($line -match '^\s*-\s*(\S+)') {
                        $dep = $Matches[1].Trim('"''')
                        $graph.edges += [ordered]@{ from = $name; to = $dep }
                        [void]$adj[$name].Add($dep)
                        continue
                    }
                    if ($line -match '^\S') { $inDepends = $false }
                }
            }
        }
        foreach ($n in $graph.nodes) {
            if (-not $adj.ContainsKey($n)) { $adj[$n] = New-Object "System.Collections.Generic.List[string]" }
        }
        foreach ($n in $graph.nodes) {
            $incoming = @($graph.edges | Where-Object { $_.to -eq $n }).Count
            $outgoing = @($graph.edges | Where-Object { $_.from -eq $n }).Count
            if ($incoming -eq 0 -and $outgoing -eq 0 -and $graph.nodes.Count -gt 1) { $graph.orphans += $n }
        }
        $graph.galleryModulesLoaded = @($galLoaded)
        ($graph | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $OutPath -Encoding UTF8
    }
    return (Start-PSUJsonReportJob -ReportBaseName "stack-dependencies" -Worker $worker)
}

function Invoke-PSUJob_SecurityScanner {
    $worker = {
        param($OutPath, $Repo, $Stacks, $DockgeBase, $DockgeUser, $DockgePass, $GalleryInit)
        $galLoaded = @()
        if (-not [string]::IsNullOrWhiteSpace($GalleryInit) -and (Test-Path -LiteralPath $GalleryInit)) {
            . $GalleryInit
            if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
                try { $null = Import-PSUGalleryModules -Optional } catch { }
            }
            else {
                $null = Import-PSUGalleryModules
            }
            if ($null -ne $global:DockgePSUGalleryModuleState) {
                foreach ($kv in $global:DockgePSUGalleryModuleState.GetEnumerator()) {
                    if ($kv.Value.ok) { $galLoaded += $kv.Key }
                }
            }
        }
        elseif ($env:PSU_GALLERY_OPTIONAL -ne '1') {
            throw "Dockge PSU job: gallery init path missing."
        }
        $obj = [ordered]@{
            job            = "security-scanner"
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            trivy          = $null
            notes          = @()
        }
        $tv = Invoke-Sh "command -v trivy >/dev/null 2>&1 && trivy fs --scanners vuln --severity HIGH,CRITICAL --quiet --format json `"$Repo`" 2>/dev/null | head -c 400000"
        if ([string]::IsNullOrWhiteSpace($tv)) { $obj.notes += "trivy not installed or scan skipped" }
        else { $obj.trivy = $tv }
        $obj.galleryModulesLoaded = @($galLoaded)
        ($obj | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $OutPath -Encoding UTF8
    }
    return (Start-PSUJsonReportJob -ReportBaseName "security-scanner" -Worker $worker)
}

function Invoke-PSUJob_BackupSnapshot {
    $worker = {
        param($OutPath, $Repo, $Stacks, $DockgeBase, $DockgeUser, $DockgePass, $GalleryInit)
        $galLoaded = @()
        if (-not [string]::IsNullOrWhiteSpace($GalleryInit) -and (Test-Path -LiteralPath $GalleryInit)) {
            . $GalleryInit
            if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
                try { $null = Import-PSUGalleryModules -Optional } catch { }
            }
            else {
                $null = Import-PSUGalleryModules
            }
            if ($null -ne $global:DockgePSUGalleryModuleState) {
                foreach ($kv in $global:DockgePSUGalleryModuleState.GetEnumerator()) {
                    if ($kv.Value.ok) { $galLoaded += $kv.Key }
                }
            }
        }
        elseif ($env:PSU_GALLERY_OPTIONAL -ne '1') {
            throw "Dockge PSU job: gallery init path missing."
        }
        $obj = [ordered]@{
            job            = "backup-snapshot"
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            manifest       = @()
        }
        $targets = @(
            (Join-Path $Repo ".pre-commit-config.yaml"),
            (Join-Path $Repo "stacks/_haproxy/haproxy.cfg")
        )
        foreach ($t in $targets) {
            if (Test-Path -LiteralPath $t) {
                $h = Get-FileHash -LiteralPath $t -Algorithm SHA256
                $obj.manifest += [ordered]@{ path = $t; sha256 = $h.Hash; size = (Get-Item $t).Length }
            }
        }
        $obj.galleryModulesLoaded = @($galLoaded)
        ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $OutPath -Encoding UTF8
    }
    return (Start-PSUJsonReportJob -ReportBaseName "backup-snapshot" -Worker $worker)
}

function Invoke-PSUJob_AutoRemediation {
    $worker = {
        param($OutPath, $Repo, $Stacks, $DockgeBase, $DockgeUser, $DockgePass, $GalleryInit)
        $galLoaded = @()
        if (-not [string]::IsNullOrWhiteSpace($GalleryInit) -and (Test-Path -LiteralPath $GalleryInit)) {
            . $GalleryInit
            if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
                try { $null = Import-PSUGalleryModules -Optional } catch { }
            }
            else {
                $null = Import-PSUGalleryModules
            }
            if ($null -ne $global:DockgePSUGalleryModuleState) {
                foreach ($kv in $global:DockgePSUGalleryModuleState.GetEnumerator()) {
                    if ($kv.Value.ok) { $galLoaded += $kv.Key }
                }
            }
        }
        elseif ($env:PSU_GALLERY_OPTIONAL -ne '1') {
            throw "Dockge PSU job: gallery init path missing."
        }
        $enabled = $env:PSU_REMEDIATION_ENABLED -eq "1"
        $obj = [ordered]@{
            job            = "auto-remediation"
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            enabled        = [bool]$enabled
            actions        = @()
            notes          = @()
        }
        if (-not $enabled) {
            $obj.actions += "Remediation disabled (set PSU_REMEDIATION_ENABLED=1 after review)."
            $obj.galleryModulesLoaded = @($galLoaded)
            ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $OutPath -Encoding UTF8
            return
        }
        $reportsRoot = Split-Path -Parent $OutPath
        function Get-LatestReportContentByPrefix {
            param([string]$Root, [string]$Prefix)
            if (-not (Test-Path -LiteralPath $Root)) { return $null }
            $f = Get-ChildItem -LiteralPath $Root -Filter ("$Prefix*.json") -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($null -eq $f) { return $null }
            return (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8)
        }
        function Get-LatestReportFileByPrefix {
            param([string]$Root, [string]$Prefix)
            if (-not (Test-Path -LiteralPath $Root)) { return $null }
            return (Get-ChildItem -LiteralPath $Root -Filter ("$Prefix*.json") -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        }
        function Get-NasHostStacksRootForSsh {
            $h = $env:NAS_HOST_STACKS_ROOT
            if (-not [string]::IsNullOrWhiteSpace($h)) { return $h.TrimEnd('/') }
            $p = $env:PSU_STACK_ROOT
            if ([string]::IsNullOrWhiteSpace($p)) { return $null }
            if ($p -like '/nas-repo*') { return $null }
            return $p.TrimEnd('/')
        }
        function Test-PSUHostSshConfigured {
            if ([string]::IsNullOrWhiteSpace($env:NAS_HOST_IP)) { return $false }
            if ([string]::IsNullOrWhiteSpace($env:NAS_SSH_USER)) { return $false }
            if ([string]::IsNullOrWhiteSpace($env:SSH_KEY_PATH)) { return $false }
            if (-not (Test-Path -LiteralPath $env:SSH_KEY_PATH)) { return $false }
            return $true
        }
        function Resolve-SshExecutable {
            foreach ($c in @('/usr/bin/ssh', '/bin/ssh')) {
                if (Test-Path -LiteralPath $c) { return $c }
            }
            return 'ssh'
        }
        function Invoke-PSUHostSsh {
            param([string]$RemoteBashScript)
            $h = $env:NAS_HOST_IP
            $u = $env:NAS_SSH_USER
            $k = $env:SSH_KEY_PATH
            $kh = $env:NAS_SSH_KNOWN_HOSTS_FILE
            if ([string]::IsNullOrWhiteSpace($kh)) {
                $kh = Join-Path $reportsRoot "_psu_ssh_known_hosts"
            }
            $khDir = Split-Path -Parent $kh
            if (-not [string]::IsNullOrWhiteSpace($khDir) -and -not (Test-Path -LiteralPath $khDir)) {
                New-Item -ItemType Directory -Path $khDir -Force | Out-Null
            }
            $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($RemoteBashScript))
            $remoteOneLiner = "echo $b64 | base64 -d | bash"
            $so = [System.IO.Path]::GetTempFileName()
            $se = [System.IO.Path]::GetTempFileName()
            try {
                $sshExe = Resolve-SshExecutable
                $sshArgs = @(
                    '-i', $k,
                    '-o', 'BatchMode=yes',
                    '-o', 'StrictHostKeyChecking=accept-new',
                    '-o', "UserKnownHostsFile=$kh",
                    '-o', 'ConnectTimeout=25',
                    "${u}@${h}",
                    $remoteOneLiner
                )
                $p = Start-Process -FilePath $sshExe -ArgumentList $sshArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput $so -RedirectStandardError $se -ErrorAction Stop
                $out = ''
                $err = ''
                if (Test-Path -LiteralPath $so) { $out = (Get-Content -LiteralPath $so -Raw -ErrorAction SilentlyContinue) }
                if (Test-Path -LiteralPath $se) { $err = (Get-Content -LiteralPath $se -Raw -ErrorAction SilentlyContinue) }
                return [ordered]@{
                    exitCode = [int]$p.ExitCode
                    stdout   = ($out | Out-String).TrimEnd()
                    stderr   = ($err | Out-String).TrimEnd()
                    target   = "${u}@${h}"
                }
            }
            catch {
                return [ordered]@{ exitCode = -1; stdout = ''; stderr = $_.Exception.Message; target = "${u}@${h}" }
            }
            finally {
                Remove-Item -LiteralPath $so, $se -Force -ErrorAction SilentlyContinue
            }
        }
        function Add-RemediationAppendixToLatestReport {
            param([string]$Root, [string]$Prefix, $Entry)
            try {
                $f = Get-LatestReportFileByPrefix -Root $Root -Prefix $Prefix
                if ($null -eq $f) { return }
                $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
                $jo = $raw | ConvertFrom-Json -ErrorAction Stop
                $list = @()
                if ($jo.PSObject.Properties.Name -contains 'remediationSshAppendix') {
                    $list = @($jo.remediationSshAppendix)
                }
                $list += $Entry
                $jo | Add-Member -NotePropertyName remediationSshAppendix -NotePropertyValue $list -Force
                ($jo | ConvertTo-Json -Depth 14) | Set-Content -LiteralPath $f.FullName -Encoding UTF8
            }
            catch { }
        }
        function Test-NasHealthDiskPressure {
            param([string]$JsonText, [int]$ThresholdPct)
            if ([string]::IsNullOrWhiteSpace($JsonText)) { return @() }
            try {
                $nh = $JsonText | ConvertFrom-Json -ErrorAction Stop
            }
            catch { return @() }
            $warn = @()
            $block = [string]$nh.diskFree
            if ([string]::IsNullOrWhiteSpace($block)) { return $warn }
            foreach ($line in ($block -split "`n")) {
                if ($line -match 'Filesystem' -or $line -match '^\s*$') { continue }
                if ($line -match '\s(\d+)%\s+(/\S+)\s*$') {
                    $usePct = [int]$Matches[1]
                    $mnt = $Matches[2].Trim()
                    if ($usePct -ge $ThresholdPct) {
                        $warn += [ordered]@{ mount = $mnt; usePercent = $usePct; line = $line.Trim() }
                    }
                }
            }
            return $warn
        }
        function Test-NasHardwareDegradedObject {
            param($nh)
            $reasons = @()
            if ($null -eq $nh) { return @{ degraded = $false; reasons = $reasons } }
            $md = [string]$nh.mdstat
            if (-not [string]::IsNullOrWhiteSpace($md)) {
                if ($md -match '\(F\)' -or $md -match '\(D\)' -or $md -match '(?i)\bdegraded\b') { $reasons += "mdstat" }
            }
            $bt = [string]$nh.btrfs
            if (-not [string]::IsNullOrWhiteSpace($bt)) {
                if ($bt -match '(?i)with\s+(\d+)\s+uncorrectable') {
                    try {
                        if ([int]$Matches[1] -gt 0) { $reasons += ("btrfs uncorrectable: " + $Matches[1]) }
                    }
                    catch { }
                }
            }
            return @{ degraded = ($reasons.Count -gt 0); reasons = $reasons }
        }
        function Test-NasLoadOrMemoryCritical {
            param($nh, [double]$Load1Max, [double]$MemAvailRatioMin)
            $loadCrit = $false
            $memCrit = $false
            $load1 = $null
            if ($null -ne $nh) {
                $la = [string]$nh.loadavg
                if (-not [string]::IsNullOrWhiteSpace($la)) {
                    $tok = ($la -split '\s+')[0]
                    try {
                        $load1 = [double]$tok
                        if ($load1 -ge $Load1Max) { $loadCrit = $true }
                    }
                    catch { }
                }
                $memBlock = [string]$nh.memorySummary
                if (-not [string]::IsNullOrWhiteSpace($memBlock)) {
                    foreach ($line in ($memBlock -split "`n")) {
                        if ($line -notmatch '^\s*Mem:\s+') { continue }
                        if ($line -match 'Mem:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
                            $total = [double]$Matches[1]
                            $avail = [double]$Matches[6]
                            if ($total -gt 0 -and (($avail / $total) -lt $MemAvailRatioMin)) { $memCrit = $true }
                            break
                        }
                    }
                }
            }
            return @{ loadCritical = $loadCrit; memCritical = $memCrit; load1 = $load1 }
        }
        function Get-EmergencyBackupManifestEntries {
            param([string]$RepoPath)
            $manifest = @()
            $targets = @(
                (Join-Path $RepoPath ".pre-commit-config.yaml"),
                (Join-Path $RepoPath "stacks/_haproxy/haproxy.cfg")
            )
            foreach ($t in $targets) {
                if (Test-Path -LiteralPath $t) {
                    try {
                        $h = Get-FileHash -LiteralPath $t -Algorithm SHA256
                        $manifest += [ordered]@{ path = $t; sha256 = $h.Hash; size = (Get-Item $t).Length }
                    }
                    catch { }
                }
            }
            return $manifest
        }
        function Send-PSUSafeModeWebhookAlerts {
            param([string]$Reason, [string]$Detail)
            $msg = "PSU Safe Mode: $Reason — $Detail"
            $urls = @($env:PSU_SAFE_MODE_WEBHOOK_URL, $env:PSU_SAFE_MODE_DISCORD_WEBHOOK) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            foreach ($url in $urls) {
                try {
                    if ($url -match 'discord\.com/api/webhooks') {
                        $body = (@{ content = $msg } | ConvertTo-Json -Compress)
                        $null = Invoke-RestMethod -Uri $url -Method POST -Body $body -ContentType "application/json" -TimeoutSec 20 -ErrorAction Stop
                    }
                    else {
                        $payload = @{
                            source  = "psu-ots"
                            severity = "critical"
                            reason  = $Reason
                            detail  = $Detail
                            at      = (Get-Date).ToUniversalTime().ToString("o")
                        } | ConvertTo-Json -Compress
                        $null = Invoke-RestMethod -Uri $url -Method POST -Body $payload -ContentType "application/json" -TimeoutSec 20 -ErrorAction Stop
                    }
                }
                catch { }
            }
            try {
                $snd = Get-Command Send-PSUNotification -ErrorAction SilentlyContinue
                if ($null -ne $snd) {
                    & $snd -Title "PSU Safe Mode" -Body $msg -ErrorAction SilentlyContinue
                }
            }
            catch { }
        }

        $thresh = 90
        try { $thresh = [int]$env:PSU_REMEDIATION_DISK_THRESHOLD_PCT } catch { }
        $loadCritTh = 8.0
        try { $loadCritTh = [double]$env:PSU_REMEDIATION_LOADAVG1_CRITICAL } catch { }
        $memRatioMin = 0.08
        try { $memRatioMin = [double]$env:PSU_REMEDIATION_MEM_AVAILABLE_RATIO_MIN } catch { }
        $dockerCpuPct = 90
        try { $dockerCpuPct = [int]$env:PSU_REMEDIATION_DOCKER_CPU_PCT } catch { }

        $driftRaw = Get-LatestReportContentByPrefix -Root $reportsRoot -Prefix "image-drift"
        $analyzerPath = Join-Path $reportsRoot "analyzer-latest.json"
        $analyzerRaw = $null
        if (Test-Path -LiteralPath $analyzerPath) {
            $analyzerRaw = Get-Content -LiteralPath $analyzerPath -Raw -Encoding UTF8
        }
        $nasRaw = Get-LatestReportContentByPrefix -Root $reportsRoot -Prefix "nas-health"

        $obj.imageDriftReport = $null
        $obj.analyzerLatest = $null
        $obj.sshStackRemediation = @()
        $obj.diskPressure = @()
        $obj.dockerPrune = $null
        $obj.sshHost = [ordered]@{
            configured        = (Test-PSUHostSshConfigured)
            nasHostStacksRoot = (Get-NasHostStacksRootForSsh)
            target            = if (Test-PSUHostSshConfigured) { ("{0}@{1}" -f $env:NAS_SSH_USER, $env:NAS_HOST_IP) } else { $null }
        }
        $obj.sshSessions = @()
        $obj.nasHealthTriage = [ordered]@{}
        $obj.safeMode = [ordered]@{ triggered = $false }
        $obj.cpuTriage = [ordered]@{ triggered = $false }

        $nasObj = $null
        if (-not [string]::IsNullOrWhiteSpace($nasRaw)) {
            try { $nasObj = $nasRaw | ConvertFrom-Json -ErrorAction Stop } catch { $obj.notes += ("nas-health parse: " + $_.Exception.Message) }
        }

        $sshOk = Test-PSUHostSshConfigured
        $hostStacksRoot = Get-NasHostStacksRootForSsh
        $stackRestartAllowed = ($env:PSU_ALLOW_STACK_RESTART -eq "1")

        $hwSig = (Test-NasHardwareDegradedObject -nh $nasObj)
        $lmSig = (Test-NasLoadOrMemoryCritical -nh $nasObj -Load1Max $loadCritTh -MemAvailRatioMin $memRatioMin)
        $obj.nasHealthTriage = [ordered]@{
            load1            = $lmSig.load1
            loadCritical     = [bool]$lmSig.loadCritical
            memCritical      = [bool]$lmSig.memCritical
            hardwareDegraded = [bool]$hwSig.degraded
            hardwareReasons  = @($hwSig.reasons)
        }

        if ($env:PSU_SAFE_MODE_ENABLED -eq "1" -and $hwSig.degraded) {
            $obj.safeMode.triggered = $true
            $obj.safeMode.hardwareReasons = @($hwSig.reasons)
            $obj.actions += "Safe Mode: hardware degradation detected — stopping configured stacks and capturing manifest."
            $obj.safeMode.emergencyBackupManifest = @(Get-EmergencyBackupManifestEntries -RepoPath $Repo)
            Send-PSUSafeModeWebhookAlerts -Reason "hardware_degraded" -Detail (($hwSig.reasons | Out-String).Trim())
            if ($sshOk -and -not [string]::IsNullOrWhiteSpace($hostStacksRoot)) {
                $stopList = @()
                if (-not [string]::IsNullOrWhiteSpace($env:PSU_SAFE_MODE_STOP_STACKS)) {
                    $stopList = @($env:PSU_SAFE_MODE_STOP_STACKS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[a-zA-Z0-9._-]+$' })
                }
                $stopped = @()
                foreach ($sname in $stopList) {
                    $tstop = @'
set -e
d='__SR__/__SN__'
if [ ! -d "$d" ]; then exit 0; fi
if [ -f "$d/compose.yaml" ]; then f=compose.yaml
elif [ -f "$d/docker-compose.yaml" ]; then f=docker-compose.yaml
elif [ -f "$d/docker-compose.yml" ]; then f=docker-compose.yml
else exit 0; fi
cd "$d" && docker compose -f "$f" stop
'@
                    $rstop = Invoke-PSUHostSsh -RemoteBashScript ($tstop.Replace('__SR__', $hostStacksRoot).Replace('__SN__', $sname))
                    $stopped += [ordered]@{ stack = $sname; ssh = $rstop }
                    $obj.sshSessions += [ordered]@{ action = "safe_mode_compose_stop"; stack = $sname; ssh = $rstop }
                }
                $obj.safeMode.stoppedStacks = $stopped
            }
            else {
                $obj.safeMode.stoppedStacks = @()
                $obj.safeMode.note = "SSH or NAS_HOST_STACKS_ROOT not configured — stacks not stopped remotely."
            }
            if ($env:PSU_SAFE_MODE_QUEUE_BACKUP -ne "0" -and -not [string]::IsNullOrWhiteSpace($GalleryInit) -and (Test-Path -LiteralPath $GalleryInit)) {
                $dj = Join-Path ([System.IO.Path]::GetDirectoryName($GalleryInit)) "dockge-jobs.ps1"
                if (Test-Path -LiteralPath $dj) {
                    try {
                        . $dj
                        if (Get-Command Invoke-PSUJob_BackupSnapshot -ErrorAction SilentlyContinue) {
                            $obj.safeMode.backupSnapshotJob = Invoke-PSUJob_BackupSnapshot
                            $obj.actions += "Safe Mode: queued backup-snapshot job (Invoke-PSUJob_BackupSnapshot)."
                        }
                    }
                    catch { $obj.safeMode.backupSnapshotError = $_.Exception.Message }
                }
            }
            Add-RemediationAppendixToLatestReport -Root $reportsRoot -Prefix "nas-health" -Entry ([ordered]@{
                generatedAtUtc   = (Get-Date).ToUniversalTime().ToString("o")
                action           = "safe_mode_hardware"
                hardwareReasons  = @($hwSig.reasons)
                stoppedStacks    = $obj.safeMode.stoppedStacks
                backupSnapshot   = $obj.safeMode.backupSnapshotJob
                backupError      = $obj.safeMode.backupSnapshotError
            })
        }

        if ($env:PSU_REMEDIATION_CPU_TRIAGE -eq "1" -and $sshOk -and -not [string]::IsNullOrWhiteSpace($hostStacksRoot) -and $stackRestartAllowed -and ($lmSig.loadCritical -or $lmSig.memCritical)) {
            $obj.cpuTriage.triggered = $true
            $topRemote = @'
set -e
top -b -n 1 | head -n 40
echo '---DOCKERSTATS---'
docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' 2>/dev/null || true
'@
            $topR = Invoke-PSUHostSsh -RemoteBashScript $topRemote
            $obj.cpuTriage.topAndStats = $topR
            $cpuScript = @'
set +e
docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' 2>/dev/null | while IFS= read -r line; do
  [ -z "$line" ] && continue
  name="${line%% *}"
  pct="${line##* }"
  pct="${pct%%%}"
  awk -v p="$pct" -v th=__TH_INT__ 'BEGIN{exit !(p+0>=th)}' || continue
  svc=$(docker inspect -f '{{if .Config.Labels}}{{index .Config.Labels "com.docker.compose.service"}}{{end}}' "$name" 2>/dev/null || true)
  wd=$(docker inspect -f '{{if .Config.Labels}}{{index .Config.Labels "com.docker.compose.project.working_dir"}}{{end}}' "$name" 2>/dev/null || true)
  if [ -z "$svc" ] || [ -z "$wd" ] || [ ! -d "$wd" ]; then echo "skip $name (no compose labels)"; continue; fi
  if [ -f "$wd/compose.yaml" ]; then f=compose.yaml
  elif [ -f "$wd/docker-compose.yaml" ]; then f=docker-compose.yaml
  elif [ -f "$wd/docker-compose.yml" ]; then f=docker-compose.yml
  else echo "skip $name (no compose file)"; continue; fi
  (cd "$wd" && docker compose -f "$f" restart "$svc") && echo "restarted $name service=$svc in $wd"
done
exit 0
'@
            $cpuScript = $cpuScript.Replace('__TH_INT__', [string][int]$dockerCpuPct)
            $cpuR = Invoke-PSUHostSsh -RemoteBashScript $cpuScript
            $obj.cpuTriage.restartSsh = $cpuR
            $obj.sshSessions += [ordered]@{ action = "cpu_triage_compose_restart"; ssh = $cpuR }
            Add-RemediationAppendixToLatestReport -Root $reportsRoot -Prefix "nas-health" -Entry ([ordered]@{
                generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
                action         = "cpu_memory_triage"
                load1          = $lmSig.load1
                loadCritical   = [bool]$lmSig.loadCritical
                memCritical    = [bool]$lmSig.memCritical
                topStdout      = $topR.stdout
                topStderr      = $topR.stderr
                restartStdout  = $cpuR.stdout
                restartStderr  = $cpuR.stderr
                restartExit    = $cpuR.exitCode
            })
        }

        if (-not [string]::IsNullOrWhiteSpace($driftRaw)) {
            try { $obj.imageDriftReport = ($driftRaw | ConvertFrom-Json -ErrorAction Stop) } catch { $obj.notes += ("image-drift parse: " + $_.Exception.Message) }
        }
        else { $obj.notes += "No image-drift-*.json found yet (run Invoke-PSUJob_ImageDrift)." }

        if (-not [string]::IsNullOrWhiteSpace($analyzerRaw)) {
            try { $obj.analyzerLatest = ($analyzerRaw | ConvertFrom-Json -ErrorAction Stop) } catch { $obj.notes += ("analyzer-latest parse: " + $_.Exception.Message) }
        }
        else { $obj.notes += "analyzer-latest.json missing (GET /api/v1/analyzer/report or scheduled analyzer)." }

        if ($null -ne $obj.imageDriftReport -and $obj.imageDriftReport.floatingTags) {
            foreach ($ft in @($obj.imageDriftReport.floatingTags)) {
                $sn = [string]$ft.stack
                if ([string]::IsNullOrWhiteSpace($sn)) { continue }
                if (-not $stackRestartAllowed) {
                    $obj.sshStackRemediation += [ordered]@{
                        stack   = $sn
                        image   = $ft.image
                        skipped = "Set PSU_ALLOW_STACK_RESTART=1 to acknowledge host docker compose actions over SSH."
                    }
                    continue
                }
                if (-not $sshOk) {
                    $obj.sshStackRemediation += [ordered]@{
                        stack   = $sn
                        image   = $ft.image
                        skipped = "Configure NAS_HOST_IP, NAS_SSH_USER, SSH_KEY_PATH, and NAS_HOST_STACKS_ROOT (see NAS_HOST_SSH_SETUP.md)."
                    }
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($hostStacksRoot)) {
                    $obj.sshStackRemediation += [ordered]@{
                        stack   = $sn
                        image   = $ft.image
                        skipped = "NAS_HOST_STACKS_ROOT unset and PSU_STACK_ROOT is a container path (/nas-repo/...); set NAS_HOST_STACKS_ROOT to the host stacks dir (e.g. /volume1/docker/dockge/stacks)."
                    }
                    continue
                }
                if ($sn -notmatch '^[a-zA-Z0-9._-]+$') {
                    $obj.sshStackRemediation += [ordered]@{
                        stack   = $sn
                        image   = $ft.image
                        skipped = "Stack name failed safe character check for SSH remote script."
                    }
                    continue
                }
                $tplt = @'
set -e
d='__SR__/__SN__'
if [ ! -d "$d" ]; then echo "missing stack dir: $d" >&2; exit 2; fi
if [ -f "$d/compose.yaml" ]; then f=compose.yaml
elif [ -f "$d/docker-compose.yaml" ]; then f=docker-compose.yaml
elif [ -f "$d/docker-compose.yml" ]; then f=docker-compose.yml
else echo "no compose file in $d" >&2; exit 3; fi
cd "$d" && docker compose -f "$f" pull && docker compose -f "$f" up -d
'@
                $remote = $tplt.Replace('__SR__', $hostStacksRoot).Replace('__SN__', $sn)
                $r = Invoke-PSUHostSsh -RemoteBashScript $remote
                $row = [ordered]@{ stack = $sn; image = $ft.image; ssh = $r }
                $obj.sshStackRemediation += $row
                $obj.sshSessions += $row
                Add-RemediationAppendixToLatestReport -Root $reportsRoot -Prefix "image-drift" -Entry ([ordered]@{
                    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
                    action         = "compose_pull_up"
                    stack          = $sn
                    exitCode       = $r.exitCode
                    stdout         = $r.stdout
                    stderr         = $r.stderr
                })
            }
        }

        $obj.diskPressure = @(Test-NasHealthDiskPressure -JsonText $nasRaw -ThresholdPct $thresh)
        if ($obj.diskPressure.Count -gt 0) {
            $obj.actions += "Disk use at or above ${thresh}% on one or more mounts — review nas-health report; reclaim space on the NAS host."
            if ($env:PSU_REMEDIATION_DOCKER_PRUNE -eq "1") {
                if (-not $sshOk) {
                    $obj.dockerPrune = @{ skipped = "PSU_REMEDIATION_DOCKER_PRUNE=1 requires SSH (NAS_HOST_IP, NAS_SSH_USER, SSH_KEY_PATH); in-container docker is not used." }
                }
                else {
                    try {
                        $r = Invoke-PSUHostSsh -RemoteBashScript 'docker image prune -a -f'
                        $obj.dockerPrune = $r
                        $obj.sshSessions += [ordered]@{ action = "docker_image_prune_a_f"; ssh = $r }
                        Add-RemediationAppendixToLatestReport -Root $reportsRoot -Prefix "nas-health" -Entry ([ordered]@{
                            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
                            action         = "docker_image_prune_a_f"
                            exitCode       = $r.exitCode
                            stdout         = $r.stdout
                            stderr         = $r.stderr
                        })
                    }
                    catch {
                        $obj.dockerPrune = @{ exitCode = -1; stderr = $_.Exception.Message }
                    }
                }
            }
            else {
                $obj.dockerPrune = @{ skipped = "Set PSU_REMEDIATION_DOCKER_PRUNE=1 to run docker image prune -a -f on the NAS host via SSH." }
            }
        }

        $obj.galleryModulesLoaded = @($galLoaded)
        ($obj | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $OutPath -Encoding UTF8
    }
    return (Start-PSUJsonReportJob -ReportBaseName "auto-remediation" -Worker $worker)
}

function Invoke-PSUJob_GitOpsSync {
    $worker = {
        param($OutPath, $Repo, $Stacks, $DockgeBase, $DockgeUser, $DockgePass, $GalleryInit)
        $galLoaded = @()
        if (-not [string]::IsNullOrWhiteSpace($GalleryInit) -and (Test-Path -LiteralPath $GalleryInit)) {
            . $GalleryInit
            if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
                try { $null = Import-PSUGalleryModules -Optional } catch { }
            }
            else {
                $null = Import-PSUGalleryModules
            }
            if ($null -ne $global:DockgePSUGalleryModuleState) {
                foreach ($kv in $global:DockgePSUGalleryModuleState.GetEnumerator()) {
                    if ($kv.Value.ok) { $galLoaded += $kv.Key }
                }
            }
        }
        elseif ($env:PSU_GALLERY_OPTIONAL -ne '1') {
            throw "Dockge PSU job: gallery init path missing."
        }
        $enabled = ($env:PSU_GITOPS_ENABLED -eq "1")
        $obj = [ordered]@{
            job              = "gitops-sync"
            generatedAtUtc   = (Get-Date).ToUniversalTime().ToString("o")
            enabled          = [bool]$enabled
            repo             = $Repo
            porcelain        = ""
            branch           = ""
            actions          = @()
            commitSha        = $null
            push             = $null
        }
        if (-not $enabled) {
            $obj.actions += "Set PSU_GITOPS_ENABLED=1 after mounting /nas-repo read-write and configuring git identity + credentials on the host."
            $obj.galleryModulesLoaded = @($galLoaded)
            ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $OutPath -Encoding UTF8
            return
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Repo ".git"))) {
            $obj.actions += "No .git at repo root — bind ${Repo} from a git checkout (not a bare export)."
            $obj.galleryModulesLoaded = @($galLoaded)
            ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $OutPath -Encoding UTF8
            return
        }
        try {
            $obj.branch = (& git -C $Repo rev-parse --abbrev-ref HEAD 2>$null)
        }
        catch { }
        try {
            $obj.porcelain = (& git -C $Repo status --porcelain -b 2>$null | Out-String).Trim()
        }
        catch { $obj.actions += ("git status failed: " + $_.Exception.Message) }

        if ([string]::IsNullOrWhiteSpace($obj.porcelain) -or $obj.porcelain -match '^\s*$') {
            $obj.actions += "Working tree clean (no commit)."
            $obj.galleryModulesLoaded = @($galLoaded)
            ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $OutPath -Encoding UTF8
            return
        }

        $wt = (& git -C $Repo status --porcelain 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($wt)) {
            $obj.actions += "Branch metadata only (no file changes); skipping commit."
            $obj.galleryModulesLoaded = @($galLoaded)
            ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $OutPath -Encoding UTF8
            return
        }

        if ($env:PSU_GITOPS_AUTO_COMMIT -ne "1") {
            $obj.actions += "Drift detected; set PSU_GITOPS_AUTO_COMMIT=1 (and optional PSU_GITOPS_AUTO_PUSH=1) to auto-commit. Never store PATs in git — use ~/.netrc, git credential helper, or SSH keys on the NAS host."
            $obj.galleryModulesLoaded = @($galLoaded)
            ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $OutPath -Encoding UTF8
            return
        }

        $gn = $env:PSU_GIT_USER_NAME
        $ge = $env:PSU_GIT_USER_EMAIL
        if (-not [string]::IsNullOrWhiteSpace($gn)) {
            $null = & git -C $Repo config user.name $gn 2>$null
        }
        if (-not [string]::IsNullOrWhiteSpace($ge)) {
            $null = & git -C $Repo config user.email $ge 2>$null
        }

        try {
            $null = & git -C $Repo add -u 2>&1
            $null = & git -C $Repo diff --staged --quiet 2>$null
            if ($LASTEXITCODE -eq 0) {
                $obj.actions += "No staged changes after git add -u (untracked files are ignored — use host git or widen policy intentionally)."
                $obj.galleryModulesLoaded = @($galLoaded)
                ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $OutPath -Encoding UTF8
                return
            }
            $msg = if ($env:PSU_GITOPS_COMMIT_MESSAGE) { $env:PSU_GITOPS_COMMIT_MESSAGE } else { "chore(gitops): auto-sync drift configurations" }
            $commitOut = & git -C $Repo commit -m $msg 2>&1
            $obj.actions += ("commit: " + ($commitOut | Out-String).Trim())
            try { $obj.commitSha = (& git -C $Repo rev-parse HEAD 2>$null) } catch { }
        }
        catch {
            $obj.actions += ("commit failed: " + $_.Exception.Message)
            $obj.galleryModulesLoaded = @($galLoaded)
            ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $OutPath -Encoding UTF8
            return
        }

        if ($env:PSU_GITOPS_AUTO_PUSH -eq "1") {
            try {
                $pushOut = & git -C $Repo push 2>&1
                $obj.push = @{ ok = $true; output = ($pushOut | Out-String).Trim() }
            }
            catch {
                $obj.push = @{ ok = $false; error = $_.Exception.Message }
            }
        }
        else {
            $obj.push = @{ skipped = "Set PSU_GITOPS_AUTO_PUSH=1 after verifying credentials on the NAS (SSH/PAT)." }
        }

        $obj.galleryModulesLoaded = @($galLoaded)
        ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $OutPath -Encoding UTF8
    }
    return (Start-PSUJsonReportJob -ReportBaseName "gitops-sync" -Worker $worker)
}

$script:DockgeGalleryInitForInteractive = Join-Path $PSScriptRoot "Import-PSUGalleryModules.ps1"
if (Test-Path -LiteralPath $script:DockgeGalleryInitForInteractive) {
    . $script:DockgeGalleryInitForInteractive
    if ($env:PSU_GALLERY_OPTIONAL -eq '1') {
        try { Import-PSUGalleryModules -Optional | Out-Null } catch { Write-Warning "dockge-jobs.ps1: gallery import (optional): $($_.Exception.Message)" }
    }
    else {
        Import-PSUGalleryModules | Out-Null
    }
}
elseif ($env:PSU_GALLERY_OPTIONAL -ne '1') {
    throw "dockge-jobs.ps1: Import-PSUGalleryModules.ps1 not found at '$script:DockgeGalleryInitForInteractive'."
}

Write-Output "dockge-jobs.ps1: loaded Phase 2 jobs. Call Invoke-PSUJob_* from PSU schedules (each queues a background JSON report)."
