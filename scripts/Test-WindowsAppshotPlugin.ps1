[CmdletBinding()]
param(
    [string]$Root = "",
    [switch]$IncludeHotkeyValidation,
    [switch]$SkipInstallerSmoke
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $Root = (Get-Location).Path
    }
    else {
        $Root = Join-Path $PSScriptRoot ".."
    }
}

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-InstallerSmokeTest {
    param([string]$RootPath)

    $installerPath = Join-Path $RootPath "scripts\Install-WindowsAppshotPlugin.ps1"
    Assert-Condition (Test-Path -LiteralPath $installerPath) "Missing installer script: $installerPath"

    $base = Join-Path ([System.IO.Path]::GetTempPath()) ("windows-appshot-installer-test-{0}" -f ([guid]::NewGuid().ToString("N")))
    $pluginsRoot = Join-Path $base "plugins"
    $marketplacePath = Join-Path $base ".agents\plugins\marketplace.json"
    $marketplaceDir = Split-Path -Parent $marketplacePath
    $sourceRepo = Join-Path $base "source-repo"
    $badBase = $null

    function Invoke-SmokeInstaller {
        param([hashtable]$Parameters)

        $output = @(& $installerPath @Parameters)
        $result = $output |
            Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains "codexPluginAdd" } |
            Select-Object -Last 1

        Assert-Condition ($null -ne $result) "Installer smoke test did not receive a structured result object."
        $result
    }

    function Invoke-SmokeGit {
        param([string[]]$Arguments)

        & git @Arguments | Out-Null
        Assert-Condition ($LASTEXITCODE -eq 0) "Installer smoke git command failed: git $($Arguments -join ' ')"
    }

    try {
        Invoke-SmokeGit -Arguments @("clone", $RootPath, $sourceRepo)
        Invoke-SmokeGit -Arguments @("-C", $sourceRepo, "checkout", "-B", "installer-smoke")

        $freshBase = Join-Path $base "fresh install with spaces"
        $freshPluginsRoot = Join-Path $freshBase "plugins with spaces"
        $freshMarketplacePath = Join-Path $freshBase ".agents with spaces\plugins\marketplace.json"
        $fresh = Invoke-SmokeInstaller -Parameters @{
            RepoUrl = $sourceRepo
            PluginsRoot = $freshPluginsRoot
            MarketplacePath = $freshMarketplacePath
            SkipCodexAdd = $true
        }
        $freshMarketplace = Get-Content -Raw -LiteralPath $freshMarketplacePath | ConvertFrom-Json
        $freshEntries = @($freshMarketplace.plugins | Where-Object { $_.name -eq "windows-appshot" })

        Assert-Condition ($fresh.codexPluginAdd -eq "skipped") "Fresh installer smoke test should skip codex plugin add."
        Assert-Condition ($freshEntries.Count -eq 1) "Fresh installer run should create one windows-appshot marketplace entry."
        Assert-Condition ($freshEntries[0].source.path -eq "./plugins/windows-appshot") "Fresh installer run should write canonical windows-appshot source path."

        New-Item -ItemType Directory -Force -Path $marketplaceDir | Out-Null

        $existingMarketplace = [pscustomobject]@{
            name = "personal"
            interface = [pscustomobject]@{
                displayName = "Personal"
            }
            plugins = @(
                [pscustomobject]@{
                    name = "unrelated-plugin"
                    source = [pscustomobject]@{
                        source = "local"
                        path = "./plugins/unrelated-plugin"
                    }
                    policy = [pscustomobject]@{
                        installation = "AVAILABLE"
                        authentication = "ON_INSTALL"
                    }
                    category = "Productivity"
                },
                [pscustomobject]@{
                    name = "windows-appshot"
                    source = [pscustomobject]@{
                        source = "local"
                        path = "./plugins/old-windows-appshot"
                    }
                    policy = [pscustomobject]@{
                        installation = "CUSTOM_INSTALL"
                        authentication = "CUSTOM_AUTH"
                    }
                    category = "Custom"
                    customField = "keep-me"
                },
                [pscustomobject]@{
                    name = "windows-appshot"
                    source = [pscustomobject]@{
                        source = "local"
                        path = "./plugins/duplicate-windows-appshot"
                    }
                    policy = [pscustomobject]@{
                        installation = "AVAILABLE"
                        authentication = "ON_INSTALL"
                    }
                    category = "Productivity"
                }
            )
        }

        $existingMarketplace | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $marketplacePath -Encoding UTF8

        $installerParameters = @{
            RepoUrl = $sourceRepo
            PluginsRoot = $pluginsRoot
            MarketplacePath = $marketplacePath
            SkipCodexAdd = $true
        }
        $first = Invoke-SmokeInstaller -Parameters $installerParameters
        $second = Invoke-SmokeInstaller -Parameters $installerParameters

        $marketplace = Get-Content -Raw -LiteralPath $marketplacePath | ConvertFrom-Json
        $entries = @($marketplace.plugins | Where-Object { $_.name -eq "windows-appshot" })
        $unrelated = @($marketplace.plugins | Where-Object { $_.name -eq "unrelated-plugin" })
        $bytes = [System.IO.File]::ReadAllBytes($marketplacePath)
        $hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF

        Assert-Condition (($first.codexPluginAdd -eq "skipped") -and ($second.codexPluginAdd -eq "skipped")) "Installer smoke test should skip codex plugin add."
        Assert-Condition ($entries.Count -eq 1) "Installer should collapse duplicate windows-appshot marketplace entries."
        Assert-Condition ($entries[0].source.path -eq "./plugins/windows-appshot") "Installer should write canonical windows-appshot source path."
        Assert-Condition ($entries[0].policy.installation -eq "CUSTOM_INSTALL") "Installer should preserve existing installation policy fields."
        Assert-Condition ($entries[0].policy.authentication -eq "CUSTOM_AUTH") "Installer should preserve existing authentication policy fields."
        Assert-Condition ($entries[0].category -eq "Custom") "Installer should preserve existing category metadata."
        Assert-Condition ($entries[0].customField -eq "keep-me") "Installer should preserve unknown marketplace entry fields."
        Assert-Condition ($unrelated.Count -eq 1) "Installer should preserve unrelated marketplace entries."
        Assert-Condition (Test-Path -LiteralPath "$marketplacePath.bak") "Installer should create a marketplace backup when replacing an existing file."
        Assert-Condition (-not $hasUtf8Bom) "Installer should write marketplace JSON as UTF-8 without BOM."

        $detachedPluginsRoot = Join-Path $base "detached-plugins"
        $detachedInstallPath = Join-Path $detachedPluginsRoot "windows-appshot"
        $detachedMarketplacePath = Join-Path $base ".agents\plugins\detached-marketplace.json"
        Invoke-SmokeGit -Arguments @("clone", $sourceRepo, $detachedInstallPath)
        Invoke-SmokeGit -Arguments @("-C", $detachedInstallPath, "checkout", "--detach")
        $detachedBlocked = $false
        try {
            & $installerPath -RepoUrl $sourceRepo -PluginsRoot $detachedPluginsRoot -MarketplacePath $detachedMarketplacePath -SkipCodexAdd | Out-Null
        }
        catch {
            $detachedBlocked = $_.Exception.Message -like "*detached*"
        }
        Assert-Condition $detachedBlocked "Installer should report detached existing checkouts before pulling."

        $noUpstreamPluginsRoot = Join-Path $base "no-upstream-plugins"
        $noUpstreamInstallPath = Join-Path $noUpstreamPluginsRoot "windows-appshot"
        $noUpstreamMarketplacePath = Join-Path $base ".agents\plugins\no-upstream-marketplace.json"
        Invoke-SmokeGit -Arguments @("clone", $sourceRepo, $noUpstreamInstallPath)
        Invoke-SmokeGit -Arguments @("-C", $noUpstreamInstallPath, "checkout", "-B", "local-only")
        $noUpstreamBlocked = $false
        try {
            & $installerPath -RepoUrl $sourceRepo -PluginsRoot $noUpstreamPluginsRoot -MarketplacePath $noUpstreamMarketplacePath -SkipCodexAdd | Out-Null
        }
        catch {
            $noUpstreamBlocked = $_.Exception.Message -like "*no upstream*"
        }
        Assert-Condition $noUpstreamBlocked "Installer should report existing checkout branches without upstream before pulling."

        $dirtyFile = Join-Path $pluginsRoot "windows-appshot\dirty-smoke-test.txt"
        Set-Content -LiteralPath $dirtyFile -Value "dirty" -Encoding UTF8
        $dirtyBlocked = $false
        try {
            & $installerPath -RepoUrl $sourceRepo -PluginsRoot $pluginsRoot -MarketplacePath $marketplacePath -SkipCodexAdd | Out-Null
        }
        catch {
            $dirtyBlocked = $_.Exception.Message -like "*local changes*"
        }
        Assert-Condition $dirtyBlocked "Installer should block dirty existing checkouts by default."

        $badBase = Join-Path ([System.IO.Path]::GetTempPath()) ("windows-appshot-installer-bad-json-{0}" -f ([guid]::NewGuid().ToString("N")))
        $badPluginsRoot = Join-Path $badBase "plugins"
        $badMarketplacePath = Join-Path $badBase ".agents\plugins\marketplace.json"
        $badMarketplaceDir = Split-Path -Parent $badMarketplacePath
        New-Item -ItemType Directory -Force -Path $badMarketplaceDir | Out-Null
        Set-Content -LiteralPath $badMarketplacePath -Value "{ bad json" -Encoding UTF8

        $badJsonBlocked = $false
        try {
            & $installerPath -RepoUrl $sourceRepo -PluginsRoot $badPluginsRoot -MarketplacePath $badMarketplacePath -SkipCodexAdd | Out-Null
        }
        catch {
            $badJsonBlocked = $_.Exception.Message -like "*Could not parse marketplace JSON*"
        }
        Assert-Condition $badJsonBlocked "Installer should report malformed marketplace JSON clearly."
        Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $badPluginsRoot "windows-appshot"))) "Installer should not clone before rejecting malformed marketplace JSON."
    }
    finally {
        foreach ($path in @($base, $badBase)) {
            if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
                $resolved = (Resolve-Path -LiteralPath $path).Path
                if ($resolved.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
                    Remove-Item -LiteralPath $resolved -Recurse -Force
                }
            }
        }
    }
}

$rootPath = (Resolve-Path -LiteralPath $Root).Path

$manifestPath = Join-Path $rootPath ".codex-plugin\plugin.json"
$skillPath = Join-Path $rootPath "skills\windows-appshot\SKILL.md"
$readmePath = Join-Path $rootPath "README.md"
$gitignorePath = Join-Path $rootPath ".gitignore"

Assert-Condition (Test-Path -LiteralPath $manifestPath) "Missing plugin manifest: $manifestPath"
Assert-Condition (Test-Path -LiteralPath $skillPath) "Missing skill entrypoint: $skillPath"

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
Assert-Condition ($manifest.name -eq "windows-appshot") "plugin.json name must be windows-appshot."
Assert-Condition ($manifest.version -match "^\d+\.\d+\.\d+$") "plugin.json version must be semantic MAJOR.MINOR.PATCH."
Assert-Condition ($manifest.skills -eq "./skills/") "plugin.json skills must point to ./skills/."
Assert-Condition (-not [string]::IsNullOrWhiteSpace($manifest.interface.displayName)) "plugin.json interface.displayName is required."
Assert-Condition (-not [string]::IsNullOrWhiteSpace($manifest.interface.shortDescription)) "plugin.json interface.shortDescription is required."

$skill = Get-Content -Raw -LiteralPath $skillPath
$frontmatterMatch = [regex]::Match($skill, "(?s)^---\s*(.*?)\s*---")
Assert-Condition $frontmatterMatch.Success "SKILL.md must start with YAML frontmatter."
$frontmatter = $frontmatterMatch.Groups[1].Value
Assert-Condition ($frontmatter -match "(?m)^name:\s*windows-appshot\s*$") "SKILL.md frontmatter name must be windows-appshot."
Assert-Condition ($frontmatter -match "(?m)^description:\s*\S") "SKILL.md frontmatter description is required."
Assert-Condition ($skill -match [regex]::Escape('$windows-appshot')) "SKILL.md should document the plugin invocation."

if (Test-Path -LiteralPath $readmePath) {
    $readme = Get-Content -Raw -LiteralPath $readmePath
    Assert-Condition ($readme -match [regex]::Escape('$windows-appshot create a Windows appshot')) "README should lead with the plugin command."
    Assert-Condition ($readme -match "Direct PowerShell Reference") "README should keep direct script usage in a reference section."
    Assert-Condition ($readme -match "not native Codex Appshots") "README should preserve the non-native Appshots caveat."
}

if (Test-Path -LiteralPath $gitignorePath) {
    $gitignore = Get-Content -Raw -LiteralPath $gitignorePath
    Assert-Condition ($gitignore -match "(?m)^appshots/$") ".gitignore must ignore generated appshots/ output."
    Assert-Condition ($gitignore -match "(?m)^\*\.log$") ".gitignore must ignore logs."
}

$scriptPaths = @(
    "scripts\New-Appshot.ps1",
    "scripts\Start-AppshotHotkey.ps1",
    "scripts\Install-WindowsAppshotPlugin.ps1",
    "scripts\Test-WindowsAppshotPlugin.ps1"
)

foreach ($relativePath in $scriptPaths) {
    $scriptPath = Join-Path $rootPath $relativePath
    Assert-Condition (Test-Path -LiteralPath $scriptPath) "Missing required script: $relativePath"
    $null = [scriptblock]::Create((Get-Content -Raw -LiteralPath $scriptPath))
}

$captureScriptPath = Join-Path $rootPath "scripts\New-Appshot.ps1"
$captureScript = Get-Content -Raw -LiteralPath $captureScriptPath
Assert-Condition ($captureScript -match '\[string\]\$CommandTarget\s*=\s*"NewThread"') "New-Appshot.ps1 must keep NewThread as the default command target."
Assert-Condition ($captureScript -notmatch 'TextPattern') "New-Appshot.ps1 must not reintroduce aggregate TextPattern extraction."
Assert-Condition ($captureScript -match 'IsPassword') "New-Appshot.ps1 must keep password filtering."
Assert-Condition ($captureScript -match '\$controlType\s+-eq\s+"Edit"') "New-Appshot.ps1 must keep editable-control filtering."
Assert-Condition ($captureScript -match '\$controlType\s+-eq\s+"Pane"') "New-Appshot.ps1 must keep generic Pane filtering."
Assert-Condition ($captureScript -match '\[int\]\$MaxElements\s*=\s*300') "New-Appshot.ps1 must keep bounded UI Automation traversal."
Assert-Condition ($captureScript -match '\$scanned\s+-lt\s+\$MaxElements') "New-Appshot.ps1 must enforce the UI Automation element limit."
Assert-Condition ($captureScript -match 'IsOffscreen') "New-Appshot.ps1 must keep off-screen UI Automation filtering."
Assert-Condition ($captureScript -match '\$isOffscreen\s+-and\s+\$scanned\s+-gt\s+1') "New-Appshot.ps1 must skip off-screen descendants."
Assert-Condition ($captureScript -match 'function Quote-PowerShellArgument') "New-Appshot.ps1 must keep PowerShell argument quoting helper."
Assert-Condition ($captureScript -match '\$Value\s+-replace\s+"''",\s+"''''"') "New-Appshot.ps1 must keep single-quote escaping for generated commands."
Assert-Condition ($captureScript -match '\$imageArg\s*=\s*Quote-PowerShellArgument\s+\$ImagePath') "New-Appshot.ps1 must quote screenshot paths in generated commands."
Assert-Condition ($captureScript -match '\$promptArg\s*=\s*Quote-PowerShellArgument\s+\$prompt') "New-Appshot.ps1 must quote prompt text in generated commands."
Assert-Condition ($captureScript -match 'function Test-AppshotTargetActive') "New-Appshot.ps1 must verify matched targets before capture."
Assert-Condition ($captureScript -match 'did not become the foreground window') "New-Appshot.ps1 must fail closed when a matched target is not foreground."
Assert-Condition ($captureScript -match 'foregroundVerified') "New-Appshot.ps1 must record foreground verification metadata."
Assert-Condition ($captureScript -match 'function Test-BrowserTabElementSelected') "New-Appshot.ps1 must verify browser-tab selected state when available."
Assert-Condition ($captureScript -match 'function Test-WindowTitleMatchesTab') "New-Appshot.ps1 must verify browser-tab title fallback."
Assert-Condition ($captureScript -match 'tabSelectionVerified') "New-Appshot.ps1 must record browser-tab selection verification metadata."
Assert-Condition ($captureScript -match 'tabTitleVerified') "New-Appshot.ps1 must record browser-tab title verification metadata."
Assert-Condition ($captureScript -match 'Test-AppshotTargetActive\s+-Target\s+\$selectedTarget') "New-Appshot.ps1 must run target-active verification before capture."
Assert-Condition ($captureScript -match '(?s)MatchKind\s+-eq\s+"BrowserTab".*NoConfirmation') "New-Appshot.ps1 must keep BrowserTab TargetIndex confirmation protection."

if (-not $SkipInstallerSmoke) {
    Invoke-InstallerSmokeTest -RootPath $rootPath
}

if ($IncludeHotkeyValidation) {
    $hotkeyScript = Join-Path $rootPath "scripts\Start-AppshotHotkey.ps1"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $hotkeyScript -Hotkey "Ctrl+Shift+F12" -ValidateOnly
    if ($LASTEXITCODE -ne 0) {
        throw "Hotkey validation failed."
    }
}

Write-Host "Windows Appshot plugin validation passed for $rootPath"
