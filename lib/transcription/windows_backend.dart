import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'backend.dart';

/// Starts AudioSubs' private, headless worker; never invokes a system Python.
class WindowsTranscriptionBackend extends TranscriptionBackend {
  Process? _process;
  bool _running = false;
  bool _cancelRequested = false;
  bool _disposed = false;

  static const _descriptors = <Map<String, Object>>[
    {'id': 'tiny', 'label': 'Tiny', 'bytes': 78000000, 'memoryMb': 512},
    {'id': 'base', 'label': 'Base', 'bytes': 148000000, 'memoryMb': 768},
    {'id': 'small', 'label': 'Small', 'bytes': 488000000, 'memoryMb': 2048},
    {'id': 'medium', 'label': 'Medium', 'bytes': 1530000000, 'memoryMb': 5120},
    {
      'id': 'large-v3',
      'label': 'Large v3',
      'bytes': 3100000000,
      'memoryMb': 10240,
    },
  ];

  Future<Directory> _modelDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}models');
  }

  @override
  Future<List<Map<String, dynamic>>> models() async {
    final root = await _modelDirectory();
    final results = <Map<String, dynamic>>[];
    for (final descriptor in _descriptors) {
      final directory = Directory('${root.path}/whisper/${descriptor['id']}');
      var installed = true;
      for (final filename in ['model.bin', 'config.json', 'tokenizer.json']) {
        if (!await File('${directory.path}/$filename').exists()) {
          installed = false;
          break;
        }
      }
      if (installed) {
        installed = await directory.list().any(
          (entry) =>
              entry is File &&
              entry.uri.pathSegments.last.startsWith('vocabulary.'),
        );
      }
      results.add({
        ...descriptor,
        'installed': installed,
        'path': directory.path,
      });
    }
    return results;
  }

  Future<(String, List<String>)> _invocation() async {
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final packaged = File(
      '${executableDirectory.path}/transcription_runtime/audiosubs_worker.exe',
    );
    if (!kDebugMode && await packaged.exists()) {
      return (packaged.path, <String>[]);
    }

    // flutter run may inherit the project root or start from a build directory.
    // Locate only our managed environment; never rely on PATH or a second app.
    final roots = <String>{};
    for (final startingDirectory in [Directory.current, executableDirectory]) {
      var directory = startingDirectory;
      for (var depth = 0; depth < 9; depth++) {
        roots.add(directory.path);
        final parent = directory.parent;
        if (parent.path == directory.path) break;
        directory = parent;
      }
    }
    for (final root in roots) {
      final python = File('$root/worker/.venv/Scripts/python.exe');
      final script = File('$root/worker/audiosubs_worker.py');
      if (await python.exists() && await script.exists()) {
        return (python.path, ['-u', script.path]);
      }
    }
    if (await packaged.exists()) return (packaged.path, <String>[]);
    throw StateError(
      'AudioSubs transcription runtime is missing. From the project root run '
      'powershell -ExecutionPolicy Bypass -File scripts/setup_windows_runtime.ps1 '
      '(requires Windows x64 Python 3.11 or 3.12), then rebuild. '
      'Release distributions must include the transcription_runtime folder.',
    );
  }

  @override
  Stream<Map<String, dynamic>> run(Map<String, dynamic> request) async* {
    if (_disposed || _running) {
      yield {
        'type': 'fileError',
        'message': _disposed
            ? 'Backend is disposed.'
            : 'Another operation is running.',
      };
      yield {'type': 'done', 'cancelled': false};
      return;
    }
    _running = true;
    _cancelRequested = false;
    Process? process;
    StreamSubscription<String>? stderrSubscription;
    var diagnostic = '';
    var receivedDone = false;
    Map<String, dynamic>? terminal;
    try {
      final root = await _modelDirectory();
      final invocation = await _invocation();
      if (_cancelRequested) throw StateError('Operation cancelled.');
      process = await Process.start(
        invocation.$1,
        invocation.$2,
        environment: {'PYTHONUTF8': '1', 'PYTHONUNBUFFERED': '1'},
      );
      _process = process;
      stderrSubscription = process.stderr.transform(utf8.decoder).listen((
        text,
      ) {
        diagnostic += text;
        if (diagnostic.length > 8192) {
          diagnostic = diagnostic.substring(diagnostic.length - 8192);
        }
      });
      process.stdin.writeln(
        jsonEncode({
          ...request,
          'modelDirectory': request['modelDirectory'] ?? root.path,
        }),
      );
      await process.stdin.flush();
      if (_cancelRequested) {
        process.stdin.writeln(jsonEncode({'operation': 'cancel'}));
        await process.stdin.flush();
      }
      await for (final line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map<String, dynamic> || decoded['type'] is! String) {
            throw const FormatException('Invalid worker event');
          }
          if (decoded['type'] == 'done') {
            receivedDone = true;
            terminal = decoded;
          } else {
            yield decoded;
          }
        } on FormatException catch (error) {
          yield {
            'type': 'fileError',
            'message': 'Worker protocol error: $error',
          };
        }
      }
      final exitCode = await process.exitCode;
      if (!receivedDone || exitCode != 0) {
        yield {
          'type': 'fileError',
          'message':
              'Transcription worker exited with code $exitCode.'
              '${diagnostic.trim().isEmpty ? '' : '\n${diagnostic.trim()}'}',
        };
      }
    } catch (error) {
      if (!_cancelRequested) {
        yield {'type': 'fileError', 'message': error.toString()};
      }
    } finally {
      if (process != null) {
        // A cancelled stream must also stop the native generator/download.
        // Keeping the supervisor alive lets it remove only this run's partials.
        if (!receivedDone) {
          try {
            process.stdin.writeln(jsonEncode({'operation': 'cancel'}));
            await process.stdin.flush();
          } on Object {
            // The process may already have exited.
          }
        }
        await process.exitCode;
        try {
          await process.stdin.close();
        } on Object {
          // The worker has already exited and may have closed its input pipe.
        }
      }
      await stderrSubscription?.cancel();
      _process = null;
      _running = false;
    }
    yield terminal ?? {'type': 'done', 'cancelled': _cancelRequested};
  }

  @override
  Future<void> cancel() async {
    _cancelRequested = true;
    final process = _process;
    if (process == null) return;
    try {
      process.stdin.writeln(jsonEncode({'operation': 'cancel'}));
      await process.stdin.flush();
    } on Object {
      // An operation can finish concurrently with cancellation.
    }
    await process.exitCode;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await cancel();
  }
}
