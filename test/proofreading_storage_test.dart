import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_player/proofreading/storage.dart';
import 'package:audiobook_player/subtitle_files.dart';

void main() {
  test('correction copies preserve existing files and remain discoverable per audio', () async {
    final support = await Directory.systemTemp.createTemp(
      'audiosubs-correction-',
    );
    addTearDown(() => support.delete(recursive: true));
    final audio = '${support.path}/book/chapter1.mp3';
    final source = File('${support.path}/chapter1.es.srt');
    await source.writeAsString('original');
    final first = await saveCorrectedSubtitles(
      sourcePath: source.path,
      audioPath: audio,
      content: 'first correction',
      support: support,
    );
    final second = await saveCorrectedSubtitles(
      sourcePath: source.path,
      audioPath: audio,
      content: 'second correction',
      support: support,
    );
    expect(await source.readAsString(), 'original');
    expect(await File(first).readAsString(), 'first correction');
    expect(await File(second).readAsString(), 'second correction');
    final discovered = await discoverSubtitleFiles(audio, support: support);
    expect(discovered.map((s) => File(s.path).absolute.uri).toSet(), {
      File(first).absolute.uri,
      File(second).absolute.uri,
    });
    expect(discovered.every((s) => s.kind == 'corrected'), isTrue);
    expect(
      await discoverSubtitleFiles(
        '${support.path}/other/chapter1.mp3',
        support: support,
      ),
      isEmpty,
    );
    final directory = await generatedDirectory(audio, support: support);
    expect((await directory.list().toList()).whereType<Directory>(), isEmpty);
  });

  test('atomic publication refuses existing destination without touching either file', () async {
    final directory = await Directory.systemTemp.createTemp(
      'audiosubs-no-replace-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final temporary = File('${directory.path}/owned.partial');
    final completed = File('${directory.path}/completed.srt');
    await temporary.writeAsString('new');
    await completed.writeAsString('completed');
    expect(
      () => publishCorrection(temporary, completed.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(await temporary.readAsString(), 'new');
    expect(await completed.readAsString(), 'completed');
  });

  test(
    'corrected matching still respects complete stems and language suffixes',
    () {
      expect(
        matchingSubtitle('chapter1.mp3', 'chapter1.corrected-1.srt')!.kind,
        'corrected',
      );
      expect(
        matchingSubtitle(
          'chapter1.mp3',
          'chapter1.en-es.corrected-2.srt',
        )!.kind,
        'corrected',
      );
      for (final name in [
        'chapter10.corrected-1.srt',
        'chapter1.notes.corrected-1.srt',
        'chapter1.corrected-1.srt.partial',
        'chapter1.corrected-0.srt',
      ]) {
        expect(matchingSubtitle('chapter1.mp3', name), isNull);
      }
    },
  );
}
