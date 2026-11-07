#!/usr/bin/env bash
# 把 engine/fork-patches 里的三处补丁应用到 Amethyst 检出目录。
# 用法：bash engine/apply-fork-patches.sh <amethyst-checkout-dir>
# 幂等：重复执行时已打过的补丁会跳过（以特征串为准）。
set -euo pipefail

AMETHYST_DIR="${1:?用法: apply-fork-patches.sh <amethyst-checkout-dir>}"
MARKER="YZL_LAUNCH_PLAN"

echo "[patch] target: $AMETHYST_DIR"

PL="JavaApp/src/launcher/net/kdt/pojavlaunch/PojavLauncher.java"

if grep -q "$MARKER" "$AMETHYST_DIR/$PL"; then
  echo "[patch] PojavLauncher.java 已含 YZL 分支，跳过"
else
  python3 - "$AMETHYST_DIR/$PL" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()
needle = "public static void launchMinecraft(String[] args) throws Throwable {"
if needle not in src:
    sys.exit("launchMinecraft 方法未找到，Amethyst 版本可能已变化，需人工核对 fork 补丁")
branch = needle + '''
    // ---- YZL branch: fully-resolved launch plan from the YZL launcher UI ----
    String yzlPlanPath = System.getenv("YZL_LAUNCH_PLAN");
    if (yzlPlanPath != null && !yzlPlanPath.isEmpty()) {
        YZLGameEntry.launch(new File(yzlPlanPath));
        return;
    }
'''
src = src.replace(needle, branch, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print("[patch] PojavLauncher.java: YZL 分支已插入")
PY
fi

# 二进制名解耦：GLFW.java / UIKit.java 的 System.load(BUNDLE_PATH/固定名)
for f in "JavaApp/src/lwjgl/org/lwjgl/glfw/GLFW.java" \
         "JavaApp/src/launcher/net/kdt/pojavlaunch/uikit/UIKit.java"; do
  target="$AMETHYST_DIR/$f"
  if [ ! -f "$target" ]; then
    echo "[patch] WARN: $f 不存在，跳过（fork 结构变化，需人工核对）"
    continue
  fi
  if grep -q "YZL_ENGINE_BINARY" "$target"; then
    echo "[patch] $f 已解耦二进制名，跳过"
  else
    python3 - "$target" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()
needle = 'System.getenv("BUNDLE_PATH") + "/AngelAuraAmethyst"'
replacement = '(System.getenv("YZL_ENGINE_BINARY") != null ? System.getenv("YZL_ENGINE_BINARY") : System.getenv("BUNDLE_PATH") + "/AngelAuraAmethyst")'
if needle not in src:
    sys.exit(f"二进制名加载点在 {path} 中未找到，需人工核对")
src = src.replace(needle, replacement)
with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"[patch] {path}: 二进制名已解耦")
PY
  fi
done

# YZLGameEntry.java（fork 桥的 Java 侧实现，独立文件，直接落盘）
# 必须落在 net.kdt.pojavlaunch 包内：PojavClassLoader 的
# appendToClassPathForInstrumentation 是 protected，跨包访问不了。
ENTRY_DIR="$AMETHYST_DIR/JavaApp/src/launcher/net/kdt/pojavlaunch"
mkdir -p "$ENTRY_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/fork-patches/yzl/YZLGameEntry.java" ]; then
  cp "$SCRIPT_DIR/fork-patches/yzl/YZLGameEntry.java" "$ENTRY_DIR/YZLGameEntry.java"
  echo "[patch] YZLGameEntry.java 已放置（net.kdt.pojavlaunch 包）"
else
  echo "[patch] WARN: engine/fork-patches/yzl/YZLGameEntry.java 缺失，YZL 启动分支会编译失败"
fi

# 上游兼容补丁：新版 Xcode（macos-15 runner 的 clang）把隐式函数声明当错误，
# JavaLauncher.m 用了 Mach 异步端口 API 但没 include mach/mach.h
# （上游自托管越狱机的旧 Xcode 只给 warning）。
JL="$AMETHYST_DIR/Natives/JavaLauncher.m"
if [ -f "$JL" ]; then
  if grep -q "#include <mach/mach.h>" "$JL"; then
    echo "[patch] JavaLauncher.m 已含 mach/mach.h，跳过"
  else
    python3 - "$JL" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()
needle = '#import "JavaLauncher.h"'
if needle not in src:
    sys.exit("JavaLauncher.h import 未找到，上游结构变化，需人工核对")
src = src.replace(
    needle,
    "#include <mach/mach.h>      /* YZL fork: task_set_exception_ports */\n"
    "#include <mach/mach_init.h> /* YZL fork: mach_task_self (new Xcode rejects implicit decls) */\n" + needle,
    1,
)
with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print("[patch] JavaLauncher.m: mach/mach.h 已补")
PY
  fi
else
  echo "[patch] WARN: Natives/JavaLauncher.m 不存在"
fi

# ---- YZL fork 补丁③：SceneDelegate 根视图让位给 YZL UI ----
# Amethyst 的根装配在 SceneDelegate.m 的 launchInitialViewController(self.window)。
# 在其之前尝试 dlopen YZLUI.framework：命中 YZLUIRootController 就接管根视图，
# 未命中（无框架）继续走原生 UI，永不卡死。
SD="$AMETHYST_DIR/Natives/SceneDelegate.m"
if [ -f "$SD" ]; then
  if grep -q "YZLUIRootController" "$SD"; then
    echo "[patch] SceneDelegate.m 已含 YZL 注入，跳过"
  else
    python3 - "$SD" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()

call_needle = "launchInitialViewController(self.window);"
if call_needle not in src:
    sys.exit("launchInitialViewController 调用未找到，上游结构变化，需人工核对")

# 文件头补 dlfcn（dlopen 需要；ObjC 的 #import 必须在文件作用域）
import_needle = '#import "utils.h"'
if "#include <dlfcn.h>" not in src and "#import <dlfcn.h>" not in src:
    if import_needle in src:
        src = src.replace(import_needle, import_needle + '\n#include <dlfcn.h>', 1)

injection = '''    // ---- YZL UI injection (M2-b patch 3) ----
    {
        NSString *yzlFrameworkPath = [NSBundle.mainBundle.privateFrameworksPath
            stringByAppendingPathComponent:@"YZLUI.framework/YZLUI"];
        void *yzlHandle = dlopen(yzlFrameworkPath.fileSystemRepresentation, RTLD_LAZY);
        Class yzlRootClass = yzlHandle ? NSClassFromString(@"YZLUIRootController") : nil;
        if (yzlRootClass) {
            UIViewController *yzlRoot = [yzlRootClass new];
            self.window.rootViewController = yzlRoot;
            NSLog(@"[YZL] YZLUI.framework loaded, YZL UI takes over");
            return;
        }
        NSLog(@"[YZL] YZLUI.framework not present, falling back to Amethyst UI");
    }
'''
src = src.replace(call_needle, injection + call_needle, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print("[patch] SceneDelegate.m: YZL UI 注入点已插入")
PY
  fi
else
  echo "[patch] WARN: Natives/SceneDelegate.m 不存在"
fi

echo "[patch] done"
