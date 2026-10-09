[CmdletBinding()]
param([switch]$Rebuild)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Python = Join-Path $Root 'worker\.venv\Scripts\python.exe'
if (-not (Test-Path $Python)) { throw 'Create worker/.venv with Windows x64 Python 3.12 using setup_windows_runtime.ps1 first.' }
$Helper = Join-Path $PSScriptRoot 'lgpl_pyav.py'
if (-not $Rebuild) {
    & $Python $Helper reuse
    if ($LASTEXITCODE -eq 0) { return }
    if ($LASTEXITCODE -ne 2) { throw 'Existing LGPL build failed provenance verification; use -Rebuild to reconstruct it.' }
}
# Discover installations through the Visual Studio Installer/registry, never a
# guessed VS year or toolset directory. vcvars supplies cl, lib and dumpbin.
$Vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$Install = $null
if (Test-Path $Vswhere) {
    $Install = & $Vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0) { throw 'Visual Studio discovery failed.' }
}
if (-not $Install) {
    foreach ($Key in @('HKLM:\SOFTWARE\Microsoft\VisualStudio\SxS\VS7', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\SxS\VS7')) {
        if (Test-Path $Key) {
            $Properties = (Get-ItemProperty $Key).PSObject.Properties | Where-Object { $_.Name -match '^\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending
            foreach ($Property in $Properties) {
                if (Test-Path (Join-Path $Property.Value 'VC\Auxiliary\Build\vcvars64.bat')) { $Install = $Property.Value; break }
            }
        }
        if ($Install) { break }
    }
}
if (-not $Install) { throw 'Install Visual Studio Build Tools with Desktop development with C++ (MSVC x64 and Windows SDK), then rerun setup.' }
$Vcvars = Join-Path ([string]$Install).Trim() 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $Vcvars)) { throw "Visual Studio C++ activation script is absent: $Vcvars" }
# Import cmd's environment, rather than interpolate Python arguments into a
# cmd command line. Quoted vcvars handles spaces in its installation directory.
$Activation = 'call "' + $Vcvars + '" >nul && set'
$Environment = & $env:ComSpec /d /s /c $Activation
if ($LASTEXITCODE -ne 0) { throw 'Visual Studio x64 environment activation failed.' }
foreach ($Line in $Environment) {
    if ($Line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
}
$env:DISTUTILS_USE_SDK = '1'
$env:MSSdk = '1'
& $Python $Helper build
if ($LASTEXITCODE -ne 0) { throw 'LGPL PyAV construction failed. No release may use an unverified FFmpeg runtime.' }
Write-Host 'LGPL PyAV installed; exact provenance: worker/build/lgpl/provenance.json'
