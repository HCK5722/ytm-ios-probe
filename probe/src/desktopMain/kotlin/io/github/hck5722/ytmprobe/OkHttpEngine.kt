package io.github.hck5722.ytmprobe

import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.okhttp.OkHttp

internal actual fun probeEngine(): HttpClientEngine = OkHttp.create()

internal actual fun cacheAudioChunks(chunks: List<ByteArray>): String? = null
