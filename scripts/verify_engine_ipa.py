#!/usr/bin/env python3
"""校验引擎 IPA 的产物完整性，失败即返回非 0。

用法：
    python3 scripts/verify_engine_ipa.py <engine.ipa> [--mode sideload|trollstore]
                                        [--report <报告路径>]

检查项：
  * YZLUI.framework/YZLUI 必须是真实 Mach-O（不能是只有资源、没有二进制的空壳）
  * JRE 8 / 17 必须真实可用（含 libjli.dylib 且体积达标），否则拒绝出包
  * JRE 21 / 25 缺席只告警并写入报告，不阻断（当前上游源确实拿不到）
  * launcher.jar、图形翻译层 dylib、Java 桥 jar 必须存在
  * sideload 模式额外要求：无 _CodeSignature / embedded.mobileprovision / CodeResources，
    且二进制里不带 TrollStore 私有 entitlement 字符串
"""

import argparse
import re
import struct
import sys
import zipfile
from collections import defaultdict

MACHO_MAGICS = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
                b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")
PRIVATE_KEYS = (
    b"com.apple.private.security.no-sandbox",
    b"platform-application",
    b"com.apple.private.cs.debugger",
    b"com.apple.private.skip-library-validation",
    b"dynamic-codesigning",
)
LC_CODE_SIGNATURE = 0x1D


def macho_has_code_signature(data):
    """判断 Mach-O 是否带 LC_CODE_SIGNATURE；非 Mach-O 返回 None。

    entitlement 只有作为代码签名 blob 的一部分才具备权限效力。因此
    「无 LC_CODE_SIGNATURE」是比「字节里有没有 entitlement 字符串」更准确的
    判据——上游常把 entitlement 名作为字符串常量编译进 __TEXT。
    """
    if len(data) < 32:
        return None
    magic = data[:4]
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        nfat = struct.unpack(">I", data[4:8])[0]
        stride = 32 if magic == b"\xca\xfe\xba\xbf" else 20
        off_at = 8 if stride == 20 else 16
        for index in range(min(nfat, 8)):
            base = 8 + index * stride
            if base + stride > len(data):
                break
            offset = struct.unpack(">I", data[base + off_at:base + off_at + 4])[0]
            size = struct.unpack(">I", data[base + off_at + 4:base + off_at + 8])[0]
            if offset + size > len(data):
                continue
            if macho_has_code_signature(data[offset:offset + size]):
                return True
        return False
    if magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
        endian = "<"
        header = 32 if magic == b"\xcf\xfa\xed\xfe" else 28
    elif magic in (b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"):
        endian = ">"
        header = 32 if magic == b"\xfe\xed\xfa\xcf" else 28
    else:
        return None
    ncmds = struct.unpack(endian + "I", data[16:20])[0]
    pos = header
    for _ in range(min(ncmds, 4096)):
        if pos + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack(endian + "II", data[pos:pos + 8])
        if cmdsize < 8:
            break
        if cmd == LC_CODE_SIGNATURE:
            return True
        pos += cmdsize
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa")
    ap.add_argument("--mode", choices=("sideload", "trollstore"), default="trollstore")
    ap.add_argument("--report", default=None)
    args = ap.parse_args()

    errors, warnings, lines = [], [], []

    def note(text):
        lines.append(text)
        print(text)

    try:
        z = zipfile.ZipFile(args.ipa)
    except Exception as exc:  # noqa: BLE001
        print(f"打不开 IPA：{exc}")
        return 2

    infos = z.infolist()
    names = {i.filename for i in infos}
    by_name = {i.filename: i for i in infos}

    note(f"校验对象: {args.ipa}")
    note(f"模式: {args.mode}")
    note(f"条目总数: {len(infos)}")

    app_root = None
    for name in names:
        m = re.match(r"^(Payload/[^/]+\.app)/Info\.plist$", name)
        if m:
            app_root = m.group(1)
            break
    if not app_root:
        errors.append("IPA 里找不到 Payload/*.app/Info.plist")
        note("IPA 里找不到 Payload/*.app/Info.plist")
        _finish(errors, warnings, lines, args.report)
        return 1
    note(f"App 根: {app_root}")

    # 1. YZLUI 二进制必须是真 Mach-O
    ui_rel = f"{app_root}/Frameworks/YZLUI.framework/YZLUI"
    ui_hit = next((n for n in names if n.endswith("Frameworks/YZLUI.framework/YZLUI")), None)
    if not ui_hit:
        errors.append("缺少 YZLUI.framework/YZLUI —— 真机只会看到 Amethyst 原生 UI")
    else:
        head = z.read(ui_hit)[:8]
        size = by_name[ui_hit].file_size
        if not any(head.startswith(m) for m in MACHO_MAGICS):
            errors.append(f"YZLUI 不是 Mach-O（前 8 字节 {head.hex()}）")
        elif size < 10000:
            errors.append(f"YZLUI 只有 {size} 字节，疑似空壳")
        else:
            note(f"OK  YZLUI 二进制 {size} 字节，Mach-O")

    # 2. JRE 完整性
    jre = defaultdict(lambda: {"count": 0, "bytes": 0, "jli": 0})
    for info in infos:
        m = re.search(r"java_runtimes/(java-(\d+)-openjdk)/", info.filename)
        if not m:
            continue
        ver = m.group(2)
        jre[ver]["count"] += 1
        jre[ver]["bytes"] += info.file_size
        # Java 8 的布局是 jli/libjli.dylib，Java 17+ 是 lib/libjli.dylib，
        # 不能写死目录，否则会把完整可用的 JRE 8 误判成空壳。
        if info.filename.endswith("/libjli.dylib"):
            jre[ver]["jli"] = max(jre[ver]["jli"], info.file_size)

    for ver in sorted(jre, key=int):
        d = jre[ver]
        note(f"JRE {ver}: {d['count']} 条目 / {d['bytes']/1024/1024:.1f} MB / "
             f"libjli.dylib {d['jli']} 字节")

    def healthy(ver):
        d = jre.get(ver)
        return bool(d and d["jli"] > 10000 and d["count"] > 20 and d["bytes"] > 20 * 1024 * 1024)

    for ver in ("8", "17"):
        if healthy(ver):
            note(f"OK  JRE {ver} 真实可用")
        else:
            errors.append(
                f"JRE {ver} 缺失或为空壳（需要 libjli.dylib + >20 条目 + >20MB）。"
                f"没有它 1.16- / 1.18-1.20.x 无法启动，拒绝出包"
            )
    for ver in ("21", "25"):
        if healthy(ver):
            note(f"OK  JRE {ver} 真实可用")
        else:
            warnings.append(
                f"JRE {ver} 缺席或为空壳：需要 Java {ver} 的版本（如 1.21+）暂不能玩，"
                f"请在安装器里选 1.20.1 及以下"
            )

    # 3. 关键引擎件
    def exists_contains(fragment, suffix=None):
        return any(fragment in n and (suffix is None or n.endswith(suffix)) for n in names)

    checks = [
        ("launcher.jar", lambda: exists_contains("launcher.jar")),
        ("Java 桥 jar (cacio)", lambda: exists_contains("cacio", ".jar")),
        ("图形翻译层 dylib", lambda: exists_contains("libEGL") or exists_contains("libGLESv2")
         or exists_contains("libgl4es")),
    ]
    for label, fn in checks:
        if fn():
            note(f"OK  {label}")
        else:
            errors.append(f"缺少 {label}")

    # 4. sideload 专属：签名必须彻底清除
    if args.mode == "sideload":
        forbidden = [n for n in names if "_CodeSignature" in n
                     or n.endswith("embedded.mobileprovision")
                     or n.endswith("/CodeResources")]
        if forbidden:
            errors.append(f"仍有 {len(forbidden)} 个签名残留（示例 {forbidden[:3]}）")
        else:
            note("OK  无 _CodeSignature / embedded.mobileprovision / CodeResources")

        still_signed = []
        string_hits = []
        scanned = 0
        for info in infos:
            if info.is_dir() or info.file_size < 4096 or info.file_size > 60 * 1024 * 1024:
                continue
            try:
                with z.open(info) as handle:
                    head = handle.read(8)
                if not any(head.startswith(m) for m in MACHO_MAGICS):
                    continue
                blob = z.read(info.filename)
            except Exception:  # noqa: BLE001
                continue
            scanned += 1
            if macho_has_code_signature(blob):
                still_signed.append(info.filename)
            if any(key in blob for key in PRIVATE_KEYS):
                string_hits.append(info.filename)
        note(f"已检查 {scanned} 个 Mach-O 的 LC_CODE_SIGNATURE")
        if still_signed:
            errors.append(
                f"仍有 {len(still_signed)} 个 Mach-O 带代码签名（私有权限可能残留）: "
                f"{still_signed[:5]}"
            )
        else:
            note("OK  所有 Mach-O 均无 LC_CODE_SIGNATURE（无有效 entitlement）")
        if string_hits:
            warnings.append(
                f"{len(string_hits)} 个二进制的 __TEXT 含 entitlement 名字符串，"
                f"属上游源码常量、不构成有效权限: {string_hits[:3]}"
            )
        else:
            note("OK  未发现私有 entitlement 字符串")

    _finish(errors, warnings, lines, args.report)
    return 1 if errors else 0


def _finish(errors, warnings, lines, report):
    lines.append("")
    lines.append(f"结果: {len(errors)} 个错误, {len(warnings)} 条告警")
    for e in errors:
        print(f"::error::{e}")
        lines.append(f"ERROR  {e}")
    for w in warnings:
        print(f"::warning::{w}")
        lines.append(f"WARN   {w}")
    if report:
        with open(report, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        print(f"报告已写入 {report}")


if __name__ == "__main__":
    sys.exit(main())
