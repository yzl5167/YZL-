# 构建与侧载（M0 参考流程）

> 本机是 Windows，没有 Xcode，以下内容**尚未在本机实测**。第一次真正构建时请按实际报错修正，并把结果回填到本文档。

## 0. 先选安装路线

| 方案 | 需要电脑？ | 掉签 | JIT | 适用系统 |
| --- | --- | --- | --- | --- |
| **TrollStore** | 装好后不需要 | 永久 | 自动开启 | iOS 14.0 beta 2 – 16.6.1、16.7 RC (20H18)、17.0 |
| AltStore / SideStore | 首次和续签需要 | 约 7 天 | 需要电脑附加 | iOS 14+ |
| 付费签名服务 | 安装不需要 | 证书可能被吊销 | 仍需电脑附加 JIT | 任意 |
| App Store / TestFlight | 不需要 | — | 不允许 | 不可行 |

**想要完全不用电脑签名，只能走 TrollStore。** 官方 TrollStore README 明确支持 14.0 beta 2 – 16.6.1、16.7 RC (20H18)、17.0；16.7 正式版、17.0.1 及以上“永远不会支持”（除非再出现第三个 CoreTrust 漏洞）。TrollStore 本身在部分系统需要电脑安装一次，装好之后安装 IPA 不再需要电脑、Apple ID 或证书。

App 部署目标是 **iOS 15.0**（通用版），覆盖 15.x / 16.x / 17.0 的 TrollStore 兼容机和 17.0.1+ / 18 / 26 的电脑签名机。iOS 14.x 需要替换 `AsyncImage` 等 iOS 15 API，暂未做。

## 0.1 测试机与设备决策（2026-11-05）

> **决策更新（2026-11-05）**：主线切到 **TrollStore `.tipa`**（FCL 式：永久签名、自动 JIT、免 Apple ID），并要求**全程免电脑**。因此新增一台 **A12+ / iOS 15.0 – 15.4.1** 的测试机，用 **TrollHelperOTA** 在手机 Safari 里直接装 TrollStore，连首次安装都不需要电脑。选型与操作步骤见 [`docs/FCL-PARITY.md`](FCL-PARITY.md) §5.1，通用自适应策略见 §5.2。**全系统覆盖 + 逐档自动选免电脑路线的矩阵见 [`docs/DEPLOYMENT-MATRIX.md`](DEPLOYMENT-MATRIX.md)**（17.4–18.x 走一次配对后手机自维持）。下面 iOS 18.7.8 的流程降级为该机器的**备用自签方案**，不再是主线。

### 备用机器：iOS 18.7.8

结论：**这台机器不能走 TrollStore**（官方支持范围 14.0 beta 2 – 16.6.1、16.7 RC (20H18)、17.0；16.7.x 非 RC 与 17.0.1+ 永久不支持）。因此：

- 安装与续签**必须有电脑参与**（好消息：Windows 就够，不需要 Mac）；
- JIT 也**必须电脑附加**，做不到"手机完全独立运行"；
- App 最低部署目标是 iOS 15.0，18.7.8 可以安装；固定横屏在 iPhone 上正常。

这台机器的完整流程：

1. **准备**：iPhone 打开 设置 → 隐私与安全性 → 开发者模式 → 重启；电脑装 iTunes/iCloud（AltServer 依赖 Apple 移动设备组件）。
2. **装 AltStore**：Windows 上装 AltServer（https://altstore.io），用它把 AltStore 装到手机，首次需要 Apple ID 签名。
3. **签我们的包**：托盘 AltServer → Quick Script → **Sign a File on Disk** → 选 `YZLLauncher-unsigned.ipa` → 生成签名版 → 通过 AltStore 安装。免费 Apple ID 约 7 天到期，续签要电脑在同一 Wi-Fi；改用 SideStore 可在手机上续签，但首次仍要电脑生成配对文件。
4. **开 JIT**（三选一）：
   - AltServer 菜单 → Enable JIT（要求 AltServer 与手机同网）；
   - **SideJITServer**（Windows 可跑，需要配对文件，支持 iOS 17+）：https://github.com/SideStore/SideJITServer
   - **StikDebug**：手机端常驻，但首次仍需要电脑导出的配对文件。
5. **内存限制**：`com.apple.developer.kernel.increased-memory-limit` 需要描述文件里的对应能力，免费个人开发者账号拿不到。所以 JVM 堆要保守（先按 1024–1536 MB 测），大版本/高视距更容易被 jetsam 杀掉——这是 M2 的已知风险，不是下载器的问题。

## 0.2 如果以后想彻底免电脑

只有换设备：找一台能停留在 iOS 15.0–16.6.1、16.7 RC (20H18) 或 17.0 的 iPhone/iPad（A 系列芯片均可），装 TrollStore 后：永久签名、不掉签、App 内 `apple-magnifier://enable-jit?bundle-id=com.yzl.launcher` 直接开 JIT。这是目前唯一的免电脑组合。

这正是当前主线要复刻的 **FCL 式体验**（下载即装、免维护），而且 TrollStore **完全免费、连免费 Apple ID 都不需要** —— 既不用 $99 开发者账号，也没有 7 天续签。云构建已直接产出 `.tipa`。完整对照与「免费 Apple ID 能搞吗」的答案见 [`docs/FCL-PARITY.md`](FCL-PARITY.md)。


构建环境：

- macOS 14+，Xcode 15/16（或 GitHub Actions 的 macOS runner）
- XcodeGen：`brew install xcodegen`
- Windows 本机可以写代码，但不能编译 iOS App

安装环境：

- iPhone / iPad，系统版本决定路线（见上表）
- TrollStore：不需要 Apple ID，不需要 AltServer
- 或 AltStore / SideStore + 免费 Apple ID
- JIT 工具按系统选择：TrollStore、StikDebug、Jitterbug、SideJITServer

## 1.1 本机网络实测（2026-11-05，重测于 09:40 之后）

用 `scripts/check-network.ps1` 可以随时复测（每个目标 3 次；只有 `NET_X` 才是真的不通，返回 404/403/405 说明 TLS+HTTP 通道是通的）。

| 目标 | 结果 |
| --- | --- |
| `github.com` **GET** | 200（`/status` 3/3 通；早先测到的全超时是间歇性的） |
| `github.com` **POST** | **3/3 超时**：`/login/device/code`、`/graphql`、`/login/session_cookie` 全部无响应 |
| `api.github.com` GET + POST | 都通（`/meta` 3/3 200；`/markdown` POST 200；`/graphql` POST 403=到达服务器） |
| `codeload.github.com` | 200（3/3） |
| `objects.githubusercontent.com` | 404（根路径正常表现，通道通）→ artifact 压缩包吃得到 |
| `raw.githubusercontent.com` | 3/3 超时，完全不通（发布流程不用它） |
| `login.live.com` | 200；`auth.microsoft.com` 3/3 超时（设备码走的是 Live Connect 域名，PC 侧也能通） |

结论（比原来那版更准确）：

- 拦的是 **github.com 上的写操作**，不只是"域名连不上"：`git push`（POST git-upload-pack）、`gh auth login` 设备码（POST `/login/device/code`）、在 PC 浏览器里点"Generate token"（表单 POST）**都会卡住**，而 GET 页面却是好的——所以 PC 浏览器能打开 github.com 却提交不了任何表单。
- GitHub 的 **git data API 全在 api 域**：建仓、上传 blob、建 tree/commit/ref、改默认分支、`workflow_dispatch` 触发、轮询运行状态、下载 artifact 都可以只用 `api.github.com` 完成。
- 因此发布走 `scripts/api-publish.ps1`（只用 api 域，不需要 git 通道），只需要一个 token；token 的创建页面要在**能 POST github.com 的浏览器**里做——手机用蜂窝流量最稳，别连和 PC 同一个 WiFi。

## 1.2 fine-grained token 的实测限制（2026-11-05）

- `POST /user/repos` 返回 **403 "Resource not accessible by personal access token"**：fine-grained token **不能创建仓库**，这是 GitHub 的设计限制，不是权限勾错。
- 所以建仓必须由人在网页上做一次：建一个**空仓库**，不要勾选"Add a README"（空仓库才能由 API 建第一棵 tree）。
- **仓库叫什么无所谓**，`yzl-launcher-ios` 只是示例；他实际建的时候如果 GitHub 提示名字重复，直接换一个（`yzllauncher-ios`、`YZL-Launcher-iOS`、加年份都行）。`scripts/api-publish.ps1` 不挑名字：留空 `-RepoName` 会自动列出你账号里名字带 `ios` 的仓库并选中最新的那个，也可以显式 `-RepoName 你建的名字`（在组织里就再加 `-Owner 组织名`）。
- **建议建成 Public**：GitHub Actions 的 macOS Runner 对私有仓库按 **10 倍**计费，免费计划只有 100 分钟/月额度，一次 5–20 分钟的 macOS 构建就能把额度吃光甚至直接失败；公开仓库的 macOS Runner 不占这个额度。iOS 端本来就要按 GPLv3 开源，公开没有额外损失。`api-publish.ps1` 检测到仓库是私有时会把这件事打出来提醒。
- 触发 `workflow_dispatch` 与下载 artifact 需要 **Actions: Read and write**；`Workflows: Read and write` 只负责提交 `.yml` 文件，两个都要。
- 备选是 classic token（`repo` 作用域）可以建仓，但权限明显更大，不推荐长期持有。
- 现有仓库 `yzl5167/YZLLauncher` 和 `yzl5167/YZL-Launcher-Update` 都是**公开**仓库，后者按约定只放二进制更新源；iOS 源码不往这两个仓库推。

## 2. 本地构建

```bash
cd YZL-Launcher-iOS
xcodegen generate
open YZLLauncher.xcodeproj
```

1. 选中 `YZLLauncher` target → Signing & Capabilities；
2. 勾选 Automatically manage signing，选择自己的 Team；
3. Bundle Identifier 如与别人的冲突，改成自己的（例如 `com.yourname.yzl`）；
4. 连接 iPhone，选择设备运行；
5. 首次运行需在 iPhone 设置 → 隐私与安全性 → 开发者模式 中开启并重启。

模拟器可以看 UI 和版本清单，但**不能运行 Java 版**，不要用模拟器判断启动能力。

## 3. 云构建与发布

```bash
xcodebuild \
  -project YZLLauncher.xcodeproj \
  -scheme YZLLauncher \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

bash scripts/package-unsigned-ipa.sh
```

得到 `YZLLauncher-unsigned.ipa`。

### Windows 上一键取包（推荐）

本机没有 Xcode， IPA 只能由 macOS Runner 编译出来，但产物可以自动取回 Windows：

```powershell
$env:GITHUB_TOKEN = "github_pat_..."
cd D:\YZL启动器开放\YZL-Launcher-iOS
powershell -ExecutionPolicy Bypass -File .\scripts\fetch-ipa.ps1
```

脚本触发 `build-ipa.yml`、轮询到完成、下载 artifact，最终把 `YZLLauncher-unsigned.ipa` 放到 `dist\`。构建失败会拉回云端日志并打印 `error:` 摘录。首次上传源码用 `scripts\api-publish.ps1`。token 的创建页面必须在能提交 `github.com` 表单的浏览器里打开（手机蜂窝流量最稳），细节见 1.1 / 1.2 节。

- `build-ipa.yml`：每次 push / 手动触发，上传未签名 IPA artifact；
- `release-ipa.yml`：推送 `v*` tag 时，把 IPA 挂到 GitHub Release，手机上可直接下载；
- 两个工作流都在 `YZL-Launcher-iOS/.github/workflows/`。GitHub 只识别仓库根目录的 `.github/workflows`；本目录如果单独成仓库可直接用。若放进主仓库，需要把工作流移到仓库根目录，并增加 `defaults.run.working-directory: YZL-Launcher-iOS`、修正产物路径。

## 4. 安装

### TrollStore（免电脑签名）

1. 在 GitHub Release 页面下载 `YZLLauncher-unsigned.ipa`（可以直接用 iPhone Safari 下载）；
2. 在“文件”里长按 IPA → 分享 → TrollStore；
3. TrollStore 会用自己的签名安装，永久有效，不需要 Apple ID；
4. TrollStore 安装 App 时可授予 JIT 等 entitlement；M2 的引擎会检测并调用 TrollStore 的 JIT URL Scheme。

TrollStore 还提供 URL Scheme，可在浏览器里直接装 IPA 或开 JIT（2.0.12+）：

```
apple-magnifier://install?url=<IPA 直链>
apple-magnifier://enable-jit?bundle-id=com.yzl.launcher
```

### AltStore / SideStore / Sideloadly（iOS 18.7.8 走这条）

- 电脑装 AltServer（Windows/macOS），手机装 AltStore，同一 Wi-Fi；
- 或者用 SideStore + 配对文件；
- 用免费 Apple ID 签名，通常 7 天到期，需要重新签名；免费账号同时最多 3 个自签 App；
- SideStore 配对成功后可以在手机上续签，但首次安装仍要电脑。
- **要拿到「已签名的 IPA 文件」而不是边签边装**：用 Sideloadly 的 Advanced options → Signing mode → **Export**，它会用 Apple ID 签好并存成 `.ipa`；有 `.p12` + 描述文件时可改用 `scripts/sign-ipa.ps1` 命令行自签。详见 `docs/SIGNING.md` §0.5 / §0.6。
- 本机记录的测试机是 iOS 18.7.8，TrollStore 不支持这个版本，所以上一节的免电脑路线在这台机器上不可用；JIT 还需 StikDebug / SideJITServer 附加。

### 付费签名服务

可以做到“网页一点、手机安装、不用电脑”，但证书可能被吊销，且 JIT 仍然需要电脑附加调试器；不推荐作为长期方案。

## 5. JIT

Java 版没有 JIT 基本不可玩。当前 M0 不启动 JVM，所以只看界面不需要 JIT；M2 会加入检测和明确提示。

- **TrollStore**：支持的系统上签名时授予 JIT 相关 entitlement，并可用 `apple-magnifier://enable-jit?bundle-id=...` 从 App 内触发，全程不需要电脑；
- **StikDebug / Jitterbug / SideJITServer / AltServer**：通过配对文件和调试器附加开 JIT，首次通常需要一台电脑；Amethyst 在 iOS 26 上还会用 `UniversalJIT26` 脚本配合 StikDebug；
- **Xcode 调试**：数据线连接、Xcode 附加进程，调试期间 JIT 可用。

Amethyst 官方 README 的 JIT 对照表显示：TrollStore 不需要外部设备、不需要 Wi-Fi、自动开启；StikDebug/AltStore/SideStore 首次需要外部设备。M2 会按这个差异做检测和提示。

## 6. 常见问题

| 现象 | 排查 |
| --- | --- |
| 安装后图标空白 | 确认 `Assets.xcassets/AppIcon.appiconset` 已编译进 App；删除旧 App 重装 |
| TrollStore 不支持我的系统 | 17.0.1+、16.7 正式版没有支持；只能换设备或接受电脑方案 |
| 启动即闪退 | 看 Xcode Devices and Simulators 的控制台日志；确认签名和 iOS 版本 |
| 7 天后打不开 | 免费签名过期，重新用 AltStore/SideStore 签名 |
| JIT 未启用 | TrollStore 版检查 URL Scheme；其他方案检查配对/调试器是否连接 |
| 构建报 Team 错误 | 设置自己的 DEVELOPMENT_TEAM，或在 CI 中关闭签名 |

## 7. 当前未验证项

**2026-11-05 09:20 首次云构建结论**：`xcodegen generate` 零错误生成工程；`xcodebuild` 在 `AvatarView.swift` 报 3 个编译错误（exit 65），其余文件编译通过；`DownloadQueue.swift` 另有 1 条 Swift 6 并发警告。错误与警告当天已修复，但**修复后的代码尚未复跑编译**，仓库里仍没有 IPA。

建议的验收顺序：

1. 本机先跑 `python3 scripts/preflight.py`（已接入全部 CI 任务，静态项应全部通过；含中文的 `.ps1` 会检查 UTF-8 BOM）；
2. 设置 `$env:GITHUB_TOKEN` 后跑 `powershell -ExecutionPolicy Bypass -File .\scripts\fetch-ipa.ps1` 重新触发 `build-ipa.yml` 并把 IPA 取回 `dist\`，确认 `Device IPA (unsigned)` 出包、`Unit tests (simulator)` 三个新测试文件全绿；
3. 模拟器上打开主页 / 版本 / 账号 / 设置四个页面并拉到版本列表；
4. 真机上验证 `Info.plist` 场景配置、ATS 版本清单请求、AppIcon 1024 单尺寸、TrollStore 免电脑安装与 JIT URL Scheme；
5. M2 桥接后，再在真机验证 RWX 页探测结果与实际 JVM 启动。

另：仓库若为私有，macOS Runner 按 10 倍计费，建议转成 Public（见 1.2 节）。

## 8. 参考

- TrollStore：https://github.com/opa334/TrollStore
- TrollStore 安装指南：https://ios.cfw.guide/installing-trollstore
- Amethyst-iOS：https://github.com/AngelAuraMC/Amethyst-iOS
- Amethyst wiki：https://wiki.angelauramc.dev
- AltStore：https://altstore.io
- SideStore：https://sidestore.io
- SideJITServer：https://github.com/SideStore/SideJITServer
- 已归档的 PojavLauncher iOS：https://github.com/PojavLauncherTeam/PojavLauncher_iOS
