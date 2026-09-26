package io.github.hck5722.ytmprobe

import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.okhttp.OkHttp

internal actual fun probeEngine(): HttpClientEngine = OkHttp.create()

internal actual fun cacheAudioChunks(chunks: List<ByteArray>): String? = null
internal actual fun createStreamingAudioFile(): String? = null
internal actual fun appendStreamingAudioFile(path: String, chunk: ByteArray): Long = 0L
internal actual fun finishStreamingAudioFile(path: String) = Unit
