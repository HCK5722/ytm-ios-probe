# YTMKit KMP adapter

This module is the first Phase 0.5 boundary in the public GPL-3.0 probe repository.

It intentionally exposes only Swift-friendly DTOs (`ItemDTO`, `SectionDTO`, `PlaylistDTO`,
`StreamInfoDTO`) and keeps `innertubex` types internal to the Kotlin implementation. It has
`iosArm64`, `iosSimulatorArm64`, and `desktop` targets. iOS uses Ktor Darwin; desktop uses Ktor
OkHttp. The existing probe remains the evidence source for real-device stream and AVPlayer tests.

The full Metrolist `:innertube` source migration is being done in slices because its transport
facade still contains JVM-only OkHttp/File/InputStream/Proxy code. See `FORK-执行手册.md` for the
measured audit and the next migration boundary.
