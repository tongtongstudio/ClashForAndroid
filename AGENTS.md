# AGENTS.md

本文件记录构建相关的关键约束，供后续维护参考。

## 内核与 submodule

| 变体 | 路径 | 来源 |
|---|---|---|
| foss | `core/src/foss/golang/clash` | `Dreamacro_clash` 仓库 `main` 分支（Clash 1.7.1） |
| premium | `core/src/premium/golang/clash` | `Dreamacro_clash` 仓库 `premium` 分支（Clash.Meta `6e31f1d`，模块路径仍为 `github.com/Dreamacro/clash`） |

两个 submodule 指向同一仓库 `https://github.com/tongtongstudio/Dreamacro_clash`，仅分支不同。克隆后需执行：

```bash
git submodule update --init --recursive
```

## premium 为什么必须用 Go 1.20

premium 内核（Clash.Meta 2023-05）锁定了：

```
github.com/metacubex/quic-go v0.33.3-0.20230510010206-687b537b6a58
```

该版本 quic-go 内部 fork 了 Go 的 `crypto/tls`（`qtls`），并有编译期版本护栏
（`internal/qtls/go121.go`）：

```go
//go:build go1.21

var _ int = "The version of quic-go you're using can't be built on Go 1.21 yet. ..."
```

用 Go 1.21+ 编译 premium 会直接报错。护栏背后是真实不兼容：该 quic-go 通过
`//go:linkname` 依赖 Go ≤ 1.20 的 `crypto/tls` 内部符号，Go 1.21 重写了这部分实现。

因此**不要尝试用系统当前的 Go 1.26 构建 premium**。升级 quic-go 需要同步修改
Meta 的 QUIC transport 代码；升级到新版 mihomo 则需要改模块路径并重做 JNI 适配，
成本都很高。

### 处理方式：两个变体使用不同 Go 工具链

| 变体 | Go 版本 | 额外参数 |
|---|---|---|
| foss | 系统 Go（1.26） | `-ldflags=-checklinkname=0`（旧版 x/net 的 linkname 检查） |
| premium | Go 1.20.14 | 无需 checklinkname |

- Go 1.20 工具链在本机位置（不纳入仓库）：
  `D:\TongTongStudio\deprecated\_tools\go1.20.14`
- 构建命令：

```bash
# premium（必须带 -Pgo120Home，否则 core/build.gradle.kts 会主动报错）
gradle :app:assemblePremiumDebug -Pgo120Home=D:/TongTongStudio/deprecated/_tools/go1.20.14

# foss（使用系统 Go）
gradle :app:assembleFossDebug
```

- [core/build.gradle.kts](core/build.gradle.kts) 中 `afterEvaluate` 会按任务名区分：
  premium 任务被强制指定 `go.exe`、`GOROOT`、`PATH` 并清空 `GOFLAGS`；foss 任务注入
  `-checklinkname=0`。
- 换机器/CI 时必须重新准备 Go 1.20，并通过 `-Pgo120Home` 指定，否则 premium 必然失败。

## premium 内核适配要点

Clash.Meta 与原 Kr328 premium 内核 API 不一致，当前适配如下：

- **Script 模式不支持**：Meta 只有 direct/global/rule。UI 已隐藏 Script 菜单与覆盖设置项
  （`ProxyMenu.kt`、`OverrideSettingsDesign.kt`）。
- **sniff 开关映射**：UI 的 `experimental.sniff-tls-sni` 在
  `native/config/override_extras_premium.go` 中映射为 Meta 的
  `sniffer.enable` + `sniffing: [tls]`。
- **内核 TUN 不启用**：App 使用 VpnService + tun2socket，`native/config/process_premium.go`
  的 `patchTun` 为 no-op。
- **Providers**：`native/tunnel/providers_premium.go` 使用 `tunnel.Providers()` +
  `tunnel.RuleProviders()`，`UpdatableProvider` 为非泛型接口。
- **元数据**：Meta 的 `C.Metadata` 没有 `AddrType` 字段，连接类型使用 `C.HTTPS`；
  见 `native/tunnel/init_premium.go`、`native/tun/metadata_premium.go`。
- **构建标签**：premium 使用 `premium,without_gvisor,without_system`；Meta 的 gVisor
  是 `with_gvisor` 可选开关，默认不启用。

## 依赖来源

`maven.kr328.app` 已下线，以下依赖改为本地发布：

- `com.github.kr328.kaidl:{kaidl,kaidl-runtime}:1.15`，源码在
  `D:\TongTongStudio\deprecated\kaidl`
- `com.github.kr328.golang:gradle-plugin:1.0.4`，源码在
  `D:\TongTongStudio\deprecated\golang-android-plugin`（需 checkout 1.0.4 对应提交）

两者均通过 `publishToMavenLocal` 安装到本机 `~/.m2`，项目 repositories 已加
`mavenLocal()`。换机器需重新发布。

## 其他注意事项

- `.idea/` 已在 `.gitignore` 中整体忽略，不再跟踪。
- premium 首次 checkout submodule 时可能因换行符转换触发一次全量 Go 重建（约 20 分钟）。
- Debug 版 `libclash.so` 较大（premium 单 ABI 约 17–19 MB，universal 约 54 MB），
  release 版加 `-s -w` 会明显减小。
- 以上结论基于编译/打包验证，未在真机做流量验证。
