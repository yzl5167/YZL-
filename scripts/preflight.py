#!/usr/bin/env python3
"""Windows / macOS 都能跑的静态自检。

本机没有 Xcode 和 Swift 编译器，云构建一轮要几分钟，所以把能在本地查的
问题先查掉：括号配平、JSON/plist 可解析、已知会编译失败的 API 写法。

用法: python3 scripts/preflight.py
出问题退出码 1，适合挂在 GitHub Actions 的编译步骤之前。
"""
from __future__ import annotations

import json
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SWIFT_DIRS = [ROOT / "YZLLauncher", ROOT / "Tests"]

# 这些写法在之前的云构建里真实炸过，列成黑名单防止回潮。
FORBIDDEN = [
    (
        r"setInterpolationQuality\s*\(",
        "Swift 的 CGContext 没有 setInterpolationQuality(_:)，改用 interpolationQuality = .none",
    ),
    (
        r"SkinTexture\.head\(from:\s*phase\.image",
        "AsyncImage 的 phase.image 是 SwiftUI.Image，不能传给需要 UIImage 的裁剪函数",
    ),
]

PAIRS = {")": "(", "]": "[", "}": "{"}
OPENERS = set("([{")
CLOSERS = set(")]}")


def line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def bracket_error(text: str) -> str | None:
    """注释/字符串感知的括号配平。字符串插值内的括号整体忽略，避免误报。"""
    stack: list[tuple[str, int]] = []
    i = 0
    n = len(text)
    state = "code"
    block_depth = 0

    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if state == "code":
            if c == "/" and nxt == "/":
                state = "line"
                i += 2
                continue
            if c == "/" and nxt == "*":
                state = "block"
                block_depth = 1
                i += 2
                continue
            if text.startswith('"""', i):
                state = "multiline_string"
                i += 3
                continue
            if c == '"':
                state = "string"
                i += 1
                continue
            if c in OPENERS:
                stack.append((c, line_of(text, i)))
            elif c in CLOSERS:
                if not stack or stack[-1][0] != PAIRS[c]:
                    return f"第 {line_of(text, i)} 行出现多余的 {c!r}"
                stack.pop()
            i += 1

        elif state == "line":
            if c == "\n":
                state = "code"
            i += 1

        elif state == "block":
            if c == "/" and nxt == "*":
                block_depth += 1
                i += 2
                continue
            if c == "*" and nxt == "/":
                block_depth -= 1
                i += 2
                if block_depth == 0:
                    state = "code"
                continue
            i += 1

        elif state == "string":
            if c == "\\":
                i += 2
                continue
            if c == '"':
                state = "code"
            i += 1

        elif state == "multiline_string":
            if text.startswith('"""', i):
                state = "code"
                i += 3
                continue
            if c == "\\":
                i += 2
                continue
            i += 1

    if state in {"string", "multiline_string", "block"}:
        return f"文件结束时仍处于 {state} 状态，字符串或注释没有闭合"
    if stack:
        opener, line = stack[-1]
        return f"第 {line} 行的 {opener!r} 没有闭合"
    return None


def main() -> int:
    problems: list[str] = []
    counts = {"swift": 0, "json": 0, "plist": 0, "sh": 0, "ps1": 0}

    swift_files = sorted(
        path for directory in SWIFT_DIRS if directory.exists()
        for path in directory.rglob("*.swift")
    )
    counts["swift"] = len(swift_files)

    for path in swift_files:
        text = path.read_text(encoding="utf-8-sig")
        rel = path.relative_to(ROOT)
        error = bracket_error(text)
        if error:
            problems.append(f"{rel}: 括号不配平 —— {error}")

        # 说明文档里出现旧 API 名称是正常且必要的，只扫描代码行。
        scan_text = "\n".join(
            "" if line.lstrip().startswith("//") else line
            for line in text.splitlines()
        )
        for pattern, reason in FORBIDDEN:
            for match in re.finditer(pattern, scan_text):
                problems.append(
                    f"{rel}:{line_of(scan_text, match.start())}: {reason}"
                )

    for path in sorted(ROOT.rglob("*.json")):
        if ".git" in path.parts:
            continue
        counts["json"] += 1
        try:
            json.loads(path.read_text(encoding="utf-8-sig"))
        except Exception as exc:
            problems.append(f"{path.relative_to(ROOT)}: JSON 解析失败 —— {exc}")

    for path in sorted((ROOT / "packaging").glob("*.plist")):
        counts["plist"] += 1
        try:
            with path.open("rb") as handle:
                plistlib.load(handle)
        except Exception as exc:
            problems.append(f"{path.relative_to(ROOT)}: plist 解析失败 —— {exc}")

    # Windows PowerShell 5.1 对无 BOM 的 UTF-8 按 GBK 读取，含中文的脚本会乱码甚至语法错。
    # 这个坑在本项目里踩过多次，列成强制检查项。
    for path in sorted((ROOT / "scripts").glob("*.ps1")):
        counts["ps1"] += 1
        raw = path.read_bytes()
        rel = path.relative_to(ROOT)
        try:
            decoded = raw.decode("utf-8-sig")
        except UnicodeDecodeError:
            problems.append(f"{rel}: ps1 不是有效的 UTF-8")
            continue
        if any(ord(ch) > 127 for ch in decoded) and not raw.startswith(b"\xef\xbb\xbf"):
            problems.append(f"{rel}: 含中文但缺少 UTF-8 BOM，PowerShell 5.1 会乱码")

    bash = shutil.which("bash")
    if bash:
        sh_paths = sorted((ROOT / "scripts").glob("*.sh")) + sorted((ROOT / "engine").rglob("*.sh"))
        for path in sh_paths:
            counts["sh"] += 1
            result = subprocess.run(
                [bash, "-n", str(path)], capture_output=True, text=True
            )
            if result.returncode != 0:
                problems.append(
                    f"{path.relative_to(ROOT)}: shell 语法错误 —— {result.stderr.strip()}"
                )

    for required in ["project.yml", "YZLLauncher", "Tests", "scripts", "packaging", "engine"]:
        if not (ROOT / required).exists():
            problems.append(f"缺少必需路径：{required}")

    print(
        "[preflight] "
        + " · ".join(f"{key} {value}" for key, value in counts.items())
    )
    if problems:
        for problem in problems:
            print(f"[preflight] FAIL {problem}")
        print(f"[preflight] 共 {len(problems)} 项问题")
        return 1

    print("[preflight] OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
