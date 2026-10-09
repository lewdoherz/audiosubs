[CmdletBinding()]
param([string]$PythonPath)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'setup_windows_runtime.ps1') -PythonPath $PythonPath
Push-Location $Root
try {
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
    & flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows build failed.' }
} finally {
    Pop-Location
}
Write-Host 'Distribute the entire build/windows/x64/runner/Release directory, including transcription_runtime; do not ship only the exe.'
