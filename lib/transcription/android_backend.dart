import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'backend.dart';

/// CPU-only, offline whisper.cpp inference. Model downloads are explicit.
class AndroidTranscriptionBackend extends TranscriptionBackend {
  static const _methods = MethodChannel('audiosubs/transcription');
  static const _events = EventChannel('audiosubs/transcription/events');
  StreamSubscription<dynamic>? _subscription;
  StreamController<Map<String, dynamic>>? _run;
  Completer<void>? _finished;
  int _sequence = 0;
  bool _disposed = false;
  bool _nativeStarted = false;

  Future<String> _modelDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/models');
    await directory.create(recursive: true);
    return directory.path;
  }

  @override
  Future<List<Map<String, dynamic>>> models() async {
    final result = await _methods.invokeListMethod<dynamic>('models', {
      'modelDirectory': await _modelDirectory(),
    });
    return (result ?? [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
  }

  void _finish({
    bool cancelled = false,
    String? error,
    Map<String, dynamic>? terminal,
  }) {
    final controller = _run;
    if (controller == null) return;
    _run = null;
    if (error != null) controller.add({'type': 'fileError', 'message': error});
    controller.add(
      terminal ??
          {
            'type': 'done',
            'cancelled': cancelled,
            if (error != null) 'message': 'Failed: $error',
          },
    );
    unawaited(controller.close());
    _finished?.complete();
  }

  Future<void> _start(Map<String, dynamic> request, int id) async {
    try {
      _subscription ??= _events.receiveBroadcastStream().listen(
        (dynamic event) {
          final map = Map<String, dynamic>.from(event as Map);
          if (map.remove('runId') != _sequence || _run == null) return;
          if (map['type'] == 'done') {
            _finish(cancelled: map['cancelled'] == true, terminal: map);
          } else {
            _run!.add(map);
          }
        },
        onError: (Object error) {
          _finish(error: error.toString());
        },
        onDone: () {
          _finish(error: 'Android transcription event channel closed.');
        },
      );
      final directory = await _modelDirectory();
      if (_run == null || id != _sequence) return;
      _nativeStarted = true;
      await _methods.invokeMethod<void>('start', {
        ...request,
        'modelDirectory': directory,
        'runId': id,
      });
    } catch (error) {
      if (id == _sequence) _finish(error: error.toString());
    }
  }

  @override
  Stream<Map<String, dynamic>> run(Map<String, dynamic> request) {
    if (_disposed || _run != null) {
      return Stream.fromIterable([
        {
          'type': 'fileError',
          'message': _disposed
              ? 'Backend is disposed.'
              : 'A transcription job is already running.',
        },
        {'type': 'done', 'cancelled': false},
      ]);
    }
    final id = ++_sequence;
    _nativeStarted = false;
    _finished = Completer<void>();
    final controller = StreamController<Map<String, dynamic>>();
    _run = controller;
    controller.onListen = () => unawaited(_start(request, id));
    controller.onCancel = () => cancel();
    return controller.stream;
  }

  @override
  Future<void> cancel() async {
    if (_run == null) return;
    if (!_nativeStarted) {
      _finish(cancelled: true);
    } else {
      await _methods.invokeMethod<void>('cancel', {'runId': _sequence});
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await cancel();
    if (_run != null) await _finished!.future;
    await _methods.invokeMethod<void>('dispose');
    await _subscription?.cancel();
    _subscription = null;
  }
}
