package sh.ian.lively.audio

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.SystemClock
import java.util.concurrent.Executors

/**
 * Plays spoken translations for speech-to-speech mode: 24 kHz mono PCM16
 * chunks from `SonioxSpeaker`, queued back to back as they arrive.
 *
 * Android has no shared audio session to coordinate with the mic, as iOS
 * does: an [AudioTrack] plays alongside a recording on its own.
 */
class SpeechPlayer(private val audioManager: AudioManager?) {
    /** Writes block until the track has room, so they run on their own thread. */
    private val writer = Executors.newSingleThreadExecutor { Thread(it, "lively-speech").apply { priority = Thread.MAX_PRIORITY } }
    private var track: AudioTrack? = null
    /** Bumped on stop, so writes queued before it are dropped. */
    @Volatile private var generation = 0
    /** Bytes written and not played yet are estimated from this. */
    @Volatile private var playsUntil = 0L
    /** A byte left over from a chunk with an odd length. */
    private var leftover: Byte? = null

    /** Something is playing, or just finished. */
    val isAudible: Boolean get() = SystemClock.elapsedRealtime() < playsUntil + ECHO_TAIL_MS

    /**
     * The mic would hear the translation through the speaker, so it should
     * send silence for now. Headphones keep it out of the mic.
     */
    val mutesMic: Boolean get() = isAudible && !outputIsPrivate

    /** Queues one chunk of little-endian PCM16 at [SAMPLE_RATE]. */
    fun play(pcm: ByteArray) {
        var bytes = pcm
        leftover?.let {
            bytes = byteArrayOf(it) + bytes
            leftover = null
        }
        if (bytes.size % 2 == 1) {
            leftover = bytes.last()
            bytes = bytes.copyOf(bytes.size - 1)
        }
        if (bytes.isEmpty()) return
        // Count the audio as playing from now, so the mic mutes before it starts.
        val now = SystemClock.elapsedRealtime()
        playsUntil = maxOf(playsUntil, now) + bytes.size / 2 * 1000L / SAMPLE_RATE
        val generation = generation
        writer.execute {
            if (generation != this.generation) return@execute
            val track = track ?: makeTrack().also { track = it }
            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) track.play()
            track.write(bytes, 0, bytes.size)
        }
    }

    /** Stops at once and drops everything queued. */
    fun stop() {
        generation += 1
        leftover = null
        playsUntil = minOf(playsUntil, SystemClock.elapsedRealtime())
        writer.execute {
            track?.let {
                runCatching { it.pause(); it.flush(); it.stop() }
                it.release()
            }
            track = null
        }
    }

    private fun makeTrack(): AudioTrack {
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build()
        val minBuffer = AudioTrack.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        return AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(format)
            .setBufferSizeInBytes(maxOf(minBuffer, SAMPLE_RATE / 2))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
    }

    /** Audio goes to headphones or a headset rather than a loudspeaker. */
    private val outputIsPrivate: Boolean
        get() {
            val devices = audioManager?.getDevices(AudioManager.GET_DEVICES_OUTPUTS) ?: return false
            return devices.any { it.type in PRIVATE_OUTPUTS }
        }

    companion object {
        const val SAMPLE_RATE = 24_000
        /** How long after the last sound the mic stays muted, for the room's echo. */
        private const val ECHO_TAIL_MS = 400L

        private val PRIVATE_OUTPUTS = setOf(
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_USB_HEADSET,
        )
    }
}
