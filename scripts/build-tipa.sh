#!/usr/bin/env bash
# 一条命令出 TrollStore 包（必须在 macOS 上跑）。
#
#   bash scripts/build-tipa.sh            # Release 构建 + 打包 + ldid 伪签
#   RELEASE=0 bash scripts/build-tipa.sh  # Debug 构建（带 get-task-allow，便于 Xcode 附加开 JIT）
#
# 依赖：brew install xcodegen ldid
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RELEASE="${RELEASE:-1}"
CONFIG="Release"
[[ "$RELEASE" == "0" ]] && CONFIG="Debug"

command -v xcodegen >/dev/null 2>&1 || { echo "缺少 xcodegen：brew install xcodegen" >&2; exit 1; }
command -v ldid >/dev/null 2>&1 || { echo "缺少 ldid：brew install ldid" >&2; exit 1; }

echo "[1/4] 生成 Xcode 工程"
xcodegen generate

echo "[2/4] 编译 $CONFIG（关闭签名）"
xcodebuild \
  -project YZLLauncher.xcodeproj \
  -scheme YZLLauncher \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

echo "[3/4] 打包未签名 IPA"
bash scripts/package-unsigned-ipa.sh \
  "build/Build/Products/${CONFIG}-iphoneos/YZLLauncher.app" \
  "dist/YZLLauncher-unsigned.ipa"

echo "[4/4] ldid 伪签成 TrollStore 包"
bash scripts/sign-ipa.sh "dist/YZLLauncher-unsigned.ipa" trollstore

echo
echo "完成。把生成的 .tipa 传到 iPhone：文件 App 长按 → 共享 → TrollStore → Install"
