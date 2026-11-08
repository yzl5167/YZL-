import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// JIT 可用性探测。
///
/// 真实具备 JIT 的只有两种情况：
/// 1. **TrollStore 安装**：CoreTrust 绕过让进程被当作平台签名（CS_PLATFORM_BINARY）；
/// 2. **调试器附加**（StikDebug / SideJITServer / AltServer）：进程带 CS_DEBUGGED。
/// 普通侧载（免费/企业证书）两者皆无，JIT 不可用。
///
/// 为什么不能只测 mprotect RWX：实测（2026-11-08，用户侧载设备反馈）内核会
/// **静默剥离**匿名页的执行权限——mprotect 返回成功但实际不可执行，造成假阳性。
/// 因此以 csops 代码签名标志为准，mprotect 只作 csops 不可用时的兜底。
enum JITProbe {
    typealias Probe = () -> Bool

    // csops 的操作码与标志位（sys/codesign.h，SDK 未公开，按稳定 ABI 手写）。
    private static let CS_OPS_STATUS: UInt32 = 0
    private static let CS_PLATFORM_BINARY: UInt32 = 0x0400_0000
    private static let CS_DEBUGGED: UInt32 = 0x1000_0000

    /// 读取本进程的代码签名标志；csops 不可用（符号缺失/调用失败）返回 nil。
    private static func codeSigningFlags() -> UInt32? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else {
            return nil
        }
        typealias CSOpsFn = @convention(c) (Int32, UInt32, UnsafeMutableRawPointer, Int) -> Int32
        let csops = unsafeBitCast(symbol, to: CSOpsFn.self)
        var flags: UInt32 = 0
        guard csops(getpid(), CS_OPS_STATUS, &flags, MemoryLayout<UInt32>.size) == 0 else {
            return nil
        }
        return flags
    }

    /// csops 标志判定：平台签名（TrollStore）或调试器附加才有真 JIT。
    static func systemProbe() -> Bool {
        #if canImport(Darwin)
        if let flags = codeSigningFlags() {
            return flags & CS_PLATFORM_BINARY != 0 || flags & CS_DEBUGGED != 0
        }
        // csops 不可用时退回 mprotect 探测（老行为，可能假成功，但聊胜于无）。
        return mprotectProbe()
        #else
        return false
        #endif
    }

    /// 老的 mprotect 探测：在部分侧载环境会假成功，仅作兜底保留。
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

    static func detect(using probe: Probe = JITProbe.systemProbe) -> JITStatus {
        probe() ? .enabled : .disabled
    }
}
