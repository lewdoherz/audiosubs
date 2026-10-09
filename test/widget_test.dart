import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:audiobook_player/main.dart';

void main() {
  test('naturalCompare orders numbered files by numeric value', () {
    final names = ['book10.mp3', 'book2.mp3', 'book1.mp3', 'book3.mp3'];
    names.sort(naturalCompare);
    expect(names, ['book1.mp3', 'book2.mp3', 'book3.mp3', 'book10.mp3']);
  });

  test('discoverNumberedSiblings finds and orders numbered siblings', () async {
    final dir = await Directory.systemTemp.createTemp('audiobook_test');
    addTearDown(() => dir.delete(recursive: true));

    for (final n in ['book1', 'book2', 'book10', 'book3']) {
      File('${dir.path}${Platform.pathSeparator}$n.mp3').createSync();
    }
    // Non-siblings must be ignored.
    File('${dir.path}${Platform.pathSeparator}book2.srt').createSync();
    File('${dir.path}${Platform.pathSeparator}other1.mp3').createSync();

    final siblings = await discoverNumberedSiblings(
      '${dir.path}${Platform.pathSeparator}book2.mp3',
    );
    final names = siblings.map(fileNameFromPath).toList();
    expect(names, ['book1.mp3', 'book2.mp3', 'book3.mp3', 'book10.mp3']);
  });

  test(
    'discoverNumberedSiblings returns empty for a non-numbered name',
    () async {
      final dir = await Directory.systemTemp.createTemp('audiobook_test');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}${Platform.pathSeparator}book.mp3').createSync();

      final siblings = await discoverNumberedSiblings(
        '${dir.path}${Platform.pathSeparator}book.mp3',
      );
      expect(siblings, isEmpty);
    },
  );

  test('stripTrailingNumber removes a number and trailing separator', () {
    expect(stripTrailingNumber('book12'), 'book');
    expect(stripTrailingNumber('chapter_3'), 'chapter');
    expect(stripTrailingNumber('intro'), 'intro');
  });

  test('deriveBookTitle uses common prefix or folder name', () {
    expect(
      deriveBookTitle(['/a/book1.mp3', '/a/book2.mp3', '/a/book10.mp3']),
      'book',
    );
    expect(
      deriveBookTitle(['/a/chapter 1.mp3', '/a/chapter 2.mp3']),
      'chapter',
    );
    expect(
      deriveBookTitle(['/a/book1.mp3'], folderName: 'My Novel'),
      'My Novel',
    );
  });

  test('activeSubtitleIndex finds the covering caption or reports a gap', () {
    final subs = [
      SubtitleItem(1000, 2000, 'one'),
      SubtitleItem(3000, 4000, 'two'),
    ];

    expect(activeSubtitleIndex(subs, 500), -1, reason: 'before first caption');
    expect(activeSubtitleIndex(subs, 1000), 0, reason: 'inclusive start');
    expect(activeSubtitleIndex(subs, 2000), 0, reason: 'inclusive end');
    expect(activeSubtitleIndex(subs, 2500), -1, reason: 'gap between captions');
    expect(activeSubtitleIndex(subs, 3000), 1);
    expect(activeSubtitleIndex(subs, 4001), -1, reason: 'after last caption');
    expect(activeSubtitleIndex(const <SubtitleItem>[], 1000), -1);
  });

  test('PlayerSettings round-trip and repair unusable persisted values', () {
    final settings = PlayerSettings()
      ..fontSize = 40.0
      ..fontFamily = 'serif'
      ..fontColor = 'yellow'
      ..readingTheme = 'sepia'
      ..playbackSpeed = 1.3
      ..showContextLines = false;

    final decoded =
        jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>;
    final restored = PlayerSettings.fromJson(decoded);
    expect(restored.fontSize, 40.0);
    expect(restored.fontFamily, 'serif');
    expect(restored.fontColor, 'yellow');
    expect(restored.readingTheme, 'sepia');
    expect(restored.playbackSpeed, 1.3);
    expect(restored.showContextLines, isFalse);

    // A hand-edited or stale state file must not produce an unusable player.
    final repaired = PlayerSettings.fromJson(<String, dynamic>{
      'fontSize': 500.0,
      'fontFamily': 'comic sans',
      'fontColor': 'chartreuse',
      'readingTheme': 'blueprint',
      'playbackSpeed': 9.0,
      'showContextLines': 'yes',
    });
    expect(repaired.fontSize, PlayerSettings.maxFontSize);
    expect(repaired.fontFamily, 'default');
    expect(repaired.fontColor, 'auto');
    expect(repaired.readingTheme, 'dark');
    expect(repaired.playbackSpeed, PlayerSettings.maxSpeed);
    expect(repaired.showContextLines, isTrue);
  });

  test('subtitle colour follows the reading background unless set', () {
    final settings = PlayerSettings()..readingTheme = 'sepia';
    expect(settings.subtitleColor, readerThemeFor('sepia').foreground);

    settings.fontColor = 'yellow';
    expect(settings.subtitleColor, const Color(0xFFFFEB3B));

    settings.readingTheme = 'dark';
    expect(settings.subtitleColor, const Color(0xFFFFEB3B));
  });

  test('listAudioFilesInFolder collects audio recursively, sorted', () async {
    final dir = await Directory.systemTemp.createTemp('audiobook_test');
    addTearDown(() => dir.delete(recursive: true));

    File('${dir.path}${Platform.pathSeparator}book2.mp3').createSync();
    File('${dir.path}${Platform.pathSeparator}book1.mp3').createSync();
    File('${dir.path}${Platform.pathSeparator}notes.txt').createSync();
    final sub = Directory('${dir.path}${Platform.pathSeparator}sub');
    sub.createSync();
    File('${sub.path}${Platform.pathSeparator}book3.wav').createSync();

    final files = await listAudioFilesInFolder(dir.path);
    final names = files.map(fileNameFromPath).toList();
    expect(names, ['book1.mp3', 'book2.mp3', 'book3.wav']);
  });
}
