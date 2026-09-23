package io.github.hck5722.ytmprobe

import java.net.HttpURLConnection
import java.net.URI
import kotlinx.coroutines.runBlocking

private data class Options(
    val providers: String,
    val potUrl: String,
    val cookie: String?,
    val video: String?,
    val sampleCount: Int,
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

    val result = runBlocking {
        YTMProbe().run(
            playlistId = "PLd9orNjDFThOxxBaWd36m-6a87SO34Y62",
            videoId = options.video ?: "DcDbKDAb7go",
            cookie = options.cookie,
            tokenGroup = if (options.providers == "EXTERNAL") "2a" else "baseline",
            tokenServiceUrl = options.potUrl,
            candidateVideoIds = options.video?.let(::listOf) ?: DEFAULT_CANDIDATES,
            sampleCount = options.sampleCount,
        )
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
        .filter { it.startsWith("PROBE_TOKEN ") || it.startsWith("PROBE_TOKEN_ATTEMPT ") }
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
    var sampleCount = 1
    args.forEach { arg ->
        when {
            arg.startsWith("--providers=") -> providers = arg.substringAfter('=').uppercase()
            arg.startsWith("--pot-url=") -> potUrl = arg.substringAfter('=')
            arg.startsWith("--video=") -> video = arg.substringAfter('=').takeIf(String::isNotBlank)
            arg.startsWith("--sample-count=") -> sampleCount = arg.substringAfter('=').toInt()
            arg == "--cookie=env:YT_COOKIE" -> cookie = System.getenv("YT_COOKIE")?.takeIf(String::isNotBlank)
            arg.startsWith("--cookie=") -> error("cookie 参数只允许 --cookie=env:YT_COOKIE")
            else -> error("未知参数: $arg")
        }
    }
    require(providers == "NONE" || providers == "EXTERNAL") { "--providers 只能是 NONE 或 EXTERNAL" }
    require(sampleCount in 1..30) { "--sample-count 必须介于 1 和 30" }
    if (providers == "EXTERNAL") require(potUrl.startsWith("http://127.0.0.1:")) { "EXTERNAL 服务必须是本机 127.0.0.1" }
    return Options(providers, potUrl, cookie, video, sampleCount)
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
