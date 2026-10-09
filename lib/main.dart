import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:android_file_picker/android_file_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'subtitle_files.dart';
import 'transcription/jobs.dart';
import 'transcription/screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadAppState();
  try {
    await transcriptionJobs.loadHistory();
  } catch (error) {
    debugPrint('Could not read transcription history: $error');
  }
  runApp(const AudiobookApp());
}

/// Returns the final path segment (file name) of [path], handling both
/// '/' and '\' separators.
String fileNameFromPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final idx = normalized.lastIndexOf('/');
  return idx == -1 ? normalized : normalized.substring(idx + 1);
}

/// Strips the file extension from [fileName] (e.g. "book.mp3" -> "book").
String baseNameNoExt(String fileName) {
  final dotIndex = fileName.lastIndexOf('.');
  return dotIndex == -1 ? fileName : fileName.substring(0, dotIndex);
}

/// Compares two strings "naturally": embedded runs of digits are compared by
/// value rather than character code, so "book2" sorts before "book10".
int naturalCompare(String a, String b) {
  final re = RegExp(r'\d+|\D+');
  final aParts = re.allMatches(a).map((m) => m.group(0)!).toList();
  final bParts = re.allMatches(b).map((m) => m.group(0)!).toList();
  final len = aParts.length < bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < len; i++) {
    final ap = aParts[i];
    final bp = bParts[i];
    final cmp = (RegExp(r'^\d').hasMatch(ap) && RegExp(r'^\d').hasMatch(bp))
        ? int.parse(ap).compareTo(int.parse(bp))
        : ap.toLowerCase().compareTo(bp.toLowerCase());
    if (cmp != 0) return cmp;
  }
  return aParts.length.compareTo(bParts.length);
}

/// Finds numbered siblings of [audioFilePath] in the same directory.
///
/// Given "book3.mp3", returns every `book<N>.mp3` in that folder (including
/// the given file), sorted naturally by number. Returns an empty list when the
/// file name has no trailing number or the folder cannot be scanned.
Future<List<String>> discoverNumberedSiblings(String audioFilePath) async {
  final file = File(audioFilePath);
  final fileName = fileNameFromPath(audioFilePath);
  final base = baseNameNoExt(fileName);
  final ext = fileName.substring(base.length);

  final match = RegExp(r'^(.*?)(\d+)$').firstMatch(base);
  if (match == null) return [];

  final prefix = match.group(1)!;
  final dir = file.parent;
  if (!await dir.exists()) return [];

  final siblings = <String>[];
  try {
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = fileNameFromPath(entity.path);
      if (!name.toLowerCase().endsWith(ext.toLowerCase())) continue;
      final baseName = baseNameNoExt(name);
      final m = RegExp(r'^(.*?)(\d+)$').firstMatch(baseName);
      if (m == null) continue;
      if (m.group(1)!.toLowerCase() != prefix.toLowerCase()) continue;
      siblings.add(entity.path);
    }
  } catch (e) {
    debugPrint('Error scanning folder for numbered files: $e');
  }

  siblings.sort(
    (a, b) => naturalCompare(fileNameFromPath(a), fileNameFromPath(b)),
  );
  return siblings;
}

/// Returns the lowercased extension of [fileName] (without the dot),
/// or '' when there is none.
String fileExtension(String fileName) {
  final dotIndex = fileName.lastIndexOf('.');
  return dotIndex == -1 ? '' : fileName.substring(dotIndex + 1).toLowerCase();
}

/// Strips a trailing number (and any trailing separator) from [name],
/// e.g. "book12" -> "book", "chapter_3" -> "chapter".
String stripTrailingNumber(String name) {
  final match = RegExp(r'^(.*?)\d+$').firstMatch(name);
  final stem = match == null ? name : match.group(1)!;
  return stem.replaceAll(RegExp(r'[-_.\s]+$'), '');
}

/// Longest common prefix (case-insensitive) of [a] and [b].
String commonPrefix(String a, String b) {
  var i = 0;
  final max = a.length < b.length ? a.length : b.length;
  while (i < max && a[i].toLowerCase() == b[i].toLowerCase()) {
    i++;
  }
  return a.substring(0, i);
}

/// Derives a human-readable title for a set of audio [files]. Uses
/// [folderName] when provided; otherwise the common prefix of the file names
/// with trailing numbers stripped, falling back to the first file's base name.
String deriveBookTitle(List<String> files, {String? folderName}) {
  if (folderName != null && folderName.isNotEmpty) return folderName;
  if (files.isEmpty) return 'Untitled';
  final stems = files
      .map((f) => stripTrailingNumber(baseNameNoExt(fileNameFromPath(f))))
      .toList();
  var prefix = stems.first;
  for (final stem in stems.skip(1)) {
    prefix = commonPrefix(prefix, stem);
  }
  final trimmed = prefix.trim();
  if (trimmed.isNotEmpty) return trimmed;
  return baseNameNoExt(fileNameFromPath(files.first));
}

/// Playable audio extensions the library recognizes.
const Set<String> audioExtensions = {
  'mp3',
  'm4a',
  'm4b',
  'wav',
  'flac',
  'ogg',
  'aac',
};

/// Lists all audio files inside [dirPath], recursively, sorted naturally.
Future<List<String>> listAudioFilesInFolder(String dirPath) async {
  final dir = Directory(dirPath);
  final files = <String>[];
  try {
    if (!await dir.exists()) return files;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (audioExtensions.contains(
        fileExtension(fileNameFromPath(entity.path)),
      )) {
        files.add(entity.path);
      }
    }
  } catch (e) {
    debugPrint('Error scanning folder for audio: $e');
  }
  files.sort((a, b) => naturalCompare(a, b));
  return files;
}

String _newBookId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${library.length}';

/// A single audiobook: a title plus an ordered list of audio files, along
/// with the position at which the listener last stopped.
class Audiobook {
  final String id;
  String title;
  final List<String> files;
  String? coverPath;
  int currentIndex;
  int positionMs;
  final Map<String, String> primarySubtitles;
  final Map<String, String> secondarySubtitles;

  Audiobook({
    required this.id,
    required this.title,
    required this.files,
    this.coverPath,
    this.currentIndex = 0,
    this.positionMs = 0,
    Map<String, String>? primarySubtitles,
    Map<String, String>? secondarySubtitles,
  }) : primarySubtitles = primarySubtitles ?? {},
       secondarySubtitles = secondarySubtitles ?? {};

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'files': files,
    'coverPath': coverPath,
    'currentIndex': currentIndex,
    'positionMs': positionMs,
    'primarySubtitles': primarySubtitles,
    'secondarySubtitles': secondarySubtitles,
  };

  factory Audiobook.fromJson(Map<String, dynamic> json) => Audiobook(
    id: json['id'] as String,
    title: json['title'] as String,
    files: (json['files'] as List).cast<String>(),
    coverPath: json['coverPath'] as String?,
    currentIndex: (json['currentIndex'] as int?) ?? 0,
    positionMs: (json['positionMs'] as int?) ?? 0,
    primarySubtitles: (json['primarySubtitles'] as Map?)
        ?.cast<String, String>(),
    secondarySubtitles: (json['secondarySubtitles'] as Map?)
        ?.cast<String, String>(),
  );
}

/// The app's in-memory library, loaded once at startup and persisted on change.
List<Audiobook> library = [];

Future<File> _appStateFile() async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}${Platform.pathSeparator}player_state.json');
}

/// Decodes legacy unversioned state and current state before committing changes.
void restoreAppState(String content, {bool merge = false}) {
  final decoded = jsonDecode(content) as Map<String, dynamic>;
  final version = decoded['schemaVersion'] as int? ?? 1;
  if (version > 2) {
    throw const FormatException('State belongs to a newer AudioSubs version');
  }
  final restored = (decoded['library'] as List)
      .map((item) => Audiobook.fromJson((item as Map).cast<String, dynamic>()))
      .toList();
  for (final book in restored) {
    if (book.files.isEmpty) {
      throw const FormatException('A book has no audio files');
    }
    book.currentIndex = book.currentIndex.clamp(0, book.files.length - 1);
    book.positionMs = book.positionMs < 0 ? 0 : book.positionMs;
  }
  final settings = decoded['settings'];
  final restoredSettings = settings is Map<String, dynamic>
      ? PlayerSettings.fromJson(settings)
      : PlayerSettings();
  if (!merge) library.clear();
  for (final book in restored) {
    if (!library.any((existing) => existing.id == book.id)) library.add(book);
  }
  playerSettings = restoredSettings;
}

Future<void> loadAppState() async {
  try {
    final file = await _appStateFile();
    if (await file.exists()) restoreAppState(await file.readAsString());
  } catch (e) {
    debugPrint('Error loading library: $e');
  }
}

Future<void> _saveQueue = Future.value();

/// Serialize saves so playback and library updates cannot race temp publication.
Future<void> saveAppState() {
  final content = jsonEncode({
    'schemaVersion': 2,
    'library': library.map((b) => b.toJson()).toList(),
    'settings': playerSettings.toJson(),
  });
  return _saveQueue = _saveQueue
      .then((_) async {
        final file = await _appStateFile();
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(content, flush: true);
        await temporary.rename(file.path);
      })
      .catchError((Object e) {
        debugPrint('Error saving library: $e');
      });
}

/// Ensures the app can read audiobook folders and sibling subtitle files on
/// Android, where direct filesystem access requires the "All files access"
/// grant (Android 11+) or the legacy storage permission (Android 10 and
/// below). Returns true when access is available or not applicable (desktop).
Future<bool> ensureStoragePermission() async {
  if (!Platform.isAndroid) return true;

  var status = await Permission.manageExternalStorage.status;
  if (status.isGranted) return true;

  // Opens the system "All files access" settings page when not yet granted.
  status = await Permission.manageExternalStorage.request();
  if (status.isGranted) return true;

  // Android 10 and below fall back to the runtime storage permission.
  return (await Permission.storage.request()).isGranted;
}

/// Channel to native storage helpers (Android real-path resolution).
const MethodChannel _storageChannel = MethodChannel(
  'com.example.audiobook_player/storage',
);

/// Resolves an Android `content://` URI to a real filesystem path, or null
/// when the platform can't map it (or isn't Android).
Future<String?> _resolveContentUri(String uri, {required String name}) async {
  try {
    return await _storageChannel.invokeMethod<String>('resolveContentUri', {
      'uri': uri,
      'name': name,
    });
  } on MissingPluginException {
    return null;
  } on PlatformException catch (e) {
    debugPrint('Error resolving content URI: $e');
    return null;
  }
}

/// Returns the on-disk path to play [file] from.
///
/// On Android, file_picker hands back a cache copy of the picked file and
/// exposes the original `content://` URI through its SAF handle. Resolving
/// that URI to the real path lets numbered-sibling discovery and subtitle
/// auto-loading see the original folder. Unmappable providers are copied into
/// app-owned storage; picker cache fallback is also made persistent.
Future<String> _resolvedPathFor(PlatformFile file) async {
  var path = file.path ?? '';
  if (file is AndroidPlatformFile) {
    final uri = file.safHandle?.uri;
    if (uri != null && uri.scheme == 'content') {
      final resolved = await _resolveContentUri(
        uri.toString(),
        name: file.name,
      );
      if (resolved != null &&
          resolved.isNotEmpty &&
          await File(resolved).exists()) {
        return resolved;
      }
    }
    // A picker cache copy is not persistent library storage.
    if (path.isNotEmpty && await File(path).exists()) {
      final support = await getApplicationSupportDirectory();
      final key = await generatedDirectory(
        uri?.toString() ?? path,
        support: support,
      );
      final imported = Directory(
        '${support.path}/imports/${pathFileName(key.path)}',
      );
      await imported.create(recursive: true);
      final destination = File('${imported.path}/${fileNameFromPath(path)}');
      if (!await destination.exists()) await File(path).copy(destination.path);
      path = destination.path;
    }
  }
  return path;
}

class AudiobookApp extends StatelessWidget {
  const AudiobookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AudioSubs',
      theme: ThemeData.dark(),
      home: const LibraryScreen(),
    );
  }
}

/// How a new audiobook can be added to the library.
enum _AddMode { singleFile, severalFiles, folder }

/// Actions available from each library entry's overflow menu.
enum _BookAction { changeCover, rename, delete, transcribe }

/// Lists the saved audiobooks and provides the three "add" entry points.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            tooltip: 'Transcription jobs / batch',
            onPressed: () => openTranscription(
              context,
              library.expand((book) => book.files).toList(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: 'Import player state JSON',
            onPressed: _importState,
          ),
          if (Platform.isAndroid)
            IconButton(
              icon: const Icon(Icons.folder_shared),
              tooltip: 'Allow folder / sibling subtitle access',
              onPressed: () async {
                final granted = await ensureStoragePermission();
                if (mounted) {
                  _showMessage(
                    granted ? 'Folder and sibling subtitle access granted.' : 'Single-file imports still work as app-owned copies. Folder import and automatic sibling subtitles require storage access.',
                  );
                }
              },
            ),
          PopupMenuButton<_AddMode>(
            icon: const Icon(Icons.add),
            tooltip: 'Add audiobook',
            onSelected: _onAddMode,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _AddMode.singleFile,
                child: Text('Add single file'),
              ),
              PopupMenuItem(
                value: _AddMode.severalFiles,
                child: Text('Add several files'),
              ),
              PopupMenuItem(value: _AddMode.folder, child: Text('Add folder')),
            ],
          ),
        ],
      ),
      body: library.isEmpty
          ? const Center(
              child: Text(
                'No audiobooks yet.\nTap + to add one.',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.separated(
              itemCount: library.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final book = library[index];
                return ListTile(
                  leading: _bookCover(book),
                  title: Text(book.title),
                  subtitle: Text(
                    book.files.length == 1
                        ? '1 file'
                        : '${book.files.length} files',
                  ),
                  trailing: PopupMenuButton<_BookAction>(
                    icon: const Icon(Icons.more_vert),
                    tooltip: 'Book options',
                    onSelected: (action) => _onBookAction(action, book),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: _BookAction.transcribe,
                        child: Text('Generate subtitles for book'),
                      ),
                      PopupMenuItem(
                        value: _BookAction.changeCover,
                        child: Text('Change cover'),
                      ),
                      PopupMenuItem(
                        value: _BookAction.rename,
                        child: Text('Rename'),
                      ),
                      PopupMenuItem(
                        value: _BookAction.delete,
                        child: Text('Delete'),
                      ),
                    ],
                  ),
                  onTap: () => _openBook(book),
                );
              },
            ),
    );
  }

  Future<void> _importState() async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (picked?.path == null) return;
      restoreAppState(await File(picked!.path!).readAsString(), merge: true);
      await saveAppState();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) _showMessage('Could not import state: $error');
    }
  }

  /// The leading cover for a library entry: its image when one is set and
  /// readable, otherwise a placeholder icon.
  Widget _bookCover(Audiobook book) {
    final coverPath = book.coverPath;
    if (coverPath == null || coverPath.isEmpty) {
      return const Icon(Icons.music_note);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.file(
        File(coverPath),
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const Icon(Icons.music_note),
      ),
    );
  }

  Future<void> _onBookAction(_BookAction action, Audiobook book) async {
    switch (action) {
      case _BookAction.changeCover:
        await _changeCover(book);
      case _BookAction.rename:
        await _renameBook(book);
      case _BookAction.delete:
        await _deleteBook(book);
      case _BookAction.transcribe:
        if (mounted) await openTranscription(context, book.files);
    }
  }

  Future<void> _changeCover(Audiobook book) async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    if (result.isEmpty) return;
    final path = await _resolvedPathFor(result.first);
    if (path.isEmpty) return;
    setState(() {
      book.coverPath = path;
    });
    saveAppState();
  }

  Future<void> _renameBook(Audiobook book) async {
    final controller = TextEditingController(text: book.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename audiobook'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newTitle == null || newTitle.trim().isEmpty) return;
    setState(() {
      book.title = newTitle.trim();
    });
    saveAppState();
  }

  Future<void> _deleteBook(Audiobook book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete audiobook'),
        content: Text('Delete "${book.title}" from the library?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      library.remove(book);
    });
    saveAppState();
  }

  Future<void> _openBook(Audiobook book) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => PlayerScreen(audiobook: book)));
    if (mounted) setState(() {});
  }

  Future<void> _onAddMode(_AddMode mode) async {
    switch (mode) {
      case _AddMode.singleFile:
        await _addSingleFile();
      case _AddMode.severalFiles:
        await _addSeveralFiles();
      case _AddMode.folder:
        await _addFolder();
    }
  }

  Future<void> _addSingleFile() async {
    final file = await FilePicker.pickFile(
      // Document providers may report audiobook files as generic binary data.
      type: Platform.isAndroid ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isAndroid ? null : audioExtensions.toList(),
      androidOptions: const FilePickerAndroidOptions(),
    );
    if (file == null) return;
    if (!audioExtensions.contains(fileExtension(file.name))) {
      if (mounted) {
        _showMessage(
          'Unsupported audio file. Supported extensions: ${audioExtensions.join(', ')}.',
        );
      }
      return;
    }
    final path = await _resolvedPathFor(file);
    if (path.isEmpty || !audioExtensions.contains(fileExtension(path))) {
      if (mounted) {
        _showMessage(
          'Unsupported or unavailable audio file. Supported extensions: ${audioExtensions.join(', ')}.',
        );
      }
      return;
    }

    final siblings = await discoverNumberedSiblings(path);
    final files = siblings.isNotEmpty ? siblings : [path];
    _addBook(
      Audiobook(id: _newBookId(), title: deriveBookTitle(files), files: files),
    );
  }

  Future<void> _addSeveralFiles() async {
    final result = await FilePicker.pickFiles(
      type: Platform.isAndroid ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isAndroid ? null : audioExtensions.toList(),
      androidOptions: const FilePickerAndroidOptions(),
    );
    if (result.isEmpty) return;

    final files = <String>[];
    for (final f in result) {
      if (!audioExtensions.contains(fileExtension(f.name))) {
        if (mounted) {
          _showMessage('Skipped unsupported file: ${f.name}');
        }
        continue;
      }
      final path = await _resolvedPathFor(f);
      if (path.isNotEmpty && audioExtensions.contains(fileExtension(path))) {
        files.add(path);
      } else if (mounted) {
        _showMessage('Skipped unsupported or unavailable file: ${f.name}');
      }
    }
    if (files.isEmpty) return;
    files.sort(
      (a, b) => naturalCompare(fileNameFromPath(a), fileNameFromPath(b)),
    );

    _addBook(
      Audiobook(id: _newBookId(), title: deriveBookTitle(files), files: files),
    );
  }

  Future<void> _addFolder() async {
    if (!await ensureStoragePermission()) {
      _showMessage(
        'Storage access is required to read audiobook folders. '
        'Grant "All files access" and try again.',
      );
      return;
    }
    final dirPath = await FilePicker.getDirectoryPath();
    if (dirPath == null) return;
    final files = await listAudioFilesInFolder(dirPath);
    if (files.isEmpty) {
      _showMessage('No audio files found in the selected folder.');
      return;
    }
    _addBook(
      Audiobook(
        id: _newBookId(),
        title: deriveBookTitle(files, folderName: fileNameFromPath(dirPath)),
        files: files,
      ),
    );
  }

  void _addBook(Audiobook book) {
    setState(() {
      library.add(book);
    });
    saveAppState();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class SubtitleItem {
  final int startMs;
  final int endMs;
  final String text;

  SubtitleItem(this.startMs, this.endMs, this.text);
}

/// Index of the caption covering [currentMs] in [subs], or -1 when none does
/// (a gap between captions, an empty track, or a position before the first
/// caption). Both ends of a caption's interval are inclusive.
int activeSubtitleIndex(List<SubtitleItem> subs, int currentMs) => subs
    .indexWhere((sub) => currentMs >= sub.startMs && currentMs <= sub.endMs);

/// A subtitle font choice. [family] is looked up among the fonts installed on
/// the platform, falling back through [fallback] when it isn't there.
class SubtitleFontChoice {
  final String id;
  final String label;
  final String? family;
  final List<String> fallback;

  const SubtitleFontChoice(
    this.id,
    this.label,
    this.family, [
    this.fallback = const [],
  ]);
}

/// Subtitle fonts offered in settings, in display order.
const List<SubtitleFontChoice> subtitleFonts = [
  SubtitleFontChoice('default', 'Default', null),
  SubtitleFontChoice('serif', 'Serif', 'Georgia', [
    'Times New Roman',
    'Noto Serif',
    'serif',
  ]),
  SubtitleFontChoice('sans', 'Sans', 'Segoe UI', [
    'Roboto',
    'Arial',
    'Helvetica',
    'sans-serif',
  ]),
  SubtitleFontChoice('mono', 'Mono', 'Consolas', [
    'Courier New',
    'Roboto Mono',
    'monospace',
  ]),
];

/// The font choice with [id], or the default font when [id] is unknown.
SubtitleFontChoice subtitleFontFor(String id) => subtitleFonts.firstWhere(
  (font) => font.id == id,
  orElse: () => subtitleFonts.first,
);

/// A reading background, like the page themes of an ebook reader.
/// [foreground] stays legible on [background] and doubles as the "auto"
/// subtitle colour.
class ReaderTheme {
  final String id;
  final String label;
  final Color background;
  final Color foreground;

  const ReaderTheme(this.id, this.label, this.background, this.foreground);
}

/// Reading backgrounds offered in settings, in display order.
const List<ReaderTheme> readerThemes = [
  ReaderTheme('dark', 'Dark', Color(0xFF121212), Color(0xFFFFFFFF)),
  ReaderTheme('black', 'Black', Color(0xFF000000), Color(0xFFE8E8E8)),
  ReaderTheme('sepia', 'Sepia', Color(0xFFF4ECD8), Color(0xFF5B4636)),
  ReaderTheme('light', 'Light', Color(0xFFFFFFFF), Color(0xFF1A1A1A)),
];

/// The reading background with [id], or the default one when [id] is unknown.
ReaderTheme readerThemeFor(String id) => readerThemes.firstWhere(
  (theme) => theme.id == id,
  orElse: () => readerThemes.first,
);

/// A subtitle text colour; a null [color] follows the reading background.
class SubtitleColorChoice {
  final String id;
  final String label;
  final Color? color;

  const SubtitleColorChoice(this.id, this.label, this.color);
}

/// Subtitle colours offered in settings, in display order. The presets are
/// bright enough to read on either the dark or the light backgrounds.
const List<SubtitleColorChoice> subtitleColorChoices = [
  SubtitleColorChoice('auto', 'Auto', null),
  SubtitleColorChoice('white', 'White', Color(0xFFFFFFFF)),
  SubtitleColorChoice('yellow', 'Yellow', Color(0xFFFFEB3B)),
  SubtitleColorChoice('orange', 'Orange', Color(0xFFFFAB40)),
  SubtitleColorChoice('red', 'Red', Color(0xFFFF5252)),
  SubtitleColorChoice('pink', 'Pink', Color(0xFFFF4081)),
  SubtitleColorChoice('purple', 'Purple', Color(0xFFBB86FC)),
  SubtitleColorChoice('blue', 'Blue', Color(0xFF64B5F6)),
  SubtitleColorChoice('cyan', 'Cyan', Color(0xFF4DD0E1)),
  SubtitleColorChoice('green', 'Green', Color(0xFF69F0AE)),
];

/// The colour choice with [id], or "auto" when [id] is unknown.
SubtitleColorChoice subtitleColorFor(String id) =>
    subtitleColorChoices.firstWhere(
      (choice) => choice.id == id,
      orElse: () => subtitleColorChoices.first,
    );

/// Player display settings, persisted next to the library so they survive a
/// restart. Every value is kept inside the range the settings dialog offers.
class PlayerSettings {
  /// Subtitle size range, in points.
  static const double minFontSize = 12.0;
  static const double maxFontSize = 96.0;

  /// Playback rate range. Platforms only honour rates up to 2x.
  static const double minSpeed = 0.5;
  static const double maxSpeed = 2.0;

  PlayerSettings();

  double fontSize = 24.0;
  String fontFamily = 'default';
  String fontColor = 'auto';
  String readingTheme = 'dark';
  double playbackSpeed = 1.0;
  bool showContextLines = true;

  /// The chosen reading background.
  ReaderTheme get theme => readerThemeFor(readingTheme);

  /// The caption colour: the chosen preset, or the reading background's text
  /// colour while "auto" is selected.
  Color get subtitleColor =>
      subtitleColorFor(fontColor).color ?? theme.foreground;

  /// Subtitle text style at [size] points, dimmed to [opacity] for the
  /// neighbouring lines.
  TextStyle subtitleStyle(double size, {double opacity = 1.0}) {
    final font = subtitleFontFor(fontFamily);
    return TextStyle(
      fontSize: size,
      color: subtitleColor.withValues(alpha: opacity),
      fontFamily: font.family,
      fontFamilyFallback: font.fallback,
    );
  }

  /// Snaps [value] to a tenth, so repeated 0.1 speed changes don't drift into
  /// 1.2000000000000002.
  static double roundSpeed(double value) => (value * 10).roundToDouble() / 10;

  Map<String, dynamic> toJson() => {
    'fontSize': fontSize,
    'fontFamily': fontFamily,
    'fontColor': fontColor,
    'readingTheme': readingTheme,
    'playbackSpeed': playbackSpeed,
    'showContextLines': showContextLines,
  };

  /// Reads persisted settings, replacing anything missing, mistyped, or out of
  /// range with the default so a hand-edited state file still loads.
  factory PlayerSettings.fromJson(Map<String, dynamic> json) {
    final settings = PlayerSettings();

    final size = (json['fontSize'] as num?)?.toDouble();
    if (size != null && size.isFinite) {
      settings.fontSize = size.clamp(minFontSize, maxFontSize);
    }

    final speed = (json['playbackSpeed'] as num?)?.toDouble();
    if (speed != null && speed.isFinite) {
      settings.playbackSpeed = roundSpeed(speed.clamp(minSpeed, maxSpeed));
    }

    final family = json['fontFamily'];
    if (family is String && subtitleFonts.any((font) => font.id == family)) {
      settings.fontFamily = family;
    }

    final color = json['fontColor'];
    if (color is String &&
        subtitleColorChoices.any((choice) => choice.id == color)) {
      settings.fontColor = color;
    }

    final theme = json['readingTheme'];
    if (theme is String && readerThemes.any((entry) => entry.id == theme)) {
      settings.readingTheme = theme;
    }

    final contextLines = json['showContextLines'];
    if (contextLines is bool) {
      settings.showContextLines = contextLines;
    }

    return settings;
  }
}

/// The player settings in force, loaded at startup and persisted on change.
PlayerSettings playerSettings = PlayerSettings();

class PlayerScreen extends StatefulWidget {
  final Audiobook audiobook;

  const PlayerScreen({super.key, required this.audiobook});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late AudioPlayer _audioPlayer;
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  List<SubtitleItem> _subtitles = [];

  /// Index of the caption on screen within [_subtitles], or -1 while none has
  /// played yet (still loading, no file, or an empty file).
  int _subtitleIndex = -1;

  /// Shown in place of a caption while [_subtitleIndex] is -1: a load status
  /// or error message.
  String _subtitleMessage = '';
  List<SubtitleItem> _subtitles2 = [];
  int _subtitleIndex2 = -1;
  String _subtitleMessage2 = '';

  /// Position being previewed while a horizontal drag scrubs the audio, or
  /// null when no drag is in progress.
  Duration? _scrubPosition;

  /// Horizontal position of the last double tap, so a tap on the left third of
  /// the caption area rewinds and one on the right third skips forward.
  double? _doubleTapX;

  /// The reading background chosen in settings.
  ReaderTheme get _theme => playerSettings.theme;

  /// Style of the caption on screen.
  TextStyle get _subtitleStyle =>
      playerSettings.subtitleStyle(playerSettings.fontSize);

  /// Style for the dimmed neighbouring captions around the current line.
  TextStyle get _contextSubtitleStyle => playerSettings.subtitleStyle(
    playerSettings.fontSize * 0.8,
    opacity: 0.45,
  );

  /// Style for the secondary subtitle track, smaller and dimmer.
  TextStyle get _secondarySubtitleStyle =>
      playerSettings.subtitleStyle(playerSettings.fontSize * 0.8, opacity: 0.7);

  /// Caption on screen for track 1: the active line, or the last line shown
  /// while playback sits in a gap between captions, or the status message.
  String get _currentSubtitle =>
      _subtitleIndex >= 0 ? _subtitles[_subtitleIndex].text : _subtitleMessage;

  /// Caption on screen for track 2, shown below the primary one.
  String get _currentSubtitle2 => _subtitleIndex2 >= 0
      ? _subtitles2[_subtitleIndex2].text
      : _subtitleMessage2;

  /// The line right before the one on screen, or null when there is none.
  String? get _previousSubtitle =>
      _subtitleIndex > 0 ? _subtitles[_subtitleIndex - 1].text : null;

  /// The line right after the one on screen, or null when there is none.
  String? get _nextSubtitle =>
      _subtitleIndex >= 0 && _subtitleIndex + 1 < _subtitles.length
      ? _subtitles[_subtitleIndex + 1].text
      : null;

  /// Ordered audio file paths to play in sequence.
  List<String> _playlist = [];

  /// Index of the currently loaded file within [_playlist], or -1.
  int _currentIndex = -1;

  /// Path of the file currently loaded in the player, used for persistence.
  String? _currentFilePath;

  /// Periodically persists progress so a force-close loses at most a few
  /// seconds of listening position.
  Timer? _saveTimer;

  /// Player subscriptions, cancelled on dispose so no event can rebuild a
  /// defunct state.
  StreamSubscription<PlayerState>? _stateSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<void>? _completeSubscription;
  StreamSubscription<Map<String, dynamic>>? _outputSubscription;
  final Map<int, int> _subtitleLoads = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _audioPlayer = AudioPlayer();
    _outputSubscription = transcriptionJobs.outputs.stream.listen((event) {
      final audio = _currentFilePath;
      if (mounted && audio != null && event['audio'] == audio) {
        unawaited(_loadSubtitlesForAudio(audio));
      }
    });

    // Listen to playback state changes
    _stateSubscription = _audioPlayer.onPlayerStateChanged.listen((state) {
      setState(() {
        _isPlaying = state == PlayerState.playing;
      });
    });

    // Listen to audio duration
    _durationSubscription = _audioPlayer.onDurationChanged.listen((
      newDuration,
    ) {
      setState(() {
        _duration = newDuration;
      });
    });

    // Listen to audio position
    _positionSubscription = _audioPlayer.onPositionChanged.listen((
      newPosition,
    ) {
      setState(() {
        _position = newPosition;
        final ms = _position.inMilliseconds;
        _subtitleIndex = _matchSubtitle(_subtitles, ms, _subtitleIndex);
        _subtitleIndex2 = _matchSubtitle(_subtitles2, ms, _subtitleIndex2);
      });
    });

    // When a file finishes, advance to the next numbered file (if any).
    _completeSubscription = _audioPlayer.onPlayerComplete.listen((_) {
      _playNext();
    });

    // Persist progress periodically while playing.
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_isPlaying) {
        _saveState();
      }
    });

    // Open the audiobook at its last-known position, after the first frame
    // so that the initial load's setState runs outside initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_openAudiobook());
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    unawaited(_stateSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    unawaited(_completeSubscription?.cancel());
    unawaited(_outputSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_saveState());
    unawaited(_audioPlayer.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(_saveState());
    }
  }

  /// Returns the index of the caption active at [currentMs] within [subs], or
  /// [previous] unchanged if none is active, so the last line stays on screen
  /// through the gaps between captions.
  int _matchSubtitle(List<SubtitleItem> subs, int currentMs, int previous) {
    final index = activeSubtitleIndex(subs, currentMs);
    return index == -1 ? previous : index;
  }

  /// Loads the audiobook passed to this screen, resuming at its saved
  /// position, and starts playback.
  Future<void> _openAudiobook() async {
    _playlist = List.of(widget.audiobook.files);
    if (_playlist.isEmpty) return;

    var index = widget.audiobook.currentIndex;
    if (index < 0 || index >= _playlist.length) index = 0;

    await _loadFileAt(
      index,
      autoplay: true,
      seekTo: Duration(milliseconds: widget.audiobook.positionMs),
    );
  }

  /// Loads [_playlist][index] into the player, attaches its subtitles, and
  /// starts playback (optionally from [seekTo]).
  Future<void> _loadFileAt(
    int index, {
    bool autoplay = true,
    Duration? seekTo,
  }) async {
    if (index < 0 || index >= _playlist.length) return;
    _currentIndex = index;
    final filePath = _playlist[index];

    setState(() {
      _currentFilePath = filePath;
      _setSubtitles(1, const [], 'Looking for subtitles...');
      _setSubtitles(2, const [], '');
      _position = Duration.zero;
      _duration = Duration.zero;
      _scrubPosition = null;
    });

    try {
      final readable = await File(filePath).open();
      await readable.close();
      await _audioPlayer.setSource(DeviceFileSource(filePath));
      await _audioPlayer.setPlaybackRate(playerSettings.playbackSpeed);
    } catch (error) {
      if (mounted) {
        setState(
          () => _setSubtitles(
            1,
            const [],
            'Cannot play this file. Its codec may be unsupported or the file unavailable.\n$filePath\n$error',
          ),
        );
      }
      return;
    }
    if (!mounted || _currentFilePath != filePath) return;
    await _loadSubtitlesForAudio(filePath);

    if (seekTo != null) {
      var pos = seekTo;
      if (_duration > Duration.zero && pos >= _duration) {
        // Avoid seeking exactly to the end, which would trigger completion.
        pos = _duration - const Duration(milliseconds: 500);
        if (pos < Duration.zero) pos = Duration.zero;
      }
      if (pos > Duration.zero) {
        await _audioPlayer.seek(pos);
      }
      setState(() {
        _position = pos;
      });
    }

    if (autoplay) {
      await _audioPlayer.resume();
    }
    await _saveState();
  }

  /// Advances to the next file in the playlist after the current one finishes.
  Future<void> _playNext() async {
    if (_currentIndex < 0 || _currentIndex + 1 >= _playlist.length) return;
    await _loadFileAt(_currentIndex + 1, autoplay: true);
  }

  /// Jumps to the previous file in the book; pressing it on the first file
  /// restarts that file from the beginning.
  Future<void> _previousChapter() async {
    if (_currentIndex < 0 || _playlist.isEmpty) return;
    if (_currentIndex > 0) {
      await _loadFileAt(_currentIndex - 1, autoplay: true);
      return;
    }
    setState(() {
      _position = Duration.zero;
    });
    await _audioPlayer.seek(Duration.zero);
    if (_isPlaying) {
      await _audioPlayer.resume();
    }
    await _saveState();
  }

  /// Shows the list of files in this audiobook so the listener can jump to
  /// a specific chapter. Tapping a row starts that chapter.
  void _showChapterList() {
    if (_playlist.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.6,
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    'Chapters',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                for (var i = 0; i < _playlist.length; i++)
                  ListTile(
                    leading: Text('${i + 1}'),
                    title: Text(
                      fileNameFromPath(_playlist[i]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: i == _currentIndex
                          ? const TextStyle(color: Colors.blueAccent)
                          : null,
                    ),
                    trailing: i == _currentIndex
                        ? const Icon(Icons.play_arrow)
                        : null,
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      if (i != _currentIndex) {
                        _loadFileAt(i, autoplay: true);
                      }
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Persists the current file and position into the audiobook's saved
  /// progress (so the library resumes where the listener left off on the next
  /// launch) along with the player settings.
  Future<void> _saveState() async {
    if (_currentFilePath != null) {
      final book = widget.audiobook;
      book.currentIndex = _currentIndex < 0 ? 0 : _currentIndex;
      book.positionMs = _position.inMilliseconds;
    }
    await saveAppState();
  }

  /// Lets the user pick a .srt file directly, bypassing auto-detection.
  /// [track] 1 is the primary (centered) subtitle, 2 is the secondary
  /// one shown below it.
  Future<void> _pickSubtitleFile(int track) async {
    try {
      final List<PlatformFile> files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['srt'],
      );
      if (files.length == 1) {
        final path = await _resolvedPathFor(files.single);
        if (path.isNotEmpty) await _selectSubtitle(path, track);
      }
    } catch (e) {
      debugPrint("Error picking subtitle file: $e");
    }
  }

  Future<void> _selectSubtitle(String path, int track) async {
    final audio = _currentFilePath;
    if (audio == null) return;
    final selections = track == 1
        ? widget.audiobook.primarySubtitles
        : widget.audiobook.secondarySubtitles;
    selections[audio] = path;
    if (path.isEmpty) {
      if (mounted) setState(() => _setSubtitles(track, const [], ''));
    } else {
      await _loadSubtitlesFromPath(path, track: track);
    }
    await saveAppState();
  }

  Future<void> _chooseSubtitle(int track) async {
    final audio = _currentFilePath;
    if (audio == null) return;
    final available = await discoverSubtitleFiles(audio);
    if (!mounted || _currentFilePath != audio) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                track == 1 ? 'Primary subtitles' : 'Secondary subtitles',
              ),
            ),
            ListTile(
              title: const Text('None'),
              onTap: () => Navigator.pop(context, ''),
            ),
            for (final subtitle in available)
              ListTile(
                title: Text(subtitle.label),
                subtitle: Text(subtitle.path),
                onTap: () => Navigator.pop(context, subtitle.path),
              ),
            ListTile(
              title: const Text('Browse SRT…'),
              onTap: () => Navigator.pop(context, ':browse'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || _currentFilePath != audio || choice == null) return;
    if (choice == ':browse') {
      await _pickSubtitleFile(track);
    } else {
      await _selectSubtitle(choice, track);
    }
  }

  /// Discover sibling and app-owned generated tracks without restarting playback.
  Future<void> _loadSubtitlesForAudio(String audioFilePath) async {
    final available = await discoverSubtitleFiles(audioFilePath);
    if (!mounted || _currentFilePath != audioFilePath) return;
    final primary =
        widget.audiobook.primarySubtitles[audioFilePath] ??
        available.firstOrNull?.path;
    final secondary = widget.audiobook.secondarySubtitles[audioFilePath];
    if (primary == null || primary.isEmpty) {
      setState(
        () => _setSubtitles(
          1,
          const [],
          primary == null
              ? 'No subtitles yet. Play now, or use Generate subtitles.'
              : '',
        ),
      );
    } else {
      await _loadSubtitlesFromPath(primary);
    }
    if (secondary != null && secondary.isNotEmpty) {
      await _loadSubtitlesFromPath(secondary, track: 2);
    }
  }

  Future<void> _loadSubtitlesFromPath(String srtPath, {int track = 1}) async {
    final file = File(srtPath);
    final audio = _currentFilePath;
    final generation = (_subtitleLoads[track] ?? 0) + 1;
    _subtitleLoads[track] = generation;

    if (!await file.exists()) {
      if (!mounted ||
          _currentFilePath != audio ||
          _subtitleLoads[track] != generation) {
        return;
      }
      setState(() {
        _setSubtitles(track, const [], 'Subtitle file not found:\n$srtPath');
      });
      return;
    }

    try {
      final content = await file.readAsString();
      final parsed = _parseSrt(content);
      if (!mounted ||
          _currentFilePath != audio ||
          _subtitleLoads[track] != generation) {
        return;
      }
      setState(() {
        _setSubtitles(
          track,
          parsed,
          parsed.isEmpty ? 'Subtitle file is empty.' : '',
        );
      });
    } catch (e) {
      debugPrint("Error reading subtitle file: $e");
      if (!mounted ||
          _currentFilePath != audio ||
          _subtitleLoads[track] != generation) {
        return;
      }
      setState(() {
        _setSubtitles(track, const [], 'Could not read subtitle file.');
      });
    }
  }

  /// Installs [subs] into one of the two subtitle tracks, resetting its
  /// position so no caption from the previous file lingers. [message] is
  /// shown until the first caption of [subs] plays.
  void _setSubtitles(int track, List<SubtitleItem> subs, String message) {
    if (track == 1) {
      _subtitles = subs;
      _subtitleIndex = activeSubtitleIndex(subs, _position.inMilliseconds);
      _subtitleMessage = message;
    } else {
      _subtitles2 = subs;
      _subtitleIndex2 = activeSubtitleIndex(subs, _position.inMilliseconds);
      _subtitleMessage2 = message;
    }
  }

  /// Parses standard SubRip (.srt) content into a list of [SubtitleItem]s.
  /// Tolerates \r\n line endings, a '.' instead of ',' before milliseconds,
  /// multi-line captions, and strips simple HTML-style tags (e.g. <i>).
  List<SubtitleItem> _parseSrt(String content) {
    final normalized = content.replaceAll('\r\n', '\n');
    final blocks = normalized.split(RegExp(r'\n\s*\n'));
    final timeLineRegex = RegExp(
      r'(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})',
    );

    final items = <SubtitleItem>[];

    for (final block in blocks) {
      final lines = block.trim().split('\n');
      if (lines.isEmpty || lines.first.isEmpty) continue;

      var timingLineIndex = -1;
      for (var i = 0; i < lines.length; i++) {
        if (timeLineRegex.hasMatch(lines[i])) {
          timingLineIndex = i;
          break;
        }
      }
      if (timingLineIndex == -1) continue;

      final match = timeLineRegex.firstMatch(lines[timingLineIndex])!;
      final startMs = _srtTimeToMs(match, 1);
      final endMs = _srtTimeToMs(match, 5);

      final text = lines
          .sublist(timingLineIndex + 1)
          .join('\n')
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim();
      if (text.isEmpty) continue;

      items.add(SubtitleItem(startMs, endMs, text));
    }

    items.sort((a, b) => a.startMs.compareTo(b.startMs));
    return items;
  }

  int _srtTimeToMs(RegExpMatch match, int startGroup) {
    final hours = int.parse(match.group(startGroup)!);
    final minutes = int.parse(match.group(startGroup + 1)!);
    final seconds = int.parse(match.group(startGroup + 2)!);
    final millis = int.parse(match.group(startGroup + 3)!);
    return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis;
  }

  /// Applies [speed] to the running player and remembers it in the settings.
  Future<void> _setPlaybackSpeed(double speed) async {
    final snapped = PlayerSettings.roundSpeed(
      speed.clamp(PlayerSettings.minSpeed, PlayerSettings.maxSpeed),
    );
    setState(() {
      playerSettings.playbackSpeed = snapped;
    });
    await _audioPlayer.setPlaybackRate(snapped);
  }

  /// Moves the playback speed by [delta], e.g. 0.1 per arrow key press.
  Future<void> _nudgeSpeed(double delta) =>
      _setPlaybackSpeed(playerSettings.playbackSpeed + delta);

  /// Seeks to [target], clamped to the length of the loaded audio.
  Future<void> _seekTo(Duration target) async {
    var position = target;
    if (position < Duration.zero) {
      position = Duration.zero;
    } else if (_duration > Duration.zero && position > _duration) {
      position = _duration;
    }
    await _audioPlayer.seek(position);
    await _saveState();
  }

  Future<void> _skip(Duration offset) => _seekTo(_position + offset);

  /// Starts or pauses playback, from the play button, a tap on the caption
  /// area, or the space bar.
  Future<void> _togglePlayPause() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
      await _saveState();
    } else {
      await _audioPlayer.resume();
    }
  }

  /// Scrubs by dragging horizontally across the caption area: each pixel
  /// moves the previewed position by [_msPerScrubPixel], and the preview is
  /// applied on release.
  static const int _msPerScrubPixel = 200;

  void _onScrubUpdate(DragUpdateDetails details) {
    final offset = Duration(
      milliseconds: (details.delta.dx * _msPerScrubPixel).round(),
    );
    var target = (_scrubPosition ?? _position) + offset;
    if (target < Duration.zero) target = Duration.zero;
    if (_duration > Duration.zero && target > _duration) target = _duration;
    setState(() {
      _scrubPosition = target;
    });
  }

  Future<void> _onScrubEnd() async {
    final target = _scrubPosition;
    setState(() {
      _scrubPosition = null;
    });
    if (target != null) await _seekTo(target);
  }

  /// Double-tapping the left or right third of the caption area skips 15
  /// seconds backwards or forwards, as mobile players do.
  void _onCaptionDoubleTap(double width) {
    final x = _doubleTapX;
    if (x == null || width <= 0) return;
    if (x < width / 3) {
      unawaited(_skip(const Duration(seconds: -15)));
    } else if (x > width * 2 / 3) {
      unawaited(_skip(const Duration(seconds: 15)));
    }
  }

  /// Opens the settings dialog and persists whatever was changed in it.
  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return _SettingsDialog(
          onChanged: () {
            setState(() {});
          },
          onSpeedChanged: _setPlaybackSpeed,
        );
      },
    );
    await _saveState();
  }

  @override
  Widget build(BuildContext context) {
    final theme = _theme;
    final previousSubtitle = playerSettings.showContextLines
        ? _previousSubtitle
        : null;
    final nextSubtitle = playerSettings.showContextLines ? _nextSubtitle : null;
    // While a drag is scrubbing, the time readouts follow the preview.
    final position = _scrubPosition ?? _position;
    final sliderMax = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds.toDouble()
        : 1.0;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () =>
            unawaited(_togglePlayPause()),
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () =>
            unawaited(_togglePlayPause()),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            unawaited(_skip(const Duration(seconds: -15))),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            unawaited(_skip(const Duration(seconds: 15))),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () =>
            unawaited(_skip(const Duration(seconds: -60))),
        const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () =>
            unawaited(_skip(const Duration(seconds: 60))),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            unawaited(_nudgeSpeed(0.1)),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            unawaited(_nudgeSpeed(-0.1)),
        const SingleActivator(LogicalKeyboardKey.comma): () =>
            unawaited(_previousChapter()),
        const SingleActivator(LogicalKeyboardKey.period): () =>
            unawaited(_playNext()),
        const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): () =>
            unawaited(_previousChapter()),
        const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () =>
            unawaited(_playNext()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: theme.background,
          appBar: AppBar(
            backgroundColor: theme.background,
            foregroundColor: theme.foreground,
            title: Text(widget.audiobook.title),
            actions: [
              IconButton(
                icon: const Icon(Icons.auto_awesome),
                tooltip: 'Generate subtitles',
                onPressed: () => openTranscription(context, [
                  ?_currentFilePath,
                  ...widget.audiobook.files.where(
                    (path) => path != _currentFilePath,
                  ),
                ]),
              ),
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: _openSettings,
                tooltip: 'Settings',
              ),
              IconButton(
                icon: const Icon(Icons.subtitles),
                onPressed: () => _chooseSubtitle(1),
                tooltip: 'Primary subtitle track',
              ),
              IconButton(
                icon: const Icon(Icons.subtitles_outlined),
                onPressed: () => _chooseSubtitle(2),
                tooltip: 'Secondary subtitle track',
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => unawaited(_togglePlayPause()),
                        onDoubleTapDown: (details) =>
                            _doubleTapX = details.localPosition.dx,
                        onDoubleTap: () =>
                            _onCaptionDoubleTap(constraints.maxWidth),
                        onHorizontalDragUpdate: _onScrubUpdate,
                        onHorizontalDragEnd: (_) => unawaited(_onScrubEnd()),
                        child: Center(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (previousSubtitle != null) ...[
                                  Text(
                                    previousSubtitle,
                                    style: _contextSubtitleStyle,
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 12),
                                ],
                                Text(
                                  _currentSubtitle,
                                  style: _subtitleStyle,
                                  textAlign: TextAlign.center,
                                ),
                                if (nextSubtitle != null) ...[
                                  const SizedBox(height: 12),
                                  Text(
                                    nextSubtitle,
                                    style: _contextSubtitleStyle,
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                                if (_currentSubtitle2.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    _currentSubtitle2,
                                    style: _secondarySubtitleStyle,
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: theme.foreground,
                    inactiveTrackColor: theme.foreground.withValues(alpha: 0.3),
                    thumbColor: theme.foreground,
                    overlayColor: theme.foreground.withValues(alpha: 0.12),
                  ),
                  child: Slider(
                    min: 0.0,
                    max: sliderMax,
                    value: position.inMilliseconds.toDouble().clamp(
                      0.0,
                      sliderMax,
                    ),
                    onChanged: (value) async {
                      final target = Duration(milliseconds: value.toInt());
                      setState(() {
                        _scrubPosition = target;
                      });
                    },
                    onChangeEnd: (value) async {
                      setState(() {
                        _scrubPosition = null;
                      });
                      await _seekTo(Duration(milliseconds: value.toInt()));
                    },
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(position),
                      style: TextStyle(color: theme.foreground),
                    ),
                    Text(
                      _formatDuration(_duration),
                      style: TextStyle(color: theme.foreground),
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      iconSize: 32,
                      color: theme.foreground,
                      tooltip: 'Previous chapter',
                      onPressed: _currentIndex >= 0 ? _previousChapter : null,
                    ),
                    TextButton.icon(
                      onPressed: _showChapterList,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.foreground,
                      ),
                      icon: const Icon(Icons.playlist_play, size: 20),
                      label: Text(
                        _currentIndex >= 0
                            ? 'Chapter ${_currentIndex + 1} / ${_playlist.length}'
                            : 'Chapters',
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      iconSize: 32,
                      color: theme.foreground,
                      tooltip: 'Next chapter',
                      onPressed:
                          _currentIndex >= 0 &&
                              _currentIndex + 1 < _playlist.length
                          ? _playNext
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _SkipButton(
                      icon: Icons.replay,
                      label: '15',
                      color: theme.foreground,
                      onPressed: () => _skip(const Duration(seconds: -15)),
                    ),
                    const SizedBox(width: 24),
                    IconButton(
                      iconSize: 48,
                      color: theme.foreground,
                      icon: Icon(
                        _isPlaying ? Icons.pause_circle : Icons.play_circle,
                      ),
                      onPressed: () => unawaited(_togglePlayPause()),
                    ),
                    const SizedBox(width: 24),
                    _SkipButton(
                      icon: Icons.replay,
                      label: '15',
                      color: theme.foreground,
                      flip: true,
                      onPressed: () => _skip(const Duration(seconds: 15)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${playerSettings.playbackSpeed.toStringAsFixed(1)}x',
                  style: TextStyle(
                    color: theme.foreground.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(duration.inHours);
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return duration.inHours > 0
        ? '$hours:$minutes:$seconds'
        : '$minutes:$seconds';
  }
}

/// A round icon button with a small numeric label (e.g. a "15" badge)
/// used for the skip-back / skip-forward controls.
class _SkipButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;
  final bool flip;

  const _SkipButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
    this.flip = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconWidget = Icon(icon, size: 36, color: color);
    return InkResponse(
      onTap: onPressed,
      radius: 32,
      child: SizedBox(
        width: 56,
        height: 56,
        child: Stack(
          alignment: Alignment.center,
          children: [
            flip
                ? Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..scaleByDouble(-1.0, 1.0, 1.0, 1.0),
                    child: iconWidget,
                  )
                : iconWidget,
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings dialog for the subtitle appearance (size, font, colour), the
/// reading background, the neighbouring caption lines, and playback speed.
/// Each control edits the shared [playerSettings] directly, keeping a local
/// copy so the dialog responds immediately, and tells the player screen to
/// redraw through [onChanged].
class _SettingsDialog extends StatefulWidget {
  final VoidCallback onChanged;
  final ValueChanged<double> onSpeedChanged;

  const _SettingsDialog({
    required this.onChanged,
    required this.onSpeedChanged,
  });

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late double _fontSize;
  late String _fontFamily;
  late String _fontColor;
  late String _readingTheme;
  late bool _showContextLines;
  late double _speed;

  @override
  void initState() {
    super.initState();
    _fontSize = playerSettings.fontSize;
    _fontFamily = playerSettings.fontFamily;
    _fontColor = playerSettings.fontColor;
    _readingTheme = playerSettings.readingTheme;
    _showContextLines = playerSettings.showContextLines;
    _speed = playerSettings.playbackSpeed;
  }

  /// Redraws the dialog and the player behind it after a change.
  void _apply(VoidCallback update) {
    setState(update);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = readerThemeFor(_readingTheme);

    return AlertDialog(
      title: const Text('Settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Subtitle size: ${_fontSize.round()}'),
            Slider(
              min: PlayerSettings.minFontSize,
              max: PlayerSettings.maxFontSize,
              divisions:
                  (PlayerSettings.maxFontSize - PlayerSettings.minFontSize)
                      .round(),
              value: _fontSize,
              label: _fontSize.round().toString(),
              onChanged: (value) => _apply(() {
                _fontSize = value;
                playerSettings.fontSize = value;
              }),
            ),
            const SizedBox(height: 8),
            const Text('Subtitle font:'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final font in subtitleFonts)
                  ChoiceChip(
                    label: Text(font.label),
                    selected: _fontFamily == font.id,
                    onSelected: (_) => _apply(() {
                      _fontFamily = font.id;
                      playerSettings.fontFamily = font.id;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Subtitle colour (Auto follows the background):'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final choice in subtitleColorChoices)
                  _ColorSwatch(
                    color: choice.color ?? theme.foreground,
                    label: choice.label,
                    selected: _fontColor == choice.id,
                    onTap: () => _apply(() {
                      _fontColor = choice.id;
                      playerSettings.fontColor = choice.id;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Reading background:'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final preset in readerThemes)
                  _ColorSwatch(
                    color: preset.background,
                    label: preset.label,
                    selected: _readingTheme == preset.id,
                    onTap: () => _apply(() {
                      _readingTheme = preset.id;
                      playerSettings.readingTheme = preset.id;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show neighbouring lines'),
              subtitle: const Text(
                'Previous and next caption, dimmed around the current line',
              ),
              value: _showContextLines,
              onChanged: (value) => _apply(() {
                _showContextLines = value;
                playerSettings.showContextLines = value;
              }),
            ),
            const SizedBox(height: 8),
            Text('Playback speed: ${_speed.toStringAsFixed(1)}x'),
            Slider(
              min: PlayerSettings.minSpeed,
              max: PlayerSettings.maxSpeed,
              divisions:
                  ((PlayerSettings.maxSpeed - PlayerSettings.minSpeed) * 10)
                      .round(),
              value: _speed,
              label: '${_speed.toStringAsFixed(1)}x',
              onChanged: (value) {
                final speed = PlayerSettings.roundSpeed(value);
                setState(() {
                  _speed = speed;
                });
                widget.onSpeedChanged(speed);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// A circular, tappable colour choice used in the settings dialog. Shows a
/// check mark and accent ring when [selected], and outlines pale colours so
/// they stay visible against the dialog.
class _ColorSwatch extends StatelessWidget {
  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ColorSwatch({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark;
    final checkColor = isDark ? Colors.white : Colors.black87;

    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Colors.blueAccent
                  : (isDark ? Colors.white38 : Colors.black26),
              width: selected ? 3.0 : 1.0,
            ),
          ),
          child: selected
              ? Icon(Icons.check, size: 20, color: checkColor)
              : null,
        ),
      ),
    );
  }
}
