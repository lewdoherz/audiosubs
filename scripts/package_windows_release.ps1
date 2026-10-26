<#
.SYNOPSIS
Packages the existing Windows Release bundle; does not build the application.
.DESCRIPTION
Requires Windows PowerShell 5.1+ and the open-source NSIS 3.x distribution.
The ZIP and installer use exactly the same staged payload, including licenses,
package metadata, the private Python runtime, and README.md. Downloaded speech /
translation models, imported media, player state and test fixtures are rejected.
The worker's built-in VAD asset and tokenizer normalization tables are runtime
assets, not downloaded speech models, and must remain in the bundle.
ZIP entry ordering and timestamps are fixed for repeatable packaging of the same
input. Installer reproducibility also depends on using the same NSIS distribution.
Neither output is signed: no signing certificate is required or assumed.
.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts/package_windows_release.ps1 -NsisCompilerPath 'C:\tools\nsis\makensis.exe'
.NOTES
Silent install: setup.exe /S /D=C:\Users\name\AppData\Local\Programs\AudioSubs
/D must be the last argument; NSIS does not require quotes around its value.
Silent uninstall: & "$env:LOCALAPPDATA\Programs\AudioSubs\uninstall.exe" /S
The install directory can be changed for isolated per-user smoke tests. Neither
upgrades nor uninstall recursively delete it, or touch application support data.
#>
[CmdletBinding()]
param([string]$NsisCompilerPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = Split-Path -Parent $PSScriptRoot
$Bundle = Join-Path $Root 'build\windows\x64\runner\Release'
$Readme = Join-Path $Root 'README.md'
$InstallerScript = Join-Path $PSScriptRoot 'windows_installer.nsi'
$VersionMatch = [regex]::Match(
    (Get-Content -LiteralPath (Join-Path $Root 'pubspec.yaml') -Raw),
    '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*(?:#.*)?$'
)
if (-not $VersionMatch.Success) { throw 'pubspec.yaml must contain version: major.minor.patch+build.' }
$Version = '{0}.{1}.{2}' -f $VersionMatch.Groups[1].Value, $VersionMatch.Groups[2].Value, $VersionMatch.Groups[3].Value
$FileVersion = '{0}.{1}' -f $Version, $VersionMatch.Groups[4].Value
foreach ($Group in 1..4) {
    if ([uint64]$VersionMatch.Groups[$Group].Value -gt 65535) { throw 'Windows version components must be at most 65535.' }
}

if ([string]::IsNullOrWhiteSpace($NsisCompilerPath)) {
    $CompilerCommand = Get-Command makensis.exe -ErrorAction SilentlyContinue
    if ($CompilerCommand) { $NsisCompilerPath = $CompilerCommand.Source }
}
if ([string]::IsNullOrWhiteSpace($NsisCompilerPath) -or -not (Test-Path -LiteralPath $NsisCompilerPath -PathType Leaf)) {
    throw 'Install the open-source NSIS 3.x distribution and pass -NsisCompilerPath pointing to makensis.exe (or add it to PATH).'
}
$NsisCompilerPath = (Resolve-Path -LiteralPath $NsisCompilerPath).Path
foreach ($RelativePath in @(
    'AudioSubs.exe', 'flutter_windows.dll', 'data\app.so', 'data\icudtl.dat',
    'transcription_runtime\audiosubs_worker.exe',
    'transcription_runtime\_internal\base_library.zip',
    'transcription_runtime\_internal\av\_lgpl_provenance.json',
    'transcription_runtime\_internal\THIRD-PARTY-LICENSES\manifest.json',
    'transcription_runtime\_internal\THIRD-PARTY-LICENSES\WINDOWS-TERMS.txt'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $Bundle $RelativePath) -PathType Leaf)) {
        throw "Incomplete Windows Release bundle: missing $RelativePath. Run scripts/build_windows.ps1 first."
    }
}
$NoticeManifest = Get-Content -LiteralPath (Join-Path $Bundle 'transcription_runtime\_internal\THIRD-PARTY-LICENSES\manifest.json') -Raw | ConvertFrom-Json
if ($NoticeManifest.application.version -ne $Version -or
    -not ($NoticeManifest.components | Where-Object { $_.name -eq 'PDFium-native' })) {
    throw 'Release notices are stale or omit native PDFium. Rebuild the managed runtime and regenerate notices for this version before packaging.'
}
$FlutterAssets = Join-Path $Bundle 'data\flutter_assets'
if (-not (Test-Path -LiteralPath $FlutterAssets -PathType Container) -or
    -not (Get-ChildItem -LiteralPath $FlutterAssets -File -Recurse -Force | Select-Object -First 1)) {
    throw 'Incomplete Windows Release bundle: Flutter assets are missing or empty.'
}
$WorkerInternal = Join-Path $Bundle 'transcription_runtime\_internal'
if (-not (Get-ChildItem -LiteralPath $WorkerInternal -Filter 'python3*.dll' -File)) {
    throw 'The worker bundle has no embedded Python runtime; a system Python dependency is not permitted.'
}
foreach ($RequiredFile in @($Readme, $InstallerScript)) {
    if (-not (Test-Path -LiteralPath $RequiredFile -PathType Leaf)) { throw "Missing packaging input: $RequiredFile" }
}
$WorkerPython = Join-Path $Root 'worker\.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $WorkerPython -PathType Leaf)) {
    throw 'The managed build environment is required to verify the actual packaged LGPL DLLs.'
}
& $WorkerPython (Join-Path $PSScriptRoot 'lgpl_pyav.py') verify --bundle (Join-Path $Bundle 'transcription_runtime')
if ($LASTEXITCODE -ne 0) { throw 'Refusing to publish unverified or GPL/nonfree Windows media libraries.' }

# Inspect before staging: never silently publish build fixtures or a user's data.
$BundleItems = @(Get-ChildItem -LiteralPath $Bundle -Recurse -Force)
foreach ($Item in $BundleItems) {
    $RelativePath = $Item.FullName.Substring($Bundle.Length + 1).Replace('\', '/')
    $IsNotice = $RelativePath.StartsWith('transcription_runtime/_internal/THIRD-PARTY-LICENSES/', [StringComparison]::OrdinalIgnoreCase)
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Release bundle must not contain junctions or symlinks: $RelativePath"
    }
    if ($Item.PSIsContainer) {
        if ($RelativePath -notmatch '/' -and $RelativePath -notin @('data', 'transcription_runtime')) {
            throw "Unexpected top-level payload directory (possible user data): $RelativePath"
        }
        # Source licence texts retain upstream names such as tests/COPYING.
        if (-not $IsNotice -and $RelativePath -match '(?i)(^|/)(fixtures|test[_-]fixtures|smoke[_-]fixtures|tests|\.venv|\.git|__pycache__|downloads|imported_audio|\.cache)(/|$)') {
            throw "Non-release content in bundle: $RelativePath"
        }
        if (-not $IsNotice -and $Item.Name -ieq 'models' -and $RelativePath -notin @(
            'transcription_runtime/_internal/tokenizers/models',
            'transcription_runtime/_internal/ctranslate2/models'
        )) { throw "Downloaded model directory in bundle: $RelativePath" }
    } else {
        # Sacremoses uses ISO suffixes (including .pt) for tokenizer text data,
        # not Torch checkpoints. Keep those package assets; reject model files.
        if ($Item.Name -ieq 'player_state.json' -or
            $Item.Extension -match '(?i)^\.(mp3|m4a|m4b|wav|flac|ogg|aac|srt|argospkg|safetensors|gguf)$' -or
            ($Item.Extension -match '(?i)^\.(pt|pth)$' -and
             $RelativePath -notmatch '^transcription_runtime/_internal/sacremoses/data/(nonbreaking_prefixes|perluniprops)/') -or
            $Item.Name -match '(?i)^(ggml.*\.bin|model\.bin|pytorch_model\.bin)$' -or
            ($Item.Extension -ieq '.onnx' -and $RelativePath -ne 'transcription_runtime/_internal/faster_whisper/assets/silero_vad_v6.onnx')) {
            throw "User media, downloaded model or fixture in bundle: $RelativePath"
        }
    }
}

$OutputDirectory = Join-Path $Root "dist\$Version"
$StageRoot = Join-Path $OutputDirectory 'windows-portable'
$Payload = Join-Path $StageRoot 'AudioSubs'
$ZipPath = Join-Path $OutputDirectory "AudioSubs-$Version-windows-x64-portable.zip"
$SetupPath = Join-Path $OutputDirectory "AudioSubs-$Version-windows-x64-setup.exe"
$PayloadInclude = Join-Path $OutputDirectory 'windows-payload.nsh'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
if (Test-Path -LiteralPath $StageRoot) { Remove-Item -LiteralPath $StageRoot -Recurse -Force }
New-Item -ItemType Directory -Path $Payload -Force | Out-Null
Get-ChildItem -LiteralPath $Bundle -Force | Copy-Item -Destination $Payload -Recurse -Force
Copy-Item -LiteralPath $Readme -Destination (Join-Path $Payload 'README.md') -Force

# The DLL search path for Flutter starts beside AudioSubs.exe, not in _internal.
foreach ($Dll in @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'msvcp140_1.dll')) {
    $CrtSource = Join-Path $WorkerInternal $Dll
    if (Test-Path -LiteralPath $CrtSource -PathType Leaf) {
        Copy-Item -LiteralPath $CrtSource -Destination (Join-Path $Payload $Dll) -Force
    } elseif ($Dll -in @('vcruntime140.dll', 'msvcp140.dll')) {
        throw "Required app-local CRT is missing from the bundled worker: $Dll"
    } else {
        Write-Warning "Optional app-local CRT DLL unavailable in worker bundle: $Dll"
    }
}

$PayloadFiles = @(Get-ChildItem -LiteralPath $Payload -File -Recurse -Force | Sort-Object FullName)
$PayloadDirectories = @(Get-ChildItem -LiteralPath $Payload -Directory -Recurse -Force | Sort-Object FullName)
$ArchiveTimestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
foreach ($File in $PayloadFiles) { $File.LastWriteTimeUtc = $ArchiveTimestamp.UtcDateTime }

# Generate exact extraction/deletion lists from the same payload used by ZIP.
# No wildcard or recursive deletion is allowed in the generated uninstaller.
function ConvertTo-NsisLiteral([string]$Value) {
    return $Value.Replace('$', '$$').Replace('"', '$\"')
}
$IncludeLines = [System.Collections.Generic.List[string]]::new()
$IncludeLines.Add('; Generated by package_windows_release.ps1; do not edit.')
$IncludeLines.Add('!macro InstallPayload')
$IncludeLines.Add('  SetOutPath "$INSTDIR"')
foreach ($Directory in $PayloadDirectories) {
    $RelativePath = ConvertTo-NsisLiteral $Directory.FullName.Substring($Payload.Length + 1)
    $IncludeLines.Add('  CreateDirectory "$INSTDIR\' + $RelativePath + '"')
}
$CurrentDirectory = ''
foreach ($File in $PayloadFiles) {
    $RelativePath = ConvertTo-NsisLiteral $File.FullName.Substring($Payload.Length + 1)
    $RelativeDirectory = ConvertTo-NsisLiteral $File.DirectoryName.Substring($Payload.Length)
    if ($RelativeDirectory -ne $CurrentDirectory) {
        $IncludeLines.Add('  SetOutPath "$INSTDIR' + $RelativeDirectory + '"')
        $CurrentDirectory = $RelativeDirectory
    }
    $IncludeLines.Add('  File "${SOURCE_DIR}\' + $RelativePath + '"')
}
$IncludeLines.Add('!macroend')
$IncludeLines.Add('!macro RemovePayload')
foreach ($File in $PayloadFiles) {
    $RelativePath = ConvertTo-NsisLiteral $File.FullName.Substring($Payload.Length + 1)
    $IncludeLines.Add('  Delete "$INSTDIR\' + $RelativePath + '"')
    $IncludeLines.Add('  ${If} ${FileExists} "$INSTDIR\' + $RelativePath + '"')
    $IncludeLines.Add('    MessageBox MB_OK|MB_ICONSTOP "Close AudioSubs before uninstalling. An installation file could not be removed." /SD IDOK')
    $IncludeLines.Add('    SetErrorLevel 1')
    $IncludeLines.Add('    Abort')
    $IncludeLines.Add('  ${EndIf}')
}
foreach ($Directory in ($PayloadDirectories | Sort-Object { $_.FullName.Length } -Descending)) {
    $RelativePath = ConvertTo-NsisLiteral $Directory.FullName.Substring($Payload.Length + 1)
    $IncludeLines.Add('  RMDir "$INSTDIR\' + $RelativePath + '"')
}
$IncludeLines.Add('!macroend')
[System.IO.File]::WriteAllLines($PayloadInclude, $IncludeLines, [System.Text.UTF8Encoding]::new($true))

Add-Type -AssemblyName System.IO.Compression
if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
$ZipStream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::CreateNew)
try {
    $Archive = [System.IO.Compression.ZipArchive]::new($ZipStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        $Entry = $Archive.CreateEntry('AudioSubs/')
        $Entry.LastWriteTime = $ArchiveTimestamp
        foreach ($Directory in $PayloadDirectories) {
            $Name = 'AudioSubs/' + $Directory.FullName.Substring($Payload.Length + 1).Replace('\', '/') + '/'
            $Entry = $Archive.CreateEntry($Name)
            $Entry.LastWriteTime = $ArchiveTimestamp
        }
        foreach ($File in $PayloadFiles) {
            $Name = 'AudioSubs/' + $File.FullName.Substring($Payload.Length + 1).Replace('\', '/')
            $Entry = $Archive.CreateEntry($Name, [System.IO.Compression.CompressionLevel]::Optimal)
            $Entry.LastWriteTime = $ArchiveTimestamp
            $InputStream = $File.OpenRead()
            try {
                $EntryStream = $Entry.Open()
                try { $InputStream.CopyTo($EntryStream) } finally { $EntryStream.Dispose() }
            } finally { $InputStream.Dispose() }
        }
    } finally { $Archive.Dispose() }
} finally { $ZipStream.Dispose() }

if (Test-Path -LiteralPath $SetupPath) { Remove-Item -LiteralPath $SetupPath -Force }
$CompilerArguments = @(
    '/INPUTCHARSET', 'UTF8', '/V3',
    "/DAPP_VERSION=$Version", "/DAPP_FILE_VERSION=$FileVersion",
    "/DSOURCE_DIR=$Payload", "/DOUTPUT_FILE=$SetupPath",
    "/DPAYLOAD_INCLUDE=$PayloadInclude", $InstallerScript
)
& $NsisCompilerPath @CompilerArguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $SetupPath -PathType Leaf)) {
    throw "NSIS packaging failed (exit code $LASTEXITCODE)."
}
Write-Host "Unsigned portable ZIP: $ZipPath"
Write-Host "Unsigned per-user setup: $SetupPath"
Write-Host "Shared application payload: $Payload"
Write-Host 'No downloaded models or user data are included. Models are downloaded explicitly in AudioSubs.'
