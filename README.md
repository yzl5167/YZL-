# YZL Launcher iOS

仿照 PojavLauncher / Amethyst 思路的 Minecraft: Java Edition iOS 启动器（侧载版）。沿用 YZL 桌面端的浅色蓝主题与卡片样式。

> 与 FCL 启动器的对应关系、平台差异、以及「免费 Apple ID 能不能搞」见 [`docs/FCL-PARITY.md`](docs/FCL-PARITY.md)。**一个二进制覆盖全部 iOS 15+，凡是该系统版本支持免电脑就自动走免电脑路线**，完整分流矩阵见 [`docs/DEPLOYMENT-MATRIX.md`](docs/DEPLOYMENT-MATRIX.md)。主线交付物是 TrollStore `.tipa`。

当前处于 **M0 工程骨架 + M1 安装/启动准备 + M2 引擎接缝（可测部分）**。界面、Mojang 版本清单、设备代码登录、分片下载器、整包安装、安装记录持久化、启动参数与命令行组装已写入；**JRE 二进制与 Amethyst 内核尚未接入，真正进入游戏仍要等引擎桥实现**。

2026-11-05 09:20 的首次云构建暴露了 `AvatarView.swift` 的 3 个 Swift 编译错误，当天已修复，并把 `scripts/preflight.py` 静态自检挂进全部 CI 任务。截至 11-05 中午，**修复后的代码尚未在 macOS 上复跑编译**，仓库里仍没有 IPA。

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
| XcodeGen 工程与资源目录 | 已建立，未编译 |
| YZL 风格 SwiftUI 外壳（固定横屏、左侧图标栏） | 已实现，未编译 |
| 安卓同款 FCL 式居中主页（头像 / 版本 / 启动） | 已实现，未编译 |
| 账号管理页（安卓同款卡片 + 设备代码登录） | 已实现，未编译 |
| 皮肤页（读取 Mojang 档案皮肤贴图） | 已实现，未编译 |
| 版本页主从分栏（左列表 + 右详情） | 已实现，未编译 |
| 微软设备代码登录（Xbox / XSTS / Minecraft + Keychain） | 已实现，未编译联调 |
| Mojang 版本清单拉取 | 接口结构已用真实响应验证；Swift 侧未编译联调 |
| 分片下载器 + 客户端 jar / 整包安装 | 已实现，未编译 |
| 安装清单（规则过滤/依赖库/资源去重）+ 多文件队列 | 已实现，清单数字用真实 Mojang 数据核对，未编译 |
| 安装记录 `installed.json` + 当前版本持久化 | 已实现，未编译 |
| 启动自检（账户/文件/令牌/JRE/JIT/内核）+ LaunchPlan 参数生成 | 已实现到引擎边界，未编译 |
| LaunchCommand（JVM argv 顺序、令牌脱敏、环境变量） | 已实现，含单测 |
| RuntimeLocator（JRE / natives 真实定位，空目录不算可用） | 已实现，含单测 |
| JITProbe（RWX 页探测，可注入便于测试） | 已实现，含单测 |
| AmethystEngine + EngineBridge 协议（M2 接缝） | 已实现，含单测；桥未注入 |
| JRE 二进制 + Amethyst 内核 + SurfaceViewController | 未开始，需要 macOS / CMake 构建 |
| 上游引擎接缝审计 | 已完成初步审计，见 `docs/POJAV-ENGINE-AUDIT.md` |
| 静态自检 `scripts/preflight.py`（括号 / JSON / plist / 禁用 API / shell / ps1 BOM） | 已实现并接入全部 CI 任务 |
| `scripts/fetch-ipa.ps1`（Windows 一键触发构建并取回 IPA） | 已实现，PowerShell 5.1 语法校验通过 |
| **云构建直出 TrollStore `.tipa`（主线）** | 已接入 `build-ipa.yml` / `release-ipa.yml`（ldid 伪签 + artifact + Release 附件），未实跑 |
| 现代版本参数解析（arguments / minecraftArguments + 占位符替换 + 平台/feature 规则过滤） | 已实现，含单测（ArgumentResolverTests），未编译 |
| 版本继承合并 VersionMerger（inheritsFrom 拍平，Forge/Fabric 启动前置） | 已实现，含单测（VersionMergerTests）；安装期拍平存盘待接入 |
| 通用自适应（堆上限按可用内存收敛、不按机型出包） | 已实现并补单测，未编译 |
| 全系统自动分流（6 档，能用免电脑就用免电脑） | 已实现：部署档位判定、JIT 按钮分流、诊断页三行提示、单测；未编译 |
| Windows 自签（备用，当前不采用） | 脚本与 entitlement 模板已实现，未用真实证书实跑 |

> 表里的「未编译」指**修复后的整包代码还没在 macOS 上重新编过一次**；09:20 那次云构建已成功生成 Xcode 工程，并编过除 `AvatarView.swift` 以外的全部文件。
>
> 本工程在 Windows 上创建，本机没有 Xcode 和 Swift 编译器。现在可以先跑 `python3 scripts/preflight.py` 做静态自检（CI 三个任务也都会跑），但**真正的编译验证仍只能在 Mac 或云端 macOS 上完成**：`xcodegen generate` + `xcodebuild` 通过，模拟器能打开主页、版本、账号、设置四个页面并拉到版本列表，且 `LaunchCommandTests` / `RuntimeLocatorTests` / `EngineIntegrationTests` 全绿。

iOS 外壳按安卓已安装版同步：左侧 84pt 图标栏、居中 FCL 式主页、卡片式账号管理页和设备代码登录弹窗。安卓工程本身未做修改；iOS 的默认微软公共客户端 ID 与安卓一致（`00000000402b5328`），自定义 Azure 客户端仍可在设置里覆盖。

### 下载与启动按钮现在做什么

- **开始安装**：主页的「下载游戏」或版本页的「开始安装」都会拉取版本 JSON，保存到 `Documents/YZLVersions/<版本>/<版本>.json`；随后下载客户端 jar、iOS 适用的依赖库、资源索引和去重后的资源对象。全部文件通过 SHA-1 后才写入 `installed.json` 并自动设为当前版本；中断/失败不会留下“已安装”标记。
- **继续安装**：已完成且 SHA-1 一致的文件直接跳过，未完成的分片从断点续传，不会把 732 MB 从头再下一遍。
- **启动游戏**：先做启动自检——账户与令牌、安装记录、版本 JSON、客户端 jar、依赖库、资源索引、JRE、JIT、Amethyst 内核、内存——再生成 classpath、主类、JVM 参数和游戏参数（`LaunchPlan`）。全部通过后才交给引擎。
- 自检面板现在会额外显示一条「启动命令」检查项：`LaunchCommand` 已把 JVM 参数、`-cp`、主类与游戏参数按顺序组装好，令牌只留在内存且展示时脱敏。
- 目前 JRE 二进制与 Amethyst 内核仍属于 M2，所以自检会明确停在「Java 运行时 / 启动内核」两项；按钮不再弹一句“还不能启动”，而是打开可逐项核对的启动面板。接入引擎后只需提供一个 `EngineBridge` 实现并注入 `AmethystEngine`，外壳与启动面板都不用改。

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
│                                   LaunchCommand / RuntimeLocator / JIT / 引擎接缝
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

**要自己签名**：看 `docs/SIGNING.md`。Windows 自签走 `scripts/sign-ipa.ps1`（或 Sideloadly 的 Export 模式），macOS 侧用 `scripts/sign-ipa.sh` 与 `scripts/build-tipa.sh`，`scripts/make-ota-manifest.sh` 出 OTA 清单；entitlements 模板在 `packaging/`，免费账号用 `entitlements.free.plist`。前提是先有编译产物——本机没有 Xcode，目前仓库里还没有 IPA。

> 注意：这条流水线只适用于 M0 自制外壳。接入 Amethyst 引擎后，构建要改成它的 `Makefile` + CMake 流程（cmake、JDK 8、ldid、4 个子模块），并同时产出 `.ipa` 和 TrollStore 用的 `.tipa`。详见 `docs/POJAV-ENGINE-AUDIT.md` 第 8–9 节。

## 微软登录配置

登录使用**设备代码流（device code flow）**，不需要重定向 URI，也不需要把密码交给启动器。默认公共客户端 ID 与安卓版一致，开箱即可登录。

1. 直接点「登录微软账户」，按弹窗提示在 `https://microsoft.com/link` 输入代码。
2. 如果想用自己的 Azure 应用：App registrations → New registration，账户类型选「仅个人 Microsoft 账户」。
3. 在 Authentication 里打开 **Allow public client flows** 并保存。
4. 复制 **Application (client) ID**，填入 App 的「设置 → 账户」。

客户端 ID 是公开标识，不是密钥；令牌只保存在本机 Keychain。启动时会自动用刷新令牌续期。

## 里程碑

- **M0（已完成）** 工程骨架、界面、版本清单、构建与侧载文档
- **M1（代码完成，待编译）** 微软登录、版本安装、分片断点续传下载器、安装记录、启动自检与 LaunchPlan
- **M2（接缝完成，二进制未接）** LaunchCommand / RuntimeLocator / JITProbe / AmethystEngine + EngineBridge 已实现并带单测；JRE 二进制、Amethyst 内核、`JLI_Launch` 与 `SurfaceViewController` 桥接仍待 macOS / CMake 侧完成，之后才能真机进主菜单
- **M3（未开始）** 模组 / 整合包、三源聚合、联机能力

## 合规

- 不内置游戏文件，资源从 Mojang 官方获取；用户必须自己拥有 Minecraft。
- PojavLauncher_iOS 已归档；活跃继任者 Amethyst-iOS 为 GPLv3。M2 复用其 JRE / 启动层后，iOS 端相关部分及衍生作品需要按 GPLv3 开源。目前 M0 外壳不包含上游代码。
- 与 Mojang、Microsoft、Amethyst / PojavLauncher 团队无隶属关系。

## 已确定的路线（2026-11-04）

1. **构建环境**：目前只有 Windows。首轮编译走 GitHub Actions 云构建，或临时借用 Mac；本机继续做代码和静态检查。
2. **引擎路线**：保留自制 SwiftUI 外壳，复用 Pojav 系引擎。PojavLauncher_iOS 已归档，实际底座改用活跃维护的 **Amethyst-iOS**（GPLv3）。与引擎链接的 iOS 端部分按 GPLv3 开源，不再按闭源分发设计。
3. **测试机（2026-11-05 已决策）**：为做到**全程免电脑**，选一台 **A12+ / iOS 15.0 – 15.4.1** 的设备，用 **TrollHelperOTA** 在手机 Safari 里装 TrollStore（不用电脑、不用 Apple ID）；到手先关自动更新、别升级。选型与操作步骤见 `docs/FCL-PARITY.md` §5.1。原 iOS 18.7.8 保留作免费 Apple ID 自签的备用机器。
4. **界面方向**：2026-11-04 晚改为固定横屏，主页/账户/关于/版本详情统一双列；竖屏布局不再维护。

引擎接缝审计见 `docs/POJAV-ENGINE-AUDIT.md`（已完成初步审计）。
