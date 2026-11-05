#!/usr/bin/env bash
# 由已签名的 IPA 生成 OTA 安装用的 manifest.plist（itms-services 安装页用）。
# 需要 macOS（读 IPA 里的 Info.plist）。
#
# 用法：
#   bash scripts/make-ota-manifest.sh <signed.ipa> <https 下载地址前缀> [图标512.png]
# 例：
#   bash scripts/make-ota-manifest.sh dist/app-signed.ipa https://dl.example.com/yzl/
#
# 产物：与 IPA 同目录的 manifest.plist，以及一行可直接点开的 itms-services 链接。
set -euo pipefail

IPA="${1:-}"
BASE_URL="${2:-}"
ICON="${3:-}"

if [[ -z "$IPA" || -z "$BASE_URL" ]]; then
  echo "用法: bash scripts/make-ota-manifest.sh <signed.ipa> <https 下载地址前缀> [图标png]" >&2
  exit 1
fi
[[ -f "$IPA" ]] || { echo "找不到 IPA：$IPA" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/packaging/manifest.template.plist"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$IPA" -d "$WORK"
APP="$(find "$WORK/Payload" -maxdepth 1 -type d -name '*.app' | head -1)"
[[ -n "$APP" ]] || { echo "IPA 里没有 .app" >&2; exit 1; }

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"

BASE_URL="${BASE_URL%/}/"
IPA_NAME="$(basename "$IPA")"
OUT="$(dirname "$IPA")/manifest.plist"

cp "$TEMPLATE" "$OUT"
/usr/libexec/PlistBuddy -c "Set :items:0:assets:0:url ${BASE_URL}${IPA_NAME}" "$OUT"
/usr/libexec/PlistBuddy -c "Set :items:0:metadata:bundle-identifier ${BUNDLE_ID}" "$OUT"
/usr/libexec/PlistBuddy -c "Set :items:0:metadata:bundle-version ${VERSION}" "$OUT"

if [[ -n "$ICON" && -f "$ICON" ]]; then
  ICON_NAME="$(basename "$ICON")"
  /usr/libexec/PlistBuddy -c "Set :items:0:assets:1:url ${BASE_URL}${ICON_NAME}" "$OUT"
  /usr/libexec/PlistBuddy -c "Set :items:0:assets:2:url ${BASE_URL}${ICON_NAME}" "$OUT"
else
  # 没有图标就把两条 display-image 指回 IPA，iOS 会忽略无效图标但不会拒绝安装
  /usr/libexec/PlistBuddy -c "Set :items:0:assets:1:url ${BASE_URL}${IPA_NAME}" "$OUT"
  /usr/libexec/PlistBuddy -c "Set :items:0:assets:2:url ${BASE_URL}${IPA_NAME}" "$OUT"
fi

echo "manifest: $OUT"
echo "安装链接: itms-services://?action=download-manifest&url=${BASE_URL}manifest.plist"
echo "把这个链接放进网页 <a> 里，用 Safari 打开即可安装（HTTPS 必须有效证书）。"
