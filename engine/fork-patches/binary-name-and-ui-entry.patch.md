# M2-b fork 补丁 2 + 3：二进制名解耦与 YZL UI 注入点

## 补丁 2：二进制名解耦（2 行 × 2 文件）

Amethyst 的 Java 补丁层把主可执行文件当库加载（原生桥符号都在主二进制里），
且路径写死了产品名。fork 里把它改成环境变量优先，保持原值兜底：

`JavaApp/src/lwjgl/org/lwjgl/glfw/GLFW.java`（第 517 行附近）：
```java
// 原：System.load(System.getenv("BUNDLE_PATH") + "/AngelAuraAmethyst");
System.load(System.getenv("YZL_ENGINE_BINARY") != null
    ? System.getenv("YZL_ENGINE_BINARY")
    : System.getenv("BUNDLE_PATH") + "/AngelAuraAmethyst");
```

`JavaApp/src/launcher/net/kdt/pojavlaunch/uikit/UIKit.java`（第 49 行附近）：同样改法。

fork 构建时（build-engine-ipa.yml）设置 `YZL_ENGINE_BINARY=<bundle>/<引擎二进制名>`；
若沿用 Amethyst 二进制名则两个 env 都不用设。

## 补丁 3：YZL UI 注入点（AppDelegate / SceneDelegate）

文件：fork 的根视图装配处（Amethyst 的 `LauncherSplitViewController` 装配在
`SceneDelegate` / `AppDelegate` 中，具体类名以 fork 时 main 分支为准）。
在装配 split view controller 之前插入：

```objc
// YZL UI overlay：dlopen YZL UI framework，命中就用它当根控制器。
NSString *yzlFramework = [NSBundle.mainBundle.privateFrameworksPath
    stringByAppendingPathComponent:@"YZLUI.framework/YZLUI"];
void *handle = dlopen(yzlFramework.fileSystemRepresentation, RTLD_LAZY);
if (handle) {
    Class rootClass = NSClassFromString(@"YZLUIRootController");
    if (rootClass) {
        UIViewController *root = [rootClass new];
        self.window.rootViewController = root;   // 替换原 split VC 装配
        [self.window makeKeyAndVisible];
        return;                                  // YZL UI 接管，原 Amethyst UI 不再装配
    }
}
// dlopen 失败或类缺失 → 继续走原 Amethyst UI（fallback，引擎构建永不被 UI 卡死）
```

配套要求（Makefile payload 阶段）：

```make
# 把 YZL UI framework 塞进 bundle（由 YZL 仓库 CI 产出后上传 artifact，
# fork 构建时下载；缺失时跳过 → fallback 到 Amethyst 原生 UI）
ifneq ($(wildcard $(YZL_UI_FRAMEWORK)),)
	cp -R $(YZL_UI_FRAMEWORK) $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/
endif
```

## 运行时链路（fork 侧完整闭环）

```
YZLUI.framework (SwiftUI)
  └─ YZLUIRootController (Swift, UIViewControllerRepresentable)
       ├─ 首页 / 版本 / 账号 / 设置（YZL 现有四页，零改动复用）
       └─ 启动按钮 →
            1. EngineLaunchContract.write(plan, $AME_HOME)   // YZL_LAUNCH_PLAN.json
            2. dlsym(RTLD_DEFAULT, "launchJVM")               // 引擎符号在主二进制里
            3. objc_getClass("SurfaceViewController") 呈现游戏画面
            4. launchJVM(username, profileDict, w, h, minJava)
                 └─ JVM 启动 → PojavLauncher.main → launchMinecraft()
                      → [补丁 1] YZL 分支 → PojavClassLoader → 游戏主类
```

## 首次 fork 编译需要人工核对的三处（已在代码里标 TODO）

1. `SurfaceViewController` 的初始化签名（`SurfaceViewController.h:14-30`，
   fork 时以实际头文件为准——用 `new` 还是带 frame 的 init）。
2. 根视图装配的准确位置（SceneDelegate 或 AppDelegate，找
   `LauncherSplitViewController` 的实例化点）。
3. `jvm_processed` 里是否需要追加 `-Xmx`（YZL 契约 memoryMB）——
   默认沿用 fork 偏好值，不追加。
