package com.github.hck5722.ytmkit

import com.metrolist.innertubex.InnerTube
import com.metrolist.innertubex.cipher.YouTubeCipherService
import com.metrolist.innertubex.extraction.AudioQuality
import com.metrolist.innertubex.extraction.ContentHints
import com.metrolist.innertubex.extraction.InnerTubeExtractor
import com.metrolist.innertubex.extraction.YtConfigParserImpl
import com.metrolist.innertubex.models.YouTubeClient
import com.metrolist.innertubex.models.YouTubeLocale
import io.ktor.client.HttpClient
import io.ktor.client.statement.bodyAsText
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

internal expect fun platformHttpClient(): HttpClient

/** Stable, Swift-friendly DTOs. innertubex types stay behind this boundary. */
public data class ItemDTO(
    public val id: String,
    public val title: String,
    public val subtitle: String = "",
    public val thumbnailUrl: String? = null,
)

public data class SectionDTO(
    public val title: String,
    public val items: List<ItemDTO>,
)

public data class PlaylistDTO(
    public val id: String,
    public val title: String,
    public val author: String = "",
    public val items: List<ItemDTO> = emptyList(),
    public val error: String = "",
)

public data class StreamInfoDTO(
    public val videoId: String,
    public val mimeType: String,
    public val codec: String,
    public val durationMs: Long,
    public val itag: Int,
    public val isSabr: Boolean,
    public val client: String,
    public val profile: String,
    public val error: String = "",
)

/** Narrow façade for the first vertical slice. */
public class YTMKit {
    private val client: HttpClient = platformHttpClient()
    private val innerTube: InnerTube = InnerTube(client)
    private val extractor: InnerTubeExtractor by lazy {
        InnerTubeExtractor(
            configParser = YtConfigParserImpl(client, innerTube),
            cipherService = YouTubeCipherService(client),
            innerTube = innerTube,
        )
    }

    public suspend fun home(): List<SectionDTO> = try {
        sectionsFromJson(browseWithLocaleFallback("FEmusic_home").bodyAsText())
    } catch (_: Throwable) {
        emptyList()
    }

    public suspend fun search(query: String): List<ItemDTO> = try {
        itemsFromJson(searchWithLocaleFallback(query).bodyAsText())
    } catch (_: Throwable) {
        emptyList()
    }

    public suspend fun playlist(id: String): PlaylistDTO = try {
        val body = browseWithLocaleFallback("VL$id").bodyAsText()
        PlaylistDTO(
            id = id,
            title = firstText(body, "title") ?: id,
            author = firstText(body, "subtitle") ?: "",
            items = itemsFromJson(body),
        )
    } catch (error: Throwable) {
        PlaylistDTO(id = id, title = id, error = safeError(error))
    }

    public suspend fun stream(videoId: String): StreamInfoDTO = try {
        extractor.prewarm()
        val stream = requireNotNull(
            extractor.extract(
                videoId = videoId,
                hints = ContentHints(wantVideo = false),
                audioQuality = AudioQuality.MP4,
            ),
        ) { "No playable stream for $videoId" }
        StreamInfoDTO(
            videoId = videoId,
            mimeType = stream.mimeType.orEmpty(),
            codec = stream.codecs.orEmpty(),
            durationMs = 0L,
            itag = stream.itag,
            isSabr = stream.sabrBootstrap != null,
            client = stream.clientName,
            profile = stream.profileId,
        )
    } catch (error: Throwable) {
        StreamInfoDTO(videoId, "", "", 0L, -1, false, "", "", safeError(error))
    }

    public fun close() {
        innerTube.close()
        client.close()
    }

    private suspend fun browseWithLocaleFallback(browseId: String) = try {
        innerTube.browse(YouTubeClient.WEB_REMIX, browseId = browseId)
    } catch (error: Throwable) {
        if (!isHttp400(error) || isUsEnglish()) throw error
        innerTube.locale = YouTubeLocale(gl = "US", hl = "en")
        innerTube.browse(YouTubeClient.WEB_REMIX, browseId = browseId)
    }

    private suspend fun searchWithLocaleFallback(query: String) = try {
        innerTube.search(YouTubeClient.WEB_REMIX, query = query)
    } catch (error: Throwable) {
        if (!isHttp400(error) || isUsEnglish()) throw error
        innerTube.locale = YouTubeLocale(gl = "US", hl = "en")
        innerTube.search(YouTubeClient.WEB_REMIX, query = query)
    }

    private fun isUsEnglish(): Boolean = innerTube.locale.gl == "US" && innerTube.locale.hl == "en"

    private fun isHttp400(error: Throwable): Boolean =
        error.message?.contains("HTTP 400", ignoreCase = true) == true
}

private fun safeError(error: Throwable): String =
    (error.message ?: error::class.simpleName ?: "Unknown error")
        .replace(Regex("https?://\\S+"), "<url>")
        .take(500)

private fun itemsFromJson(body: String): List<ItemDTO> {
    val result = ArrayList<ItemDTO>()
    fun visit(element: JsonElement) {
        when (element) {
            is JsonObject -> {
                val id = element["videoId"]?.jsonPrimitive?.contentOrNull
                    ?: element["playlistId"]?.jsonPrimitive?.contentOrNull
                    ?: element["browseId"]?.jsonPrimitive?.contentOrNull
                val title = element["title"]?.let(::firstText)
                    ?: element["headline"]?.let(::firstText)
                    ?: ""
                if (!id.isNullOrBlank() && title.isNotBlank()) result += ItemDTO(id = id, title = title)
                element.values.forEach(::visit)
            }
            is JsonArray -> element.forEach(::visit)
            else -> Unit
        }
    }
    runCatching { visit(Json.parseToJsonElement(body)) }
    return result.distinctBy { it.id }.take(100)
}

private fun sectionsFromJson(body: String): List<SectionDTO> {
    val items = itemsFromJson(body)
    return if (items.isEmpty()) emptyList() else listOf(SectionDTO("Home", items))
}

private fun firstText(body: String, key: String): String? =
    runCatching { firstText(Json.parseToJsonElement(body), key) }.getOrNull()

private fun firstText(element: JsonElement?, key: String): String? = when (element) {
    is JsonObject -> element[key]?.let { firstText(it) } ?: element.values.firstNotNullOfOrNull { firstText(it, key) }
    is JsonArray -> element.firstNotNullOfOrNull { firstText(it, key) }
    else -> null
}

private fun firstText(element: JsonElement): String? = when (element) {
    is JsonPrimitive -> element.contentOrNull
    is JsonObject -> element["runs"]?.let(::firstText)
        ?: element["simpleText"]?.jsonPrimitive?.contentOrNull
        ?: element.values.firstNotNullOfOrNull(::firstText)
    is JsonArray -> element.firstNotNullOfOrNull(::firstText)
    else -> null
}
