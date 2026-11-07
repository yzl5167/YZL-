# 覆盖矩阵与自动分流

> 目标：**一个通用二进制覆盖尽量多的系统版本，凡是该系统版本支持免电脑，就自动走免电脑方法**。
> 2026-11-05 定稿。实现见 `Core/System/DeploymentProfile.swift`，设置页「诊断」会显示本机档位。

## 1. 先把矛盾说清楚

「大部分系统都能用」和「完全免电脑」在 iOS 上**不能同时 100% 满足**，这不是启动器实现问题：

- **TrollStore 永久签名**依赖 CoreTrust 漏洞，Apple 从 iOS 16.7 正式版 / 17.0.1 起已修复，新系统永远不可能用。
- **JIT** 只在调试器附加时才被允许。iOS 17.4+ 可以用 StikDebug 在手机端扮演调试器，但**首次必须有一台电脑生成配对文件**（建立设备与"可信电脑"的信任关系）。
- **免费 Apple ID 签名** 7 天到期；SideStore 能在手机上续签，但装 SideStore / 生成配对文件仍需电脑一次。

所以能做到的最优解是：**覆盖全部 iOS 15+，且每台设备自动选「最省电脑」的那条路** —— 能全程零电脑就零电脑，做不到就一次电脑，实在不行才需要电脑持续参与。

## 2. 自动分流矩阵

`DeploymentProfile` 在运行时按系统版本/构建号判定，App 的 JIT 按钮、建议安装包、电脑依赖提示都跟着它走，**用户不用查表**。

| 档位 | 系统版本 | 签名 / 有效期 | 电脑依赖 | JIT 方式 | 发哪个包 |
| --- | --- | --- | --- | --- | --- |
| `permanentNoComputer` | **iOS 14.0 – 15.4.1**（A12+ 可到 15.6 beta） | TrollStore 永久 | **全程零电脑** | TrollStore 自动 + App 内 URL Scheme | `com.yzl.launcher.tipa` |
| `oneTimeComputerThenPermanent` | 15.5 / 15.6 正式版、16.0 – 16.6.1、16.7 RC (20H18)、17.0 | TrollStore 永久 | **首次一次**：电脑侧载 TrollInstallerX / TrollRestore | 同上，之后永久免维护 | `com.yzl.launcher.tipa` |
| `oneTimePairing` | **17.4 – 18.x** | 免费 ID 7 天（SideStore 手机续签） | **首次一次**：电脑生成配对文件 | 之后手机端 StikDebug + LocalDevVPN | 未签名 IPA 自签 |
| `appJITAdaptation` | **iOS 26+** | 同上 | 首次一次 | StikDebug 有限支持，App 需适配新 JIT 方式（M2 待做） | 未签名 IPA 自签 |
| `computerAttached` | 16.7.x 非 RC、17.0.1 – 17.3.x | 免费 ID 7 天 | **持续需要电脑** | AltServer / SideJITServer 附加 | 未签名 IPA 自签 |
| `unsupportedOld` | < iOS 15.0 | — | — | 本 App 部署目标为 15.0 | 不支持 |

> 覆盖结论：**iOS 15.0 及以上全部可装**；其中约一半档位在首次一次电脑后即可长期免电脑，只有 16.7.x / 17.0.1–17.3.x 这段需要电脑持续参与。

## 3. 「能用免电脑就用」怎么落地的

- `DeviceCapabilities.deploymentProfile` 在运行时判定档位（复用 `installRoute`，额外按 15.5 / 16 / 17.4 / 26 细分），`project.yml` 已声明 `LSApplicationQueriesSchemes: apple-magnifier`。
- `AppState.jitActionTitle` / `AppState.enableJIT()` **按档位选方法**：
  - TrollStore 两档 → 直接 `apple-magnifier://enable-jit?bundle-id=...`，全免电脑；
  - 17.4+ 两档 → 引导手机端 StikDebug + LocalDevVPN（配对一次，之后免电脑）；
  - 只有 `computerAttached` 才提示 AltServer / SideJITServer。
- `SettingsView` 的「诊断」新增三行：部署档位、电脑依赖、建议安装包，用户打开就能看到本机该走哪条。
- 云构建同时产出 `.tipa` 与未签名 IPA，Release 两个都挂 —— 老系统拿 `.tipa`，新系统拿 IPA 自签，**同一个二进制，不按机型出包**。
- 堆内存同样运行时自适应（`maxSafeHeapMB`，见 `FCL-PARITY.md` §5.2）。

## 4. 各档操作要点

**A. 全程零电脑（14.0 – 15.4.1）**
手机 Safari → TrollHelperOTA（A12+ 用 `https://api.jailbreaks.app/troll64e`，A11- 用 `/troll`）→ GTA Car Tracker → Install TrollStore → **Register Persistence Helper** → TrollStore Settings 装 ldid、开 URL Scheme → Release 下载 `.tipa` → 分享给 TrollStore。见 `FCL-PARITY.md` §5.1。

**B. 一次电脑后永久免维护（16.x / 17.0）**
电脑用 Sideloadly / AltServer 侧载一次 TrollInstallerX（16.x）或 TrollRestore（16.7 RC / 17.0）→ 装好 TrollStore → 之后同 A 的 `.tipa` 流程，永久签名、自动 JIT、不再需要电脑或 Apple ID。

**C. 一次配对后手机自维持（17.4 – 18.x）**
1. 电脑：iloader / JitterbugPair 生成配对文件，装 SideStore（一次性）。
2. 手机：装 LocalDevVPN（回环 VPN，不走远程服务器）+ StikDebug。
3. 日常：SideStore 手机上续签；每次启动游戏前连上 VPN → StikDebug 选中 YZL Launcher → Enable JIT。**JIT 不会跨 App 重启保留，每次都要点一次**。
4. 免费 ID 7 天到期由 SideStore 自动刷新；付费账号可延长到 1 年。

**D. 电脑持续参与（16.7.x 非 RC / 17.0.1 – 17.3.x）**
StikDebug 不支持这段，用 AltServer → Enable JIT 或 SideJITServer，续签同样要电脑。这是覆盖矩阵里唯一无法省掉电脑的档位，建议尽量别选这个版本区间的测试机。

**E. iOS 26+**
StikDebug 支持有限，且要求 App 显式适配新 JIT 接口。列进 M2-b 待办，接入 Amethyst 引擎时一并处理。

## 5. 建议

- 要**完全零电脑** → 只能买 A12+ / iOS 15.0–15.4.1 的机器（覆盖范围窄，但体验最好）。
- 要**覆盖广 + 尽量省电脑** → 主力机用 17.4–18.x 走 C 档（一次电脑），再备一台 15.4.1 的机器走 A 档做 TrollStore 验收。
- **别买** 16.7.x 非 RC、17.0.1–17.3.x，这两段是唯一必须电脑持续参与的区间。

> 一句话：**不是所有系统都能免电脑，但每个系统都会自动用它能用的最免电脑的那条路。**
