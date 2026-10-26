param(
    [Parameter(Mandatory)][string]$ReferenceTpc,
    [Parameter(Mandatory)][string]$ReferencePdf,
    [Parameter(Mandatory)][string]$ReferenceCad
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
    Reject { Test-TubePackage $job $ReferenceTpc $wrongName } 'PDF with wrong job filename is rejected' 'filenames'

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
    $another=New-TubeJob 'Staging test [1]' $temp $spec 240
    Check ($another.Directory -cne $staged.Directory) 'Repeated job preparation uses separate folders'
    $spec+= $spec[0]
    Reject { New-TubeJob 'duplicate parts' $temp $spec 240 } 'Duplicate part names are rejected'
    $fraction=@([pscustomobject]@{PartName=$cadSource.BaseName;Quantity=1.5;SourcePath=$cadSource.FullName})
    Reject { New-TubeJob 'fraction' $temp $fraction 240 } 'Fractional quantities are rejected' 'whole numbers'
    Write-Output "Completed: $script:passed checks passed. Windows GUI and live TRUMPF actions were not run."
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
