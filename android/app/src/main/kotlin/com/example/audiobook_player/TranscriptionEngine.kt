package com.example.audiobook_player

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedWriter
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.CancellationException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal object WhisperNative {
    init { System.loadLibrary("audiosubs_whisper") }
    external fun open(path: String): Long
    external fun abort(handle: Long)
    external fun close(handle: Long)
    external fun infer(handle: Long, pcm: ByteBuffer, samples: Int, language: String, translate: Boolean, sink: NativeCueSink): String
    external fun publish(source: ByteArray, target: ByteArray): Boolean
}

internal interface NativeCueSink {
    fun onSegment(startMs: Long, endMs: Long, text: ByteArray)
}

internal class TranscriptionEngine(messenger: BinaryMessenger) {
    private data class Model(val id: String, val bytes: Long, val memoryMb: Int, val sha1: String)
    // SHA1/sizes: upstream model README/HF LFS; memory: upstream README estimates.
    private val catalogue = listOf(
        Model("tiny", 77691713, 273, "bd577a113a864445d4c299885e0cb97d4ba92b5f"),
        Model("base", 147951465, 388, "465707469ff3a37a2b9b8d8f89f2f99de7299dac"),
        Model("small", 487601967, 852, "55356645c2b361a969dfd0ef2c5a50d530afd8d5")
    )
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "audiosubs/transcription")
    private val events = EventChannel(messenger, "audiosubs/transcription/events")
    private var sink: EventChannel.EventSink? = null
    private val cancelled = AtomicBoolean(false)
    private var busy = false
    private var disposed = false
    private var runId: Number? = null
    private val handleLock = Any()
    private var handle = 0L
    @Volatile private var connection: HttpURLConnection? = null

    init {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) { sink = eventSink }
            override fun onCancel(arguments: Any?) { sink = null; cancel() }
        })
        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "models" -> {
                    val directory = call.argument<String>("modelDirectory")
                    if (directory == null) result.error("bad_args", "modelDirectory is required", null)
                    else if (disposed) result.error("disposed", "Backend is disposed", null)
                    else worker.execute {
                        try {
                            val descriptors = catalogue.map { model ->
                                val file = File(directory, "ggml-${model.id}.bin")
                                mapOf("id" to model.id, "label" to "${model.id} (multilingual, CPU)", "bytes" to model.bytes,
                                    "memoryMb" to model.memoryMb, "installed" to (file.isFile && file.length() == model.bytes), "path" to file.path)
                            }
                            main.post { result.success(descriptors) }
                        } catch (error: Exception) { main.post { result.error("models", error.message, null) } }
                    }
                }
                "start" -> {
                    @Suppress("UNCHECKED_CAST")
                    val request = call.arguments as? Map<String, Any?>
                    if (disposed || busy || request == null || sink == null) {
                        result.error("unavailable", "Backend disposed, busy, or event listener missing", null)
                    } else {
                        busy = true
                        cancelled.set(false)
                        runId = request["runId"] as? Number
                        val id = runId
                        worker.execute { run(request, id) }
                        result.success(null)
                    }
                }
                "cancel" -> {
                    val id = call.argument<Number>("runId")
                    if (id == null || id.toLong() == runId?.toLong()) cancel()
                    result.success(null)
                }
                "dispose" -> { dispose(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun cancel() {
        cancelled.set(true)
        connection?.disconnect()
        synchronized(handleLock) { if (handle != 0L) WhisperNative.abort(handle) }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        cancel()
        worker.shutdown()
    }

    private fun checkCancelled() {
        if (cancelled.get()) throw CancellationException("Cancelled")
    }

    private fun emit(id: Number?, event: Map<String, Any?>) {
        main.post { sink?.success(event + ("runId" to id)) }
    }

    private fun status(id: Number?, message: String) = emit(id, mapOf("type" to "status", "message" to message))

    private fun run(request: Map<String, Any?>, id: Number?) {
        var failures = 0
        try {
            checkCancelled()
            val model = catalogue.firstOrNull { it.id == request["model"] } ?: error("Unknown model")
            val directory = File(request["modelDirectory"] as? String ?: error("Missing model directory"))
            require(directory.isDirectory || directory.mkdirs()) { "Cannot create model directory" }
            val modelFile = File(directory, "ggml-${model.id}.bin")
            when (request["operation"]) {
                "download" -> download(model, modelFile, id)
                "transcribe" -> {
                    val target = request["targetLanguage"] as? String
                    require(target == null || target == "en") { "Android Whisper translates into English only; other targets are unavailable offline." }
                    require(request["bilingual"] != true || target != null) { "Bilingual output requires English translation" }
                    require(request["device"] != "cuda") { "Android inference supports CPU only" }
                    status(id, "Android uses the GGML model's F16/F32 precision on CPU; compute type is not configurable.")
                    require(modelFile.isFile && modelFile.length() == model.bytes) { "Model is missing or incomplete. Download it explicitly before offline transcription." }
                    status(id, "Verifying ${model.id} model for offline inference")
                    require(hash(modelFile) == model.sha1) { "Model checksum mismatch. Remove the damaged model and download it again." }
                    status(id, "Loading ${model.id} on CPU; estimated memory ${model.memoryMb} MB")
                    val nativeHandle = WhisperNative.open(modelFile.path)
                    synchronized(handleLock) { handle = nativeHandle }
                    checkCancelled()
                    try {
                        val files = request["files"] as? List<*> ?: error("Missing audio files")
                        for (entry in files) {
                            checkCancelled()
                            val file = entry as? Map<*, *>
                            val audio = file?.get("audio") as? String
                            try {
                                require(audio != null) { "Missing audio path" }
                                val base = file?.get("outputBase") as? String ?: error("Missing output base")
                                transcribe(audio, base, request["sourceLanguage"] as? String ?: "auto", target,
                                    request["bilingual"] == true, nativeHandle, id)
                            } catch (error: Exception) {
                                checkCancelled()
                                failures++
                                emit(id, mapOf("type" to "fileError", "audio" to audio, "message" to (error.message ?: error.toString())))
                            }
                        }
                    } finally { releaseHandle() }
                }
                else -> error("Unknown operation")
            }
        } catch (error: Throwable) {
            if (!cancelled.get()) failures++
            if (!cancelled.get()) emit(id, mapOf("type" to "fileError", "message" to (error.message ?: error.toString())))
        } finally {
            releaseHandle()
            val wasCancelled = cancelled.get()
            main.post {
                busy = false
                runId = null
                sink?.success(mapOf("type" to "done", "runId" to id, "cancelled" to wasCancelled,
                    "message" to if (wasCancelled) "Cancelled" else if (failures > 0) "Completed with $failures error(s)" else "Completed"))
            }
        }
    }

    private fun releaseHandle() {
        val released = synchronized(handleLock) {
            val value = handle
            handle = 0L
            value
        }
        if (released != 0L) WhisperNative.close(released)
    }

    private fun hash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-1")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                checkCancelled()
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }

    private fun publish(temp: File, target: File): Boolean =
        WhisperNative.publish(temp.path.toByteArray(Charsets.UTF_8), target.path.toByteArray(Charsets.UTF_8))

    private fun download(model: Model, target: File, id: Number?) {
        if (target.exists()) {
            require(target.length() == model.bytes && hash(target) == model.sha1) { "Existing model is damaged; remove it before downloading again" }
            status(id, "${model.id} is already installed and verified")
            return
        }
        val temp = File.createTempFile(".${model.id}-", ".download", target.parentFile)
        try {
            status(id, "Downloading multilingual ${model.id}")
            val url = URL("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${model.id}.bin")
            val http = url.openConnection() as HttpURLConnection
            connection = http
            http.connectTimeout = 20000
            http.readTimeout = 20000
            http.instanceFollowRedirects = true
            val digest = MessageDigest.getInstance("SHA-1")
            var received = 0L
            var lastProgress = 0L
            try {
                require(http.responseCode == HttpURLConnection.HTTP_OK) { "Model download failed: HTTP ${http.responseCode}" }
                http.inputStream.buffered().use { input ->
                    FileOutputStream(temp).use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            checkCancelled()
                            val count = input.read(buffer)
                            if (count < 0) break
                            received += count
                            require(received <= model.bytes) { "Downloaded model exceeds expected size" }
                            output.write(buffer, 0, count)
                            digest.update(buffer, 0, count)
                            val now = System.nanoTime()
                            if (now - lastProgress > 100000000) {
                                emit(id, mapOf("type" to "progress", "progress" to received.toDouble() / model.bytes))
                                lastProgress = now
                            }
                        }
                        output.fd.sync()
                    }
                }
            } finally { http.disconnect(); connection = null }
            checkCancelled()
            val sha = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            require(received == model.bytes && sha == model.sha1) { "Model size or SHA1 verification failed" }
            require(publish(temp, target) || (target.length() == model.bytes && hash(target) == model.sha1)) { "Another download installed an invalid model" }
            emit(id, mapOf("type" to "progress", "progress" to 1.0))
            status(id, "${model.id} installed and SHA1 verified")
        } finally { temp.delete() }
    }

    private class SrtOutput(val target: File, val kind: String, val language: String) : AutoCloseable {
        val temp: File = File.createTempFile(".audiosubs-", ".partial", target.parentFile)
        private val stream = FileOutputStream(temp)
        private val writer: BufferedWriter = stream.bufferedWriter(Charsets.UTF_8)
        private var index = 0
        private var sealed = false
        private val newlines = Regex("[\\r\\n]+")
        fun cue(start: Long, end: Long, text: String) {
            if (text.isBlank() || end <= start) return
            val lines = text.trim().split(newlines).map { it.trim() }.filter { it.isNotEmpty() }.joinToString("\n")
            writer.write("${++index}\n${timestamp(start)} --> ${timestamp(end)}\n$lines\n\n")
        }
        fun seal() {
            if (sealed) return
            writer.flush()
            stream.fd.sync()
            writer.close()
            sealed = true
        }
        override fun close() { try { if (!sealed) writer.close() } finally { temp.delete() } }
        private fun timestamp(ms: Long): String = String.format(Locale.ROOT, "%02d:%02d:%02d,%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
    }

    private fun transcribe(audio: String, base: String, source: String, target: String?, bilingual: Boolean, nativeHandle: Long, id: Number?) {
        require(File(audio).isFile && File(audio).canRead()) { "Audio path is unreadable" }
        require(source.matches(Regex("auto|[a-z]{2,3}"))) { "Invalid source language" }
        val outputs = mutableListOf<SrtOutput>()
        fun output(path: String, kind: String, language: String): SrtOutput? {
            val file = File(path)
            if (file.exists()) { status(id, "Skipping completed output: $path"); return null }
            return SrtOutput(file, kind, language).also { outputs.add(it) }
        }
        try {
            val original = output("$base.srt", "original", source)
            val translated = target?.let { output("$base.$it.srt", "translated", it) }
            val dual = if (bilingual) output("$base.${if (source == "auto") "original" else source}-$target.srt", "bilingual", "${if (source == "auto") "original" else source}-$target") else null
            if (outputs.isEmpty()) return
            emit(id, mapOf("type" to "status", "audio" to audio, "message" to "Transcribing ${File(audio).name} offline on CPU"))
            if (dual != null) status(id, "Bilingual cues use 30-second audio chunk timing, not equivalent source/translation segment boundaries")
            var detected = source
            AudioDecoder(::checkCancelled).decode(audio) { pcm, samples, offset, duration ->
                checkCancelled()
                val sourceText = if (dual != null) StringBuilder() else null
                val translatedText = if (dual != null) StringBuilder() else null
                if (original != null || dual != null) {
                    detected = WhisperNative.infer(nativeHandle, pcm, samples, source, false, object : NativeCueSink {
                        override fun onSegment(startMs: Long, endMs: Long, text: ByteArray) {
                            checkCancelled()
                            val value = String(text, Charsets.UTF_8).trim()
                            original?.cue(offset + startMs, offset + endMs, value)
                            if (sourceText != null && value.isNotBlank()) { if (sourceText.isNotEmpty()) sourceText.append(' '); sourceText.append(value) }
                        }
                    })
                }
                if (translated != null || dual != null) {
                    WhisperNative.infer(nativeHandle, pcm, samples, if (detected == "auto") source else detected, true, object : NativeCueSink {
                        override fun onSegment(startMs: Long, endMs: Long, text: ByteArray) {
                            checkCancelled()
                            val value = String(text, Charsets.UTF_8).trim()
                            translated?.cue(offset + startMs, offset + endMs, value)
                            if (translatedText != null && value.isNotBlank()) { if (translatedText.isNotEmpty()) translatedText.append(' '); translatedText.append(value) }
                        }
                    })
                }
                if (dual != null && (!sourceText.isNullOrBlank() || !translatedText.isNullOrBlank())) {
                    // A chunk is a real shared audio interval. Do not zip unrelated inferred segments.
                    dual.cue(offset, offset + samples * 1000L / 16000, "$sourceText\n$translatedText")
                }
                emit(id, mapOf("type" to "progress", "audio" to audio, "progress" to if (duration > 0) ((offset + samples * 1000L / 16000).toDouble() / duration).coerceIn(0.0, 1.0) else 0.0))
            }
            for (output in outputs) {
                checkCancelled()
                output.seal()
                if (publish(output.temp, output.target)) {
                    emit(id, mapOf("type" to "output", "audio" to audio, "path" to output.target.path,
                        "kind" to output.kind, "language" to if (output.kind == "original") detected else output.language))
                } else status(id, "Skipping output completed by another job: ${output.target.path}")
            }
            emit(id, mapOf("type" to "progress", "audio" to audio, "progress" to 1.0))
        } finally { outputs.forEach { it.close() } }
    }
}
