# YTM iOS Phase 0 Probe

Public GPL-3.0 probe for the iOS route described in `FORK-执行手册.md` section 12.8.

## Phase 0.5 status

The repository now contains the `innertube-kmp` module (`YTMKit.framework`) with `iosArm64`,
`iosSimulatorArm64`, and `desktop` targets. The desktop target compiles locally on Windows;
the iOS framework targets are built by the public macOS GitHub Actions workflow
`Phase 0.5 KMP adapter`. Real YouTube stream checks remain device/home-network checks; CI is
used for compilation, linking, and headers only.

The workflow records assertions for:

1. Kotlin/Native dependency resolution and iOS framework linking.
2. Ktor Darwin HTTP on the iOS simulator.
3. Anonymous YT Music playlist browse and search.
4. Audio stream extraction with `innertubex` 0.7.0.
5. AVPlayer readiness and playback-time progress.
6. Optional cookie login validation. Credentials are never committed. The login step reports `SKIP_NO_CREDENTIAL` unless the workflow receives an ephemeral `YT_COOKIE` environment value.

Target playlist: `PLd9orNjDFThOxxBaWd36m-6a87SO34Y62`.

## 阶段 1A 最小垂直切片

当前 device IPA 已把 `YTMKit.framework` 接入现有真机探针：Swift 通过 `playlist()` 读取公开歌单条目，界面显示条目，点击条目后复用已验证的 SABR + loopback + AVPlayer 链路播放。它仍然不是正式 UI，也不包含登录。

最新构建：Run `35988402733` 的 artifact `ytm-device-play-probe-14`。请在 iPhone Wi-Fi 和蜂窝网络各测试一次，关闭 VPN/代理；打开后点“加载歌单并播放第一首”或点列表中的条目，把 `PROBE_PLAY`、client/profile、AVPlayer status/currentTime 截图反馈。

## Windows 家宽对照实验

这是步骤 3 的取流实验，必须在用户自己的 Windows 家宽上运行。请按下面三步操作：

1. 如果脚本提示缺依赖，安装：
   `winget install EclipseAdoptium.Temurin.21.JDK`
   和 `winget install --id OpenJS.NodeJS.22 --exact`
2. 关闭 VPN、代理软件和系统代理；本实验要证明取流请求来自住宅/运营商 IP。
3. 双击仓库根目录的 `run-home-probe.bat`。结束后把 `probe-result.txt` 的全部内容贴回对话。

脚本会在运行期间临时启动只监听 `127.0.0.1:4416` 的 PoToken 服务，依次执行 `NONE` 与 `{EXTERNAL}` 两组，结束时停止进程并清理临时目录。默认不读取 cookie；只有用户明确设置 `YT_COOKIE` 并使用 `-UseCookieEnv` 时才会读取，cookie 不会写入日志或文件。
