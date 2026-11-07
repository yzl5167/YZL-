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
import sys
import zipfile
from collections import defaultdict

MACHO_MAGIC = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
               b"\xca\xfe\xba\xbe", b"\xcf\xfa\xed\xfe\x7fELF")
PRIVATE_KEYS = (
    b"com.apple.private.security.no-sandbox",
    b"platform-application",
    b"com.apple.private.cs.debugger",
    b"com.apple.private.skip-library-validation",
    b"dynamic-codesigning",
)


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
        if not any(head.startswith(m) for m in MACHO_MAGIC):
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

        leaked = []
        scanned = 0
        for info in infos:
            if not (info.filename.endswith((".dylib", ".framework/YZLUI"))
                    or re.search(r"/[^/]+\.(app)/[^/]+$", info.filename)):
                continue
            if info.file_size > 40 * 1024 * 1024 or info.file_size < 10000:
                continue
            scanned += 1
            try:
                blob = z.read(info.filename)
            except Exception:  # noqa: BLE001
                continue
            if any(key in blob for key in PRIVATE_KEYS):
                leaked.append(info.filename)
        note(f"私有 entitlement 扫描: {scanned} 个二进制")
        if leaked:
            errors.append(f"仍带 TrollStore 私有 entitlement 的二进制: {leaked[:5]}")
        else:
            note("OK  未发现 TrollStore 私有 entitlement")

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
