package net.kdt.pojavlaunch;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.Scanner;

/**
 * M2-b fork 桥的 Java 侧：读取 YZL 启动器生成的完整启动计划
 * （$AME_HOME/yzl-launch-plan.json，字段契约见 YZL 仓库
 * Core/Engine/EngineLaunchContract.swift），用 Amethyst 既有的
 * PojavClassLoader + 反射 main 机制在进程内拉起游戏。
 *
 * 注意：必须在 net.kdt.pojavlaunch 包内（不能开 yzl 子包）——
 * PojavClassLoader.appendToClassPathForInstrumentation 是 protected，
 * 同包才能访问（Tools.launchMinecraft 就是这么用的）。
 *
 * 与原 Tools.launchMinecraft 的差异：mainClass / classpath / 游戏参数
 * 全部来自 YZL 侧解析（LaunchPlanBuilder / ArgumentResolver），不再读取
 * Amethyst 自己的版本布局、安装器与参数组装。
 *
 * 令牌安全：契约文件由 YZL 侧（ObjC 桥）在 JVM 拉起后删除；
 * 本类不复制、不落日志。
 */
public final class YZLGameEntry {
    private YZLGameEntry() {}

    public static void launch(File planFile) throws Throwable {
        Scanner scanner = new Scanner(planFile, "UTF-8").useDelimiter("\\A");
        String json = scanner.hasNext() ? scanner.next() : "{}";
        scanner.close();

        String mainClass = extractString(json, "mainClass");
        String versionID = extractString(json, "versionID");
        String gameDir = extractString(json, "gameDirectory");
        List<String> classpath = extractArray(json, "classpath");
        List<String> gameArgs = extractArray(json, "gameArguments");

        if (mainClass == null || classpath.isEmpty()) {
            throw new IllegalStateException("YZL_LAUNCH_PLAN 缺少 mainClass 或 classpath");
        }

        System.out.println("[YZL] Launching " + versionID + " via YZL launch plan, mainClass=" + mainClass
            + ", classpath entries=" + classpath.size() + ", game args=" + gameArgs.size());

        // 卡死采样：整合包在「正在加载地形」卡住时，界面完全静止，什么日志都不再输出。
        // 起一个守护线程在几个时间点把全部 Java 线程栈落到磁盘，下一次就能直接看出
        // 是哪个线程（渲染线程 / 区块构建 / 集成服务端 worldgen）在等锁。
        startStallWatchdog(versionID, gameDir);

        // 沿用 Tools.launchMinecraft 的进程内启动机制。
        PojavClassLoader loader = (PojavClassLoader) ClassLoader.getSystemClassLoader();
        for (String s : System.getProperty("java.class.path").split(":")) {
            loader.appendToClassPathForInstrumentation(s);
        }
        for (String s : classpath) {
            if (!s.isEmpty()) {
                loader.addURL(new File(s).toURI().toURL());
            }
        }

        Class<?> clazz = loader.loadClass(mainClass);
        Method method = clazz.getMethod("main", String[].class);
        method.invoke(null, new Object[]{gameArgs.toArray(new String[0])});
    }

    // ---- 卡死采样 ----

    /// 第一次采样在 120 秒，之后 240 / 420 秒，最多三份，避免日志无限膨胀。
    /// 位置：<gameDir>/logs/yzl-stall-<版本>-<n>.log，游戏目录不可写时退回 user.home。
    private static void startStallWatchdog(final String versionID, final String gameDir) {
        Thread thread = new Thread(new Runnable() {
            @Override
            public void run() {
                long[] delays = new long[] {120000L, 120000L, 180000L};
                for (int i = 0; i < delays.length; i++) {
                    try {
                        Thread.sleep(delays[i]);
                    } catch (InterruptedException e) {
                        return;
                    }
                    File target = stallLogFile(versionID, gameDir, i + 1);
                    try {
                        dumpThreads(target);
                        System.out.println("[YZL] thread dump #" + (i + 1) + " -> " + target.getAbsolutePath());
                    } catch (Throwable t) {
                        System.out.println("[YZL] thread dump failed: " + t);
                    }
                }
            }
        }, "yzl-stall-watchdog");
        thread.setDaemon(true);
        thread.start();
    }

    private static File stallLogFile(String versionID, String gameDir, int index) {
        String name = "yzl-stall-" + sanitizeName(versionID) + "-" + index + ".log";
        File dir = null;
        if (gameDir != null && !gameDir.isEmpty()) {
            dir = new File(new File(gameDir), "logs");
            if (!dir.isDirectory() && !dir.mkdirs()) {
                dir = null;
            }
        }
        if (dir == null) {
            dir = new File(System.getProperty("user.home", "."));
        }
        return new File(dir, name);
    }

    private static String sanitizeName(String raw) {
        if (raw == null || raw.isEmpty()) {
            return "unknown";
        }
        return raw.replaceAll("[^A-Za-z0-9._-]", "_");
    }

    private static void dumpThreads(File target) throws IOException {
        StringBuilder sb = new StringBuilder(64 * 1024);
        sb.append("# YZL stall sample ").append(new Date()).append('\n');
        Map<Thread, StackTraceElement[]> traces = Thread.getAllStackTraces();
        for (Map.Entry<Thread, StackTraceElement[]> entry : traces.entrySet()) {
            Thread t = entry.getKey();
            sb.append("\n\"").append(t.getName()).append("\" #").append(t.getId())
                .append(' ').append(t.getState())
                .append(t.isDaemon() ? " daemon" : "").append('\n');
            StackTraceElement[] stack = entry.getValue();
            for (int i = 0; i < stack.length; i++) {
                sb.append("    at ").append(stack[i]).append('\n');
            }
        }
        FileWriter writer = new FileWriter(target, false);
        try {
            writer.write(sb.toString());
        } finally {
            writer.close();
        }
    }

    // ---- 最小 JSON 读取（Amethyst 的 JRE 不带 org.json；字段平铺且结构固定）----

    static String extractString(String json, String key) {
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
                else if (next == 'r') { /* drop */ }
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

    static List<String> extractArray(String json, String key) {
        List<String> result = new ArrayList<String>();
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
                if (c == '\\' && i + 1 < json.length()) {
                    current.append(c).append(json.charAt(++i));
                    continue;
                }
                if (c == '"') {
                    inString = false;
                    result.add(unescape(current.toString()));
                    current.setLength(0);
                    continue;
                }
                current.append(c);
                continue;
            }
            if (c == '"') {
                inString = true;
                current.setLength(0);
                continue;
            }
            if (c == '[') {
                depth++;
                continue;
            }
            if (c == ']') {
                depth--;
                if (depth == 0) break;
                continue;
            }
        }
        return result;
    }

    private static String unescape(String raw) {
        StringBuilder sb = new StringBuilder(raw.length());
        for (int i = 0; i < raw.length(); i++) {
            char c = raw.charAt(i);
            if (c == '\\' && i + 1 < raw.length()) {
                char next = raw.charAt(++i);
                if (next == 'n') sb.append('\n');
                else if (next == 't') sb.append('\t');
                else if (next == 'r') { /* drop */ }
                else if (next == 'u') {
                    sb.append((char) Integer.parseInt(raw.substring(i + 1, i + 5), 16));
                    i += 4;
                } else sb.append(next);
                continue;
            }
            sb.append(c);
        }
        return sb.toString();
    }
}
