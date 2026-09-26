package io.github.hck5722.ytmprobe

import java.net.HttpURLConnection
import java.net.URI
import kotlinx.coroutines.runBlocking

private data class Options(
    val providers: String,
    val potUrl: String,
    val cookie: String?,
    val video: String?,
    val videos: List<String>,
    val sampleCount: Int,
    val fastPlayback: Boolean,
    val repeat: Int,
    val clientOverride: String?,
    val noPrewarm: Boolean,
    val directPlayer: Boolean,
)

public fun main(args: Array<String>) {
    val options = parseOptions(args)
    fun safe(value: String?): String = value.orEmpty().let { raw ->
        options.cookie?.takeIf(String::isNotEmpty)?.let { raw.replace(it, "<redacted>") } ?: raw
    }
    val resultFileSafe = options.cookie == null
    println("PROBE_DESKTOP=PASS runtime=jvm target=desktop")
    println("PROBE_PROXY=${proxyState()}")
    printEgressIdentity()
    println("PROBE_TOKEN_CONFIG providers=[${if (options.providers == "EXTERNAL") "EXTERNAL" else ""}]")
    if (!resultFileSafe) {
        println("PROBE_COOKIE=PASS source=env presence=true length=${options.cookie.length}")
    } else {
        println("PROBE_COOKIE=SKIP_NO_CREDENTIAL")
    }

    val probe = YTMProbe()
    if (options.noPrewarm) {
        println("PROBE_PREWARM=SKIP reason=cold_start")
    } else {
        val prewarmStartedAt = System.nanoTime()
        val prewarmOk = runBlocking {
            probe.prewarmPlayback(
                cookie = options.cookie,
                tokenGroup = if (options.providers == "EXTERNAL") "2a" else "baseline",
                tokenServiceUrl = options.potUrl,
            )
        }
        println("PROBE_PREWARM=${if (prewarmOk) "PASS" else "FAIL"} elapsedMs=${(System.nanoTime() - prewarmStartedAt) / 1_000_000}")
    }
    val startedAt = System.nanoTime()
    val result = runBlocking {
        probe.run(
            playlistId = "PLd9orNjDFThOxxBaWd36m-6a87SO34Y62",
            videoId = options.videos.firstOrNull() ?: options.video ?: "DcDbKDAb7go",
            cookie = options.cookie,
            tokenGroup = if (options.providers == "EXTERNAL") "2a" else "baseline",
            tokenServiceUrl = options.potUrl,
            candidateVideoIds = options.videos.ifEmpty { options.video?.let(::listOf) ?: DEFAULT_CANDIDATES },
            sampleCount = options.sampleCount,
            fastPlayback = options.fastPlayback,
            directPlayerFastPath = options.directPlayer,
            playbackClientOverrideId = options.clientOverride,
        )
    }
    println("PROBE_TIMING resolveMs=${(System.nanoTime() - startedAt) / 1_000_000} fastPlayback=${options.fastPlayback}")
    repeat(options.repeat - 1) { repeatIndex ->
        val repeatStartedAt = System.nanoTime()
        val repeatVideo = options.video ?: DEFAULT_CANDIDATES[(repeatIndex + 1) % DEFAULT_CANDIDATES.size]
        runBlocking {
            probe.run(
                playlistId = "PLd9orNjDFThOxxBaWd36m-6a87SO34Y62",
                videoId = repeatVideo,
                cookie = options.cookie,
                tokenGroup = if (options.providers == "EXTERNAL") "2a" else "baseline",
                tokenServiceUrl = options.potUrl,
                candidateVideoIds = listOf(repeatVideo),
                sampleCount = options.sampleCount,
                fastPlayback = options.fastPlayback,
                directPlayerFastPath = options.directPlayer,
                playbackClientOverrideId = options.clientOverride,
            )
        }
        println("PROBE_TIMING repeat=${repeatIndex + 2} video=$repeatVideo resolveMs=${(System.nanoTime() - repeatStartedAt) / 1_000_000} fastPlayback=${options.fastPlayback}")
    }

    println("PROBE_1_LINK=PASS framework=YTMProbe target=desktop")
    println("PROBE_2_HTTP=${if (result.darwinHttpOk) "PASS" else "FAIL"} status=${result.darwinStatus}")
    println("PROBE_3_BROWSE=${if (result.browseOk) "PASS" else "FAIL"} status=${result.browseStatus} bytes=${result.browseBytes}")
    println("PROBE_3_SEARCH=${if (result.searchOk) "PASS" else "FAIL"} status=${result.searchStatus} bytes=${result.searchBytes}")
    println(
        "PROBE_4_STREAM=${if (result.streamOk) "PASS" else "FAIL"} " +
            "attempts=${result.streamAttempts} failure=${safe(result.streamFailure ?: "nil")} " +
            "itag=${result.audioItag} mime=${result.audioMimeType ?: "nil"} " +
            "client=${result.audioClient ?: "nil"} profile=${result.audioProfile ?: "nil"} sabr=${result.isSabr}",
    )
    println("PROBE_DIAG_SUMMARY ${safe(result.streamDiagnostics)}")
    println("PROBE_4A1_STREAM_URL=${if (result.streamUrlObtained) "OBTAINED" else "MISSING"} bytesPulled=${result.streamBytesPulled} thresholdBytes=262144")
    println("PROBE_4A2_SAMPLE=complete candidates=${result.sampleCandidates} passed=${result.samplePassed} failed=${result.sampleCandidates - result.samplePassed}")
    result.sampleTrackResults.forEach { println("PROBE_4A2_TRACK ${safe(it)}") }
    result.streamRunSummaries.forEach { println("PROBE_DIAG_RUN ${safe(it)}") }
    result.diagnostic.lineSequence()
        .filter {
            it.startsWith("PROBE_TOKEN ") ||
                it.startsWith("PROBE_TOKEN_ATTEMPT ") ||
                it.startsWith("PROBE_TIMING_DIRECT_PLAYER ")
        }
        .map(::safe)
        .forEach(::println)
    println("PROBE_6_LOGIN=${result.loginState} status=${result.loginStatus} bytes=${result.loginBytes}")
    println("PROBE_5_AVPLAYER=SKIP reason=desktop_target_no_AVPlayer")
}

private fun parseOptions(args: Array<String>): Options {
    var providers = "NONE"
    var potUrl = "http://127.0.0.1:4416/get_pot"
    var cookie: String? = null
    var video: String? = null
    var videos = emptyList<String>()
    var sampleCount = 1
    var fastPlayback = false
    var repeat = 1
    var clientOverride: String? = null
    var noPrewarm = false
    var directPlayer = false
    args.forEach { arg ->
        when {
            arg.startsWith("--providers=") -> providers = arg.substringAfter('=').uppercase()
            arg.startsWith("--pot-url=") -> potUrl = arg.substringAfter('=')
            arg.startsWith("--video=") -> video = arg.substringAfter('=').takeIf(String::isNotBlank)
            arg.startsWith("--videos=") -> videos = arg.substringAfter('=').split(',').map(String::trim).filter(String::isNotBlank)
            arg.startsWith("--sample-count=") -> sampleCount = arg.substringAfter('=').toInt()
            arg == "--fast" -> fastPlayback = true
            arg.startsWith("--repeat=") -> repeat = arg.substringAfter('=').toInt()
            arg.startsWith("--client=") -> clientOverride = arg.substringAfter('=').takeIf(String::isNotBlank)
            arg == "--cold" -> noPrewarm = true
            arg == "--direct-player" -> directPlayer = true
            arg == "--cookie=env:YT_COOKIE" -> cookie = System.getenv("YT_COOKIE")?.takeIf(String::isNotBlank)
            arg.startsWith("--cookie=") -> error("cookie 参数只允许 --cookie=env:YT_COOKIE")
            else -> error("未知参数: $arg")
        }
    }
    require(providers == "NONE" || providers == "EXTERNAL") { "--providers 只能是 NONE 或 EXTERNAL" }
    require(sampleCount in 1..30) { "--sample-count 必须介于 1 和 30" }
    require(repeat in 1..5) { "--repeat 必须介于 1 和 5" }
    if (providers == "EXTERNAL") require(potUrl.startsWith("http://127.0.0.1:")) { "EXTERNAL 服务必须是本机 127.0.0.1" }
    require(video == null || videos.isEmpty()) { "--video 与 --videos 不能同时使用" }
    require(videos.size <= 30) { "--videos 最多支持 30 个 ID" }
    return Options(providers, potUrl, cookie, video, videos, sampleCount, fastPlayback, repeat, clientOverride, noPrewarm, directPlayer)
}

private val DEFAULT_CANDIDATES = listOf("DcDbKDAb7go", "XgAgFCO-ufI", "MpevbZazUf8", "nqMYG2Riq54")

private fun printEgressIdentity() {
    try {
        val ip = fetchText("https://api.ipify.org").trim().take(80)
        println("PROBE_EGRESS_IP=PASS ip=$ip")
        val json = fetchText("https://ipinfo.io/json")
        val org = Regex("\"org\"\\s*:\\s*\"([^\"]*)\"").find(json)?.groupValues?.get(1)?.take(120) ?: "unknown"
        val asn = Regex("\"asn\"\\s*:\\s*\"([^\"]*)\"").find(json)?.groupValues?.get(1)?.take(80)
            ?: Regex("\\bAS\\d+\\b").find(org)?.value
            ?: "unknown"
        println("PROBE_EGRESS_META=PASS org=$org asn=$asn")
    } catch (error: Exception) {
        println("PROBE_EGRESS=FAIL errorType=${error::class.simpleName ?: "unknown"}")
    }
}

private fun proxyState(): String {
    val envNames = listOf("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")
    val envPresent = envNames.any { !System.getenv(it).isNullOrBlank() }
    val systemPresent = listOf("http.proxyHost", "https.proxyHost", "socksProxyHost").any { !System.getProperty(it).isNullOrBlank() }
    return "${if (envPresent || systemPresent) "DETECTED" else "NOT_DETECTED"} envOrSystemPresence=${envPresent || systemPresent}"
}

private fun fetchText(url: String): String {
    val connection = URI(url).toURL().openConnection() as HttpURLConnection
    connection.connectTimeout = 15_000
    connection.readTimeout = 15_000
    connection.requestMethod = "GET"
    return connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
}
