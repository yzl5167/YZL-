#!/usr/bin/env bash
# 从 Amethyst 构建出的 artifacts/ 目录（内含 Payload/）生成「干净未签名」IPA。
#
# 用途：iOS 17.4+ / 18.x 不走 TrollStore 时，用 SideStore / AltStore / 轻松签
#       以个人开发证书重签安装。这是唯一能被这些工具正常重签的形态。
#
# 与 YZL-engine.tipa 的区别：
#   tipa  : ldid 伪签 + TrollStore 私有 entitlement（no-sandbox / platform-application
#           / increased-memory-limit ...），只有 TrollStore 能装；交给轻松签会
#           在安装阶段被拒，这正是历史「安装失败，稍后再试」的根因。
#   sideload: 剥离全部 LC_CODE_SIGNATURE（私有 entitlement 随签名一起消失），
#           删除 _CodeSignature / embedded.mobileprovision / CodeResources，
#           不预置任何 entitlement。重签工具用自己的开发证书写入
#           get-task-allow，JIT 由 StikDebug / SideJITServer 调试器附加获得。
#
# 注意：本脚本必须在 macOS 上运行（依赖 codesign / PlistBuddy / file）。
#
# 用法：bash scripts/make-sideload-ipa.sh <artifacts 目录> <输出 .ipa 绝对路径>
set -euo pipefail

ARTIFACTS="${1:-}"
OUT_IPA="${2:-}"

if [[ -z "$ARTIFACTS" || -z "$OUT_IPA" ]]; then
  echo "用法: bash scripts/make-sideload-ipa.sh <artifacts 目录> <输出 .ipa>" >&2
  exit 2
fi
if [[ ! -d "$ARTIFACTS/Payload" ]]; then
  echo "找不到 $ARTIFACTS/Payload" >&2
  exit 1
fi
if ! command -v codesign >/dev/null 2>&1; then
  echo "缺少 codesign：本脚本只能在 macOS 上运行" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 复制 Payload（保留符号链接与文件权限）"
cp -a "$ARTIFACTS/Payload" "$WORK/Payload"

APP="$(find "$WORK/Payload" -maxdepth 1 -type d -name '*.app' | head -1)"
if [[ -z "$APP" ]]; then
  echo "Payload 里没有 .app" >&2
  exit 1
fi
EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
MAIN_BIN="$APP/$EXEC"
if [[ ! -f "$MAIN_BIN" ]]; then
  echo "主程序不存在：$MAIN_BIN" >&2
  exit 1
fi

echo "==> 剥离所有 Mach-O 的代码签名"
MACHO_COUNT=0
FOUND_LIST="$WORK/macho.list"
: > "$FOUND_LIST"
# -type f 不跟随符号链接，避免对同一 Mach-O 重复处理；真实文件仍在 Versions/A 下被找到。
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" 2>/dev/null | grep -q 'Mach-O'; then
    printf '%s\n' "$candidate" >> "$FOUND_LIST"
    # 未签名的文件会返回非 0，属于正常情况
    codesign --remove-signature "$candidate" >/dev/null 2>&1 || true
  fi
done < <(find "$WORK/Payload" -type f -print0)
MACHO_COUNT="$(wc -l < "$FOUND_LIST" | tr -d ' ')"
echo "    已处理 $MACHO_COUNT 个 Mach-O"

echo "==> 删除签名残留"
find "$WORK/Payload" -type d -name '_CodeSignature' -prune -exec rm -rf '{}' + 2>/dev/null || true
find "$WORK/Payload" -type f \( -name 'CodeResources' -o -name 'embedded.mobileprovision' -o -name '*.entitlements' \) -delete 2>/dev/null || true

echo "==> 校验私有 entitlement 已清除"
PRIVATE_PATTERN='com\.apple\.private|platform-application|no-sandbox|dynamic-codesigning|skip-library-validation'
LEAK=0
while IFS= read -r macho; do
  ENT="$(codesign -d --entitlements :- "$macho" 2>/dev/null || true)"
  if printf '%s' "$ENT" | grep -qE "$PRIVATE_PATTERN"; then
    echo "::error::仍带私有 entitlement: ${macho#$WORK/}"
    LEAK=1
  fi
done < "$FOUND_LIST"

# 兜底：如果 codesign 没能移除 ldid 写入的 ad-hoc 签名，用 ldid 无 entitlement 重签一次。
if [[ "$LEAK" -ne 0 ]] && command -v ldid >/dev/null 2>&1; then
  echo "    codesign 剥离不彻底，改用 ldid 中性重签"
  while IFS= read -r macho; do
    ldid -S "$macho" >/dev/null 2>&1 || true
  done < "$FOUND_LIST"
  LEAK=0
  while IFS= read -r macho; do
    ENT="$(codesign -d --entitlements :- "$macho" 2>/dev/null || true)"
    if printf '%s' "$ENT" | grep -qE "$PRIVATE_PATTERN"; then
      echo "::error::ldid 重签后仍带私有 entitlement: ${macho#$WORK/}"
      LEAK=1
    fi
  done < "$FOUND_LIST"
fi
if [[ "$LEAK" -ne 0 ]]; then
  echo "私有 entitlement 清除失败，拒绝产出会被重签工具拒绝的包" >&2
  exit 1
fi

if find "$WORK/Payload" \( -name '_CodeSignature' -o -name 'embedded.mobileprovision' \) -print | grep -q .; then
  echo "签名残留未清理干净" >&2
  exit 1
fi

echo "==> 主程序签名状态（应显示 not signed）"
codesign -dvv "$MAIN_BIN" 2>&1 | head -6 || true

echo "==> 打包"
rm -f "$OUT_IPA"
mkdir -p "$(dirname "$OUT_IPA")"
(cd "$WORK" && zip -qry "$OUT_IPA" Payload)

echo "已生成干净未签名 IPA：$OUT_IPA"
echo "大小：$(du -h "$OUT_IPA" | cut -f1)"
echo "用 SideStore / AltStore / 轻松签 以个人开发证书重签后安装。"
echo "JIT：安装后每次启动前用 StikDebug（+ LocalDevVPN）或 SideJITServer 附加开启。"
