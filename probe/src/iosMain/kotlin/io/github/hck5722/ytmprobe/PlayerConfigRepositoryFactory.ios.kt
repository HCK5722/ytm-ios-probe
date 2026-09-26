package io.github.hck5722.ytmprobe

import com.metrolist.innertubex.cipher.PlayerConfigRepository
import platform.Foundation.NSUserDefaults

internal actual fun createPlayerConfigRepository(): PlayerConfigRepository =
    object : PlayerConfigRepository {
        private val defaults = NSUserDefaults.standardUserDefaults

        override val enabled: Boolean = true
        override val sourceUrl: String = PLAYER_CONFIG_URL
        override val defaultSourceUrl: String = PLAYER_CONFIG_URL
        override var cachedJson: String
            get() = defaults.stringForKey("ytm_probe_player_config_json") ?: ""
            set(value) = defaults.setObject(value, forKey = "ytm_probe_player_config_json")
        override var cachedAtMs: Long
            get() = defaults.doubleForKey("ytm_probe_player_config_cached_at_ms").toLong()
            set(value) = defaults.setDouble(value.toDouble(), forKey = "ytm_probe_player_config_cached_at_ms")
        override var cachedSourceUrl: String
            get() = defaults.stringForKey("ytm_probe_player_config_source_url") ?: ""
            set(value) = defaults.setObject(value, forKey = "ytm_probe_player_config_source_url")
        override var cachedEtag: String
            get() = defaults.stringForKey("ytm_probe_player_config_etag") ?: ""
            set(value) = defaults.setObject(value, forKey = "ytm_probe_player_config_etag")
    }

private const val PLAYER_CONFIG_URL =
    "https://raw.githubusercontent.com/ZemerTeam/zemer-cipher/master/library/src/main/assets/player_configs.json"
