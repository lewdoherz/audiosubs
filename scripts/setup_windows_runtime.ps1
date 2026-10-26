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

# PyAV 19 requires Python 3.12; the managed runtime is Windows x64 only.
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
            # Modern Python Install Manager can provision the compatible runtime.
            & $Launcher install 3.12
            if ($LASTEXITCODE -ne 0) {
                throw 'Install Windows x64 Python 3.12 from python.org, or run py install 3.12 with Python Install Manager; then rerun setup.'
            }
            & $Launcher @Prefix -c 'import sys'
            if ($LASTEXITCODE -ne 0) { throw 'Python 3.12 provisioning failed.' }
        }
    }
    & $Launcher @Prefix -c "import sys,struct; assert sys.platform == 'win32' and sys.version_info[:2] == (3,12) and struct.calcsize('P') == 8, 'Requires Windows x64 Python 3.12'"
    if ($LASTEXITCODE -ne 0) { throw 'Unsupported Python interpreter.' }
    & $Launcher @Prefix -m venv $Venv
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create the private Python environment.' }
}
& $Python -c "import sys,struct; assert sys.platform == 'win32' and sys.version_info[:2] == (3,12) and struct.calcsize('P') == 8"
if ($LASTEXITCODE -ne 0) { throw 'worker/.venv must use Windows x64 Python 3.12. Remove that environment and rerun setup.' }
& $Python -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw 'pip setup failed.' }
# Install our checksum-pinned, dynamically linked LGPL PyAV before resolving
# faster-whisper. requirements pins its local version so pip cannot replace it
# with the stock GPL FFmpeg wheel on later setup runs.
& (Join-Path $PSScriptRoot 'build_lgpl_pyav.ps1')
# Argos depends on Stanza/Torch, although the cue translator never uses them.
# Installing CPU Torch avoids pulling CUDA development libraries into the venv.
& $Python -m pip install torch --index-url https://download.pytorch.org/whl/cpu
if ($LASTEXITCODE -ne 0) { throw 'CPU Torch dependency installation failed.' }
& $Python -m pip install -r (Join-Path $Worker 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Worker dependency installation failed.' }
& $Python (Join-Path $PSScriptRoot 'lgpl_pyav.py') verify
if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution replaced or altered the LGPL runtime.' }
if (-not $SourceOnly) {
    & (Join-Path $PSScriptRoot 'package_windows_runtime.ps1')
    & $Python (Join-Path $PSScriptRoot 'collect_dependency_notices.py') --release-source-url 'https://github.com/lewdoherz/audiosubs/releases/download/v2.1.0/AudioSubs-2.1.0-ffmpeg-lgpl-source.zip'
    if ($LASTEXITCODE -ne 0) { throw 'Third-party notice/source collection failed; do not distribute this runtime.' }
}
Write-Host 'Managed runtime ready. Models are downloaded explicitly from the AudioSubs UI, not by setup.'
