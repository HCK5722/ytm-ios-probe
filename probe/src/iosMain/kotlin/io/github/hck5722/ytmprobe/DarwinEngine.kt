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
import platform.Foundation.NSFileHandle
import platform.Foundation.fileHandleForWritingAtPath
import platform.Foundation.writeData
import platform.Foundation.seekToEndOfFile
import platform.Foundation.closeFile

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

@OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
internal actual fun createStreamingAudioFile(): String? {
    val path = NSTemporaryDirectory() + "ytm-probe-stream-${NSUUID().UUIDString}.mp4"
    return if (NSFileManager.defaultManager.createFileAtPath(path, null, null)) {
        streamFileLengths[path] = 0L
        path
    } else null
}

@OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
internal actual fun appendStreamingAudioFile(path: String, chunk: ByteArray): Long {
    if (chunk.isEmpty()) return streamFileLengths[path] ?: 0L
    val data = chunk.usePinned { pinned -> NSData.create(bytes = pinned.addressOf(0), length = chunk.size.toULong()) }
    val handle = NSFileHandle.fileHandleForWritingAtPath(path) ?: return 0L
    handle.seekToEndOfFile()
    handle.writeData(data)
    handle.closeFile()
    val length = (streamFileLengths[path] ?: 0L) + chunk.size
    streamFileLengths[path] = length
    return length
}

internal actual fun finishStreamingAudioFile(path: String) { streamFileLengths.remove(path) }

private val streamFileLengths = mutableMapOf<String, Long>()
