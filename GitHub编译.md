# YZL iOS 版 · 用 GitHub 编译教程（本机零 Xcode，已实跑验证）

这台电脑没有 macOS/Xcode，iOS 端**只能**靠 GitHub 的 macOS Runner 编译。这条路线今天已经完整跑通并拿到安装包，
不是纸上方案。

## 0. 已验证的事实

| 项 | 证据 |
| --- | --- |
| 云端能编出包 | run `42026461299`（commit `1e8222e`）completed/**success**，exit 0；更早 `42007822923`（`8c6736a`）同样 success |
| 产物是真的 | `YZLLauncher-unsigned.ipa` 964,957 B（sha256 `c35e324f…4fc490b`）、`com.yzl.launcher.tipa` 1,014,723 B（sha256 `e4c43d40…efa71317`）；IPA 内 `Payload/YZLLauncher.app/YZLLauncher` 是 3,733,824 B 的 arm64 可执行文件 |
| 上传通道 | 只走 `api.github.com`（本机网络：**github.com 只放 GET、POST 被拦**，所以 `git push` 和设备码登录都不通） |
| 取包通道 | `objects.githubusercontent.com` 可达（artifact 302 落点） |
| 费用 | 公开仓库标准 macOS Runner **免费**；私有仓库按 $0.062/分钟计费（macOS 约 Linux 10 倍） |

## 1. 一条命令出包（推荐，桌面双击同一件事）

```powershell
cd D:\YZL启动器开放
$env:GITHUB_TOKEN = "你的token"
powershell -ExecutionPolicy Bypass -File .\YZL-Launcher-iOS\scripts\ephemeral-build.ps1
```

它做的事：**复用或新建 `yzl-ios-build-<时间戳>` 公开仓库 → 推本机源码 → 触发 `build-ipa.yml` → 轮询 →
下载 IPA+TIPA 到 `桌面\YZL-iOS-builds`（并写 `最新包信息.txt` 含 run id/commit/sha256）→ 把那个仓库删掉；
删不掉（token 缺 `delete_repo` 作用域）就转回私有、下次自动复用。**

为什么要临时公开：macOS 分钟数只有公开仓库免费，而源码必须待在能被 Actions 读到的仓库里才能编译。
iOS 端本来就要按 GPLv3 开源，所以这条路线没有额外泄露；源码只在编译那十几分钟可见。

桌面双击版：`YZL iOS - 临时公开仓库编译并取包.bat`（还有 `取最新的包` / `重新云构建` / `网络自检` /
`打开包目录` / `存一次token` / `同步源码到私有仓库`）。

常用参数：

```powershell
.\scripts\ephemeral-build.ps1 -KeepRepo            # 编完不删不转私有（调试）
.\scripts\ephemeral-build.ps1 -ForceNew            # 不复用，强制新建临时仓库
.\scripts\ephemeral-build.ps1 -ReuseRepo yzl-ios-build-261105-200256
.\scripts\ephemeral-build.ps1 -TimeoutMinutes 45
.\scripts\delete-repo.ps1 -Prefix yzl-ios-build    # 真删（需要 delete_repo 作用域）
.\scripts\fetch-ipa.ps1 -RepoUrl https://github.com/yzl5167/YZL- -NoTrigger -OutputDir .\build-output
```

## 2. 只想要"最近一次成功构建"的包（不花时间编译）

```powershell
powershell -ExecutionPolicy Bypass -File .\YZL-Launcher-iOS\scripts\fetch-ipa.ps1 `
  -RepoUrl https://github.com/yzl5167/YZL- -NoTrigger -OutputDir .\YZL-Launcher-iOS\build-output
```

## 3. 云端编译做了什么（`.github/workflows/build-ipa.yml`）

两条**互相独立**的 job，测试挂了也照样出包：

1. `Device IPA (unsigned)`（`macos-latest`）：`brew install xcodegen` → `xcodegen generate` → `xcodebuild -sdk iphoneos -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO` → `scripts/package-unsigned-ipa.sh` 打 Payload → artifact `YZLLauncher-unsigned-ipa` → `scripts/build-tipa.sh` 出 TrollStore 包 → artifact `YZLLauncher-trollstore-tipa` → 无论成败上传 `build-device.log`；
2. `Unit tests (simulator)`：`xcrun simctl list -j | jq` 自动挑一台可用 iPhone 模拟器，`xcodebuild test`，`continue-on-error`，日志存 artifact。

工程由 XcodeGen 从 `project.yml` 生成（**不提交 .xcodeproj**）：`deploymentTarget iOS 15.0`、
`TARGETED_DEVICE_FAMILY=1`、bundle id `com.yzl.launcher`、固定横屏 + `UIRequiresFullScreen`。

## 4. 拿到包之后怎么装（测试机 iPhone iOS 18.7.8）

- `.tipa`（TrollStore）**装不了**：TrollStore 只覆盖 14.0b2–16.6.1 / 16.7 RC(20H18) / 17.0。
- 走 `YZLLauncher-unsigned.ipa` + Windows 上的 Sideloadly（Export 模式，免费 Apple ID 签名并导出已签 IPA）
  或 AltServer：7 天到期、同时最多 3 个自签 App；JIT 需要 SideJITServer/StikDebug 由电脑提供。
  详细步骤见 `docs/SIGNING.md` §0.5/§0.6 与 `docs/FCL-PARITY.md`。
- 全程 0 元：Actions 公开仓库免费、Sideloadly/AltServer 免费开源、不需要 99 美元开发者账号、不需要 Mac。

## 5. 仓库与令牌

- 源码主仓库：私有 `yzl5167/YZL-`（HEAD `8c6736a`；本地与它同源，工作目录被多个会话共用，**动文件前先重读**）。
  另有私有旧快照 `yzl-launcher-ios`（今早 09:20 的第一版，两次构建都失败）——脚本里"名字带 ios 就选中"的
  自动发现会挑到它，所以**调用一律显式 `-RepoUrl …/YZL-`**，桌面脚本已写死。
- 令牌：classic `ghp_…`，作用域 `repo, workflow`；**建议再补 `delete_repo`**（否则临时仓库删不掉，只能转私有复用）。
  账号未开 2FA；开 2FA 不会作废已颁发的 token，只在新建 token 时要验证码。
- 全部 5 个仓库现在都是私有，匿名访问 404（已复核）。

## 6. 已知坑（别再踩）

1. `POST /git/blobs` 偶发 404 —— 脚本已带 4 次退避重试；
2. 脚本中途崩会让临时仓库**一直公开** —— 已在顶部加 `trap` 兜底转私有；
3. PS 5.1 里 `@(Invoke-RestMethod …)` 会把整个 JSON 数组当成一个元素，导致"名字带 ios"筛错仓库 —— 一律先赋值再走管道，并加了"只允许 `yzl-ios-build-*` 被转公开"的双保险；
4. 后台跑脚本不要把 stdout 丢掉（`> /dev/null` 曾让我们看不到失败原因）；
5. 复测网络：`powershell -File .\YZL-Launcher-iOS\scripts\check-network.ps1`（只有 `NET_X` 才是真不通，404/403 说明通道是通的）。
