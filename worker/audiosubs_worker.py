"""One JSONL request per process; a supervisor can interrupt native inference.

stdout is protocol-only. Heavy work runs in a killable child. Translation uses
installed Argos package tokenizers and CTranslate2 directly, one timed cue at a
time, avoiding sentence-detector downloads and an unbounded translation cache.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
import zipfile

MODELS = {"tiny", "base", "small", "medium", "large-v3"}
REQUIRED_MODEL_FILES = ("model.bin", "config.json", "tokenizer.json")


def model_ready(path):
    return all((Path(path) / name).is_file() for name in REQUIRED_MODEL_FILES) and any(
        Path(path).glob("vocabulary.*"))


def language(value, allow_auto=False):
    if allow_auto and value == "auto":
        return value
    if not isinstance(value, str) or not re.fullmatch(r"[a-z]{2,3}(?:-[A-Za-z]{2,4})?", value):
        raise ValueError("Choose an explicit source/target language code, for example en or es.")
    return value


def timestamp(seconds):
    millis = max(0, round(seconds * 1000))
    hours, millis = divmod(millis, 3600000)
    minutes, millis = divmod(millis, 60000)
    seconds, millis = divmod(millis, 1000)
    return f"{hours:02}:{minutes:02}:{seconds:02},{millis:03}"


class Output:
    def __init__(self, path, token, kind, language_code):
        self.path = Path(path)
        self.kind = kind
        self.language = language_code
        self.temp = self.path.parent / f".audiosubs-{token}-{uuid.uuid4().hex}.part"
        self.file = None if self.path.exists() else self.temp.open("x", encoding="utf-8", newline="\n")

    def cue(self, index, start, end, text):
        if self.file is not None:
            self.file.write(f"{index}\n{timestamp(start)} --> {timestamp(end)}\n{text.strip()}\n\n")

    def abort(self):
        if self.file is not None:
            self.file.close()
            self.file = None
        self.temp.unlink(missing_ok=True)

    def publish(self):
        if self.file is None:
            return False
        self.file.flush()
        os.fsync(self.file.fileno())
        self.file.close()
        self.file = None
        try:
            # Hard-link publication is atomic and fails if a destination exists.
            # On Windows rename also refuses replacement; use it for filesystems
            # without hard-link support (e.g. removable FAT/exFAT volumes).
            try:
                os.link(self.temp, self.path)
            except FileExistsError:
                return False
            except OSError:
                if os.name != "nt":
                    raise
                try:
                    os.rename(self.temp, self.path)
                except FileExistsError:
                    return False
            return True
        finally:
            self.temp.unlink(missing_ok=True)


def download_file(url, destination, emit, label, before=0, total=0):
    if urllib.parse.urlparse(url).scheme != "https":
        raise ValueError("Model downloads must use HTTPS.")
    request = urllib.request.Request(url, headers={"User-Agent": "AudioSubs/1"})
    with urllib.request.urlopen(request, timeout=45) as response, Path(destination).open("xb") as output:
        expected = int(response.headers.get("Content-Length", "0"))
        received = 0
        last_event = 0.0
        while True:
            block = response.read(256 * 1024)
            if not block:
                break
            output.write(block)
            received += len(block)
            now = time.monotonic()
            if now - last_event > 0.2:
                denominator = total or expected
                emit({"type": "progress", "message": label,
                      "progress": min(1.0, (before + received) / denominator) if denominator else 0.0,
                      "bytes": before + received})
                last_event = now
        if expected and received != expected:
            raise IOError(f"Incomplete download: {received} of {expected} bytes")
        output.flush()
        os.fsync(output.fileno())
    return received


def json_url(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "AudioSubs/1"}), timeout=45) as response:
        return json.load(response)


def download_models(request, root, token, emit):
    source = language(request.get("sourceLanguage", "auto"), allow_auto=True)
    target = request.get("targetLanguage")
    if target:
        target = language(target)
        if source == "auto":
            raise ValueError("Translation download needs a known source language. Select a source language, download its pair, then return to Auto detection if desired.")
    model = request.get("model", "base")
    if model not in MODELS:
        raise ValueError(f"Unknown Whisper model: {model}")
    staging = root / f".download-{token}"
    staging.mkdir(parents=True)
    final = root / "whisper" / model
    if model_ready(final):
        emit({"type": "status", "message": f"Whisper {model} is already installed."})
    else:
        if final.exists():
            raise ValueError(f"Incomplete model directory {final}. Remove it before downloading again.")
        emit({"type": "status", "message": f"Downloading Whisper {model} explicitly…"})
        repo = f"Systran/faster-whisper-{model}"
        metadata = json_url(f"https://huggingface.co/api/models/{repo}?blobs=true")
        revision = metadata["sha"]
        names = [entry for entry in metadata["siblings"] if entry["rfilename"] in
                 (*REQUIRED_MODEL_FILES, "preprocessor_config.json") or
                 entry["rfilename"].startswith("vocabulary.")]
        whisper_stage = staging / "whisper"
        whisper_stage.mkdir()
        total = sum(entry.get("size", 0) for entry in names)
        received = 0
        for entry in names:
            filename = entry["rfilename"]
            received += download_file(f"https://huggingface.co/{repo}/resolve/{revision}/{filename}",
                                      whisper_stage / filename, emit, f"Whisper {model}: {filename}", received, total)
        if not model_ready(whisper_stage):
            raise ValueError("Downloaded Whisper model is missing required local inference files.")
        final.parent.mkdir(parents=True, exist_ok=True)
        os.rename(whisper_stage, final)
        emit({"type": "status", "message": f"Whisper {model} installed."})
    if target and target != source:
        packages = root / "argos" / "packages"
        if find_argos_package(packages, source, target) is not None:
            emit({"type": "status", "message": f"Argos {source} → {target} already installed."})
        else:
            emit({"type": "status", "message": f"Downloading Argos {source} → {target} explicitly…"})
            index = json_url("https://raw.githubusercontent.com/argosopentech/argospm-index/main/index.json")
            entry = next((item for item in index if item.get("from_code") == source and
                          item.get("to_code") == target and item.get("type", "translate") == "translate"), None)
            if not entry:
                raise ValueError(f"No direct Argos package is available for {source} → {target}.")
            archive = staging / "translation.argosmodel"
            # Mirrors are tried only during the explicit download operation.
            failure = None
            for link in entry["links"]:
                try:
                    download_file(link, archive, emit, f"Argos {source} → {target}")
                    failure = None
                    break
                except Exception as error:
                    archive.unlink(missing_ok=True)
                    failure = error
            if failure or not archive.exists():
                raise IOError(f"Argos download failed: {failure or 'no download URL'}")
            extracted = staging / "argos"
            extracted.mkdir()
            with zipfile.ZipFile(archive) as zipped:
                for member in zipped.infolist():
                    destination = (extracted / member.filename).resolve()
                    if not destination.is_relative_to(extracted.resolve()):
                        raise ValueError("Unsafe path in Argos package archive.")
                zipped.extractall(extracted)
            package_path = find_argos_package(extracted, source, target)
            if package_path is None or not (package_path / "model" / "model.bin").is_file():
                raise ValueError("Downloaded Argos package does not contain the requested model.")
            packages.mkdir(parents=True, exist_ok=True)
            final_package = packages / f"{source}_{target}"
            if final_package.exists():
                raise ValueError(f"Incomplete Argos package {final_package}. Remove it before retrying.")
            os.rename(package_path, final_package)
            emit({"type": "status", "message": f"Argos {source} → {target} installed."})
    emit({"type": "progress", "progress": 1.0, "message": "Requested models are ready."})


def find_argos_package(directory, source, target):
    directory = Path(directory)
    if not directory.exists():
        return None
    for metadata_path in directory.glob("*/metadata.json"):
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        if metadata.get("from_code") == source and metadata.get("to_code") == target:
            path = metadata_path.parent
            if (path / "model" / "model.bin").is_file():
                return path
    return None


def get_translator(root, source, target):
    if source == target:
        return lambda text: text
    path = find_argos_package(root / "argos" / "packages", source, target)
    if path is None:
        raise ValueError(f"Offline Argos package {source} → {target} is missing. Select source {source} and target {target}, then Download models before retrying. No packages are downloaded during transcription.")
    from argostranslate.package import Package
    import ctranslate2
    package = Package(path)
    translator = ctranslate2.Translator(str(path / "model"), device="cpu", compute_type="int8")

    def translate(text):
        prefix = getattr(package, "target_prefix", "")
        result = translator.translate_batch(
            [package.tokenizer.encode(text)], target_prefix=[[prefix]] if prefix else None,
            replace_unknowns=True, beam_size=4, num_hypotheses=1, length_penalty=0.2)
        value = package.tokenizer.decode(result[0].hypotheses[0])
        return value.removeprefix(prefix).strip() if prefix else value.strip()
    return translate


def audio_chunks(path, seconds=60):
    """Decode/resample incrementally; never materialize an audiobook in memory."""
    import av
    import numpy as np
    size = seconds * 16000
    buffer = np.empty(size, dtype=np.float32)
    used = 0
    offset = 0.0
    with av.open(str(path)) as container:
        if not container.streams.audio:
            raise ValueError("No audio stream found.")
        stream = container.streams.audio[0]
        duration = float(stream.duration * stream.time_base) if stream.duration is not None else (
            container.duration / av.time_base if container.duration else 0.0)
        resampler = av.AudioResampler(format="fltp", layout="mono", rate=16000)
        def frames():
            for frame in container.decode(stream):
                yield from resampler.resample(frame)
            yield from resampler.resample(None)
        for frame in frames():
            samples = frame.to_ndarray().reshape(-1)
            position = 0
            while position < len(samples):
                count = min(size - used, len(samples) - position)
                buffer[used:used + count] = samples[position:position + count]
                used += count
                position += count
                if used == size:
                    yield buffer, offset, duration
                    offset += used / 16000
                    used = 0
        if used:
            yield buffer[:used], offset, duration


def transcribe_file(model, item, request, root, token, emit):
    audio = str(item["audio"])
    base = str(item["outputBase"])
    target = request.get("targetLanguage")
    source = request.get("sourceLanguage", "auto")
    outputs = []
    translation_outputs = []
    translation_error = None
    translator = None
    cue_count = 0
    try:
        original = Output(f"{base}.srt", token, "original", source)
        outputs.append(original)
        chunks = audio_chunks(audio)
        for samples, offset, duration in chunks:
            segments, info = model.transcribe(samples, language=None if source == "auto" else source,
                                             beam_size=5, vad_filter=True)
            if source == "auto":
                source = info.language
            if original.language == "auto":
                original.language = source
            if target and translator is None and translation_error is None:
                try:
                    translator = get_translator(root, source, target)
                    translated_path = f"{base}.{target}.srt"
                    # source == target still has an explicit translated artifact.
                    translated = Output(translated_path, token, "translated", target)
                    translation_outputs.append(translated)
                    outputs.append(translated)
                    if request.get("bilingual"):
                        bilingual = Output(f"{base}.{source}-{target}.srt", token, "bilingual", f"{source}-{target}")
                        translation_outputs.append(bilingual)
                        outputs.append(bilingual)
                except Exception as error:
                    translation_error = str(error)
                    for output in translation_outputs:
                        output.abort()
                    emit({"type": "fileError", "audio": audio, "message": translation_error})
            for segment in segments:
                text = segment.text.strip()
                if not text:
                    continue
                cue_count += 1
                start, end = offset + segment.start, offset + segment.end
                original.cue(cue_count, start, end, text)
                if translator and not translation_error:
                    try:
                        translated_text = translator(text)
                        for output in translation_outputs:
                            output.cue(cue_count, start, end, text + "\n" + translated_text if output.kind == "bilingual" else translated_text)
                    except Exception as error:
                        translation_error = str(error)
                        for output in translation_outputs:
                            output.abort()
                        emit({"type": "fileError", "audio": audio, "message": f"Translation failed: {error}"})
                emit({"type": "progress", "audio": audio, "language": source,
                      "progress": min(1.0, end / duration) if duration else 0.0,
                      "message": f"{Path(audio).name}: {timestamp(end)} ({source})"})
        if not cue_count:
            raise ValueError("No speech was detected; no empty subtitle file was published.")
        for output in outputs:
            if output in translation_outputs and translation_error:
                continue
            if output.publish():
                emit({"type": "output", "audio": audio, "path": str(output.path),
                      "kind": output.kind, "language": output.language})
            elif output.path.exists():
                emit({"type": "status", "audio": audio, "message": f"Kept existing output: {output.path}"})
        emit({"type": "progress", "audio": audio, "progress": 1.0})
    finally:
        for output in outputs:
            output.abort()


def offline_connect(*args, **kwargs):
    raise OSError("Network access is disabled during offline transcription.")


def execute(request, root, token, emit):
    os.environ.update({"ARGOS_PACKAGES_DIR": str(root / "argos" / "packages"),
                       "XDG_DATA_HOME": str(root / "argos" / "data"),
                       "XDG_CACHE_HOME": str(root / "argos" / "cache"),
                       "XDG_CONFIG_HOME": str(root / "argos" / "config"),
                       "ARGOS_DEVICE_TYPE": "cpu", "ARGOS_MODEL_PROVIDER": "OPENNMT"})
    operation = request.get("operation")
    if operation == "download":
        download_models(request, root, token, emit)
        return
    if operation != "transcribe":
        raise ValueError(f"Unknown worker operation: {operation}")
    os.environ.update({"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"})
    socket.socket.connect = offline_connect
    socket.socket.connect_ex = offline_connect
    model_id = request.get("model", "base")
    if model_id not in MODELS:
        raise ValueError(f"Unknown Whisper model: {model_id}")
    path = root / "whisper" / model_id
    if not model_ready(path):
        raise ValueError(f"Whisper {model_id} is not installed. Use Download models first.")
    language(request.get("sourceLanguage", "auto"), allow_auto=True)
    if request.get("targetLanguage"):
        language(request["targetLanguage"])
    device = request.get("device", "cpu")
    compute = request.get("computeType", "int8")
    if device not in {"cpu", "cuda", "auto"} or compute not in {"int8", "float16", "float32"}:
        raise ValueError("Unsupported device or compute type.")
    import ctranslate2
    from faster_whisper import WhisperModel
    try:
        if device == "auto":
            device = "cuda" if ctranslate2.get_cuda_device_count() else "cpu"
        supported = ctranslate2.get_supported_compute_types(device)
    except Exception as error:
        if request.get("device") != "auto":
            raise
        emit({"type": "status", "message": f"CUDA detection unavailable ({error}); using CPU int8."})
        device, compute = "cpu", "int8"
        supported = ctranslate2.get_supported_compute_types(device)
    if compute not in supported:
        if request.get("device") == "auto" and device == "cpu":
            emit({"type": "status", "message": f"{compute} unavailable on CPU; Auto selected CPU int8."})
            compute = "int8"
        else:
            raise ValueError(f"{compute} is unsupported on {device}. Choose int8 or float32 for CPU; CUDA float16 requires a compatible NVIDIA GPU and CUDA runtime.")
    emit({"type": "status", "message": f"Loading local Whisper {model_id} on {device} ({compute})…"})
    try:
        model = WhisperModel(str(path), device=device, compute_type=compute, local_files_only=True)
    except Exception as error:
        if request.get("device") != "auto" or device != "cuda":
            raise
        emit({"type": "status", "message": f"CUDA unavailable ({error}); using CPU int8."})
        model = WhisperModel(str(path), device="cpu", compute_type="int8", local_files_only=True)
    for item in request.get("files", []):
        audio = str(item.get("audio", ""))
        emit({"type": "status", "audio": audio, "message": f"Transcribing {Path(audio).name} offline…"})
        try:
            transcribe_file(model, item, request, root, token, emit)
        except Exception as error:
            emit({"type": "fileError", "audio": audio, "message": str(error)})


def child_main(request_file):
    envelope = json.loads(Path(request_file).read_text(encoding="utf-8"))
    # Keep a private JSONL descriptor before redirecting native stdout to stderr.
    # Unlike multiprocessing, this ordinary subprocess never duplicates handles
    # from a remote parent process or inherits the parent's live stdin pipe.
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8",
                         errors="strict", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    sys.stdout = sys.stderr
    def emit(event):
        protocol.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
        protocol.flush()
    try:
        execute(envelope["request"], Path(envelope["root"]), envelope["token"], emit)
    except Exception as error:
        emit({"type": "fileError", "message": str(error)})
    finally:
        emit({"type": "_finished"})
        protocol.close()


def cleanup(request, root, token):
    shutil.rmtree(Path(root) / f".download-{token}", ignore_errors=True)
    directories = {Path(item["outputBase"]).parent for item in request.get("files", []) if "outputBase" in item}
    for directory in directories:
        for partial in directory.glob(f".audiosubs-{token}-*.part"):
            try:
                partial.unlink(missing_ok=True)
            except OSError:
                pass


def child_command(request_file):
    if getattr(sys, "frozen", False):
        return [sys.executable, "--child", str(request_file)]
    return [sys.executable, "-u", str(Path(__file__).resolve()), "--child", str(request_file)]


def supervise(request, command_queue, emit):
    root = Path(request["modelDirectory"]).resolve()
    root.mkdir(parents=True, exist_ok=True)
    token = uuid.uuid4().hex
    request_file = root / f".request-{token}.json"
    events = queue.Queue(maxsize=128)
    stopped = threading.Event()
    child = None
    reader = None
    cancelled = False
    finished = False
    def enqueue(event):
        while not stopped.is_set():
            try:
                events.put(event, timeout=0.05)
                return
            except queue.Full:
                pass
    def read_events():
        try:
            for line in child.stdout:
                if not line.strip():
                    continue
                event = json.loads(line)
                if not isinstance(event, dict) or not isinstance(event.get("type"), str):
                    raise ValueError("Invalid child event")
                enqueue(event)
        except Exception as error:
            enqueue({"type": "fileError", "message": f"Child protocol error: {error}"})
        finally:
            enqueue({"type": "_pipeClosed"})
    try:
        with request_file.open("x", encoding="utf-8") as output:
            json.dump({"request": request, "root": str(root), "token": token}, output,
                      ensure_ascii=False)
        environment = os.environ.copy()
        environment.update({"PYTHONUTF8": "1", "PYTHONUNBUFFERED": "1",
                            "PYINSTALLER_RESET_ENVIRONMENT": "1"})
        child = subprocess.Popen(
            child_command(request_file), stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=None, close_fds=True,
            text=True, encoding="utf-8", errors="strict", env=environment,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        reader = threading.Thread(target=read_events, daemon=True)
        reader.start()
        while not finished:
            try:
                command = command_queue.get_nowait()
                if command.get("operation") == "cancel":
                    cancelled = True
                    break
            except queue.Empty:
                pass
            try:
                event = events.get(timeout=0.05)
                if event["type"] == "_finished":
                    finished = True
                elif event["type"] == "_pipeClosed":
                    code = child.wait(timeout=5)
                    emit({"type": "fileError", "message": f"Worker exited unexpectedly (code {code})."})
                    break
                else:
                    emit(event)
            except queue.Empty:
                pass
        if cancelled and child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    except Exception as error:
        emit({"type": "fileError", "message": str(error)})
    finally:
        if child is not None and child.poll() is None:
            child.kill()
            child.wait()
        stopped.set()
        if reader is not None:
            reader.join(timeout=2)
        if child is not None:
            child.stdout.close()
        cleanup(request, root, token)
        request_file.unlink(missing_ok=True)
        emit({"type": "done", "cancelled": cancelled})


def diagnostics():
    import av
    import ctranslate2
    import faster_whisper
    from argostranslate.package import Package
    codecs = {name: av.Codec(name, "r").name for name in
              ("mp3", "aac", "pcm_s16le", "flac", "vorbis", "opus")}
    containers = {name: av.format.ContainerFormat(name).is_input for name in
                  ("mp3", "mov", "wav", "flac", "ogg")}
    print(json.dumps({"type": "diagnostics", "python": sys.version,
                      "pyav": av.__version__, "ctranslate2": ctranslate2.__version__,
                      "decoders": codecs, "containers": containers,
                      "audioExtensions": [".mp3", ".m4a", ".m4b", ".wav", ".flac", ".ogg", ".aac"],
                      "cudaDevices": ctranslate2.get_cuda_device_count()},
                     ensure_ascii=False), flush=True)


def main():
    # Reconfigure Unicode independently of Windows console codepages.
    sys.stdout.reconfigure(encoding="utf-8", errors="strict")
    sys.stdin.reconfigure(encoding="utf-8")
    def emit(event):
        print(json.dumps(event, ensure_ascii=False, separators=(",", ":")), flush=True)
    try:
        request = json.loads(sys.stdin.readline())
        commands = queue.Queue()
        def listen():
            for line in sys.stdin:
                try:
                    commands.put(json.loads(line))
                except json.JSONDecodeError:
                    continue
        threading.Thread(target=listen, daemon=True).start()
        supervise(request, commands, emit)
    except Exception as error:
        emit({"type": "fileError", "message": str(error)})
        emit({"type": "done", "cancelled": False})


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--child":
        child_main(sys.argv[2])
    elif "--diagnostics" in sys.argv:
        diagnostics()
    else:
        main()
    # The stdin listener intentionally blocks until the parent exits. Avoid
    # CPython shutting down while that daemon holds its buffered-reader lock.
    os._exit(0)
