package io.github.hck5722.ytmprobe

import com.metrolist.innertubex.InnerTube
import com.metrolist.innertubex.InnerTubeLogEvent
import com.metrolist.innertubex.InnerTubeLogger
import com.metrolist.innertubex.bodyAsTextLimited
import com.metrolist.innertubex.cipher.YouTubeCipherService
import com.metrolist.innertubex.cipher.RemotePlayerConfigStore
import com.metrolist.innertubex.extraction.AudioQuality
import com.metrolist.innertubex.extraction.ContentHints
import com.metrolist.innertubex.extraction.InnerTubeExtractor
import com.metrolist.innertubex.extraction.PoTokenResult
import com.metrolist.innertubex.extraction.StreamResolveException
import com.metrolist.innertubex.extraction.TokenProvider
import com.metrolist.innertubex.extraction.TokenProviderCapabilities
import com.metrolist.innertubex.extraction.YtConfigParserImpl
import com.metrolist.innertubex.extraction.YtConfigParser
import com.metrolist.innertubex.extraction.selectBestAudioFormat
import com.metrolist.innertubex.extraction.strategy.PoTokenProviderKind
import com.metrolist.innertubex.models.YouTubeClient
import com.metrolist.innertubex.models.YouTubeLocale
import com.metrolist.innertubex.models.response.PlayerResponse
import com.metrolist.innertubex.sabr.ExperimentalSabrApi
import com.metrolist.innertubex.sabr.SabrAudioStream
import io.ktor.client.HttpClient
import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.post
import io.ktor.client.request.header
import io.ktor.client.request.prepareGet
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.client.statement.bodyAsChannel
import io.ktor.utils.io.cancel
import io.ktor.utils.io.readAvailable
import io.ktor.http.isSuccess
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.contentOrNull
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.takeWhile
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.time.Clock
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource

public class YTMProbe {
    private data class PlaybackBundle(
        val client: HttpClient,
        val innerTube: InnerTube,
        val extractor: InnerTubeExtractor,
    )

    private val playbackBundleMutex = Mutex()
    private var cachedPlaybackBundle: PlaybackBundle? = null
    private var cachedPlaybackKey: String? = null

    /** Preloads the same extractor bundle that Metrolist keeps alive globally. */
    public suspend fun prewarmPlayback(
        cookie: String? = null,
        tokenGroup: String = "baseline",
        tokenServiceUrl: String = "http://127.0.0.1:4416/get_pot",
    ): Boolean {
        if (tokenGroup != "baseline") return false
        return runCatching {
            // Publish the shared bundle before warming it. Playback can then enter
            // the direct client path concurrently instead of waiting on warm-up.
            val bundle = getCachedPlaybackBundle(cookie, tokenGroup, tokenServiceUrl, InnerTubeLogger.NONE, warm = false)
            bundle.extractor.prewarm()
        }.isSuccess
    }

    /** Builds the shared fast-playback client and primes only anonymous visitor data. */
    public suspend fun prepareFastPlayback(
        cookie: String? = null,
        tokenGroup: String = "baseline",
        tokenServiceUrl: String = "http://127.0.0.1:4416/get_pot",
    ): Boolean = runCatching {
        val bundle = getCachedPlaybackBundle(cookie, tokenGroup, tokenServiceUrl, InnerTubeLogger.NONE, warm = false)
        if (bundle.innerTube.visitorData.isNullOrBlank()) {
            bundle.innerTube.fetchFreshVisitorData(bundle.innerTube.sessionSnapshot())
        }
        true
    }.getOrDefault(false)

    /** Resolves one SABR stream, then keeps downloading it into a growing file. */
    @OptIn(ExperimentalSabrApi::class)
    public suspend fun startStreaming(
        videoId: String,
        cookie: String? = null,
        tokenGroup: String = "baseline",
        tokenServiceUrl: String = "http://127.0.0.1:4416/get_pot",
        streamSink: AudioStreamSink,
    ): StreamingAudioHandle? {
        val useCachedPlaybackBundle = tokenGroup == "baseline"
        val bundle = if (useCachedPlaybackBundle) {
            getCachedPlaybackBundle(cookie, tokenGroup, tokenServiceUrl, InnerTubeLogger.NONE, warm = false)
        } else {
            createPlaybackBundle(cookie, tokenGroup, tokenServiceUrl, InnerTubeLogger.NONE, warm = true)
        }
        val client = bundle.client
        val innerTube = bundle.innerTube
        val extractor = bundle.extractor
        try {
            cookie?.trim()?.takeIf(String::isNotEmpty)?.let {
                innerTube.cookie = it
                innerTube.useLoginForBrowse = true
            }
            val stream = extractor.extract(
                videoId = videoId,
                hints = ContentHints(wantVideo = false, sabrFirst = true),
                audioQuality = AudioQuality.MP4,
            ) ?: run {
                if (!useCachedPlaybackBundle) { innerTube.close(); client.close() }; return null
            }
            val bootstrap = stream.sabrBootstrap ?: run {
                if (!useCachedPlaybackBundle) { innerTube.close(); client.close() }; return null
            }
            val path = createStreamingAudioFile() ?: run {
                if (!useCachedPlaybackBundle) { innerTube.close(); client.close() }; return null
            }
            streamSink.onStreamStarted(path, stream.mimeType ?: "audio/mp4", stream.clientName ?: "unknown", stream.profileId ?: "unknown", (stream.contentLengthBytes ?: 0L).toString())
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val job = scope.launch {
                try {
                    collectAudio(client, stream, path, streamSink)
                    streamSink.onStreamCompleted()
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    streamSink.onStreamFailed(error::class.simpleName ?: "SabrProtocolException", sanitizeFailureMessage(error.message).orEmpty())
                } finally {
                    if (!useCachedPlaybackBundle) {
                        innerTube.close()
                        client.close()
                    }
                }
            }
            return StreamingAudioHandle(
                path = path,
                mimeType = stream.mimeType ?: "audio/mp4",
                client = stream.clientName ?: "unknown",
                profile = stream.profileId ?: "unknown",
                expectedBytes = stream.contentLengthBytes ?: 0L,
                job = job,
                scope = scope,
                closeResources = {
                    if (!useCachedPlaybackBundle) {
                        innerTube.close()
                        client.close()
                    }
                },
            )
        } catch (error: Throwable) {
            if (!useCachedPlaybackBundle) {
                innerTube.close()
                client.close()
            }
            streamSink.onStreamFailed(error::class.simpleName ?: "KotlinException", sanitizeFailureMessage(error.message).orEmpty())
            return null
        }
    }

    @Throws(Exception::class)
    public suspend fun run(
        playlistId: String,
        videoId: String,
        cookie: String?,
        tokenGroup: String = "baseline",
        tokenServiceUrl: String = "http://127.0.0.1:4416/get_pot",
        candidateVideoIds: List<String> = listOf(videoId),
        sampleCount: Int = 1,
        collectFullAudio: Boolean = false,
        forceSabr: Boolean = false,
        fastPlayback: Boolean = false,
        directPlayerFastPath: Boolean = false,
        verifyAudioPrefix: Boolean = false,
        playbackClientOverrideId: String? = null,
        streamSink: AudioStreamSink? = null,
    ): ProbeResult {
        val logLines = mutableListOf<String>()
        var stage = "init"
        val logger = InnerTubeLogger { event: InnerTubeLogEvent ->
            if (tokenGroup == "2a" && event.message in TOKEN_DIAGNOSTIC_EVENTS) {
                val details = event.details.orEmpty()
                val clientName = details["client"] ?: "none"
                val tokenPresent = details["tokenPresent"] ?: "unknown"
                val profile = details["profile"]?.takeIf { it.matches(SAFE_LOG_VALUE) } ?: "none"
                val mediaId = event.mediaId?.takeIf { it.matches(SAFE_LOG_VALUE) } ?: "none"
                logLines += "PROBE_TOKEN_ATTEMPT client=" + clientName + " profile=" + profile +
                    " videoId=" + mediaId + " event=" + event.message.replace(' ', '_') +
                    " tokenPresent=" + tokenPresent
            }
        }
        val useCachedPlaybackBundle = fastPlayback && tokenGroup == "baseline"
        val bundle = if (useCachedPlaybackBundle) {
            getCachedPlaybackBundle(cookie, tokenGroup, tokenServiceUrl, logger, warm = false)
        } else {
            createPlaybackBundle(cookie, tokenGroup, tokenServiceUrl, logger, warm = !fastPlayback)
        }
        val client = bundle.client
        val innerTube = bundle.innerTube
        val extractor = bundle.extractor
        try {
            val normalizedCookie = cookie?.trim()?.takeIf(String::isNotEmpty)
            if (normalizedCookie != null) {
                innerTube.cookie = normalizedCookie
                innerTube.useLoginForBrowse = true
            }
            stage = "darwin_http"
            val darwinResponse = if (!fastPlayback) client.get("https://music.youtube.com/") else null
            val darwinBody = darwinResponse?.bodyAsText().orEmpty()

            stage = "browse"
            val detectedLocale = innerTube.locale
            logLines += "PROBE_LOCALE gl=${detectedLocale.gl.ifBlank { "none" }} hl=${detectedLocale.hl.ifBlank { "none" }}"
            val browseResponse = if (!fastPlayback) {
                try {
                    innerTube.browse(YouTubeClient.WEB_REMIX, browseId = "VL$playlistId")
                } catch (error: Throwable) {
                    val isHttp400 = error.message?.contains("browse failed with HTTP 400") == true
                    if (!isHttp400 || detectedLocale.gl == "US" && detectedLocale.hl == "en") throw error
                    val fallbackLocale = YouTubeLocale(gl = "US", hl = "en")
                    logLines += "PROBE_BROWSE_RETRY reason=http_400 locale=${fallbackLocale.gl}/${fallbackLocale.hl}"
                    innerTube.locale = fallbackLocale
                    logLines += "PROBE_LOCALE_ACTIVE gl=${fallbackLocale.gl} hl=${fallbackLocale.hl}"
                    innerTube.browse(YouTubeClient.WEB_REMIX, browseId = "VL$playlistId")
                }
            } else null
            val browseBody = browseResponse?.bodyAsTextLimited(MAX_RESPONSE_BYTES).orEmpty()

            stage = "search"
            val searchResponse = if (!fastPlayback) {
                innerTube.search(YouTubeClient.WEB_REMIX, query = "YouTube Music", setLogin = false)
            } else null
            val searchBody = searchResponse?.bodyAsTextLimited(MAX_RESPONSE_BYTES).orEmpty()

            stage = "extractor_init"
            stage = "extractor_prewarm"
            val streamCandidates =
                (candidateVideoIds + extractPlaylistVideoIds(browseBody))
                    .distinct()
                    .filter(String::isNotBlank)
                    .take(sampleCount.coerceAtLeast(1))
                    .ifEmpty { listOf(videoId) }
            var stream: com.metrolist.innertubex.extraction.ExtractedStream? = null
            var streamFailure: String? = null
            var streamAttempts = 0
            var lastStreamDiagnostics = "not_run"
            val streamRunSummaries = mutableListOf<String>()
            val sampleTrackResults = mutableListOf<String>()
            var selectedStreamBytesPulled = 0L
            var selectedPrefixReadable = false
            var selectedPrefixFailure: String? = null
            for (candidate in streamCandidates) {
                val candidateStartedAt = TimeSource.Monotonic.markNow()
                streamAttempts += 1
                stage = "stream_extract:$candidate"
                try {
                    val candidateStream = if (directPlayerFastPath && !forceSabr) {
                        val directStartedAt = TimeSource.Monotonic.markNow()
                        val direct = extractDirectPlayerAudio(innerTube, candidate)
                        logLines += "PROBE_TIMING_DIRECT_PLAYER video=$candidate elapsedMs=${directStartedAt.elapsedNow().inWholeMilliseconds} ${direct.diagnostic}"
                        direct.stream ?: extractor.extract(
                            videoId = candidate,
                            hints = ContentHints(
                                wantVideo = false,
                                playbackClientOverrideId = playbackClientOverrideId,
                                sabrFirst = forceSabr,
                            ).withStreamCapabilities(
                                allowHls = false,
                                allowSabr = forceSabr,
                                allowBoundedRange = !fastPlayback,
                            ),
                            audioQuality = AudioQuality.MP4,
                        )
                    } else {
                        extractor.extract(
                            videoId = candidate,
                            // Match Metrolist's playback policy: the fast path must
                            // request a normal Range-capable media URL. SABR is
                            // reserved for the dedicated streaming fallback.
                            hints = ContentHints(
                                wantVideo = false,
                                playbackClientOverrideId = playbackClientOverrideId,
                                sabrFirst = forceSabr,
                            ).withStreamCapabilities(
                                allowHls = false,
                                allowSabr = forceSabr,
                                // AVPlayer can issue its own Range requests. Requiring
                                // a preflight content-length check adds a CDN round-trip
                                // and can discard an otherwise playable direct URL.
                                allowBoundedRange = !fastPlayback,
                            ),
                            audioQuality = AudioQuality.MP4,
                        )
                    }
                    if (candidateStream == null) {
                        sampleTrackResults += "videoId=$candidate result=FAIL reason=NULL_STREAM"
                    } else {
                        var pulledBytes = 0L
                        var prefixFailure: String? = null
                        if (streamSink == null && (!fastPlayback || verifyAudioPrefix)) {
                            try {
                                pulledBytes = pullAudioPrefix(client, candidateStream)
                            } catch (error: Throwable) {
                                prefixFailure = error::class.simpleName ?: "PREFIX_READ_FAILURE"
                                logLines += "PROBE_PREFIX_FAIL candidate=$candidate type=$prefixFailure message=${sanitizeFailureMessage(error.message).orEmpty()}"
                            }
                        }
                        val pulled = fastPlayback && candidateStream.audioUrl.startsWith("https://") ||
                            pulledBytes >= MIN_SAMPLE_BYTES || streamSink != null
                        selectedPrefixReadable = pulled
                        selectedPrefixFailure = prefixFailure
                        sampleTrackResults += "videoId=$candidate result=PASS prefix=${if (pulled) "PASS" else "FAIL"} reason=${prefixFailure ?: if (pulled) "NONE" else "STREAM_BYTES_SHORT"} bytesPulled=$pulledBytes client=${candidateStream.clientName ?: "unknown"} profile=${candidateStream.profileId ?: "unknown"} sabr=${candidateStream.sabrBootstrap != null}"
                        if (stream == null) {
                            stream = candidateStream
                            selectedStreamBytesPulled = pulledBytes
                        }
                        logLines += "PROBE_TIMING_CANDIDATE video=$candidate elapsedMs=${candidateStartedAt.elapsedNow().inWholeMilliseconds} bytesPulled=$pulledBytes prefixFailure=${prefixFailure ?: "none"}"
                    }
                } catch (error: Throwable) {
                    val resolveError = error as? StreamResolveException
                    streamFailure = if (resolveError != null) {
                        "${error::class.simpleName}: ${resolveError.reason}"
                    } else {
                        error::class.simpleName ?: "UNKNOWN"
                    }
                    logLines += "STREAM_CANDIDATE_FAIL candidate=$candidate reason=$streamFailure"
                    if (resolveError != null) {
                        val diagnostics = resolveError.diagnostics
                        lastStreamDiagnostics = if (diagnostics != null) {
                            val attemptSummary = diagnostics.attempts.joinToString("|") {
                                it.clientName + "/" + (it.profileId ?: "none") + ":" + it.outcome
                            }
                            "reason=${resolveError.reason} sawPlayable=unknown usedAuthenticatedWatchPage=${diagnostics.usedAuthenticatedWatchPage} attemptCount=${diagnostics.attempts.size} attemptSummary=$attemptSummary"
                        } else {
                            "reason=${resolveError.reason} sawPlayable=unknown usedAuthenticatedWatchPage=unknown attemptCount=0 attemptSummary=missing"
                        }
                        val runSummary = "candidate=$candidate exceptionReason=${resolveError.reason} $lastStreamDiagnostics"
                        streamRunSummaries += runSummary
                        sampleTrackResults += "videoId=$candidate result=FAIL reason=${resolveError.reason}"
                        logLines += "PROBE_DIAG_RUN $runSummary"
                        if (tokenGroup != "2a") diagnostics?.attempts?.forEach { attempt ->
                            logLines += "PROBE_DIAG exceptionReason=${resolveError.reason} sawPlayable=unknown client=${attempt.clientName} profile=${attempt.profileId ?: "none"} userAgent=${attempt.userAgent} outcome=${attempt.outcome} tokenUnavailable=not_exposed requestFailure=not_exposed failurePresent=not_exposed"
                        }
                    } else {
                        val runSummary = "candidate=$candidate exceptionReason=NON_STREAM_RESOLVE $streamFailure"
                        streamRunSummaries += runSummary
                        sampleTrackResults += "videoId=$candidate result=FAIL reason=${error::class.simpleName ?: "UNKNOWN"}"
                        logLines += "PROBE_DIAG_RUN $runSummary"
                    }
                }
            }

            stage = "audio_collect"
            val streamingPath = if (streamSink != null && stream?.sabrBootstrap != null) {
                createStreamingAudioFile()
            } else null
            if (streamingPath != null && stream != null) {
                streamSink?.onStreamStarted(
                    streamingPath,
                    stream.mimeType ?: "audio/mp4",
                    stream.clientName ?: "unknown",
                    stream.profileId ?: "unknown",
                    (stream.contentLengthBytes ?: 0L).toString(),
                )
            }
            val audioChunks = if (stream != null && (collectFullAudio || streamingPath != null)) {
                collectAudio(client, stream!!, streamingPath, streamSink)
            } else emptyList()
            val streamBytesPulled = if (audioChunks.isNotEmpty()) audioChunks.sumOf { it.size.toLong() } else selectedStreamBytesPulled
            val audioExpectedBytes = stream?.contentLengthBytes
            val audioComplete = collectFullAudio && audioChunks.isNotEmpty() &&
                (audioExpectedBytes == null || audioExpectedBytes == streamBytesPulled)
            val audioCachePath = when {
                streamingPath != null -> streamingPath
                audioComplete -> cacheAudioChunks(audioChunks)
                else -> null
            }
            if (streamingPath != null) streamSink?.onStreamCompleted()

            val loginStatus: Int
            val loginBytes: Int
            val loginState: String
            if (normalizedCookie == null) {
                loginStatus = 0
                loginBytes = 0
                loginState = "SKIP_NO_CREDENTIAL"
            } else {
                stage = "login"
                val loginResponse = innerTube.browse(
                    client = YouTubeClient.WEB_REMIX,
                    browseId = "FEmusic_home",
                    setLogin = true,
                )
                val loginBody = loginResponse.bodyAsTextLimited(MAX_RESPONSE_BYTES)
                loginStatus = loginResponse.status.value
                loginBytes = loginBody.encodeToByteArray().size
                loginState = if (loginResponse.status.isSuccess() && loginBytes > 1_000) "PASS" else "FAIL"
            }

            return ProbeResult(
                darwinHttpOk = darwinResponse?.status?.isSuccess() == true && darwinBody.isNotBlank(),
                darwinStatus = darwinResponse?.status?.value ?: 0,
                browseOk = browseResponse?.status?.isSuccess() == true && browseBody.contains(playlistId),
                browseStatus = browseResponse?.status?.value ?: 0,
                browseBytes = browseBody.encodeToByteArray().size,
                searchOk = searchResponse?.status?.isSuccess() == true && searchBody.length > 1_000,
                searchStatus = searchResponse?.status?.value ?: 0,
                searchBytes = searchBody.encodeToByteArray().size,
                streamOk = stream != null,
                streamAttempts = streamAttempts,
                streamFailure = streamFailure,
                audioUrl = stream?.audioUrl,
                audioHeaders = stream?.headers.orEmpty(),
                audioMimeType = stream?.mimeType,
                audioItag = stream?.itag ?: -1,
                audioClient = stream?.clientName,
                audioProfile = stream?.profileId,
                isSabr = stream?.sabrBootstrap != null || stream?.audioUrl?.startsWith("sabr://") == true,
                streamDiagnostics = lastStreamDiagnostics,
                streamRunSummaries = streamRunSummaries,
                sampleCandidates = streamAttempts,
                samplePassed = sampleTrackResults.count { "result=PASS" in it },
                sampleTrackResults = sampleTrackResults,
                streamBytesPulled = streamBytesPulled,
                streamUrlObtained = stream != null && stream.audioUrl.isNotBlank(),
                audioChunks = audioChunks,
                audioExpectedBytes = audioExpectedBytes,
                audioExpiresAtMs = stream?.expiresAt?.toEpochMilliseconds(),
                audioComplete = audioComplete,
                audioCachePath = audioCachePath,
                prefixReadable = selectedPrefixReadable,
                prefixFailure = selectedPrefixFailure,
                loginState = loginState,
                loginStatus = loginStatus,
                loginBytes = loginBytes,
                diagnostic = logLines.takeLast(120).joinToString("\n"),
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            streamSink?.onStreamFailed(error::class.simpleName ?: "KotlinException", sanitizeFailureMessage(error.message).orEmpty())
            return ProbeResult(
                streamFailure = "${error::class.simpleName ?: "KotlinException"}: ${error.message ?: "no_message"}",
                failureStage = stage,
                failureType = error::class.simpleName ?: "KotlinException",
                failureMessage = sanitizeFailureMessage(
                    listOfNotNull(
                        error.toString(),
                        error.cause?.toString(),
                    ).joinToString(" | "),
                ),
                diagnostic = logLines.takeLast(120).joinToString("\n"),
            )
        } finally {
            if (!useCachedPlaybackBundle) {
                innerTube.close()
                client.close()
            }
        }
    }

    private suspend fun getCachedPlaybackBundle(
        cookie: String?,
        tokenGroup: String,
        tokenServiceUrl: String,
        logger: InnerTubeLogger,
        warm: Boolean,
    ): PlaybackBundle = playbackBundleMutex.withLock {
        val key = "${tokenGroup}:${cookie.orEmpty()}"
        cachedPlaybackBundle?.takeIf { cachedPlaybackKey == key }?.let { return@withLock it }
        cachedPlaybackBundle?.let {
            it.innerTube.close()
            it.client.close()
        }
        val bundle = createPlaybackBundle(cookie, tokenGroup, tokenServiceUrl, logger, warm = warm)
        cachedPlaybackBundle = bundle
        cachedPlaybackKey = key
        bundle
    }

    private suspend fun createPlaybackBundle(
        cookie: String?,
        tokenGroup: String,
        tokenServiceUrl: String,
        logger: InnerTubeLogger,
        warm: Boolean,
    ): PlaybackBundle {
        val client = createHttpClient(probeEngine())
        val innerTube = InnerTube(client, logger = logger)
        try {
            cookie?.trim()?.takeIf(String::isNotEmpty)?.let {
                innerTube.cookie = it
                innerTube.useLoginForBrowse = true
            }
            val configRepository = createPlayerConfigRepository()
            val remoteStore = RemotePlayerConfigStore(client, configRepository, logger)
            val cipher = YouTubeCipherService(client, remoteStore, logger)
            val tokenProvider = if (tokenGroup == "2a") {
                BgutilTokenProvider(client, tokenServiceUrl, mutableListOf())
            } else {
                null
            }
            val extractor = InnerTubeExtractor(
                configParser = YtConfigParserImpl(client, innerTube, remoteStore, logger)
                    .withEmbeddedConfigFallback(),
                cipherService = cipher,
                innerTube = innerTube,
                tokenProvider = tokenProvider,
                logger = logger,
            )
            if (warm) extractor.prewarm()
            return PlaybackBundle(client, innerTube, extractor)
        } catch (error: Throwable) {
            innerTube.close()
            client.close()
            throw error
        }
    }

    private fun YtConfigParser.withEmbeddedConfigFallback(): YtConfigParser =
        object : YtConfigParser by this {
            override suspend fun fetchConfig(videoId: String, useLoginCookies: Boolean): com.metrolist.innertubex.extraction.PlayerConfig =
                try {
                    this@withEmbeddedConfigFallback.fetchConfig(videoId, useLoginCookies)
                } catch (_: IllegalStateException) {
                    this@withEmbeddedConfigFallback.fetchEmbeddedConfig(videoId, useLoginCookies = false)
                }
        }

    private companion object {
        private const val MAX_RESPONSE_BYTES: Int = 8 * 1024 * 1024
        private val SAFE_LOG_VALUE = Regex("[A-Za-z0-9_.-]{1,80}")
        private val TOKEN_DIAGNOSTIC_EVENTS =
            setOf(
                "tokenized request selected",
                "token fetch completed",
                "token binding rejected",
                "tokenized response unavailable",
                "playback-ready client response",
            )
    }
}

private fun sanitizeFailureMessage(message: String?): String? = message
    ?.replace(Regex("https?://\\S+"), "<url>")
    ?.replace(Regex("(?i)cookie[=:]\\S+"), "cookie=<redacted>")
    ?.take(240)

@OptIn(ExperimentalSabrApi::class)
private suspend fun collectAudio(
    client: HttpClient,
    stream: com.metrolist.innertubex.extraction.ExtractedStream,
    streamingPath: String? = null,
    streamSink: AudioStreamSink? = null,
): List<ByteArray> {
    val maximumBytes = MAX_PLAYBACK_CACHE_BYTES
    val chunks = mutableListOf<ByteArray>()
    var total = 0L
    val bootstrap = stream.sabrBootstrap
    if (bootstrap != null) {
        SabrAudioStream(client, bootstrap).bytes().collect { chunk ->
            check(total + chunk.size <= maximumBytes) { "SABR playback probe exceeded 64 MiB cache limit" }
            total += chunk.size
            if (streamingPath != null) {
                val available = appendStreamingAudioFile(streamingPath, chunk)
                streamSink?.onChunkAvailable(available.toString())
            } else {
                chunks += chunk
            }
        }
        if (streamingPath != null) finishStreamingAudioFile(streamingPath)
        return chunks
    }
    if (!stream.audioUrl.startsWith("https://")) return emptyList()
    client.prepareGet(stream.audioUrl) {
        stream.headers.forEach { (name, value) -> header(name, value) }
    }.execute { response ->
        if (!response.status.isSuccess()) return@execute
        val channel = response.bodyAsChannel()
        val buffer = ByteArray(64 * 1024)
        while (total < maximumBytes) {
            val read = channel.readAvailable(buffer, 0, minOf(buffer.size.toLong(), maximumBytes - total).toInt())
            if (read < 0) break
            if (read == 0) continue
            chunks += buffer.copyOf(read)
            total += read
        }
        check(total < maximumBytes) { "Direct playback probe exceeded 64 MiB cache limit" }
        channel.cancel()
    }
    return chunks
}

internal expect fun cacheAudioChunks(chunks: List<ByteArray>): String?
internal expect fun createStreamingAudioFile(): String?
internal expect fun appendStreamingAudioFile(path: String, chunk: ByteArray): Long
internal expect fun finishStreamingAudioFile(path: String)

private data class DirectPlayerExtraction(
    val stream: com.metrolist.innertubex.extraction.ExtractedStream?,
    val diagnostic: String,
)

private val DIRECT_PLAYER_JSON = Json { ignoreUnknownKeys = true }

private suspend fun extractDirectPlayerAudio(
    innerTube: InnerTube,
    videoId: String,
): DirectPlayerExtraction {
    val initialSession = innerTube.sessionSnapshot()
    val visitorData = initialSession.visitorData ?: innerTube.fetchFreshVisitorData(initialSession)
    val response = innerTube.player(
        client = YouTubeClient.VISIONOS_0_1,
        videoId = videoId,
        requestVisitorData = visitorData,
    )
    if (!response.status.isSuccess()) return DirectPlayerExtraction(null, "http=${response.status.value} result=HTTP_FAILURE")
    val body = response.bodyAsText()
    val playerResponse = runCatching {
        DIRECT_PLAYER_JSON.decodeFromString<PlayerResponse>(body)
    }.getOrNull() ?: return DirectPlayerExtraction(null, "http=${response.status.value} decode=FAIL bodyChars=${body.length}")
    val streamingData = playerResponse.streamingData
    if (playerResponse.playabilityStatus.status !in setOf("OK", "PLAYABLE") || streamingData == null) {
        val reason = playerResponse.playabilityStatus.reason.orEmpty().replace(Regex("[^A-Za-z0-9 _-]"), "").replace(' ', '_').take(80)
        return DirectPlayerExtraction(null, "http=${response.status.value} playability=${playerResponse.playabilityStatus.status} reason=${reason.ifBlank { "none" }} visitorPresent=${!visitorData.isNullOrBlank()} streamingData=${streamingData != null}")
    }
    val audioFormats = streamingData.adaptiveFormats.filter { it.isAudio }
    val urlFormats = audioFormats.filter { !it.url.isNullOrBlank() }
    val unsignedFormats = audioFormats.filter { it.signatureCipher.isNullOrBlank() && it.cipher.isNullOrBlank() }
    val format = selectBestAudioFormat(
        formats = audioFormats.filter {
            it.isAudio && it.signatureCipher.isNullOrBlank() && it.cipher.isNullOrBlank()
        },
        audioQuality = AudioQuality.MP4,
    ) ?: return DirectPlayerExtraction(null, "http=${response.status.value} playability=PLAYABLE audio=${audioFormats.size} urls=${urlFormats.size} unsigned=${unsignedFormats.size} mp4=${audioFormats.count { it.mimeType.contains("audio/mp4") }} result=NO_DIRECT_FORMAT")
    val mediaUrl = format.url?.takeIf { isTrustedDirectAudioUrl(it) && !hasNParameter(it) }
        ?: return DirectPlayerExtraction(null, "http=${response.status.value} playability=PLAYABLE itag=${format.itag} result=URL_REJECTED")
    val codec = Regex("codecs=\"([^\"]+)\"").find(format.mimeType)?.groupValues?.getOrNull(1)
    val expiresAt = streamingData.expiresInSeconds?.takeIf { it > 0 }?.let { Clock.System.now() + it.seconds }
    val stream = com.metrolist.innertubex.extraction.ExtractedStream(
        videoId = videoId,
        audioUrl = mediaUrl,
        headers = emptyMap(),
        loudnessDb = format.loudnessDb,
        expiresAt = expiresAt,
        contentLengthBytes = format.contentLength,
        itag = format.itag,
        mimeType = format.mimeType.substringBefore(';').trim(),
        codecs = codec,
        bitrate = format.bitrate,
        sampleRate = format.audioSampleRate,
        clientName = YouTubeClient.VISIONOS_0_1.clientName,
        profileId = "VISIONOS_0_1__direct_player",
        requireBoundedRange = false,
        rangeChunkSizeBytes = 1_048_576L,
    )
    return DirectPlayerExtraction(stream, "http=${response.status.value} playability=PLAYABLE audio=${audioFormats.size} urls=${urlFormats.size} unsigned=${unsignedFormats.size} itag=${format.itag} result=PASS")
}

private fun isTrustedDirectAudioUrl(value: String): Boolean =
    runCatching { io.ktor.http.Url(value) }.getOrNull()?.let { url ->
        url.protocol == io.ktor.http.URLProtocol.HTTPS &&
            url.port == 443 &&
            (url.host == "googlevideo.com" || url.host.endsWith(".googlevideo.com")) &&
            url.encodedPath == "/videoplayback" &&
            url.user == null &&
            url.password == null
    } == true

private fun hasNParameter(value: String): Boolean =
    Regex("[?&]n=[^&]+", RegexOption.IGNORE_CASE).containsMatchIn(value)

private fun extractPlaylistVideoIds(body: String): List<String> {
    val ids = linkedSetOf<String>()
    fun visit(element: kotlinx.serialization.json.JsonElement) {
        when (element) {
            is kotlinx.serialization.json.JsonObject -> element.forEach { (key, value) ->
                if (key == "videoId" && value is kotlinx.serialization.json.JsonPrimitive) {
                    value.contentOrNull?.takeIf { VIDEO_ID.matches(it) }?.let(ids::add)
                }
                visit(value)
            }
            is kotlinx.serialization.json.JsonArray -> element.forEach(::visit)
            else -> Unit
        }
    }
    runCatching { visit(Json.parseToJsonElement(body)) }
    return ids.toList()
}

@OptIn(ExperimentalSabrApi::class)
private suspend fun pullAudioPrefix(
    client: HttpClient,
    stream: com.metrolist.innertubex.extraction.ExtractedStream,
): Long {
    val targetBytes = MIN_SAMPLE_BYTES
    val bootstrap = stream.sabrBootstrap
    if (bootstrap != null) {
        var count = 0L
        SabrAudioStream(client, bootstrap).bytes()
            .takeWhile { count < targetBytes }
            .collect { chunk -> count += chunk.size }
        return count
    }
    if (!stream.audioUrl.startsWith("https://")) return 0L
    return client.prepareGet(stream.audioUrl) {
        header("Range", "bytes=0-${targetBytes - 1}")
        stream.headers.forEach { (name, value) -> header(name, value) }
    }.execute { response ->
        if (!response.status.isSuccess()) return@execute 0L
        val channel = response.bodyAsChannel()
        val buffer = ByteArray(32 * 1024)
        var count = 0L
        while (count < targetBytes) {
            val read = channel.readAvailable(buffer, 0, minOf(buffer.size.toLong(), targetBytes - count).toInt())
            if (read < 0) break
            if (read == 0) continue
            count += read
        }
        channel.cancel()
        count
    }
}

private val VIDEO_ID = Regex("[A-Za-z0-9_-]{11}")
private const val MIN_SAMPLE_BYTES = 256L * 1024L
private const val MAX_PLAYBACK_CACHE_BYTES = 64L * 1024L * 1024L

private class BgutilTokenProvider(
    private val client: HttpClient,
    private val endpoint: String,
    private val logLines: MutableList<String>,
) : TokenProvider {
    override val capabilities: TokenProviderCapabilities =
        TokenProviderCapabilities(setOf(PoTokenProviderKind.EXTERNAL), usesWebView = false)

    override suspend fun getPoToken(videoId: String, visitorData: String, cookie: String?): PoTokenResult? {
        val started = TimeSource.Monotonic.markNow()
        val callIndex = calls++
        return try {
            val player = requestToken(visitorData)
            val streaming = requestToken(videoId)
            val elapsedMs = started.elapsedNow().inWholeMilliseconds
            val valid = player.binding == visitorData && streaming.binding == videoId &&
                player.token.isNotBlank() && streaming.token.isNotBlank() && player.token != streaming.token
            logLines += "PROBE_TOKEN group=2a providers=[EXTERNAL] call=$callIndex videoId=$videoId playerPresence=${player.token.isNotBlank()} playerLength=${player.token.length} streamingPresence=${streaming.token.isNotBlank()} streamingLength=${streaming.token.length} distinct=${player.token != streaming.token} bindingValid=$valid elapsedMs=$elapsedMs"
            if (!valid) return null
            PoTokenResult(player.token, streaming.token, visitorData)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            logLines += "PROBE_TOKEN group=2a providers=[EXTERNAL] call=$callIndex videoId=$videoId tokenPresence=missing errorType=${error::class.simpleName ?: "unknown"}"
            null
        }
    }

    private var calls = 0

    private suspend fun requestToken(binding: String): BoundToken {
        val response = client.post(endpoint) {
            contentType(ContentType.Application.Json)
            setBody(buildJsonObject { put("content_binding", binding) })
        }
        if (response.status.value !in 200..299) throw IllegalStateException("bgutil_http_${response.status.value}")
        val json = Json.parseToJsonElement(response.bodyAsText()) as? JsonObject
            ?: throw IllegalStateException("bgutil_invalid_json")
        val token = json["poToken"]?.jsonPrimitive?.contentOrNull
            ?: throw IllegalStateException("bgutil_token_missing")
        val returnedBinding = json["contentBinding"]?.jsonPrimitive?.contentOrNull
            ?: throw IllegalStateException("bgutil_binding_missing")
        return BoundToken(token, returnedBinding)
    }

    private data class BoundToken(val token: String, val binding: String)
}

private fun createHttpClient(engine: HttpClientEngine): HttpClient =
    HttpClient(engine) {
        expectSuccess = false
        install(HttpTimeout) {
            requestTimeoutMillis = 60_000
            connectTimeoutMillis = 30_000
            socketTimeoutMillis = 60_000
        }
        install(ContentNegotiation) {
            json(Json { ignoreUnknownKeys = true })
        }
    }

internal expect fun probeEngine(): HttpClientEngine
