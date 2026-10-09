[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Worker = Join-Path $Root 'worker'
$Python = Join-Path $Worker '.venv\Scripts\python.exe'
if (-not (Test-Path $Python)) { throw 'Run scripts/setup_windows_runtime.ps1 first.' }
$Arguments = @(
    '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--console',
    '--name', 'audiosubs_worker',
    '--distpath', (Join-Path $Worker 'runtime'),
    '--workpath', (Join-Path $Worker 'build'),
    '--specpath', $Worker,
    '--collect-all', 'faster_whisper',
    '--collect-all', 'ctranslate2',
    '--collect-all', 'av',
    '--collect-all', 'tokenizers',
    '--collect-all', 'sentencepiece',
    '--collect-all', 'sacremoses',
    '--collect-data', 'argostranslate',
    '--hidden-import', 'argostranslate.package',
    '--hidden-import', 'argostranslate.apply_bpe',
    '--exclude-module', 'PyQt6', '--exclude-module', 'torch',
    '--exclude-module', 'stanza', '--exclude-module', 'spacy',
    '--exclude-module', 'minisbd',
    (Join-Path $Worker 'audiosubs_worker.py')
)
& $Python @Arguments
if ($LASTEXITCODE -ne 0) { throw 'Headless runtime packaging failed.' }
$Executable = Join-Path $Worker 'runtime\audiosubs_worker\audiosubs_worker.exe'
if (-not (Test-Path $Executable)) { throw 'PyInstaller did not produce the expected executable.' }
Write-Host "Portable helper: $Executable"
Write-Host 'Flutter CMake installs the complete onedir bundle as transcription_runtime next to AudioSubs.exe.'
