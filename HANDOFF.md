# AudioSubs handoff for Tern

## Start here

Continue the existing implementation; do not restart or replace it with a scaffold. Read this file, then `README.md`, then the source relevant to the next requested change. Code and current configuration take precedence if documentation becomes stale.

- Repository: https://github.com/lewdoherz/audiosubs
- Published preview: https://github.com/lewdoherz/audiosubs/releases/tag/v2.1.0
- Source revision: release tag `v2.1.0`; the original v2.0.0 preview was commit `477db2451d7a8bf65429c9f1f529a657ba7db074`.
- App version: `2.1.0+7` in `pubspec.yaml`.
- Original working directory: `C:\develop\AudioSubs`.
- Reference projects: `C:\develop\AudioSubs-Player` and `C:\develop\AudioSubs-Transcriber`. Keep them intact. They are not required at runtime and are not assumed to exist in a fresh Tern workspace.
- The original handoff followed v2.0.0; ebook proofreading and v2.1.0 release preparation were added later. Historical verification below is not a claim about unreviewed later changes.

Open/import the GitHub repository in Tern, or clone it if the workspace is empty:

```sh
git clone https://github.com/lewdoherz/audiosubs.git
```

Run subsequent commands from the repository root. If using an existing checkout, preserve uncommitted work rather than resetting it to the published tag. A fresh clone contains source, not the previous workstation's virtual environment, SDKs, model downloads, build outputs or smoke fixtures. Do not assume ignored local directories are available.

Suggested first message to the next assistant:

> Read HANDOFF.md and README.md. Inspect the current checkout and available toolchains before changing anything. Continue AudioSubs rather than rebuilding it. Preserve library compatibility, offline processing, safe output publication, the integrated Flutter UI, and both native platforms. Distinguish historical evidence from checks you run here. Do not publish releases or change signing/application identities without my instruction. Ask for my next feature or bug if I have not supplied one.

## Product and current implementation

AudioSubs is one Flutter application for Windows and Android. It imports audiobooks/audio, plays immediately without transcription, discovers matching SRT files, displays two synchronized subtitle tracks, and generates missing subtitles for a track, book or batch from the same app.

The player retains its library, natural/numbered-sibling sorting, covers, rename/removal, file-based chapter navigation, resume positions, playback speed/seeking/auto-advance, reading themes, Windows shortcuts and Android gestures. See README for controls and the verified format matrix.

The separate PyQt transcriber is a reference, not the delivered UI. Windows includes a private headless worker inside the app distribution. Android has its own packaged native backend and does not run Python or the Windows executable.

### Source map

| Area | Files | Responsibility |
| --- | --- | --- |
| Player and library | `lib/main.dart` | Shared UI, import, playback, state migration/settings, subtitle selection and integrated transcription entry points |
| Subtitle files | `lib/subtitle_files.dart` | Whole-stem matching, generated-output discovery, safe storage selection |
| Ebook proofreading | `lib/proofreading/ebook.dart`, `review.dart`, `screen.dart`, `storage.dart` | Local ebook extraction, conservative cue alignment/word differences, review editor and atomic no-replace corrected copies |
| Job controller | `lib/transcription/jobs.dart` | Single-job lifecycle, progress/current file, errors, output stream, cancellation/history |
| Job UI and contract | `lib/transcription/screen.dart`, `lib/transcription/backend.dart` | Model/options/job screen and platform backend interface |
| Windows adapter | `lib/transcription/windows_backend.dart` | Internal worker process and event protocol |
| Android adapter | `lib/transcription/android_backend.dart` | Flutter/native transcription bridge |
| Windows consent | `lib/windows_terms.dart` | Component terms gate and persisted document fingerprint before normal startup |
| Windows worker | `worker/audiosubs_worker.py` | Model downloads, incremental decoding/transcription, Argos translation, streamed SRT output and cancellation |
| Android storage/platform bridge | `android/app/src/main/kotlin/com/example/audiobook_player/MainActivity.kt` | Native channel/storage integration and persistent URI imports |
| Android inference/decoding | `android/app/src/main/kotlin/com/example/audiobook_player/TranscriptionEngine.kt`, `AudioDecoder.kt` in that directory | Background job execution, model handling, MediaExtractor/MediaCodec and WAV decoding |
| Android JNI | `android/app/src/main/cpp/whisper_jni.cpp`, `CMakeLists.txt` | CPU whisper.cpp integration; pinned upstream tag `v1.8.3` |
| Build/distribution | `scripts/`, `windows/CMakeLists.txt`, `android/app/build.gradle.kts` | Runtime assembly, native builds, licence/source collection and Windows packaging |
| Regression tests | `test/widget_test.dart`, `test/unified_app_test.dart`, `test/transcription_jobs_test.dart`, `test/windows_terms_test.dart`, `worker/test_worker.py` | Retained player coverage plus matching/discovery/migration/job/output/consent behaviour |
| Proofreading regressions | `test/ebook_test.dart`, `test/proofreading_test.dart`, `test/proofreading_storage_test.dart` | Reading order, encodings/format rejection, matching ambiguity/recovery, lossless SRT rendering and output preservation |

## Ebook proofreading (v2.1.0)

Included in the v2.1.0 preview; signing/application identities remain unchanged.

- Library/player checklist icon opens **Check subtitles against ebook**. Player seeds the selected primary SRT; manual SRT/ebook picking uses the existing persistent Android resolver.
- Reference extraction: EPUB spine order, legacy uncompressed/PalmDOC MOBI7/AZW, FB2, DOCX, TXT/HTML and PDF embedded text. Hybrid Kindle files may use a legacy rendition; KF8-only/AZW3, KFX, HUFF/CDIC, DRM and scanned-PDF OCR are not implemented. Unsupported input fails explicitly; see README for exact limits.
- Word-anchor/fuzzy monotonic alignment works with sentence fragments and whole-book references. Ambiguous/low-confidence passages abstain. **Auto-correct all matched cues** applies every reliable suggestion after a count/impact confirmation; manual edits are preserved unless explicitly opted into replacement. Saving a corrected copy remains separate. The editor also supports per-cue spelling/punctuation/line-break changes, word highlighting, navigation, restoration and unsaved-change confirmation.
- **Keep isolate closures outside the widget State.** Native smoke caught `Isolate.run` capturing unsendable widget resources through shared closure contexts. `screen.dart` now delegates through top-level worker closures. Pure parser tests alone do not catch that UI failure.
- Corrected copies always use app-owned support `subtitles/<hash>/` on Windows and Android. Source, cue numbers/order and raw timestamp lines remain unchanged. `*.corrected-N.srt` tracks are discoverable when associated with the current audio; existing primary/secondary selections are retained. A standalone SRT uses its own hash. Android has no shared-storage export for these copies.
- Publication uses a temporary transaction directory and native no-replace operations: Windows `MoveFileExW` without replacement flags; POSIX hard link in app-private storage. Never replace these with Dart `rename`, which can overwrite a completed file.
- PDFium is a new bundled native dependency downloaded at development build time, not during local proofreading. `assets/pdfium-NOTICES.txt` contains chromium/7811 Windows x64 and Android arm64/x64 notices, including Android-only components. `main.dart` registers them in Flutter's licences page; the release collector verifies the resolved native release pin and includes them. Refresh notices and pin together on upgrades.

Verification for this source addition (2026-10-26): 77 Flutter tests passed; scoped formatting and `flutter analyze lib test` were clean. Full-checkout analysis traverses existing `dist/` and `worker/` packaged dependency snapshots and reports unrelated missing imports/paths; these were preserved. Windows native debug API smoke read real Project Gutenberg EPUB/MOBI plus TXT/HTML/FB2/DOCX/text-PDF fixtures, checked suggestions/abstention and lossless timing/source preservation. A software-rendered native UI harness exercised review/apply/manual multiline edits/numbered saving/unsaved guards with rendered-frame proof and output readback; native EPUB picking also worked, but final UI actions used temporary fixture picker responses after the interactive desktop became unavailable. Android arm64/x64 **debug APK** built and contained both native PDFium ABIs and the notice asset; no Android runtime device was available. The native notice collector was exercised. Throwaway harnesses/fixtures were removed; no new release or signing change was made.

After smoke cleanup, the normal `lib/main.dart` Windows entrypoint also passed `flutter build windows --debug`; the debug executable no longer targets the temporary harness.

Bulk-correction release checks: all 80 Flutter tests and 11 worker tests passed, with clean scoped analysis. Native software-rendered UI smoke exercised protected bulk application, explicit replacement of an already-edited cue, and two saved outputs with unchanged timings/unmatched cues/source files. Complete native FreeType license text and its acknowledgement are bundled; notice collection rejects missing sections/reader placeholders. Windows packaging rejects stale-version manifests or missing PDFium-native notices. Notice cache/temp trees now default to ignored `.dart_tool/dependency-notices` to keep generated package snapshots out of source-analysis staging.

Release build evidence for v2.1.0: normal-entry Windows x64 release and Android arm64/x64 release builds passed. Windows native startup created a responsive window without agreement/library/model actions, and its frozen worker diagnostics loaded the private supported runtime and expected codecs. Android package/version/ABIs and v2 signature verified, with the same debug certificate as v2.0.0 and all 19 native PDFium notice texts. Fresh notice manifest is version 2.1.0 with 152 components and the matching LGPL source URL/archive. No Android device smoke or production-signing claim is implied; use release notes/checksums for downloadable artifact details.

## Contracts that must survive future changes

1. **Audio playback does not wait for subtitles or model downloads.** Existing readable SRTs load automatically. Generated outputs become selectable without restarting the app or playback. Respect an explicit primary/secondary selection, including **None**.
2. **Keep processing local after explicit downloads.** Windows uses faster-whisper/CTranslate2 and direct Argos translation packages; Android uses whisper.cpp GGML models. Those model formats are not interchangeable. Models are not bundled in releases.
3. **Keep inference off the UI thread and transcript memory bounded.** Windows decodes 60-second chunks; Android uses 30-second chunks. Stream transcript output rather than accumulating a whole audiobook.
4. **Never overwrite completed subtitle files.** Publish through safe temporary-file transactions. Cancellation/failure removes unfinished job-owned files, not completed outputs. Individual file errors must not prevent later batch files from running. Original and translated/bilingual files are separate transactions.
5. **Preserve the job protocol.** Windows exchanges structured events with the private worker; native/library diagnostics must not pollute protocol stdout. A batch must complete while stdin remains open for cancellation. A backend ending without a completion event is an error. Only one job runs at a time.
6. **Preserve storage identities and migration.** Dart package name remains `audiobook_player`; Android ID remains `com.example.audiobook_player`; Windows company/product identity remains `com.example` / `audiobook_player`. These are intentional compatibility choices, not unfinished branding. State schema is 2, with legacy library/settings/resume fields retained. Manual state import merges book IDs and rejects invalid/future schemas. Do not rename identifiers casually or delete user state.
7. **Do not treat Android content URIs as ordinary paths.** Unreadable URI/picker-cache inputs are persisted into app-private storage, preserving display filenames. Folder/sibling discovery can require all-files access; single/multiple file picking does not require it first.
8. **Preserve deliberate output placement.** Windows writes beside audio when possible, otherwise under application support `subtitles/<hash-of-audio-path>/`. Android generated subtitles always use that app-owned fallback: shared storage failed atomic no-replace publication during verification. Android uninstall/clear-data deletes private imports/subtitles/models. Do not change this silently.
9. **Match the entire audio stem.** `chapter1.srt` must not match `chapter10.mp3`; matching is case-insensitive and supports language/source-target suffixes. Partial files are not subtitle candidates. Identical basenames in different folders need distinct fallback storage.

## Windows development and distribution

Use a Windows x64 host for the Windows build. The prior workstation used Flutter **3.47.2**, Dart **3.13.2**, and Visual Studio C++ desktop tools. `pubspec.yaml` requires Dart `^3.13.2`; do not downgrade dependencies merely to fit an older SDK. Building the private worker requires **Windows x64 Python 3.12**, not 3.14. End users do not need Python installed.

PowerShell, from the repository root:

```powershell
flutter pub get
powershell -ExecutionPolicy Bypass -File scripts/setup_windows_runtime.ps1
flutter run -d windows
```

`setup_windows_runtime.ps1` creates `worker/.venv`, builds the custom LGPL PyAV/FFmpeg stack, installs dependencies, freezes the worker and collects notices/corresponding source. It can provision Python 3.12 through Python Install Manager; otherwise supply `-PythonPath C:\path\to\python.exe`. It provisions private MSYS2/build tools without requiring WSL. First setup needs internet and substantial dependency/build storage. `-SourceOnly` is not a complete fresh-app setup: Windows startup still needs a previously packaged runtime and its terms.

Build the complete Windows release with the wrapper:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1
```

This wrapper runs runtime setup and dependency resolution before `flutter build windows --release`. Launch `build\windows\x64\runner\Release\AudioSubs.exe`. Distribute the entire Release directory, including native DLLs, Flutter assets and `transcription_runtime`, never just the exe. Close running AudioSubs instances before replacing locked Windows binaries; do not terminate unrelated user processes.

For installer and portable ZIP, install/provision NSIS 3.x, then point to its actual compiler:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/package_windows_release.ps1 -NsisCompilerPath C:\tools\nsis\makensis.exe
```

The compiler path is an example, not a checked-in dependency. The script packages an existing build; it does not compile Flutter. Outputs are under `dist/<version>/`.

### Licensing and packaging decisions already made

- The user chose an **LGPL-only FFmpeg media runtime**, not relicensing AudioSubs as GPLv3. Do not replace the custom build with the stock PyAV Windows wheel: its bundled FFmpeg included GPL components.
- Current pins include PyAV `19.0.1+audiosubs.lgpl`, FFmpeg `9.0.2`, faster-whisper `1.2.1` and CTranslate2 `4.8.2`. See `worker/requirements.txt` for the actual dependency constraints.
- `scripts/build_lgpl_pyav.ps1` / `scripts/lgpl_pyav.py` verify source hashes, compiler configuration, shared DLL licences and binary provenance. Keep these guards; renamed/removed codec DLLs are not a substitute for rebuilding correctly.
- The user chose to retain the Intel/Microsoft runtime terms. `lib/windows_terms.dart` requires explicit first-use agreement and repeats it if the terms fingerprint changes; the installer also shows the terms. Missing terms block startup instead of silently bypassing consent.
- `scripts/collect_dependency_notices.py` assembles vendor notices plus FFmpeg/PyAV corresponding source and rebuild/relink instructions. Ship the corresponding-source ZIP at the URL recorded inside the Windows bundle. No AudioSubs application licence has been supplied; third-party notices do not grant one. Distribution entitlement/compliance is not certified by the collector.
- CUDA/cuDNN are not bundled. CPU + int8 was tested; GPU use needs the user's compatible CUDA 12/cuDNN 9 environment.
- Packaging rejects user audio, SRT outputs, downloaded speech models, state and reparse points. Preserve necessary worker assets such as VAD/tokenizer data.
- Installer is per-user, with exact-file uninstall. Unknown/user-added files and application-support data survive upgrade/uninstall. Portable ZIP means **no installation**, not portable user data: it still uses application-support storage.

## Android development

Use the pinned project configuration: compile SDK **37**, target **36**, minimum **24**, Flutter-selected NDK, CMake **3.22.1**, and a compatible JDK/Gradle toolchain supporting the Java 17 target. First native configuration fetches whisper.cpp `v1.8.3` from GitHub. MIT attribution is included at `android/app/src/main/assets/whisper.cpp-LICENSE`.

From the root, after installing Flutter/Android prerequisites:

```sh
flutter pub get
flutter build apk --release --target-platform android-arm64,android-x64
```

APK: `build/app/outputs/flutter-apk/app-release.apk`. Install on an appropriate attached emulator/device with:

```sh
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Only `arm64-v8a` and `x86_64` are packaged; no 32-bit ARM or x86. The release build currently uses the **debug signing configuration**. A newly generated debug key on Tern will not necessarily match the old workstation's key. Do not uninstall an existing app to bypass a signature mismatch without first protecting its state/private media/subtitles. Production signing needs owner-provided keys and an explicit migration/distribution decision; do not invent or commit signing secrets.

If Tern runs on Linux or another non-Windows host, source editing and Android work may be possible with the right installed tools, but that does not validate a Windows native build. No Linux desktop or web target is implemented as a substitute. Report unavailable host/device checks explicitly and use a suitable native build host.

## Validation for the next change

Start by checking installed tools, for example `flutter --version`, `flutter doctor -v`, and `flutter devices`. Do not assume the previous workstation's toolchains or emulator survived the transfer.

Shared checks:

```sh
dart format lib test
flutter analyze
flutter test
```

Windows worker tests, after supported runtime setup:

```powershell
worker\.venv\Scripts\python.exe -m unittest discover -s worker -p test_*.py
```

For behaviour changes, also launch the actual platform app and exercise the changed path. Tests/build success alone does not prove native decoding, storage permissions, inference, cancellation or packaging. Use separate scratch audio/output folders and preserve real user library data. Keep regression tests for consumer-visible behaviour, not source text or incidental widget wording.

### Historical verification of v2.0.0

The preceding implementation/release session recorded:

- Formatting and Flutter analysis passed; **21 Flutter tests**, including all 9 existing player tests, and **11 worker tests** passed.
- Windows release and Android ARM64/x86_64 APK builds passed. APK signature/ABI metadata was checked; final APK installed/launched on an API 35 x86_64 emulator.
- Windows UI exercised immediate playback, integrated downloads/transcription, original/Spanish/bilingual generation, dual subtitles and live output refresh.
- The extracted Windows portable worker, with system Python absent from PATH, decoded MP3/M4A/M4B/WAV/FLAC/OGG/AAC fixtures and produced 21 original/Spanish/bilingual SRTs offline. Missing-file recovery, live-stdin completion and native cancellation passed; completed outputs survived without partial files.
- Installer/portable payload hashes matched all 1,001 staged files. Both app bundles launched without system Python. Installation into a path with spaces, upgrade, registry/shortcuts, uninstall, user-added-file preservation and existing-library preservation passed. First-use consent persisted the exact document fingerprint; the installer loaded the full terms.
- Android emulator exercised all seven playback/transcription encodings, source-language detection, English translation/bilingual output, cancellation/error recovery, dual subtitles and hot refresh. Single/multiple URI imports worked with all-files access denied and persisted after restart.
- All **six uploaded release assets** were publicly downloaded and matched their local SHA-256 hashes. The release page includes installer, portable ZIP, APK, third-party notices, corresponding source and `SHA256SUMS.txt`.

These results are historical, not physical-phone evidence and not a substitute for rerunning affected checks after future changes. Detailed smoke scripts were throwaways, not a retained permanent integration suite.

## Known gaps and sensible next work

No new feature is authorized merely by this list. Confirm the user's next task, then choose a small end-to-end milestone.

- **Android translation parity is incomplete:** only speech translation into English is implemented. Bilingual timing uses whole 30-second chunks, not aligned words. Arbitrary-target on-device translation would require a native translation/tokenizer backend, compatible models and licence/storage/performance work; it is not solved by bundling Python. Windows supports downloaded direct Argos pairs, not pivot routing.
- **Android background execution is incomplete:** keep the app foregrounded. There is no foreground service or durable scheduler, nor automatic resume for interrupted jobs/downloads. Model construction can delay cancellation. Completed files remain preserved.
- **Production distribution is incomplete:** Windows binaries are unsigned; Android APK is debug-key signed. Physical ARM64 runtime verification, store requirements and safe signing-key migration remain work.
- **Hardware/performance evidence is limited:** no CUDA inference or sustained full-length-book/thermal testing; no physical ARM64 phone. Tiny-model translation can be poor despite producing valid timed output. Do not claim quality from pipeline success.
- **Decoder limits remain:** the tested Windows Media Foundation decoder rejected OGG playback, although transcription decoded it. Other device codecs, DRM/encrypted M4B, uncommon container encodings, compressed/RF64 WAV and all Android document providers are not verified. Embedded MP4 chapter extraction is not implemented; chapters are imported files.
- **Private subtitle portability is limited:** Android app-owned generated files work in the player but are not exported to Downloads and disappear on uninstall/clear-data. Export/sharing would be a separate feature, not an excuse to write unsafely to arbitrary shared storage.
- **Future releases need synchronized metadata:** update `pubspec.yaml`, the source-release URL in `scripts/setup_windows_runtime.ps1`, and versioned paths/text/manifest metadata in `scripts/collect_dependency_notices.py` together. Current release metadata targets v2.1.0. Never overwrite published tags/assets; publish matching LGPL source and notices with each binary set and verify public downloads.

## Transfer and security boundaries

Keep work inside the unified repository; do not modify the reference implementations, delete user data, rewrite published history or publish a new release without instruction. Do not copy `.venv`, build caches, model folders, signing keys, credential-manager exports or chat-pasted tokens into source control. Authenticate Tern separately through an approved account/SSH/secret mechanism. Keep documentation honest about exactly which checks were exercised on which host and device.
