# Phase 0.5 audit

Measured against `D:\Project\yt\metrolist\innertube` on 2026-09-24:

- 82 Kotlin files under `src/main/kotlin` and 4 test files.
- 0 Android SDK imports.
- Timber occurs in `YouTube.kt`, `ArtistItemsPage.kt`, `HomePage.kt`, `LibraryPage.kt`, and `PlaylistPage.kt` (78 matches), so the old “5 Timber calls” statement is not an accurate call count.
- JVM/transport coupling is concentrated in `InnerTube.kt`, `YouTube.kt`, and `utils/Utils.kt`: OkHttp engine/configuration, `File`, `InputStream`, `Proxy`, `Dispatchers.IO`, JVM byte-channel adapter, `MessageDigest`, `@JvmName`, and JVM string formatting.

The new `innertube-kmp` module is the stable export boundary while those platform seams are migrated. It does not export `innertubex` types and it has a real desktop compilation path plus Darwin/OkHttp platform client factories.
