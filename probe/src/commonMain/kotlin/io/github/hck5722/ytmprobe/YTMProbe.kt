package io.github.hck5722.ytmprobe

import com.metrolist.innertubex.InnerTube
import com.metrolist.innertubex.InnerTubeLogEvent
import com.metrolist.innertubex.InnerTubeLogger
import com.metrolist.innertubex.bodyAsTextLimited
import com.metrolist.innertubex.cipher.YouTubeCipherService
import com.metrolist.innertubex.extraction.AudioQuality
import com.metrolist.innertubex.extraction.ContentHints
import com.metrolist.innertubex.extraction.InnerTubeExtractor
import com.metrolist.innertubex.extraction.YtConfigParserImpl
import com.metrolist.innertubex.models.YouTubeClient
import io.ktor.client.HttpClient
import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.json.Json

public class YTMProbe {
    public suspend fun run(
        playlistId: String,
        videoId: String,
        cookie: String?,
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
            val extractor = InnerTubeExtractor(
                configParser = YtConfigParserImpl(client, innerTube, logger = logger),
                cipherService = cipher,
                innerTube = innerTube,
                logger = logger,
            )
            val stream = extractor.extract(
                videoId = videoId,
                hints = ContentHints(wantVideo = false),
                audioQuality = AudioQuality.AUTO,
            )

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
                audioUrl = stream?.audioUrl,
                audioHeaders = stream?.headers.orEmpty(),
                audioMimeType = stream?.mimeType,
                audioItag = stream?.itag ?: -1,
                audioClient = stream?.clientName,
                audioProfile = stream?.profileId,
                isSabr = stream?.sabrBootstrap != null || stream?.audioUrl?.startsWith("sabr://") == true,
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
