package io.github.hck5722.ytmprobe

import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.darwin.Darwin

internal actual fun probeEngine(): HttpClientEngine = Darwin.create()
