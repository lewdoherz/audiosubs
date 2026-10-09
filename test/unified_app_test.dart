import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_player/main.dart';
import 'package:audiobook_player/subtitle_files.dart';

void main() {
  test('subtitle matching respects stem boundaries and language variants', () {
    expect(
      matchingSubtitle(r'C:\books\Chapter1.M4A', '/books/CHAPTER1.SRT')!.kind,
      'original',
    );
    expect(
      matchingSubtitle(
        '/books/chapter1.mp3',
        '/books/chapter1.es.srt',
      )!.language,
      'es',
    );
    expect(
      matchingSubtitle(
        '/books/chapter1.mp3',
        '/books/chapter1.en-es.srt',
      )!.kind,
      'bilingual',
    );
    expect(
      matchingSubtitle(
        '/books/chapter1.mp3',
        '/books/chapter1.original-en.srt',
      )!.kind,
      'bilingual',
    );
    for (final name in [
      'chapter10.srt',
      'chapter1.notes.srt',
      'chapter1.es.srt.tmp',
      'chapter1.srt.partial',
    ]) {
      expect(
        matchingSubtitle('/books/chapter1.mp3', name),
        isNull,
        reason: name,
      );
    }
  });

  test(
    'generated discovery refreshes and separates duplicate audio names',
    () async {
      final dir = await Directory.systemTemp.createTemp('audiosubs-discovery-');
      addTearDown(() => dir.delete(recursive: true));
      final first = '${dir.path}/a/book.m4b';
      final second = '${dir.path}/b/book.m4b';
      await File(first).create(recursive: true);
      await File(second).create(recursive: true);
      await File('${dir.path}/a/Book.SRT').writeAsString('existing');
      final initial = await discoverSubtitleFiles(first, support: dir);
      expect(initial.map((s) => s.kind), ['original']);
      final fallback = await generatedDirectory(first, support: dir);
      await fallback.create(recursive: true);
      final translated = File('${fallback.path}/book.es.srt');
      await translated.writeAsString('completed');
      await File('${fallback.path}/book.original-es.srt.partial')
          .writeAsString('incomplete');
      final refreshed = await discoverSubtitleFiles(first, support: dir);
      expect(refreshed.map((s) => s.kind), ['original', 'translated']);
      expect(await File(refreshed.last.path).readAsString(), 'completed');
      expect(await discoverSubtitleFiles(second, support: dir), isEmpty);
    },
  );

  test(
    'unavailable source directory uses discoverable isolated output storage',
    () async {
      final dir = await Directory.systemTemp.createTemp('audiosubs-output-');
      addTearDown(() => dir.delete(recursive: true));
      final audio = '${dir.path}/unmounted-a/book.mp3';
      final other = '${dir.path}/unmounted-b/book.mp3';
      final base = await outputBaseForAudio(audio, support: dir);
      final output = File('$base.srt');
      await output.writeAsString(
        '1\n00:00:00,000 --> 00:00:01,000\nCompleted\n',
      );
      final discovered = await discoverSubtitleFiles(audio, support: dir);
      expect(
        await File(discovered.single.path).readAsString(),
        await output.readAsString(),
      );
      expect(await discoverSubtitleFiles(other, support: dir), isEmpty);
      expect(await Directory('${dir.path}/unmounted-a').exists(), isFalse);
    },
  );

  test(
    'legacy state preserves resume, cover, settings and upgrades selections',
    () {
      addTearDown(() {
        library.clear();
        playerSettings = PlayerSettings();
      });
      restoreAppState(
        jsonEncode({
          'library': [
            {
              'id': 'legacy',
              'title': 'Book',
              'files': [r'C:\books\1.mp3', r'C:\books\2.mp3'],
              'coverPath': r'C:\books\cover.jpg',
              'currentIndex': 1,
              'positionMs': 12345,
            },
          ],
          'settings': {
            'readingTheme': 'sepia',
            'playbackSpeed': 1.4,
            'showContextLines': false,
          },
        }),
      );
      expect(library.single.currentIndex, 1);
      expect(library.single.positionMs, 12345);
      expect(library.single.coverPath, r'C:\books\cover.jpg');
      expect(playerSettings.readingTheme, 'sepia');
      expect(playerSettings.playbackSpeed, 1.4);
      expect(playerSettings.showContextLines, false);
      library.single.primarySubtitles[library.single.files.first] =
          'original.srt';
      library.single.secondarySubtitles[library.single.files.first] =
          'translation.srt';
      final current = jsonEncode({
        'schemaVersion': 2,
        'library': library.map((b) => b.toJson()).toList(),
        'settings': playerSettings.toJson(),
      });
      restoreAppState(current);
      expect(library.single.primarySubtitles.values, ['original.srt']);
      expect(library.single.secondarySubtitles.values, ['translation.srt']);
      restoreAppState(current, merge: true);
      expect(library.map((b) => b.id), ['legacy']);
    },
  );

  test('malformed migration cannot replace current library and future schema rejected', () {
    addTearDown(() {
      library.clear();
      playerSettings = PlayerSettings();
    });
    library = [
      Audiobook(id: 'keep', title: 'Keep', files: ['keep.mp3']),
    ];
    expect(
      () => restoreAppState('{"library":[{"id":"broken"}]}'),
      throwsA(anything),
    );
    expect(library.single.id, 'keep');
    expect(
      () => restoreAppState('{"schemaVersion":99,"library":[]}'),
      throwsFormatException,
    );
    expect(library.single.id, 'keep');
  });

  test(
    'folder imports recognize required formats without importing sidecars',
    () async {
      final dir = await Directory.systemTemp.createTemp('audiosubs-formats-');
      addTearDown(() => dir.delete(recursive: true));
      for (final ext in [
        'mp3',
        'M4A',
        'm4b',
        'wav',
        'flac',
        'ogg',
        'aac',
        'srt',
        'exe',
      ]) {
        await File('${dir.path}/book.$ext').create();
      }
      final files = await listAudioFilesInFolder(dir.path);
      expect(files.map((f) => fileExtension(f)).toSet(), {
        'mp3',
        'm4a',
        'm4b',
        'wav',
        'flac',
        'ogg',
        'aac',
      });
    },
  );
}
