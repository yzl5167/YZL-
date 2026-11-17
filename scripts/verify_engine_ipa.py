#!/usr/bin/env python3
"""校验引擎 IPA 的产物完整性，失败即返回非 0。

用法：
    python3 scripts/verify_engine_ipa.py <engine.ipa> [--mode sideload|trollstore]
                                        [--report <报告路径>]

检查项：
  * YZLUI.framework/YZLUI 必须是真实 Mach-O（不能是只有资源、没有二进制的空壳）
  * 全架构门禁：引擎主二进制、YZLUI、以及每个 JRE 的 libjli/libjvm 都必须含
    arm64 切片（CPU_TYPE_ARM64 = 0x0100000C）。所有 iPhone/iPad 都是 arm64/arm64e，
    arm64e 能运行 arm64 二进制，因此单个 arm64 切片即覆盖**全部** iOS 机型；
    纯 x86_64 / armv7 的二进制在任何真机上都会 SIGILL，必须拒绝出包。
  * JRE 8 / 17 / 21 必须真实可用（含 libjli.dylib 且体积达标），否则拒绝出包
    （2026-11-17 起 21 已有可用的 iOS 真源，1.21+ 版本依赖它，不能再缺）
  * JRE 25 缺席只告警并写入报告，不阻断（官方无 iOS 构建，当前为实验性转换）
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

# Mach-O cputype：arm64 覆盖全部在役 iOS 机型（A7 起的 arm64 与 A12 起的 arm64e，
# arm64e 设备可正常运行 arm64 二进制）。x86_64 只存在于模拟器，真机会直接崩。
CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPE_X86_64 = 0x01000007
CPU_TYPE_ARM = 0x0000000C
CPU_TYPE_I386 = 0x00000007
CPU_ARCH_ABI64 = 0x01000000


def macho_cpu_types(data):
    """解析 Mach-O（thin 或 fat）里所有切片的 cputype，返回整数集合。

    非 Mach-O 返回空集合。用于架构门禁：必须是 arm64，且不能是纯 x86_64/armv7。
    """
    types = set()
    if len(data) < 8:
        return types
    magic = data[:4]
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):  # FAT_MAGIC / FAT_CIGAM
        nfat = struct.unpack(">I", data[4:8])[0]
        stride = 32 if magic == b"\xca\xfe\xba\xbf" else 20
        for index in range(min(nfat, 16)):
            base = 8 + index * stride
            if base + stride > len(data):
                break
            cputype = struct.unpack(">I", data[base:base + 4])[0]
            types.add(cputype)
        return types
    if magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                 b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"):
        endian = "<" if magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe") else ">"
        types.add(struct.unpack(endian + "I", data[4:8])[0])
    return types


def arch_report(types):
    names = []
    for t in sorted(types):
        if t == CPU_TYPE_ARM64:
            names.append("arm64")
        elif t == CPU_TYPE_X86_64:
            names.append("x86_64")
        elif t == CPU_TYPE_ARM:
            names.append("armv7")
        elif t == CPU_TYPE_I386:
            names.append("i386")
        else:
            names.append(hex(t))
    return "/".join(names) if names else "非 Mach-O"


def check_arm64(label, data, errors, note):
    """单个 Mach-O 的架构门禁。返回 True 表示可做后续校验。"""
    types = macho_cpu_types(data)
    if not types:
        errors.append(f"{label} 不是可解析的 Mach-O，无法确认架构")
        note(f"FAIL {label} 架构解析失败")
        return False
    if CPU_TYPE_ARM64 not in types:
        errors.append(
            f"{label} 缺 arm64 切片（实际 {arch_report(types)}）——"
            f"只有 arm64 能覆盖所有 iPhone/iPad，其它架构在真机会崩溃"
        )
        note(f"FAIL {label} 架构 {arch_report(types)}")
        return False
    # 允许 fat 里同时带模拟器切片（那是构建副产物，不影响真机），
    # 但只要含 arm64 就满足全机型要求。
    note(f"OK  {label} 架构 {arch_report(types)}（含 arm64，覆盖全部 iOS 机型）")
    return True


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
        ui_bytes = z.read(ui_hit)
        size = by_name[ui_hit].file_size
        if not any(ui_bytes[:8].startswith(m) for m in MACHO_MAGICS):
            errors.append(f"YZLUI 不是 Mach-O（前 8 字节 {ui_bytes[:8].hex()}）")
        elif size < 10000:
            errors.append(f"YZLUI 只有 {size} 字节，疑似空壳")
        else:
            note(f"OK  YZLUI 二进制 {size} 字节，Mach-O")
            check_arm64("YZLUI.framework/YZLUI", ui_bytes, errors, note)

    # 1b. 引擎主二进制架构门禁（fork 的 Mach-O，全机型跑的就是它）
    engine_hit = next(
        (n for n in names if re.match(r"^" + re.escape(app_root) + r"/AngelAuraAmethyst$", n)),
        None,
    )
    if not engine_hit:
        errors.append("缺少引擎主二进制 AngelAuraAmethyst")
    else:
        check_arm64("AngelAuraAmethyst（引擎主二进制）", z.read(engine_hit), errors, note)

    # 2. JRE 完整性 + 架构门禁
    jre = defaultdict(lambda: {"count": 0, "bytes": 0, "jli": 0})
    jre_macho = {}  # ver -> [(label, bytes), ...]
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
            jre_macho.setdefault(ver, []).append(
                (f"JRE {ver} libjli.dylib", z.read(info.filename)))
        if info.filename.endswith("/libjvm.dylib"):
            jre_macho.setdefault(ver, []).append(
                (f"JRE {ver} libjvm.dylib", z.read(info.filename)))

    # 每个 JRE 的核心二进制都必须是 arm64，否则该版本一启动就 SIGILL。
    for ver, machos in sorted(jre_macho.items(), key=lambda kv: int(kv[0])):
        for label, data in machos:
            check_arm64(label, data, errors, note)

    for ver in sorted(jre, key=int):
        d = jre[ver]
        note(f"JRE {ver}: {d['count']} 条目 / {d['bytes']/1024/1024:.1f} MB / "
             f"libjli.dylib {d['jli']} 字节")

    def healthy(ver):
        d = jre.get(ver)
        return bool(d and d["jli"] > 10000 and d["count"] > 20 and d["bytes"] > 20 * 1024 * 1024)

    for ver, why in (("8", "1.16-"), ("17", "1.18-1.20.x"), ("21", "1.21+")):
        if healthy(ver):
            note(f"OK  JRE {ver} 真实可用")
        else:
            errors.append(
                f"JRE {ver} 缺失或为空壳（需要 libjli.dylib + >20 条目 + >20MB）。"
                f"没有它 {why} 无法启动，拒绝出包"
            )
    # 25 无官方 iOS 构建，build-engine.sh 里是 macOS JDK 的实验性转换，
    # 即便暂存成功也可能在真机跑不起来，因此只告警、不阻断出包。
    if healthy("25"):
        note("OK  JRE 25 存在（实验性转换，真机兼容性未验证）")
    else:
        warnings.append(
            "JRE 25 缺席或为空壳：官方无 iOS 构建，且没有 Minecraft 版本需要 Java 25，"
            "可忽略"
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
