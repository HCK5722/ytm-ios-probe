package io.github.hck5722.ytmprobe

import com.metrolist.innertubex.InnerTube
import com.metrolist.innertubex.InnerTubeLogEvent
import com.metrolist.innertubex.InnerTubeLogger
import com.metrolist.innertubex.bodyAsTextLimited
import com.metrolist.innertubex.cipher.YouTubeCipherService
import com.metrolist.innertubex.extraction.AudioQuality
import com.metrolist.innertubex.extraction.ContentHints
import com.metrolist.innertubex.extraction.InnerTubeExtractor
import com.metrolist.innertubex.extraction.PoTokenResult
import com.metrolist.innertubex.extraction.StreamResolveException
import com.metrolist.innertubex.extraction.TokenProvider
import com.metrolist.innertubex.extraction.TokenProviderCapabilities
import com.metrolist.innertubex.extraction.YtConfigParserImpl
import com.metrolist.innertubex.extraction.strategy.PoTokenProviderKind
import com.metrolist.innertubex.models.YouTubeClient
import io.ktor.client.HttpClient
import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.contentOrNull
import kotlinx.coroutines.CancellationException
import kotlin.time.TimeSource

public class YTMProbe {
    public suspend fun run(
        playlistId: String,
        videoId: String,
        cookie: String?,
        tokenGroup: String = "baseline",
        tokenServiceUrl: String = "http://127.0.0.1:4416/get_pot",
    ): ProbeResult {
        val logLines = mutableListOf<String>()
        val logger = InnerTubeLogger { event: InnerTubeLogEvent ->
            logLines += "${event.level}/${event.tag}: ${event.message} ${event.details}"
        }
        val client = createHttpClient(darwinEngine())
        val innerTube = InnerTube(client, logger = logger)
        try {
            val darwinResponse = client.get("https://music.youtube.com/")
            val darwinBody = darwinResponse.bodyAsText()

            val browseResponse = innerTube.browse(YouTubeClient.WEB_REMIX, browseId = "VL$playlistId")
            val browseBody = browseResponse.bodyAsTextLimited(MAX_RESPONSE_BYTES)

            val searchResponse = innerTube.search(YouTubeClient.WEB_REMIX, query = "YouTube Music", setLogin = false)
            val searchBody = searchResponse.bodyAsTextLimited(MAX_RESPONSE_BYTES)

            val cipher = YouTubeCipherService(client, logger = logger)
            val externalTokenProvider = if (tokenGroup == "2a") {
                BgutilTokenProvider(client, tokenServiceUrl, logLines)
            } else {
                null
            }
            val extractor = InnerTubeExtractor(
                configParser = YtConfigParserImpl(client, innerTube, logger = logger),
                cipherService = cipher,
                innerTube = innerTube,
                tokenProvider = externalTokenProvider,
                logger = logger,
            )
            extractor.prewarm()
            val streamCandidates = listOf(videoId, "XgAgFCO-ufI", "MpevbZazUf8", "nqMYG2Riq54")
            var stream: com.metrolist.innertubex.extraction.ExtractedStream? = null
            var streamFailure: String? = null
            var streamAttempts = 0
            var lastStreamDiagnostics = "not_run"
            val streamRunSummaries = mutableListOf<String>()
            for (candidate in streamCandidates) {
                streamAttempts += 1
                try {
                    stream = extractor.extract(
                        videoId = candidate,
                        hints = ContentHints(wantVideo = false),
                        audioQuality = AudioQuality.AUTO,
                    )
                    if (stream != null) break
                } catch (error: Throwable) {
                    streamFailure = "${error::class.simpleName}: ${error.message}"
                    logLines += "STREAM_CANDIDATE_FAIL candidate=$candidate reason=$streamFailure"
                    val resolveError = error as? StreamResolveException
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
                        logLines += "PROBE_DIAG_RUN $runSummary"
                        if (tokenGroup != "2a") diagnostics?.attempts?.forEach { attempt ->
                            logLines += "PROBE_DIAG exceptionReason=${resolveError.reason} sawPlayable=unknown client=${attempt.clientName} profile=${attempt.profileId ?: "none"} userAgent=${attempt.userAgent} outcome=${attempt.outcome} tokenUnavailable=not_exposed requestFailure=not_exposed failurePresent=not_exposed"
                        }
                    } else {
                        val runSummary = "candidate=$candidate exceptionReason=NON_STREAM_RESOLVE $streamFailure"
                        streamRunSummaries += runSummary
                        logLines += "PROBE_DIAG_RUN $runSummary"
                    }
                }
            }

            val normalizedCookie = cookie?.trim()?.takeIf(String::isNotEmpty)
            val loginStatus: Int
            val loginBytes: Int
            val loginState: String
            if (normalizedCookie == null) {
                loginStatus = 0
                loginBytes = 0
                loginState = "SKIP_NO_CREDENTIAL"
            } else {
                innerTube.cookie = normalizedCookie
                innerTube.useLoginForBrowse = true
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
                darwinHttpOk = darwinResponse.status.isSuccess() && darwinBody.isNotBlank(),
                darwinStatus = darwinResponse.status.value,
                browseOk = browseResponse.status.isSuccess() && browseBody.contains(playlistId),
                browseStatus = browseResponse.status.value,
                browseBytes = browseBody.encodeToByteArray().size,
                searchOk = searchResponse.status.isSuccess() && searchBody.length > 1_000,
                searchStatus = searchResponse.status.value,
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
                loginState = loginState,
                loginStatus = loginStatus,
                loginBytes = loginBytes,
                diagnostic = logLines.takeLast(120).joinToString("\n"),
            )
        } finally {
            innerTube.close()
            client.close()
        }
    }

    private companion object {
        private const val MAX_RESPONSE_BYTES: Int = 8 * 1024 * 1024
    }
}

private class BgutilTokenProvider(
    private val client: HttpClient,
    private val endpoint: String,
    private val logLines: MutableList<String>,
) : TokenProvider {
    override val capabilities: TokenProviderCapabilities =
        TokenProviderCapabilities(setOf(PoTokenProviderKind.EXTERNAL), usesWebView = false)

    override suspend fun getPoToken(videoId: String, visitorData: String, cookie: String?): PoTokenResult? {
        val started = TimeSource.Monotonic.markNow()
        return try {
            val player = requestToken(visitorData)
            val streaming = requestToken(videoId)
            val elapsedMs = started.elapsedNow().inWholeMilliseconds
            val valid = player.binding == visitorData && streaming.binding == videoId &&
                player.token.isNotBlank() && streaming.token.isNotBlank() && player.token != streaming.token
            logLines += "PROBE_TOKEN group=2a providers=[EXTERNAL] playerPresence=${player.token.isNotBlank()} playerLength=${player.token.length} streamingPresence=${streaming.token.isNotBlank()} streamingLength=${streaming.token.length} distinct=${player.token != streaming.token} bindingValid=$valid elapsedMs=$elapsedMs"
            if (!valid) return null
            PoTokenResult(player.token, streaming.token, visitorData)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            logLines += "PROBE_TOKEN group=2a providers=[EXTERNAL] tokenPresence=missing errorType=${error::class.simpleName ?: "unknown"}"
            null
        }
    }

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

internal expect fun darwinEngine(): HttpClientEngine
