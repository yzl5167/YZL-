# YZL Launcher iOS

> **只想编译、不想折腾本机环境？看这一篇就够：[`GitHub编译.md`](GitHub编译.md)** —— 这台 Windows 上没有 Xcode，
> 走"临时公开仓库 → macOS Runner 免费编译 → 取回 IPA/TIPA → 仓库转回私有/删除"，已实跑验证（run 42026461299 success）。

仿照 PojavLauncher / Amethyst 思路的 Minecraft: Java Edition iOS 启动器（侧载版）。沿用 YZL 桌面端的浅色蓝主题与卡片样式。

> 与 FCL 启动器的对应关系、平台差异、以及「免费 Apple ID 能不能搞」见 [`docs/FCL-PARITY.md`](docs/FCL-PARITY.md)。**一个二进制覆盖全部 iOS 15+，凡是该系统版本支持免电脑就自动走免电脑路线**，完整分流矩阵见 [`docs/DEPLOYMENT-MATRIX.md`](docs/DEPLOYMENT-MATRIX.md)。
>
> **两种安装形态，按系统选一个**：iOS 15–16.6.1 / 17.0 用 `YZL-engine.tipa`（TrollStore 永久签名）；**iOS 17.4+ / 18.x 不走巨魔用 `YZL-engine-sideload-unsigned.ipa`**（干净未签名，SideStore / 轻松签 重签），完整步骤见 [`docs/IOS18-SIDELOAD.md`](docs/IOS18-SIDELOAD.md)。
>
> ⚠️ **架构是单包 fork-overlay**：YZL 界面以 `YZLUI.framework` 注入 Amethyst 主 App，装上面任意一个引擎包即可，启动后就是 YZL 界面。`YZLLauncher-unsigned.ipa`（1.1 MB 纯外壳）只是 UI 预览 / 单测用，里面没有 `launchJVM` 符号，**单独装它进不了游戏，也不要把两个包都装上**。

当前处于 **M0/M1 完成 + M2 引擎件就位、待真机联调**。界面、Mojang 版本清单、微软登录、分片下载、整包安装、安装记录持久化、启动参数组装都已实现并通过云构建与单测。引擎包含图形 dylib、Java 桥 jar 与 `YZLGameEntry`；**JRE 8 / 17 完整可用，JRE 21 / 25 因上游 CDN 失效仍是空壳（1.21+ 暂不能玩，见 `IOS18-SIDELOAD.md` §5）**；YZL UI 注入件（`YZLUI.framework` 二进制）此前缺失，已修好并在 CI 中硬校验通过。

2026-11-07 新增：引擎 CI 同时产出 `.tipa` 与**干净未签名** `YZL-engine-sideload-unsigned.ipa`（剥离 ldid 伪签与 TrollStore 私有 entitlement），并用 `scripts/verify_engine_ipa.py` 对两个包做产物完整性硬校验（YZLUI 真 Mach-O、JRE 8/17 真实可用、关键 jar/dylib 齐备、侧载包无签名残留）。

**最大缺口仍是真机联调**：安装 → YZL 界面 → 装版本 → 启动进游戏，这条链路目前一次都没在 iPhone 上跑过。联调清单见 `IOS18-SIDELOAD.md` §8。

## 为什么只能侧载

- iOS 不允许 App Store 应用使用 JIT，而 Java 版 Minecraft 没有 JIT 基本不可用。
- 启动器需要下载并执行 Java 字节码，不符合 App Store 审核条款 2.5.2。
- 所以只能走 TrollStore / AltStore / SideStore + SideJITServer 的侧载路线，不上架 App Store。

### 能不能不用电脑签名？

| 方案 | 需要电脑？ | 掉签 | JIT | 适用系统 |
| --- | --- | --- | --- | --- |
| **TrollStore** | 装好后不需要 | 永久 | 自动开启 | iOS 14.0 beta 2 – 16.6.1、16.7 RC (20H18)、17.0 |
| AltStore / SideStore | 首次和续签需要 | 约 7 天 | 需要电脑附加 | iOS 14+ |
| 付费签名服务 | 安装不需要 | 证书可能被吊销 | 仍需电脑附加 JIT | 任意 |
| App Store / TestFlight | 不需要 | — | 不允许 | 不可行 |

结论：**想完全不用电脑签名，只能走 TrollStore**；iOS 17.0.1 及以上没有免费、稳定、免电脑的方案。TrollStore 本身在部分系统需要电脑安装一次（以 ios.cfw.guide 为准），装好后安装 IPA 不再需要电脑、Apple ID 或证书。

**通用策略**：一个二进制覆盖尽可能多的系统版本。部署目标已降到 **iOS 15.0**（`presentationDetents`、`scrollContentBackground` 两处 iOS 16 API 收进 `YZLCompat` 用 `#available` 兜底），这样 TrollStore 兼容区里的 15.x / 16.x / 17.0 机器和 17.0.1+ / 18 / 26 机器都能装。iOS 14.x 需要再替换 `AsyncImage`、`refreshable`、`URLSession` 异步接口，收益很小，暂不做。运行时由 `DeviceCapabilities` 判断本机属于哪条路线、JVM 能给多少内存，设置页直接显示；堆上限按 `os_proc_available_memory()` 自动收敛（`maxSafeHeapMB`，见 `docs/FCL-PARITY.md` §5.2），**不按机型出包、不按设备预设参数**。

## 当前进度

| 模块 | 状态 |
| --- | --- |
| XcodeGen 工程与资源目录 | 已建立，云构建通过 |
| YZL 风格 SwiftUI 外壳（固定横屏、左侧图标栏） | 已实现，云构建通过 |
| 安卓同款 FCL 式居中主页（头像 / 版本 / 启动） | 已实现，云构建通过 |
| 账号管理页（安卓同款卡片 + 微软登录） | 已实现，云构建通过 |
| 皮肤页（读取 Mojang 档案皮肤贴图） | 已实现，云构建通过 |
| 版本页主从分栏（左列表 + 右详情） | 已实现，云构建通过 |
| 微软登录（默认 v1.0 浏览器授权码流；自定义 Azure 走设备码） | 已实现，含单测；真机登录待联调 |
| Mojang 版本清单拉取 | 已实现，接口结构与真实响应核对 |
| 分片下载器 + 客户端 jar / 整包安装 | 已实现，含单测；真实文件哈希核对通过 |
| 安装清单（规则过滤/依赖库/资源去重）+ 多文件队列 | 已实现，清单数字用真实 Mojang 数据核对 |
| 安装记录 `installed.json` + 当前版本持久化 | 已实现，云构建通过 |
| 启动自检（账户/文件/令牌/JRE/JIT/内核）+ LaunchPlan 参数生成 | 已实现，云构建通过 |
| LaunchCommand（JVM argv 顺序、令牌脱敏、环境变量） | 已实现，含单测 |
| RuntimeLocator（JRE / natives 真实定位，空目录不算可用） | 已实现，含单测 |
| JITProbe（RWX 页探测，可注入便于测试） | 已实现，含单测 |
| AmethystEngine + EngineBridge 协议（M2 接缝） | 已实现，含单测；fork 环境由 YZLEngineHost 接管 |
| JRE 二进制 + Amethyst 内核 + SurfaceViewController | 已打进引擎 `.tipa`；YZL UI 注入件已修复，待真机进游戏验证 |
| 上游引擎接缝审计 | 已完成初步审计，见 `docs/POJAV-ENGINE-AUDIT.md` |
| 静态自检 `scripts/preflight.py`（括号 / JSON / plist / 禁用 API / shell / ps1 BOM） | 已实现并接入全部 CI 任务 |
| `scripts/fetch-ipa.ps1`（Windows 一键触发构建并取回 IPA） | 已实现，PowerShell 5.1 语法校验通过 |
| **云构建直出 TrollStore `.tipa`（主线）** | 已接入 `build-ipa.yml` / `release-ipa.yml`（ldid 伪签 + artifact + Release 附件），未实跑 |
| 现代版本参数解析（arguments / minecraftArguments + 占位符替换 + 平台/feature 规则过滤） | 已实现，含单测（ArgumentResolverTests），已编译（云构建通过） |
| 版本继承合并 VersionMerger（inheritsFrom 拍平，Forge/Fabric 启动前置） | 已实现，含单测（VersionMergerTests）；安装期拍平存盘已接入（`VersionInheritanceResolver` 取回父版本链并逐层落盘，启动不再依赖网络） |
| Fabric 加载器安装（官方 Meta：加载器列表 → profile → 继承链解析 → Maven 坐标库下载 → 拍平安装） | 已实现，含单测（LoaderInstallTests）；版本页显示已安装加载器版本（fabric-loader-* 合并进清单 + Fabric 徽章）；已编译（云构建通过） |
| Quilt 加载器安装（meta.quiltmc.org v3，与 Fabric 同链路） | 已实现，含单测（MirrorPolicyTests）；Quilt 条目无 stable 字段，按版本号 beta 兜底；已编译（云构建通过） |
| 下载源切换（Mojang 官方 / BMCLAPI 镜像） | 已实现，含单测（MirrorPolicyTests）；映射表与 Android 端 Mirrors.kt 一致，端点已实测（清单 278,772 字节、资源对象、fabric-meta 均 200）；清单/详情/Meta/库/资源对象全链路生效；已编译（云构建通过） |
| 离线皮肤本地导入（相册选图 → 尺寸校验 → Documents/YZLSkins 存 PNG） | 已实现，含单测（MirrorPolicyTests）；`yzl-local-skin://` 引用走本地文件，头像与皮肤页自动生效；微软账号补官网皮肤设置入口；已编译（云构建通过） |
| 通用自适应（堆上限按可用内存收敛、不按机型出包） | 已实现并补单测，已编译（云构建通过） |
| 全系统自动分流（6 档，能用免电脑就用免电脑） | 已实现：部署档位判定、JIT 按钮分流、诊断页三行提示、单测；已编译（云构建通过） |
| **M2-b fork-overlay 架构定案与桥接层** | 已实现：架构决策（`docs/M2B-ENGINE.md`，证据链：原生桥焊在主二进制 / Java 侧自持启动链 / 无官方预编译）；`EnginePayloadLocator` 逐件诊断（含单测）、`EngineLaunchContract` 启动契约（含单测）、`YZLEngineHost` 运行时桥（dlsym + 契约 + SurfaceVC 运行时呈现）、`LauncherEngineFactory` fork↔外壳自动切换；已编译（云构建通过） |
| **M2-b fork 补丁与引擎 CI** | 已实现：三处补丁（PojavLauncher YZL 分支 / 二进制名解耦 / UI 注入点）+ 幂等应用脚本 + `engine/fork-patches/yzl/YZLGameEntry.java`；实验流水线 `build-engine-ipa.yml`（workflow_dispatch，托管 runner 实测审计 §10 待验证项）；未实跑 |
| Windows 自签（备用，当前不采用） | 脚本与 entitlement 模板已实现，未用真实证书实跑 |

> 表格状态已于 2026-11-07 统一刷新：此前标注为待编译的条目，现在都已由 GitHub Actions 的 macOS runner 编译并通过单测（`** TEST SUCCEEDED **`，139 个 / 1 跳过 / 0 失败）。
>
> 本工程在 Windows 上创建，本机没有 Xcode；编译与测试一律走云端 macOS runner。`python3 scripts/preflight.py` 是提交前的静态自检（括号 / JSON / plist / 禁用 API / shell / ps1 BOM），三个 CI 任务都会先跑它。

iOS 外壳按安卓已安装版同步：左侧 84pt 图标栏、居中 FCL 式主页、卡片式账号管理页和设备代码登录弹窗。安卓工程本身未做修改；iOS 的默认微软公共客户端 ID 与安卓一致（`00000000402b5328`），自定义 Azure 客户端仍可在设置里覆盖。

### 下载与启动按钮现在做什么

- **开始安装**：主页的「下载游戏」或版本页的「开始安装」都会拉取版本 JSON，保存到 `Documents/YZLVersions/<版本>/<版本>.json`；随后下载客户端 jar、iOS 适用的依赖库、资源索引和去重后的资源对象。全部文件通过 SHA-1 后才写入 `installed.json` 并自动设为当前版本；中断/失败不会留下“已安装”标记。
- **继续安装**：已完成且 SHA-1 一致的文件直接跳过，未完成的分片从断点续传，不会把 732 MB 从头再下一遍。
- **启动游戏**：先做启动自检——账户与令牌、安装记录、版本 JSON、客户端 jar、依赖库、资源索引、JRE、JIT、Amethyst 内核、内存——再生成 classpath、主类、JVM 参数和游戏参数（`LaunchPlan`）。全部通过后才交给引擎。
- 自检面板现在会额外显示一条「启动命令」检查项：`LaunchCommand` 已把 JVM 参数、`-cp`、主类与游戏参数按顺序组装好，令牌只留在内存且展示时脱敏。
- 引擎包（fork-overlay）已把 JRE 8/17 与 `launchJVM` 打进同一个 App，`LauncherEngineFactory` 在 fork 进程内 `dlsym` 命中后自动切到 `YZLEngineHost` 真启动；纯外壳构建仍走 `AmethystEngine()` 接缝实现并如实报「内核未接入」。启动面板会逐项显示 JRE / JIT / 内核状态，不再含糊地弹一句“还不能启动”。

### 本机已做过的检查（2026-11-04）

- 真实请求 `piston-meta.mojang.com` 的 `version_manifest_v2.json`：HTTP 200，278,772 字节，922 个版本；代码依赖的 5 个字段无缺失。
- 真实探测 1.20.1 客户端 jar：`HEAD` 返回 `Accept-Ranges: bytes`、`Content-Length: 23028853`；`Range: bytes=0-1023` 返回 `206` + `Content-Range: bytes 0-1023/23028853`。下载器的探测、分片和单连接回退逻辑按这个行为编写。
- 用真实 Mojang 版本详情生成测试样本 `Tests/Fixtures/VersionDetail_1.20.1.json`（Java 17）和 `VersionDetail_1.12.2.json`（Java 8），并核对安装清单：1.20.1 共 88 条 libraries，按 Mojang 规则在 iOS 下保留 **43** 条（56,765,207 字节），加客户端 jar 23,028,853 与资源索引 413,067，合计 **80,207,127 字节 / 45 个文件**；1.12.2 为 **33** 条库（40,470,614 字节），合计 **50,793,863 字节 / 35 个文件**。
- 真实拉取 1.20.1 资源索引：3,598 条记录、去重后 **3,575** 个对象、**651,738,281 字节**。即整包"安装原版"约 **3,620 个文件 / 732 MB**，队列必须按文件+字节两级真实统计。
- 用真实索引前 40 条生成 `AssetIndex_5.sample.json` 作为对象规划测试样本（全部小于 4 MiB，验证走单连接与 `objects/<前2位>/<hash>` 路径）。
- 6 个 Asset Catalog `Contents.json` 全部可解析；AppIcon 1024×1024 无透明通道，方块图标 192×192。
- 49 个 Swift 文件括号配平、9 个 JSON 可解析；打包脚本通过 `bash -n`。新增 `LaunchPlanTests` 覆盖 classpath 数量、Java 17/8 参数、内存夹取、安装记录往返。CI 增加了模拟器单元测试步骤，但**本机和 CI 都还没实际跑过一次编译/测试**。
- 2026-11-04 对微软登录链路做过真实端点探测（不登录，只看协议形状）：
  - `login.live.com/oauth20_connect.srf` 返回 `user_code / device_code / verification_uri / interval / expires_in`，**没有 `message`**；因此 `DeviceCode.message` 已改为可选，否则真机登录会在解码阶段直接失败。
  - `grant_type=urn:ietf:params:oauth:grant-type:device_code` 被 Live Connect 接受；`grant_type=device` 返回 `unsupported_grant_type`。现有写法正确。
  - 默认公共客户端 ID 打到 Azure v2.0 `devicecode` 端点会返回 `AADSTS700016`，证明它必须走 Live Connect 分支，这个分支不能删。
- 头像不再请求第三方 `mc-heads.net`（那会把玩家 UUID 发给外部服务），改为本地裁 Mojang 贴图的 (8,8,8,8) 头部像素并最近邻放大；新增 `SkinTextureTests` 覆盖 64×64、64×32、128×128 与过小贴图四种情况。
- `RootView` 的 overlay / tab 切换补上 `.animation(value:)`；之前只写了 `.transition`，状态变化没有动画包裹，切页不会平滑。
- 真实探测资源对象端点：`resources.download.minecraft.com` **无法解析**，正确主机是 `resources.download.minecraft.net`；已修正 `InstallPlanner.assetsBaseURL` 并用真实对象 `b62ca8…3356` 验证 `HEAD 200 / Accept-Ranges: bytes / Content-Length: 9101`。这个错误会让整包安装卡在资源对象阶段，属于本次修复的关键项。
- 横版设计预览：`docs/preview/landscape.html` 可在浏览器里按 `?screen=home|home-out|home-install|versions|install|skin|launch|account|account-in|login|settings|about` 切换，2400×1080 截图在 `docs/preview/shots/`。

### 2026-11-05：首次云构建与 M2 接缝

- 09:20 GitHub Actions（macos-15-arm64）首次真编译：`xcodegen generate` 成功，`xcodebuild test` exit 65。3 个错误全在 `AvatarView.swift`：Swift 的 `CGContext` 没有 `setInterpolationQuality(_:)`；`AsyncImage` 的 `phase.image` 是 `SwiftUI.Image`，不能传给需要 `UIImage` 的 `SkinTexture.head(from:)`。另有 `DownloadQueue.swift` 在 `nonisolated` 方法里跨 actor 读 `self.downloader` 的 Swift 6 并发警告。
- 修复：`interpolationQuality = .none` 属性赋值；头像改为 `.task(id:)` + `URLSession` 异步取 `UIImage`（仍只走 Mojang 官方地址）；`downloader` 改为在 MainActor 上下文取出后传参给 `runOne`。
- 新增静态自检 `scripts/preflight.py`：注释/字符串感知的括号配平、JSON 与 plist 解析、禁用 API 黑名单、shell 语法、含中文的 `.ps1` 必须有 UTF-8 BOM（PowerShell 5.1 按 GBK 读会乱码）。本机 56 个 Swift 文件全部通过，已挂到 `build-ipa.yml` 两个 job 和 `release-ipa.yml`；顺手给 `check-network.ps1` 补了 BOM。
- 新增 `scripts/fetch-ipa.ps1`：Windows 上一条命令触发云构建、轮询、下载 artifact 并取出 `dist\YZLLauncher-unsigned.ipa`，失败时自动抓回云端日志打印编译错误。首次上传源码仍用 `api-publish.ps1`。
- 补上「自签 IPA」这条链路（**后降级为备用**）：新增 `scripts/sign-ipa.ps1`（zsign + p12/mobileprovision）与 `packaging/entitlements.free.plist`；文档给出 Sideloadly Export 的逐步操作。
- 通用自适应补齐：`LaunchPlanBuilder` 的堆上限从硬编码 4096 改为可注入 `maxHeapMB`，`AppState` 传入 `DeviceCapabilities.maxSafeHeapMB`（按 `os_proc_available_memory()` 取 60%、夹 1024–4096 MB）；启动自检显示「设置 / 上限 / 实际」三项。同一个 `.tipa` 在 3GB 老机和大内存 iPad 上自动收敛，不按机型出包，新增 5 个单测。
- 全系统自动分流：新增 `Core/System/DeploymentProfile.swift`（6 档）与 `docs/DEPLOYMENT-MATRIX.md`，`AppState.enableJIT()` 按档位选「最省电脑」的方式（TrollStore URL Scheme → StikDebug 手机端 → 电脑附加），设置页诊断新增「部署档位 / 电脑依赖 / 建议安装包」三行；`project.yml` 声明 `LSApplicationQueriesSchemes: apple-magnifier`。原则是**凡是该系统版本支持免电脑就自动用免电脑方法**。新增 2 个单测。
- M2 接缝落地（纯 Swift，可单测）：`LaunchCommand` 固定 argv 顺序并脱敏令牌；`RuntimeLocator` 用真实标记文件判定 JRE/natives；`JITProbe` 用 RWX 页探测且可注入；`AmethystEngine` 把「运行时 → JIT → 命令 → 桥」串成一条链，`EngineBridge` 未注入时明确抛 `.notIntegrated`。启动面板新增「启动命令」检查项，能看到已生成的参数数量（不含令牌）。
- 仍缺：JRE 二进制、Amethyst 内核、`JLI_Launch` / `SurfaceViewController` 桥接，以及修复后代码的一次真实编译与 IPA。

### 2026-11-05 晚：Fabric 加载器安装链路（对照 Android / Windows 端补齐）

Android 端（DownloadScreen 选 Fabric）与 Windows 端（CmlLib 加载器下拉）都支持加载器版本，iOS 端此前完全缺失，且存在两处硬伤：

1. `VersionDetail.downloads` 是非可选字段——Fabric profile（`inheritsFrom` 指向原版、没有 `downloads` 键）**在解码阶段就会失败**；
2. `VersionMergerTests` 一直在用可选 `downloads` 构造 `VersionDetail`，测试目标存在从未被编译到的潜在编译错误（CI 里应用目标先挂，测试目标从未参与编译）。

本次改动：

- **模型**：`downloads` 改为可选，`clientArtifact` 随之可选；`Library` 增加顶层 `sha1` / `size`（Fabric Meta 格式）与 `time` / `releaseTime`（安装记录用）。
- **Maven 坐标库**：新增 `Core/Minecraft/MavenCoordinates.swift`——加载器 profile 的库只有 `name`（`group:artifact:version[:classifier]`）+ `url`（仓库根），按 Maven 布局推导 jar 路径与下载地址；`InstallPlanner` 与 `LaunchPlanBuilder.classpath` 共用同一解析，保证「装了什么就进 classpath 什么」。
- **继承链解析**：新增 `Core/Minecraft/VersionInheritanceResolver.swift`——递归解析 `inheritsFrom`（本地已装优先，否则按 Mojang 清单取回），逐层落盘祖先版本 JSON，再交给 `VersionMerger` 拍平存为本版本 JSON；带环检测与深度上限。README 里挂了许久的「安装期拍平存盘待接入」至此落地，安装与启动都不再依赖网络。
- **Fabric 服务与 UI**：新增 `Core/Minecraft/FabricLoaderService.swift`（`meta.fabricmc.net` 加载器列表 + profile）与 `Features/Versions/FabricInstallCardView.swift`（版本详情页内选加载器版本 → 拉取 profile → 复用原版安装卡的状态机）。`InstallCardView` 参数化标题/说明，`VersionDetailViewModel` 支持预注入详情与本地优先加载。
- **版本页**：已安装但不在 Mojang 清单里的版本（如 `fabric-loader-0.16.14-1.20.1`）合并进列表并可选中启动，带 Fabric/Forge/Quilt/NeoForge 徽章（`MinecraftVersion.loaderLabel`）。
- **测试**：新增 `Tests/LoaderInstallTests.swift`（profile 解码、Maven 推导、拍平安装清单字节核对 82,087,576、继承链顺序/缺父/环/深度、JSON 往返、classpath 一致性）与真实裁剪样本 `Tests/Fixtures/FabricProfile_1.20.1.sample.json`；`preflight.py` 全绿（69 Swift / 10 JSON）。

Forge / NeoForge / Quilt 走安装器或独立 meta，需要后续单独接（Android 端同样未支持 Forge）。

### 2026-11-06：BMCLAPI 镜像 + Quilt 加载器 + 离线皮肤导入

对照 Android / Windows 端补齐的又一批能力：

- **下载源切换**：新增 `Core/Download/MirrorPolicy.swift`（`DownloadSource` 官方 / BMCLAPI）。映射表与 Android 端 `net/Mirrors.kt` 完全一致：piston-meta / piston-data / launchermeta / launcher → `bmclapi2.bangbang93.com`，`resources.download.minecraft.net` → `/assets/`，`libraries.minecraft.net` 与各 maven → `/maven/`，`meta.fabricmc.net` → `/fabric-meta/`，`meta.quiltmc.org` → `/quilt-meta/`。生效范围：版本清单、版本详情（含加载器 profile）、加载器列表、安装 spec（客户端 jar / 依赖库 / 资源对象）——全部单点改写。设置页新增「下载源」分段选择。镜像端点已实测：清单 200（278,772 字节，与官方一致）、真实资源对象 200（9,101 字节，与 README 2026-11-04 的记录一致）、fabric-meta 列表 200。
- **Quilt 加载器**：`FabricLoaderService` 泛化为 `LoaderService` + `LoaderKind`（fabric v2 / quilt v3）。Quilt 列表条目没有 `stable` 字段，`LoaderEntry.isStable` 用「版本号含 beta 即非稳定」兜底；profile 端点同构，直接复用继承链解析与安装链路。安装卡升级为「Fabric / Quilt」双分段。
- **离线皮肤本地导入**：新增 `Core/Auth/LocalSkinStore.swift`——PHPicker 相册选图 → 尺寸校验（64×32 / 64×64 / 128×64 / 128×128，与 Android 端规则一致）→ PNG 存 `Documents/YZLSkins/<账号 id>.png` → `skinURL` 写 `yzl-local-skin://<id>.png?v=<时间戳>`（时间戳保证重复导入时 UI 重新取图）。`AvatarView` / `SkinBodyView` 识别该 scheme 走本地文件；皮肤页离线账号显示「导入 / 恢复默认」卡，微软账号补 minecraft.net 官方皮肤设置入口（对照 Android 端的三源皮肤策略）。
- **测试**：新增 `Tests/MirrorPolicyTests.swift`（官方原样、13 条镜像映射、未知 host 不动、非法值回退官方、Fabric/Quilt 条目解码、Meta URL、皮肤尺寸校验与存取往返）。

### 2026-11-06（二）：M2-b 定案——fork-overlay 架构与桥接层落地

「把引擎塞进 YZL 工程」的路线经源码级验证**不可行**（三条硬证据见
`docs/M2B-ENGINE.md` §2：原生桥符号焊在 Amethyst 主二进制里、Java 侧
自持进程内启动链、上游无预编译产物）。定案走 **fork + UI framework 注入**：

- **架构文档**：`docs/M2B-ENGINE.md`——分层契约图、启动链路、执行手册（三阶段）、风险表。
- **YZL 侧桥（全部可编译、带单测）**：
  - `EnginePayloadLocator`：扫描 bundle 里 java_runtimes / Frameworks / libs / cacio 四类引擎件，启动面板从一句"未接入"变成逐件诊断；
  - `EngineLaunchContract`：`YZL_LAUNCH_PLAN.json` 契约（mainClass / classpath / gameArgs / 账号），令牌只落沙箱、交接即删；
  - `YZLEngineHost`：dlsym("launchJVM") + 契约写入 + `SurfaceViewController` 运行时呈现——**编译期零依赖 Amethyst 源码**，纯外壳构建全绿；
  - `LauncherEngineFactory`：fork 环境（符号命中）自动切真引擎桥，外壳构建维持 M2 接缝。
- **fork 侧补丁（本仓库内备好，幂等脚本一键应用）**：
  - `PojavLauncher.launchMinecraft` 顶部加 YZL 分支 → `YZLGameEntry.launch(plan)`（PojavClassLoader + 反射 main，进程内进游戏）；
  - `GLFW.java` / `UIKit.java` 的 `System.load(BUNDLE_PATH + 固定二进制名)` 改为 env 可覆盖；
  - 根视图装配处 dlopen `YZLUI.framework`，命中即 YZL UI 接管，未命中回退原生 UI。
- **引擎基线 CI**：`.github/workflows/build-engine-ipa.yml`（workflow_dispatch）+ `engine/build-engine.sh`——在 GitHub 托管 macOS runner 上实测审计 §10 悬而未决的「cmake + JDK8 + ldid 能否构建 make package」，失败日志即产出。
- preflight 扩展 `engine/**/*.sh` 语法检查（本机无 bash 由 CI 执行）。

**M2-b 当前状态**（云构建已验证，本机无 Xcode 的物理边界仍在）：

1. ✅ 引擎基线流水线跑通（macOS 托管 runner + cmake / JDK8 / ldid）；
2. ✅ `make payload` → 构建并注入可执行的 `YZLUI.framework` → 最终 `.tipa` 硬校验通过；
3. ⏳ 真机联调：TrollStore 安装 → YZL 界面 → 安装版本 → 启动进游戏
   （JIT/内存按既有 DEPLOYMENT-MATRIX 分流）。
   （YZLUI framework target 已于 2026-11-06 修复：`project.yml` 的 `YZLUI`
   target 链接 `WebKit.framework`；2026-11-06 再次确认 CI 不再容忍空壳 framework。）

### 2026-11-06（三）：DarkRPG 整合包「卡在正在加载地形」

现象：同一个整合包（1.20.1 / Fabric / 454 个模组）在 Windows 上用 PCL 能正常进世界，
在 YZL 上一直停在「正在加载地形」（`ReceivingLevelScreen`——客户端已进世界，等渲染线程
把出生点区块建出来）。对照 Amethyst 源码逐层排，落出三处 iOS 独有的差异：

1. **堆大小是假的**。`-Xmx` 不是我们命令行传的，是 `JavaLauncher.m:211` 读
   `java.auto_ram` / `java.allocated_memory` 算的；没写过偏好就按物理内存 25%
   （4 GB 设备 = 1 GB）。PCL 那边给 8 GB，手机给 1–2 GB，454 个模组光世界加载就会
   GC 到不动。→ 新增 `AmethystPreferences`：启动前把用户选的堆写进
   `$AME_HOME/launcher_preferences_v2.plist`（下次启动由 Amethyst 自己算对），
   同时在 `jvm_processed` 里补一条 `-Xmx`（`JavaLauncher.m:353` 会把它拼在
   Amethyst 自己的参数之后，最后一条生效）——Amethyst 在 `main.m:301` 就已经把
   偏好读进内存了，只写盘本次启动不会生效，两条路径必须都走。
2. **Iris 光影**。整合包 `config/iris.properties` 里 `enableShaders=true`（Windswept
   Fantasy）。Iris 在收到地形那一刻编译整套 shader 管线，而 iOS 走 gl4es /
   MobileGlues / ANGLE 翻译层，缺 compute、SSBO、持久映射，编译线程会一直等下去。
   → `MobileCompat` 启动前把它改成 `false`，保留 `shaderPack` 名字，回桌面端能开回来。
3. **Sodium 的高级 staging buffer** 依赖 GL 4.4 持久映射，翻译层不可靠。
   → `use_advanced_staging_buffers=false`、`cpu_render_ahead_limit=2`。

另外把 `options.txt` 收敛到手机档位（视图距离 4 / 模拟距离 4 / 60 FPS / 关云层 /
关生物群系过渡 / 关实体阴影），全部改动前备份到实例目录 `.yzl-compat-backup/`。

- 设置页新增「iPhone 兼容」卡：**自动适配**（默认开）+ **极端兼容**
  （再把 `iris` / `sodium` / `indium` / `reeses_sodium_options` 移进 `mods-ios-off/`，
  换渲染器也能进）+「立即处理当前版本」/「恢复原样」。
- 启动自检新增「整合包」一行：模组数量、光影是否已关、当前渲染器与 Sodium 0.5
  是否匹配（`auto`/`gl4es` 与 Sodium 0.5 本来就不兼容，提前说，别让用户干等）。
- `YZLGameEntry` 加**卡死采样**：启动后 120 / 240 / 420 秒各 dump 一次全部 Java
  线程栈到 `<gameDir>/logs/yzl-stall-<版本>-<n>.log`。下次再卡，直接看线程栈就知道
  是渲染线程、区块构建还是集成服务端 worldgen 在等锁，不用再猜。

### 下载管线端到端实测（2026-11-06，真实 Mojang 服务器）

与 iOS 安装器同逻辑的 PowerShell 复刻测试全绿：清单 922 版本 → 1.20.1/1.12.2 详情 → 规则过滤 43/33 条 iOS 适用库（与 11-04 核对值一致）→ 客户端 jar Range 分片下载 23,028,853 字节 + SHA-1 `0c3ec587…` 精确匹配（20.1 MB/s）→ 资源索引 3,598 条 SHA-1 匹配 → 资源对象/依赖库抽样全部哈希吻合。下载、校验、清单语义三层全通。

## 目录结构

```
YZL-Launcher-iOS/
├── project.yml                     XcodeGen 工程定义
├── YZLLauncher/
│   ├── App/                        入口、左栏外壳、全局状态
│   ├── Theme/                      颜色、卡片、按钮、皮肤头像
│   ├── Features/
│   │   ├── Home/                   主页
│   │   ├── Versions/               版本列表与详情
│   │   ├── Account/                微软账户（设备代码登录）
│   │   ├── Skin/                   皮肤预览
│   │   ├── Launch/                 启动自检面板
│   │   └── Settings/               设置、诊断、关于
│   ├── Core/
│   │   ├── Minecraft/              版本模型与 Mojang API
│   │   ├── Download/               分片下载器、续传状态、SHA-1
│   │   ├── Install/                安装布局、计划、installed.json 记录
│   │   ├── Launch/                 启动自检与 LaunchPlan 参数生成
│   │   ├── Auth/                   设备代码流、Xbox/XSTS/Minecraft、Keychain
│   │   ├── Engine/                 启动内核协议与 JIT 状态
│   │   └── System/                 设备诊断信息
│   └── Resources/Assets.xcassets   AppIcon、品牌图标、方块图标
├── Tests/                          分片规划、Range 探测、版本 JSON、续传、设备代码模型、
│                                   LaunchCommand / RuntimeLocator / JIT / 引擎接缝 / 引擎契约
├── YZLUI/                          M2-b fork 注入外壳的入口（YZLUIRootController，
│                                   project.yml 的 YZLUI framework target 使用）
├── engine/                         M2-b：fork 补丁、幂等应用脚本、引擎基线构建脚本
├── docs/
│   ├── ARCHITECTURE.md
│   ├── BUILD-AND-SIDELOAD.md
│   ├── DEPLOYMENT-MATRIX.md            全系统覆盖矩阵与自动选免电脑路线的分流
│   ├── FCL-PARITY.md                   与 FCL 的对照、平台差异、免费 Apple ID 能力边界
│   ├── SIGNING.md                      自签与安装（备用路线）
│   ├── POJAV-ENGINE-AUDIT.md
│   └── preview/                        横版设计预览与截图
├── packaging/                          entitlements 与 OTA manifest 模板
├── scripts/
│   ├── preflight.py                    本地/CI 静态自检（python3 scripts/preflight.py）
│   ├── fetch-ipa.ps1                   Windows 一键触发云构建并取回 IPA
│   ├── sign-ipa.ps1                    Windows 自签（zsign + p12/mobileprovision）
│   ├── api-publish.ps1                 首次上传源码 + 触发构建（api.github.com only）
│   ├── package-unsigned-ipa.sh         未签名 IPA
│   ├── sign-ipa.sh                     trollstore(.tipa) / sideload(.ipa)
│   ├── make-ota-manifest.sh            itms-services 清单
│   └── build-tipa.sh                   macOS 一条命令出 TrollStore 包
└── .github/workflows/
    ├── build-ipa.yml
    └── release-ipa.yml
```

## 构建

### 本地（macOS）

```bash
brew install xcodegen
cd YZL-Launcher-iOS
xcodegen generate
open YZLLauncher.xcodeproj
```

在 Signing & Capabilities 里选择自己的 Team，再连接 iPhone 运行。模拟器只能看界面，不能跑 Java 版。

`Info.plist` 由 XcodeGen 生成，不提交到仓库。

### 云构建（GitHub Actions）

工作流位于 `YZL-Launcher-iOS/.github/workflows/build-ipa.yml`。GitHub 只识别仓库根目录的 `.github/workflows`：

- 如果这个目录单独作为一个仓库推送，工作流可直接使用（当前按这种布局编写）；
- 如果放进现有仓库，请把工作流移到仓库根目录 `.github/workflows/`，增加 `defaults.run.working-directory: YZL-Launcher-iOS`，并把产物路径改成 `YZL-Launcher-iOS/YZLLauncher-unsigned.ipa`。

云构建一次产出两个包：`YZLLauncher-unsigned.ipa`（底包）与 **`com.yzl.launcher.tipa`**（ldid 伪签、带 TrollStore entitlement 的**主线交付物**）。推 `v*` tag 时 `release-ipa.yml` 会把两者都挂到 GitHub Release：手机 Safari 下载 `.tipa` → 文件 App 长按 → 分享 → TrollStore → Install，永久签名、免 Apple ID、自动 JIT，最接近 FCL 的「下载即装」。JIT 与设备兼容细节见 `docs/BUILD-AND-SIDELOAD.md`。

#### 怎么拿到 IPA

IPA = Xcode 编译出的 `YZLLauncher.app` 放进 `Payload/` 再打成 zip 改名。**Windows 不能编译 iOS，所以必须借 macOS 或云端 Runner**：

| 环境 | 命令 | 产物 |
| --- | --- | --- |
| **Windows（主线，一次拿两个包）** | `$env:GITHUB_TOKEN="..."` 后运行 `powershell -ExecutionPolicy Bypass -File .\scripts\fetch-ipa.ps1` | `dist\YZLLauncher-unsigned.ipa` + **`dist\com.yzl.launcher.tipa`** |
| Windows（备用，当前不采用） | Sideloadly → Advanced → **Signing mode: Export**；或有证书时跑 `scripts\sign-ipa.ps1` | `dist\YZLLauncher-signed.ipa`（7 天） |
| macOS（一步到位） | `bash scripts/build-tipa.sh` | `dist/com.yzl.launcher.tipa`，已 ldid 伪签，直接给 TrollStore |
| macOS（只要未签名包） | `xcodegen generate` → `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` → `bash scripts/package-unsigned-ipa.sh` | `YZLLauncher-unsigned.ipa` |
| 手机直接下载 | 推 `v*` tag 触发 `release-ipa.yml` | GitHub Release 附件 |

`fetch-ipa.ps1` 只做触发 / 轮询 / 下载，不重传源码（首次上传用 `scripts\api-publish.ps1`）；构建失败会自动抓回云端日志并打印 `error:` 摘录。

`fetch-ipa.ps1` 现在会同时取回 `.ipa` 与 `.tipa`。**主线用 `.tipa`**：它已带 TrollStore entitlement，直接分享给 TrollStore 就能装，永久有效、免 Apple ID、自动 JIT —— 免费，且不需要任何证书（详见 `docs/FCL-PARITY.md`）。唯一门槛是设备系统：TrollStore 支持 iOS 14.0 beta 2 – 16.6.1 / 16.7 RC / 17.0。已决定**新增一台 iOS 16.0–16.6.1 的兼容测试机**（选型见 `docs/FCL-PARITY.md` §5.1）；原 iOS 18.7.8 留作免费 Apple ID 自签的备用机器。

**以下为备用路线（当前不采用）**：未签名 IPA 普通 iPhone 装不上，要「自签后的 IPA 文件」还有一步：

- **免费 Apple ID**（推荐）：Sideloadly 的 **Signing mode → Export**，用 Apple ID 签好并**导出成 `.ipa` 文件**（不是边签边装）；7 天有效、最多 3 个自签 App。
- **有 `.p12` + `.mobileprovision`**：`scripts\sign-ipa.ps1` 调 zsign 命令行一键出签名包，可进 CI。
- **TrollStore 兼容设备**（iOS 14–16.6.1 / 16.7 RC / 17.0）：可直接分享未签名 IPA 给 TrollStore，或 `scripts/sign-ipa.sh … trollstore` 出带 entitlement 的 `.tipa`，永久有效。

备用机器是 iOS 18.7.8，**不在 TrollStore 兼容区**，只能走前两条；JIT 仍需 StikDebug / SideJITServer 附加。完整步骤、entitlement 匹配注意事项见 `docs/SIGNING.md` §0.5 / §0.6。

**本机被拦的是 `github.com` 的写操作**（实测：GET `/status` 3/3 通，POST `/login/device/code`、`/graphql` 3/3 超时；复测命令 `scripts/check-network.ps1`）。所以 `git push`、`gh auth login` 设备码、以及在 PC 浏览器里提交 token 表单都不可用，但 `api.github.com` 的 GET/POST 全通。发布因此改用 `scripts/api-publish.ps1`：只用 api 域完成建仓、上传文件树、触发 Actions、轮询、下载 artifact，并在构建失败时把云端日志抓回本地、直接打印 `error:` 摘录。它只需要一个 token，且必须在**能提交 github.com 表单的浏览器**（手机蜂窝流量）里创建。细节见 `docs/BUILD-AND-SIDELOAD.md` 的 1.1 / 1.2 节。

**仓库建议建成 Public**：Actions 的 macOS Runner 对私有仓库按 10 倍计费，免费额度 100 分钟/月大概只够 10 分钟 macOS 构建；公开仓库不占额度，而 iOS 端本来就要按 GPLv3 开源。`build-ipa.yml` 现在是两条独立的 job：`Device IPA (unsigned)` 出包（不依赖测试），`Unit tests (simulator)` 跑单测且失败不挡包；两边的构建日志都会作为 artifact 留下来。

**要自己签名**：看 `docs/SIGNING.md`。Windows 自签走 `scripts/sign-ipa.ps1`（或 Sideloadly 的 Export 模式），macOS 侧用 `scripts/sign-ipa.sh` 与 `scripts/build-tipa.sh`，`scripts/make-ota-manifest.sh` 出 OTA 清单；entitlements 模板在 `packaging/`，免费账号用 `entitlements.free.plist`。编译产物由 GitHub Actions 产出：外壳在 `build-output/YZL-Launcher-*-unsigned.ipa`，引擎整包在 `build-output/YZL-engine.tipa`。

> 注意：这条流水线只适用于 M0 自制外壳。接入 Amethyst 引擎后，构建要改成它的 `Makefile` + CMake 流程（cmake、JDK 8、ldid、4 个子模块），并同时产出 `.ipa` 和 TrollStore 用的 `.tipa`。详见 `docs/POJAV-ENGINE-AUDIT.md` 第 8–9 节。

## 微软登录配置

登录默认使用**微软 v1.0 浏览器授权码流**（`login.live.com/oauth20_authorize.srf` + App 内 `WKWebView` 拦截固定回调），密码只输在微软官方页面，不经过启动器。默认公共客户端 ID 与安卓版一致（`00000000402b5328`），开箱即可登录。自定义 Azure 公共客户端仍在设置里覆盖，走 v2.0 设备码流。

1. 直接点「登录微软账户」，在弹出的微软官方页面完成登录。
2. 如果想用自己的 Azure 应用：App registrations → New registration，账户类型选「仅个人 Microsoft 账户」。
3. 在 Authentication 里打开 **Allow public client flows** 并保存。
4. 复制 **Application (client) ID**，填入 App 的「设置 → 账户」。

客户端 ID 是公开标识，不是密钥；令牌只保存在本机 Keychain。启动时会自动用刷新令牌续期。

## 里程碑

- **M0（已完成）** 工程骨架、界面、版本清单、构建与侧载文档
- **M1（已完成）** 微软登录、版本安装、分片断点续传下载器、安装记录、启动自检与 LaunchPlan；云构建通过，单测 139 个全绿
- **M2（接缝完成）** LaunchCommand / RuntimeLocator / JITProbe / AmethystEngine + EngineBridge 已实现并带单测
- **M2-b（引擎包完成，待真机联调）** fork-overlay 路线：Amethyst fork + 三处补丁（Java YZL 分支 / 二进制名解耦 / SceneDelegate 根视图接管）+ mach.h 兼容补丁。成品含引擎、图形 dylib、Java 桥 jar、**完整可用的 JRE 8 / 17**（各约 102 MB）、`launcher.jar` 内的 `YZLGameEntry`，以及可执行的 `YZLUI.framework`。
  - **修正（2026-11-06）**：此前一版 `YZLUI.framework` 只有 `Info.plist` / `Assets.car`，缺 Mach-O 二进制（`YZLUI` 源码引用 `WKWebView` 但 framework target 没链接 WebKit，且 CI 对该步 `continue-on-error`）。现已补 `WebKit.framework` 依赖、去掉容错，并硬校验 `Frameworks/YZLUI.framework/YZLUI`；run `42220940394` 通过。
  - **修正（2026-11-07）**：旧产物 `YZL-engine-unsigned.ipa` 只是把 `.tipa` 复制改名，仍带 ldid 伪签与 TrollStore 私有 entitlement，iOS 18 用 SideStore / 轻松签 重签必然失败。现由 `scripts/make-sideload-ipa.sh` 剥离全部代码签名与私有权限，另产 `YZL-engine-sideload-unsigned.ipa`；`scripts/verify_engine_ipa.py` 对两个包做完整性硬校验并输出报告。
  - **已知限制**：JRE 21 / 25 因上游 CDN `assets.angelauramc.dev` 失效仍是空壳，**1.21+ 暂不能玩**；JRE 8/17 来自停更的 PojavLauncher iOS v2.2，建议后续换 Amethyst 社区维护版。
  - **剩余**：真机安装 → 确认进入 YZL 界面 → 安装版本 → 启动进游戏（清单见 `IOS18-SIDELOAD.md` §8）；微软网页授权真机回环；M3 与 GPLv3 衍生开源义务。
- **M3（未开始）** 模组 / 整合包、三源聚合、联机能力

## 合规

- 不内置游戏文件，资源从 Mojang 官方获取；用户必须自己拥有 Minecraft。
- PojavLauncher_iOS 已归档；活跃继任者 Amethyst-iOS 为 GPLv3。M2 复用其 JRE / 启动层后，iOS 端相关部分及衍生作品需要按 GPLv3 开源。纯 SwiftUI 外壳预览包不含上游代码，但**引擎包包含**，详见 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。仓库目前仍为私有、缺少 `LICENSE`，**对外分发引擎 IPA 前必须补齐对应源码与许可声明**，这是尚未完成的合规义务。
- 与 Mojang、Microsoft、Amethyst / PojavLauncher 团队无隶属关系。

## 已确定的路线（2026-11-04）

1. **构建环境**：目前只有 Windows。首轮编译走 GitHub Actions 云构建，或临时借用 Mac；本机继续做代码和静态检查。
2. **引擎路线**：保留自制 SwiftUI 外壳，复用 Pojav 系引擎。PojavLauncher_iOS 已归档，实际底座改用活跃维护的 **Amethyst-iOS**（GPLv3）。与引擎链接的 iOS 端部分按 GPLv3 开源，不再按闭源分发设计。
3. **测试机与两条并行路线（2026-11-07 更新）**：
   - **TrollStore 主线（全程零电脑）**：A12+ / iOS 15.0 – 15.4.1 的设备，手机 Safari 用 TrollHelperOTA 装 TrollStore，装 `YZL-engine.tipa`。选型见 `docs/FCL-PARITY.md` §5.1。
   - **iOS 17.4+ / 18.x 侧载线（本机既有测试机 18.7.8，用户指定优先）**：不折腾巨魔，用 `YZL-engine-sideload-unsigned.ipa` + SideStore 重签 + StikDebug 开 JIT。**不要再把它当「备用机器」**——2026-11-07 起该路线有独立构建产物与文档 `docs/IOS18-SIDELOAD.md`；首次配对仍需电脑，之后手机可自续签。
4. **界面方向**：2026-11-04 晚改为固定横屏，主页/账户/关于/版本详情统一双列；竖屏布局不再维护。

引擎接缝审计见 `docs/POJAV-ENGINE-AUDIT.md`（已完成初步审计）。
