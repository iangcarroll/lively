package sh.ian.lively.audio

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.Process
import sh.ian.lively.support.DebugFlags
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Captures the microphone and emits 16 kHz mono PCM16 chunks, the format
 * both engines expect. Chunks are small (80 ms) to keep latency low.
 *
 * Reads on its own high-priority thread; [onChunk] is called there.
 */
class MicCapture {
    /** Called on the capture thread with a PCM16 chunk and its level in dBFS. */
    var onChunk: ((ByteArray, Float) -> Unit)? = null
    /** Called on the main thread if capture stops for a reason outside our control. */
    var onInterrupted: (() -> Unit)? = null

    private var record: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile private var running = false
    private var fileTimer: ScheduledExecutorService? = null
    private val main = Handler(Looper.getMainLooper())

    /**
     * Another app (a call, a voice assistant) can take the mic; Android then
     * feeds us silence instead of failing. Say so instead of listening to nothing.
     */
    private val recordingCallback = object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
            val session = record?.audioSessionId ?: return
            val ours = configs.firstOrNull { it.clientAudioSessionId == session } ?: return
            if (ours.isClientSilenced) main.post {
                if (!running) return@post
                stop()
                onInterrupted?.invoke()
            }
        }
    }

    /** Needs RECORD_AUDIO, which the caller checks first. */
    @SuppressLint("MissingPermission")
    @Throws(IOException::class)
    fun start() {
        if (running) return
        DebugFlags.audioFile?.let {
            startFile(File(it))
            return
        }
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuffer <= 0) throw IOException("No microphone is available.")
        val record = AudioRecord.Builder()
            // Tuned for speech recognition: no echo cancellation or noise gating
            // that would clip the person across the table.
            .setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(max(minBuffer, CHUNK_BYTES * 4))
            .build()
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw IOException("No microphone is available.")
        }
        try {
            record.startRecording()
        } catch (e: IllegalStateException) {
            record.release()
            throw IOException("The microphone is in use by another app.")
        }
        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            record.release()
            throw IOException("The microphone is in use by another app.")
        }
        record.registerAudioRecordingCallback(Executors.newSingleThreadExecutor(), recordingCallback)
        this.record = record
        running = true
        thread = Thread({ readLoop(record) }, "lively-mic").apply { start() }
    }

    fun stop() {
        running = false
        fileTimer?.shutdownNow()
        fileTimer = null
        val record = record ?: return
        this.record = null
        runCatching { record.unregisterAudioRecordingCallback(recordingCallback) }
        runCatching { record.stop() }
        thread?.join(500)
        thread = null
        record.release()
    }

    private fun readLoop(record: AudioRecord) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val buffer = ByteArray(CHUNK_BYTES)
        while (running) {
            var filled = 0
            while (filled < CHUNK_BYTES && running) {
                val read = record.read(buffer, filled, CHUNK_BYTES - filled)
                if (read < 0) {
                    // The device went away (a headset unplugged mid-read).
                    if (running) main.post {
                        if (!running) return@post
                        stop()
                        onInterrupted?.invoke()
                    }
                    return
                }
                filled += read
            }
            if (filled == CHUNK_BYTES) onChunk?.invoke(buffer.copyOf(), decibels(buffer))
        }
    }

    /**
     * Debug builds: plays a 16-bit PCM WAV file into the app in real time
     * instead of the microphone, once, then silence. For testing without a
     * speaker or a quiet room, and on emulators.
     */
    private fun startFile(file: File) {
        val pcm = readWav(file)
        running = true
        var offset = 0
        val timer = Executors.newSingleThreadScheduledExecutor()
        timer.scheduleAtFixedRate({
            val chunk = ByteArray(CHUNK_BYTES)
            if (offset < pcm.size) {
                val n = min(CHUNK_BYTES, pcm.size - offset)
                System.arraycopy(pcm, offset, chunk, 0, n)
                offset += CHUNK_BYTES
            }
            onChunk?.invoke(chunk, decibels(chunk))
        }, 0, (CHUNK_DURATION * 1000).toLong(), TimeUnit.MILLISECONDS)
        fileTimer = timer
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        const val CHUNK_DURATION = 0.08
        const val CHUNK_BYTES = (SAMPLE_RATE * CHUNK_DURATION).toInt() * 2

        /** The RMS level of a PCM16 chunk in dBFS, from about -120 (silence) to 0. */
        fun decibels(chunk: ByteArray): Float {
            var sum = 0.0
            val samples = chunk.size / 2
            for (i in 0 until samples) {
                val sample = ((chunk[2 * i + 1].toInt() shl 8) or (chunk[2 * i].toInt() and 0xFF)).toShort() / 32768.0
                sum += sample * sample
            }
            if (samples == 0) return -120f
            return (20 * log10(max(sqrt(sum / samples), 1e-6))).toFloat()
        }

        /** Maps roughly -50 dB…0 dB onto 0…1 for the level meter. */
        fun meterLevel(decibels: Float): Float = ((decibels + 50) / 50).coerceIn(0f, 1f)

        /** A 16-bit PCM WAV file as 16 kHz mono PCM16, resampled linearly. */
        fun readWav(file: File): ByteArray {
            val bytes = file.readBytes()
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            if (bytes.size < 12 || String(bytes, 0, 4) != "RIFF" || String(bytes, 8, 4) != "WAVE") throw IOException("Not a WAV file")
            var position = 12
            var channels = 1
            var rate = SAMPLE_RATE
            var bits = 16
            while (position + 8 <= bytes.size) {
                val id = String(bytes, position, 4)
                val size = buffer.getInt(position + 4)
                val body = position + 8
                if (id == "fmt ") {
                    channels = buffer.getShort(body + 2).toInt()
                    rate = buffer.getInt(body + 4)
                    bits = buffer.getShort(body + 14).toInt()
                } else if (id == "data") {
                    if (bits != 16) throw IOException("Only 16-bit WAV is supported")
                    val frames = min(size, bytes.size - body) / (2 * channels)
                    val mono = ShortArray(frames) { i ->
                        var total = 0
                        for (c in 0 until channels) total += buffer.getShort(body + (i * channels + c) * 2)
                        (total / channels).toShort()
                    }
                    val outFrames = (frames.toLong() * SAMPLE_RATE / rate).toInt()
                    val out = ByteBuffer.allocate(outFrames * 2).order(ByteOrder.LITTLE_ENDIAN)
                    for (i in 0 until outFrames) {
                        val at = i.toDouble() * rate / SAMPLE_RATE
                        val j = at.toInt().coerceAtMost(frames - 1)
                        val next = min(j + 1, frames - 1)
                        val t = at - j
                        out.putShort((mono[j] * (1 - t) + mono[next] * t).toInt().toShort())
                    }
                    return out.array()
                }
                position = body + size + (size and 1)
            }
            throw IOException("No audio in the WAV file")
        }
    }
}
