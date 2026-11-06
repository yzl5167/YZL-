# M2-b 引擎接入：架构决策与执行手册

日期：2026-11-06。本文是 M2-b（JRE + Amethyst 内核 + SurfaceViewController 桥）
的定案文档，取代此前「待 macOS 侧完成」的开放式描述。
前置阅读：`docs/POJAV-ENGINE-AUDIT.md`（引擎审计）。

## 1. 一句话结论

**不做「把引擎抽成库塞进 YZL 工程」，也不从零重写；做 Amethyst fork +
YZL UI framework 注入。** YZL 现有 SwiftUI 外壳以预编译 framework 形式
进入 fork 的 bundle，fork 补丁只有三处、合计不到一百行。

## 2. 为什么是这条路（已证实的硬约束）

引擎审计时留过第三种可能：「把 Amethyst 当 payload 塞进 YZL 的
xcodegen 工程」。深读源码后确认此路不通，证据有三：

1. **原生桥符号焊在主可执行文件里。** Amethyst 的 Java 补丁层靠
   `System.load(BUNDLE_PATH + "/AngelAuraAmethyst")` 加载主二进制来取
   GLFW/AWT 的 JNI 符号（`JavaApp/src/lwjgl/.../GLFW.java:517`、
   `uikit/UIKit.java:49`）。引擎不能是 framework，必须是 app 本体。
2. **Java 侧有自己的启动链。** JVM 以 `net.kdt.pojavlaunch.PojavLauncher`
   为主类启动（`-Djava.system.class.loader=PojavClassLoader`），由它读
   Amethyst 自己的版本布局并反射拉起游戏（`Tools.launchMinecraft`，
   `Tools.java:55-77`）。直接用 YZL 的 LaunchCommand 当 argv 启动游戏主类，
   会缺掉 cacio AWT、GLFW 桥与 `-XstartOnFirstThread` 语义——这些都在
   Amethyst 的 JVM 参数组装里（`Natives/JavaLauncher.m:234-342`）。
3. **无官方预编译产物。** `AngelAuraMC/Amethyst-iOS` 没有 GitHub Releases
   （2026-11-06 经 API 实测），dylib 必须从源码构建。

而「fork + 注入」恰好绕开所有三条：

- fork 的可执行文件就是引擎本体（约束 1 自动满足）；
- fork 保留 Amethyst 的 JVM 组装与 Java 桥（约束 2 自动满足），
  YZL 只接管 YZL 擅长的部分：版本解析、下载安装、账户、参数生成；
- 源码构建交给 CI（约束 3 由本仓库新增的
  `.github/workflows/build-engine-ipa.yml` 承担）。

## 3. 分层契约

```
┌─ YZLLauncher.app（fork 构建，引擎本体）───────────────────────┐
│  主二进制（CMake）：Amethyst Natives + launchJVM + 原生桥      │
│  Frameworks/：libpojavexec*、GL4ES/Mesa/MetalANGLE/MoltenVK…  │
│  java_runtimes/：JRE 8/17/21/25（assets.angelauramc.dev）     │
│  libs/ + libs_caciocavallo(17)/：JavaApp jar、AWT 桥          │
│  Frameworks/YZLUI.framework：← YZL SwiftUI 外壳（本仓库产出） │
└───────────────────────────────────────────────────────────────┘
        ↑ 运行时交互（三处 fork 补丁定义的接缝）
   ① PojavLauncher.java：env YZL_LAUNCH_PLAN 存在 → YZLGameEntry.launch()
   ② GLFW.java / UIKit.java：System.load 目标支持 env YZL_ENGINE_BINARY 覆盖
   ③ 根视图装配：dlopen YZLUI.framework → NSClassFromString("YZLUIRootController")
        → 命中则 YZL UI 接管，未命中回退 Amethyst 原生 UI（永不卡死构建）
```

### 3.1 启动契约：`YZL_LAUNCH_PLAN.json`

YZL 侧生成（`Core/Engine/EngineLaunchContract.swift`），fork 侧消费
（`engine/fork-patches/yzl/YZLGameEntry.java`）。字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| mainClass | string | 游戏主类（含 Forge bootstrap） |
| classpath | string[] | 客户端 jar + 全部依赖库的绝对路径 |
| gameArguments | string[] | 占位符已替换的游戏参数（含令牌） |
| accountName / accountUUID / accessToken / xuid | string | 账号 |
| versionID / versionType | string | 版本 |
| gameDirectory / assetsDirectory | string | 路径 |
| javaMajor / memoryMB | number | 运行时选择与堆提示 |

写入位置：`$AME_HOME/yzl-launch-plan.json`（`AME_HOME` 由
`YZLEngineHost` 指向 App 沙箱内 `Documents/YZLEngineHome`）。
文件含访问令牌——fork 启动流程交接后由 ObjC 桥删除，Java 侧不复制。

### 3.2 启动链路（fork 进程内）

```
YZL 启动按钮
  → AppState.requestLaunch（自检，逐件诊断）
  → YZLEngineHost.launch(plan)
      1. 写 yzl-launch-plan.json；setenv AME_HOME / YZL_LAUNCH_PLAN / GAME_DIR / JAVA_HOME
      2. dlsym(RTLD_DEFAULT, "launchJVM")          // 符号在 fork 主二进制里
      3. objc_getClass("SurfaceViewController") 呈现游戏画面
      4. launchJVM(username, {id, arguments.jvm_processed=[]}, 0, 0, javaMajor)
           └─ JavaLauncher.m 组装 JVM argv（cacio/LWJGL/首线程/JIT…）
                └─ JVM boot → PojavLauncher.main → launchMinecraft()
                     → [补丁①] YZLGameEntry.launch(planFile)
                          → PojavClassLoader 追加 classpath
                          → 反射 game mainClass.main(gameArgs)   // 进程内进游戏
```

JVM 级参数（堆、cacio、LWJGL、字体、JIT workaround）全部沿用 fork 侧
`JavaLauncher.m` 的既有实现，YZL 不重复下发——只接管 mainClass /
classpath / gameArgs 三样 YZL 已解析到位的东西。

## 4. 仓库内的交付物（本清单即当前进度）

| 交付物 | 位置 | 状态 |
| --- | --- | --- |
| 引擎件扫描（launch 面板逐件诊断） | `Core/Engine/EnginePayloadLocator.swift` | ✅ 已实现，含单测 |
| 启动契约模型与读写 | `Core/Engine/EngineLaunchContract.swift` | ✅ 已实现，含单测 |
| 运行时桥（dlsym + 契约 + SurfaceVC） | `Core/Engine/YZLEngineHost.swift` | ✅ 已实现（fork 环境才激活） |
| 引擎工厂（fork↔外壳自动切换） | `LauncherEngineFactory.make()` | ✅ 已接入 AppState |
| fork 补丁①②（Java 分支 + 二进制名） | `engine/fork-patches/` + `engine/apply-fork-patches.sh` | ✅ 已实现，含 mach/mach.h 新 Xcode 兼容补丁 |
| fork 补丁③ Java 侧实现 | `engine/fork-patches/yzl/YZLGameEntry.java` | ✅ 已实现（同包访问 protected classloader），云端编译通过 |
| fork 补丁③ UI 注入点说明 | `engine/fork-patches/binary-name-and-ui-entry.patch.md` | ✅ 文档级 |
| **YZLUI framework target（注入外壳）** | `project.yml` 的 `YZLUI` target + `YZLUI/YZLUIRootController.swift` | ✅ **云端编译通过（BUILD SUCCEEDED），并已注入成品 tipa** |
| 引擎基线 CI（含 UI 构建注入 + 自行打包 tipa） | `.github/workflows/build-engine-ipa.yml` + `engine/build-engine.sh` | ✅ **全链路绿（2026-11-06 run 42145361915），产出 33.5 MB tipa** |
| JRE 二进制（java_runtimes） | 原分发 CDN `assets.angelauramc.dev` 已死（动态 DNS 失效），Wayback 无快照，上游 openjdk-build 库只有 android 变体 | ⏳ **当前唯一缺口**；tipa 内 java_runtimes 为空壳兜底，可经 fork 自带 JRE 管理界面手动导入 tar.xz |

## 5. 执行手册（按顺序）

**阶段一：引擎基线（验证工具链，不改任何行为）**

1. 用户提供 `GITHUB_TOKEN`（需 repo + workflow 权限），在能访问
   github.com 的环境运行 `scripts/fetch-ipa.ps1` 同款流程触发
   `build-engine-ipa.yml`（workflow_dispatch）；
2. 看 artifact：`Amethyst-baseline-payload.zip` / `*.tipa` 是否产出；
   失败则 `engine-build.log` 回来定位（预期失败点：JDK8 安装、
   CMake 子模块、JRE 下载域名连通性）；
3. 产出的 `.tipa` 装 TrollStore 设备：能打开 Amethyst 原生 UI、
   看到其自带页面即算基线通过。

**阶段二：UI 注入（把 YZL 外壳变成 fork 的脸）**

4. ✅ `YZLUI` framework target 已就位（`project.yml`；共享外壳源码、
   排除 @main 入口；入口类 `@objc(YZLUIRootController)`；
   图标经 `YZLTheme.icon` 解析 framework bundle，独立 App 行为不变）；
5. fork 构建时把 framework 拷进 `Frameworks/`（流水线已接线：
   `build-engine-ipa.yml` 的 Build/Inject 步骤；本地等价命令见
   `engine/build-engine.sh` 第 4/6 步）；
6. 在 fork checkout 上跑 `engine/apply-fork-patches.sh` 后 `make payload`
   → 注入 → 自行打 zip 成 `.tipa`；
7. 核对三处 TODO（见 `binary-name-and-ui-entry.patch.md` 末尾）：
   SurfaceViewController 初始化签名、根视图装配点、jvm_processed 追加策略。

**阶段三：真机联调**

8. TrollStore 装 fork `.tipa` → YZL UI 启动 → 安装 1.20.1 →
   启动自检逐项绿 → 进入游戏主菜单；
9. JIT 与内存问题按 `docs/DEPLOYMENT-MATRIX.md` 的既有分流处理。

## 6. 风险与对策

| 风险 | 对策 |
| --- | --- |
| 托管 runner 编不过 Amethyst（官方用自托管越狱机） | 阶段一就是为此设计的实验；失败日志即产出 |
| `apply-fork-patches.sh` 因上游变化失配 | 幂等 + 特征串检测，失配显式告警不静默 |
| SurfaceViewController 呈现签名不对 | 运行时查找 + TODO 核对点；呈现失败不阻断 JVM 启动 |
| 契约 JSON 含令牌泄漏 | 沙箱内路径 + 启动交接即删 + Java 侧零复制零日志 |
| YZL UI framework 与 fork 的 UIKit 交互（SwiftUI 生命周期） | UI 注入走独立 UIViewController，最坏回退 Amethyst 原生 UI |
