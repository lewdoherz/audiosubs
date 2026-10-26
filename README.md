# AudioSubs

A single Flutter application for Windows and Android: import audiobooks, play audio immediately, read synchronized subtitles, generate missing subtitles locally, and proofread SRT text against an ebook from the same UI. The original Player and Transcriber projects are reference implementations only; neither is required at runtime.

## Install the preview release

[AudioSubs v2.1.0 downloads](https://github.com/lewdoherz/audiosubs/releases/tag/v2.1.0):

- **Windows installer:** `AudioSubs-2.1.0-windows-x64-setup.exe`. Installs for the current user under `%LOCALAPPDATA%\Programs\AudioSubs`, adds Start menu shortcuts, and optionally adds a desktop shortcut. Close AudioSubs before upgrading or uninstalling.
- **Windows portable ZIP:** `AudioSubs-2.1.0-windows-x64-portable.zip`. Extract the whole archive and run `AudioSubs\AudioSubs.exe`; moving the exe alone will not work. This is a **no-install application bundle**, not portable user data: library/settings/models still use the Windows application support directory.
- **Android APK:** `AudioSubs-2.1.0-android-arm64-x86_64.apk`. Requires Android 7/API 24 or later and a 64-bit ARM or x86 device. Download and open the APK, granting installation permission to your chosen browser/file manager when Android asks.
- **Integrity:** compare downloaded files against `SHA256SUMS.txt` with `Get-FileHash -Algorithm SHA256` on Windows. The release also contains dependency notices and corresponding source for its LGPL media libraries.

The Windows binaries are **unsigned** and can trigger SmartScreen warnings. The Android APK is **debug-key signed**, not production/store signed; an existing installation with a different signing key cannot be upgraded in place. Do not uninstall an existing Android player until you have exported its state and saved any app-private audio/subtitles you need. This preview was exercised on Windows and an Android x86_64 emulator, not a physical ARM64 phone.

Python, the internal transcription worker and native libraries are included in both Windows downloads. Models are **not included**: download them explicitly from the transcription page, then generate subtitles offline. Windows uninstall removes application payload files, not your library/settings/models or imported media; Android uninstall/clear-data removes app-private data.

Windows asks for acceptance of the bundled **Intel/Microsoft component terms** before first use, and again if their text changes. Full vendor terms and notices are included in the package. These terms do not turn AudioSubs into a GPL application or prohibit replacing/relinking its LGPL FFmpeg libraries. CUDA/cuDNN are not redistributed; Windows GPU use requires your own compatible NVIDIA installation.

## Library and playback

- Import one file, several files, or a folder. Numbered siblings and natural sorting, covers, rename/remove, chapter navigation, resume positions, settings, speed, seeking, and auto-advance are retained from the player.
- Audio does not require transcription before playback. Matching existing SRT files load automatically.
- Select primary and secondary subtitles independently using the two subtitle buttons. Choices include discovered original/translated/bilingual outputs, **None**, and a manual file picker. Selections persist per audio file.
- Generated outputs refresh the current player and available tracks without restarting the app or restarting audio.
- Reading themes, fonts, colours, subtitle size and neighbouring context lines are retained.
- Removing a library entry does not delete source audio or completed subtitles. App-owned imported copies are also retained.

### Controls

| Windows key | Action |
| --- | --- |
| Space / media Play-Pause | Play/pause |
| Left / Right | Seek 15 seconds |
| Shift + Left / Right | Seek 60 seconds |
| Up / Down | Change speed by 0.1 |
| Comma / Period / media Previous-Next | Previous/next chapter |

Android retains tap-to-pause, double-tap left/right to seek, horizontal drag seeking, and the player's reading gestures and touch controls.

## Check subtitles against an ebook

Included in the v2.1.0 preview.

1. Press **Check SRT against ebook** (the checklist icon) in the library or player. From the player, the selected primary SRT is offered first; **Open SRT** can choose another file.
2. Use **Open ebook** to select a local reference in the same language and preferably the same edition as the narration. No speech model, cloud service or download is required for proofreading.
3. Review each timed cue against its aligned ebook passage. Matching works on word sequences, so a cue can contain a sentence fragment rather than a complete sentence. **Word differences** highlights spelling, capitalization and punctuation changes; switch it off for a plain passage view. **Differences only**, previous/next, and the cue slider help navigation.
4. Press **Use ebook wording** for one suggestion, edit the text/line breaks manually, or choose **Auto-correct all matched cues** to apply every reliable difference together. The confirmation shows how many cues will change and how many remain unmatched/ambiguous. Existing per-cue edits are protected unless you explicitly check **Replace already edited cues too**. Bulk correction still requires **Save corrected copy**; ambiguous and unmatched cues are never filled automatically. Translation, cue merging/splitting, timing regeneration, OCR and general-purpose dictionary spellchecking are not implemented.
5. Press **Save corrected copy**. Cue numbers, order and timestamp lines are preserved exactly; the original SRT and ebook are never modified. Invalid SRT blocks or unsafe/empty replacement text stop saving rather than silently losing captions. Leaving/replacing the SRT with unsaved edits asks before discarding them.

Corrections use numbered names such as `chapter.corrected-1.srt` or `chapter.es.corrected-2.srt`, always in app-owned `subtitles/<hash>/` support storage on both platforms. The complete path is shown after saving. When opened from the player, copies appear as **Corrected** tracks after returning; existing track choices, including **None**, stay selected. For a standalone SRT review, use the player's **Browse SRT…** to open the displayed output path on Windows. Android corrections stay app-private and disappear on uninstall/clear-data; shared-storage export is not implemented.

### Ebook formats and boundaries

| Input | Supported text |
| --- | --- |
| EPUB | DRM-free EPUB reading order from the OPF spine; navigation/nonlinear content excluded |
| MOBI / AZW | Legacy MOBI7 or PalmDOC, uncompressed/PalmDOC compression, UTF-8/Windows-1252; hybrid Kindle files can use their legacy MOBI rendition |
| AZW3 | Only files containing a supported legacy rendition; **KF8-only layout is not supported** |
| PDF | Embedded text in page order; scanned/image-only PDFs need OCR elsewhere first; complex columns may extract in the wrong order |
| FB2 | Main reading bodies, excluding named notes bodies and binary images |
| DOCX | Main document text, paragraphs and tables; not legacy `.doc` |
| TXT / HTML / HTM | UTF-8, Windows-1252, or BOM-marked UTF-16; HTML entities decoded and scripts/styles/navigation removed |

DRM is not removed. KF8-only/AZW3, KFX, HUFF/CDIC-compressed Kindle files and other unsupported encodings must be converted to a DRM-free EPUB/text edition first. Books are limited to 64 MiB input, 128 MiB expanded ZIP content and 32 million text characters; PDF imports are limited to 10,000 pages. Parsing/comparison runs off the UI isolate; PDFium uses its background native worker.

Alignment is deliberately conservative: approximate spelling needs recognizable word anchors; repeated passages may stay ambiguous, and large omissions/edition differences can leave the remaining cues unmatched. Languages without useful word boundaries and canonically different Unicode spellings may require manual review. Match percentages measure text similarity, not proofreading accuracy. Accepted ebook wording replaces the whole cue text, including any existing inline styling; untouched cues retain their formatting.

PDF support adds bundled PDFium native assets. First development builds download those assets through the dependency build hook; installed proofreading itself stays offline. **Open-source licences** on the review page includes the pinned PDFium/native third-party notices (`assets/pdfium-NOTICES.txt`). The release collector checks the native release pin and includes the same notices; refresh them together when upgrading PDFium.


## Transcription workflow

1. Import audio and open a title. Playback is available immediately.
2. Use the player's generate-subtitles button for its track, the book menu for a book, or the library's transcription button for a batch. The job page lets you select individual files.
3. Select a model and source language (`auto`, or a two/three-letter ISO code such as `en`, `de`, or `es`). Start with **tiny** or **base**.
4. For Windows translation, enter the target ISO code. Set an explicit source code when downloading a translation pair; automatic source detection cannot determine which Argos package to download. Android optionally translates speech into **English** using Whisper itself.
5. Press **Download speech / selected translation models**. Downloads require internet. The UI shows download status, estimated model disk/RAM needs, model location, current file, progress, completion, errors, and output locations.
6. Press **Generate missing subtitles**. Transcription and translation run locally after downloads; no audio is uploaded. Windows inference uses local model files and blocks network connections. Android inference uses the checksum-verified local GGML file.
7. Return to the player. Original subtitles appear automatically unless you deliberately selected another primary track or **None**. Choose a translated or bilingual output for either track.

A single job runs at a time. Individual file errors remain visible and do not prevent later files in the batch from running. **Cancel job** preserves completed outputs and removes unfinished job-owned output/download files. Android model construction itself may need to finish before cancellation takes effect. Completed outputs are never overwritten; remove or move an output yourself if you want to regenerate it with different settings.

Tiny models favour speed and storage over accuracy, especially for translation. Larger models need more RAM and processing time; they do not guarantee accurate speech recognition or translation. Proofread generated subtitles.

### Output naming and storage

- Original: `chapter.srt`.
- Translated: `chapter.es.srt`, or `chapter.en.srt` for Android English translation.
- Bilingual: `chapter.en-es.srt` on Windows, or `chapter.original-en.srt` when the source was selected automatically on Android.
- Windows writes beside audio when the directory is writable; otherwise it uses the app's support directory under `subtitles/<hash-of-audio-path>/`.
- Android deliberately writes generated subtitles into that **app-owned** subtitle storage. Shared/emulated storage rejected atomic no-replace publication during verification, even when ordinary file creation worked. Existing readable sibling SRT files are still discovered.
- Original, translated and bilingual outputs are separate safe-write transactions. A translation failure can leave an already completed original intact.
- Temporary output files are not subtitle candidates. Duplicate audio basenames in different directories have separate fallback storage.
- Exact locations appear in job output messages. Android private outputs remain accessible to the player, but are not files in Downloads and are removed if app data is cleared or the app is uninstalled.

Subtitle matching is case-insensitive and respects the whole audio stem: `chapter1.srt` does not match `chapter10.mp3`. Recognized suffixes include ISO language codes and source-target pairs, including `original-en`.

### Backend capabilities and exact differences

| Platform | Local speech backend | Local translation | Timed outputs |
| --- | --- | --- | --- |
| Windows x64 | faster-whisper / CTranslate2, bundled headless worker | Downloaded direct Argos source-to-target packages | Original, translated and bilingual SRT; translation keeps source cue timing |
| Android arm64-v8a / x86_64 | Packaged whisper.cpp v1.8.3 CPU JNI backend | Whisper speech translation into English | Original and English SRT with native segment times; bilingual SRT uses whole 30-second chunk intervals |

The Flutter UI is the only application UI. Windows does **not** launch PyQt or require a separately installed transcriber. Its worker is an internal component distributed with AudioSubs. Android does not run Python or the Windows executable.

Android arbitrary-target translation is not implemented. The smallest integrated alternative provided here is on-device original transcription plus English translation/bilingual output. For other target languages, generate the subtitles in AudioSubs on Windows and import them on Android. Full on-device arbitrary-target parity would require an additional native translation/tokenizer backend and compatible model packaging; that is not included. Windows only supports downloaded **direct** Argos pairs, not automatic pivot-language routing.

Speech is decoded incrementally: Windows processes 60-second audio chunks, Android 30-second chunks. Transcript text is streamed to temporary SRT files rather than accumulated for a whole book. Independent chunk boundaries can affect recognition and segmentation. Android bilingual cues do not claim word-by-word alignment between independently inferred source and English cues.

## Models and hardware

Models are stored in the application support directory under `models`, not inside either reference project. Windows uses CTranslate2 model directories; Android uses GGML `.bin` files. They are **not interchangeable**.

| Model | Windows estimated disk MiB | Android GGML disk MiB | Android estimated model RAM MB |
| --- | ---: | ---: | ---: |
| tiny | 74 | 74 | 273 |
| base | 141 | 141 | 388 |
| small | 465 | 465 | 852 |
| medium | 1459 | Not offered | Not offered |
| large-v3 | 2956 | Not offered | Not offered |

These are estimates, not maximum total process memory. Decoder/runtime memory, operating system memory, downloaded translation packages, import copies and temporary download space are additional. Windows UI RAM estimates range from 512 MB for tiny to 10,240 MB for large-v3; actual usage depends on precision and hardware. Argos package size varies with the language pair.

Windows supports CPU/CUDA/auto device selection and int8/float16/float32 compute choices. CPU + int8 was exercised. CUDA requires compatible NVIDIA hardware plus CTranslate2-compatible CUDA 12 and cuDNN 9 runtime libraries; GPU inference was **not exercised** here. Unsupported combinations produce job errors, not silent fallback to a different requested device.

Android is CPU-only, using the GGML model's F16/F32 representation rather than the Windows compute-type controls. Prefer tiny/base on phones. Small can require substantial memory and cause thermal throttling. Keep AudioSubs in the foreground during transcription: there is no Android foreground service or durable background-job scheduler. Activity/process destruction cancels or interrupts the job; completed outputs remain intact. Model downloads and incomplete jobs are not automatically resumed after termination.

## Formats: verified results and boundaries

The importer recognizes MP3, M4A, M4B, WAV, FLAC, OGG and AAC. The following are **actual runtime smoke results**, not just extension acceptance:

| Format / tested encoding | Windows playback | Windows transcription | Android playback | Android transcription |
| --- | --- | --- | --- | --- |
| MP3 | Passed | Passed | Passed | Passed |
| M4A / AAC in MP4 | Passed | Passed | Passed | Passed |
| M4B / AAC in MP4 | Passed | Passed | Passed | Passed |
| WAV / PCM16 | Passed | Passed | Passed | Passed |
| FLAC | Passed | Passed | Passed | Passed |
| OGG / Vorbis | Unsupported on this Windows decoder | Passed | Passed | Passed |
| AAC / ADTS | Passed | Passed | Passed | Passed |

Windows playback depends on the installed Media Foundation decoders; the tested Windows machine rejected OGG. The app reports playback errors rather than treating a recognized extension as a guarantee. Windows transcription uses PyAV/FFmpeg, which successfully decoded all seven fixture encodings.

Android compressed decoding uses MediaExtractor/MediaCodec and depends on device codecs. Its WAV fallback supports ordinary RIFF PCM8/16/24/32 and float32, but only PCM16 was runtime-tested. Compressed/RF64 WAV, other OGG codecs, DRM/encrypted M4B, uncommon codecs inside M4A/M4B, and every Android hardware decoder variant are not verified. Unlisted extensions are not imported. Chapter navigation is between imported files; embedded MP4 chapter extraction was not added.

## Android file access

Single/multiple file picks do not require granting all-files access first. Android uses a broad document picker because providers may report generic MIME types; AudioSubs validates the supported filename extension before copying. If a content URI cannot be used as a readable filesystem path, the native resolver copies it into persistent app-private storage on a worker thread and preserves the display filename. Picker-cache files are also persisted rather than retaining a transient cache path.

For multiple selection, long-press a file tile, select additional files, then press **Select**. If an ADB-copied fixture is absent from the Downloads provider's index, browse the device's physical storage root and its `Download` folder instead.

Folder imports and numbered-sibling/subtitle discovery need filesystem access. Use the Android library's storage-access control to grant all-files access when required. Without readable siblings, pick subtitles manually or generate app-owned subtitles. Scoped-storage/provider behaviour varies by Android version and document provider; broad storage access also affects store-distribution policy.

## Existing player state

The Android application ID (`com.example.audiobook_player`) and Windows company/product storage identity (`com.example` / `audiobook_player`) are intentionally retained. Where the original installation and signing identity match, `player_state.json` remains readable in the same support directory. AudioSubs writes schema version 2 while preserving legacy library fields, resume positions, covers and settings, and adds per-audio subtitle selections.

Use **Import player state** in the library toolbar to merge an existing `player_state.json` if automatic reuse is unavailable. Invalid or future-schema imports are rejected without replacing the current library. Matching book IDs are not duplicated. State files reference audio/cover paths; they are not a portable copy of the media, and Windows paths do not become valid Android paths by importing JSON.

## Development and builds

### Prerequisites

- Flutter/Dart compatible with `pubspec.yaml`; this workstation used Flutter 3.47.2 and Dart 3.13.2.
- Windows: Visual Studio C++ desktop tools and Windows x64 Python **3.12** for building the private worker. Python 3.14 is not the supported wheel environment. End users of either Windows package do not need Python installed. The runtime build provisions portable MSYS2 tools locally to compile an LGPL-only FFmpeg and PyAV; no WSL or administrator installation is required.
- Android: SDK platform 37, Flutter's configured NDK, CMake 3.22.1, compatible Android Studio JDK/Gradle, Git and accepted SDK licences. First native build fetches the pinned whisper.cpp source. Runtime minimum is API 24; packaged ABIs are arm64-v8a and x86_64, not 32-bit ARM.
- Initial dependency/tool/model downloads need internet. Models are downloaded explicitly in the app, not silently during inference.

From `C:\develop\AudioSubs`:

```powershell
flutter pub get
powershell -ExecutionPolicy Bypass -File scripts/setup_windows_runtime.ps1
flutter run -d windows
```

The setup script creates `worker/.venv`, provisions Python 3.12 with Python Install Manager when available, installs dependencies, and packages the headless helper. If needed, pass `-PythonPath C:\path\to\python.exe`. `-SourceOnly` skips PyInstaller; launching the Windows UI still requires a previously packaged complete runtime and its bundled terms.

Build Windows:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1
```

Run `build\windows\x64\runner\Release\AudioSubs.exe`. Distribute the **entire Release folder**, including DLLs, Flutter assets and `transcription_runtime`; the exe alone is not a working distribution. CMake requires the packaged runtime for release/profile builds.

Package a Windows installer and portable ZIP after building:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/package_windows_release.ps1 -NsisCompilerPath C:\tools\nsis\makensis.exe
```

Use the open-source [NSIS 3.x compiler](https://nsis.sourceforge.io/Download). Both packages share the same staged payload and are written under `dist/<version>/`. Packaging does not download speech models or include imported audio, generated subtitles, test fixtures or player state. Silent installation uses `setup.exe /S /D=C:\path with spaces` (`/D` last and its value unquoted); silent uninstall uses `uninstall.exe /S`.

Build/install Android:

```powershell
flutter build apk --release --target-platform android-arm64,android-x64
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

The current APK is locally installable and **debug-key signed**, following the original project's local-build configuration. It is not a store-ready, production-signed release. Upgrading an existing install requires the same signing key; a different key requires a separate data-migration strategy before uninstalling.

Checks:

```powershell
dart format lib test
flutter analyze
flutter test
worker\.venv\Scripts\python.exe -m unittest discover -s worker -p test_*.py
```

## Ebook proofreading verification (2026-10-26)

- Scoped `dart format` completed; `flutter analyze lib test` reported no issues; all **80 Flutter tests and 11 Windows worker tests passed**, including bulk-correction timing preservation, protected manual edits, opt-in replacement and idempotence.
- Whole-checkout `flutter analyze` also traversed existing packaged licence/source snapshots under `dist/` and `worker/`, producing missing-path/import diagnostics there. Those generated snapshots were not changed; source/test analysis is the clean check above.
- A Windows native debug harness extracted the actual Project Gutenberg *Alice's Adventures in Wonderland* EPUB and legacy MOBI, plus local TXT/HTML/FB2/DOCX/text-PDF fixtures. Each produced the expected spelling/punctuation suggestions and rejected unrelated wording; rendered corrections kept every timestamp and preserved source text. A real KF8/AZW3 file produced the documented conversion error.
- Windows review UI smoke exercised library entry, loading/comparison, word highlighting, applying ebook wording, cue navigation, unmatched abstention, manual multiline editing, two numbered saves and unsaved-edit protection. Output files were read back and compared with the untouched source. UI visual proof used software rendering; final interactions used a temporary native harness with fixture picker responses after the interactive desktop became unavailable. Native EPUB selection was also exercised through the Windows picker. The temporary harness/fixtures were removed.
- Additional native bulk UI smoke verified the confirmation counts, default protection of a manual edit, explicit opt-in replacement, and two saved SRTs: both reliably matched cues were corrected, unmatched/exact cues and every timestamp stayed unchanged. The original SRT remained untouched.
- After removing the harness and smoke outputs, normal-entry `flutter build windows --debug` passed.
- `flutter build apk --debug --target-platform android-arm64,android-x64` passed. APK inspection found PDFium/gate libraries for both requested ABIs and the native notices asset. **No Android device runtime smoke** was available.
- The real Flutter dependency notice collector included native PDFium and Android-only third-party notices. Release-specific builds, packaging and publication evidence is recorded separately below; these feature checks do not certify production signing or Android device behavior.

## Release build verification (v2.1.0)

- Final normal-entry Windows x64 release and Android ARM64/x86_64 release builds passed for `2.1.0+7`. The Windows executable launched with a responsive native window; no agreement, library or model action was performed during that startup check.
- The frozen Windows worker loaded its private Python 3.12, custom LGPL PyAV 19.0.1 and CTranslate2 4.8.2, and reported its expected audio decoders/containers through `--diagnostics`. This does not claim new transcription-quality or GPU verification.
- Android package metadata is `com.example.audiobook_player`, version name `2.1.0`, code `7`, minimum SDK 24, target SDK 36, and only `arm64-v8a`/`x86_64`. Its APK signature verifies and retains the same debug certificate as v2.0.0. Both PDFium native ABIs and all 19 upstream native notice texts are included. No Android device runtime test was available for this release.
- Release notices were regenerated for version 2.1.0 with 152 components, the PDFium-native entry, full FreeType text/acknowledgement, and a matching versioned LGPL corresponding-source archive. Windows packages remain unsigned; Android remains debug-key signed. Release notes and `SHA256SUMS.txt` accompany the downloadable assets.

## Historical v2.0.0 verification

- Formatting and Flutter analysis passed with no issues; 21 Flutter tests passed, including all 9 existing player tests, matching/discovery/fallback/migration/job-lifecycle coverage, and first-use consent/error boundaries.
- 11 worker tests passed, including safe output publication, batch recovery, cancellation, open-stdin completion and separation of native/Python diagnostics from the JSON protocol.
- Final normal-entry Windows release and Android arm64/x86_64 release APK builds passed and both applications launched. Windows reused the existing library without manual migration. Final APK metadata advertises only arm64-v8a and x86_64.
- Windows actual UI: playback before subtitles, integrated model download/transcription, original + Spanish + bilingual output, live subtitle refresh and simultaneous original/Spanish display.
- Packaged Windows runtime: all seven transcription encodings produced 21 original/Spanish/bilingual outputs offline; a missing file did not stop later files. Real native-job cancellation preserved completed output and removed incomplete files. Live stdin remained open throughout batch completion.
- Windows release packaging: installer and extracted portable payload hashes matched all 1,001 staged files. Both applications reached their visible first frame and closed normally with only Windows/system directories on `PATH`; the extracted portable worker produced the same seven-format/21-output offline results without system Python.
- Per-user installation into a path containing spaces, upgrade, HKCU registration/Start menu shortcuts and uninstall passed. A user-added sentinel survived upgrade/uninstall, and the existing schema-2 library remained byte-for-byte unchanged across both distribution launches and the installation lifecycle.
- Actual first-use agreement/acceptance controls persisted the exact terms fingerprint. The native installer's licence page displayed the complete Intel/Microsoft terms and an explicit agreement button.
- Android **API 35 x86_64 emulator**: all seven playback encodings advanced position; all seven transcription encodings produced timed originals offline. German speech produced detected-German originals, separate English speech-translation cues and a bilingual output. Bad-file recovery, cancellation, preservation of existing outputs and removal of partials passed.
- Android actual UI: native model download, progress/errors/output locations, generated-subtitle refresh without restart, generated-track selection and simultaneous two-track display. Standard physical-storage-provider single and multiple URI imports worked with all-files access denied; the resolver preserved filenames under persistent private `files/picked/` storage. The imported library remained readable after process restart.
- ARM64 native code compiled, but **no physical ARM64 Android device** was available for runtime verification. CUDA, sustained full-length-book performance, other document providers, background survival and production signing/store publication were not validated.

The German tiny-model translation produced timed English output but poor wording; verification demonstrates the local pipeline, not translation quality. Remaining platform gaps are the Android translation/timing/background limitations and the Windows OGG playback limitation described above, not a Windows-only transcription substitute for Android.

## Source layout and backend references

- `lib/main.dart`: retained player/library/settings and integrated entry points.
- `lib/subtitle_files.dart`: matching, generated discovery and output storage.
- `lib/transcription/`: shared job controller/UI and platform adapters.
- `lib/proofreading/`: local ebook extraction, cue alignment, review editing and safe corrected-copy publication.
- `worker/`, `scripts/`: managed Windows worker, packaging and build scripts.
- `android/app/src/main/kotlin/` and `android/app/src/main/cpp/`: storage bridge, streaming decoder, native job engine and JNI.
- `test/`, `worker/test_worker.py`: behavioural regressions.

Backend/model licensing and format references:

- [whisper.cpp v1.8.3](https://github.com/ggml-org/whisper.cpp/tree/v1.8.3), MIT; its licence is included in Android assets. [GGML model catalogue and published checksums](https://github.com/ggml-org/whisper.cpp/blob/v1.8.3/models/README.md).
- [OpenAI Whisper licence](https://github.com/openai/whisper/blob/main/LICENSE), MIT code/model weights.
- [faster-whisper](https://github.com/SYSTRAN/faster-whisper), [CTranslate2](https://github.com/OpenNMT/CTranslate2), and [Argos Translate](https://github.com/argosopentech/argos-translate). Review dependency and individual translation-package licences before redistributing models; the Windows bundle also includes PyAV/FFmpeg dependencies.
- Windows uses locally rebuilt **PyAV 19.0.1+audiosubs.lgpl** with **FFmpeg 9.0.2, LGPL 2.1 or later**, dynamically linked. GPL/nonfree, external-library autodetection and FFmpeg network support are disabled. `scripts/build_lgpl_pyav.ps1` records verified source hashes, configuration and DLL provenance; packaging refuses the stock GPL FFmpeg wheel.
- Full component notices are under `transcription_runtime/_internal/THIRD-PARTY-LICENSES`. The release's `AudioSubs-2.1.0-ffmpeg-lgpl-source.zip` includes original FFmpeg/PyAV sources, local changes, configuration and rebuild/relink instructions. ABI-compatible FFmpeg DLLs can be replaced under `transcription_runtime/_internal/av/` while AudioSubs is closed. See [FFmpeg licensing guidance](https://ffmpeg.org/legal.html); these notices are not a legal-compliance certification.
- [Android platform media formats](https://developer.android.com/media/platform/supported-formats) and [Windows Media Foundation formats](https://learn.microsoft.com/en-us/windows/win32/medfound/supported-media-formats-in-media-foundation).

The reference projects remain separate and unchanged. Built applications and downloaded models are excluded from source control.
