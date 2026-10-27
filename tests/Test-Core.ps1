param(
    [Parameter(Mandatory)][string]$ReferenceTpc,
    [Parameter(Mandatory)][string]$ReferencePdf,
    [Parameter(Mandatory)][string]$ReferenceCad,
    [Parameter(Mandatory)][string]$ReferenceTubx,
    [Parameter(Mandatory)][string]$ReferenceTeox
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'helper/TubeJob.Core.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:passed=0
function Check($condition,$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:passed++; Write-Output "PASS: $message"
}
function Reject([scriptblock]$action,[string]$message,[string]$expectedPattern='') {
    $failure=$null
    try { $null=& $action } catch { $failure=$_.Exception.Message }
    if (-not $failure) { throw "FAIL: $message did not reject input" }
    if ($expectedPattern -and $failure -notmatch $expectedPattern) { throw "FAIL: $message failed for unexpected reason: $failure" }
    $script:passed++; Write-Output "PASS: $message"
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('tube-helper-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temp
try {
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $repo 'helper') -File | Where-Object { $_.Extension -in @('.ps1','.psm1') })) {
        $tokens=$null; $errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        Check ($errors.Count -eq 0) ('PowerShell parses: '+$file.Name+' '+($errors -join '; '))
    }
    $fields=ConvertFrom-TrumpfCsv "'O''Brien, sample','Assembly Beam2','Assembly_Beam2',10"
    Check ($fields.Count -eq 4 -and $fields[0] -ceq "O'Brien, sample" -and $fields[3] -ceq '10') 'TRUMPF quoted commas and escaped apostrophes'
    Reject { ConvertFrom-TrumpfCsv "'unterminated,10" } 'Malformed quoted record' 'Unterminated'
    Reject { Test-JobName '../other' } 'Path traversal in job name'
    Reject { Test-JobName 'CON.txt' } 'Reserved Windows filename'
    $normal=[pscustomobject]@{Name='Tube Design 17';Path='C:\Start Menu\Tube Design 17.lnk';TargetPath='C:\Program Files\TRUMPF\TruTops\TubeDesign\binTD\TubeDesign.exe';Arguments='-installed-mode';WorkingDirectory='C:\Program Files\TRUMPF\TruTops\TubeDesign\binTD'}
    $wrong=[pscustomobject]@{Name='Tube Design';Path='C:\Desktop\Tube Design.lnk';TargetPath='C:\Program Files\TRUMPF\TruTops\TubeDesign\bin\sldworks.exe';Arguments='';WorkingDirectory=''}
    $routes=@(Get-TubeDesignShortcutCandidates @($wrong,$normal))
    Check ($routes.Count -eq 1 -and $routes[0].Path -ceq $normal.Path) 'Tube Design startup excludes direct sldworks and selects the TRUMPF starter shortcut'
    Check ($routes[0].Arguments -ceq '-installed-mode' -and $routes[0].WorkingDirectory -ceq $normal.WorkingDirectory) 'Starter shortcut arguments and working directory are retained'
    Check (@(Get-TubeDesignShortcutCandidates @($wrong)).Count -eq 0) 'No direct sldworks fallback when a starter shortcut is missing'
    $duplicateRoute=[pscustomobject]@{Name=$normal.Name;Path='C:\Desktop\Tube Design 17.lnk';TargetPath=$normal.TargetPath;Arguments=$normal.Arguments;WorkingDirectory=$normal.WorkingDirectory}
    Check (@(Get-TubeDesignShortcutCandidates @($normal,$duplicateRoute)).Count -eq 1) 'Equivalent installed starter shortcuts are deduplicated'
    $desktopSource=Get-Content -LiteralPath (Join-Path $repo 'helper/TubeJob.Desktop.psm1') -Raw
    $nativeSource=[regex]::Match($desktopSource,"(?s)Add-Type @'\r?\n(.*?)\r?\n'@").Groups[1].Value
    Add-Type -TypeDefinition $nativeSource
    Check ($null -ne ('TubeJobNative' -as [type])) 'Native Win32 adapter compiles (Windows functions not invoked here)'
    $nativeState=New-Object TubeJobNative+ToolbarState
    $nativeState.ProcessId=123; $nativeState.ToolbarId=59424; $nativeState.ClassName='ToolbarWindow32'
    $nativeState.Visible=$true; $nativeState.Enabled=$true; $nativeState.CommandIndex=2; $nativeState.ButtonState=4
    Assert-TubeToolbarState $nativeState 123 59424
    Check $true 'Native fallback accepts a verified visible and enabled command'
    Reject { Assert-TubeToolbarState $nativeState 999 59424 } 'Native fallback rejects a different process' 'identity'
    Reject { Assert-TubeToolbarState $nativeState 123 59430 } 'Native fallback rejects a different toolbar' 'identity'
    $nativeState.ClassName='OtherWindow'
    Reject { Assert-TubeToolbarState $nativeState 123 59424 } 'Native fallback rejects a different window class' 'identity'
    $nativeState.ClassName='ToolbarWindow32'; $nativeState.CommandIndex=-1
    Reject { Assert-TubeToolbarState $nativeState 123 59424 } 'Native fallback rejects an absent command' 'enabled, visible'
    $nativeState.CommandIndex=2; $nativeState.ButtonState=12
    Reject { Assert-TubeToolbarState $nativeState 123 59424 } 'Native fallback rejects a hidden command' 'enabled, visible'
    $nativeState.ButtonState=0
    Reject { Assert-TubeToolbarState $nativeState 123 59424 } 'Native fallback rejects a disabled command' 'enabled, visible'
    $summary=Get-TpcSummary $ReferenceTpc
    Check ($summary.Parts.Count -eq 1 -and $summary.Parts[0].Quantity -eq 10) 'Actual uploaded TPC contains one part type and quantity 10'
    Check ($summary.Parts[0].JobName -ceq 'CODEX TEST 10262026 SQ6X25') 'Actual TPC job identity'
    Check ($summary.Machines.Count -eq 1 -and $summary.Machines[0] -ceq 'T12') 'Actual TPC machine identity'
    $job=[pscustomobject]@{
        Name='CODEX TEST 10262026 SQ6X25'; Machine='T12'
        Parts=@([pscustomobject]@{PartName='Assembly Beam2';Quantity=10})
        Directory=$temp
    }
    $null=New-Item -ItemType Directory -Path (Join-Path $temp 'deliverables')
    $report=Test-TubePackage $job $ReferenceTpc $ReferencePdf -PdfReviewed
    Check ($report.MetadataChecks -eq 'Passed' -and -not $report.MachineReady) 'Actual PDF/TPC pair passes metadata checks without a machine-ready claim'
    $job.Parts[0].Quantity=11
    Reject { Test-TubePackage $job $ReferenceTpc $ReferencePdf } 'Wrong requested quantity' 'mismatch'
    $job.Parts[0].Quantity=10; $job.Machine='OTHER'
    Reject { Test-TubePackage $job $ReferenceTpc $ReferencePdf } 'Wrong machine' 'machine'
    $job.Machine='T12'; $job.Parts[0].PartName='Different part'
    Reject { Test-TubePackage $job $ReferenceTpc $ReferencePdf } 'Wrong part name' 'mismatch'
    $job.Parts[0].PartName='Assembly Beam2'
    $noReview=Test-TubePackage $job $ReferenceTpc $ReferencePdf
    Reject { Copy-CheckedPackage $job $ReferenceTpc $ReferencePdf $noReview } 'PDF review is mandatory before collection' 'review'
    $destination=Copy-CheckedPackage $job $ReferenceTpc $ReferencePdf $report
    Check ((Get-FileHash -LiteralPath (Join-Path $destination ([IO.Path]::GetFileName($ReferenceTpc)))).Hash -ceq $report.TpcSHA256) 'Collected TPC remains byte-for-byte unchanged'
    Check ((Get-FileHash -LiteralPath (Join-Path $destination ([IO.Path]::GetFileName($ReferencePdf)))).Hash -ceq $report.PdfSHA256) 'Collected PDF remains byte-for-byte unchanged'
    $report.TpcSHA256='changed'
    Reject { Copy-CheckedPackage $job $ReferenceTpc $ReferencePdf $report } 'Change after validation is detected' 'changed'

    # Modify only temporary copies to exercise failures against the real archive format.
    $archive=[IO.Compression.ZipFile]::OpenRead($ReferenceTpc)
    try {
        $entry=@($archive.Entries | Where-Object { $_.FullName -match '^PROGRAMS/.*\.lst$' })[0]
        $reader=New-Object IO.StreamReader($entry.Open())
        try { $program=$reader.ReadToEnd() } finally { $reader.Dispose() }
        $entryName=$entry.FullName
    } finally { $archive.Dispose() }
    function Make-Tpc($fileName,$content,[switch]$DuplicateEntry) {
        $path=Join-Path $temp $fileName
        $archive=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $count=if ($DuplicateEntry) { 2 } else { 1 }
            for ($i=0;$i -lt $count;$i++) {
                $member=$archive.CreateEntry($entryName)
                $writer=New-Object IO.StreamWriter($member.Open())
                try { $writer.Write($content) } finally { $writer.Dispose() }
            }
        } finally { $archive.Dispose() }
        return $path
    }
    $noHeader=[regex]::Replace($program,'(?ms)^BEGIN_FERTIGUNG_AUFTRAG_TMP.*?^ENDE_FERTIGUNG_AUFTRAG_TMP\r?\n','')
    $individual=Make-Tpc 'individual.tpc' $noHeader
    Reject { Get-TpcSummary $individual } 'Individual part TPC cannot substitute for a nested job' 'nested-job header'
    Test-AutoRunContext $true @('TruLaser Tube 7000 (T12)') 1 0
    Check $true 'Auto Run handoff accepts a selected Auto Run tab, verified T12, and one import dialog'
    Reject { Test-AutoRunContext $false @('TruLaser Tube 7000 (T12)') 1 0 } 'Auto Run handoff rejects nesting tabs' 'Auto Run tab'
    Reject { Test-AutoRunContext $true @('Other machine') 1 0 } 'Auto Run handoff rejects an unverified machine' 'machine'
    Reject { Test-AutoRunContext $true @('TruLaser Tube 7000 (T12)') 0 0 } 'Auto Run handoff requires its specific import dialog' 'dialog'
    Reject { Test-AutoRunContext $true @('TruLaser Tube 7000 (T12)') 1 1 } 'Auto Run handoff refuses an existing visible queue part' 'duplicate'
    $properties=Read-TubxProperties $ReferenceTubx
    Check (-not $properties.HasErrors -and $properties.Machine -ceq 'TruLaser Tube 7000 (T12)') 'Real uploaded TUBX properties are readable without processing errors'
    $calcFolder=Join-Path $temp 'calculation';$null=New-Item -ItemType Directory -Path $calcFolder
    $inputTeox=Join-Path $calcFolder 'Assembly Beam2.teox'
    Copy-Item -LiteralPath $ReferenceTeox -Destination $inputTeox
    $request=[pscustomobject]@{InputPath=$inputTeox;InputSHA256=(Get-FileHash -LiteralPath $inputTeox).Hash;
        PartName='Assembly Beam2';RequestedUtc=[DateTime]::UtcNow.AddSeconds(-10).ToString('o');
        PriorOutputs=@(foreach ($ext in @('.tpc','.tubx','.pdf')) { [pscustomobject]@{Path=[IO.Path]::ChangeExtension($inputTeox,$ext);Exists=$false} })}
    $calcTpc=[IO.Path]::ChangeExtension($inputTeox,'.tpc');$calcTubx=[IO.Path]::ChangeExtension($inputTeox,'.tubx');$calcPdf=[IO.Path]::ChangeExtension($inputTeox,'.pdf')
    function Reset-CalculationFiles {
        Copy-Item -LiteralPath $individual -Destination $calcTpc -Force
        Copy-Item -LiteralPath $ReferenceTubx -Destination $calcTubx -Force
        Copy-Item -LiteralPath $ReferencePdf -Destination $calcPdf -Force
        foreach ($path in @($calcTpc,$calcTubx,$calcPdf)) { [IO.File]::SetLastWriteTimeUtc($path,[DateTime]::UtcNow.AddSeconds(-3)) }
    }
    Reset-CalculationFiles
    Check ((Test-AutoRunCalculation $request).Status -eq 'OutputsVerified') 'Fresh consistent part outputs verify independently of final job collection'
    $edgeRequest=$request | Select-Object *
    $edgeRequest.RequestedUtc=[DateTime]::UtcNow.AddSeconds(-2).ToString('o')
    $edgeRequest.PriorOutputs=@(foreach ($path in @($calcTpc,$calcTubx,$calcPdf)) {
        $item=Get-Item -LiteralPath $path
        [pscustomobject]@{Path=$path;Exists=$true;Length=$item.Length;WriteTicks=$item.LastWriteTimeUtc.Ticks;SHA256=(Get-FileHash -LiteralPath $path).Hash}
    })
    Check ((Test-AutoRunCalculation $edgeRequest).Status -eq 'Pending') 'An unchanged cached output is rejected even within timestamp tolerance'
    [IO.File]::SetLastWriteTimeUtc($calcTpc,[DateTime]::UtcNow.AddHours(-1))
    Check ((Test-AutoRunCalculation $request).Status -eq 'Pending') 'Stale cached part output cannot count as a fresh calculation'
    Reset-CalculationFiles;Remove-Item -LiteralPath $calcPdf
    Check ((Test-AutoRunCalculation $request).Status -eq 'Pending') 'Missing part PDF keeps calculation pending'
    Reset-CalculationFiles;Add-Content -LiteralPath $inputTeox -Value 'changed'
    Check ((Test-AutoRunCalculation $request).Status -eq 'Failed') 'Changed TEOX invalidates its import receipt'
    Copy-Item -LiteralPath $ReferenceTeox -Destination $inputTeox -Force
    $wrongMachine=Make-Tpc 'calc-wrong-machine.tpc' ($noHeader.Replace("DA,'T12',1", "DA,'OTHER',1"))
    Reset-CalculationFiles;Copy-Item -LiteralPath $wrongMachine -Destination $calcTpc -Force
    [IO.File]::SetLastWriteTimeUtc($calcTpc,[DateTime]::UtcNow.AddSeconds(-3))
    Check ((Test-AutoRunCalculation $request).Status -eq 'Failed') 'Wrong calculated machine is rejected'
    $wrongPart=Make-Tpc 'calc-wrong-part.tpc' ($noHeader.Replace("'Assembly_Beam2','HP'", "'DifferentPart','HP'"))
    Reset-CalculationFiles;Copy-Item -LiteralPath $wrongPart -Destination $calcTpc -Force
    [IO.File]::SetLastWriteTimeUtc($calcTpc,[DateTime]::UtcNow.AddSeconds(-3))
    Check ((Test-AutoRunCalculation $request).Status -eq 'Failed') 'Wrong calculated part program is rejected'
    Reset-CalculationFiles;Copy-Item -LiteralPath $ReferenceTpc -Destination $calcTpc -Force
    [IO.File]::SetLastWriteTimeUtc($calcTpc,[DateTime]::UtcNow.AddSeconds(-3))
    Check ((Test-AutoRunCalculation $request).Status -eq 'Failed') 'Nested package cannot substitute for fresh individual-part output'
    function Write-TestTubx([string]$xml) {
        Remove-Item -LiteralPath $calcTubx
        $archive=[IO.Compression.ZipFile]::Open($calcTubx,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry=$archive.CreateEntry('tubeProps/app.xml');$writer=New-Object IO.StreamWriter($entry.Open())
            try { $writer.Write($xml) } finally { $writer.Dispose() }
        } finally { $archive.Dispose() }
        [IO.File]::SetLastWriteTimeUtc($calcTubx,[DateTime]::UtcNow.AddSeconds(-3))
    }
    $xml='<appProperties><machineId>TruLaser Tube 7000 (T12)</machineId><profileId>1_600X600X50_1_25</profileId><errors /></appProperties>'
    Reset-CalculationFiles;Write-TestTubx ($xml.Replace('<errors />','<errors><error>Processing failed</error></errors>'))
    Check ((Test-AutoRunCalculation $request).Status -eq 'Failed') 'Reported TUBX processing errors are rejected'
    Reset-CalculationFiles;Write-TestTubx ($xml.Replace('1_600X600X50_1_25','wrong-profile'))
    Check ((Test-AutoRunCalculation $request).Status -eq 'Failed') 'TPC and TUBX profile disagreement is rejected'
    Write-TestTubx ('<!DOCTYPE appProperties [<!ENTITY sample "text">]>'+ $xml)
    Reject { Read-TubxProperties $calcTubx } 'TUBX XML document type declarations are prohibited'
    Reset-CalculationFiles;[IO.File]::WriteAllText($calcTpc,'incomplete')
    [IO.File]::SetLastWriteTimeUtc($calcTpc,[DateTime]::UtcNow.AddSeconds(-3))
    Check ((Test-AutoRunCalculation $request).Status -eq 'Pending') 'Incomplete or unreadable calculation output is not marked verified'
    $duplicate=Make-Tpc 'duplicate.tpc' $program -DuplicateEntry
    Reject { Get-TpcSummary $duplicate } 'Duplicate ZIP entries are rejected' 'Duplicate'
    $zeroQty=Make-Tpc 'zero.tpc' ($program.Replace("'Assembly_Beam2',10","'Assembly_Beam2',0"))
    Reject { Get-TpcSummary $zeroQty } 'Zero job quantity is rejected' 'quantity'
    $broken=Join-Path $temp 'broken.tpc'
    [IO.File]::WriteAllText($broken,'not a zip')
    Reject { Get-TpcSummary $broken } 'Unreadable archive is rejected'
    $badPdf=Join-Path $temp ([IO.Path]::GetFileName($ReferencePdf))
    [IO.File]::WriteAllText($badPdf,'This is not a PDF document')
    Reject { Test-TubePackage $job $ReferenceTpc $badPdf } 'Fake PDF file is rejected' 'signature'
    $wrongName=Join-Path $temp 'DifferentJob.pdf'
    Copy-Item -LiteralPath $ReferencePdf -Destination $wrongName
    Reject { Test-TubePackage $job $ReferenceTpc $wrongName } 'PDF with wrong job filename is rejected' '(?s)Helper job name: \[CODEX TEST 10262026 SQ6X25\].*Selected TPC: \[CODEX TEST 10262026 SQ6X25\.tpc\].*Selected PDF: \[DifferentJob\.pdf\]'

    $cadSource=Get-Item -LiteralPath $ReferenceCad
    $originalHash=(Get-FileHash -LiteralPath $cadSource.FullName).Hash
    $spec=@([pscustomobject]@{PartName=$cadSource.BaseName;Quantity=10;SourcePath=$cadSource.FullName})
    $staged=New-TubeJob 'Staging test [1]' $temp $spec 240
    Check ((Get-FileHash -LiteralPath $staged.Parts[0].WorkingCopy).Hash -ceq $originalHash) 'CAD working copy retains exact source bytes'
    Check ((Get-FileHash -LiteralPath $cadSource.FullName).Hash -ceq $originalHash) 'Original uploaded CAD remains unchanged'
    Check (Test-Path -LiteralPath (Join-Path $staged.Directory 'job.json')) 'Job manifest is saved in the staged run folder'
    $reopened=Open-TubeJob (Join-Path $staged.Directory 'job.json')
    Check ($reopened.Name -ceq $staged.Name -and $reopened.Parts[0].Quantity -eq 10) 'Saved job can be resumed with its quantities and staged copies'
    $reopened.Parts[0].WorkingCopy=$ReferenceCad
    Save-TubeJob $reopened
    Reject { Open-TubeJob (Join-Path $staged.Directory 'job.json') } 'Resume rejects working-copy path outside the job folder' 'outside'
    Save-TubeJob $staged
    $originalDirectory=$staged.Directory
    $staged.PackageReport=[pscustomobject]@{MetadataChecks='Passed'}
    Set-TubeJobName $staged 'Revised nested job'
    $renamed=Open-TubeJob (Join-Path $staged.Directory 'job.json')
    Check ($renamed.Name -ceq 'Revised nested job' -and $renamed.Directory -ceq $originalDirectory -and (Test-Path -LiteralPath $renamed.Parts[0].WorkingCopy)) 'Helper job name can be corrected without moving the job or CAD files'
    Check ($null -eq $renamed.PackageReport -and $renamed.State -eq 'Job name changed; output review pending') 'Changing the helper name clears prior package approval'
    Reject { Set-TubeJobName $staged '../invalid' } 'Invalid helper name correction is rejected'
    $another=New-TubeJob 'Staging test [1]' $temp $spec 240
    Check ($another.Directory -cne $staged.Directory) 'Repeated job preparation uses separate folders'
    Check ((Get-TubeOutputDirectory $another) -ceq (Split-Path -Parent $another.Parts[0].WorkingCopy)) 'Output picker defaults beside the working input before TEOX registration'
    $exportFolder=Join-Path (Split-Path -Parent $another.Parts[0].WorkingCopy) 'native-exports'
    $null=New-Item -ItemType Directory -Path $exportFolder
    $another.Parts[0].TeoxPath=Join-Path $exportFolder 'Assembly Beam2.teox'
    Check ((Get-TubeOutputDirectory $another) -ceq $exportFolder) 'Output picker follows the registered TEOX input folder'
    $finalTpc=Join-Path $another.Directory 'sample.tpc'
    Copy-Item -LiteralPath $ReferenceTpc -Destination $finalTpc
    Check ((Get-TubeOutputDirectory $another 0 $finalTpc) -ceq $another.Directory) 'Matching PDF picker starts beside the chosen TPC'
    $spec+= $spec[0]
    Reject { New-TubeJob 'duplicate parts' $temp $spec 240 } 'Duplicate part names are rejected'
    $fraction=@([pscustomobject]@{PartName=$cadSource.BaseName;Quantity=1.5;SourcePath=$cadSource.FullName})
    Reject { New-TubeJob 'fraction' $temp $fraction 240 } 'Fractional quantities are rejected' 'whole numbers'
    Write-Output "Completed: $script:passed checks passed. Windows GUI and live TRUMPF actions were not run."
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
