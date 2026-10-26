Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Initialize-TubeDesktop {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    if (-not ('TubeJobNative' -as [type])) {
        Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TubeJobNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
'@
    }
}

function Get-TubeDesignWindow {
    $matches = @(Get-Process -Name sldworks -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like 'Tube Design*'
    })
    if ($matches.Count -ne 1) { throw 'Open exactly one visible Tube Design window, then try again. No application was launched or closed.' }
    return $matches[0]
}

function Set-VerifiedTubeForeground {
    param([IntPtr]$Handle, [int]$ProcessId)
    [void][TubeJobNative]::ShowWindow($Handle, 9)
    [void][TubeJobNative]::SetForegroundWindow($Handle)
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
        $foregroundProcess = [uint32]0
        $foreground = [TubeJobNative]::GetForegroundWindow()
        [void][TubeJobNative]::GetWindowThreadProcessId($foreground, [ref]$foregroundProcess)
        if ($foreground -eq $Handle -and $foregroundProcess -eq $ProcessId) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Tube Design could not be brought to the foreground. Click Tube Design, return to the helper, and try again.'
}

function Get-ImportDialog {
    param($Process)
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle)
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, 'Select the model to be imported.'
    )
    $matches = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition))
    # AutomationElementCollection is sometimes wrapped as one object by Windows PowerShell.
    $found = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $matches) {
        if ($item -is [System.Windows.Automation.AutomationElement]) { $found.Add($item) }
    }
    if ($found.Count -gt 1) { throw 'More than one import dialog was found. Close extra dialogs manually.' }
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}

function Invoke-TubeToolbar {
    param($Process, [ValidateSet('Import','Identify')][string]$Command)
    $commandId = if ($Command -eq 'Import') { 41699 } else { 41706 }
    $toolbarName = if ($Command -eq 'Import') { 'Standard' } else { 'Tubes' }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle)
    if (-not $root.Current.IsEnabled) { throw 'Tube Design has an open dialog. Finish or cancel it manually before continuing.' }
    $toolbarCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $toolbarName
    )
    $toolbars = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $toolbarCondition)
    $buttons = New-Object 'System.Collections.Generic.List[object]'
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, ('Item ' + $commandId)
    )
    foreach ($toolbar in $toolbars) {
        foreach ($button in $toolbar.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
            if ($button.Current.IsEnabled -and -not $button.Current.IsOffscreen) { $buttons.Add($button) }
        }
    }
    if ($buttons.Count -ne 1) { throw "The recorded $Command toolbar control is unavailable. Use the command manually; no substitute button was clicked." }
    Set-VerifiedTubeForeground $Process.MainWindowHandle $Process.Id
    # Standard WM_COMMAND dispatch, only after finding the exact enabled toolbar ID
    # observed in the user's archived UI tree and recording. No coordinates/SendKeys.
    if (-not [TubeJobNative]::PostMessage($Process.MainWindowHandle, 0x111, [IntPtr]$commandId, [IntPtr]::Zero)) {
        throw 'Windows rejected the toolbar command.'
    }
}

function Invoke-TubeImport {
    param([string]$InputPath)
    Initialize-TubeDesktop
    $file = Get-Item -LiteralPath $InputPath
    if ($file.Extension -notmatch '^(?i:\.stp|\.step|\.sldprt)$') { throw 'Unsupported CAD file.' }
    $process = Get-TubeDesignWindow
    $dialog = Get-ImportDialog $process
    if ($null -eq $dialog) {
        Invoke-TubeToolbar $process Import
        $deadline = [DateTime]::UtcNow.AddSeconds(6)
        do {
            Start-Sleep -Milliseconds 200
            $dialog = Get-ImportDialog $process
        } until ($null -ne $dialog -or [DateTime]::UtcNow -ge $deadline)
    }
    if ($null -eq $dialog) { throw 'Import dialog did not appear. Inspect Tube Design for a prompt, or open Import manually and retry.' }
    if ($dialog.Current.ProcessId -ne $process.Id) { throw 'Import dialog belongs to an unexpected process.' }
    $controls = $dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $editMatches = @($controls | Where-Object {
        $_.Current.AutomationId -eq '1148' -and $_.Current.ClassName -eq 'Edit' -and
        $_.Current.IsEnabled -and -not $_.Current.IsOffscreen
    })
    if ($editMatches.Count -ne 1) { throw 'The filename field is missing or ambiguous. No filename was entered.' }
    $value = $null
    if (-not $editMatches[0].TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$value)) {
        throw 'Filename field does not support direct value entry. Select the working copy manually.'
    }
    $value.SetValue($file.FullName)
    if ($value.Current.Value -cne $file.FullName) { throw 'The filename field did not retain the expected working-copy path.' }
    # Native ID/class are used because archived captures exposed this button as
    # both ControlType.Button and ControlType.Pane.
    $buttons = @($dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object {
        $_.Current.Name -eq 'Import' -and $_.Current.AutomationId -eq '1' -and
        $_.Current.ClassName -eq 'Button' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen
    })
    if ($buttons.Count -ne 1) { throw 'Import button is missing or ambiguous. The path is filled; inspect the dialog manually.' }
    $buttonHandle = [IntPtr]$buttons[0].Current.NativeWindowHandle
    $dialogHandle = [IntPtr]$dialog.Current.NativeWindowHandle
    $nativeProcess = [uint32]0
    [void][TubeJobNative]::GetWindowThreadProcessId($buttonHandle,[ref]$nativeProcess)
    if ($buttonHandle -eq [IntPtr]::Zero -or $dialogHandle -eq [IntPtr]::Zero -or
        $nativeProcess -ne $process.Id -or [TubeJobNative]::GetDlgCtrlID($buttonHandle) -ne 1) {
        throw 'Import button native identity could not be verified.'
    }
    Set-VerifiedTubeForeground $dialogHandle $process.Id
    if (-not [TubeJobNative]::PostMessage($buttonHandle, 0xF5, [IntPtr]::Zero, [IntPtr]::Zero)) { throw 'Windows rejected the import request.' }
    return 'Import requested for the staged working copy. Inspect the loaded model; this is not confirmation that import or tube identification succeeded.'
}

function Invoke-TubeIdentify {
    param([string]$InputPath)
    Initialize-TubeDesktop
    $process = Get-TubeDesignWindow
    $baseName = [IO.Path]::GetFileNameWithoutExtension($InputPath)
    if ($process.MainWindowTitle.IndexOf($baseName,[StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw 'The active document title does not match this part. Select the correct working copy manually.'
    }
    Invoke-TubeToolbar $process Identify
    return 'Identify profile requested. Select the body and review material, dimensions, profile, and direction; confirm in Tube Design.'
}

function Save-TubeControls {
    param([string]$OutputPath)
    Initialize-TubeDesktop
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    function Read-Controls($element, [int]$depth) {
        if ($depth -gt 6 -or $lines.Count -ge 1000) { return }
        try {
            $item = $element.Current
            $lines.Add(('{0}{1} | Name={2} | Id={3} | Class={4} | Enabled={5}' -f
                ('  '*$depth),$item.ControlType.ProgrammaticName,$item.Name,$item.AutomationId,$item.ClassName,$item.IsEnabled))
            if ($depth -ge 6) { return }
            $child = $walker.GetFirstChild($element)
            while ($null -ne $child -and $lines.Count -lt 1000) {
                Read-Controls $child ($depth+1)
                $child = $walker.GetNextSibling($child)
            }
        } catch { $lines.Add('Unreadable control: ' + $_.Exception.Message) }
    }
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.ProcessName -eq 'sldworks' -and $_.MainWindowTitle -like 'Tube Design*') -or
        $_.ProcessName -eq 'ProgrammingTubeAutoRun'
    })) {
        if ($process.MainWindowHandle -eq 0) { continue }
        $lines.Add('APPLICATION: ' + $process.ProcessName + ' | ' + $process.MainWindowTitle)
        Read-Controls ([System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)) 0
    }
    if ($lines.Count -eq 0) { throw 'No visible Tube Design or Auto Run window was found.' }
    $lines | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    return 'Saved application control names only. No desktop screenshots or unrelated windows were captured.'
}

Export-ModuleMember -Function Invoke-TubeImport,Invoke-TubeIdentify,Save-TubeControls
