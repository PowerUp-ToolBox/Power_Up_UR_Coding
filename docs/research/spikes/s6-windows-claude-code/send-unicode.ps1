# S6 check K: types text into the focused window with SendInput + KEYEVENTF_UNICODE,
# one INPUT pair (down, up) per UTF-16 code unit, then presses Enter.
# Throwaway spike code (#133). Windows PowerShell 5.1 or PowerShell 7, NOT elevated
# (UIPI blocks injection from a non-elevated process into an elevated window and
# the other way round; run both this script and the target at the same level).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File send-unicode.ps1 -Case all
#   powershell -NoProfile -ExecutionPolicy Bypass -File send-unicode.ps1 -Case emoji -Mode PairedDown
#
# -Case     bmp | emoji | code | all   (which test string(s) to send)
# -Mode     PerUnit    : high-down, high-up, low-down, low-up   (the plan's rule, default)
#           PairedDown : high-down, low-down, high-up, low-up   (fallback if PerUnit splits pairs)
# -DelayMs  pause between code units (default 0 = all units in one SendInput call)
# -NoEnter  type the text but do not press Enter
# -Countdown seconds to switch focus to the target window (default 5)
param(
    [ValidateSet('bmp', 'emoji', 'code', 'all')][string]$Case = 'all',
    [ValidateSet('PerUnit', 'PairedDown')][string]$Mode = 'PerUnit',
    [int]$DelayMs = 0,
    [switch]$NoEnter,
    [int]$Countdown = 5
)

$source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public static class SpikeInjector {
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion U; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);

    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint KEYEVENTF_UNICODE = 0x0004;
    const ushort VK_RETURN = 0x0D;
    static readonly ushort[] Modifiers = { 0x10, 0x11, 0x12, 0x5B, 0x5C, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5 };

    static INPUT Key(ushort vk, ushort scan, uint flags) {
        INPUT input = new INPUT();
        input.type = INPUT_KEYBOARD;
        input.U.ki.wVk = vk;
        input.U.ki.wScan = scan;
        input.U.ki.dwFlags = flags;
        return input;
    }

    public static string ForegroundTitle() {
        var sb = new System.Text.StringBuilder(512);
        GetWindowText(GetForegroundWindow(), sb, sb.Capacity);
        return sb.ToString();
    }

    // Returns "sent/expected lastError" so partial sends are visible.
    static string Send(List<INPUT> inputs) {
        if (inputs.Count == 0) return "0/0";
        uint sent = SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf(typeof(INPUT)));
        int err = sent == inputs.Count ? 0 : Marshal.GetLastWin32Error();
        return sent + "/" + inputs.Count + (err != 0 ? " lastError=" + err : "");
    }

    public static string ReleaseModifiers() {
        var inputs = new List<INPUT>();
        foreach (ushort vk in Modifiers) inputs.Add(Key(vk, 0, KEYEVENTF_KEYUP));
        return Send(inputs);
    }

    public static string TypeText(string text, bool pairedDown, int delayMs) {
        var all = new List<INPUT>();
        for (int i = 0; i < text.Length; i++) {
            char c = text[i];
            bool pair = pairedDown && char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]);
            if (pair) {
                char low = text[i + 1];
                all.Add(Key(0, c, KEYEVENTF_UNICODE));
                all.Add(Key(0, low, KEYEVENTF_UNICODE));
                all.Add(Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
                all.Add(Key(0, low, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
                i++;
            } else {
                all.Add(Key(0, c, KEYEVENTF_UNICODE));
                all.Add(Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            }
        }
        if (delayMs <= 0) return Send(all);
        int ok = 0;
        foreach (INPUT input in all) {
            ok += (int)SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT)));
            Thread.Sleep(delayMs);
        }
        return ok + "/" + all.Count;
    }

    public static string PressEnter() {
        var inputs = new List<INPUT>();
        inputs.Add(Key(VK_RETURN, 0, 0));
        inputs.Add(Key(VK_RETURN, 0, KEYEVENTF_KEYUP));
        return Send(inputs);
    }
}
'@
Add-Type -TypeDefinition $source -Language CSharp

# Test strings, built from code points so this file's own encoding cannot corrupt them.
function U([int[]]$codePoints) { -join ($codePoints | ForEach-Object { [char]::ConvertFromUtf32($_) }) }
$cases = [ordered]@{
    # "hello 世界"  (BMP CJK, one UTF-16 unit per character)
    bmp   = 'hello ' + (U 0x4E16, 0x754C)
    # "emoji 😀 and 𠮷 ok"  (two surrogate pairs: U+1F600 and CJK Ext-B U+20BB7)
    emoji = 'emoji ' + (U 0x1F600) + ' and ' + (U 0x20BB7) + ' ok'
    # "fix `parseConfig()` in src/app.ts — 修一下"  (code punctuation, em dash, CJK)
    code  = 'fix `parseConfig()` in src/app.ts ' + (U 0x2014) + ' ' + (U 0x4FEE, 0x4E00, 0x4E0B)
}
$selected = if ($Case -eq 'all') { @($cases.Keys) } else { @($Case) }

Write-Host "Switch focus to the target window now. Typing in $Countdown s (mode $Mode)..."
for ($i = $Countdown; $i -gt 0; $i--) { Write-Host "  $i"; Start-Sleep -Seconds 1 }
Write-Host ("target window: '{0}'" -f [SpikeInjector]::ForegroundTitle())
Write-Host ("release modifiers: {0}" -f [SpikeInjector]::ReleaseModifiers())

foreach ($name in $selected) {
    $text = $cases[$name]
    $units = ($text.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' '
    Write-Host ("[{0}] expected UTF-16 units: {1}" -f $name, $units)
    Write-Host ("[{0}] typed: {1}" -f $name, [SpikeInjector]::TypeText($text, $Mode -eq 'PairedDown', $DelayMs))
    if (-not $NoEnter) {
        Start-Sleep -Milliseconds 300
        Write-Host ("[{0}] enter: {1}" -f $name, [SpikeInjector]::PressEnter())
    }
    Start-Sleep -Milliseconds 800
}
Write-Host 'done'
