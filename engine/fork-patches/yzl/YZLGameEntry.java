package net.kdt.pojavlaunch;

import java.io.File;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
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
        List<String> classpath = extractArray(json, "classpath");
        List<String> gameArgs = extractArray(json, "gameArguments");

        if (mainClass == null || classpath.isEmpty()) {
            throw new IllegalStateException("YZL_LAUNCH_PLAN 缺少 mainClass 或 classpath");
        }

        System.out.println("[YZL] Launching " + versionID + " via YZL launch plan, mainClass=" + mainClass
            + ", classpath entries=" + classpath.size() + ", game args=" + gameArgs.size());

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
