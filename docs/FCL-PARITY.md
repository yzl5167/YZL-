# 和 FCL 启动器一样吗

> 结论：**架构和界面已经按 FCL 的思路对齐了，装法永远对不齐** —— 差别来自 Android 与 iOS 的系统限制，不是启动器实现问题。
> 2026-11-05 确认：当前主线只走 **TrollStore `.tipa`**（FCL 式：装一次一直用、免 Apple ID、自动 JIT）；7 天自签与证书路线保留为备用，不启用。

## 1. FCL 是什么

FCL（Fold Craft Launcher）是**安卓**平台的 Minecraft Java 版启动器，GPL-3.0，免费开源：

- 以 HMCL 的核心逻辑为前台，**Amethyst-Android（PojavLauncher 的 Android 分支）** 作 JVM 启动与渲染后端；
- 内置 Java 8 / 17 / 21 / 25 多版本运行时，首次打开点一下「安装运行环境」即可；
- 支持 Forge / Fabric / Quilt / NeoForge、整合包、光影、虚拟按键；
- 分发方式就是 **一个 APK**：浏览器下载 → 允许「未知来源」→ 安装 → 完事，不签名、不续期、不用电脑。

本项目的安卓端此前就是照 FCL 做的，所以 iOS 端也沿用了「左侧图标栏 + 居中 FCL 式主页 + 卡片式账号页」。

## 2. 一一对应

| 层 | FCL（Android） | YZL Launcher iOS | 是否对齐 |
| --- | --- | --- | --- |
| 界面 | HMCL 风格 / FCL 式主页 | 安卓同款 FCL 式主页、账号卡片、版本主从分栏 | ✅ 已同步 |
| JVM 后端 | Amethyst-Android（Pojav 系） | **Amethyst-iOS**（同一生态的 iOS 分支，M2-b 待接） | ⚠️ 同宗，未接入 |
| Java 运行时 | 内置 Java 8/17/21/25 | 待随 Amethyst 内核放入 `java_runtimes/`（M2-b） | ⚠️ 未接入 |
| 版本安装 | 下载页面选版本 / 加载器 | Mojang 清单 + Fabric / Quilt 加载器（官方 Meta）+ BMCLAPI 镜像 + 分片断点续传 + 整包安装 | ✅ 已实现（Forge/NeoForge 待接） |
| 皮肤 | 本地导入 / 皮肤站 / 官方 | 离线本地导入（相册 + 尺寸校验）/ Mojang 档案读取 / 官网引导 | ✅ 已实现（皮肤站账号待接） |
| 账号 | 离线 / 微软正版 | 设备代码流 + Keychain | ✅ 已实现 |
| 分发 | 直接装 APK | **IPA 必须签名**；主线出 `.tipa` 给 TrollStore | ❌ 平台差异 |
| JIT | Android 默认允许 | iOS 沙箱默认禁止，需 TrollStore 或调试器附加 | ❌ 平台差异 |
| 有效期 | 永久 | TrollStore 永久；免费 Apple ID 仅 7 天 | ❌ 平台差异 |

## 3. 三道墙：为什么 iOS 不能"和 FCL 一样"

1. **代码签名**：iOS 上任何可执行代码都必须有有效签名。Android 允许侧载任意 APK，iOS 不允许无签名安装。
2. **JIT / W^X**：iOS 普通沙箱不能把内存页同时设为可写可执行，Java 版没有 JIT 基本不可用。TrollStore 通过 CoreTrust 漏洞授权，AltStore/SideStore 只能靠调试器附加。
3. **App Store 2.5.2**：禁止应用下载并执行代码，因此这类启动器无法上架，只能侧载。

FCL 在 Android 上把「运行时 + 引擎 + 游戏下载」全塞进一个 APK 就解决了；iOS 上同样的技术栈必须拆成「编译 → 签名 → 授权 JIT」三步。

## 4. 免费 Apple ID 能搞吗

**能装，但做不到 FCL 式。** 更反直觉的一点：**真正接近 FCL 的 TrollStore 完全免费，而且根本不需要 Apple ID**。

| 方案 | 花钱 | 要 Apple ID | 有效期 | JIT | 要电脑 | iOS 18.7.8 |
| --- | --- | --- | --- | --- | --- | --- |
| **TrollStore `.tipa`（主线）** | 免费 | **不需要** | **永久** | **自动** | 装好 TrollStore 后不用 | ❌ 系统不支持 |
| 免费 Apple ID 自签 | 免费 | 需要 | 7 天 | 需 AltServer / StikDebug 附加 | 需要 | ✅ |
| 付费开发者 $99/年 | 付费 | 需要 | 1 年 | 仍需附加 | 需要 | ✅ |
| App Store / TestFlight | — | — | — | 禁止 JIT | — | ❌ 条款 2.5.2 |

所以：

- **免费 Apple ID 能做到**：把 IPA 签好装进手机、打开界面、装版本、跑起来（如果引擎已接）。代价是每 7 天重签一次（最多同时 3 个自签 App），并且每次要电脑或用 StikDebug/SideJITServer 开 JIT。这**不是** FCL 式"装一次不用管"。
- **免费 Apple ID 做不到**：永久签名、自动 JIT、完全脱离电脑。
- **要 FCL 式且免费**：走 TrollStore，它既不要钱也不要 Apple ID，唯一门槛是**系统版本**。

## 5. 当前主线与硬约束

`build-ipa.yml` / `release-ipa.yml` 现在会在 macOS Runner 上用 `ldid` 把未签名 IPA 伪签成 **`com.yzl.launcher.tipa`**，并上传为 artifact；推 `v*` tag 时 `.tipa` 会直接挂到 GitHub Release。用户的操作只剩：

```
手机 Safari 打开 Release → 下载 .tipa → 文件 App 长按 → 分享 → TrollStore → Install
```

这和 FCL 的"下载 APK 直接装"在体验上最接近：一次安装、永久有效、自动 JIT、不用 Apple ID、不用电脑续签。JIT 也可在 App 内用
`apple-magnifier://enable-jit?bundle-id=com.yzl.launcher` 触发。

**硬约束**：TrollStore 官方支持 iOS 14.0 beta 2 – 16.6.1、16.7 RC (20H18)、17.0；16.7.x（非 RC）与 17.0.1 及以上明确「永远不会支持」，因为 CoreTrust 漏洞已修。原记录的测试机是 **iOS 18.7.8，装不了 TrollStore**。

> **2026-11-05 决策：换一台 TrollStore 兼容设备**。主线 `.tipa` 以新机器为目标；18.7.8 保留作免费 Apple ID 自签的备用测试机（`docs/SIGNING.md`）。签名方案解决不了系统版本这道墙，只能换设备。

### 5.1 设备选型：以「全程免电脑」排序

> 2026-11-05 补充要求：**最好连装 TrollStore 那一步也不用电脑**。所以首选从「最稳的 16.6.1 + TrollInstallerX」改成了「纯手机的 TrollHelperOTA」。装好 TrollStore 之后，所有路线装 `.tipa` 都免电脑。

| 优先级 | 设备 / 系统 | 装 TrollStore 的方式 | 要不要电脑 |
| --- | --- | --- | --- |
| **1（首选，全程免电脑）** | **A12+ / iOS 15.0 – 15.4.1** | **TrollHelperOTA**（手机 Safari） | **完全不用** |
| 2 | A12+ / iOS 14.0–14.8.1、15.5 beta、15.6 beta | TrollHelperOTA | 不用，但构建号要逐项核对 |
| 3 | A11 及更早 / iOS 15.0–15.4.1 | TrollHelperOTA（`troll` 链接） | 不用，但老芯片跑 MC Java 吃力 |
| 4 | iOS 16.0 – 16.6.1 | TrollInstallerX | **首次需电脑侧载一次**，之后全免 |
| ✗ | 15.5 / 15.6 正式版、16.7.x 非 RC、17.0.1+、18.x / 26 | 无永久签方案 | — |

**首选方案的手机端操作**（以 <https://ios.cfw.guide/installing-trollstore> 当前页面为准）

1. 手机 Safari 打开对应 OTA 链接：**A12+ 用 `https://api.jailbreaks.app/troll64e`**，A11 及更早用 `https://api.jailbreaks.app/troll`。必须用 Safari，不能用 Chrome/其它浏览器。
2. 允许安装描述文件 → 桌面出现 **GTA Car Tracker**（TrollHelper 的伪装名，不是游戏）→ 打开点 `Install TrollStore` → 等待自动 respring。
3. **务必执行 `Register Persistence Helper`**，选一个不常用的系统 App（如「提示 / Tips」）挂载。跳过这步，重启后 TrollStore 装的 App 可能打不开，且被占用的系统 App 之后不能删。
4. 打开 TrollStore → Settings → 安装 **ldid**、开启 **URL Scheme Enabled**。
5. 从 GitHub Release 下载 `com.yzl.launcher.tipa` → 文件 App 长按 → 分享 → TrollStore → Install；JIT 由 App 内 `apple-magnifier://enable-jit?bundle-id=com.yzl.launcher` 触发。

全程手机、无 Apple ID、无证书、无电脑、无 7 天续签 —— 这才是 FCL 的完全体。

**防坑要点**

- **拿到机器先关自动更新**（设置 → 通用 → 软件更新 → 自动更新），删掉已下载的 OTA 包。升到不支持的版本就回不来了。
- 二手机让卖家报**准确版本号 + 构建号**（设置 → 通用 → 关于本机）。**15.5 / 15.6 正式版不支持 TrollHelperOTA**（官方兼容表标 Not Supported），16.7.x 一律不要，别只听「15」或「16」这个大版本。
- 跑 MC Java 版建议 **A12+ / 4GB 内存以上**（iPhone XS/XR 及以后、iPad 8 / Air 3 及以后）。
- 网上「TrollStore 2.1 支持 iOS 17–18」「TrollStore Lite 支持新系统」多为第三方包装或依赖越狱，不是官方 CoreTrust 永久签名路线，别据此挑机器。

### 5.2 通用二进制，不按机型定制

- 部署目标 **iOS 15.0**，一个 `com.yzl.launcher.tipa` 覆盖全部 TrollStore 兼容机，**不为具体机型出包、不按设备预设参数**。
- 运行时自适应：`DeviceCapabilities.installRoute` 判断安装路线，`YZLCompat` 用 `#available` 兜底 iOS 16 API；JVM 堆由 `recommendedHeapMB`（建议值）和 `maxSafeHeapMB`（按 `os_proc_available_memory()` 取 60%、夹 1024–4096 MB 的安全上限）自动收敛。
- 用户在设置里把堆拖到 4096 MB 也会被本机安全上限夹住，启动自检会明确写出「设置 X MB / 上限 Y MB / 实际用 Z MB」，低内存老设备不会被 jetsam 杀掉。
- 换设备不需要改配置或重新出包，参数跟着机器走。
- **部署路线同样自动分流**：`Core/System/DeploymentProfile.swift` 把 iOS 15+ 分成 6 档，凡是该系统版本支持免电脑就自动走免电脑方法（TrollStore URL Scheme → StikDebug 手机端 → 最后才退回电脑附加）。完整矩阵见 [`docs/DEPLOYMENT-MATRIX.md`](DEPLOYMENT-MATRIX.md)。

## 6. 参考

- FCL 官网：<https://www.fclmc.cn/>
- FoldCraftLauncher（GPL-3.0）：<https://github.com/FCL-Team/FoldCraftLauncher>
- Amethyst-iOS（GPL-3.0）：<https://github.com/AngelAuraMC/Amethyst-iOS>
- TrollStore 兼容表：<https://ios.cfw.guide/installing-trollstore>
