package io.github.hck5722.ytmprobe

public class ProbeResult(
    public val darwinHttpOk: Boolean,
    public val darwinStatus: Int,
    public val browseOk: Boolean,
    public val browseStatus: Int,
    public val browseBytes: Int,
    public val searchOk: Boolean,
    public val searchStatus: Int,
    public val searchBytes: Int,
    public val streamOk: Boolean,
    public val audioUrl: String?,
    public val audioHeaders: Map<String, String>,
    public val audioMimeType: String?,
    public val audioItag: Int,
    public val audioClient: String?,
    public val audioProfile: String?,
    public val isSabr: Boolean,
    public val loginState: String,
    public val loginStatus: Int,
    public val loginBytes: Int,
    public val diagnostic: String,
)
