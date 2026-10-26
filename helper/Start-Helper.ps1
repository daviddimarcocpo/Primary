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
$form = New-Object Windows.Forms.Form
$form.Text = 'Tube Job Helper 0.1 - assisted workflow'
$form.ClientSize = New-Object Drawing.Size(1000,760)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object Drawing.Size(1016,799)
$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$form.Controls.Add($tabs)
$setupPage = New-Object Windows.Forms.TabPage('1. Prepare job')
$partsPage = New-Object Windows.Forms.TabPage('2. Design and program')
$packagePage = New-Object Windows.Forms.TabPage('3. Nest and check outputs')
$tabs.TabPages.AddRange(@($setupPage,$partsPage,$packagePage))

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
    if ($action -notin @('Import','Identify','Capture')) { throw 'Unsupported desktop action.' }
    $part=Get-CurrentPart
    $resultPath=Join-Path (Join-Path $script:job.Directory 'diagnostics') ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)+'.json')
    $worker=Join-Path $PSScriptRoot 'Desktop-Worker.ps1'
    foreach ($value in @($worker,$part.WorkingCopy,$resultPath)) {
        if ($value.Contains('"')) { throw 'A path contains an unsupported quotation mark.' }
    }
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -File "'+$worker+'" -Action '+$action+' -InputPath "'+$part.WorkingCopy+'" -ResultPath "'+$resultPath+'"'
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
    } finally {
        $workerProcess.Dispose(); $script:busy=$false; $form.Show(); $form.Activate()
    }
}
function Launch-Application($kind) {
    $paths = if ($kind -eq 'Tube Design') {
        @('C:\Program Files\TRUMPF\TruTops\TubeDesign\bin\sldworks.exe','C:\Program Files\TRUMPF\TruTops\TubeDesign\binTD\TubeDesign.exe')
    } else { @('C:\Program Files\TRUMPF\TruTops\ProgrammingTubeAutoRun\ProgrammingTubeAutoRun.exe') }
    $processName=if ($kind -eq 'Tube Design') { 'sldworks' } else { 'ProgrammingTubeAutoRun' }
    if (@(Get-Process -Name $processName -ErrorAction SilentlyContinue).Count -gt 0) {
        [void][Windows.Forms.MessageBox]::Show($form,"$kind is already running. Switch to its window.",'Application running')
        return
    }
    $exe=@($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) | Select-Object -First 1
    if (-not $exe) { throw "Installed $kind executable was not found at the recorded paths. Open it normally from your Start menu." }
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
}

function Show-PreparedJob {
    $setupStatus.Text='Job folder: '+$script:job.Directory
    $jobName.Text=$script:job.Name; $stock.Value=$script:job.StockLengthInches
    foreach ($control in @($createJob,$resumeJob,$addFiles,$clearFiles,$grid,$jobName,$stock,$parentPath)) { $control.Enabled=$false }
    $partList.Items.Clear()
    foreach ($part in $script:job.Parts) { $null=$partList.Items.Add($part.PartName+' - quantity '+$part.Quantity) }
    $partList.SelectedIndex=0; $tabs.SelectedTab=$partsPage
    $packageInstructions.Text=Get-PackageInstructions
}

$null=Add-Label $setupPage 'Local assistant for TRUMPF. No API license required. This version guides the workflow; it is not unattended programming.' 18 18 940 38
$null=Add-Label $setupPage 'Job name (use this exact name when exporting the nested job)' 18 65
$jobName=Add-Text $setupPage 18 91 620
$null=Add-Label $setupPage 'Stock length (inches)' 670 65 260
$stock=New-Object Windows.Forms.NumericUpDown
$stock.Location=New-Object Drawing.Point(670,91); $stock.Width=180
$stock.DecimalPlaces=3; $stock.Minimum=0.001; $stock.Maximum=10000; $stock.Value=240
$setupPage.Controls.Add($stock)
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
        $part.TeoxPath=$path; Save-TubeJob $script:job
        $teoxLabel.Text='Registered: '+$path
    } catch { Show-Error $_.Exception.Message }
}
$null=Add-Button $partsPage 'Copy TEOX path' 263 544 180 {
    try {
        $part=Get-CurrentPart
        if (-not $part.TeoxPath) { throw 'Register the newly exported TEOX first.' }
        [Windows.Forms.Clipboard]::SetText($part.TeoxPath)
        $partsStatus.Text='TEOX path copied. In Auto Run, select the T12 machine, click +, and paste this path.'
    } catch { Show-Error $_.Exception.Message }
}
$null=Add-Button $partsPage 'Open Auto Run' 458 544 170 { try { Launch-Application 'Auto Run' } catch { Show-Error $_.Exception.Message } }
$null=Add-Button $partsPage 'Save control report' 643 544 200 { try { Invoke-DesktopAction Capture } catch { Show-Error $_.Exception.Message } }
$partsStatus=Add-Label $partsPage 'Import/Identify controls are experimental until tested on your workstation. Manual operation remains available.' 18 600 925 80
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
4. Export production data. If asked to save SLDPRT, save beside this working copy with the same base name. Select the intended profile(s) and export TEOX with this part name into the working folder.
5. Register the new TEOX below. In Auto Run, choose TruLaser Tube 7000 (T12), click +, and import it. Wait for successful calculation and inspect any warnings.

Repeat for each part. If one CAD file contains multiple separately produced profiles, stop: this release expects one part name/quantity per CAD file.
"@ -replace '\r?\n',"`r`n"
    } catch { Show-Error $_.Exception.Message }
})
foreach ($check in @($profileReviewed,$markingReviewed)) {
    $check.Add_Click({
        try {
            $part=Get-CurrentPart
            $part.MaterialAndProfileReviewed=$profileReviewed.Checked; $part.MarkingReviewed=$markingReviewed.Checked
            if (-not $profileReviewed.Checked -or -not $markingReviewed.Checked) {
                $part.TeoxPath=$null; $teoxLabel.Text='Review changed: re-export and register the TEOX.'
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
Export the named nested job TPC and Production Package PDF into:
$(Join-Path $script:job.Directory 'generated')

The helper does not drive Auto Run/nesting controls yet. Perform these steps as in your recording, then select the two new files below. Check the PDF's job name, machine, parts, quantities, stock lengths, and tube layout yourself. Do not substitute an individual part report or timestamp-named intermediate TPC.
"@
}
$packageInstructions=New-Object Windows.Forms.TextBox
$packageInstructions.Location=New-Object Drawing.Point(18,18); $packageInstructions.Size=New-Object Drawing.Size(925,295)
$packageInstructions.Multiline=$true; $packageInstructions.ReadOnly=$true; $packageInstructions.ScrollBars='Vertical'
$packageInstructions.Text='Create a job first.'; $packagePage.Controls.Add($packageInstructions)
$tpcPath=Add-Text $packagePage 18 340 720
$null=Add-Button $packagePage 'Select final TPC...' 755 334 190 {
    try {
        if ($null -eq $script:job) { throw 'Create a job first.' }
        $path=Select-File 'Select the final named nested job TPC' 'TPC|*.tpc' (Join-Path $script:job.Directory 'generated')
        if ($path) { $tpcPath.Text=$path; $script:report=$null }
    } catch { Show-Error $_.Exception.Message }
}
$pdfPath=Add-Text $packagePage 18 390 720
$null=Add-Button $packagePage 'Select job PDF...' 755 384 190 {
    try {
        if ($null -eq $script:job) { throw 'Create a job first.' }
        $path=Select-File 'Select the matching Production Package PDF' 'PDF|*.pdf' (Join-Path $script:job.Directory 'generated')
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
    } catch { $script:report=$null; $packageStatus.Text='Checks did not complete. '+$_.Exception.Message; Show-Error $_.Exception.Message }
}
$null=Add-Button $packagePage 'Open generated folder' 295 625 230 {
    try { if ($null -eq $script:job) { throw 'Create a job first.' }; Show-Folder (Join-Path $script:job.Directory 'generated') } catch { Show-Error $_.Exception.Message }
}
$form.Add_FormClosing({ param($sender,$eventData) if ($script:busy) { $eventData.Cancel=$true } })
try { [void]$form.ShowDialog() } finally { $form.Dispose() }
