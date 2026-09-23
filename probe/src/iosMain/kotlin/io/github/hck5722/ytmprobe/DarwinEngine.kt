package io.github.hck5722.ytmprobe

import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.darwin.Darwin
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.Foundation.NSData
import platform.Foundation.NSFileManager
import platform.Foundation.NSUUID
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.create

internal actual fun probeEngine(): HttpClientEngine = Darwin.create()

@OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
internal actual fun cacheAudioChunks(chunks: List<ByteArray>): String? {
    val total = chunks.sumOf { it.size.toLong() }
    if (total == 0L || total > Int.MAX_VALUE) return null
    val bytes = ByteArray(total.toInt())
    var offset = 0
    chunks.forEach { chunk ->
        chunk.copyInto(bytes, offset)
        offset += chunk.size
    }
    if (bytes.isEmpty()) return null
    val name = "ytm-probe-${NSUUID().UUIDString}.webm"
    val path = platform.Foundation.NSTemporaryDirectory() + name
    val data = bytes.usePinned { pinned ->
        NSData.create(bytes = pinned.addressOf(0), length = bytes.size.toULong())
    }
    return if (NSFileManager.defaultManager.createFileAtPath(path, data, null)) path else null
}
