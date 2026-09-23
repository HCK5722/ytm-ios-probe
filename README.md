# YTM iOS Phase 0 Probe

Public GPL-3.0 probe for the iOS route described in `FORK-执行手册.md` section 12.8.

The workflow records assertions for:

1. Kotlin/Native dependency resolution and iOS framework linking.
2. Ktor Darwin HTTP on the iOS simulator.
3. Anonymous YT Music playlist browse and search.
4. Audio stream extraction with `innertubex` 0.7.0.
5. AVPlayer readiness and playback-time progress.
6. Optional cookie login validation. Credentials are never committed. The login step reports `SKIP_NO_CREDENTIAL` unless the workflow receives an ephemeral `YT_COOKIE` environment value.

Target playlist: `PLd9orNjDFThOxxBaWd36m-6a87SO34Y62`.
