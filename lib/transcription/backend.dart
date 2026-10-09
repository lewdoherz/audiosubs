abstract class TranscriptionBackend {
  /// Model descriptors: id, label, bytes, memoryMb, installed, path.
  Future<List<Map<String, dynamic>>> models();

  /// Requests: operation ('download'|'transcribe'), model, sourceLanguage
  /// ('auto' or ISO code), targetLanguage (null or ISO code), bilingual,
  /// device ('cpu'|'cuda'|'auto'), computeType ('int8'|'float16'|'float32'),
  /// files [{audio, outputBase}], modelDirectory.
  /// Events: type ('status'|'progress'|'output'|'fileError'|'done'), message,
  /// audio, progress (0..1), path, kind ('original'|'translated'|'bilingual'),
  /// language, cancelled. A terminal done event must always be emitted.
  Stream<Map<String, dynamic>> run(Map<String, dynamic> request);
  Future<void> cancel();
  Future<void> dispose();
}
