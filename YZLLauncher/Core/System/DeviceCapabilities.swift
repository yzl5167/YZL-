import Foundation
import os

enum InstallRoute: String, Equatable {
    /// TrollStore 兼容：免电脑、永久签名、App 内可自开 JIT
    case trollStore
    /// 需要电脑：AltStore/SideStore 签名 + AltServer/SideJITServer/StikDebug 开 JIT
    case computerSign
    /// 低于本 App 最低系统版本
    case unsupportedOld
}

/// 运行时能力探测：决定"这台设备该怎么装、JVM 能给多少内存"。
/// 目的是同一个二进制服务尽可能多的 iOS 版本，而不是一台机器一套配置。
enum DeviceCapabilities {
    static var systemMajorMinor: (major: Int, minor: Int) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return (version.majorVersion, version.minorVersion)
    }

    /// `kern.osversion` 是构建号，例如 iOS 16.7 RC 为 20H18。
    static var osBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    /// TrollStore 官方支持范围：14.0 beta 2 – 16.6.1、16.7 RC (20H18)、17.0。
    /// 本 App 最低 iOS 15，所以从 15.x 起算；16.7 正式版不在支持列表里。
    static func installRoute(major: Int, minor: Int, build: String) -> InstallRoute {
        if major < 15 { return .unsupportedOld }
        if major >= 18 { return .computerSign }
        if major == 17 { return minor == 0 ? .trollStore : .computerSign }
        if major == 16 {
            if minor <= 6 { return .trollStore }
            if minor == 7 && build.range(of: "20H18") != nil { return .trollStore }
            return .computerSign
        }
        return .trollStore
    }

    static var route: InstallRoute {
        let version = systemMajorMinor
        return installRoute(major: version.major, minor: version.minor, build: osBuild)
    }

    static var physicalMemoryMB: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory / 1_048_576)
    }

    /// 当前进程真实可用的内存上限；`increased-memory-limit` 是否生效会直接体现在这里。
    static var processMemoryLimitMB: Int64 {
        Int64(os_proc_available_memory() / 1_048_576)
    }

    /// JVM 堆建议值：可用上限的 40%，夹在 512–2048 MB。
    /// 免费个人签名拿不到内存上限能力，这里会自动退回保守值。
    static func recommendedHeapMB(processLimitMB: Int64, physicalMB: Int64) -> Int {
        let base: Int64
        if processLimitMB > 0 {
            base = processLimitMB
        } else {
            base = Int64(Double(physicalMB) * 0.5)
        }
        let heap = Int64(Double(base) * 0.4)
        return Int(max(512, min(2048, heap)))
    }

    static var recommendedHeapMB: Int {
        recommendedHeapMB(processLimitMB: processMemoryLimitMB, physicalMB: physicalMemoryMB)
    }

    /// 通用包的安全堆上限：按「当前进程真实可用内存」封顶，让同一个二进制
    /// 在 3GB 老设备和大内存 iPad 上都能自动收敛，不需要按机型出包或手工调参。
    /// 取可用内存的 60%（给 JVM 元空间、native 库和渲染器留余量），夹在 1024–4096 MB。
    /// 拿不到读数时退回 4096，保持原来的行为。
    static func maxSafeHeapMB(processLimitMB: Int64) -> Int {
        guard processLimitMB > 0 else { return 4096 }
        let cap = Int(Double(processLimitMB) * 0.6)
        return max(1024, min(4096, cap))
    }

    static var maxSafeHeapMB: Int {
        maxSafeHeapMB(processLimitMB: processMemoryLimitMB)
    }

    static var routeHint: String {
        switch route {
        case .trollStore:
            return "TrollStore：免电脑、永久签名、可自动开 JIT"
        case .computerSign:
            return "需要电脑：AltStore/SideStore 签名 + 附加开 JIT"
        case .unsupportedOld:
            return "系统低于 iOS 15，请升级后再安装"
        }
    }
}
