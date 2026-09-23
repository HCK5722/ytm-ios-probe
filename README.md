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

## Windows 家宽对照实验

这是步骤 3 的取流实验，必须在用户自己的 Windows 家宽上运行。请按下面三步操作：

1. 如果脚本提示缺依赖，安装：
   `winget install EclipseAdoptium.Temurin.21.JDK`
   和 `winget install OpenJS.NodeJS.LTS`
2. 关闭 VPN、代理软件和系统代理；本实验要证明取流请求来自住宅/运营商 IP。
3. 双击仓库根目录的 `run-home-probe.bat`。结束后把 `probe-result.txt` 的全部内容贴回对话。

脚本会在运行期间临时启动只监听 `127.0.0.1:4416` 的 PoToken 服务，依次执行 `NONE` 与 `{EXTERNAL}` 两组，结束时停止进程并清理临时目录。默认不读取 cookie；只有用户明确设置 `YT_COOKIE` 并使用 `-UseCookieEnv` 时才会读取，cookie 不会写入日志或文件。
