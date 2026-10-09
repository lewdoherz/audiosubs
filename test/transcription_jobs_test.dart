import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_player/transcription/backend.dart';
import 'package:audiobook_player/transcription/jobs.dart';

class ControlledBackend extends TranscriptionBackend {
  final stream = StreamController<Map<String, dynamic>>();
  final started = Completer<void>();
  final cancelled = Completer<void>();
  @override
  Future<List<Map<String, dynamic>>> models() async => [];
  @override
  Stream<Map<String, dynamic>> run(Map<String, dynamic> request) {
    started.complete();
    return stream.stream;
  }

  @override
  Future<void> cancel() async {
    cancelled.complete();
  }

  @override
  Future<void> dispose() async {
    await stream.close();
  }
}

void main() {
  test('job rejects concurrent work, preserves completed output after cancellation', () async {
    final dir = await Directory.systemTemp.createTemp('audiosubs-job-');
    addTearDown(() => dir.delete(recursive: true));
    final audio = File('${dir.path}/book.wav');
    await audio.create();
    final backend = ControlledBackend();
    final jobs = TranscriptionJobs(backend);
    final observed = <String>[];
    final subscription = jobs.outputs.stream.listen(
      (event) => observed.add(event['path'] as String),
    );
    final run = jobs.start(
      {'operation': 'transcribe'},
      [audio.path],
      support: dir,
      persist: false,
    );
    await backend.started.future;
    expect(jobs.busy, true);
    await expectLater(jobs.start({}, [], persist: false), throwsStateError);
    final complete = File('${dir.path}/book.srt');
    await complete.writeAsString(
      '1\n00:00:00,000 --> 00:00:01,000\nCompleted\n',
    );
    backend.stream.add({
      'type': 'output',
      'path': complete.path,
      'audio': audio.path,
      'kind': 'original',
    });
    await jobs.cancel();
    await backend.cancelled.future;
    expect(jobs.cancelling, true);
    backend.stream.add({'type': 'done', 'cancelled': true});
    await backend.stream.close();
    await run;
    expect(jobs.busy, false);
    expect(jobs.cancelling, false);
    expect(jobs.message, contains('completed outputs preserved'));
    expect(await complete.readAsString(), contains('Completed'));
    expect(observed, [complete.path]);
    await subscription.cancel();
    jobs.dispose();
  });

  test('file errors remain visible when later file succeeds', () async {
    final backend = ControlledBackend();
    final jobs = TranscriptionJobs(backend);
    final run = jobs.start({'operation': 'transcribe'}, [], persist: false);
    await backend.started.future;
    backend.stream.add({
      'type': 'fileError',
      'audio': 'bad.mp3',
      'message': 'Unsupported codec',
    });
    backend.stream.add({
      'type': 'output',
      'audio': 'good.wav',
      'path': 'good.srt',
      'kind': 'original',
    });
    backend.stream.add({
      'type': 'done',
      'message': 'Completed with 1 file error',
    });
    await backend.stream.close();
    await run;
    expect(
      jobs.events.where((e) => e['type'] == 'fileError').single['message'],
      'Unsupported codec',
    );
    expect(jobs.currentFile, 'good.wav');
    expect(jobs.message, 'Completed with 1 file error');
    expect(jobs.busy, false);
    jobs.dispose();
  });

  test(
    'unexpected worker exit ends job as failure rather than success',
    () async {
      final backend = ControlledBackend();
      final jobs = TranscriptionJobs(backend);
      final run = jobs.start({}, [], persist: false);
      await backend.started.future;
      await backend.stream.close();
      await run;
      expect(jobs.busy, false);
      expect(jobs.message, contains('without a completion event'));
      expect(jobs.events.where((e) => e['type'] == 'fileError'), hasLength(1));
      jobs.dispose();
    },
  );
}
