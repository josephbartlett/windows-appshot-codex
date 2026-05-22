[CmdletBinding()]
param(
    [string]$RepoUrl = "https://github.com/josephbartlett/windows-appshot-codex.git",
    [string]$PluginName = "windows-appshot",
    [string]$PluginsRoot = (Join-Path $HOME "plugins"),
    [string]$MarketplacePath = (Join-Path $HOME ".agents\plugins\marketplace.json"),
    [switch]$NoPull,
    [switch]$AllowDirty,
    [switch]$SkipCodexAdd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Git {
    param([string[]]$Arguments)

    & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Get-DefaultMarketplace {
    [pscustomobject]@{
        name = "personal"
        interface = [pscustomobject]@{
            displayName = "Personal"
        }
        plugins = @()
    }
}

function Test-ObjectProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    $null -ne $Object.PSObject.Properties[$Name]
}

function Ensure-Property {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    if (-not (Test-ObjectProperty -Object $Object -Name $Name)) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Set-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    if (Test-ObjectProperty -Object $Object -Name $Name) {
        $Object.PSObject.Properties[$Name].Value = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Copy-JsonObject {
    param([object]$Object)

    if ($null -eq $Object) {
        return [pscustomobject]@{}
    }

    $Object | ConvertTo-Json -Depth 20 | ConvertFrom-Json
}

function Merge-PluginEntry {
    param(
        [object]$Existing,
        [string]$PluginName
    )

    $merged = Copy-JsonObject -Object $Existing
    Set-PropertyValue -Object $merged -Name "name" -Value $PluginName

    if (-not (Test-ObjectProperty -Object $merged -Name "source") -or $null -eq $merged.source) {
        Set-PropertyValue -Object $merged -Name "source" -Value ([pscustomobject]@{})
    }
    Set-PropertyValue -Object $merged.source -Name "source" -Value "local"
    Set-PropertyValue -Object $merged.source -Name "path" -Value "./plugins/$PluginName"

    if (-not (Test-ObjectProperty -Object $merged -Name "policy") -or $null -eq $merged.policy) {
        Set-PropertyValue -Object $merged -Name "policy" -Value ([pscustomobject]@{})
    }
    Ensure-Property -Object $merged.policy -Name "installation" -Value "AVAILABLE"
    Ensure-Property -Object $merged.policy -Name "authentication" -Value "ON_INSTALL"
    Ensure-Property -Object $merged -Name "category" -Value "Productivity"

    $merged
}

function Get-GitStatusPorcelain {
    param([string]$Path)

    $output = & git -C $Path status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "git -C $Path status --porcelain failed with exit code $LASTEXITCODE."
    }

    @($output)
}

function Assert-CleanCheckout {
    param(
        [string]$Path,
        [string]$Reason
    )

    if ($AllowDirty) {
        Write-Warning "Skipping dirty checkout guard for $Path because -AllowDirty was supplied."
        return
    }

    $status = @(Get-GitStatusPorcelain -Path $Path)
    if ($status.Count -gt 0) {
        throw "Plugin checkout has local changes before $Reason`: $Path. Commit, stash, or rerun with -AllowDirty only for a development checkout."
    }
}

function Assert-PullReady {
    param([string]$Path)

    $branchOutput = @(& git -C $Path rev-parse --abbrev-ref HEAD)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the plugin checkout branch at $Path."
    }

    $branch = ($branchOutput | Select-Object -First 1).Trim()
    if ($branch -eq "HEAD") {
        throw "Plugin checkout is detached at $Path. Switch to a branch with an upstream, such as main, or reclone the plugin."
    }

    $upstreamOutput = @(& git -C $Path rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or $upstreamOutput.Count -eq 0 -or [string]::IsNullOrWhiteSpace(($upstreamOutput | Select-Object -First 1))) {
        throw "Plugin checkout branch '$branch' has no upstream at $Path. Set an upstream, rerun with -NoPull for a deliberate local checkout, or reclone the plugin."
    }
}

function Read-Marketplace {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return Get-DefaultMarketplace
    }

    try {
        $raw = Get-Content -Raw -LiteralPath $Path
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return Get-DefaultMarketplace
        }

        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed) {
            return Get-DefaultMarketplace
        }

        return $parsed
    }
    catch {
        throw "Could not parse marketplace JSON at $Path. Back up or repair that file, then rerun this installer. Original error: $($_.Exception.Message)"
    }
}

function Save-Marketplace {
    param(
        [object]$Marketplace,
        [string]$Path
    )

    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Item -LiteralPath $Path
        if ($existing.IsReadOnly) {
            throw "Marketplace file is read-only: $Path. Clear the read-only flag or pass a writable -MarketplacePath."
        }
    }

    $tempPath = Join-Path $dir ("marketplace.json.tmp.{0}" -f ([guid]::NewGuid().ToString("N")))
    $backupPath = "$Path.bak"

    try {
        $json = $Marketplace | ConvertTo-Json -Depth 20
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)
        $null = Get-Content -Raw -LiteralPath $tempPath | ConvertFrom-Json

        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($tempPath, $Path, $backupPath, $false)
        }
        else {
            Move-Item -LiteralPath $tempPath -Destination $Path
        }
    }
    catch {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
        throw "Could not safely write marketplace JSON at $Path. Original error: $($_.Exception.Message)"
    }
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    throw "git is required to install or update $PluginName."
}

$installPath = Join-Path $PluginsRoot $PluginName
$marketplaceDir = Split-Path -Parent $MarketplacePath
New-Item -ItemType Directory -Force -Path $marketplaceDir | Out-Null
$marketplace = Read-Marketplace -Path $MarketplacePath

if (Test-Path -LiteralPath $installPath) {
    if (-not (Test-Path -LiteralPath (Join-Path $installPath ".git"))) {
        throw "Install path exists but is not a git checkout: $installPath"
    }

    Assert-CleanCheckout -Path $installPath -Reason "updating"
    Write-Host "Updating existing plugin checkout: $installPath"
    if (-not $NoPull) {
        Assert-PullReady -Path $installPath
        Invoke-Git -Arguments @("-C", $installPath, "pull", "--ff-only")
        Assert-CleanCheckout -Path $installPath -Reason "marketplace registration"
    }
}
else {
    New-Item -ItemType Directory -Force -Path $PluginsRoot | Out-Null
    Write-Host "Cloning $RepoUrl to $installPath"
    Invoke-Git -Arguments @("clone", $RepoUrl, $installPath)
}

$manifestPath = Join-Path $installPath ".codex-plugin\plugin.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Installed checkout is missing .codex-plugin\plugin.json."
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.name -ne $PluginName) {
    throw "Installed plugin manifest name is '$($manifest.name)', expected '$PluginName'."
}

Ensure-Property -Object $marketplace -Name "name" -Value "personal"
Ensure-Property -Object $marketplace -Name "interface" -Value ([pscustomobject]@{ displayName = "Personal" })
Ensure-Property -Object $marketplace -Name "plugins" -Value @()

if ($null -eq $marketplace.interface) {
    $marketplace.interface = [pscustomobject]@{ displayName = "Personal" }
}
Ensure-Property -Object $marketplace.interface -Name "displayName" -Value "Personal"

$updatedPlugins = @()
$entryAdded = $false
foreach ($plugin in @($marketplace.plugins)) {
    $pluginNameValue = $null
    if ($null -ne $plugin -and (Test-ObjectProperty -Object $plugin -Name "name")) {
        $pluginNameValue = $plugin.name
    }

    if ($pluginNameValue -eq $PluginName) {
        if (-not $entryAdded) {
            $updatedPlugins += (Merge-PluginEntry -Existing $plugin -PluginName $PluginName)
            $entryAdded = $true
        }
    }
    else {
        $updatedPlugins += $plugin
    }
}

if (-not $entryAdded) {
    $updatedPlugins += (Merge-PluginEntry -Existing $null -PluginName $PluginName)
}

$marketplace.plugins = @($updatedPlugins)
Save-Marketplace -Marketplace $marketplace -Path $MarketplacePath

$codexAddStatus = "skipped"
if (-not $SkipCodexAdd) {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if ($codex) {
        & codex plugin add "$PluginName@personal"
        if ($LASTEXITCODE -eq 0) {
            $codexAddStatus = "ok"
        }
        else {
            $codexAddStatus = "failed"
            Write-Warning "codex plugin add failed. The marketplace entry was still written to $MarketplacePath."
        }
    }
    else {
        $codexAddStatus = "codex-not-found"
        Write-Warning "Codex CLI was not found. Install the plugin later with: codex plugin add $PluginName@personal"
    }
}

[pscustomobject]@{
    plugin = $PluginName
    version = $manifest.version
    installPath = $installPath
    marketplacePath = $MarketplacePath
    codexPluginAdd = $codexAddStatus
}
