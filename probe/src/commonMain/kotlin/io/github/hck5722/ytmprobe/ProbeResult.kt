package io.github.hck5722.ytmprobe

import kotlinx.coroutines.Job
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.cancel

/** Receives progress from a SABR stream written incrementally to disk. */
public interface AudioStreamSink {
    public fun onStreamStarted(path: String, mimeType: String, client: String, profile: String, expectedBytes: String)
    public fun onChunkAvailable(bytesAvailable: String)
    public fun onStreamCompleted()
    public fun onStreamFailed(type: String, message: String)
}

public class ProbeResult(
    public val darwinHttpOk: Boolean = false,
    public val darwinStatus: Int = 0,
    public val browseOk: Boolean = false,
    public val browseStatus: Int = 0,
    public val browseBytes: Int = 0,
    public val searchOk: Boolean = false,
    public val searchStatus: Int = 0,
    public val searchBytes: Int = 0,
    public val streamOk: Boolean = false,
    public val streamAttempts: Int = 0,
    public val streamFailure: String? = null,
    public val audioUrl: String? = null,
    public val audioHeaders: Map<String, String> = emptyMap(),
    public val audioMimeType: String? = null,
    public val audioItag: Int = -1,
    public val audioClient: String? = null,
    public val audioProfile: String? = null,
    public val isSabr: Boolean = false,
    public val streamDiagnostics: String = "not_run",
    public val streamRunSummaries: List<String> = emptyList(),
    public val sampleCandidates: Int = 0,
    public val samplePassed: Int = 0,
    public val sampleTrackResults: List<String> = emptyList(),
    public val streamBytesPulled: Long = 0,
    public val streamUrlObtained: Boolean = false,
    public val audioChunks: List<ByteArray> = emptyList(),
    public val audioExpectedBytes: Long? = null,
    public val audioComplete: Boolean = false,
    public val audioCachePath: String? = null,
    public val loginState: String = "SKIP_NO_CREDENTIAL",
    public val loginStatus: Int = 0,
    public val loginBytes: Int = 0,
    public val diagnostic: String = "",
    public val failureStage: String? = null,
    public val failureType: String? = null,
    public val failureMessage: String? = null,
    public val prefixReadable: Boolean = false,
    public val prefixFailure: String? = null,
    public val audioStreamHandle: StreamingAudioHandle? = null,
)

/** Owns a background SABR writer and its network resources. */
public class StreamingAudioHandle internal constructor(
    public val path: String,
    public val mimeType: String,
    public val client: String,
    public val profile: String,
    public val expectedBytes: Long,
    private val job: Job,
    private val scope: CoroutineScope,
    private val closeResources: () -> Unit,
) {
    public fun close() {
        job.cancel()
        scope.cancel()
        closeResources()
    }
}
