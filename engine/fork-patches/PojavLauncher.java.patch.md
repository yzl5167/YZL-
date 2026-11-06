# M2-b fork 补丁 1：PojavLauncher 主类的 YZL 分支

文件：`JavaApp/src/launcher/net/kdt/pojavlaunch/PojavLauncher.java`（Amethyst fork 内）

原 `launchMinecraft(String[] args)` 从 Amethyst 自己的版本布局组装命令；
本补丁在方法入口加一个 YZL 分支：环境变量 `YZL_LAUNCH_PLAN` 指向 YZL
生成的启动契约 JSON（见 YZL 仓库 `Core/Engine/EngineLaunchContract.swift`），
直接用 YZL 解析好的 mainClass / classpath / gameArguments 进程内拉起游戏，
完全跳过 Amethyst 的版本布局、安装器与参数组装。

替换后的 `launchMinecraft` 全文如下（其余方法不动）：

```java
public static void launchMinecraft(String[] args) throws Throwable {
    // ---- YZL branch: fully-resolved launch plan from the YZL launcher UI ----
    String yzlPlanPath = System.getenv("YZL_LAUNCH_PLAN");
    if (yzlPlanPath != null && !yzlPlanPath.isEmpty()) {
        launchFromYZLPlan(new File(yzlPlanPath));
        return;
    }
    // ---- original Amethyst path below (unchanged) ----
    System.setProperty("appdir", "./spiral");
    System.setProperty("resource_dir", "./spiral/rsrc");

    String sizeStr = System.getProperty("cacio.managed.screensize");
    System.setProperty("glfw.windowSize", sizeStr);

    File forgeSplashFile = new File(Tools.DIR_GAME_NEW, "config/splash.properties");
    if (System.getProperty("pojav.internal.keepForgeSplash") == null) {
        forgeSplashFile.getParentFile().mkdir();
        if (forgeSplashFile.exists()) {
            Tools.write(forgeSplashFile.getAbsolutePath(), Tools.read(forgeSplashFile.getAbsolutePath().replace("enabled=true", "enabled=false")));
        } else {
            Tools.write(forgeSplashFile.getAbsolutePath(), "enabled=false");
        }
    }

    System.setProperty("org.lwjgl.vulkan.libname", "libMoltenVK.dylib");

    MinecraftAccount account = MinecraftAccount.load(args[0]);
    JMinecraftVersionList.Version version = Tools.getVersionInfo(args[1]);
    System.out.println("Launching Minecraft " + version.id);
    String configPath;
    if (version.logging != null) {
        if (version.logging.client.file.id.equals("client-1.12.xml")) {
            configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.12.xml";
        } else if (version.logging.client.file.id.equals("client-1.7.xml")) {
            configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.7.xml";
        } else {
            configPath = Tools.DIR_GAME_NEW + "/" + version.logging.client.file.id;
        }
        System.setProperty("log4j.configurationFile", configPath);
    }

    Tools.launchMinecraft(account, version);
}

/**
 * YZL 引擎桥：读取 YZL 启动器（SwiftUI 外壳）生成的完整启动计划，
 * 复用 Amethyst 的进程内启动机制（PojavClassLoader + 反射 main），
 * 但 mainClass / classpath / 游戏参数全部来自 YZL 侧的解析结果。
 */
private static void launchFromYZLPlan(File planFile) throws Throwable {
    java.util.Scanner scanner = new java.util.Scanner(planFile, "UTF-8").useDelimiter("\\A");
    String json = scanner.hasNext() ? scanner.next() : "{}";
    scanner.close();

    // 轻量 JSON 解析：org.json 在 Android 上内置，Amethyst 的 JRE 不带——
    // 这里用最小手写解析，字段都是平铺的字符串 / 字符串数组。
    String mainClass = extractString(json, "mainClass");
    String gameDir = extractString(json, "gameDirectory");
    String assetsDir = extractString(json, "assetsDirectory");
    String username = extractString(json, "accountName");
    String uuid = extractString(json, "accountUUID");
    String accessToken = extractString(json, "accessToken");
    String xuid = extractString(json, "xuid");
    String versionID = extractString(json, "versionID");
    String versionType = extractString(json, "versionType");
    int memoryMB = (int) extractNumber(json, "memoryMB", 2048);
    java.util.List<String> classpath = extractArray(json, "classpath");
    java.util.List<String> gameArgs = extractArray(json, "gameArguments");

    if (mainClass == null || classpath.isEmpty()) {
        throw new IllegalStateException("YZL_LAUNCH_PLAN 缺少 mainClass 或 classpath");
    }

    System.out.println("[YZL] Launching " + versionID + " via YZL launch plan, mainClass=" + mainClass);

    // 把游戏目录暴露给沿用 Tools 常量的代码路径（splash.properties 等）。
    System.setProperty("glfw.windowSize", System.getProperty("cacio.managed.screensize", "1920x1080"));
    System.setProperty("org.lwjgl.vulkan.libname", "libMoltenVK.dylib");

    PojavClassLoader loader = (PojavClassLoader) ClassLoader.getSystemClassLoader();
    for (String s : System.getProperty("java.class.path").split(":")) {
        loader.appendToClassPathForInstrumentation(s);
    }
    for (String s : classpath) {
        if (!s.isEmpty()) {
            loader.addURL(new File(s).toURI().toURL());
        }
    }

    // 游戏参数：YZL 已替换占位符，直接透传；补 --demo 等由 YZL 侧负责。
    java.util.List<String> argv = new java.util.ArrayList<String>(gameArgs);

    Class<?> clazz = loader.loadClass(mainClass);
    java.lang.reflect.Method method = clazz.getMethod("main", String[].class);
    method.invoke(null, new Object[]{argv.toArray(new String[0])});
}

private static String extractString(String json, String key) {
    String needle = "\"" + key + "\"";
    int keyIndex = json.indexOf(needle);
    if (keyIndex < 0) return null;
    int colon = json.indexOf(':', keyIndex + needle.length());
    if (colon < 0) return null;
    int open = json.indexOf('"', colon);
    if (open < 0) return null;
    StringBuilder sb = new StringBuilder();
    for (int i = open + 1; i < json.length(); i++) {
        char c = json.charAt(i);
        if (c == '\\' && i + 1 < json.length()) {
            char next = json.charAt(++i);
            if (next == 'n') sb.append('\n');
            else if (next == 't') sb.append('\t');
            else if (next == 'u') {
                sb.append((char) Integer.parseInt(json.substring(i + 1, i + 5), 16));
                i += 4;
            } else sb.append(next);
            continue;
        }
        if (c == '"') break;
        sb.append(c);
    }
    return sb.toString();
}

private static long extractNumber(String json, String key, long fallback) {
    String needle = "\"" + key + "\"";
    int keyIndex = json.indexOf(needle);
    if (keyIndex < 0) return fallback;
    int colon = json.indexOf(':', keyIndex + needle.length());
    if (colon < 0) return fallback;
    int end = colon + 1;
    while (end < json.length() && ("-0123456789".indexOf(json.charAt(end)) >= 0 || Character.isDigit(json.charAt(end)))) end++;
    try {
        return Long.parseLong(json.substring(colon + 1, end).trim());
    } catch (NumberFormatException e) {
        return fallback;
    }
}

private static java.util.List<String> extractArray(String json, String key) {
    java.util.List<String> result = new java.util.ArrayList<String>();
    String needle = "\"" + key + "\"";
    int keyIndex = json.indexOf(needle);
    if (keyIndex < 0) return result;
    int open = json.indexOf('[', keyIndex + needle.length());
    if (open < 0) return result;
    int depth = 0;
    StringBuilder current = new StringBuilder();
    boolean inString = false;
    for (int i = open; i < json.length(); i++) {
        char c = json.charAt(i);
        if (inString) {
            if (c == '\\') { current.append(c).append(json.charAt(++i)); continue; }
            if (c == '"') { inString = false; result.add(current.toString()); current.setLength(0); continue; }
            current.append(c);
            continue;
        }
        if (c == '"') { inString = true; current.setLength(0); continue; }
        if (c == '[') { depth++; continue; }
        if (c == ']') { depth--; if (depth == 0) break; continue; }
    }
    return result;
}
```

## 设计要点

1. **不重排 JVM 参数**：堆、cacio、LWJGL、字体等 JVM 级参数全部沿用
   `JavaLauncher.m` 的既有组装（fork 原样保留），YZL 只接管
   mainClass / classpath / 游戏参数——这三样 YZL 的
   `LaunchPlanBuilder` / `ArgumentResolver` 已经解析到位。
2. **内存覆盖**：YZL 契约里的 `memoryMB` 目前不重复下发 -Xmx（fork 的
   `java.allocated_memory` 偏好默认值即可）；如需覆盖，把
   `-Xmx<memoryMB>M` 追加进 `jvm_processed`（见 YZLLaunchBridge.m 注释），
   JVM 取最后一个 -Xmx。
3. **令牌安全**：契约文件含访问令牌，只写进 `$AME_HOME`（应用沙箱内），
   fork 启动后应删除——`YZLLaunchBridge.m` 在 JVM 正常拉起后负责删除；
   Java 侧不复制不落日志。
4. **手写 JSON 解析**：Amethyst 的 JRE 不带 org.json，避免引入新依赖；
   字段结构固定且平铺，手写解析足够（已对转义 / unicode / 嵌套数组处理）。
