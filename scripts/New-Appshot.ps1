[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path (Get-Location) "appshots"),
    [int]$DelayMilliseconds = 1200,
    [ValidateSet("None", "NewThread", "Exec", "ResumeLastExec")]
    [string]$CommandTarget = "NewThread",
    [string]$Task = "Use this Windows appshot as context. Read the generated prompt and text files, inspect the attached screenshot, and ask me what to do next if the task is not clear.",
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
        $queue = [System.Collections.Generic.Queue[System.Windows.Automation.AutomationElement]]::new()
        $queue.Enqueue($root)
        $scanned = 0
        $charCount = 0
        $elementLimitReached = $false

        while ($queue.Count -gt 0 -and $scanned -lt $MaxElements) {
            $element = $queue.Dequeue()
            $scanned++

            try {
                $child = $walker.GetFirstChild($element)
                while ($null -ne $child) {
                    if (($scanned + $queue.Count) -ge $MaxElements) {
                        $elementLimitReached = $true
                        break
                    }

                    $queue.Enqueue($child)
                    $child = $walker.GetNextSibling($child)
                }
            }
            catch {}

            $isOffscreen = $false
            try { $isOffscreen = [bool]$element.Current.IsOffscreen } catch {}
            if ($isOffscreen -and $scanned -gt 1) {
                continue
            }

            $isPassword = $false
            try { $isPassword = [bool]$element.Current.IsPassword } catch {}
            if ($isPassword) {
                continue
            }

            $chunks = [System.Collections.Generic.List[string]]::new()

            try {
                $controlType = $element.Current.ControlType.ProgrammaticName -replace "^ControlType\.", ""
                if (-not [string]::IsNullOrWhiteSpace($controlType)) {
                    $chunks.Add("[$controlType]")
                }
            }
            catch {}

            try {
                $name = $element.Current.Name
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $chunks.Add($name.Trim())
                }
            }
            catch {}

            try {
                $valuePattern = $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                if ($null -ne $valuePattern -and -not [string]::IsNullOrWhiteSpace($valuePattern.Current.Value)) {
                    $chunks.Add($valuePattern.Current.Value.Trim())
                }
            }
            catch {}

            try {
                $textPattern = $element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
                if ($null -ne $textPattern) {
                    $text = $textPattern.DocumentRange.GetText(4096)
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        $chunks.Add(($text -replace "\s+", " ").Trim())
                    }
                }
            }
            catch {}

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

if ($DelayMilliseconds -gt 0) {
    Start-Sleep -Milliseconds $DelayMilliseconds
}

Add-AppshotNativeTypes
Add-Type -AssemblyName System.Windows.Forms

$hwnd = [AppshotNative]::GetForegroundWindow()
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

## Files

- Screenshot: $imagePath
- UI Automation text: $textPath
- Metadata: $metadataPath

## User Task

$Task

## Handling Notes

- Treat the screenshot as the visual source of truth.
- Treat UI Automation text as helpful but incomplete; it intentionally skips off-screen and password controls.
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
