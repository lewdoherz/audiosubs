import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

import '../subtitle_files.dart';

/// Atomically publishes a completed copy without replacing an existing file.
/// Windows MoveFileEx without REPLACE_EXISTING and POSIX link both refuse a
/// destination that already exists. Temp files stay outside SRT discovery.
void publishCorrection(File temporary, String destination) {
  if (Platform.isWindows) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final move = kernel
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)
        >('MoveFileExW');
    final lastError = kernel.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
    );
    final source = temporary.absolute.path.toNativeUtf16();
    final target = File(destination).absolute.path.toNativeUtf16();
    try {
      if (move(source, target, 0) == 0) {
        final code = lastError();
        throw FileSystemException(
          'Could not publish corrected subtitle (existing files are never replaced)',
          destination,
          OSError('MoveFileExW', code),
        );
      }
    } finally {
      calloc.free(source);
      calloc.free(target);
    }
  } else {
    final libc = DynamicLibrary.process();
    final link = libc
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('link');
    final source = temporary.absolute.path.toNativeUtf8();
    final target = File(destination).absolute.path.toNativeUtf8();
    try {
      if (link(source, target) != 0) {
        throw FileSystemException(
          'Could not publish corrected subtitle (existing files are never replaced)',
          destination,
        );
      }
    } finally {
      calloc.free(source);
      calloc.free(target);
    }
    temporary.deleteSync();
  }
}

Future<String> saveCorrectedSubtitles({
  required String sourcePath,
  required String content,
  String? audioPath,
  Directory? support,
}) async {
  support ??= await getApplicationSupportDirectory();
  final directory = await generatedDirectory(
    audioPath ?? sourcePath,
    support: support,
  );
  await directory.create(recursive: true);
  final transaction = await directory.createTemp('.correction-');
  final temporary = File('${transaction.path}/output.partial');
  // Keep names bounded when reviewing a previously corrected copy.
  final sourceStem = audioStem(sourcePath)
      .replaceFirst(RegExp(r'\.corrected-\d+$'), '');
  final stem =
      audioPath != null && matchingSubtitle(audioPath, sourcePath) == null
      ? audioStem(audioPath)
      : sourceStem;
  try {
    await temporary.writeAsString(content, flush: true);
    for (var number = 1; ; number++) {
      final path = '${directory.path}/$stem.corrected-$number.srt';
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      try {
        publishCorrection(temporary, path);
        return path;
      } on FileSystemException {
        // Another writer may have won the same destination between check and
        // publish. Its file belongs to that writer, so try a different name.
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        rethrow;
      }
    }
  } finally {
    await transaction.delete(recursive: true);
  }
}
