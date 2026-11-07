# iOS 17.4+ / 18.x 侧载指南（不走 TrollStore）

> 适用：没有 TrollStore、也不打算换低版本系统的 iPhone（本项目测试机为 iOS 18.7.8）。
> 对应产物：`YZL-engine-sideload-unsigned.ipa`（干净未签名，约 110 MB）。
> 2026-11-07 起由 `.github/workflows/build-engine-ipa.yml` 与 `.tipa` 同时产出。
>
> **去哪拿包**：GitHub Actions → `Engine baseline (M2-b experiment)` 最新一次
> 成功的 run → artifact `engine-build-main` → 解压取
> `YZL-engine-sideload-unsigned.ipa`（同目录还有 `ENGINE-PAYLOAD-*.txt` 校验报告）。
> Actions artifact 有保留期限；也可用 `relay-engine.yml` 中转出的临时直链。
> `release-ipa.yml` 只挂外壳预览包，**不含引擎包**。

## 0. 先纠正一个常见误解：这是单包，不是两个 App

YZL 的架构是 **fork-overlay**：YZL 的界面以 `YZLUI.framework` 注入进
Amethyst 的 `AngelAuraAmethyst.app`，由 fork 主二进制提供 `launchJVM` 符号，
`LauncherEngineFactory` 在进程内 `dlsym` 命中后走真引擎桥。

因此：

- **只装一个包**：`YZL-engine-sideload-unsigned.ipa`，启动后就是 YZL 界面。
- `YZLLauncher-unsigned.ipa`（约 1.1 MB）是**纯外壳预览包**，
  里面没有 `launchJVM` 符号，`isAvailable = false`，点启动必然报
  「启动内核尚未接入（M2）」。它只用于看 UI / 跑单测，**装了进不了游戏**。
- 不要把两个 IPA 都装上、也不要指望它们互相通信——两个独立沙盒 App 之间
  没有这条通路。

## 1. 为什么之前装不上

历史产物 `YZL-engine-unsigned.ipa` 其实是把 `.tipa` 直接复制改名：仍带
`ldid` 伪签，以及 `com.apple.private.security.no-sandbox`、
`platform-application`、`com.apple.developer.kernel.increased-memory-limit`
等 TrollStore 私有权限。个人开发证书无法签这些权限，SideStore / 轻松签
在安装阶段就会拒绝，表现为「安装失败，稍后再试」。

现在的 `YZL-engine-sideload-unsigned.ipa` 由 `scripts/make-sideload-ipa.sh`
重新生成：剥离全部 `LC_CODE_SIGNATURE`（私有 entitlement 随签名一起消失）、
删除 `_CodeSignature` / `embedded.mobileprovision` / `CodeResources`，
**不预置任何 entitlement**。重签工具用自己的开发证书写入
`get-task-allow`，JIT 靠调试器附加获得。

`scripts/verify_engine_ipa.py --mode sideload` 会在 CI 里硬校验：签名残留为 0、
二进制里不含私有 entitlement 字符串、YZLUI 是真 Mach-O、JRE 8/17 真实可用。

## 2. 准备（一次性，需要电脑）

1. 电脑装上 **SideStore**（或 AltStore）；免费 Apple ID 即可，7 天到期后
   SideStore 可在手机上自动续签。
2. 用 **JitterbugPair / iloader** 生成一次配对文件（建立设备与「可信电脑」的信任）。
3. 手机装 **LocalDevVPN**（本地回环 VPN，不走远程服务器）和 **StikDebug**。

> 17.0.1–17.3.x 这一段 StikDebug 不支持，需要 AltServer / SideJITServer
> 持续附加电脑，见 `DEPLOYMENT-MATRIX.md` 的 `computerAttached` 档。

## 3. 安装

1. 把 `YZL-engine-sideload-unsigned.ipa` 导入 SideStore，用你的开发证书重签安装。
   - 若用轻松签 / Sideloadly：选「忽略 / 移除原有 entitlement」，不要勾选
     `increased-memory-limit` 等需要付费描述文件的能力。
   - 重签工具必须递归签深层 Mach-O（含 `java_runtimes/*/lib/*.dylib`、
     `Frameworks/*.framework`）。若只签主程序，运行时 `dlopen` 会失败；
     遇到「已安装但一启动就闪退」优先排查这一点。
2. 安装后图标名显示为 **YZL Launcher**（重打包阶段已改写 `CFBundleDisplayName`）。

## 4. 每次启动前开 JIT（iOS 上不能省）

JIT 不会跨 App 重启保留，每次都要：

1. 连上 LocalDevVPN；
2. 打开 StikDebug → 选中 **YZL Launcher** → **Enable JIT**；
3. 回到启动器点启动。

不开 JIT 时 Java 运行时无法启动，启动自检会明确报「JIT 未开启，Java 运行时无法启动」。

## 5. 进游戏

1. 登录：正版走微软网页授权（Safari 内完成，回跳后由 App 拦截回调取 code）；
   无正版可用「离线账号（伪正版）」。
2. **版本选择有限制**：当前包里 **JRE 8 与 JRE 17 是完整真实的**（各约 102 MB，
   来自 PojavLauncher iOS v2.2 提取），**JRE 21 / 25 是空壳**（上游 CDN
   `assets.angelauramc.dev` 已失效，Wayback 也拿不到）。
   - 可选 **1.20.1 及以下**（Fabric / Quilt 亦可，见 README 的加载器章节）
   - **1.21+ 暂不能玩**（需要 Java 21），不要选，否则会卡在运行时校验
3. 安装版本 → 等 SHA-1 校验完成 → 启动。
4. 整合包建议开启设置页「iPhone 兼容 → 自动适配」：会关掉 Iris 光影、
   收敛 Sodium 参数与 `options.txt` 视距，并在 120/240/420 秒 dump 线程栈到
   `<gameDir>/logs/yzl-stall-*.log`，便于定位「卡在正在加载地形」。

## 6. 内存限制（免费账号的硬约束）

免费个人开发者描述文件**不含** `com.apple.developer.kernel.increased-memory-limit`
与 `extended-virtual-addressing`，写了反而会导致安装被拒。所以侧载包刻意不预置
这两个权限，由 App 的 `maxSafeHeapMB` 按可用内存自适应收敛 JVM 堆。

实际影响：堆通常只能给到 1–2 GB，454 模组这类大整合包比桌面端更容易
GC 抖动或被 jetsam 杀掉。这不是下载器的问题。

## 7. 已知限制 / 待验证（诚实清单）

| 项 | 状态 |
| --- | --- |
| 云构建产出干净侧载 IPA、完整性硬校验 | 已实现，CI 校验通过 |
| **真机联调**（安装 → YZL 界面 → 装版本 → 启动进游戏） | **尚未做过一次**，这是当前最大缺口 |
| 微软网页授权在真机上的完整 OAuth 回环 | 有待联调（单测已覆盖参数链路） |
| JRE 21 / 25（1.21+ 版本） | 上游源失效，包内为空壳；报告 `ENGINE-PAYLOAD-SIDELOAD.txt` 会告警 |
| 深层 dylib 是否被各类重签工具完整签名 | 取决于工具，需真机验证 |
| Forge / NeoForge、联机、模组整合包下载 | M3，未开始 |
| GPLv3 衍生部分开源义务 | 分发引擎包前需补齐许可证与对应源码声明 |

## 8. 真机联调清单（请按序回填结果）

1. SideStore 重签 `YZL-engine-sideload-unsigned.ipa` **是否安装成功**（不再出现「稍后再试」）
2. 打开后**是否进入 YZL 界面**（而不是 Amethyst 原生 UI）
3. 诊断页显示 JRE 8 / 17 就绪、YZLUI 就绪
4. 微软网页授权能否拿到令牌；离线账号能否直接进
5. 下载 1.20.1（或原版 1.12.2）→ SHA-1 全绿
6. StikDebug 开 JIT 后点启动 → 是否真正进入世界
7. 若卡住，取 `<gameDir>/logs/yzl-stall-*.log` 与启动面板逐项截图
