#requires -Version 5.1
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($env:OS -ne 'Windows_NT') { throw 'Run this helper on your Windows programming workstation.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start using Start Helper.cmd so Windows file dialogs work.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.Windows.Forms.Application]::EnableVisualStyles()
Import-Module (Join-Path $PSScriptRoot 'TubeJob.Core.psm1') -Force

$script:job = $null
$script:report = $null
$script:busy = $false
$script:reviewedPdfHash = $null
$script:tubeDesignShortcut = $null
$script:calculationPart = $null
$script:calculationDeadline = $null
$calculationTimer=New-Object Windows.Forms.Timer
$calculationTimer.Interval=2000
$script:teoxPart=$null
$script:teoxDeadline=$null
$teoxTimer=New-Object Windows.Forms.Timer
$teoxTimer.Interval=2000
$form = New-Object Windows.Forms.Form
$form.Text = 'Tube Design Helper 0.3.0 - CAD to TEOX'
$form.ClientSize = New-Object Drawing.Size(1000,760)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object Drawing.Size(1016,799)
$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$form.Controls.Add($tabs)
$setupPage = New-Object Windows.Forms.TabPage('1. Prepare job')
$partsPage = New-Object Windows.Forms.TabPage('2. Tube Design to TEOX')
$packagePage = New-Object Windows.Forms.TabPage('3. Nest and check outputs')
$tabs.TabPages.AddRange(@($setupPage,$partsPage))

function Add-Label($parent,$text,$x,$y,$width=920,$height=24) {
    $control = New-Object Windows.Forms.Label
    $control.Text=$text; $control.Location=New-Object Drawing.Point($x,$y)
    $control.Size=New-Object Drawing.Size($width,$height)
    $parent.Controls.Add($control)
    return $control
}
function Add-Button($parent,$text,$x,$y,$width,$handler) {
    $control=New-Object Windows.Forms.Button
    $control.Text=$text; $control.Location=New-Object Drawing.Point($x,$y)
    $control.Size=New-Object Drawing.Size($width,34)
    $control.Add_Click($handler); $parent.Controls.Add($control)
    return $control
}
function Add-Text($parent,$x,$y,$width,$text='') {
    $control=New-Object Windows.Forms.TextBox
    $control.Location=New-Object Drawing.Point($x,$y); $control.Width=$width; $control.Text=$text
    $parent.Controls.Add($control); return $control
}
function Show-Error($errorRecord) {
    [void][Windows.Forms.MessageBox]::Show($form,[string]$errorRecord,'Stopped - please inspect', 'OK','Warning')
}
function Select-File($title,$filter,$initialDirectory='') {
    $dialog=New-Object Windows.Forms.OpenFileDialog
    try {
        $dialog.Title=$title; $dialog.Filter=$filter; $dialog.InitialDirectory=$initialDirectory
        if ($dialog.ShowDialog($form) -eq 'OK') { return $dialog.FileName }
        return $null
    } finally { $dialog.Dispose() }
}
function Show-Folder($path) {
    # explorer.exe is invoked directly; no shell command strings or job-name interpolation.
    if ($path.Contains('"')) { throw 'Invalid folder path.' }
    Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('"'+$path+'"')
}
function Get-CurrentPart {
    if ($null -eq $script:job -or $partList.SelectedIndex -lt 0) { throw 'Prepare a job and select a part first.' }
    return $script:job.Parts[$partList.SelectedIndex]
}
function Write-SessionLog($message) {
    if ($null -ne $script:job) {
        ('{0} {1}' -f [DateTime]::UtcNow.ToString('o'),$message) |
            Add-Content -LiteralPath (Join-Path $script:job.Directory 'helper.log') -Encoding UTF8
    }
}
function Invoke-DesktopAction($action) {
    if ($action -notin @('Import','Identify','Capture','AutoRunImport','TubeExport','ModelSave')) { throw 'Unsupported desktop action.' }
    $part=Get-CurrentPart
    $inputPath=$part.WorkingCopy
    if ($action -eq 'AutoRunImport') {
        if ($calculationTimer.Enabled) { throw 'A calculation watch is active. Finish or stop watching before requesting another import.' }
        if (-not $part.MaterialAndProfileReviewed -or -not $part.MarkingReviewed -or -not $part.TeoxPath) { throw 'Confirm the profile/marking and register the TEOX before importing into Auto Run.' }
        $inputPath=$part.TeoxPath
    }
    if ($action -eq 'TubeExport' -and (-not $part.MaterialAndProfileReviewed -or -not $part.MarkingReviewed)) { throw 'Review and confirm the profile/material and processing choices before starting TEOX export.' }
    $resultPath=Join-Path (Join-Path $script:job.Directory 'diagnostics') ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)+'.json')
    $worker=Join-Path $PSScriptRoot 'Desktop-Worker.ps1'
    foreach ($value in @($worker,$inputPath,$resultPath)) {
        if ($value.Contains('"')) { throw 'A path contains an unsupported quotation mark.' }
    }
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -File "'+$worker+'" -Action '+$action+' -InputPath "'+$inputPath+'" -ResultPath "'+$resultPath+'"'
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $workerProcess=New-Object Diagnostics.Process
    $workerProcess.StartInfo=$start
    $script:busy=$true
    $form.Hide()
    try {
        Write-SessionLog ('Desktop action requested: '+$action+'; part '+$part.PartName)
        if (-not $workerProcess.Start()) { throw 'The Windows desktop worker did not start.' }
        if (-not $workerProcess.WaitForExit(15000)) {
            $workerProcess.Kill()
            throw 'Desktop inspection timed out. Only the helper worker was stopped; TRUMPF was left running. Inspect its current state before retrying.'
        }
        if (-not (Test-Path -LiteralPath $resultPath)) { throw 'The desktop worker produced no report. Windows may have blocked script execution. Please share the console error; do not disable your security policy.' }
        $result=Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        Write-SessionLog $result.Message
        if (-not $result.Success) { throw $result.Message }
        $partsStatus.Text=$result.Message
        if ($action -eq 'AutoRunImport') {
            $part | Add-Member -NotePropertyName AutoRunRequest -NotePropertyValue $result.Data -Force
            $part | Add-Member -NotePropertyName AutoRunCalculation -NotePropertyValue $null -Force
            $script:job.PackageReport=$null; $script:job.State='Auto Run import requested; output review pending'
            $script:report=$null; $pdfReviewed.Checked=$false
            Save-TubeJob $script:job
            Start-CalculationWatch $part
        } elseif ($action -eq 'TubeExport') {
            $part | Add-Member -NotePropertyName TeoxExportRequest -NotePropertyValue $result.Data -Force
            $part | Add-Member -NotePropertyName TeoxExportCheck -NotePropertyValue $null -Force
            $script:job.State='Tube Design export requested';$script:job.PackageReport=$null
            Save-TubeJob $script:job
            Start-TeoxWatch $part
        }
    } finally {
        $workerProcess.Dispose(); $script:busy=$false; $form.Show(); $form.Activate()
    }
}

function Start-TeoxWatch($part) {
    if (-not $part.PSObject.Properties['TeoxExportRequest'] -or $null -eq $part.TeoxExportRequest) { throw 'Use Begin TEOX export first so an old export cannot be mistaken for new output. You can register an existing TEOX separately.' }
    $script:teoxPart=$part;$script:teoxDeadline=[DateTime]::UtcNow.AddSeconds(120)
    $teoxTimer.Start();Update-TeoxWatch
}

function Update-TeoxWatch {
    try {
        $part=$script:teoxPart
        if ($null -eq $part) { return }
        if (-not $part.MaterialAndProfileReviewed -or -not $part.MarkingReviewed) { throw 'Profile or processing review was withdrawn; review again before exporting.' }
        $request=$part.TeoxExportRequest
        if ($request.PartName -ine $part.PartName -or [IO.Path]::GetFullPath($request.InputPath) -ine [IO.Path]::GetFullPath($part.WorkingCopy)) { throw 'The export receipt does not match the selected working copy.' }
        $status=Test-TeoxExport $request
        $partsStatus.Text=$part.PartName+': '+$status.Message
        if ($status.Status -eq 'TeoxVerified') {
            $teoxTimer.Stop();$part.TeoxPath=$status.Summary.Path
            $part | Add-Member -NotePropertyName TeoxExportCheck -NotePropertyValue $status -Force
            $part | Add-Member -NotePropertyName AutoRunRequest -NotePropertyValue $null -Force
            $part | Add-Member -NotePropertyName AutoRunCalculation -NotePropertyValue $null -Force
            $script:job.State='TEOX container verified; operator review retained';$script:job.PackageReport=$null
            Save-TubeJob $script:job
            $reportPath=Join-Path (Join-Path $script:job.Directory 'diagnostics') ('teox-check-'+[guid]::NewGuid().ToString('N')+'.json')
            $status | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
            $teoxLabel.Text='Verified TEOX: '+$part.TeoxPath
            Write-SessionLog ('Fresh TEOX verified: '+$part.TeoxPath)
        } elseif ($status.Status -eq 'Failed') {
            $teoxTimer.Stop();Write-SessionLog ('TEOX check stopped: '+$status.Message)
        } elseif ([DateTime]::UtcNow -ge $script:teoxDeadline) {
            $teoxTimer.Stop();$partsStatus.Text='Still waiting for a fresh TEOX. Finish the save/export dialogs in Tube Design, then click Check TEOX export. For another output folder, use Register exported TEOX.'
        }
    } catch { $teoxTimer.Stop();$partsStatus.Text=$_.Exception.Message;Write-SessionLog ('TEOX watch stopped: '+$_.Exception.Message) }
}
$teoxTimer.Add_Tick({ Update-TeoxWatch })

function Start-CalculationWatch($part) {
    if (-not $part.PSObject.Properties['AutoRunRequest'] -or $null -eq $part.AutoRunRequest) { throw 'No helper import request is recorded for this part. Open the + dialog and use Import TEOX first.' }
    $script:calculationPart=$part
    $script:calculationDeadline=[DateTime]::UtcNow.AddSeconds(120)
    $calculationTimer.Start()
    Update-CalculationWatch
}

function Update-CalculationWatch {
    try {
        $part=$script:calculationPart
        if ($null -eq $part) { return }
        $request=$part.AutoRunRequest
        if ([IO.Path]::GetFullPath($request.InputPath) -ine [IO.Path]::GetFullPath($part.TeoxPath) -or $request.PartName -ine $part.PartName) {
            throw 'The recorded import does not match the currently registered TEOX. Register and import the intended part again.'
        }
        $status=Test-AutoRunCalculation $request
        $partsStatus.Text=$part.PartName+': '+$status.Message
        if ($status.Status -ne 'Pending') {
            $calculationTimer.Stop()
            $part | Add-Member -NotePropertyName AutoRunCalculation -NotePropertyValue $status -Force
            Save-TubeJob $script:job
            Write-SessionLog ('Auto Run output watch '+$status.Status+': '+$status.Message)
        } elseif ([DateTime]::UtcNow -ge $script:calculationDeadline) {
            $calculationTimer.Stop()
            $partsStatus.Text='Still waiting after two minutes. Auto Run was left running. Inspect its prompts/warnings; use Check calculation outputs when it finishes.'
            Write-SessionLog 'Auto Run watch timed out; no calculation success was claimed and the application was left running.'
        }
    } catch {
        $calculationTimer.Stop(); $partsStatus.Text=$_.Exception.Message
        Write-SessionLog ('Calculation watch stopped: '+$_.Exception.Message)
    }
}
$calculationTimer.Add_Tick({ Update-CalculationWatch })
function Launch-Application($kind) {
    $processName=if ($kind -eq 'Tube Design') { 'sldworks' } else { 'ProgrammingTubeAutoRun' }
    if (@(Get-Process -Name $processName -ErrorAction SilentlyContinue).Count -gt 0) {
        [void][Windows.Forms.MessageBox]::Show($form,"$kind is already running. Switch to its window.",'Application running')
        return
    }
    if ($kind -eq 'Tube Design') {
        if (-not $script:tubeDesignShortcut -or -not (Test-Path -LiteralPath $script:tubeDesignShortcut -PathType Leaf)) {
            $shell=New-Object -ComObject WScript.Shell
            try {
                $shortcuts=New-Object 'System.Collections.Generic.List[object]'
                $roots=@([Environment]::GetFolderPath('StartMenu'),[Environment]::GetFolderPath('CommonStartMenu'),
                    [Environment]::GetFolderPath('DesktopDirectory'),[Environment]::GetFolderPath('CommonDesktopDirectory')) |
                    Where-Object { $_ } | Select-Object -Unique
                foreach ($root in $roots) {
                    foreach ($link in @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue)) {
                        if ($link.BaseName -notmatch '(?i)Tube[\s_-]*Design') { continue }
                        try {
                            $details=$shell.CreateShortcut($link.FullName)
                            $shortcuts.Add([pscustomobject]@{Name=$link.BaseName;Path=$link.FullName;
                                TargetPath=$details.TargetPath;Arguments=$details.Arguments;WorkingDirectory=$details.WorkingDirectory})
                        } catch { }
                    }
                }
                $candidates=@(Get-TubeDesignShortcutCandidates $shortcuts.ToArray() | Where-Object { Test-Path -LiteralPath $_.TargetPath -PathType Leaf })
                if ($candidates.Count -eq 1) {
                    $script:tubeDesignShortcut=$candidates[0].Path
                } else {
                    $dialog=New-Object Windows.Forms.OpenFileDialog
                    try {
                        $dialog.Title='Select the normal TRUMPF Tube Design shortcut you use to start the software'
                        $dialog.Filter='Tube Design Windows shortcut|*.lnk'; $dialog.DereferenceLinks=$false
                        $dialog.InitialDirectory=[Environment]::GetFolderPath('DesktopDirectory')
                        if ($dialog.ShowDialog($form) -ne 'OK') { return }
                        $details=$shell.CreateShortcut($dialog.FileName)
                        $selected=[pscustomobject]@{Name=[IO.Path]::GetFileNameWithoutExtension($dialog.FileName);Path=$dialog.FileName;
                            TargetPath=$details.TargetPath;Arguments=$details.Arguments;WorkingDirectory=$details.WorkingDirectory}
                        if (@(Get-TubeDesignShortcutCandidates @($selected)).Count -ne 1 -or -not (Test-Path -LiteralPath $selected.TargetPath -PathType Leaf)) {
                            throw 'That is not a supported TRUMPF Tube Design starter shortcut. Open Tube Design from your normal Start menu shortcut instead. The helper will not launch sldworks.exe directly.'
                        }
                        $script:tubeDesignShortcut=$selected.Path
                    } finally { $dialog.Dispose() }
                }
            } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        }
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$script:tubeDesignShortcut; $start.UseShellExecute=$true
        # Shell-launch the .lnk itself; don't reconstruct or drop its arguments.
        $launched=[Diagnostics.Process]::Start($start)
        if ($null -ne $launched) { $launched.Dispose() }
        Write-SessionLog 'Requested Tube Design startup through its installed Windows shortcut.'
    } else {
        $exe='C:\Program Files\TRUMPF\TruTops\ProgrammingTubeAutoRun\ProgrammingTubeAutoRun.exe'
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Open Auto Run normally from your Start menu; the recorded executable path was not found.' }
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
    }
}

function Show-PreparedJob {
    $setupStatus.Text='Job folder: '+$script:job.Directory
    $jobName.Text=$script:job.Name; $stock.Value=$script:job.StockLengthInches
    foreach ($control in @($createJob,$resumeJob,$addFiles,$clearFiles,$grid,$jobName,$stock,$parentPath)) { $control.Enabled=$false }
    $partList.Items.Clear()
    foreach ($part in $script:job.Parts) { $null=$partList.Items.Add($part.PartName+' - quantity '+$part.Quantity) }
    $partList.SelectedIndex=0; $tabs.SelectedTab=$partsPage
    $packageInstructions.Text=Get-PackageInstructions
    Update-ExpectedFileLabels
}

function Update-ExpectedFileLabels {
    if ($null -ne $script:job) {
        $expectedTpcLabel.Text='Expected TPC: '+$script:job.Name+'.tpc'
        $expectedPdfLabel.Text='Expected PDF: '+$script:job.Name+'.pdf'
    }
}

$null=Add-Label $setupPage 'Tube Design focus: import CAD, confirm tube/processing choices, and export a verified TEOX. Auto Run and nesting are paused.' 18 18 940 38
$null=Add-Label $setupPage 'Batch / helper job name' 18 65
$jobName=Add-Text $setupPage 18 91 620
$stockLabel=Add-Label $setupPage 'Stock length (inches)' 670 65 260
$stockLabel.Visible=$false
$stock=New-Object Windows.Forms.NumericUpDown
$stock.Location=New-Object Drawing.Point(670,91); $stock.Width=180
$stock.DecimalPlaces=3; $stock.Minimum=0.001; $stock.Maximum=10000; $stock.Value=240
$setupPage.Controls.Add($stock)
$stock.Visible=$false
$null=Add-Label $setupPage 'Save jobs under' 18 132
$parentPath=Add-Text $setupPage 18 158 760 (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Tube Laser Jobs')
$null=Add-Button $setupPage 'Browse...' 790 154 150 {
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    try { if ($dialog.ShowDialog($form) -eq 'OK') { $parentPath.Text=$dialog.SelectedPath } } finally { $dialog.Dispose() }
}
$grid=New-Object Windows.Forms.DataGridView
$grid.Location=New-Object Drawing.Point(18,245); $grid.Size=New-Object Drawing.Size(925,280)
$grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.AutoSizeColumnsMode='Fill'
$null=$grid.Columns.Add('PartName','Part name (from filename)')
$null=$grid.Columns.Add('Quantity','Required quantity')
$null=$grid.Columns.Add('SourcePath','Original CAD file')
$grid.Columns['PartName'].ReadOnly=$true; $grid.Columns['SourcePath'].ReadOnly=$true
$grid.Columns['Quantity'].Visible=$false
$setupPage.Controls.Add($grid)
$addFiles=Add-Button $setupPage 'Choose CAD files...' 18 199 200 {
    $dialog=New-Object Windows.Forms.OpenFileDialog
    try {
        $dialog.Filter='STEP / SOLIDWORKS parts|*.stp;*.step;*.sldprt'; $dialog.Multiselect=$true
        if ($dialog.ShowDialog($form) -eq 'OK') {
            foreach ($path in $dialog.FileNames) { $null=$grid.Rows.Add([IO.Path]::GetFileNameWithoutExtension($path),1,$path) }
            if ([string]::IsNullOrWhiteSpace($jobName.Text) -and $grid.Rows.Count -gt 0) { $jobName.Text=[string]$grid.Rows[0].Cells['PartName'].Value }
        }
    } finally { $dialog.Dispose() }
}
$clearFiles=Add-Button $setupPage 'Clear list' 233 199 130 { $grid.Rows.Clear() }
$setupStatus=Add-Label $setupPage 'Original CAD files are copied into a new, unique job folder. Work only on the staged copies.' 18 540 925 60
$createJob=Add-Button $setupPage 'Create job' 18 620 220 {
    try {
        $null=$grid.EndEdit()
        $partSpecs=@(foreach ($row in $grid.Rows) {
            $quantity=0
            if (-not [int]::TryParse([string]$row.Cells['Quantity'].Value,[ref]$quantity)) { throw 'Each quantity must be a whole number.' }
            [pscustomobject]@{ PartName=[string]$row.Cells['PartName'].Value; Quantity=$quantity; SourcePath=[string]$row.Cells['SourcePath'].Value }
        })
        $script:job=New-TubeJob $jobName.Text $parentPath.Text $partSpecs $stock.Value
        Show-PreparedJob
        Write-SessionLog 'Job prepared. No CAD programming has been performed by staging.'
    } catch { Show-Error $_.Exception.Message }
}
$resumeJob=Add-Button $setupPage 'Resume saved job...' 478 620 200 {
    try {
        $path=Select-File 'Open an existing helper job manifest' 'Helper job|job.json' $parentPath.Text
        if (-not $path) { return }
        $script:job=Open-TubeJob $path
        Show-PreparedJob
        Write-SessionLog 'Job resumed. Export checks and PDF review must be performed again.'
    } catch { Show-Error $_.Exception.Message }
}
$null=Add-Button $setupPage 'Open job folder' 258 620 200 {
    try { if ($null -eq $script:job) { throw 'Create a job first.' }; Show-Folder $script:job.Directory } catch { Show-Error $_.Exception.Message }
}

$null=Add-Label $partsPage 'Select a part. Work on its staged copy, confirm its profile and marking, then register the exported TEOX.' 18 18 940 40
$partList=New-Object Windows.Forms.ComboBox
$partList.Location=New-Object Drawing.Point(18,65); $partList.Width=925; $partList.DropDownStyle='DropDownList'
$partsPage.Controls.Add($partList)
$null=Add-Button $partsPage 'Open Tube Design' 18 105 190 { try { Launch-Application 'Tube Design' } catch { Show-Error $_.Exception.Message } }
$null=Add-Button $partsPage 'Import working copy' 223 105 200 { try { Invoke-DesktopAction Import } catch { Show-Error $_.Exception.Message } }
$null=Add-Button $partsPage 'Identify profile' 438 105 180 { try { Invoke-DesktopAction Identify } catch { Show-Error $_.Exception.Message } }
$null=Add-Button $partsPage 'Copy working path' 633 105 180 {
    try { [Windows.Forms.Clipboard]::SetText((Get-CurrentPart).WorkingCopy); $partsStatus.Text='Working-copy path copied. Paste it into the TRUMPF import dialog if needed.' } catch { Show-Error $_.Exception.Message }
}
$partInstructions=New-Object Windows.Forms.TextBox
$partInstructions.Location=New-Object Drawing.Point(18,155); $partInstructions.Size=New-Object Drawing.Size(925,240)
$partInstructions.Multiline=$true; $partInstructions.ReadOnly=$true; $partInstructions.ScrollBars='Vertical'
$partsPage.Controls.Add($partInstructions)
$profileReviewed=New-Object Windows.Forms.CheckBox
$profileReviewed.Text='I confirmed the correct body, material, dimensions, profile, direction, and identification in Tube Design.'
$profileReviewed.Location=New-Object Drawing.Point(18,412); $profileReviewed.Size=New-Object Drawing.Size(925,28)
$partsPage.Controls.Add($profileReviewed)
$markingReviewed=New-Object Windows.Forms.CheckBox
$markingReviewed.Text='I reviewed which contours are cut or marked, applied the intended settings, and confirmed them in Tube Design.'
$markingReviewed.Location=New-Object Drawing.Point(18,448); $markingReviewed.Size=New-Object Drawing.Size(925,28)
$partsPage.Controls.Add($markingReviewed)
$teoxLabel=Add-Label $partsPage 'No TEOX registered.' 18 490 925 44
$null=Add-Button $partsPage 'Register exported TEOX...' 18 544 230 {
    try {
        $part=Get-CurrentPart
        if (-not $profileReviewed.Checked -or -not $markingReviewed.Checked) { throw 'Complete and acknowledge profile/material and marking review first.' }
        $path=Select-File 'Choose the newly exported TEOX for this part' 'TEOX|*.teox' (Split-Path -Parent $part.WorkingCopy)
        if (-not $path) { return }
        $prefix=[IO.Path]::GetFullPath($script:job.Directory)+[IO.Path]::DirectorySeparatorChar
        if (-not [IO.Path]::GetFullPath($path).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Export into this job folder and choose that new TEOX.' }
        if ([IO.Path]::GetFileNameWithoutExtension($path) -ine $part.PartName) { throw 'TEOX filename must match this part name.' }
        if ((Get-Item -LiteralPath $path).LastWriteTimeUtc -lt ([DateTime]::Parse($script:job.CreatedUtc).ToUniversalTime().AddSeconds(-2))) { throw 'This TEOX predates this helper job. Export a fresh file.' }
        $archive=[IO.Compression.ZipFile]::OpenRead($path)
        try { if ($null -eq $archive.GetEntry('ColladaData.dae')) { throw 'This does not match the supported TEOX container format.' } } finally { $archive.Dispose() }
        $summary=Get-TeoxSummary $path $part.PartName
        $part.TeoxPath=$path; Save-TubeJob $script:job
        $part | Add-Member -NotePropertyName TeoxExportCheck -NotePropertyValue $summary -Force
        $part | Add-Member -NotePropertyName TeoxExportRequest -NotePropertyValue $null -Force
        if ($null -ne $script:teoxPart -and $script:teoxPart.PartName -ieq $part.PartName) { $teoxTimer.Stop() }
        $part | Add-Member -NotePropertyName AutoRunRequest -NotePropertyValue $null -Force
        $part | Add-Member -NotePropertyName AutoRunCalculation -NotePropertyValue $null -Force
        if ($null -ne $script:calculationPart -and $script:calculationPart.PartName -ieq $part.PartName) { $calculationTimer.Stop() }
        $script:report=$null; $pdfReviewed.Checked=$false
        $script:job.PackageReport=$null; $script:job.State='TEOX container verified; operator review retained'; Save-TubeJob $script:job
        $teoxLabel.Text='Registered: '+$path
        $packageInstructions.Text=Get-PackageInstructions
    } catch { Show-Error $_.Exception.Message }
}
$null=Add-Button $partsPage 'Open input/output folder' 263 544 180 {
    try {
        $part=Get-CurrentPart
        Show-Folder (Get-TubeOutputDirectory $script:job $partList.SelectedIndex)
    } catch { Show-Error $_.Exception.Message }
}
$null=Add-Button $partsPage 'Fill model save dialog' 458 544 170 { try { Invoke-DesktopAction ModelSave } catch { Show-Error $_.Exception.Message } }
$null=Add-Button $partsPage 'Save control report' 643 544 200 { try { Invoke-DesktopAction Capture } catch { Show-Error $_.Exception.Message } }
$null=Add-Button $partsPage 'Begin TEOX export' 18 586 230 { try { Invoke-DesktopAction TubeExport } catch { Show-Error $_.Exception.Message } }
$null=Add-Button $partsPage 'Check TEOX export' 263 586 230 { try { Start-TeoxWatch (Get-CurrentPart) } catch { Show-Error $_.Exception.Message } }
$null=Add-Button $partsPage 'Stop watching' 508 586 150 {
    $calculationTimer.Stop();$teoxTimer.Stop(); $partsStatus.Text='Stopped watching. Tube Design remains running and no files were removed.'
}
$partsStatus=Add-Label $partsPage 'Focus: CAD to TEOX. Import and export controls require local verification. Profile/marking and export selection are confirmed in Tube Design.' 18 638 925 70
$partList.Add_SelectedIndexChanged({
    try {
        $part=Get-CurrentPart
        $profileReviewed.Checked=$part.MaterialAndProfileReviewed; $markingReviewed.Checked=$part.MarkingReviewed
        $teoxLabel.Text=if ($part.TeoxPath) { 'Registered: '+$part.TeoxPath } else { 'No TEOX registered.' }
        $partInstructions.Text=@"
PART: $($part.PartName)     REQUIRED QUANTITY: $($part.Quantity)
Working copy: $($part.WorkingCopy)

1. Open Tube Design. Use Import working copy, or import this path manually. Wait for the correct model to appear. Stop on any unexpected prompt.
2. Use Identify profile or open that command manually. Select the intended body, confirm material/profile/dimensions/direction, and accept in Tube Design.
3. Assign process parameters. Choose and confirm marking contours where required. Do not apply the BEAM2 example's selections to unrelated parts.
4. Click Begin TEOX export. If Tube Design asks to save first, accept its save prerequisite yourself; when the model-save dialog appears, click Fill model save dialog here. Inspect any overwrite prompt yourself.
5. In Export production data, select the intended tube, review export settings, and accept the green check. Keep TRUMPF's normal save-beside-input behavior. The helper watches the working folder and its model-named child folder for a new TEOX and registers it after validation.
6. If the export is saved elsewhere inside this job, use Register exported TEOX. No Auto Run import or TPC is needed for this stage.

Repeat for each part. If one CAD file contains multiple separately produced profiles, stop: this release expects one part name/quantity per CAD file.
"@ -replace '\r?\n',"`r`n"
        $packageInstructions.Text=Get-PackageInstructions
    } catch { Show-Error $_.Exception.Message }
})
foreach ($check in @($profileReviewed,$markingReviewed)) {
    $check.Add_Click({
        try {
            $part=Get-CurrentPart
            $part.MaterialAndProfileReviewed=$profileReviewed.Checked; $part.MarkingReviewed=$markingReviewed.Checked
            if (-not $profileReviewed.Checked -or -not $markingReviewed.Checked) {
                $part.TeoxPath=$null; $teoxLabel.Text='Review changed: re-export and register the TEOX.'
                $part | Add-Member -NotePropertyName AutoRunRequest -NotePropertyValue $null -Force
                $part | Add-Member -NotePropertyName AutoRunCalculation -NotePropertyValue $null -Force
                if ($null -ne $script:calculationPart -and $script:calculationPart.PartName -ieq $part.PartName) { $calculationTimer.Stop() }
                if ($null -ne $script:teoxPart -and $script:teoxPart.PartName -ieq $part.PartName) { $teoxTimer.Stop() }
                $part | Add-Member -NotePropertyName TeoxExportCheck -NotePropertyValue $null -Force
            }
            $script:job.State='Part review'; $script:job.PackageReport=$null
            $script:report=$null; $pdfReviewed.Checked=$false
            Save-TubeJob $script:job
        } catch { Show-Error $_.Exception.Message }
    })
}

function Get-PackageInstructions {
    if ($null -eq $script:job) { return 'Create a job first.' }
    $partLines=($script:job.Parts | ForEach-Object { $_.PartName+' : Min. = Max. = '+$_.Quantity }) -join "`r`n"
    return @"
In Auto Run, select the successfully calculated parts and enter nesting.
Machine: TruLaser Tube 7000 (T12)
Job name: $($script:job.Name)
Stock length requested: $($script:job.StockLengthInches) inches

$partLines

Keep the Amount/job multiplier at 1 for these per-part quantities. Group compatible material/profile parts appropriately; do not combine incompatible stock.
Review stock and nesting settings, recalculate after editing quantities, and inspect the completed nest and warnings.
Keep TRUMPF's normal output location beside its input TEOX; there is no need to redirect the export or move its files.
Starting folder for the selected part:
$(Get-TubeOutputDirectory $script:job $partList.SelectedIndex)

The helper does not drive Auto Run/nesting controls yet. Perform these steps as in your recording, then select the two new files below. Check the PDF's job name, machine, parts, quantities, stock lengths, and tube layout yourself. Do not substitute an individual part report or timestamp-named intermediate TPC.
"@
}
$packageInstructions=New-Object Windows.Forms.TextBox
$packageInstructions.Location=New-Object Drawing.Point(18,18); $packageInstructions.Size=New-Object Drawing.Size(925,295)
$packageInstructions.Multiline=$true; $packageInstructions.ReadOnly=$true; $packageInstructions.ScrollBars='Vertical'
$packageInstructions.Text='Create a job first.'; $packagePage.Controls.Add($packageInstructions)
$expectedTpcLabel=Add-Label $packagePage 'Expected TPC: prepare a job first' 18 316 720 22
$tpcPath=Add-Text $packagePage 18 340 720
$null=Add-Button $packagePage 'Select final TPC...' 755 334 190 {
    try {
        if ($null -eq $script:job) { throw 'Create a job first.' }
        $path=Select-File 'Select the final named nested job TPC' 'TPC|*.tpc' (Get-TubeOutputDirectory $script:job $partList.SelectedIndex $tpcPath.Text)
        if ($path) { $tpcPath.Text=$path; $script:report=$null }
    } catch { Show-Error $_.Exception.Message }
}
$expectedPdfLabel=Add-Label $packagePage 'Expected PDF: prepare a job first' 18 366 720 22
$pdfPath=Add-Text $packagePage 18 390 720
$null=Add-Button $packagePage 'Select job PDF...' 755 384 190 {
    try {
        if ($null -eq $script:job) { throw 'Create a job first.' }
        $path=Select-File 'Select the matching Production Package PDF' 'PDF|*.pdf' (Get-TubeOutputDirectory $script:job $partList.SelectedIndex $tpcPath.Text)
        if ($path) { $pdfPath.Text=$path; $script:report=$null }
    } catch { Show-Error $_.Exception.Message }
}
$pdfReviewed=New-Object Windows.Forms.CheckBox
$pdfReviewed.Text='I opened the PDF and reviewed the matching job, machine, quantities, stock, and layout against this job.'
$pdfReviewed.Location=New-Object Drawing.Point(18,435); $pdfReviewed.Size=New-Object Drawing.Size(925,35)
$packagePage.Controls.Add($pdfReviewed)
$pdfReviewed.Add_CheckedChanged({
    $script:reviewedPdfHash=$null
    if ($pdfReviewed.Checked) {
        try {
            if (-not (Test-Path -LiteralPath $pdfPath.Text -PathType Leaf)) { throw 'Select and open the final PDF before confirming its contents.' }
            $script:reviewedPdfHash=(Get-FileHash -LiteralPath $pdfPath.Text -Algorithm SHA256).Hash
        } catch { $pdfReviewed.Checked=$false; Show-Error $_.Exception.Message }
    }
})
foreach ($pathBox in @($tpcPath,$pdfPath)) {
    $pathBox.Add_TextChanged({ $script:report=$null; $pdfReviewed.Checked=$false })
}
$packageStatus=Add-Label $packagePage 'No outputs checked. This helper does not simulate or certify machine programs.' 18 490 925 115
$null=Add-Button $packagePage 'Check and collect package' 18 625 260 {
    try {
        if ($null -eq $script:job) { throw 'Create a job first.' }
        foreach ($part in $script:job.Parts) {
            if (-not $part.MaterialAndProfileReviewed -or -not $part.MarkingReviewed -or -not $part.TeoxPath) {
                throw ('Complete the part review and register the TEOX for '+$part.PartName)
            }
        }
        foreach ($path in @($tpcPath.Text,$pdfPath.Text)) {
            $prefix=[IO.Path]::GetFullPath($script:job.Directory)+[IO.Path]::DirectorySeparatorChar
            if (-not [IO.Path]::GetFullPath($path).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Choose new output files from this job folder.' }
            if ((Get-Item -LiteralPath $path).LastWriteTimeUtc -lt ([DateTime]::Parse($script:job.CreatedUtc).ToUniversalTime().AddSeconds(-2))) { throw 'An output predates this job. Export a fresh named job package.' }
        }
        if (-not $pdfReviewed.Checked) { throw 'Open the PDF and complete its review first.' }
        if ((Get-FileHash -LiteralPath $pdfPath.Text -Algorithm SHA256).Hash -cne $script:reviewedPdfHash) {
            $pdfReviewed.Checked=$false
            throw 'The PDF changed after your review. Open the new version and confirm it again.'
        }
        $script:report=Test-TubePackage $script:job $tpcPath.Text $pdfPath.Text -PdfReviewed
        $destination=Copy-CheckedPackage $script:job $tpcPath.Text $pdfPath.Text $script:report
        $script:job.State='Metadata checked; operator release pending'
        $script:job.PackageReport=$script:report; Save-TubeJob $script:job
        Write-SessionLog ('Metadata checked and package copied: '+$destination)
        $packageStatus.Text="Job/part quantities and machine metadata match. PDF filename/signature checked; PDF contents were acknowledged by you.`r`nCollected: $destination`r`nComplete your usual TRUMPF simulation and operator release. This is not a machine-readiness certification."
        Show-Folder $destination
    } catch {
        $script:report=$null
        $failure=$_.Exception.Message
        $packageStatus.Text='Checks did not complete. '+$failure
        try { Write-SessionLog ('Package check failed: '+$failure) } catch { }
        Show-Error $failure
    }
}
$null=Add-Button $packagePage 'Open output folder' 295 625 230 {
    try { Show-Folder (Get-TubeOutputDirectory $script:job $partList.SelectedIndex $tpcPath.Text) } catch { Show-Error $_.Exception.Message }
}
$null=Add-Button $packagePage 'Change helper job name...' 540 625 260 {
    try {
        if ($null -eq $script:job) { throw 'Create or resume a job first.' }
        Add-Type -AssemblyName Microsoft.VisualBasic
        $name=[Microsoft.VisualBasic.Interaction]::InputBox('Enter the exact intended nested job name. This updates helper metadata only; files, folders, and TRUMPF programs are not renamed.','Helper job name',$script:job.Name)
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $oldName=$script:job.Name
        Set-TubeJobName $script:job $name
        $jobName.Text=$script:job.Name
        $script:report=$null; $pdfReviewed.Checked=$false
        $packageInstructions.Text=Get-PackageInstructions
        Update-ExpectedFileLabels
        Write-SessionLog ('Helper job name changed from ['+$oldName+'] to ['+$name+']. Output review reset.')
        $packageStatus.Text='Helper name updated. Select the matching final nested job TPC/PDF, review the PDF again, and rerun the checks.'
    } catch { Show-Error $_.Exception.Message }
}
$form.Add_FormClosing({ param($sender,$eventData) if ($script:busy) { $eventData.Cancel=$true } else { $calculationTimer.Stop();$teoxTimer.Stop() } })
try { [void]$form.ShowDialog() } finally { $calculationTimer.Dispose();$teoxTimer.Dispose(); $form.Dispose() }
