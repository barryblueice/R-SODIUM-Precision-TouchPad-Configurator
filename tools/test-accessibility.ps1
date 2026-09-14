param([string]$Flutter = 'flutter')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    $logDirectory = Join-Path $projectRoot 'build\verification'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $logPath = Join-Path $logDirectory 'accessibility-native.log'
    & $Flutter test integration_test/accessibility_test.dart -d windows *> $logPath
    $testExit = $LASTEXITCODE
    Get-Content -LiteralPath $logPath
    if ($testExit -ne 0) { throw "Flutter accessibility test failed: $testExit" }
    # Engine errors are printed by C++; tester.takeException() cannot catch them.
    $errors = Select-String -LiteralPath $logPath -Pattern 'Failed to update ui::AXTree|Nodes left pending|will not be in the tree'
    if ($errors) { throw 'Windows AXTree errors found in native test output.' }
    if (-not (Select-String -LiteralPath $logPath -SimpleMatch 'ACCESSIBILITY_SCENARIO_COMPLETED')) {
        throw 'Accessibility scenario did not complete.'
    }
    Write-Output 'Windows AXTree regression check passed.'
} finally {
    Pop-Location
}
