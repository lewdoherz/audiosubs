import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../subtitle_files.dart';
import 'backend.dart';
import 'windows_backend.dart';
import 'android_backend.dart';

final transcriptionJobs = TranscriptionJobs(
  Platform.isAndroid
      ? AndroidTranscriptionBackend()
      : WindowsTranscriptionBackend(),
);

class TranscriptionJobs extends ChangeNotifier {
  final TranscriptionBackend backend;
  TranscriptionJobs(this.backend);
  bool busy = false;
  bool cancelling = false;
  String message = 'Ready';
  String? currentFile;
  double? progress;
  int errorCount = 0;
  final List<Map<String, dynamic>> events = [];
  final outputs = StreamController<Map<String, dynamic>>.broadcast();
  List<Map<String, dynamic>> modelList = [];

  Future<void> refreshModels() async {
    modelList = await backend.models();
    notifyListeners();
  }

  Future<void> start(
    Map<String, dynamic> options,
    List<String> audioFiles, {
    Directory? support,
    bool persist = true,
  }) async {
    if (busy) throw StateError('A job is already running');
    busy = true;
    cancelling = false;
    progress = null;
    currentFile = null;
    errorCount = 0;
    message = 'Preparing job';
    events.clear();
    notifyListeners();
    var terminal = false;
    try {
      final files = <Map<String, String>>[];
      for (final audio in audioFiles.toSet()) {
        if (cancelling) break;
        files.add({
          'audio': audio,
          'outputBase': await outputBaseForAudio(audio, support: support),
        });
      }
      if (cancelling) {
        _receive(
          {'type': 'done', 'cancelled': true, 'message': 'Cancelled'},
          persist: persist,
          support: support,
        );
        terminal = true;
      } else {
        await for (final event in backend.run({...options, 'files': files})) {
          _receive(event, persist: persist, support: support);
          if (event['type'] == 'done') terminal = true;
        }
      }
      if (!terminal) {
        throw StateError(
          'Transcription backend stopped without a completion event',
        );
      }
    } catch (error) {
      _receive(
        {'type': 'fileError', 'message': '$error', 'audio': currentFile},
        persist: persist,
        support: support,
      );
      _receive(
        {'type': 'done', 'message': 'Failed: $error', 'cancelled': cancelling},
        persist: persist,
        support: support,
      );
    } finally {
      busy = false;
      cancelling = false;
      notifyListeners();
      try {
        await refreshModels();
      } catch (_) {
        /* Job errors already remain visible. */
      }
    }
  }

  void _receive(
    Map<String, dynamic> event, {
    required bool persist,
    Directory? support,
  }) {
    if (event['audio'] is String) {
      if (currentFile != event['audio']) progress = null;
      currentFile = event['audio'] as String;
    }
    if (event['type'] == 'fileError') errorCount++;
    if (event['message'] is String) message = event['message'] as String;
    if (event['progress'] is num) {
      progress = (event['progress'] as num).toDouble().clamp(0, 1);
    }
    if (event['type'] == 'done') {
      message = event['cancelled'] == true
          ? 'Cancelled — completed outputs preserved'
          : (event['message'] as String? ??
                (errorCount > 0
                    ? 'Completed with $errorCount error(s)'
                    : 'Completed'));
      progress = null;
    }
    if (event['type'] == 'output') outputs.add(event);
    if (event['type'] != 'progress') {
      events.add(Map.of(event));
      if (events.length > 300) events.removeAt(0);
      if (persist) {
        _journal = _journal
            .then((_) => _appendJournal(event, support))
            .catchError((Object error) {
              message = 'Job history could not be saved: $error';
              notifyListeners();
            });
      }
    }
    notifyListeners();
  }

  Future<void> _journal = Future.value();
  Future<void> _appendJournal(
    Map<String, dynamic> event,
    Directory? support,
  ) async {
    support ??= await getApplicationSupportDirectory();
    await support.create(recursive: true);
    await File('${support.path}/transcription-history.jsonl').writeAsString(
      '${jsonEncode({...event, 'time': DateTime.now().toIso8601String()})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<void> loadHistory() async {
    final support = await getApplicationSupportDirectory();
    final file = File('${support.path}/transcription-history.jsonl');
    if (!await file.exists()) return;
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      try {
        events.add((jsonDecode(line) as Map).cast<String, dynamic>());
        if (events.length > 300) events.removeAt(0);
      } on FormatException {
        /* Interrupted final journal line is not an output. */
      }
    }
    notifyListeners();
  }

  Future<void> cancel() async {
    if (!busy || cancelling) return;
    cancelling = true;
    message = 'Cancelling — waiting for worker to stop safely';
    notifyListeners();
    await backend.cancel();
  }

  @override
  void dispose() {
    unawaited(backend.dispose());
    unawaited(outputs.close());
    super.dispose();
  }
}
