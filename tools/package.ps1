param([string]$Version = '1.0.3')
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must use major.minor.patch.' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$releasePath = Join-Path $projectRoot 'build\windows\x64\runner\Release'
if (-not (Test-Path -LiteralPath (Join-Path $releasePath 'rsodium_touchpad.exe'))) {
    throw 'Run flutter build windows --release before packaging.'
}
$vswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = & $vswherePath -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw 'Visual Studio C++ tools not found.' }
$redistRoot = Join-Path $vsPath 'VC\Redist\MSVC'
$redistPath = Get-ChildItem -LiteralPath $redistRoot -Directory | Where-Object { $_.Name -match '^\d+\.' } |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName 'x64\Microsoft.VC143.CRT' } |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $redistPath) { throw 'Visual C++ x64 redistributable DLL directory not found.' }
$packageName = "R-SODIUM-TouchPad-$Version-windows-x64"
$stagingPath = Join-Path $projectRoot "build\package\$packageName"
$distPath = Join-Path $projectRoot 'dist'
$archivePath = Join-Path $distPath "$packageName.zip"
if ((Test-Path -LiteralPath $stagingPath) -or (Test-Path -LiteralPath $archivePath)) {
    throw 'Package output already exists; choose a new version or explicitly remove the old artifact first.'
}
New-Item -ItemType Directory -Path $stagingPath, $distPath -Force | Out-Null
Get-ChildItem -LiteralPath $releasePath | Where-Object { $_.Extension -ne '.pdb' } |
    Copy-Item -Destination $stagingPath -Recurse
Get-ChildItem -LiteralPath $redistPath -Filter '*.dll' | Copy-Item -Destination $stagingPath
Copy-Item -LiteralPath (Join-Path $projectRoot 'README.md'), (Join-Path $projectRoot 'LICENSE') -Destination $stagingPath
Copy-Item -LiteralPath (Join-Path $projectRoot 'docs') -Destination $stagingPath -Recurse
Compress-Archive -LiteralPath $stagingPath -DestinationPath $archivePath -CompressionLevel Optimal
Get-FileHash -LiteralPath $archivePath -Algorithm SHA256 | Format-List
Write-Output "Portable directory: $stagingPath"
Write-Output "Archive: $archivePath"
