param(
    [ValidateSet('Import','Identify','Capture','AutoRunImport','TubeExport','ModelSave')][string]$Action,
    [string]$InputPath,
    [Parameter(Mandatory)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'TubeJob.Core.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TubeJob.Desktop.psm1') -Force
    $outcome = switch ($Action) {
        'Import' { Invoke-TubeImport $InputPath }
        'Identify' { Invoke-TubeIdentify $InputPath }
        'Capture' { Save-TubeControls ($ResultPath + '.controls.txt') -TubeDesignOnly }
        'AutoRunImport' { Invoke-AutoRunImport $InputPath }
        'TubeExport' { Invoke-TubeExport $InputPath }
        'ModelSave' { Invoke-TubeModelSave $InputPath }
    }
    $message=if ($outcome -is [string]) { $outcome } else { $outcome.Message }
    $data=if ($outcome -is [string]) { $null } else { $outcome.Request }
    @{Success=$true; Message=[string]$message;Data=$data} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
} catch {
    @{Success=$false; Message=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    exit 1
}
