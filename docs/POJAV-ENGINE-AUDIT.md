# Pojav / Amethyst 引擎接缝审计

日期：2026-11-04
审计对象：`PojavLauncherTeam/PojavLauncher_iOS`（归档）与 `AngelAuraMC/Amethyst-iOS`（活跃）
结论范围：能否在 YZL 自制 SwiftUI 外壳里复用其 JRE / Java 启动层。

## 结论

1. **PojavLauncher_iOS 已在 2025-09-23 归档**（GitHub API：`archived: true`，GPL-3.0，Objective-C，仓库约 229 MB）。不要把归档仓库直接当新项目底座。
2. **Amethyst-iOS 是活跃继任者**：2026-10-17 仍有提交，iOS 14+，GPL-3.0，README 明确支持 Forge/Fabric/OptiFine/Quilt、微软账户、TrollStore/JIT。
3. **它的引擎不是可 `dlopen` 的独立 framework**。入口是 `launchJVM(...)`，但依赖同工程里的 ObjC 源码、偏好/档案模型、UI 弹窗、日志视图、`AME_HOME` 目录、JavaApp 打出的 jar 和预编译图形 dylib。而且整个项目用 `Makefile` + CMake 构建，`Amethyst.xcodeproj` 只是一个调 `make` 的外壳。最现实的落地方式是 **以 Amethyst 为底座，替换它的 UIKit 界面为 YZL SwiftUI 外壳**，而不是从我们的空工程反向拼引擎。

## 1. 上游状态

| 项 | PojavLauncher_iOS | Amethyst-iOS |
| --- | --- | --- |
| 仓库状态 | 归档 | 活跃 |
| 最后提交 | 2025-09-23 | 2026-10-17 |
| License | GPL-3.0 | GPL-3.0 |
| 主要语言 | Objective-C | Objective-C |
| 支持系统 | 已停更，README 写 iOS 17 不支持 | iOS 14+，README 写 17.x/18.x 需要电脑开 JIT |
| 推荐 | 只作历史参考 | 作为引擎底座 |

## 2. 引擎入口与耦合

入口声明：

- `Natives/JavaLauncher.h:20`：`int launchJVM(NSString *username, id launchTarget, int width, int height, int minVersion);`
- `Natives/JavaLauncher.h:6-18`：定义 `JLI_Launch_func`，即 JVM 的 `JLI_Launch` 函数签名。

`Natives/JavaLauncher.m` 里能看到完整启动链：

- `:102` 入口实现；`:105-106` 初始化 GL4ES/Mesa 等环境变量；
- `:108-149` 读取 JIT flags、处理 StikDebug / LiveContainer 的 `UniversalJIT26` 脚本、dyld library validation 绕过；
- `:157-187` 按 Java 8 / Java 17 选择 JRE；`:187` 调 `getSelectedJavaHome`，缺少 JRE 时会弹窗并 `UIKit_returnToSplitView()`；
- `:210-226` 计算内存，检查 `com.apple.developer.kernel.increased-memory-limit` entitlement，失败时提示 "GetMoreRam"；
- `:234-274` 拼 JVM 参数：`-XstartOnFirstThread`、`-Djava.library.path=.../Frameworks`、`-Duser.home=$AME_HOME`、LWJGL/GLFW 参数、iOS 26 的 `-XX:+MirrorMappedCodeCache`；
- `:294-342` Caciocavallo / AWT 参数和 bootclasspath；
- `:361-367` classpath 指向 App 内 `libs/*`，主类固定为 `net.kdt.pojavlaunch.PojavLauncher`；
- `:382-411` `dlsym(libjli, "JLI_Launch")` 后直接调用，启动 JVM。

耦合点不是算法，而是**运行环境约定**：

1. 依赖 `AME_HOME`、`instances`、`libs`、`libs_caciocavallo(17)`、`Frameworks`、JRE 目录布局；
2. 直接调用 `UIKit_returnToSplitView()`、`showDialog()`、`PLLogOutputView`，默认宿主是 Amethyst 的 UIKit 导航结构；
3. 依赖 `PLProfiles`、`LauncherPreferences`、`MinecraftOptionUtils` 等偏好/档案代码；
4. 依赖 App bundle 内预编译的 LWJGL/GL4ES/Mesa/MetalANGLE/OpenAL 等 dylib；
5. 依赖 JavaApp 打出的 jar 和 Caciocavallo jar。

所以 `launchJVM` 是清晰的**函数级接缝**，但不是“链接一个 engine.framework 就能用”的接缝。

## 3. 渲染与输入层

`Natives/SurfaceViewController.h:14-30` 显示游戏宿主是一个 `UIViewController`，持有：

- `GameSurfaceView`：游戏画面；
- `ControlLayout`：自定义触控布局；
- `touchView`、`mousePointerView`、滚动手势；
- `+ (GameSurfaceView *)surface`、`+ (BOOL)isRunning` 等静态入口。

`Natives/` 下还有 `input/ControllerInput`、`KeyboardInput`、`GyroInput`、`customcontrols/*`、`ctxbridges/*` 和预编译的 `Natives/resources/Frameworks/liblwjgl*.dylib`、`libgl4es_114.dylib`、`libOSMesa.8.dylib`、`libMoltenVK.dylib`、`libopenal.dylib`、`libEGL.framework`、`libGLESv2.framework`。

对 YZL 的含义：SwiftUI 外壳可以用 `UIViewControllerRepresentable` 挂载 `SurfaceViewController`，但它的菜单、日志、触控布局和游戏内返回逻辑仍需要保留或替换。

## 4. Java 侧与安装器

- `JavaApp/src/launcher/net/kdt/pojavlaunch/PojavLauncher.java` 是 JVM 主类；
- `JavaApp/src/launcher/net/kdt/pojavlaunch/JVersion.java`、`JAssets.java` 等负责版本/资源信息；
- `JavaApp/libs/lwjgl/*.jar`、`caciocavallo*/*.jar`、`patchjna_agent` 是运行时依赖；
- `JavaApp/Makefile` 负责把 Java 源码打成 jar；
- `Natives/MinecraftResourceDownloadTask.m`、`Natives/installer/*` 已有下载与 Forge/Fabric/整合包安装逻辑；
- `Natives/authenticator/MicrosoftAuthenticator.m` 已有微软登录实现。

这意味着 M1 不应从零重写所有下载/登录逻辑；更合理的是先复用 Amethyst 的安装器和认证，再把 YZL 的分片续传加速器替换进下载层。具体接口需要读实现后确认。

## 5. JIT 与“免电脑”

官方 TrollStore README 给出的支持范围是：**iOS 14.0 beta 2 – 16.6.1、16.7 RC (20H18)、17.0**；16.7 正式版和 17.0.1+ 不再支持。TrollStore 2.0.12+ 提供 URL Scheme：

```
apple-magnifier://enable-jit?bundle-id=<Bundle_ID>
```

所以在 TrollStore 兼容设备上，签名、安装、JIT 都可以不用电脑。Amethyst 的 README 也把 TrollStore 列为唯一“不需要外部设备 / 不需要 Wi-Fi / 自动开启 JIT”的方案。

非 TrollStore 系统：

- `StikDebug`、`Jitterbug`、AltStore、SideStore 的 JIT 需要调试器附加；Amethyst README 的对照表标注首次需要外部设备（电脑）。
- `Natives/resources/UniversalJIT26.js`（`:1` 标注 2025-10-10）通过 `vAttach` 连接调试器（`:53`），配合 StikDebug 在 iOS 26 上工作；它是调试脚本，不是免电脑的签名工具。
- App Store / TestFlight 仍受 2.5.2 与 JIT 限制，不可行。

## 6. License

- 仓库整体：**GPL-3.0**。
- README 列出的第三方组件：Boardwalk（Apache-2.0）、Caciocavallo（GPLv2）、Azul Zulu JDK（GPLv2 + Classpath Exception）、GL4ES（MIT）、Mesa（MIT）、MetalANGLE（BSD-2）、MoltenVK（Apache-2.0）、openal-soft（LGPLv2）、LWJGL3（BSD-3）、shaderc（Apache-2.0）等。

一旦把 Amethyst 的引擎代码/资源打进 YZL iOS 包并分发，**iOS 端按 GPLv3 开源**是既定路线（用户 2026-11-04 已确认）。M0 外壳本身不含上游代码。

## 7. 三种落地方式

| 方式 | 工作量 | 风险 | 结论 |
| --- | --- | --- | --- |
| **Fork Amethyst，替换 UIKit UI 为 YZL SwiftUI** | 中 | 需要理解它的导航/菜单/设置耦合；GPLv3 | **推荐** |
| 把引擎抽成 framework，接进当前 M0 工程 | 大 | 要复制资源、偏好、档案、JRE 管理、日志/弹窗，易漏；GPLv3 | 可行但不划算 |
| 从零自研 JVM/渲染 | 极大 | 基本不现实 | 不选 |

推荐路径的具体做法：

1. 以 Amethyst 的 `main` 为底，保留 `Natives/JavaLauncher`、`SurfaceViewController`、`GameSurfaceView`、`ctxbridges`、`input`、`installer`、`authenticator` 和 `JavaApp`；
2. 把 `LauncherSplitViewController` / `SceneDelegate` 的入口换成 SwiftUI `WindowGroup`，用 `UIViewControllerRepresentable` 挂 `SurfaceViewController`；
3. 把本仓库 M0 的四页 UI、主题、版本模型迁移进去，作为新的设置/版本/账户/主页层；
4. 在启动前调用 TrollStore JIT URL Scheme，并检测 entitlement/JIT 状态；
5. 用 YZL 的分片下载器替换/增强 `MinecraftResourceDownloadTask` 的下载层；
6. 先跑通 Amethyst 原版引擎 + 最小 SwiftUI 壳，再逐页替换 UI，避免一次性改太多。

## 8. 构建系统实况（已核对本地源码副本）

参考副本在 `.ref-amethyst-src/Amethyst-iOS-main`（main 分支，2026-11-04 下载）。

- `Amethyst.xcodeproj/project.pbxproj:47` 只有一个 `PBXLegacyTarget`，即 Xcode 里挂的外部构建脚本；真正的构建入口是根目录 `Makefile` + `Natives/CMakeLists.txt`，**不是 `xcodebuild`**。
- `Makefile:259-279` `native`：cmake 交叉编译 arm64，`CMAKE_OSX_DEPLOYMENT_TARGET=14.0`，产出主程序和 `libawt_xawt.dylib` 等。
- `Makefile:281-284` `java`：调用 `JavaApp/Makefile`，要求 JDK 8 的 `javac`。
- `Makefile:286-306` `jre`：从 `assets.angelauramc.dev/openjdk/ios-arm64/jre{8,17,21,25}-ios-aarch64.zip` 下载并裁剪，随包放进 `java_runtimes/`。
- `Makefile:342-372` `payload`：组装 `.app`（`Frameworks/*.dylib`、`libs`、`libs_caciocavallo(17)`、jar），再用 `ldid` 分别套 `entitlements.trollstore.xml` / `entitlements.sideload.xml` / `entitlements.codesign.xml`。
- `Makefile:401-413` `package`：`TROLLSTORE_JIT_ENT=1` 时输出 `.tipa`，否则 `.ipa`；`SLIMMED=1` 时排除 `java_runtimes`，运行时再下 JRE。
- 依赖：cmake、JDK 8、ldid、curl、nproc/gnproc、iPhoneOS SDK；`.gitmodules` 有 4 个子模块（DBNumberedSlider、fishhook、AFNetworking、MobileGlues）。
- 官方 CI（`.github/workflows/development.yml:22,82-120`）跑在自托管 runner `J316sAP` 上，同一份代码执行两遍 `gmake dsym package`，第二遍带 `TROLLSTORE_JIT_ENT=1`，同时产出 `.ipa` 和 `.tipa`。
- `entitlements.trollstore.xml:6-46` 含 `get-task-allow`、`increased-memory-limit`、`extended-virtual-addressing`、`com.apple.private.memorystatus`、`com.apple.private.security.no-sandbox`、`platform-application` 及 IOKit/mach 例外，注释写明 "Disable sandbox so that Amethyst can enable JIT by itself"。这就是"免电脑开 JIT"的实现位置。
- Amethyst 自带下载器 `Natives/MinecraftResourceDownloadTask.h:6-15` 是逐文件 `NSURLSessionDownloadTask` + `NSProgress`，没有 Range 分片；YZL 的分片续传下载器正是替换这里。

## 9. 对当前工程的直接影响

1. **CI 要分两条**：M0 外壳继续用 `xcodegen + xcodebuild`；接 Amethyst 后必须改成 `make`（cmake + JDK 8 + ldid + 子模块）。GitHub 托管 runner 需要 `brew install cmake ldid coreutils` 和一个 JDK 8。
2. **产物要出两种**：`.ipa`（AltStore/SideStore）与 `.tipa`（TrollStore：免电脑、永久签名、自动 JIT）。
3. **UI 替换范围明确**：保留 `Natives/JavaLauncher.m`、`SurfaceViewController`、`GameSurfaceView`、`ctxbridges`、`input`、`installer`、`authenticator` 和整个 `JavaApp`；替换 `AppDelegate` / `SceneDelegate` / `LauncherSplitViewController` / 各 `Launcher*ViewController` 为 SwiftUI 根控制器，把 M0 的四页迁进去。
4. **下载层替换点明确**：用 `SegmentedDownloader` 取代 `MinecraftResourceDownloadTask` 的 `createDownloadTask:size:sha:altName:toPath:`，保留其任务编排与校验语义。
5. **部署目标已下调到 iOS 15.0**（2026-11-05）：Amethyst 是 iOS 14.0，YZL 外壳现在按"通用版"策略走 15.0，覆盖绝大多数 TrollStore 兼容机；再降到 14 需要替换 `AsyncImage`/`refreshable`/URLSession 异步接口，收益小，暂缓。

## 10. 仍需验证 / 下一步

- 在 Mac 或 GitHub macOS runner 上先原样 `make package` 跑通 Amethyst 基线，确认工具链与 JRE 下载可用；
- 确认 GitHub 托管 runner 能否装齐 cmake / ldid / JDK 8（官方用的是越狱 Mac 自托管 runner）；
- 去掉原 UI 后，`SurfaceViewController` 依赖的菜单、日志、退出路径需要补哪些；
- TrollStore `.tipa` 的免电脑安装与自动 JIT 在真机上的实际表现；
- YZL 分片下载器在 iOS 上的实测吞吐（与单连接对比）。

## 11. 来源

- PojavLauncher iOS（归档）：https://github.com/PojavLauncherTeam/PojavLauncher_iOS
- Amethyst iOS：https://github.com/AngelAuraMC/Amethyst-iOS
- TrollStore（支持范围与 URL Scheme）：https://github.com/opa334/TrollStore
- Amethyst JIT wiki：https://wiki.angelauramc.dev/wiki/faq/ios/JIT.html
- 本审计引用的 Amethyst 文件（`main` 分支，2026-11-04）：
  - `Makefile`
  - `.github/workflows/development.yml`
  - `.gitmodules`
  - `entitlements.trollstore.xml`
  - `Natives/JavaLauncher.h`
  - `Natives/JavaLauncher.m`
  - `Natives/SurfaceViewController.h`
  - `Natives/MinecraftResourceDownloadTask.h`
  - `Natives/resources/UniversalJIT26.js`
  - `Natives/authenticator/MicrosoftAuthenticator.m`
  - `JavaApp/src/launcher/net/kdt/pojavlaunch/PojavLauncher.java`
  - `Amethyst.xcodeproj/project.pbxproj`
- 官方 TrollStore README 的支持范围原文：`14.0 beta 2 - 16.6.1, 16.7 RC (20H18), 17.0`；`17.0.1+ will NEVER be supported`。
