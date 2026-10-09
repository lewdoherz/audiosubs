package com.example.audiobook_player

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Decoder and linear resampler retain at most one 30-second, mono 16 kHz chunk. */
internal class AudioDecoder(private val checkCancelled: () -> Unit) {
    fun decode(path: String, chunk: (ByteBuffer, Int, Long, Long) -> Unit) {
        if (File(path).extension.lowercase() == "wav") {
            decodeWave(path, chunk)
        } else {
            decodeMedia(path, chunk)
        }
    }

    private inner class Resampler(
        private val sampleRate: Int,
        private val durationMs: Long,
        private val chunk: (ByteBuffer, Int, Long, Long) -> Unit
    ) {
        private val pcm = ByteBuffer.allocateDirect(480000 * 4).order(ByteOrder.nativeOrder())
        private var count = 0
        private var total = 0L
        private var frame = 0L
        private var next = 0.0
        private var previous = 0f
        private val step = sampleRate.toDouble() / 16000.0

        fun sample(value: Float) {
            val mono = if (value.isFinite()) value.coerceIn(-1f, 1f) else 0f
            while (next <= frame.toDouble()) {
                val fraction = if (frame == 0L) 1.0 else next - (frame - 1)
                val output = previous + (mono - previous) * fraction.toFloat().coerceIn(0f, 1f)
                pcm.putFloat(output)
                count++
                total++
                next += step
                if (count == 480000) flush()
            }
            previous = mono
            frame++
        }

        fun flush() {
            if (count == 0) return
            checkCancelled()
            chunk(pcm, count, (total - count) * 1000 / 16000, durationMs)
            pcm.clear()
            count = 0
        }
    }

    private fun decodeMedia(path: String, chunk: (ByteBuffer, Int, Long, Long) -> Unit) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: error("No supported audio track in $path")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: error("Missing audio MIME type")
            val duration = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) / 1000 else 0L
            val decoder = MediaCodec.createDecoderByType(mime)
            codec = decoder
            decoder.configure(format, null, null, 0)
            decoder.start()
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            require(channels > 0 && rate > 0) { "Invalid audio format" }
            var encoding = AudioFormat.ENCODING_PCM_16BIT
            var resampler = Resampler(rate, duration, chunk)
            var receivedPcm = false
            var inputEnded = false
            var outputEnded = false
            val info = MediaCodec.BufferInfo()
            while (!outputEnded) {
                checkCancelled()
                if (!inputEnded) {
                    val index = decoder.dequeueInputBuffer(10000)
                    if (index >= 0) {
                        val buffer = decoder.getInputBuffer(index) ?: error("Missing codec input buffer")
                        buffer.clear()
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEnded = true
                        } else {
                            decoder.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val index = decoder.dequeueOutputBuffer(info, 10000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val output = decoder.outputFormat
                    val newRate = output.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = output.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    require(channels > 0 && newRate > 0) { "Invalid decoded audio format" }
                    if (newRate != rate) {
                        require(!receivedPcm) { "Midstream sample-rate changes are unsupported" }
                        rate = newRate
                        resampler = Resampler(rate, duration, chunk)
                    }
                    encoding = if (output.containsKey(MediaFormat.KEY_PCM_ENCODING)) output.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
                } else if (index >= 0) {
                    try {
                        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            val buffer = decoder.getOutputBuffer(index) ?: error("Missing codec output buffer")
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            buffer.order(ByteOrder.LITTLE_ENDIAN)
                            consumePcm(buffer, channels, encoding, resampler)
                            receivedPcm = true
                        }
                        outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    } finally {
                        decoder.releaseOutputBuffer(index, false)
                    }
                }
            }
            require(receivedPcm) { "The decoder produced no PCM audio" }
            resampler.flush()
        } finally {
            try { codec?.stop() } catch (_: Exception) { }
            codec?.release()
            extractor.release()
        }
    }

    private fun consumePcm(buffer: ByteBuffer, channels: Int, encoding: Int, resampler: Resampler) {
        val bytes = when (encoding) {
            AudioFormat.ENCODING_PCM_8BIT -> 1
            AudioFormat.ENCODING_PCM_16BIT -> 2
            AudioFormat.ENCODING_PCM_FLOAT, AudioFormat.ENCODING_PCM_32BIT -> 4
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> 3
            else -> error("Unsupported decoded PCM encoding: $encoding")
        }
        require(buffer.remaining() % (channels * bytes) == 0) { "Incomplete PCM frame" }
        var frames = 0
        while (buffer.remaining() >= channels * bytes) {
            if (++frames % 4096 == 0) checkCancelled()
            var sum = 0f
            repeat(channels) {
                sum += when (encoding) {
                    AudioFormat.ENCODING_PCM_8BIT -> ((buffer.get().toInt() and 255) - 128) / 128f
                    AudioFormat.ENCODING_PCM_16BIT -> buffer.short / 32768f
                    AudioFormat.ENCODING_PCM_FLOAT -> buffer.float
                    AudioFormat.ENCODING_PCM_32BIT -> buffer.int / 2147483648f
                    else -> {
                        val low = buffer.get().toInt() and 255
                        val mid = buffer.get().toInt() and 255
                        val high = buffer.get().toInt()
                        ((high shl 16) or (mid shl 8) or low) / 8388608f
                    }
                }
            }
            resampler.sample(sum / channels)
        }
    }

    // MediaExtractor support for PCM WAV varies by device. Parse RIFF PCM directly
    // as a bounded fallback path; compressed WAV and RF64 are explicitly rejected.
    private fun decodeWave(path: String, chunk: (ByteBuffer, Int, Long, Long) -> Unit) {
        RandomAccessFile(path, "r").use { input ->
            val header = ByteArray(12)
            input.readFully(header)
            require(String(header, 0, 4, Charsets.US_ASCII) == "RIFF" && String(header, 8, 4, Charsets.US_ASCII) == "WAVE") { "Only RIFF PCM WAV is supported" }
            var channels = 0
            var rate = 0
            var bits = 0
            var encoding = 0
            var blockAlign = 0
            var dataOffset = -1L
            var dataSize = 0L
            val chunkHeader = ByteArray(8)
            while (input.filePointer + 8 <= input.length()) {
                checkCancelled()
                input.readFully(chunkHeader)
                val id = String(chunkHeader, 0, 4, Charsets.US_ASCII)
                val size = ByteBuffer.wrap(chunkHeader, 4, 4).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xffffffffL
                val start = input.filePointer
                require(start + size <= input.length()) { "Truncated WAV chunk" }
                if (id == "fmt ") {
                    require(size >= 16) { "Invalid WAV format" }
                    val fmt = ByteArray(minOf(size, 40).toInt())
                    input.readFully(fmt)
                    val b = ByteBuffer.wrap(fmt).order(ByteOrder.LITTLE_ENDIAN)
                    encoding = b.short.toInt() and 65535
                    channels = b.short.toInt() and 65535
                    rate = b.int
                    b.int
                    blockAlign = b.short.toInt() and 65535
                    bits = b.short.toInt() and 65535
                    if (encoding == 0xfffe && fmt.size >= 40) {
                        val pcmGuidTail = byteArrayOf(0, 0, 0, 0, 16, 0, -128, 0, 0, -86, 0, 56, -101, 113)
                        require(fmt.copyOfRange(26, 40).contentEquals(pcmGuidTail)) { "Unsupported extensible WAV format" }
                        encoding = (fmt[24].toInt() and 255) or ((fmt[25].toInt() and 255) shl 8)
                    }
                } else if (id == "data" && dataOffset < 0) {
                    dataOffset = start
                    dataSize = size
                }
                input.seek(start + size + (size and 1))
            }
            require(dataOffset >= 0 && dataSize > 0 && channels > 0 && rate > 0) { "WAV is missing PCM audio" }
            val pcmEncoding = when {
                encoding == 3 && bits == 32 -> AudioFormat.ENCODING_PCM_FLOAT
                encoding == 1 && bits == 8 -> AudioFormat.ENCODING_PCM_8BIT
                encoding == 1 && bits == 16 -> AudioFormat.ENCODING_PCM_16BIT
                encoding == 1 && bits == 24 -> AudioFormat.ENCODING_PCM_24BIT_PACKED
                encoding == 1 && bits == 32 -> AudioFormat.ENCODING_PCM_32BIT
                else -> error("Unsupported WAV encoding $encoding / $bits bits")
            }
            require(blockAlign == channels * (bits / 8) && dataSize % blockAlign == 0L) { "Invalid WAV block alignment" }
            val duration = (dataSize / blockAlign) * 1000 / rate
            val resampler = Resampler(rate, duration, chunk)
            val bytes = ByteArray(maxOf(blockAlign, (65536 / blockAlign) * blockAlign))
            input.seek(dataOffset)
            var remaining = dataSize
            while (remaining > 0) {
                checkCancelled()
                val length = minOf(remaining, bytes.size.toLong()).toInt()
                input.readFully(bytes, 0, length)
                consumePcm(ByteBuffer.wrap(bytes, 0, length).order(ByteOrder.LITTLE_ENDIAN), channels, pcmEncoding, resampler)
                remaining -= length
            }
            resampler.flush()
        }
    }
}
