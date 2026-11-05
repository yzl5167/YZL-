import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// JIT 可用性探测。
///
/// iOS 普通沙箱不允许把一页内存同时设为可写可执行；TrollStore 永久签名
/// 或调试器附加（StikDebug / SideJITServer）开启 JIT 后才会成功。
/// 探测逻辑通过闭包注入，单元测试不依赖真机权限。
enum JITProbe {
    typealias Probe = () -> Bool

    static func systemProbe() -> Bool {
        #if canImport(Darwin)
        let size = Int(getpagesize())
        let failed = UnsafeMutableRawPointer(bitPattern: -1)
        guard let base = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              base != failed else {
            return false
        }
        defer { munmap(base, size) }
        return mprotect(base, size, PROT_READ | PROT_WRITE | PROT_EXEC) == 0
        #else
        return false
        #endif
    }

    static func detect(using probe: Probe = JITProbe.systemProbe) -> JITStatus {
        probe() ? .enabled : .disabled
    }
}
