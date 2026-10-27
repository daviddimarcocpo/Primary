Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TubeJob.Core.psm1') -Force

function Initialize-TubeDesktop {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    if (-not ('TubeJobNative' -as [type])) {
        Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class TubeJobNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
    delegate bool EnumWindowProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindowProc callback, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowProc callback, IntPtr p);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint command);
    [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct COMBOBOXINFO {
        public int cbSize; public RECT rcItem, rcButton; public int stateButton;
        public IntPtr hwndCombo, hwndItem, hwndList;
    }
    [DllImport("user32.dll")] static extern bool GetComboBoxInfo(IntPtr h, ref COMBOBOXINFO info);
    [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr SendText(IntPtr h, uint m, UIntPtr w, string text, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr ReadText(IntPtr h, uint m, UIntPtr w, StringBuilder text, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, IntPtr l, uint flags, uint timeout, out UIntPtr result);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int type, out int value, int length, out int returned);
    public static string Elevation(int pid) {
        IntPtr process = OpenProcess(0x1000, false, (uint)pid);
        if (process == IntPtr.Zero) return "Unknown (" + Marshal.GetLastWin32Error() + ")";
        IntPtr token = IntPtr.Zero;
        try {
            if (!OpenProcessToken(process, 8, out token)) return "Unknown (" + Marshal.GetLastWin32Error() + ")";
            int value, length;
            if (!GetTokenInformation(token, 20, out value, 4, out length)) return "Unknown (" + Marshal.GetLastWin32Error() + ")";
            return value != 0 ? "Elevated" : "Standard";
        } finally { if (token != IntPtr.Zero) CloseHandle(token); CloseHandle(process); }
    }
    static string Caption(IntPtr h) { var text=new StringBuilder(2048); GetWindowText(h,text,text.Capacity); return text.ToString(); }
    static string Class(IntPtr h) { var text=new StringBuilder(256); GetClassName(h,text,text.Capacity); return text.ToString(); }
    static bool OwnedBy(IntPtr candidate, IntPtr root) {
        if (IsChild(root,candidate)) return true;
        for (int depth=0;depth<16 && candidate!=IntPtr.Zero;depth++) {
            candidate=GetWindow(candidate,4);
            if (candidate==root) return true;
        }
        return false;
    }
    public static bool WindowEnabled(IntPtr h) { return IsWindowEnabled(h); }
    public static IntPtr[] FindDialogs(IntPtr root,int expectedPid,string title) {
        var found=new HashSet<IntPtr>();
        EnumWindowProc callback=delegate(IntPtr h,IntPtr unused) {
            uint pid; GetWindowThreadProcessId(h,out pid);
            if (pid==expectedPid && Class(h)=="#32770" && Caption(h)==title && IsWindowVisible(h) && IsWindowEnabled(h) && OwnedBy(h,root)) found.Add(h);
            return true;
        };
        EnumWindows(callback,IntPtr.Zero); EnumChildWindows(root,callback,IntPtr.Zero); GC.KeepAlive(callback);
        var result=new IntPtr[found.Count]; found.CopyTo(result); return result;
    }
    public static IntPtr FillFileDialog(IntPtr dialog,int expectedPid,string title,string buttonCaption,string path) {
        uint pid; GetWindowThreadProcessId(dialog,out pid);
        if (pid!=expectedPid || Class(dialog)!="#32770" || Caption(dialog)!=title || !IsWindowVisible(dialog) || !IsWindowEnabled(dialog))
            throw new InvalidOperationException("File dialog identity changed.");
        IntPtr field=GetDlgItem(dialog,1148);
        if (field==IntPtr.Zero) {
            var fields=new List<IntPtr>();
            EnumWindowProc find=delegate(IntPtr h,IntPtr unused) {
                uint owner; GetWindowThreadProcessId(h,out owner);
                string cls=Class(h);
                if (owner==expectedPid && GetDlgCtrlID(h)==1148 && IsWindowVisible(h) &&
                    (cls=="ComboBox" || cls=="ComboBoxEx32" || cls=="Edit")) fields.Add(h);
                return true;
            };
            EnumChildWindows(dialog,find,IntPtr.Zero);GC.KeepAlive(find);
            if (fields.Count!=1) throw new InvalidOperationException("Native file name control 1148 is missing or ambiguous.");
            field=fields[0];
        }
        IntPtr edit=field;
        if (Class(field)=="ComboBoxEx32") {
            edit=new IntPtr(Query(field,0x407,0));
        } else if (Class(field)=="ComboBox") {
            var info=new COMBOBOXINFO(); info.cbSize=Marshal.SizeOf(typeof(COMBOBOXINFO));
            if (!GetComboBoxInfo(field,ref info)) throw new InvalidOperationException("File name combo edit could not be identified.");
            edit=info.hwndItem;
        }
        uint editPid; GetWindowThreadProcessId(edit,out editPid);
        if (edit==IntPtr.Zero || editPid!=expectedPid || Class(edit)!="Edit" || !IsChild(dialog,edit) || !IsWindowEnabled(edit))
            throw new InvalidOperationException("Native file name edit identity could not be verified.");
        IntPtr button=GetDlgItem(dialog,1);
        uint buttonPid; GetWindowThreadProcessId(button,out buttonPid);
        if (button==IntPtr.Zero || buttonPid!=expectedPid || Class(button)!="Button" ||
            Caption(button).Replace("&","")!=buttonCaption || !IsWindowVisible(button) || !IsWindowEnabled(button))
            throw new InvalidOperationException("Expected file dialog button was not found.");
        UIntPtr result;
        // WM_SETTEXT/WM_GETTEXT are marshalled by Windows; no remote-memory allocation.
        if (SendText(edit,0xC,UIntPtr.Zero,path,0x22,1000,out result)==IntPtr.Zero || result==UIntPtr.Zero)
            throw new InvalidOperationException("Windows rejected the file name entry.");
        var actual=new StringBuilder(path.Length+4);
        if (ReadText(edit,0xD,(UIntPtr)(uint)actual.Capacity,actual,0x22,1000,out result)==IntPtr.Zero || actual.ToString()!=path)
            throw new InvalidOperationException("The file name readback does not match the working-copy path.");
        return button;
    }
    public sealed class ToolbarState {
        public IntPtr Handle;
        public int ProcessId;
        public int ToolbarId;
        public string ClassName;
        public bool Visible;
        public bool Enabled;
        public long CommandIndex;
        public long ButtonState;
    }
    static long Query(IntPtr h, uint message, int command) {
        UIntPtr result;
        if (SendMessageTimeout(h, message, (UIntPtr)(uint)command, IntPtr.Zero, 0x22, 500, out result) == IntPtr.Zero)
            throw new InvalidOperationException("Native toolbar query was blocked or timed out (Windows error " + Marshal.GetLastWin32Error() + ").");
        return IntPtr.Size == 4 ? unchecked((int)result.ToUInt32()) : unchecked((long)result.ToUInt64());
    }
    public static ToolbarState[] InspectToolbar(IntPtr root, int expectedPid, int toolbarId, int command) {
        uint rootPid;
        GetWindowThreadProcessId(root, out rootPid);
        if (rootPid != expectedPid || !IsWindowEnabled(root)) throw new InvalidOperationException("Tube Design window changed or has a blocking dialog.");
        var handles = new List<IntPtr>();
        EnumWindowProc callback = delegate(IntPtr h, IntPtr unused) {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            var name = new StringBuilder(256);
            GetClassName(h, name, name.Capacity);
            if (pid == expectedPid && GetDlgCtrlID(h) == toolbarId && name.ToString() == "ToolbarWindow32" && IsWindowVisible(h)) handles.Add(h);
            return true;
        };
        EnumChildWindows(root, callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        var results = new List<ToolbarState>();
        // Do not query, or act on, an ambiguous set of windows.
        if (handles.Count != 1) return results.ToArray();
        var handle = handles[0];
        results.Add(new ToolbarState { Handle=handle, ProcessId=expectedPid, ToolbarId=toolbarId,
            ClassName="ToolbarWindow32", Visible=IsWindowVisible(handle), Enabled=IsWindowEnabled(handle),
            CommandIndex=Query(handle, 0x419, command), ButtonState=Query(handle, 0x412, command) });
        return results.ToArray();
    }
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

function Assert-TubeAccess {
    param($Process)
    $workerLevel=[TubeJobNative]::Elevation([Diagnostics.Process]::GetCurrentProcess().Id)
    $tubeLevel=[TubeJobNative]::Elevation($Process.Id)
    if ($workerLevel -eq 'Standard' -and $tubeLevel -eq 'Elevated') {
        throw 'The TRUMPF application is running as administrator but the helper is not. Windows can block desktop controls across those levels. Keep both at the same level; if your normal TRUMPF shortcut requires administrator access, close the helper and use Run as administrator on Start Helper.cmd. No privilege change was made automatically.'
    }
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
    param($Process, [ValidateSet('Import','Identify','Export')][string]$Command)
    $commandId = switch ($Command) { 'Import' {41699}; 'Identify' {41706}; 'Export' {41737} }
    $toolbarName = switch ($Command) { 'Import' {'Standard'}; 'Identify' {'Tubes'}; 'Export' {'production data'} }
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
    if ($buttons.Count -ne 1) {
        # Current reports expose ToolbarWindow32 as a Pane with no UIA children.
        # Query scalar toolbar state; no remote memory, coordinate guesses, or API license calls.
        $toolbarId=switch ($Command) { 'Import' {59424}; 'Identify' {59430}; 'Export' {59431} }
        $nativeStates=@([TubeJobNative]::InspectToolbar($Process.MainWindowHandle,$Process.Id,$toolbarId,$commandId))
        if ($nativeStates.Count -ne 1) { throw "The $Command toolbar is missing, hidden, or ambiguous in both accessibility and native inspection. No command was sent." }
        Assert-TubeToolbarState $nativeStates[0] $Process.Id $toolbarId
    }
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
    Assert-TubeAccess $process
    $title='Select the model to be imported.'
    $dialogs=@([TubeJobNative]::FindDialogs($process.MainWindowHandle,$process.Id,$title))
    if ($dialogs.Count -eq 0) {
        if (Test-TubeDocumentTitle $process.MainWindowTitle $file.BaseName) { throw 'This part is already open. Continue with Identify profile, or close the part before testing a new import.' }
        Invoke-TubeToolbar $process Import
        $deadline = [DateTime]::UtcNow.AddSeconds(6)
        do {
            Start-Sleep -Milliseconds 200
            $dialogs=@([TubeJobNative]::FindDialogs($process.MainWindowHandle,$process.Id,$title))
        } until ($dialogs.Count -gt 0 -or [DateTime]::UtcNow -ge $deadline)
    }
    if ($dialogs.Count -ne 1) { throw 'A unique Tube Design import dialog did not appear. Inspect Tube Design, or open Import manually and retry.' }
    $dialogHandle=$dialogs[0]
    Set-VerifiedTubeForeground $dialogHandle $process.Id
    $buttonHandle=[TubeJobNative]::FillFileDialog($dialogHandle,$process.Id,$title,'Import',$file.FullName)
    if (-not [TubeJobNative]::PostMessage($buttonHandle, 0xF5, [IntPtr]::Zero, [IntPtr]::Zero)) { throw 'Windows rejected the import request.' }
    return 'Import requested for the staged working copy. Inspect the loaded model; this is not confirmation that import or tube identification succeeded.'
}

function Invoke-TubeIdentify {
    param([string]$InputPath)
    Initialize-TubeDesktop
    $process = Get-TubeDesignWindow
    Assert-TubeAccess $process
    $baseName = [IO.Path]::GetFileNameWithoutExtension($InputPath)
    if (-not (Test-TubeDocumentTitle $process.MainWindowTitle $baseName)) {
        throw 'The active document title does not match this part. Select the correct working copy manually.'
    }
    Invoke-TubeToolbar $process Identify
    return 'Identify profile requested. Select the body and review material, dimensions, profile, and direction; confirm in Tube Design.'
}

function Invoke-TubeExport {
    param([string]$InputPath)
    Initialize-TubeDesktop
    $process=Get-TubeDesignWindow; Assert-TubeAccess $process
    $name=[IO.Path]::GetFileNameWithoutExtension($InputPath)
    if (-not (Test-TubeDocumentTitle $process.MainWindowTitle $name)) { throw 'The active Tube Design document is not the selected part.' }
    $request=New-TeoxExportRequest $InputPath
    Invoke-TubeToolbar $process Export
    [pscustomobject]@{Message='Export production data requested. Inspect Tube Design: confirm its save prompt if shown, then use Fill model save dialog. Review export selection and accept its green check. Watching for the new TEOX.';Request=$request}
}

function Invoke-TubeModelSave {
    param([string]$InputPath)
    Initialize-TubeDesktop
    $process=Get-TubeDesignWindow; Assert-TubeAccess $process
    $title='Name of the tube design model to be stored'
    $dialogs=@([TubeJobNative]::FindDialogs($process.MainWindowHandle,$process.Id,$title))
    if ($dialogs.Count -ne 1) { throw 'Open the recorded model-save dialog first by accepting the save prerequisite in Tube Design. No generic dialog was accepted.' }
    $target=[IO.Path]::ChangeExtension($InputPath,'.SLDPRT')
    Set-VerifiedTubeForeground $dialogs[0] $process.Id
    $button=[TubeJobNative]::FillFileDialog($dialogs[0],$process.Id,$title,'Save',$target)
    if (-not [TubeJobNative]::PostMessage($button,0xF5,[IntPtr]::Zero,[IntPtr]::Zero)) { throw 'Windows rejected the model Save request.' }
    return 'Model Save requested in the working-copy folder. Inspect any overwrite prompt yourself. Confirm export settings and accept the export green check in Tube Design.'
}

function Invoke-AutoRunImport {
    param([string]$InputPath)
    Initialize-TubeDesktop
    $file=Get-Item -LiteralPath $InputPath
    if ($file.Extension -ine '.teox') { throw 'Choose the registered TEOX input.' }
    $processes=@(Get-Process -Name ProgrammingTubeAutoRun -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
    if ($processes.Count -ne 1) { throw 'Open exactly one visible Programming Tube Auto Run window first.' }
    $process=$processes[0]
    Assert-TubeAccess $process
    $root=[System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    $all=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    $tabSelected=$false
    $machineNames=New-Object 'System.Collections.Generic.List[string]'
    $dialogs=New-Object 'System.Collections.Generic.List[object]'
    $existingPartCount=0
    foreach ($element in $all) {
        $info=$element.Current
        if ($info.ControlType -eq [System.Windows.Automation.ControlType]::TabItem) {
            $labelCondition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,'Auto Run')
            if ($null -ne $element.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$labelCondition)) {
                $selection=$null
                if ($element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$selection) -and $selection.Current.IsSelected) { $tabSelected=$true }
            }
        }
        if ($info.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox -and -not $info.IsOffscreen) {
            $values=New-Object 'System.Collections.Generic.List[string]'
            $values.Add($info.Name)
            $selection=$null
            if ($element.TryGetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern,[ref]$selection)) {
                foreach ($selected in $selection.Current.GetSelection()) {
                    $values.Add($selected.Current.Name)
                    foreach ($child in $selected.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)) {
                        if ($child.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text) { $values.Add($child.Current.Name) }
                    }
                }
            }
            $valuePattern=$null
            if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$valuePattern)) { $values.Add($valuePattern.Current.Value) }
            if (@($values | Where-Object { ($_ -replace '\s','') -ieq 'TruLaserTube7000(T12)' }).Count -gt 0) { $machineNames.Add('TruLaser Tube 7000 (T12)') }
        }
        if ($info.Name -ceq 'Select TEOX files for import.' -and $info.ClassName -eq '#32770' -and $info.ProcessId -eq $process.Id) { $dialogs.Add($element) }
        if (-not $info.IsOffscreen -and $info.Name -ieq $file.BaseName) {
            $inChooser=$false; $ancestor=$element
            for ($level=0;$level -lt 24 -and $null -ne $ancestor;$level++) {
                if ($ancestor.Current.Name -ceq 'Select TEOX files for import.') { $inChooser=$true; break }
                $ancestor=[System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($ancestor)
            }
            if (-not $inChooser) { $existingPartCount++ }
        }
    }
    Test-AutoRunContext $tabSelected $machineNames.ToArray() $dialogs.Count $existingPartCount
    $dialog=$dialogs[0]
    $controls=$dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    $edits=@($controls | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
        ($_.Current.AutomationId -eq '1148' -or $_.Current.Name -eq 'File name:') -and
        $_.Current.IsEnabled -and -not $_.Current.IsOffscreen
    })
    if ($edits.Count -ne 1) { throw 'Auto Run filename field is missing or ambiguous. Save a control report with the import dialog still open.' }
    $value=$null
    if (-not $edits[0].TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$value)) { throw 'Auto Run filename field does not expose a writable value. Save a control report.' }
    $openButtons=@($controls | Where-Object {
        $_.Current.Name -eq 'Open' -and $_.Current.AutomationId -eq '1' -and $_.Current.ClassName -eq 'Button' -and
        $_.Current.IsEnabled -and -not $_.Current.IsOffscreen
    })
    if ($openButtons.Count -ne 1) { throw 'The Auto Run Open button is unavailable or ambiguous. No import was requested.' }
    $button=[IntPtr]$openButtons[0].Current.NativeWindowHandle
    $dialogHandle=[IntPtr]$dialog.Current.NativeWindowHandle
    $nativeProcess=[uint32]0
    [void][TubeJobNative]::GetWindowThreadProcessId($button,[ref]$nativeProcess)
    if ($button -eq [IntPtr]::Zero -or $dialogHandle -eq [IntPtr]::Zero -or
        $nativeProcess -ne $process.Id -or [TubeJobNative]::GetDlgCtrlID($button) -ne 1) { throw 'Auto Run Open button identity could not be verified.' }
    $value.SetValue($file.FullName)
    if ($value.Current.Value -cne $file.FullName) { throw 'The TEOX filename did not remain in the file chooser.' }
    Set-VerifiedTubeForeground $dialogHandle $process.Id
    $prior=@(foreach ($extension in @('.tpc','.tubx','.pdf')) {
        $output=[IO.Path]::ChangeExtension($file.FullName,$extension)
        if (Test-Path -LiteralPath $output -PathType Leaf) {
            $item=Get-Item -LiteralPath $output
            [pscustomobject]@{Path=$output;Exists=$true;Length=$item.Length;WriteTicks=$item.LastWriteTimeUtc.Ticks;
                SHA256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash}
        } else { [pscustomobject]@{Path=$output;Exists=$false} }
    })
    $request=[pscustomobject]@{RequestedUtc=[DateTime]::UtcNow.ToString('o');InputPath=$file.FullName;
        InputSHA256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash;PartName=$file.BaseName;PriorOutputs=$prior}
    if (-not [TubeJobNative]::PostMessage($button,0xF5,[IntPtr]::Zero,[IntPtr]::Zero)) { throw 'Windows rejected the Auto Run Open request.' }
    return [pscustomobject]@{Message='Auto Run import requested. Watching for fresh part outputs beside the TEOX; inspect any TRUMPF prompts.';Request=$request}
}

function Save-TubeControls {
    param([string]$OutputPath,[switch]$TubeDesignOnly)
    Initialize-TubeDesktop
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('Helper privilege: '+[TubeJobNative]::Elevation([Diagnostics.Process]::GetCurrentProcess().Id))
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    function Read-Controls($element, [int]$depth) {
        if ($depth -gt 14 -or $lines.Count -ge 5000) { return }
        try {
            $item = $element.Current
            $patterns='unavailable'
            try { $patterns=@($element.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName }) -join ',' } catch { }
            $selectionState=''
            try {
                $selection=$null
                if ($item.ControlType -eq [System.Windows.Automation.ControlType]::TabItem -and
                    $element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$selection)) {
                    $selectionState='Selected='+$selection.Current.IsSelected
                } elseif ($item.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox -and
                    $element.TryGetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern,[ref]$selection)) {
                    $selectionState='Selected='+(@($selection.Current.GetSelection() | ForEach-Object { $_.Current.Name }) -join ',')
                }
            } catch { $selectionState='Selection unavailable' }
            $lines.Add(('{0}{1} | Name={2} | Id={3} | Class={4} | Enabled={5} | Offscreen={6} | Help={7} | Patterns={8} | {9}' -f
                ('  '*$depth),$item.ControlType.ProgrammaticName,$item.Name,$item.AutomationId,$item.ClassName,$item.IsEnabled,$item.IsOffscreen,$item.HelpText,$patterns,$selectionState))
            if ($depth -ge 14) { $lines.Add('Depth limit reached.'); return }
            $child = $walker.GetFirstChild($element)
            while ($null -ne $child -and $lines.Count -lt 5000) {
                Read-Controls $child ($depth+1)
                $child = $walker.GetNextSibling($child)
            }
        } catch { $lines.Add('Unreadable control: ' + $_.Exception.Message) }
    }
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.ProcessName -eq 'sldworks' -and $_.MainWindowTitle -like 'Tube Design*') -or
        ($_.ProcessName -eq 'ProgrammingTubeAutoRun' -and -not $TubeDesignOnly)
    })) {
        if ($process.MainWindowHandle -eq 0) { continue }
        $lines.Add('APPLICATION: ' + $process.ProcessName + ' | ' + $process.MainWindowTitle)
        $lines.Add('Application privilege: '+[TubeJobNative]::Elevation($process.Id))
        Read-Controls ([System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)) 0
        if ($process.ProcessName -eq 'sldworks') {
            foreach ($mapping in @(@{Name='Import';Toolbar=59424;Command=41699},@{Name='Identify';Toolbar=59430;Command=41706},@{Name='Export';Toolbar=59431;Command=41737})) {
                try {
                    $states=@([TubeJobNative]::InspectToolbar($process.MainWindowHandle,$process.Id,$mapping.Toolbar,$mapping.Command))
                    if ($states.Count -eq 1) {
                        $lines.Add(('NATIVE {0}: toolbar={1}; command={2}; index={3}; state={4}; visible={5}; enabled={6}' -f
                            $mapping.Name,$mapping.Toolbar,$mapping.Command,$states[0].CommandIndex,$states[0].ButtonState,$states[0].Visible,$states[0].Enabled))
                    } else { $lines.Add('NATIVE '+$mapping.Name+': no unique visible toolbar') }
                } catch { $lines.Add('NATIVE '+$mapping.Name+': '+$_.Exception.Message) }
            }
        }
    }
    if ($lines.Count -eq 1) { throw 'No visible Tube Design or Auto Run window was found.' }
    $lines | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    return 'Saved application control names only. No desktop screenshots or unrelated windows were captured.'
}

Export-ModuleMember -Function Invoke-TubeImport,Invoke-TubeIdentify,Invoke-TubeExport,Invoke-TubeModelSave,Invoke-AutoRunImport,Save-TubeControls
