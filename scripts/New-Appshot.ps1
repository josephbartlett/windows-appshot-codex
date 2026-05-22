[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [Alias("WindowQuery")]
    [string[]]$Query = @(),
    [string]$OutDir = (Join-Path (Get-Location) "appshots"),
    [int]$DelayMilliseconds = 1200,
    [ValidateSet("None", "NewThread", "Exec", "ResumeLastExec")]
    [string]$CommandTarget = "NewThread",
    [string]$Task = "Use this Windows appshot as context. Read the generated prompt and text files, inspect the attached screenshot, and ask me what to do next if the task is not clear.",
    [switch]$ListWindows,
    [int]$TargetIndex = 0,
    [switch]$NoWindowConfirmation,
    [int]$MaxWindowMatches = 10,
    [switch]$NoClipboard,
    [switch]$OpenFolder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Add-AppshotNativeTypes {
    if ("AppshotNative" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class AppshotNative
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetShellWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT rect, int size);
}
"@
}

function Get-WindowTextValue {
    param([IntPtr]$Hwnd)

    $builder = [System.Text.StringBuilder]::new(4096)
    [void][AppshotNative]::GetWindowText($Hwnd, $builder, $builder.Capacity)
    $builder.ToString()
}

function Get-WindowClassName {
    param([IntPtr]$Hwnd)

    $builder = [System.Text.StringBuilder]::new(512)
    [void][AppshotNative]::GetClassName($Hwnd, $builder, $builder.Capacity)
    $builder.ToString()
}

function Get-WindowBounds {
    param([IntPtr]$Hwnd)

    $rect = New-Object AppshotNative+RECT
    $dwmResult = -1
    try {
        $dwmResult = [AppshotNative]::DwmGetWindowAttribute(
            $Hwnd,
            9,
            [ref]$rect,
            [Runtime.InteropServices.Marshal]::SizeOf([type][AppshotNative+RECT])
        )
    }
    catch {
        $dwmResult = -1
    }

    if ($dwmResult -ne 0) {
        if (-not [AppshotNative]::GetWindowRect($Hwnd, [ref]$rect)) {
            throw "Could not read foreground window bounds."
        }
    }

    [pscustomobject]@{
        Left   = $rect.Left
        Top    = $rect.Top
        Right  = $rect.Right
        Bottom = $rect.Bottom
        Width  = $rect.Right - $rect.Left
        Height = $rect.Bottom - $rect.Top
    }
}

function ConvertTo-Slug {
    param(
        [string]$Text,
        [string]$Fallback = "window"
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Fallback
    }

    $normalized = $Text.ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    $normalized = $normalized.Trim("-")
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $Fallback
    }

    if ($normalized.Length -gt 48) {
        return $normalized.Substring(0, 48).Trim("-")
    }

    $normalized
}

function Get-QueryText {
    param([string[]]$Parts)

    if ($null -eq $Parts -or $Parts.Count -eq 0) {
        return ""
    }

    (($Parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " ").Trim()
}

function Get-QueryTokens {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    @($Text.ToLowerInvariant() -split "[^a-z0-9]+" | Where-Object { $_.Length -gt 0 })
}

function Get-ProcessSearchAliases {
    param([string]$ProcessName)

    switch ($ProcessName.ToLowerInvariant()) {
        "msedge" { "edge microsoft-edge microsoft edge browser" }
        "chrome" { "chrome google-chrome google chrome browser" }
        "firefox" { "firefox mozilla browser" }
        "brave" { "brave browser" }
        "robloxstudiobeta" { "roblox studio roblox-studio" }
        "windowsterminal" { "terminal windows-terminal powershell pwsh" }
        default { "" }
    }
}

function Get-VisibleTopLevelWindows {
    $windows = [System.Collections.Generic.List[object]]::new()
    $shellWindow = [AppshotNative]::GetShellWindow()

    $callback = [AppshotNative+EnumWindowsProc]{
        param([IntPtr]$Hwnd, [IntPtr]$LParam)

        try {
            if ($Hwnd -eq [IntPtr]::Zero -or $Hwnd -eq $shellWindow) {
                return $true
            }

            if (-not [AppshotNative]::IsWindowVisible($Hwnd)) {
                return $true
            }

            $title = Get-WindowTextValue -Hwnd $Hwnd
            if ([string]::IsNullOrWhiteSpace($title)) {
                return $true
            }

            $bounds = Get-WindowBounds -Hwnd $Hwnd
            if ($bounds.Width -lt 80 -or $bounds.Height -lt 80) {
                return $true
            }

            $processId = [uint32]0
            [void][AppshotNative]::GetWindowThreadProcessId($Hwnd, [ref]$processId)
            $process = $null
            try {
                $process = Get-Process -Id ([int]$processId) -ErrorAction Stop
            }
            catch {}

            $processName = if ($process) { $process.ProcessName } else { "unknown" }
            $className = Get-WindowClassName -Hwnd $Hwnd

            $windows.Add([pscustomobject]@{
                Hwnd = $Hwnd
                HwndInt64 = $Hwnd.ToInt64()
                Title = $title
                ProcessId = [int]$processId
                ProcessName = $processName
                ClassName = $className
                Bounds = $bounds
                SearchText = "$title $processName $className $(Get-ProcessSearchAliases -ProcessName $processName)"
            })
        }
        catch {}

        return $true
    }

    [void][AppshotNative]::EnumWindows($callback, [IntPtr]::Zero)
    $windows.ToArray()
}

function Get-TextMatchScore {
    param(
        [string]$QueryText,
        [string[]]$Tokens,
        [string]$Text,
        [int]$BaseScore = 0
    )

    if ([string]::IsNullOrWhiteSpace($QueryText) -or [string]::IsNullOrWhiteSpace($Text)) {
        return 0
    }

    $lowerText = $Text.ToLowerInvariant()
    $lowerQuery = $QueryText.ToLowerInvariant()
    $score = $BaseScore

    if ($lowerText.Contains($lowerQuery)) {
        $score += 60
    }

    foreach ($token in $Tokens) {
        if ($lowerText -match "(^|[^a-z0-9])$([regex]::Escape($token))([^a-z0-9]|$)") {
            $score += 25
        }
        elseif ($lowerText.Contains($token)) {
            $score += 12
        }
    }

    $score
}

function Get-BrowserTabMatches {
    param(
        [object]$Window,
        [string]$QueryText,
        [string[]]$Tokens,
        [int]$MaxTabs = 50
    )

    if ($Window.ProcessName -notin @("msedge", "chrome", "firefox", "brave")) {
        return @()
    }

    try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
    }
    catch {
        return @()
    }

    $matches = [System.Collections.Generic.List[object]]::new()

    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($Window.Hwnd)
        if ($null -eq $root) {
            return @()
        }

        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::TabItem
        )
        $tabItems = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        $count = [Math]::Min($tabItems.Count, $MaxTabs)

        for ($i = 0; $i -lt $count; $i++) {
            $tab = $tabItems.Item($i)
            $tabName = ""
            try { $tabName = $tab.Current.Name } catch {}
            if ([string]::IsNullOrWhiteSpace($tabName)) {
                continue
            }

            $tabScore = Get-TextMatchScore -QueryText $QueryText -Tokens $Tokens -Text $tabName
            if ($tabScore -le 0) {
                continue
            }

            $windowScore = Get-TextMatchScore -QueryText $QueryText -Tokens $Tokens -Text $Window.SearchText
            $score = $tabScore + [Math]::Min($windowScore, 25)

            $matches.Add([pscustomobject]@{
                Hwnd = $Window.Hwnd
                HwndInt64 = $Window.HwndInt64
                Title = $Window.Title
                ProcessId = $Window.ProcessId
                ProcessName = $Window.ProcessName
                ClassName = $Window.ClassName
                Bounds = $Window.Bounds
                MatchKind = "BrowserTab"
                TabName = $tabName
                TabElement = $tab
                Score = $score
                SearchText = "$tabName $($Window.SearchText)"
            })
        }
    }
    catch {}

    $matches.ToArray()
}

function Find-AppshotTargets {
    param(
        [string]$QueryText,
        [int]$MaxMatches = 10
    )

    $tokens = Get-QueryTokens -Text $QueryText
    $windows = @(Get-VisibleTopLevelWindows)
    $matches = [System.Collections.Generic.List[object]]::new()

    foreach ($window in $windows) {
        $score = Get-TextMatchScore -QueryText $QueryText -Tokens $tokens -Text $window.SearchText
        if ($score -gt 0) {
            $matches.Add([pscustomobject]@{
                Hwnd = $window.Hwnd
                HwndInt64 = $window.HwndInt64
                Title = $window.Title
                ProcessId = $window.ProcessId
                ProcessName = $window.ProcessName
                ClassName = $window.ClassName
                Bounds = $window.Bounds
                MatchKind = "Window"
                TabName = $null
                TabElement = $null
                Score = $score
                SearchText = $window.SearchText
            })
        }

        foreach ($tabMatch in @(Get-BrowserTabMatches -Window $window -QueryText $QueryText -Tokens $tokens)) {
            $matches.Add($tabMatch)
        }
    }

    $matches |
        Sort-Object -Property @{ Expression = "Score"; Descending = $true }, @{ Expression = "MatchKind"; Descending = $false }, Title |
        Select-Object -First $MaxMatches
}

function Format-AppshotTarget {
    param(
        [object]$Target,
        [int]$Index
    )

    $label = if ($Target.MatchKind -eq "BrowserTab") {
        "$($Target.ProcessName) tab '$($Target.TabName)' in '$($Target.Title)'"
    }
    else {
        "$($Target.ProcessName) window '$($Target.Title)'"
    }

    "{0}. [{1}] score={2} pid={3} {4}" -f $Index, $Target.MatchKind, $Target.Score, $Target.ProcessId, $label
}

function Select-AppshotTarget {
    param(
        [string]$QueryText,
        [int]$MaxMatches,
        [int]$TargetIndex = 0,
        [switch]$NoConfirmation
    )

    $matches = @(Find-AppshotTargets -QueryText $QueryText -MaxMatches $MaxMatches)
    if ($matches.Count -eq 0) {
        throw "No visible window or browser tab matched query '$QueryText'. Use -ListWindows to inspect visible top-level windows."
    }

    Write-Host "Matched appshot targets for '$QueryText':"
    for ($i = 0; $i -lt $matches.Count; $i++) {
        Write-Host (Format-AppshotTarget -Target $matches[$i] -Index ($i + 1))
    }

    if ($TargetIndex -gt 0) {
        if ($TargetIndex -gt $matches.Count) {
            throw "Target index $TargetIndex is outside the available match range 1-$($matches.Count)."
        }

        $indexedTarget = $matches[$TargetIndex - 1]
        if ($indexedTarget.MatchKind -eq "BrowserTab" -and -not $NoConfirmation) {
            throw "Target index $TargetIndex selects a browser tab. Rerun with -NoWindowConfirmation only if you intentionally trust this tab activation."
        }

        return $indexedTarget
    }

    $top = $matches[0]
    $needsConfirmation = -not $NoConfirmation -and ($matches.Count -gt 1 -or $top.MatchKind -eq "BrowserTab" -or $top.Score -lt 70)
    if (-not $needsConfirmation) {
        return $top
    }

    $answer = Read-Host "Capture which target? Enter 1-$($matches.Count), or press Enter to cancel"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        throw "Appshot capture cancelled."
    }

    $selectedIndex = 0
    if (-not [int]::TryParse($answer, [ref]$selectedIndex) -or $selectedIndex -lt 1 -or $selectedIndex -gt $matches.Count) {
        throw "Invalid appshot target selection '$answer'."
    }

    $matches[$selectedIndex - 1]
}

function Request-AppshotForeground {
    param(
        [IntPtr]$Hwnd,
        [int]$TimeoutMilliseconds = 1500
    )

    $attempts = 0
    $setForegroundSucceeded = $false
    $bringWindowSucceeded = $false
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)

    do {
        $attempts++

        if ([AppshotNative]::IsIconic($Hwnd)) {
            [void][AppshotNative]::ShowWindow($Hwnd, 9)
        }
        else {
            [void][AppshotNative]::ShowWindow($Hwnd, 5)
        }

        $foreground = [AppshotNative]::GetForegroundWindow()
        $currentThread = [AppshotNative]::GetCurrentThreadId()
        $targetProcessId = [uint32]0
        $foregroundProcessId = [uint32]0
        $targetThread = [AppshotNative]::GetWindowThreadProcessId($Hwnd, [ref]$targetProcessId)
        $foregroundThread = if ($foreground -ne [IntPtr]::Zero) {
            [AppshotNative]::GetWindowThreadProcessId($foreground, [ref]$foregroundProcessId)
        }
        else {
            [uint32]0
        }

        $attachedTarget = $false
        $attachedForeground = $false
        try {
            if ($targetThread -ne 0 -and $targetThread -ne $currentThread) {
                $attachedTarget = [AppshotNative]::AttachThreadInput($currentThread, $targetThread, $true)
            }
            if ($foregroundThread -ne 0 -and $foregroundThread -ne $currentThread -and $foregroundThread -ne $targetThread) {
                $attachedForeground = [AppshotNative]::AttachThreadInput($currentThread, $foregroundThread, $true)
            }

            $bringWindowSucceeded = [AppshotNative]::BringWindowToTop($Hwnd) -or $bringWindowSucceeded
            $setForegroundSucceeded = [AppshotNative]::SetForegroundWindow($Hwnd) -or $setForegroundSucceeded
        }
        finally {
            if ($attachedForeground) {
                [void][AppshotNative]::AttachThreadInput($currentThread, $foregroundThread, $false)
            }
            if ($attachedTarget) {
                [void][AppshotNative]::AttachThreadInput($currentThread, $targetThread, $false)
            }
        }

        Start-Sleep -Milliseconds 100
    } while ([AppshotNative]::GetForegroundWindow() -ne $Hwnd -and [DateTimeOffset]::UtcNow -lt $deadline)

    [pscustomobject]@{
        foregroundRequested = $true
        foregroundVerified = ([AppshotNative]::GetForegroundWindow() -eq $Hwnd)
        setForegroundSucceeded = $setForegroundSucceeded
        bringWindowSucceeded = $bringWindowSucceeded
        attempts = $attempts
    }
}

function Test-BrowserTabElementSelected {
    param([object]$Target)

    if ($Target.MatchKind -ne "BrowserTab" -or $null -eq $Target.TabElement) {
        return $null
    }

    try {
        $selectPattern = $Target.TabElement.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        if ($null -ne $selectPattern) {
            return [bool]$selectPattern.Current.IsSelected
        }
    }
    catch {}

    return $null
}

function Invoke-AppshotTarget {
    param([object]$Target)

    if ([AppshotNative]::IsIconic($Target.Hwnd)) {
        [void][AppshotNative]::ShowWindow($Target.Hwnd, 9)
    }

    if ($Target.MatchKind -eq "BrowserTab" -and $null -ne $Target.TabElement) {
        $tabActionSucceeded = $false
        try {
            $selectPattern = $Target.TabElement.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if ($null -ne $selectPattern) {
                $selectPattern.Select()
                $tabActionSucceeded = $true
            }
        }
        catch {
            try {
                $invokePattern = $Target.TabElement.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                if ($null -ne $invokePattern) {
                    $invokePattern.Invoke()
                    $tabActionSucceeded = $true
                }
            }
            catch {}
        }

        if (-not $tabActionSucceeded) {
            throw "Matched browser tab '$($Target.TabName)' could not be selected through UI Automation."
        }
    }

    Request-AppshotForeground -Hwnd $Target.Hwnd
}

function Test-WindowTitleMatchesTab {
    param(
        [string]$Title,
        [string]$TabName
    )

    if ([string]::IsNullOrWhiteSpace($Title) -or [string]::IsNullOrWhiteSpace($TabName)) {
        return $false
    }

    $titleLower = $Title.ToLowerInvariant()
    $tabLower = $TabName.ToLowerInvariant()
    if ($titleLower.Contains($tabLower)) {
        return $true
    }

    $ignored = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($word in @("the", "and", "tab", "edge", "chrome", "firefox", "brave", "microsoft", "google", "browser", "memory", "usage", "personal")) {
        [void]$ignored.Add($word)
    }

    $tokens = @(Get-QueryTokens -Text $TabName | Where-Object { $_.Length -ge 4 -and -not $ignored.Contains($_) })
    if ($tokens.Count -lt 2) {
        return $false
    }

    $matchedCount = 0
    foreach ($token in $tokens) {
        if ($titleLower.Contains($token)) {
            $matchedCount++
        }
    }

    $requiredCount = [Math]::Min($tokens.Count, [Math]::Max(2, [Math]::Ceiling($tokens.Count * 0.5)))
    $matchedCount -ge $requiredCount
}

function Test-AppshotTargetActive {
    param([object]$Target)

    $foreground = [AppshotNative]::GetForegroundWindow()
    $foregroundMatches = $foreground -eq $Target.Hwnd
    $activeTitle = Get-WindowTextValue -Hwnd $Target.Hwnd
    $tabTitleMatches = $null
    $tabSelectionVerified = $null

    if (-not $foregroundMatches) {
        throw "Matched target '$($Target.Title)' did not become the foreground window. Capture was cancelled to avoid a stale or occluded screenshot."
    }

    if ($Target.MatchKind -eq "BrowserTab") {
        $tabSelectionVerified = Test-BrowserTabElementSelected -Target $Target
        $tabTitleMatches = Test-WindowTitleMatchesTab -Title $activeTitle -TabName $Target.TabName
        if ($tabSelectionVerified -eq $false) {
            throw "Matched browser tab '$($Target.TabName)' is no longer selected. Capture was cancelled to avoid the wrong tab."
        }
        if ($tabSelectionVerified -ne $true -and -not $tabTitleMatches) {
            throw "Matched browser tab '$($Target.TabName)' could not be verified as the active tab. Active window title is '$activeTitle'."
        }
    }

    [pscustomobject]@{
        foregroundVerified = $foregroundMatches
        activeTitle = $activeTitle
        tabTitleVerified = $tabTitleMatches
        tabSelectionVerified = $tabSelectionVerified
    }
}

function Get-UiaText {
    param(
        [IntPtr]$Hwnd,
        [int]$MaxElements = 300,
        [int]$MaxTextChars = 60000
    )

    try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
    }
    catch {
        return [pscustomobject]@{
            Lines = @()
            Error = "UI Automation assemblies could not be loaded: $($_.Exception.Message)"
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
        if ($null -eq $root) {
            return [pscustomobject]@{ Lines = @(); Error = "UI Automation returned no root element." }
        }

        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue([pscustomobject]@{ Element = $root; SensitiveSubtree = $false })
        $scanned = 0
        $charCount = 0
        $elementLimitReached = $false

        while ($queue.Count -gt 0 -and $scanned -lt $MaxElements) {
            $entry = $queue.Dequeue()
            $element = $entry.Element
            $ancestorSensitive = [bool]$entry.SensitiveSubtree
            $scanned++

            $isOffscreen = $false
            try { $isOffscreen = [bool]$element.Current.IsOffscreen } catch {}

            $isPassword = $false
            try { $isPassword = [bool]$element.Current.IsPassword } catch {}

            $controlType = ""
            try { $controlType = $element.Current.ControlType.ProgrammaticName -replace "^ControlType\.", "" } catch {}

            $isSensitiveSubtree = $ancestorSensitive -or $isPassword -or $controlType -eq "Edit"

            try {
                if (-not $isOffscreen -and -not $isSensitiveSubtree) {
                    $child = $walker.GetFirstChild($element)
                    while ($null -ne $child) {
                        if (($scanned + $queue.Count) -ge $MaxElements) {
                            $elementLimitReached = $true
                            break
                        }

                        $queue.Enqueue([pscustomobject]@{ Element = $child; SensitiveSubtree = $isSensitiveSubtree })
                        $child = $walker.GetNextSibling($child)
                    }
                }
            }
            catch {}

            if ($isOffscreen -and $scanned -gt 1) {
                continue
            }

            if ($isSensitiveSubtree) {
                continue
            }

            if ($controlType -eq "Pane") {
                continue
            }

            $chunks = [System.Collections.Generic.List[string]]::new()

            if (-not [string]::IsNullOrWhiteSpace($controlType)) {
                $chunks.Add("[$controlType]")
            }

            try {
                $name = $element.Current.Name
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $chunks.Add($name.Trim())
                }
            }
            catch {}

            if ($controlType -ne "Edit") {
                try {
                    $valuePattern = $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                    if ($null -ne $valuePattern -and -not [string]::IsNullOrWhiteSpace($valuePattern.Current.Value)) {
                        $chunks.Add($valuePattern.Current.Value.Trim())
                    }
                }
                catch {}
            }

            if ($chunks.Count -eq 0) {
                continue
            }

            $line = (($chunks | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " ")
            $line = $line -replace "\s+", " "
            if ($line.Length -gt 1200) {
                $line = $line.Substring(0, 1200) + "..."
            }

            if ($seen.Add($line)) {
                $lines.Add($line)
                $charCount += $line.Length
            }

            if ($charCount -ge $MaxTextChars) {
                $lines.Add("[truncated after $MaxTextChars characters]")
                break
            }
        }

        if ($elementLimitReached -or $queue.Count -gt 0) {
            $lines.Add("[UI Automation traversal truncated after $scanned elements]")
        }

        [pscustomobject]@{ Lines = $lines.ToArray(); Error = $null }
    }
    catch {
        [pscustomobject]@{
            Lines = $lines.ToArray()
            Error = "UI Automation extraction failed: $($_.Exception.Message)"
        }
    }
}

function Save-WindowScreenshot {
    param(
        [object]$Bounds,
        [string]$Path
    )

    Add-Type -AssemblyName System.Drawing

    if ($Bounds.Width -le 0 -or $Bounds.Height -le 0) {
        throw "Foreground window has invalid bounds: $($Bounds | ConvertTo-Json -Compress)."
    }

    $bitmap = [System.Drawing.Bitmap]::new($Bounds.Width, $Bounds.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($Bounds.Left, $Bounds.Top, 0, 0, [System.Drawing.Size]::new($Bounds.Width, $Bounds.Height))
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Quote-PowerShellArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return "''"
    }

    "'" + ($Value -replace "'", "''") + "'"
}

function New-CodexCommand {
    param(
        [string]$Target,
        [string]$ImagePath,
        [string]$PromptPath,
        [string]$TaskText
    )

    if ($Target -eq "None") {
        return $null
    }

    $prompt = "Use this Windows appshot bundle. Read $PromptPath, inspect the attached screenshot, and help with this task: $TaskText"
    $imageArg = Quote-PowerShellArgument $ImagePath
    $promptArg = Quote-PowerShellArgument $prompt

    switch ($Target) {
        "NewThread"      { "codex -i $imageArg $promptArg" }
        "Exec"           { "codex exec -i $imageArg $promptArg" }
        "ResumeLastExec" { "codex exec resume --last -i $imageArg $promptArg" }
        default          { $null }
    }
}

Add-AppshotNativeTypes
Add-Type -AssemblyName System.Windows.Forms

$queryText = Get-QueryText -Parts $Query

if ($ListWindows) {
    if (-not [string]::IsNullOrWhiteSpace($queryText)) {
        $targets = @(Find-AppshotTargets -QueryText $queryText -MaxMatches $MaxWindowMatches)
        for ($i = 0; $i -lt $targets.Count; $i++) {
            [pscustomobject]@{
                Index = $i + 1
                MatchKind = $targets[$i].MatchKind
                Score = $targets[$i].Score
                ProcessName = $targets[$i].ProcessName
                ProcessId = $targets[$i].ProcessId
                Title = $targets[$i].Title
                TabName = $targets[$i].TabName
                ClassName = $targets[$i].ClassName
            }
        }
    }
    else {
        Get-VisibleTopLevelWindows |
            Sort-Object ProcessName, Title |
            Select-Object ProcessName, ProcessId, Title, ClassName,
                @{ Name = "Left"; Expression = { $_.Bounds.Left } },
                @{ Name = "Top"; Expression = { $_.Bounds.Top } },
                @{ Name = "Width"; Expression = { $_.Bounds.Width } },
                @{ Name = "Height"; Expression = { $_.Bounds.Height } }
    }
    return
}

$selectedTarget = $null
$activationInfo = $null
if (-not [string]::IsNullOrWhiteSpace($queryText)) {
    $selectedTarget = Select-AppshotTarget -QueryText $queryText -MaxMatches $MaxWindowMatches -TargetIndex $TargetIndex -NoConfirmation:$NoWindowConfirmation
    $activationInfo = Invoke-AppshotTarget -Target $selectedTarget
}

if ($DelayMilliseconds -gt 0) {
    Start-Sleep -Milliseconds $DelayMilliseconds
}

if ($selectedTarget) {
    $activationInfo = Test-AppshotTargetActive -Target $selectedTarget
}

$hwnd = if ($selectedTarget) { [IntPtr]$selectedTarget.Hwnd } else { [AppshotNative]::GetForegroundWindow() }
if ($hwnd -eq [IntPtr]::Zero) {
    throw "No foreground window is available."
}

$processId = [uint32]0
[void][AppshotNative]::GetWindowThreadProcessId($hwnd, [ref]$processId)
$process = $null
try {
    $process = Get-Process -Id ([int]$processId) -ErrorAction Stop
}
catch {}

$title = Get-WindowTextValue -Hwnd $hwnd
$className = Get-WindowClassName -Hwnd $hwnd
$bounds = Get-WindowBounds -Hwnd $hwnd
$timestamp = Get-Date
$stamp = $timestamp.ToString("yyyyMMdd-HHmmss")
$slugSource = if ($process) { $process.ProcessName } else { $title }
$slug = ConvertTo-Slug -Text $slugSource

$selectionInfo = if ($selectedTarget) {
    [ordered]@{
        query = $queryText
        matchKind = $selectedTarget.MatchKind
        tabName = $selectedTarget.TabName
        score = $selectedTarget.Score
        noWindowConfirmation = [bool]$NoWindowConfirmation
        activation = if ($activationInfo) {
            [ordered]@{
                foregroundVerified = $activationInfo.foregroundVerified
                activeTitle = $activationInfo.activeTitle
                tabTitleVerified = $activationInfo.tabTitleVerified
                tabSelectionVerified = $activationInfo.tabSelectionVerified
            }
        } else {
            $null
        }
    }
} else {
    $null
}

$captureDir = Join-Path $OutDir "$stamp-$slug"
New-Item -ItemType Directory -Force -Path $captureDir | Out-Null

$imagePath = Join-Path $captureDir "window.png"
$textPath = Join-Path $captureDir "window-text.txt"
$metadataPath = Join-Path $captureDir "metadata.json"
$promptPath = Join-Path $captureDir "prompt.md"
$latestPath = Join-Path $OutDir "latest.json"

Save-WindowScreenshot -Bounds $bounds -Path $imagePath
$uia = Get-UiaText -Hwnd $hwnd

$textHeader = @(
    "Windows appshot text",
    "Captured: $($timestamp.ToString("o"))",
    "Title: $title",
    "Process: $(if ($process) { $process.ProcessName } else { "unknown" }) ($processId)",
    "Class: $className",
    ""
)

if ($selectionInfo) {
    $textHeader += "Selection query: $($selectionInfo.query)"
    $textHeader += "Selection match: $($selectionInfo.matchKind) score=$($selectionInfo.score) tab=$($selectionInfo.tabName)"
    $textHeader += ""
}

if ($uia.Error) {
    $textHeader += "UI Automation warning: $($uia.Error)"
    $textHeader += ""
}

($textHeader + $uia.Lines) | Set-Content -Path $textPath -Encoding utf8

$metadata = [ordered]@{
    capturedAt = $timestamp.ToString("o")
    hwnd = $hwnd.ToInt64()
    title = $title
    className = $className
    processId = [int]$processId
    processName = if ($process) { $process.ProcessName } else { $null }
    processPath = if ($process) {
        try { $process.Path } catch { $null }
    } else {
        $null
    }
    bounds = [ordered]@{
        left = $bounds.Left
        top = $bounds.Top
        right = $bounds.Right
        bottom = $bounds.Bottom
        width = $bounds.Width
        height = $bounds.Height
    }
    files = [ordered]@{
        image = $imagePath
        text = $textPath
        prompt = $promptPath
    }
    selection = $selectionInfo
    textSource = "Windows UI Automation"
    textLineCount = $uia.Lines.Count
    textWarning = $uia.Error
}

$metadata | ConvertTo-Json -Depth 8 | Set-Content -Path $metadataPath -Encoding utf8

$promptMarkdown = @"
# Windows Appshot

Use this appshot as context from the user's foreground Windows app.

## Captured Window

- Title: $title
- Process: $(if ($process) { $process.ProcessName } else { "unknown" }) ($processId)
- Class: $className
- Captured: $($timestamp.ToString("o"))
- Selection query: $(if ($selectionInfo) { $selectionInfo.query } else { "foreground window" })
- Selection match: $(if ($selectionInfo) { "$($selectionInfo.matchKind) score=$($selectionInfo.score) tab=$($selectionInfo.tabName)" } else { "foreground window" })

## Files

- Screenshot: $imagePath
- UI Automation text: $textPath
- Metadata: $metadataPath

## User Task

$Task

## Handling Notes

- Treat the screenshot as the visual source of truth.
- Treat UI Automation text as helpful but incomplete; it intentionally skips off-screen, password, and editable text controls.
- If the task depends on hidden/off-screen app state, ask for another appshot or a direct file/export.
- Do not assume this is a native Codex Appshot; it is a local Windows bundle.
"@

$promptMarkdown | Set-Content -Path $promptPath -Encoding utf8
$command = New-CodexCommand -Target $CommandTarget -ImagePath $imagePath -PromptPath $promptPath -TaskText $Task

$latest = [ordered]@{
    capturedAt = $timestamp.ToString("o")
    directory = $captureDir
    image = $imagePath
    text = $textPath
    metadata = $metadataPath
    prompt = $promptPath
    commandTarget = $CommandTarget
    codexCommand = $command
}
$latest | ConvertTo-Json -Depth 6 | Set-Content -Path $latestPath -Encoding utf8

$clipboardUpdated = $false
if ($command -and -not $NoClipboard) {
    try {
        Set-Clipboard -Value $command
        $clipboardUpdated = $true
    }
    catch {
        Write-Warning "Appshot bundle was created, but clipboard update failed: $($_.Exception.Message)"
    }
}

if ($OpenFolder) {
    Invoke-Item $captureDir
}

[pscustomobject]@{
    Directory = $captureDir
    Image = $imagePath
    Text = $textPath
    Metadata = $metadataPath
    Prompt = $promptPath
    ClipboardUpdated = $clipboardUpdated
    CodexCommand = $command
}
