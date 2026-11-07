#!/usr/bin/env bash
# 在 macOS 上给「未签名 IPA」签名。Windows 上跑不了这个脚本。
#
#   模式 1 trollstore（默认）：ldid 伪签 + packaging/entitlements.trollstore.plist
#       产物 .tipa，用 TrollStore 直接安装：免电脑、永久不掉签、可开 JIT。
#   模式 2 sideload：codesign 用 Apple Development 证书 + 描述文件
#       产物 .ipa，交给 AltStore / SideStore / Apple Configurator 安装，约 7 天到期。
#
# 用法：
#   bash scripts/sign-ipa.sh build/YZLLauncher-unsigned.ipa
#   bash scripts/sign-ipa.sh build/YZLLauncher-unsigned.ipa trollstore
#   bash scripts/sign-ipa.sh build/YZLLauncher-unsigned.ipa sideload "Apple Development: 你的名字 (TEAMID)" /path/to/profile.mobileprovision
set -euo pipefail

SRC_IPA="${1:-}"
MODE="${2:-trollstore}"
IDENTITY="${3:-}"
PROFILE="${4:-}"

if [[ -z "$SRC_IPA" || ! -f "$SRC_IPA" ]]; then
  echo "找不到输入 IPA：$SRC_IPA" >&2
  echo "用法: bash scripts/sign-ipa.sh <unsigned.ipa> [trollstore|sideload] [签名身份] [描述文件]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENT_TROLL="$ROOT/packaging/entitlements.trollstore.plist"
ENT_SIDE="$ROOT/packaging/entitlements.sideload.plist"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

unzip -q "$SRC_IPA" -d "$WORK"
APP="$(find "$WORK/Payload" -maxdepth 1 -type d -name '*.app' | head -1)"
if [[ -z "$APP" ]]; then
  echo "IPA 里没找到 .app，检查打包脚本产物" >&2
  exit 1
fi

EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
BIN="$APP/$EXEC"
[[ -f "$BIN" ]] || { echo "主程序不存在：$BIN" >&2; exit 1; }

macho_files() {
  # 先签框架/动态库，最后签主程序
  find "$APP" -type f \( -name '*.dylib' -o -path '*/Frameworks/*' \) -print
  printf '%s\n' "$BIN"
}

case "$MODE" in
  trollstore)
    if ! command -v ldid >/dev/null 2>&1; then
      echo "缺少 ldid：先执行 brew install ldid" >&2
      exit 1
    fi
    OUT_DIR="$(cd "$(dirname "$SRC_IPA")" && pwd)"
    OUT="$OUT_DIR/${BUNDLE_ID}.tipa"

    # 主程序用 TrollStore 权限；内嵌库只做 ad-hoc 伪签
    while IFS= read -r file; do
      [[ -f "$file" ]] || continue
      if [[ "$file" == "$BIN" ]]; then
        ldid -S"$ENT_TROLL" "$file"
      else
        ldid -S "$file"
      fi
    done < <(macho_files)

    rm -f "$OUT"
    (cd "$WORK" && zip --symlinks -qry "$OUT" Payload)
    echo "已生成 TrollStore 包：$OUT"
    echo "传到 iPhone 后：文件 App 长按 → 共享 → TrollStore → Install"
    echo "JIT：TrollStore 1.3+ 可在 App 内用 apple-magnifier://enable-jit?bundle-id=$BUNDLE_ID 开启"
    ;;

  sideload)
    if [[ -z "$IDENTITY" ]]; then
      echo "sideload 模式必须给签名身份，例如 \"Apple Development: 名字 (TEAMID)\"" >&2
      exit 1
    fi
    OUT_DIR="$(dirname "$SRC_IPA")"
    OUT="$OUT_DIR/${BUNDLE_ID}-signed.ipa"

    if [[ -n "$PROFILE" ]]; then
      cp "$PROFILE" "$APP/embedded.mobileprovision"
      TEAM="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$APP/embedded.mobileprovision" 2>/dev/null || true)"
      if [[ -n "$TEAM" ]]; then
        /usr/libexec/PlistBuddy -c "Set :application-identifier $TEAM.$BUNDLE_ID" "$ENT_SIDE" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Set :com.apple.developer.team-identifier $TEAM" "$ENT_SIDE" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 $TEAM.$BUNDLE_ID" "$ENT_SIDE" 2>/dev/null || true
      fi
    else
      echo "提示：没有描述文件时，increased-memory-limit 等能力会被系统忽略" >&2
    fi

    while IFS= read -r file; do
      [[ -f "$file" ]] || continue
      codesign --force --sign "$IDENTITY" --generate-entitlement-der \
        --entitlements "$ENT_SIDE" --timestamp=none "$file"
    done < <(macho_files)

    rm -f "$OUT"
    (cd "$WORK" && zip --symlinks -qry "$OUT" Payload)
    echo "已签名：$OUT"
    echo "Windows 用户：把这个 ipa 拖给 AltServer（或 SideStore）签名安装。"
    ;;

  *)
    echo "未知模式：$MODE（只支持 trollstore / sideload）" >&2
    exit 1
    ;;
esac
