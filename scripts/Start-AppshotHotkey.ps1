[CmdletBinding()]
param(
    [string]$Hotkey = "Ctrl+Alt+Space",
    [string]$OutDir = (Join-Path (Get-Location) "appshots"),
    [ValidateSet("None", "NewThread", "Exec", "ResumeLastExec")]
    [string]$CommandTarget = "NewThread",
    [int]$DelayMilliseconds = 150,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Add-HotkeyNativeTypes {
    if ("AppshotHotkeyNative" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class AppshotHotkeyNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public UIntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT pt;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern sbyte GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
}
"@
}

function Resolve-Hotkey {
    param([string]$Value)

    Add-Type -AssemblyName System.Windows.Forms

    $parts = $Value -split "\+" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($parts.Count -lt 1) {
        throw "Hotkey cannot be empty."
    }

    $modifiers = 0
    $keyName = $null

    foreach ($part in $parts) {
        switch -Regex ($part.ToLowerInvariant()) {
            "^(ctrl|control)$" { $modifiers = $modifiers -bor 0x0002; continue }
            "^alt$"            { $modifiers = $modifiers -bor 0x0001; continue }
            "^shift$"          { $modifiers = $modifiers -bor 0x0004; continue }
            "^(win|windows)$"  { $modifiers = $modifiers -bor 0x0008; continue }
            default {
                if ($null -ne $keyName) {
                    throw "Hotkey must have exactly one non-modifier key: $Value"
                }
                $keyName = $part
            }
        }
    }

    if ($null -eq $keyName) {
        throw "Hotkey must include a non-modifier key: $Value"
    }

    $key = [System.Enum]::Parse([System.Windows.Forms.Keys], $keyName, $true)
    if ($null -eq $key) {
        throw "Unknown key '$keyName'. Use a System.Windows.Forms.Keys name, such as Space, F12, or Oem3."
    }

    [pscustomobject]@{
        Modifiers = [uint32]$modifiers
        Key = [uint32]$key
    }
}

$captureScript = Join-Path $PSScriptRoot "New-Appshot.ps1"
if (-not (Test-Path -LiteralPath $captureScript)) {
    throw "Missing capture script: $captureScript"
}

Add-HotkeyNativeTypes
$resolved = Resolve-Hotkey -Value $Hotkey
$hotkeyId = 9001

if (-not [AppshotHotkeyNative]::RegisterHotKey([IntPtr]::Zero, $hotkeyId, $resolved.Modifiers, $resolved.Key)) {
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "Could not register hotkey '$Hotkey' (Win32 error $errorCode). Try another hotkey."
}

try {
    if ($ValidateOnly) {
        Write-Host "Appshot hotkey validated: $Hotkey"
        return
    }

    Write-Host "Appshot hotkey registered: $Hotkey"
    Write-Host "Captures will be saved under: $OutDir"
    Write-Host "Press Ctrl+C in this terminal to stop."

    while ($true) {
        $msg = New-Object AppshotHotkeyNative+MSG
        $result = [AppshotHotkeyNative]::GetMessage([ref]$msg, [IntPtr]::Zero, 0, 0)
        if ($result -eq 0) {
            break
        }

        if ($msg.message -eq 0x0312 -and $msg.wParam.ToUInt32() -eq $hotkeyId) {
            try {
                & $captureScript -OutDir $OutDir -DelayMilliseconds $DelayMilliseconds -CommandTarget $CommandTarget
            }
            catch {
                Write-Warning "Appshot capture failed: $($_.Exception.Message)"
            }
        }
    }
}
finally {
    [void][AppshotHotkeyNative]::UnregisterHotKey([IntPtr]::Zero, $hotkeyId)
}
