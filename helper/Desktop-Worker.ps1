param(
    [ValidateSet('Import','Identify','Capture')][string]$Action,
    [string]$InputPath,
    [Parameter(Mandatory)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'TubeJob.Desktop.psm1') -Force
    $message = switch ($Action) {
        'Import' { Invoke-TubeImport $InputPath }
        'Identify' { Invoke-TubeIdentify $InputPath }
        'Capture' { Save-TubeControls ($ResultPath + '.controls.txt') }
    }
    @{Success=$true; Message=[string]$message} | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
} catch {
    @{Success=$false; Message=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    exit 1
}
