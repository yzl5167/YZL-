# YZL Launcher iOS 架构（M0）

## 1. 分层

```
SwiftUI 外壳
  Home / Versions / Skin / Launch / Account / Settings
        │
LauncherCore（Swift）
  版本清单 · 安装计划 · 下载器 · 微软登录 · 本地配置
        │
M2 接缝（Swift，已实现并带单测）
  LaunchCommand · RuntimeLocator · JITProbe · AmethystEngine
        │
EngineBridge（协议已定义；ObjC / C 实现待接入）
  JRE 管理 · JLI_Launch · SurfaceViewController · 输入映射
        │
Pojav 系（Amethyst）iOS 内核 + 自备 JRE
  Java 运行时 · LWJGL/GLES 适配 · AWT 后端 · 输入映射
```

M0/M1 实现不依赖 JVM 的部分：界面、版本清单、账户、安装、启动自检与参数生成、诊断信息、引擎协议占位。

## 2. 为什么不能"自己下载原版就能跑"

桌面端 Minecraft 的依赖里有 Windows/macOS/Linux 原生库（LWJGL、GLFW、OpenAL 等），iOS 不能加载。Pojav 系启动器能跑，是因为内核提供了：

- 面向 iOS 的 JRE（arm64）
- JIT 开启能力（TrollStore / 调试附加）
- LWJGL 2/3 的 iOS 替换层（OpenGL ES / Metal 呈现）
- AWT 的 headless / Caciocavallo 类后端
- 触摸、手柄、键盘映射

因此 M1 的安装器不能简单照搬 PC 端的 libraries 列表，必须在内核提供的补丁库和版本规则之上生成安装计划。M2 之前不做"完整安装"的假实现。

## 3. 引擎路线

| 路线 | 工作量 | 风险 | 结论 |
| --- | --- | --- | --- |
| Fork PojavLauncher_iOS 后换 UI | 小 | 代码老、UI 改造受限于原结构、GPLv3 | 备选 |
| 保留本外壳，接 Pojav 的 JVM/启动层 | 中 | 需要理清 ObjC/C 接口和数据目录约定、GPLv3 | **已选（2026-11-04）** |
| 完全自研 JRE/渲染层 | 极大 | 基本不现实 | 不选 |

已选路线下，Swift 外壳负责界面、账户、下载、实例与配置；引擎侧提供 JRE 管理、JVM 启动、LWJGL/GLES 适配和输入映射。**在与引擎链接后，iOS 端整体按 GPLv3 开源**，文档和关于页都按这个前提写。

2026-11-04 审计更新：PojavLauncher_iOS 已归档，实际底座改用活跃维护的 Amethyst-iOS；它的入口是 `launchJVM(...)`，但不是独立 framework，推荐 fork Amethyst 后把 UIKit 界面替换成我们的 SwiftUI 外壳。详见 `docs/POJAV-ENGINE-AUDIT.md`。

需要接受的约束：

- PojavLauncher_iOS 使用 GPLv3。链接或分发其代码/二进制，iOS 端整体基本需要按 GPLv3 开源。
- 微软账户登录使用自己的 Azure 公共客户端 ID，不复用他人应用身份。
- 游戏资源从 Mojang 官方接口下载，启动器不内置游戏本体。

## 4. M1 下载器设计（沿用 YZL 桌面端加速方案）

目标不是"能下"，而是"校园网/跨境链路下也尽量快，并且进度真实"。

> 如果按审计建议 fork Amethyst，M1 不再从零写安装器和微软登录，而是复用它的 `MinecraftResourceDownloadTask` / `authenticator`，只把下载层替换成下面的 YZL 加速方案。下面的策略仍然作为验收标准。

1. **元数据阶段**
   - 拉取 `version_manifest_v2.json` 选择版本；
   - 拉取版本 JSON，解析 libraries、assetIndex、downloads；
   - 按 iOS 规则过滤依赖库；JRE 与 iOS 原生库由 M2 引擎提供，不计入安装清单。
2. **分片下载**（`SegmentedDownloader` 已按此实现，未编译）
   - 先用 `HEAD` 探测：`Accept-Ranges: bytes` + `Content-Length` 才走分片，否则直接单连接；
   - 默认 1 MiB 分片，连接数 8（可配置 1–16），单请求超时 15 s，分片重试 3 次（0.5/1.0/1.5 s 退避）；
   - 一个**尚未写入任何字节**的分片在重试耗尽后拆成两半重新排队，避免尾部长尾；已有进度的分片只续传不拆分；
   - 分片请求若收到 `200`（服务器忽略 Range），整条链路立刻回退单连接，不反复重试；
   - 每片落独立 `.part` 文件，避免多线程写同一文件偏移；完成后按偏移顺序合并。
3. **续传与校验**
   - 分片状态与临时文件落盘，重启后继续；
   - 合并后做 SHA-1 校验，失败即删除临时文件并报错；
   - 全部完成前进度不到 100%，不显示"已完成"。
   - 已知取舍：单连接回退模式用逐字节流式读取，进度真实但吞吐较低；分片模式是主路径。
4. **安装清单与队列**（`InstallPlanner` + `DownloadQueue`，已实现，未编译）
   - Mojang 规则语义：无规则即必需；有规则时以最后一条匹配规则为准；没有任何规则匹配则不必需。因此 iOS 下 osx/windows/linux 专用库全部排除，`net.java.jinput:jinput-platform` 这类只有 classifiers（原生件）的库直接跳过——iOS 原生库由引擎提供。
   - 清单 = 客户端 jar + 依赖库 + 资源索引，再展开资源对象并按 sha1 去重。1.20.1 实测：45 个基础文件 + 3,575 个资源对象 = **3,620 个文件、约 732 MB**。
   - 队列文件级并发 8；单文件 > 4 MiB 才在内部开 8 路分片，小文件走单连接，避免上千个小文件互相抢连接。
   - 聚合进度同时按"文件数 + 字节数"统计，全部完成才到 100%，失败文件单独列出并可只补差额。
   - 下载前把版本 JSON 编码保存到版本目录；全部文件通过 SHA-1 后写 `installed.json`（文件数、总字节、Java 主版本、资源索引、安装时间），并自动设为当前版本。失败/取消不写记录。
   - JRE 与 iOS 原生库不在这条清单里，由 M2 引擎侧提供；不做"假安装"。

5. **启动链**（`LaunchPlanBuilder` + `LaunchCommand` + `EngineBridge`，已实现到引擎边界，未编译）
   - 启动自检依次核对：微软账户与令牌（快过期时自动续期）、安装记录、版本 JSON、客户端 jar、依赖库、资源索引、JRE、JIT、Amethyst 内核、内存上限。
   - 通过后生成 `LaunchPlan`：classpath（客户端 jar + iOS 规则过滤后的库）、主类、`--assetIndex` / `--gameDir` / `--uuid` / `--accessToken` 等游戏参数，以及 `-Xmx` / `-Djava.library.path` 等 JVM 参数。
   - 访问令牌只存在于内存中的 `gameArguments`，不写日志、不落盘；界面只显示不含令牌的摘要。
   - `LaunchCommand` 把 JVM 参数、`-cp`、主类、游戏参数按 JLI_Launch 要求的顺序拼成 argv；`environment` 只放路径，`redactedArguments` 会把 `--accessToken` 的值全局替换成 `<redacted>`，日志与 UI 一律用脱敏版本。
   - `RuntimeLocator` 用 `libjli.dylib` / `libjvm.dylib` 等真实标记判定 JRE（空目录不算可用）；`JITProbe` 通过申请一页 RWX 内存判定 JIT，探测逻辑可注入，模拟器跳过真实探测。
   - `AmethystEngine` 按「JRE → JIT → 命令 → 桥」顺序校验；`EngineBridge` 未注入时明确抛 `notIntegrated`，不伪造启动成功。接入 Amethyst 后只需提供桥实现并注入，外壳与启动面板都不用改。`PlaceholderEngine` 保留作未桥接时的兜底占位。

M1 的验收：同一网络下与单线程下载对比总耗时；弱网断点续传后文件哈希一致；进度日志逐秒可核对。安装完成后 `installed.json` 与版本目录一致；启动自检能在缺文件、缺 JRE、JIT 未开、内核未接入时分别给出明确错误。

## 6. 账户与安全

- 登录链路：Microsoft OAuth 设备代码流 → Xbox Live → XSTS → Minecraft 档案，实现见 `Core/Auth/MicrosoftAuth.swift`。
- 设备代码流：`/devicecode` 取码，按返回的 `interval` 轮询 `/token`；不需要重定向 URI，也不内嵌自建密码页。
- 默认使用与安卓版相同的公共客户端 ID `00000000402b5328`（Live Connect）；也可以换成自己的 Azure 公共客户端（走 v2.0 consumers）。客户端 ID 是公开标识，不是密钥。
- 访问令牌与刷新令牌只存 Keychain（`AuthSessionStore`）；启动时读取未过期会话，过期后用刷新令牌自动续期。
- 启动器要求用户拥有正版账户；不实现离线绕过。
- 2026-11-04 真实端点探测补充（不登录，只看协议形状）：
  - Live Connect 的设备码响应**不含 `message`**，模型里必须是可选值，否则真机解码直接失败；
  - `grant_type=urn:ietf:params:oauth:grant-type:device_code` 被接受，`grant_type=device` 返回 `unsupported_grant_type`；
  - 默认公共 ID 打到 Azure v2.0 `devicecode` 会 `AADSTS700016`，所以 Live Connect 分支不能删；
  - Xbox `RpsTicket=d=<token>`、XSTS `RelyingParty=rp://api.minecraftservices.com/`、`XBL3.0 x=<uhs>;<xsts>`；XSTS 的 `XErr` 要翻译成中文（无 Xbox 账户 / 地区不可用 / 年龄验证 / 儿童账户需家庭组）。
- 皮肤只读 Mojang 档案的 `skins[].url`，头部在本地裁 (8,8,8,8) 后最近邻放大，不请求 mc-heads 之类第三方头像服务（那会把玩家 UUID 发给外部）。

## 7. iOS 运行时约束

- **JIT**：非越狱设备需要调试附加或 TrollStore / SideJITServer；引擎启动前要检测，未开启时直接给明确提示，不"假装启动"。
- **内存**：iPhone 上 JVM 堆建议 1024–2048 MB，超过设备 jetsam 限制会被系统杀掉。
- **后台**：进入后台会挂起，下载和游戏不能依赖后台常驻；需要恢复策略。
- **屏幕方向**：外壳固定横屏（左右），与 Amethyst 的 iPhone 配置一致；导航改为安卓同款左侧 84pt 图标栏（首页 / 版本 / 设置 + 账号头像 + 关于），主页是 FCL 式居中头像、当前版本和启动按钮，账号页是卡片式账号管理。版本页保留左列表 + 右详情主从分栏。M2 的游戏 `SurfaceViewController` 只返回横屏掩码，避免画面被竖屏拉伸，陀螺仪校准同样按横屏判定（Amethyst `Natives/input/GyroInput.m:19`）。
- **签名**：免费 Apple ID 侧载通常 7 天过期，需重新签名；TrollStore 仅支持部分系统版本。
- **审核**：App Store 2.5.2 禁止下载执行代码，因此不做上架计划。

## 8. 里程碑与验收

| 里程碑 | 交付 | 验收 |
| --- | --- | --- |
| M0 | 工程、界面、版本清单、文档 | Mac/CI 构建通过；模拟器四个页面可切换；真机可拉取版本列表并截图 |
| M1 | 微软登录、安装计划、下载器 | 完成一个原版版本的全部文件下载与校验；弱网续传通过；令牌只落 Keychain |
| M2-a（已交付） | 引擎接缝层 | LaunchCommand / RuntimeLocator / JITProbe / AmethystEngine 单测全绿；命令顺序正确、令牌脱敏、缺 JRE/JIT/桥分别给出明确错误 |
| M2-b | JRE 二进制 + Amethyst 内核 + 桥实现 | 真机（已开 JIT）进入主菜单；日志和录屏留证；能正确报告 JIT 缺失 |
| M3 | 模组/整合包/三源/联机 | 单源失败不影响其他源；真实进度；至少一个整合包可启动 |

## 9. 已知风险

- GPLv3 与闭源分发冲突，需要尽早定路线。
- Amethyst / Pojav 内核的接口和资源布局随版本变化，接之前先锁定一个可工作的上游提交，并保留可回退的基线。
- iOS 系统升级可能改变 JIT 可用性，工具链要按设备/系统版本分开验证。
- 非官方启动器不受 Mojang 支持，账号异常风险由用户承担，需在关于页说明。
