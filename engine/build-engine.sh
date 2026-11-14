#!/usr/bin/env bash
# M2-b 引擎构建：在 macOS（本地或 GitHub 托管 runner）上从 Amethyst 源码
# 构建引擎 payload，注入 YZLUI.framework，产出可装的 .tipa / .ipa。
#
# 用法（在 YZL-Launcher-iOS 仓库根目录）：
#   bash engine/build-engine.sh                     # 默认 main 分支
#   AMETHYST_REF=<sha> bash engine/build-engine.sh  # 指定 pin 的提交
#
# 阶段一验证点：托管 runner 能否装齐 cmake + JDK8 + ldid 并跑通 make payload
# （docs/POJAV-ENGINE-AUDIT.md §10）。阶段二：YZLUI.framework 注入（补丁③
# 应用后生效；未应用时框架只是不被加载）。
set -euo pipefail

AMETHYST_REF="${AMETHYST_REF:-main}"
AMETHYST_REPO="${AMETHYST_REPO:-https://github.com/AngelAuraMC/Amethyst-iOS.git}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'echo "[engine] workdir kept: $WORK"' EXIT

echo "[engine] 1/6 clone Amethyst @ $AMETHYST_REF（含子模块 MobileGlues 等）"
git clone --depth 1 --recurse-submodules --shallow-submodules "$AMETHYST_REPO" "$WORK/amethyst"
cd "$WORK/amethyst"
git fetch --depth 1 origin "$AMETHYST_REF" 2>/dev/null || true
git checkout "$AMETHYST_REF" 2>/dev/null || echo "[engine] WARN: checkout $AMETHYST_REF 失败，使用默认分支"
git rev-parse HEAD | tee "$WORK/amethyst-commit.txt"

echo "[engine] 2/6 toolchain: cmake + ldid + coreutils + xcodegen + JDK8"
if ! command -v brew >/dev/null 2>&1; then
  echo "[engine] 需要 Homebrew（GitHub macOS runner 自带）" >&2
  exit 1
fi
for pkg in cmake ldid coreutils xcodegen; do
  brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done
if ! /usr/libexec/java_home -v 1.8 >/dev/null 2>&1; then
  echo "[engine] 缺 JDK 8。本机请装 Temurin 8；CI 用 actions/setup-java@v4 (temurin, 8)" >&2
  exit 1
fi

echo "[engine] 3/6 apply fork patches"
bash "$REPO_ROOT/engine/apply-fork-patches.sh" "$WORK/amethyst" || {
  echo "[engine] WARN: 补丁应用失败，继续构建未打补丁的基线（UI 注入链路暂不可用）"
}

echo "[engine] 4/6 build YZLUI.framework"
YZLUI_FW=""
set -o pipefail
if ( cd "$REPO_ROOT" && xcodegen generate && \
     xcodebuild -project YZLLauncher.xcodeproj -target YZLUI -configuration Release \
       -sdk iphoneos -destination 'generic/platform=iOS' \
       SYMROOT="$REPO_ROOT/yzlui-sym" \
       CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$WORK/yzlui-build.log" ); then
  YZLUI_FW="$REPO_ROOT/yzlui-sym/Release-iphoneos/YZLUI.framework"
  if [ ! -f "$YZLUI_FW/YZLUI" ]; then
    echo "[engine] ERROR: YZLUI.framework 缺少可执行文件（只有资源，没有 Mach-O）" >&2
    grep -n "error:" "$WORK/yzlui-build.log" | head -40 >&2 || true
    exit 1
  fi
else
  echo "[engine] ERROR: YZLUI 构建失败；拒绝生成没有 YZL UI 的引擎包" >&2
  grep -n "error:" "$WORK/yzlui-build.log" | head -40 >&2 || true
  exit 1
fi

echo "[engine] 4.5/6 pre-stage JRE archives（RUNNER=1 时 Makefile 跳过下载）"
mkdir -p "$WORK/amethyst/depends" && cd "$WORK/amethyst/depends"
for v in 8 17 21 25; do
  curl -fL --retry 3 "https://assets.angelauramc.dev/openjdk/ios-arm64/jre$v-ios-aarch64.zip" -o "jre$v-ios-aarch64.zip"
  unzip -oq "jre$v-ios-aarch64.zip" && rm "jre$v-ios-aarch64.zip"
  echo "jre$v staged"
done
cd "$WORK/amethyst"

echo "[engine] 5/6 make payload (native + dep_mg + java + jre + payload)"
make -j"$(sysctl -n hw.ncpu)" payload RUNNER=1 TROLLSTORE_JIT_ENT=1 RELEASE=1 2>&1 | tee "$WORK/build.log"

echo "[engine] 6/6 inject UI framework + package"
APP="$(find "$WORK/amethyst/artifacts" -type d -name 'AngelAuraAmethyst.app' | head -1)"
if [ -z "$YZLUI_FW" ] || [ -z "$APP" ]; then
  echo "[engine] ERROR: 缺 YZLUI.framework 或 app，拒绝打包空壳引擎" >&2
  exit 1
fi
mkdir -p "$APP/Frameworks"
rm -rf "$APP/Frameworks/YZLUI.framework"
cp -R "$YZLUI_FW" "$APP/Frameworks/"
if [ ! -f "$APP/Frameworks/YZLUI.framework/YZLUI" ]; then
  echo "[engine] ERROR: 注入后缺少 YZLUI 可执行文件" >&2
  exit 1
fi
ldid -S "$APP/Frameworks/YZLUI.framework/YZLUI"
echo "[engine] YZLUI.framework 已注入 $APP/Frameworks"

DIST="$REPO_ROOT/dist-engine"
mkdir -p "$DIST"
if [ -d "$WORK/amethyst/artifacts/Payload" ]; then
  ( cd "$WORK/amethyst/artifacts" && zip -qry "$DIST/YZL-engine.tipa" Payload )
  # iOS 18 侧载包必须真正剥签重出，不能把 tipa 复制改名：
  # tipa 带 ldid 伪签 + TrollStore 私有 entitlement，重签后 UI 起不来。
  bash "$REPO_ROOT/scripts/make-sideload-ipa.sh" \
    "$WORK/amethyst/artifacts" \
    "$DIST/YZL-engine-sideload-unsigned.ipa"
  if ! unzip -l "$DIST/YZL-engine.tipa" | grep -q 'Frameworks/YZLUI.framework/YZLUI$'; then
    echo "[engine] ERROR: 最终 tipa 缺少 YZLUI.framework/YZLUI" >&2
    exit 1
  fi
  rm -f "$DIST/YZL-engine-unsigned.ipa"
else
  echo "[engine] ERROR: Payload 目录不存在，只有日志可取" >&2
  exit 1
fi
cp "$WORK/build.log" "$DIST/build-engine.log" 2>/dev/null || true
[ -f "$WORK/yzlui-build.log" ] && cp "$WORK/yzlui-build.log" "$DIST/" || true
cp "$WORK/amethyst-commit.txt" "$DIST/" 2>/dev/null || true
ls -la "$DIST"
echo "[engine] done。.tipa 直接给 TrollStore 安装（补丁③生效后启动即 YZL UI）。"
