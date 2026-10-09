"""Deterministic safety tests: no model downloads, GPU, or audio fixtures needed.
Run: worker/.venv/Scripts/python.exe -m unittest discover -s worker -p test_*.py
"""
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import tempfile
import time
import types
import unittest
from unittest.mock import patch

import audiosubs_worker as worker


def cancellable_child(request_file):
    # Native child stdin must be disconnected even while the supervisor's
    # Flutter JSONL stdin pipe remains open.
    assert sys.stdin.read() == ""
    envelope = json.loads(Path(request_file).read_text(encoding="utf-8"))
    request, root, token = envelope["request"], envelope["root"], envelope["token"]
    directory = Path(request["files"][0]["outputBase"]).parent
    (directory / f".audiosubs-{token}-test.part").write_text("partial", encoding="utf-8")
    (directory / "completed.srt").write_text("completed", encoding="utf-8")
    stage = Path(root) / f".download-{token}"
    stage.mkdir()
    (stage / "partial.bin").write_bytes(b"partial")
    print(json.dumps({"type": "status", "message": "ready"}), flush=True)
    while True:
        time.sleep(0.05)


class FakeModel:
    def transcribe(self, samples, **kwargs):
        return iter([types.SimpleNamespace(start=1.0, end=2.5, text=" Hola ")]), types.SimpleNamespace(language="es")


class WorkerSafetyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.events = []

    def tearDown(self):
        self.directory.cleanup()

    def item(self, name="book"):
        return {"audio": str(self.root / f"{name}.mp3"), "outputBase": str(self.root / name)}

    def transcribe(self, request, chunks=None):
        with patch.object(worker, "audio_chunks", return_value=iter(chunks or [(None, 0.0, 10.0)])):
            worker.transcribe_file(FakeModel(), self.item(), request, self.root, "testtoken", self.events.append)

    def test_existing_subtitles_are_not_replaced(self):
        existing = self.root / "book.srt"
        existing.write_text("keep me", encoding="utf-8")
        self.transcribe({"sourceLanguage": "auto"})
        self.assertEqual(existing.read_text(encoding="utf-8"), "keep me")
        self.assertFalse(any(event["type"] == "output" for event in self.events))
        self.assertFalse(list(self.root.glob("*.part")))

    def test_auto_source_and_bilingual_timestamps(self):
        with patch.object(worker, "get_translator", return_value=lambda text: "Hello") as translator:
            self.transcribe({"sourceLanguage": "auto", "targetLanguage": "en", "bilingual": True},
                            [(None, 60.0, 120.0)])
        translator.assert_called_once_with(self.root, "es", "en")
        expected = "1\n00:01:01,000 --> 00:01:02,500\nHola\nHello\n\n"
        self.assertEqual((self.root / "book.es-en.srt").read_text(encoding="utf-8"), expected)
        output = [event for event in self.events if event["type"] == "output"]
        self.assertEqual({event["kind"] for event in output}, {"original", "translated", "bilingual"})
        self.assertEqual(next(event["language"] for event in output if event["kind"] == "original"), "es")

    def test_missing_pair_keeps_completed_original(self):
        self.transcribe({"sourceLanguage": "auto", "targetLanguage": "en", "bilingual": True})
        self.assertTrue((self.root / "book.srt").exists())
        self.assertFalse((self.root / "book.en.srt").exists())
        self.assertTrue(any("es → en" in event.get("message", "") for event in self.events))
        self.assertFalse(list(self.root.glob(".audiosubs-*.part")))

    def test_decoder_error_does_not_publish_partial(self):
        def failing_chunks():
            yield None, 0.0, 10.0
            raise IOError("corrupt audio")
        with patch.object(worker, "audio_chunks", return_value=failing_chunks()):
            with self.assertRaisesRegex(IOError, "corrupt audio"):
                worker.transcribe_file(FakeModel(), self.item(), {}, self.root, "testtoken", self.events.append)
        self.assertFalse((self.root / "book.srt").exists())
        self.assertFalse(list(self.root.glob(".audiosubs-*.part")))

    def test_atomic_publication_loses_race_without_replacing(self):
        output = worker.Output(self.root / "race.srt", "testtoken", "original", "en")
        output.cue(1, 0, 1, "new")
        output.path.write_text("winner", encoding="utf-8")
        self.assertFalse(output.publish())
        self.assertEqual(output.path.read_text(encoding="utf-8"), "winner")
        self.assertFalse(output.temp.exists())

    def test_download_translation_requires_explicit_source(self):
        with patch.object(worker, "json_url") as network:
            with self.assertRaisesRegex(ValueError, "known source"):
                worker.download_models({"model": "tiny", "sourceLanguage": "auto", "targetLanguage": "en"},
                                       self.root, "testtoken", self.events.append)
        network.assert_not_called()

    def test_file_error_continues_to_next_file(self):
        model_path = self.root / "whisper" / "tiny"
        model_path.mkdir(parents=True)
        for filename in (*worker.REQUIRED_MODEL_FILES, "vocabulary.json"):
            (model_path / filename).write_text("{}", encoding="utf-8")
        fake_ct2 = types.SimpleNamespace(get_supported_compute_types=lambda device: {"int8"})
        fake_whisper = types.SimpleNamespace(WhisperModel=lambda *args, **kwargs: object())
        request = {"operation": "transcribe", "model": "tiny", "files": [self.item("bad"), self.item("good")]}
        with patch.dict("sys.modules", {"ctranslate2": fake_ct2, "faster_whisper": fake_whisper}), \
             patch.object(worker.socket.socket, "connect"), patch.object(worker.socket.socket, "connect_ex"), \
             patch.dict(worker.os.environ), \
             patch.object(worker, "transcribe_file", side_effect=[IOError("broken file"), None]) as transcribe:
            worker.execute(request, self.root, "testtoken", self.events.append)
        self.assertEqual(transcribe.call_count, 2)
        self.assertEqual(next(event["audio"] for event in self.events if event["type"] == "fileError"), self.item("bad")["audio"])

    def test_cancellation_terminates_child_and_cleans_only_partials(self):
        commands = queue.Queue()
        def emit(event):
            self.events.append(event)
            if event.get("message") == "ready":
                commands.put({"operation": "cancel"})
        request = {"modelDirectory": str(self.root / "models"), "files": [self.item()]}
        with patch.object(worker, "child_command", side_effect=lambda path:
                          [sys.executable, "-u", str(Path(__file__).resolve()), "--test-child", str(path)]):
            worker.supervise(request, commands, emit)
        self.assertEqual((self.root / "completed.srt").read_text(encoding="utf-8"), "completed")
        self.assertFalse(list(self.root.glob(".audiosubs-*.part")))
        self.assertFalse(list((self.root / "models").glob(".download-*")))
        self.assertFalse(list((self.root / "models").glob(".request-*")))
        self.assertEqual(self.events[-1], {"type": "done", "cancelled": True})

    def test_child_protocol_isolates_python_and_native_stdout(self):
        request_file = self.root / "request.json"
        request_file.write_text(json.dumps({"request": {}, "root": str(self.root), "token": "test"}),
                                encoding="utf-8")
        result = subprocess.run(
            [sys.executable, "-u", str(Path(__file__).resolve()), "--test-protocol-child", str(request_file)],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, encoding="utf-8", timeout=15)
        self.assertEqual(result.returncode, 0)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(events, [{"type": "status", "message": "real event"}, {"type": "_finished"}])
        self.assertIn("Python library log", result.stderr)
        self.assertIn("Native library log", result.stderr)

    def test_supervisor_finishes_with_live_stdin_pipe(self):
        process = subprocess.Popen(
            [sys.executable, "-u", str(Path(worker.__file__).resolve())],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8")
        received = queue.Queue()
        def collect():
            for line in process.stdout:
                received.put(json.loads(line))
        reader = threading.Thread(target=collect, daemon=True)
        reader.start()
        try:
            process.stdin.write(json.dumps({
                "operation": "download", "model": "tiny", "sourceLanguage": "auto",
                "targetLanguage": "es", "modelDirectory": str(self.root / "models")}) + "\n")
            process.stdin.flush()
            # Do not communicate/close stdin: that hid the packaged spawn bug.
            events = []
            while not events or events[-1]["type"] != "done":
                events.append(received.get(timeout=15))
            self.assertEqual(sum(event["type"] == "done" for event in events), 1)
            self.assertTrue(any("known source" in event.get("message", "") for event in events))
            self.assertEqual(process.wait(timeout=10), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            reader.join(timeout=2)
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()

    def test_cleanup_preserves_other_runs(self):
        current = self.root / ".audiosubs-current-a.part"
        other = self.root / ".audiosubs-other-a.part"
        current.touch()
        other.touch()
        worker.cleanup({"files": [self.item()]}, self.root / "models", "current")
        self.assertFalse(current.exists())
        self.assertTrue(other.exists())


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--test-child":
        cancellable_child(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "--test-protocol-child":
        def execute_with_library_logs(request, root, token, emit):
            print("Python library log")
            worker.os.write(1, b"Native library log\n")
            emit({"type": "status", "message": "real event"})
        with patch.object(worker, "execute", side_effect=execute_with_library_logs):
            worker.child_main(sys.argv[2])
    else:
        unittest.main()
