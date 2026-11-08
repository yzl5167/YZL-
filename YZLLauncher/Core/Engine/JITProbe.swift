import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// JIT 可用性探测——**如实检测本机能力，不猜获取方式**。
///
/// 获取 JIT 的途径很多：TrollStore、越狱（AMFI 放行）、带 JIT entitlement 的
/// 签名方式、调试器附加（StikDebug / SideJITServer）等。这里不枚举来源，
/// 只对内核做两条真实的能力测试，任一成功即认为本机可用 JIT：
///
/// 1. **MAP_JIT 分配**：`mmap(PROT_EXEC | MAP_JIT)`——这是带 JIT entitlement
///    的签名方式（如 allow-jit）所走的正规通道，普通签名会被 EPERM 拒绝；
/// 2. **mprotect 加执行位**：先 RW 匿名页再 `mprotect` 加 X——TrollStore /
///    越狱内核放行的环境下会成功，普通签名失败。
///
/// 两条都不涉及执行代码，探测本身不会触发代码签名击杀，安全。
/// 上个版本的 csops 白名单已移除：它会对越狱等「非平台签名但有 JIT」的
/// 设备产生假阴性，与「如实检测」的目标相悖。
enum JITProbe {
    typealias Probe = () -> Bool

    /// MAP_JIT 在 arm64 的值（iOS SDK 未公开该常量，按稳定 ABI 手写）。
    private static let MAP_JIT: Int32 = 0x800

    /// 路径一：MAP_JIT 匿名分配（带 JIT entitlement 的签名方式走这条）。
    static func mapJITProbe() -> Bool {
        let size = Int(getpagesize())
        let failed = UnsafeMutableRawPointer(bitPattern: -1)
        guard let base = mmap(nil, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                              MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0),
              base != failed else {
            return false
        }
        defer { munmap(base, size) }
        return true
    }

    /// 路径二：mprotect 给匿名页加执行位（TrollStore / 越狱内核放行走这条）。
    static func mprotectProbe() -> Bool {
        let size = Int(getpagesize())
        let failed = UnsafeMutableRawPointer(bitPattern: -1)
        guard let base = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              base != failed else {
            return false
        }
        defer { munmap(base, size) }
        return mprotect(base, size, PROT_READ | PROT_WRITE | PROT_EXEC) == 0
    }

    static func systemProbe() -> Bool {
        #if canImport(Darwin)
        return mapJITProbe() || mprotectProbe()
        #else
        return false
        #endif
    }

    static func detect(using probe: Probe = JITProbe.systemProbe) -> JITStatus {
        probe() ? .enabled : .disabled
    }
}
