#!/usr/bin/env python3
"""修复上游 Amethyst JavaApp/Makefile 的 check_empty_classes 并行竞态。

上游写法：
    launcher.jar: $(CLASSES) check_empty_classes

$(CLASSES) 与 check_empty_classes 是并列依赖，make -jN 会同时启动它们，
检查会抢在 javac 写完 .class 之前执行，把正在创建的 0 字节文件误判成
编译失败（日志表现为 "Error: found empty class files"）。

让 check_empty_classes 显式依赖 $(CLASSES) 即可强制串行化。幂等：
已打过补丁或上游已自行修复时直接跳过。

用法: python3 engine/fix-check-empty-classes.py <JavaApp/Makefile 路径>
"""
import sys

TARGET = "check_empty_classes:"
PATCHED = "check_empty_classes: $(CLASSES)"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "JavaApp/Makefile"
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines(keepends=True)

    if any(PATCHED in line for line in lines):
        print("[patch] 竞态已修复，跳过")
        return 0

    for index, line in enumerate(lines):
        if line.strip() == TARGET:
            lines[index] = line.replace(TARGET, PATCHED)
            break
    else:
        print("::error::上游 JavaApp/Makefile 找不到 check_empty_classes 目标，需人工核对")
        return 1

    with open(path, "w", encoding="utf-8") as handle:
        handle.writelines(lines)
    print("[patch] check_empty_classes 已依赖 $(CLASSES)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
