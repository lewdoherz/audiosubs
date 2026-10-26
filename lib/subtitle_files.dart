import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

String pathFileName(String path) => path.replaceAll('\\', '/').split('/').last;
String audioStem(String path) {
  final name = pathFileName(path);
  final dot = name.lastIndexOf('.');
  return dot < 0 ? name : name.substring(0, dot);
}

class SubtitleFile {
  final String path;
  final String kind;
  final String language;
  const SubtitleFile(this.path, this.kind, this.language);
  String get label => switch (kind) {
    'original' => 'Original',
    'corrected' => 'Corrected ($language)',
    _ => '$kind ($language)',
  };
}

/// Only exact stems and language suffixes match; chapter1 must not match chapter10.
SubtitleFile? matchingSubtitle(String audio, String candidate) {
  final name = pathFileName(candidate).toLowerCase();
  final stem = audioStem(audio).toLowerCase();
  if (name == '$stem.srt') {
    return SubtitleFile(candidate, 'original', 'original');
  }
  final corrected = RegExp(r'^(.*)\.corrected-([1-9]\d*)\.srt$')
      .firstMatch(name);
  if (corrected != null) {
    final original = matchingSubtitle(audio, '${corrected.group(1)}.srt');
    if (original != null && original.kind != 'corrected') {
      return SubtitleFile(
        candidate,
        'corrected',
        '${original.language}, copy ${corrected.group(2)}',
      );
    }
    return null;
  }
  if (!name.startsWith('$stem.') || !name.endsWith('.srt')) return null;
  final suffix = name.substring(stem.length + 1, name.length - 4);
  if (RegExp(r'^[a-z]{2,3}$').hasMatch(suffix)) {
    return SubtitleFile(candidate, 'translated', suffix);
  }
  if (RegExp(r'^(?:[a-z]{2,3}|original)-[a-z]{2,3}$').hasMatch(suffix)) {
    return SubtitleFile(candidate, 'bilingual', suffix);
  }
  return null;
}

Future<Directory> generatedDirectory(String audio, {Directory? support}) async {
  support ??= await getApplicationSupportDirectory();
  final key = sha256.convert(utf8.encode(File(audio).absolute.path)).toString();
  return Directory('${support.path}/subtitles/$key');
}

Future<List<SubtitleFile>> discoverSubtitleFiles(
  String audio, {
  Directory? support,
}) async {
  final found = <SubtitleFile>[];
  final directories = [
    File(audio).parent,
    await generatedDirectory(audio, support: support),
  ];
  for (final dir in directories) {
    try {
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final match = matchingSubtitle(audio, entity.path);
        if (match != null) found.add(match);
      }
    } on FileSystemException {
      // SAF/provider imports can have no readable sibling directory.
    }
  }
  const rank = {'original': 0, 'translated': 1, 'bilingual': 2, 'corrected': 3};
  found.sort((a, b) {
    final order = rank[a.kind]!.compareTo(rank[b.kind]!);
    return order != 0
        ? order
        : a.path.toLowerCase().compareTo(b.path.toLowerCase());
  });
  return found;
}

/// Android shared storage cannot reliably publish atomically; use private storage.
/// Desktop unwritable sources also fall back without touching existing subtitles.
Future<String> outputBaseForAudio(String audio, {Directory? support}) async {
  if (!Platform.isAndroid) {
    final parent = File(audio).parent;
    final probe = File(
      '${parent.path}/.audiosubs-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await probe.create(exclusive: true);
      await probe.delete();
      return '${parent.path}/${audioStem(audio)}';
    } on FileSystemException {
      // Read-only and provider locations use the same discoverable fallback.
    }
  }
  final fallback = await generatedDirectory(audio, support: support);
  await fallback.create(recursive: true);
  return '${fallback.path}/${audioStem(audio)}';
}
