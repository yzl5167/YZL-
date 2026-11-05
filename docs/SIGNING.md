# 自签与安装（SIGNING）

> ⚠️ **当前主线不是本文档**。项目已切到 **TrollStore `.tipa`**（FCL 式：装一次一直用、免 Apple ID、永久签名、自动 JIT），云构建直接出包，见 [`docs/FCL-PARITY.md`](FCL-PARITY.md)。
> 下面两条自签路线只保留给 **iOS 17.0.1+ / 18.x 等装不了 TrollStore** 的设备，当前不启用。

> 先说结论：**自签的输入是「未签名 IPA」，输出才是「已签名 IPA」。** 云构建给的 `YZLLauncher-unsigned.ipa` 只是中间产物，普通 iPhone 装不上；必须用自己的 Apple ID 或证书签一遍。
>
> 在 Windows 上做这件事有两条路，取决于你手上有什么：
> - **只有免费 Apple ID**（最常见）→ Sideloadly 的 **Export 模式**直接用 Apple ID 签名并导出 `.ipa` 文件，见 §0.5；
> - **有 `.p12` + `.mobileprovision`**（付费开发者账号 / 企业证书）→ `scripts/sign-ipa.ps1` + zsign 命令行自签，可脚本化、可进 CI，见 §0.6。
>
> 本工程在 Windows 上开发，目前还没有编译产物，所以先按下一节拿到未签名 IPA。

## 0. 先拿到未签名 IPA

方式 A：本机 macOS

```bash
brew install xcodegen
cd YZL-Launcher-iOS
xcodegen generate
xcodebuild \
  -project YZLLauncher.xcodeproj \
  -scheme YZLLauncher \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build
bash scripts/package-unsigned-ipa.sh
```

方式 B：GitHub Actions（只有 Windows 时推荐）

先用手机蜂窝流量的浏览器创建 fine-grained token（本机 `github.com` 的表单 POST 被网络拦，但 `api.github.com` 通），设成环境变量后一条命令拿包：

```powershell
$env:GITHUB_TOKEN = "github_pat_..."
cd D:\YZL启动器开放\YZL-Launcher-iOS
powershell -ExecutionPolicy Bypass -File .\scripts\fetch-ipa.ps1
```

`fetch-ipa.ps1` 会触发 `build-ipa.yml` → 轮询到结束 → 下载 artifact → 把 IPA 放到 `dist\YZLLauncher-unsigned.ipa`；构建失败时自动抓回云端日志并打印 `error:` 摘录。加 `-NoTrigger` 取最近一次构建、`-RunId <id>` 取指定 run、`-RepoUrl` 指定私有仓库。

**首次**需要把源码传上仓库：`powershell -ExecutionPolicy Bypass -File .\scripts\api-publish.ps1`（它会顺带完成一次构建与下载；fine-grained token 不能建仓，需先在网页手动建一个空仓库）。也可以推 `v*` tag 触发 `release-ipa.yml`，把 IPA 挂到 GitHub Release，手机 Safari 直接下载。

## 0.5 Windows 自签并导出已签名 IPA（免费 Apple ID，推荐）

Sideloadly 的 **Export** 模式会用你的 Apple ID 向 Apple 申请开发证书，把 IPA 签好并**保存成文件**，而不是直接装到手机 —— 这就是「自签 IPA」。

1. 装 [Sideloadly](https://sideloadly.io) Windows 版；Windows 上必须装**非 Microsoft Store 版**的 iTunes 与 iCloud（商店版沙箱会破坏设备通信）。
2. 把 `dist\YZLLauncher-unsigned.ipa` 拖进窗口，填自己的 Apple ID。
3. 点 **Advanced options**：
   - **Signing mode → Export**（不是默认的 Apple ID Sideload，那个是边签边装、不产出文件）；
   - 建议勾 **Use automatic bundle ID** 避免 App ID 冲突；免费账号每周最多注册 10 个 App ID。
4. **Start** → 输入 Apple ID 密码（双重认证会弹验证码）→ 选保存路径 → 得到已签名 `.ipa`。
5. 这个签名 IPA 之后可用 Sideloadly / AltServer / Apple Configurator 装到设备，或留作分发。

**限制**：免费账号签名 7 天有效、同时最多 3 个自签 App；到期重签一次即可（Sideloadly 的自动刷新守护进程可代劳）。付费开发者账号（$99/年）把 7 天变成 1 年并解除 3 个 App 上限。

> 为什么不让脚本用免费 ID 签？免费账号的证书由 Sideloadly / AltServer 通过 anisette 向 Apple 动态申请，不落地成 `.p12`，命令行工具拿不到。想全自动就得有付费账号导出的证书，走 §0.6。

## 0.6 有证书：命令行自签（可进 CI）

需要 `.p12`（含私钥的 Apple Development 证书）和 `.mobileprovision`（**包含目标设备 UDID** 的 development / ad-hoc 描述文件）。

```powershell
$env:P12_PASSWORD = "p12 导出时设的密码"
cd D:\YZL启动器开放\YZL-Launcher-iOS
powershell -ExecutionPolicy Bypass -File .\scripts\sign-ipa.ps1 `
  -P12 certs\dev.p12 `
  -MobileProvision certs\dev.mobileprovision `
  -TeamId ABCDE12345 `
  -Ipa dist\YZLLauncher-unsigned.ipa `
  -Output dist\YZLLauncher-signed.ipa
```

脚本做四件事：把 `packaging/entitlements.free.plist` 的 `TEAMID` 占位替换成真实 Team ID → 调 `zsign` 重签（`-k/-m/-e/-b/-o`）→ `zsign -C` 校验 → 输出 `dist\YZLLauncher-signed.ipa`。

`zsign` 是 MIT 协议的跨平台 codesign 实现，Windows 原生可跑、不需要 Xcode：从 <https://github.com/zhlynn/zsign> 用 VS2022 编译 `build/windows/vs2022/zsign.sln`，或取第三方预编译包，放进 PATH 或用 `-Zsign` 指定路径。

**entitlement 必须和描述文件匹配**，否则签名能过、安装被拒。`entitlements.free.plist` 只保留 `get-task-allow` 与三项标识；`entitlements.sideload.plist` 里那两项内存能力（`increased-memory-limit` / `extended-virtual-addressing`）免费账号的 profile 不含，用在这里会出事。只有付费账号且描述文件确实带这两项能力时，才用 `-Entitlements packaging\entitlements.sideload.plist`。

> CI 直出签名包：把 p12 与 mobileprovision 做 base64 存进仓库 Secrets，在 `build-ipa.yml` 的 macOS job 末尾加一步导入 keychain + `codesign`（或直接跑 zsign），即可让 artifact 同时包含未签名与已签名两个包。本仓库目前没有这些 Secrets，默认产出仍是未签名 IPA。

## 1. 自签路线对照

| 路线 | 需要电脑 | 有效期 | 产出文件 | 用的东西 |
| --- | --- | --- | --- | --- |
| **Sideloadly Export（Windows，推荐）** | 首次需要 | 约 7 天 | **已签名 .ipa 文件** | 免费 Apple ID，见 §0.5 |
| **zsign 命令行（Windows）** | 不需要设备 | 视证书 | **已签名 .ipa 文件** | `.p12` + `.mobileprovision` + `scripts/sign-ipa.ps1`，见 §0.6 |
| AltStore / SideStore 直接安装 | 需要 | 约 7 天 | 不产出文件（边签边装） | 把未签名 IPA 丢给 AltServer |
| TrollStore + ldid | 装好后不需要 | 永久 | `.tipa` | `packaging/entitlements.trollstore.plist` + `scripts/sign-ipa.sh … trollstore` |
| macOS codesign | 需要 Mac | 视证书 | 已签名 `.ipa` | `packaging/entitlements.sideload.plist` + `scripts/sign-ipa.sh … sideload` |

> 测试机记录为 iOS 18.7.8，**不在 TrollStore 支持范围**（14.0 beta 2 – 16.6.1 / 16.7 RC / 17.0），所以这台机器只能走前两行或 AltStore；JIT 仍需 StikDebug / SideJITServer 附加，签名本身不解决 JIT。

## 2. TrollStore（最省事，免电脑）

1. 设备系统必须在 TrollStore 支持范围：iOS 14.0 beta 2 – 16.6.1、16.7 RC (20H18)、17.0。
2. 生成 `.tipa`：

   ```bash
   bash scripts/sign-ipa.sh build/YZLLauncher-unsigned.ipa trollstore
   ```

3. 传到 iPhone（AirDrop / 文件 App / Safari 下载），长按 → 共享 → TrollStore → Install。
4. 安装后不需要 Apple ID、不会 7 天掉签；JIT 可用 URL Scheme 从 App 内触发：

   ```
   apple-magnifier://enable-jit?bundle-id=com.yzl.launcher
   ```

也可以不预先 ldid，直接把未签名 IPA 交给 TrollStore 安装（它会用自己的伪根证书签），但要拿到 `increased-memory-limit`、`no-sandbox` 这类权限，就必须按上面那样先把 entitlement 打进二进制。

## 3. AltStore / SideStore（Windows 也能签）

1. Windows 装 AltServer，手机装 AltStore，同一 Wi-Fi。
2. 未签名 IPA 右键 → **AltServer → Send to My Device / Sign App**，用你的 Apple ID 签。
3. 免费 Apple ID 通常 7 天有效、同时最多 3 个自签 App；付费开发者账号可延长。
4. JIT 需要电脑附加：AltServer 菜单 Enable JIT、或 SideJITServer / StikDebug。

## 4. OTA 安装页（可选）

```bash
bash scripts/make-ota-manifest.sh dist/com.yzl.launcher-signed.ipa https://你的域名/yzl/
```

生成 `manifest.plist`，网页里放：

```
itms-services://?action=download-manifest&url=https://你的域名/yzl/manifest.plist
```

要求：IPA、manifest、页面全部 HTTPS 且证书有效；`manifest.plist` 里的 `bundle-identifier` 必须和 IPA 一致（脚本会自动读取）。

## 5. 三个 entitlement 文件的用途

- `packaging/entitlements.free.plist`：**免费 Apple ID 自签用**，只有 `get-task-allow` + 三项标识，`TEAMID` 占位由 `scripts/sign-ipa.ps1` 替换；刻意不含内存上限能力。
- `packaging/entitlements.sideload.plist`：付费账号的常规开发/侧载签名，`get-task-allow` 为主，内存上限两项需要描述文件确实带对应能力。
- `packaging/entitlements.trollstore.plist`：TrollStore 伪签用，含 `no-sandbox`、`platform-application`、`memorystatus`、IOKit 与 mach 白名单，参考 Amethyst 的做法。
- `packaging/manifest.template.plist`：OTA 清单模板，`__IPA_URL__` 等占位由脚本替换。

**不能写的 entitlement**：iOS 15 及以后的 A12+ 设备上，`dynamic-codesigning`、`com.apple.private.cs.debugger`、`com.apple.private.skip-library-validation` 会导致启动即崩，TrollStore 也拿不到，必须靠 no-sandbox + 自行附加调试器的方式开 JIT。

## 6. 常见错误

| 现象 | 原因与处理 |
| --- | --- |
| 安装报 `This app has not been updated` / 签名无效 | IPA 未重签名，或证书过期；重新用 AltServer / ldid 签 |
| 装完打不开、秒退 | entitlement 与签名不匹配（例如 sideload 却写了 no-sandbox）；换回对应文件 |
| 提示需要描述文件 | `increased-memory-limit` 等能力必须有对应 profile，没有就去掉这两项 |
| bundle id 冲突 | 改成自己的 `PRODUCT_BUNDLE_IDENTIFIER`，同步改 entitlement 里的 application-identifier 与 manifest |
| 7 天后图标变灰 | 免费签名到期，重新签名即可，数据不会丢 |

## 7. 本仓库当前验证到哪一步

- 四个 `*.plist` 通过 XML 解析检查；4 个 `*.sh` 通过 `bash -n`；5 个 `*.ps1` 通过 PowerShell 5.1 语法解析并确认 UTF-8 BOM；`scripts/preflight.py` 全绿。
- **没有在 macOS 上实跑过**：`ldid`、`codesign`、`PlistBuddy` 的行为、以及 Xcode 产物结构都还没验证。
- **Windows 自签脚本也没实跑过**：`scripts/sign-ipa.ps1` 只做了语法与参数校验，需要真实 `.p12` + `.mobileprovision` + zsign 才能端到端验证；Sideloadly Export 流程同理，需要一次真机操作。
- **没有 IPA**：缺 macOS 编译环境（本机只有 Windows），且本机没有 GitHub 凭据，云构建尚未复跑。
