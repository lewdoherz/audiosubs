[CmdletBinding()]
param(
    [string]$PythonPath,
    [switch]$SourceOnly
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Worker = Join-Path $Root 'worker'
$Venv = Join-Path $Worker '.venv'
$Python = Join-Path $Venv 'Scripts\python.exe'

# Only Python 3.11/3.12 x64 has the supported Windows wheel set.
if (-not (Test-Path $Python)) {
    if ($PythonPath) {
        $Launcher = $PythonPath
        $Prefix = @()
    } else {
        if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
            throw 'Install Windows x64 Python 3.12 from python.org with the py launcher, or supply -PythonPath C:\path\python.exe.'
        }
        $Launcher = 'py'
        $Prefix = @('-3.12')
        & $Launcher @Prefix -c 'import sys' 2>$null
        if ($LASTEXITCODE -ne 0) {
            $Prefix = @('-3.11')
            & $Launcher @Prefix -c 'import sys' 2>$null
            if ($LASTEXITCODE -ne 0) {
                # Modern Python Install Manager can provision the compatible
                # runtime even when the workstation only has Python 3.14.
                & $Launcher install 3.12
                if ($LASTEXITCODE -ne 0) {
                    throw 'Install Windows x64 Python 3.12 from python.org, or run py install 3.12 with Python Install Manager; then rerun setup.'
                }
                $Prefix = @('-3.12')
                & $Launcher @Prefix -c 'import sys'
                if ($LASTEXITCODE -ne 0) { throw 'Python 3.12 provisioning failed.' }
            }
        }
    }
    & $Launcher @Prefix -c "import sys,struct; assert sys.platform == 'win32' and sys.version_info[:2] in [(3,11),(3,12)] and struct.calcsize('P') == 8, 'Requires Windows x64 Python 3.11/3.12'"
    if ($LASTEXITCODE -ne 0) { throw 'Unsupported Python interpreter.' }
    & $Launcher @Prefix -m venv $Venv
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create the private Python environment.' }
}
& $Python -c "import sys,struct; assert sys.platform == 'win32' and sys.version_info[:2] in [(3,11),(3,12)] and struct.calcsize('P') == 8"
if ($LASTEXITCODE -ne 0) { throw 'worker/.venv must use Windows x64 Python 3.11/3.12. Remove that environment and rerun setup.' }
& $Python -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw 'pip setup failed.' }
# Argos depends on Stanza/Torch, although the cue translator never uses them.
# Installing CPU Torch avoids pulling CUDA development libraries into the venv.
& $Python -m pip install torch --index-url https://download.pytorch.org/whl/cpu
if ($LASTEXITCODE -ne 0) { throw 'CPU Torch dependency installation failed.' }
& $Python -m pip install -r (Join-Path $Worker 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Worker dependency installation failed.' }
if (-not $SourceOnly) {
    & (Join-Path $PSScriptRoot 'package_windows_runtime.ps1')
}
Write-Host 'Managed runtime ready. Models are downloaded explicitly from the AudioSubs UI, not by setup.'
