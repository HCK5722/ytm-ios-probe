package io.github.hck5722.ytmprobe

import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.okhttp.OkHttp
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap

internal actual fun probeEngine(): HttpClientEngine = OkHttp.create()

internal actual fun cacheAudioChunks(chunks: List<ByteArray>): String? = null
internal actual fun createStreamingAudioFile(): String? {
    val file = File.createTempFile("ytm-probe-stream-", ".mp4")
    file.deleteOnExit()
    desktopStreamLengths[file.absolutePath] = 0L
    return file.absolutePath
}

internal actual fun appendStreamingAudioFile(path: String, chunk: ByteArray): Long {
    if (chunk.isEmpty()) return desktopStreamLengths[path] ?: 0L
    RandomAccessFile(path, "rw").use { file ->
        file.seek(file.length())
        file.write(chunk)
        file.fd.sync()
    }
    return desktopStreamLengths.compute(path) { _, old -> (old ?: 0L) + chunk.size } ?: chunk.size.toLong()
}

internal actual fun finishStreamingAudioFile(path: String) {
    desktopStreamLengths.remove(path)
    File(path).delete()
}

private val desktopStreamLengths = ConcurrentHashMap<String, Long>()
