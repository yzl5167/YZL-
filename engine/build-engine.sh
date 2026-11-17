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
# JRE 来源（2026-11-17 修复）：旧的 assets.angelauramc.dev 已失联，
# 下载超时只会解出空壳 → 引擎包只剩 Java 17。改用实测可用的源：
#   · Java 8/17/21：Vlad-Games PojavLauncher 3.0 release 的 iOS aarch64 真 JRE
#     （zip 内是单个 tar.xz，解开即 release + lib/，命中 RuntimeLocator 标记）
#   · Java 25：官方无 iOS 构建，实验性地拿 Microsoft macOS aarch64 JDK，
#     用 vtool 把 Mach-O 平台标记改成 ios 再 ldid 伪签。macOS JRE 依赖 AppKit，
#     真机大概率跑不起来——仅作占位/实验，**失败不阻断** 8/17/21 出包。
# 目标目录统一为 depends/java-N-openjdk/（内含 release 标记文件，
# Makefile 的 METHOD_JAVA_UNPACK 见 release 即跳过，直接用我们预置的目录）。
mkdir -p "$WORK/amethyst/depends" && cd "$WORK/amethyst/depends"

JRE_BASE="https://github.com/Vlad-Games/PojavLauncher_iOS/releases/download/3.0"

stage_ios_jre() {
  local v="$1" url="$2" inner tar
  local zip="jre${v}-src.zip"
  echo "[engine] jre$v: 下载 $url"
  if ! curl -fL --retry 3 --max-time 900 "$url" -o "$zip"; then
    echo "[engine] WARN: jre$v 下载失败，跳过" >&2; return 1
  fi
  inner="$(unzip -Z1 "$zip" 2>/dev/null | grep -E '\.tar\.xz$' | head -1)"
  if [ -z "$inner" ]; then
    echo "[engine] WARN: jre$v zip 内无 tar.xz，跳过" >&2; rm -f "$zip"; return 1
  fi
  unzip -oq "$zip" "$inner" && rm -f "$zip"
  rm -rf "jre${v}-x" && mkdir -p "jre${v}-x"
  tar -xJf "$inner" -C "jre${v}-x" || { echo "[engine] WARN: jre$v 解压失败" >&2; return 1; }
  rm -f "$inner"
  if [ ! -f "jre${v}-x/release" ]; then
    # 有些归档多套一层目录，找含 release 的那一层
    local relroot
    relroot="$(dirname "$(find "jre${v}-x" -type f -name release | head -1)")"
    [ -n "$relroot" ] || { echo "[engine] WARN: jre$v 无 release 标记" >&2; return 1; }
    rm -rf "java-${v}-openjdk" && mv "$relroot" "java-${v}-openjdk"
  else
    rm -rf "java-${v}-openjdk" && mv "jre${v}-x" "java-${v}-openjdk"
  fi
  rm -rf "jre${v}-x"
  if [ ! -f "java-${v}-openjdk/release" ]; then
    echo "[engine] WARN: jre$v 暂存后缺 release" >&2; return 1
  fi
  echo "[engine] jre$v staged ($(du -sh "java-${v}-openjdk" | cut -f1))"
}

# 8/17/21：真·iOS JRE，缺失即构建失败（不允许再出只有 17 的包）
for v in 8 17 21; do
  stage_ios_jre "$v" "$JRE_BASE/jre${v}-ios-aarch64.zip" || {
    echo "[engine] ERROR: Java $v 是必需运行时，暂存失败，拒绝出包" >&2; exit 1
  }
done

# 25：macOS aarch64 JDK 转换（实验，失败仅告警不阻断）
if command -v vtool >/dev/null 2>&1; then
  echo "[engine] jre25: 实验性转换 macOS aarch64 JDK25 → iOS（失败不阻断）"
  if curl -fL --retry 3 --max-time 1200 \
      "https://aka.ms/download-jdk/microsoft-jdk-25.0.5.0.2-macos-aarch64.tar.gz" \
      -o jdk25-macos.tar.gz; then
    rm -rf jdk25-x && mkdir -p jdk25-x
    if tar -xzf jdk25-macos.tar.gz -C jdk25-x; then
      home25="$(dirname "$(find jdk25-x -type f -name release | head -1)")"
      if [ -n "$home25" ] && [ -f "$home25/release" ]; then
        # 把包内所有 Mach-O 的平台标记从 macOS 改成 iOS 并伪签，尽量提高兼容几率
        find "$home25" -type f -perm -u+x | while read -r f; do
          if file "$f" 2>/dev/null | grep -q 'Mach-O'; then
            vtool -arch arm64 -set-build-version ios 15.0 26.0 -replace -output "$f" "$f" 2>/dev/null || true
            ldid -S "$f" 2>/dev/null || true
          fi
        done
        rm -rf java-25-openjdk && cp -R "$home25" java-25-openjdk
        echo "[engine] jre25 staged (experimental, $(du -sh java-25-openjdk | cut -f1))"
      else
        echo "[engine] WARN: jre25 解包后无 release，跳过" >&2
      fi
    else
      echo "[engine] WARN: jre25 解压失败，跳过" >&2
    fi
    rm -rf jdk25-x jdk25-macos.tar.gz
  else
    echo "[engine] WARN: jre25 下载失败，跳过" >&2
  fi
else
  echo "[engine] WARN: 无 vtool，跳过实验性 jre25" >&2
fi

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
