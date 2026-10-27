Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertFrom-TrumpfCsv {
    param([Parameter(Mandatory)][string]$Line)
    $fields = New-Object 'System.Collections.Generic.List[string]'
    $value = New-Object System.Text.StringBuilder
    $quoted = $false
    $closed = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($quoted) {
            if ($c -eq "'") {
                if ($i + 1 -lt $Line.Length -and $Line[$i + 1] -eq "'") {
                    [void]$value.Append("'"); $i++
                } else { $quoted = $false; $closed = $true }
            } else { [void]$value.Append($c) }
        } elseif ($c -eq ',') {
            $fields.Add($value.ToString().Trim()); [void]$value.Clear(); $closed = $false
        } elseif ($c -eq "'") {
            if ($closed -or $value.ToString().Trim().Length -ne 0) { throw 'Invalid quote in TRUMPF record.' }
            [void]$value.Clear(); $quoted = $true
        } elseif (-not [char]::IsWhiteSpace($c) -or -not $closed) {
            if ($closed) { throw 'Unexpected text after quoted field.' }
            [void]$value.Append($c)
        }
    }
    if ($quoted) { throw 'Unterminated quoted TRUMPF record.' }
    $fields.Add($value.ToString().Trim())
    return ,$fields.ToArray()
}

function Read-TrumpfTable {
    param([string]$Text, [string]$Section)
    $pattern = '(?ms)^BEGIN_' + [regex]::Escape($Section) + '\r?$\n(.*?)^ENDE_' + [regex]::Escape($Section) + '\r?$'
    $blocks = [regex]::Matches($Text, $pattern)
    $tables = New-Object 'System.Collections.Generic.List[object]'
    foreach ($block in $blocks) {
        $attributes = New-Object 'System.Collections.Generic.List[int]'
        $rawRecords = New-Object 'System.Collections.Generic.List[string]'
        $currentRecord = $null
        foreach ($line in ($block.Groups[1].Value -split '\r?\n')) {
            if ($line.StartsWith('DA,')) {
                if ($null -ne $currentRecord) { $rawRecords.Add($currentRecord) }
                $currentRecord = $line.Substring(3)
            } elseif ($line.StartsWith('*')) {
                if ($null -eq $currentRecord) { throw "Unexpected continuation in $Section." }
                $currentRecord += $line.Substring(1).TrimStart()
            } elseif ($line.StartsWith('-')) {
                throw "Unsupported split string in $Section. Stop for review."
            } else {
                if ($null -ne $currentRecord) { $rawRecords.Add($currentRecord); $currentRecord = $null }
                if ($line.StartsWith('MM,AT,')) {
                    $columns = ConvertFrom-TrumpfCsv $line
                    if ($columns.Count -lt 8 -or $columns[2] -ne '1') { throw "Unsupported schema in $Section." }
                    $attributeId = [int]::Parse($columns[3], [Globalization.CultureInfo]::InvariantCulture)
                    if ($attributes.Contains($attributeId)) { throw "Duplicate attribute in $Section." }
                    $attributes.Add($attributeId)
                }
            }
        }
        if ($null -ne $currentRecord) { $rawRecords.Add($currentRecord) }
        $records = New-Object 'System.Collections.Generic.List[object]'
        foreach ($record in $rawRecords) {
            $columns = ConvertFrom-TrumpfCsv $record
            if ($columns.Count -ne $attributes.Count) { throw "Record/schema length mismatch in $Section." }
            $mapped = @{}
            for ($i = 0; $i -lt $attributes.Count; $i++) { $mapped[[string]$attributes[$i]] = $columns[$i] }
            $records.Add($mapped)
        }
        $tables.Add([pscustomobject]@{ Records = $records.ToArray() })
    }
    return $tables.ToArray()
}

function Get-TpcSummary {
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -gt 134217728 -or $file.Length -eq 0) { throw 'TPC must be nonempty and at most 128 MiB.' }
    $archive = [IO.Compression.ZipFile]::OpenRead($file.FullName)
    try {
        if ($archive.Entries.Count -eq 0 -or $archive.Entries.Count -gt 512) { throw 'Unsupported TPC archive entry count.' }
        $seen = @{}
        $total = [long]0
        $parts = New-Object 'System.Collections.Generic.List[object]'
        $machines = New-Object 'System.Collections.Generic.List[string]'
        $profiles = New-Object 'System.Collections.Generic.List[string]'
        $programCount = 0
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if ($seen.ContainsKey($name) -or $name -match '(^/|(^|/)\.\.(/|$)|:)') { throw 'Duplicate or unsafe TPC entry name.' }
            $seen[$name] = $true
            $total += $entry.Length
            if ($entry.Length -gt 67108864 -or $total -gt 134217728) { throw 'TPC decompressed size exceeds inspection limits.' }
            # Read each member without extracting it or executing any program content.
            $stream = $entry.Open()
            $memory = New-Object IO.MemoryStream
            try {
                $buffer = New-Object byte[] 65536
                $actual = [long]0
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $actual += $read
                    if ($actual -gt $entry.Length -or $actual -gt 67108864) { throw 'TPC member size mismatch.' }
                    if ($name -match '(?i)^PROGRAMS/[^/]+\.lst$') { $memory.Write($buffer, 0, $read) }
                }
                if ($actual -ne $entry.Length) { throw 'Incomplete TPC member.' }
                if ($name -notmatch '(?i)^PROGRAMS/[^/]+\.lst$') { continue }
                $programCount++
                $encoding = New-Object Text.UTF8Encoding($false, $true)
                $text = $encoding.GetString($memory.ToArray()).TrimStart([char]0xFEFF)
                if ($text -notmatch '(?m)^START_TEXT\r?$' -or $text -notmatch '(?m)^STOP_TEXT\r?$') {
                    throw 'TPC does not contain a complete supported NC text section.'
                }
                foreach ($table in @(Read-TrumpfTable $text 'FERTIGUNG_AUFTRAG_TMP')) {
                    foreach ($row in $table.Records) {
                        foreach ($key in @('10','20','40','50')) {
                            if (-not $row.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($row[$key])) { throw 'Incomplete job header.' }
                        }
                        $quantity = 0
                        if (-not [int]::TryParse($row['50'], [ref]$quantity) -or $quantity -le 0) { throw 'Invalid TPC job quantity.' }
                        $parts.Add([pscustomobject]@{
                            JobName=$row['10']; PartName=$row['20']; ProgramName=$row['40']; Quantity=$quantity
                        })
                    }
                }
                foreach ($table in @(Read-TrumpfTable $text 'EINRICHTEPLAN_INFO')) {
                    foreach ($row in $table.Records) {
                        if (-not $row.ContainsKey('10')) { throw 'Machine identity is missing.' }
                        $machines.Add($row['10'])
                    }
                }
                foreach ($table in @(Read-TrumpfTable $text 'TUBE_TECH')) {
                    foreach ($row in $table.Records) { if ($row.ContainsKey('10')) { $profiles.Add($row['10']) } }
                }
            } finally { $stream.Dispose(); $memory.Dispose() }
        }
        if ($programCount -eq 0 -or $parts.Count -eq 0 -or $machines.Count -eq 0) {
            throw 'No supported nested-job header and machine identity found. An individual part TPC is insufficient.'
        }
        $keys = @{}
        foreach ($part in $parts) {
            $key = $part.JobName + [char]0 + $part.PartName
            if ($keys.ContainsKey($key)) { throw 'Duplicate job/part allocation; stop for review.' }
            $keys[$key] = $true
        }
        [pscustomobject]@{
            Parts=$parts.ToArray(); Machines=@($machines | Select-Object -Unique)
            Profiles=@($profiles | Select-Object -Unique); ProgramCount=$programCount
            ArchiveReadability='Passed (not an independent ZIP CRC or toolpath check)'
        }
    } finally { $archive.Dispose() }
}

function Test-JobName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 80 -or
        $Name -match '[^\x20-\x7e]|[<>:"/\\|?*]' -or $Name -match '[. ]$' -or
        $Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        throw 'Use a job name of 1-80 plain English characters without Windows filename symbols or trailing spaces/dots.'
    }
    return $true
}

function Get-TubeDesignShortcutCandidates {
    param([object[]]$Shortcuts)
    # A running sldworks.exe is not the Tube Design starter. Preserve the normal
    # TRUMPF shortcut, including arguments and working directory, as one route.
    $seen = @{}
    foreach ($shortcut in $Shortcuts) {
        if ($shortcut.Name -notmatch '(?i)Tube[\s_-]*Design' -or
            $shortcut.Path -notmatch '(?i)\.lnk$' -or
            $shortcut.TargetPath -notmatch '(?i)[\\/]TRUMPF[\\/].*\.exe$' -or
            $shortcut.TargetPath -match '(?i)(^|[\\/])sldworks\.exe$') { continue }
        $route = $shortcut.TargetPath + [char]0 + $shortcut.Arguments + [char]0 + $shortcut.WorkingDirectory
        if (-not $seen.ContainsKey($route)) {
            $seen[$route] = $true
            Write-Output $shortcut
        }
    }
}

function Assert-TubeToolbarState {
    param($State,[int]$ExpectedProcessId,[int]$ExpectedToolbarId)
    if ($State.ProcessId -ne $ExpectedProcessId -or $State.ToolbarId -ne $ExpectedToolbarId -or
        $State.ClassName -cne 'ToolbarWindow32' -or -not $State.Visible -or -not $State.Enabled) {
        throw 'Native toolbar identity or visibility does not match the intended Tube Design window.'
    }
    if ($State.CommandIndex -lt 0 -or $State.ButtonState -lt 0 -or ($State.ButtonState -band 4) -eq 0 -or ($State.ButtonState -band 8) -ne 0) {
        throw 'The native toolbar does not contain an enabled, visible instance of the recorded command. No command was sent.'
    }
}

function Get-TubeOutputDirectory {
    param($Job,[int]$PartIndex=0,[string]$SelectedFile='')
    if ($null -eq $Job -or $PartIndex -lt 0 -or $PartIndex -ge $Job.Parts.Count) { throw 'Prepare a job and select a part first.' }
    $prefix=[IO.Path]::GetFullPath($Job.Directory)+[IO.Path]::DirectorySeparatorChar
    # When pairing a PDF with an already chosen TPC, start beside that TPC.
    if ($SelectedFile -and (Test-Path -LiteralPath $SelectedFile -PathType Leaf) -and
        [IO.Path]::GetFullPath($SelectedFile).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
        return (Split-Path -Parent $SelectedFile)
    }
    $part=$Job.Parts[$PartIndex]
    $inputPath=if ($part.TeoxPath) { $part.TeoxPath } else { $part.WorkingCopy }
    if (-not [IO.Path]::GetFullPath($inputPath).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Part input is outside this helper job folder.' }
    $directory=Split-Path -Parent $inputPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'The part input folder no longer exists.' }
    return $directory
}

function New-TubeJob {
    param([string]$Name, [string]$ParentDirectory, [object[]]$Parts, [decimal]$StockLengthInches)
    $null = Test-JobName $Name
    if ($Parts.Count -eq 0 -or $Parts.Count -gt 50) { throw 'Choose between 1 and 50 parts.' }
    if ($StockLengthInches -le 0 -or $StockLengthInches -gt 10000) { throw 'Enter a positive stock length in inches.' }
    $names = @{}
    foreach ($part in $Parts) {
        $source = Get-Item -LiteralPath $part.SourcePath
        if ($source.PSIsContainer -or $source.Extension -notmatch '^(?i:\.stp|\.step|\.sldprt)$') { throw 'Choose STEP or SLDPRT part files.' }
        $wholeQuantity = 0
        if (-not [int]::TryParse([string]$part.Quantity,[ref]$wholeQuantity) -or $wholeQuantity -lt 1 -or $wholeQuantity -gt 1000000) { throw 'Quantities must be whole numbers from 1 to 1,000,000.' }
        $null = Test-JobName $part.PartName
        if ($names.ContainsKey($part.PartName)) { throw 'Part names must be unique within the job.' }
        $names[$part.PartName] = $true
        # Keep filenames and TRUMPF part names aligned in this first release.
        if ($part.PartName -cne $source.BaseName) { throw 'For this version, the TRUMPF part name must match the source filename without its extension.' }
    }
    $runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $directory = Join-Path $ParentDirectory ($Name + ' - ' + $runId)
    $null = New-Item -ItemType Directory -Path $directory
    foreach ($child in @('originals','work','deliverables','diagnostics')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $directory $child)
    }
    $staged = New-Object 'System.Collections.Generic.List[object]'
    $index = 0
    foreach ($part in $Parts) {
        $index++
        $source = Get-Item -LiteralPath $part.SourcePath
        $partFolder = Join-Path (Join-Path $directory 'work') ([string]$index)
        $null = New-Item -ItemType Directory -Path $partFolder
        $originalFolder = Join-Path (Join-Path $directory 'originals') ([string]$index)
        $null = New-Item -ItemType Directory -Path $originalFolder
        $originalCopy = Join-Path $originalFolder $source.Name
        $workingCopy = Join-Path $partFolder $source.Name
        $beforeHash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
        Copy-Item -LiteralPath $source.FullName -Destination $originalCopy
        Copy-Item -LiteralPath $source.FullName -Destination $workingCopy
        if ((Get-FileHash -LiteralPath $originalCopy).Hash -ne $beforeHash -or
            (Get-FileHash -LiteralPath $workingCopy).Hash -ne $beforeHash) { throw 'CAD file changed during staging. Stop and create a fresh job.' }
        $staged.Add([pscustomobject]@{
            PartName=$part.PartName; Quantity=[int]$part.Quantity; SourcePath=$source.FullName
            OriginalCopy=$originalCopy; WorkingCopy=$workingCopy; SourceSHA256=$beforeHash
            MaterialAndProfileReviewed=$false; MarkingReviewed=$false; TeoxPath=$null
        })
    }
    $job = [pscustomobject]@{
        SchemaVersion=1; Name=$Name; Directory=$directory; CreatedUtc=[DateTime]::UtcNow.ToString('o')
        Machine='T12'; MachineDisplayName='TruLaser Tube 7000 (T12)'
        StockLengthInches=$StockLengthInches; Parts=$staged.ToArray()
        State='Prepared'; PackageReport=$null
    }
    Save-TubeJob $job
    return $job
}

function Save-TubeJob {
    param($Job)
    $destination = Join-Path $Job.Directory 'job.json'
    $temp = $destination + '.tmp'
    $Job | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $destination -Force
}

function Open-TubeJob {
    param([Parameter(Mandatory)][string]$ManifestPath)
    $manifest = Get-Item -LiteralPath $ManifestPath
    if ($manifest.Length -gt 1048576 -or $manifest.Name -ine 'job.json') { throw 'Choose a helper job.json manifest under 1 MiB.' }
    $job = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
    $actualDirectory = [IO.Path]::GetFullPath($manifest.DirectoryName)
    if ($job.SchemaVersion -ne 1 -or $job.Machine -cne 'T12' -or
        [IO.Path]::GetFullPath($job.Directory) -ine $actualDirectory) { throw 'Unsupported or relocated job manifest. Keep the complete job folder in its original location.' }
    $null = Test-JobName $job.Name
    if (@($job.Parts).Count -eq 0 -or @($job.Parts).Count -gt 50) { throw 'Invalid part count in manifest.' }
    $prefix = $actualDirectory + [IO.Path]::DirectorySeparatorChar
    $seen = @{}
    foreach ($part in $job.Parts) {
        $null = Test-JobName $part.PartName
        $wholeQuantity = 0
        if (-not [int]::TryParse([string]$part.Quantity,[ref]$wholeQuantity) -or $wholeQuantity -lt 1 -or $wholeQuantity -gt 1000000 -or $seen.ContainsKey($part.PartName)) { throw 'Invalid quantity or duplicate part in manifest.' }
        $seen[$part.PartName] = $true
        foreach ($path in @($part.WorkingCopy,$part.OriginalCopy)) {
            if (-not [IO.Path]::GetFullPath($path).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'A staged CAD path is missing or outside this job folder.' }
        }
        if ((Get-FileHash -LiteralPath $part.OriginalCopy -Algorithm SHA256).Hash -cne $part.SourceSHA256) { throw 'The retained original CAD copy no longer matches its recorded hash.' }
        if ($part.TeoxPath -and (-not [IO.Path]::GetFullPath($part.TeoxPath).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $part.TeoxPath -PathType Leaf))) { throw 'A registered TEOX is missing or outside this job folder.' }
    }
    return $job
}

function Test-TubePackage {
    param($Job, [string]$TpcPath, [string]$PdfPath, [switch]$PdfReviewed)
    $tpc = Get-Item -LiteralPath $TpcPath
    $pdf = Get-Item -LiteralPath $PdfPath
    $initialTpcHash = (Get-FileHash -LiteralPath $tpc.FullName -Algorithm SHA256).Hash
    $initialPdfHash = (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash
    if ($tpc.Extension -ine '.tpc' -or $pdf.Extension -ine '.pdf') { throw 'Select a TPC and a PDF.' }
    if ($tpc.BaseName -ine $Job.Name -or $pdf.BaseName -ine $Job.Name) { throw 'Both final filenames must match the job name.' }
    if ($pdf.Length -lt 8 -or $pdf.Length -gt 134217728) { throw 'PDF size is invalid or exceeds inspection limits.' }
    $stream = [IO.File]::OpenRead($pdf.FullName)
    try {
        $header = New-Object byte[] 5
        $null = $stream.Read($header,0,5)
        if ([Text.Encoding]::ASCII.GetString($header) -ne '%PDF-') { throw 'Selected PDF has no PDF file signature.' }
    } finally { $stream.Dispose() }
    $summary = Get-TpcSummary $tpc.FullName
    if ($summary.Machines.Count -ne 1 -or $summary.Machines[0] -cne $Job.Machine) { throw 'TPC target machine does not match T12.' }
    if ($summary.Parts.Count -ne $Job.Parts.Count) { throw 'TPC part count does not match the job.' }
    foreach ($expected in $Job.Parts) {
        $actual = @($summary.Parts | Where-Object { $_.PartName -ieq $expected.PartName })
        if ($actual.Count -ne 1 -or $actual[0].Quantity -ne $expected.Quantity -or $actual[0].JobName -ine $Job.Name) {
            throw "TPC job/quantity/part mismatch for $($expected.PartName)."
        }
    }
    $finalTpcHash = (Get-FileHash -LiteralPath $tpc.FullName -Algorithm SHA256).Hash
    $finalPdfHash = (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash
    if ($initialTpcHash -ne $finalTpcHash -or $initialPdfHash -ne $finalPdfHash) { throw 'Output changed during inspection. Wait for TRUMPF export to finish and retry.' }
    [pscustomobject]@{
        CheckedUtc=[DateTime]::UtcNow.ToString('o'); JobName=$Job.Name
        MetadataChecks='Passed'; TpcSummary=$summary
        PdfCheck='PDF signature and filename checked; contents require operator review'
        PdfReviewed=[bool]$PdfReviewed
        TpcSHA256=$finalTpcHash
        PdfSHA256=$finalPdfHash
        MachineReady=$false
        Limitations=@('No collision simulation or machine test performed by this helper.',
            'Stock allocation, marking, and PDF contents require TRUMPF/operator review.',
            'Archive readability is not an independent ZIP CRC validation.')
    }
}

function Copy-CheckedPackage {
    param($Job, [string]$TpcPath, [string]$PdfPath, $Report)
    if ($Report.MetadataChecks -ne 'Passed' -or -not $Report.PdfReviewed) { throw 'Complete package checks and PDF review first.' }
    $destination = Join-Path $Job.Directory ('.pending-package-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $destination
    foreach ($item in @(@{Path=$TpcPath; Hash=$Report.TpcSHA256}, @{Path=$PdfPath; Hash=$Report.PdfSHA256})) {
        $target = Join-Path $destination ([IO.Path]::GetFileName($item.Path))
        Copy-Item -LiteralPath $item.Path -Destination $target
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $item.Hash) {
            throw 'Package changed after validation. Do not use this copy; recheck the outputs.'
        }
    }
    $Report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $destination 'checks.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $destination 'REVIEW.txt') -Encoding UTF8 -Value @'
These files passed job metadata checks and were acknowledged by the operator.
This helper has NOT simulated the NC program or certified it for machine operation.
Complete your usual TRUMPF simulation and operator release before production.
'@
    $completed = Join-Path $Job.Directory ('deliverables/package-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    Move-Item -LiteralPath $destination -Destination $completed
    return $completed
}

Export-ModuleMember -Function ConvertFrom-TrumpfCsv,Read-TrumpfTable,Get-TpcSummary,Test-JobName,Get-TubeDesignShortcutCandidates,Assert-TubeToolbarState,Get-TubeOutputDirectory,New-TubeJob,Save-TubeJob,Open-TubeJob,Test-TubePackage,Copy-CheckedPackage
