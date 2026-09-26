package io.github.hck5722.ytmprobe

import com.metrolist.innertubex.cipher.PlayerConfigRepository
import java.util.prefs.Preferences

internal actual fun createPlayerConfigRepository(): PlayerConfigRepository =
    object : PlayerConfigRepository {
        private val preferences = Preferences.userRoot().node("io.github.hck5722.ytmprobe.player_config")

        override val enabled: Boolean = true
        override val sourceUrl: String = PLAYER_CONFIG_URL
        override val defaultSourceUrl: String = PLAYER_CONFIG_URL
        override var cachedJson: String
            get() = preferences.get("json", "")
            set(value) = preferences.put("json", value)
        override var cachedAtMs: Long
            get() = preferences.getLong("cached_at_ms", 0L)
            set(value) = preferences.putLong("cached_at_ms", value)
        override var cachedSourceUrl: String
            get() = preferences.get("source_url", "")
            set(value) = preferences.put("source_url", value)
        override var cachedEtag: String
            get() = preferences.get("etag", "")
            set(value) = preferences.put("etag", value)
    }

private const val PLAYER_CONFIG_URL =
    "https://raw.githubusercontent.com/ZemerTeam/zemer-cipher/master/library/src/main/assets/player_configs.json"
