import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// JIT 可用性探测——**逐条移植引擎本体 Amethyst 的 `isJITEnabled`**（Natives/utils.m），
/// 保证外壳显示的状态与引擎实际判定完全一致。
///
/// 真实具备 JIT 的三条路径：
/// 1. 进程带 `dynamic-codesigning` entitlement（部分签名/重打包方式会带上）；
/// 2. 越狱设备（substrate / dyld 钩子 / 平台位 / /Applications 目录任一命中）；
/// 3. `csops` 查到 `CS_DEBUGGED`（TrollStore 启动或调试器附加）。
/// iOS 26+ 带 TXM 的设备还要求调试器保持附加（getppid != launchd）。
///
/// 不再使用 mmap/mprotect 探测：惰性分配在普通侧载环境会假成功
/// （2026-11-08 用户实测：侧载未配对却显示已启用）。
enum JITProbe {
    typealias Probe = () -> Bool

    private static let CS_OPS_STATUS: UInt32 = 0
    private static let CS_PLATFORM_BINARY: UInt32 = 0x0400_0000
    private static let CS_DEBUGGED: UInt32 = 0x1000_0000

    private static let FLAG_IS_IOS_26: UInt32 = 1
    private static let FLAG_FORCE_MIRRORED: UInt32 = 2
    private static let FLAG_HAS_TXM: UInt32 = 4

    static func systemProbe() -> Bool {
        #if canImport(Darwin)
        return isJITEnabled(checkCSFlags: false)
        #else
        return false
        #endif
    }

    // MARK: - isJITEnabled（Amethyst utils.m 原样移植）

    static func isJITEnabled(checkCSFlags: Bool) -> Bool {
        if !checkCSFlags, hasDynamicCodesigningEntitlement() || isJailbroken() {
            return true
        }

        guard let flags = csopsFlags() else { return false }
        if flags & CS_DEBUGGED == 0 {
            return false
        }
        if deviceJITFlags() & (FLAG_FORCE_MIRRORED | FLAG_HAS_TXM) != (FLAG_FORCE_MIRRORED | FLAG_HAS_TXM) {
            // iOS 26 以下、或无 TXM 的设备：CS_DEBUGGED 已经足够。
            return true
        }
        // iOS 26+ 带 TXM：需要调试器保持附加（父进程不是 launchd）。
        return getppid() != 1
    }

    // MARK: - csops

    /// `pid` 传 0 等价于当前进程（与 Amethyst 的 csops(0, ...) 一致）。
    private static func csopsFlags(pid: Int32 = getpid()) -> UInt32? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else {
            return nil
        }
        typealias CSOpsFn = @convention(c) (Int32, UInt32, UnsafeMutableRawPointer, Int) -> Int32
        let csops = unsafeBitCast(symbol, to: CSOpsFn.self)
        var flags: UInt32 = 0
        guard csops(pid, CS_OPS_STATUS, &flags, MemoryLayout<UInt32>.size) == 0 else {
            return nil
        }
        return flags
    }

    // MARK: - entitlement 检查（Amethyst getEntitlementValue 的 Swift 版）

    private static func hasDynamicCodesigningEntitlement() -> Bool {
        entitlementBool("dynamic-codesigning")
    }

    private static func entitlementBool(_ key: String) -> Bool {
        guard let createSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecTaskCreateFromSelf"),
              let copySym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecTaskCopyValueForEntitlement") else {
            return false
        }
        typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        typealias CopyFn = @convention(c) (UnsafeMutableRawPointer?, CFString, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> Unmanaged<CFTypeRef>?
        let create = unsafeBitCast(createSym, to: CreateFn.self)
        let copy = unsafeBitCast(copySym, to: CopyFn.self)

        guard let task = create(nil) else { return false }
        defer { deallocateSecTask(task) }
        var out: Unmanaged<CFTypeRef>?
        guard let retained = copy(task, key as CFString, &out) else { return false }
        let value = retained.takeRetainedValue() as Any
        // 与 ObjC 版一致：非数字值视为 true；数字值取 boolValue。
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return true
    }

    /// SecTaskRef 是 +0 返回的 CF 对象，这里手动释放（不直接暴露 CFRelease 类型细节）。
    private static func deallocateSecTask(_ task: UnsafeMutableRawPointer) {
        guard let releaseSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CFRelease") else { return }
        typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
        let release = unsafeBitCast(releaseSym, to: ReleaseFn.self)
        release(task)
    }

    // MARK: - 越狱检测（Amethyst init_checkForJailbreak 原样移植）

    static func isJailbroken() -> Bool {
        if ProcessInfo.processInfo.isMacCatalystApp {
            // macOS 不会自动开 JIT。
            return false
        }
        if isSubstrated() {
            return true
        }

        // posix_spawn 是否被越狱钩子替换。
        let imageCount = Int(dyldImageCount())
        for index in 0..<imageCount {
            guard let name = dyldImageName(UInt32(index)) else { continue }
            let path = String(cString: name)
            if path == "/usr/lib/pspawn_payload-stg2.dylib" || path.contains("systemhook.dylib") {
                return true
            }
        }

        // 平台位（TrollStore / 系统级签名）。
        if let flags = csopsFlags(pid: 0), flags & CS_PLATFORM_BINARY != 0 {
            return true
        }

        // 越狱文件系统的典型目录。
        let applications = opendir("/Applications")
        if applications != nil {
            closedir(applications)
            return true
        }
        return false
    }

    private static func isSubstrated() -> Bool {
        let substratePaths = [
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/usr/lib/substrate/SubstrateInserter.dylib",
            "/usr/lib/substrate/SubstrateLauncher.dylib",
            "/usr/lib/TweakInject.dylib"
        ]
        return substratePaths.contains { access($0, F_OK) == 0 }
    }

    // MARK: - iOS 26 / TXM（Amethyst DeviceGetJITFlags 原样移植）

    private static var cachedFlags: UInt32?

    private static func deviceJITFlags() -> UInt32 {
        if let cached = cachedFlags { return cached }
        var flags: UInt32 = 0
        if #available(iOS 26.0, *) {
            flags |= FLAG_IS_IOS_26
            if !canCreateRXMap() {
                flags |= FLAG_FORCE_MIRRORED
            }
        }
        if deviceHasTXM() {
            flags |= FLAG_HAS_TXM
        }
        cachedFlags = flags
        return flags
    }

    /// Amethyst DeviceCanCreateRXMap：JIT 已启用时此测试才准确
    /// （vphone 等内部环境用），失败会触发 FORCE_MIRRORED。
    private static func canCreateRXMap() -> Bool {
        let size = Int(getpagesize())
        let failed = UnsafeMutableRawPointer(bitPattern: -1)
        guard let base = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_SHARED, -1, 0),
              base != failed else {
            return false
        }
        defer { munmap(base, size) }
        base.assumingMemoryBound(to: UInt32.self).pointee = 0xFFFFFFFF
        let first = mprotect(base, size, PROT_READ | PROT_EXEC)
        let second = mprotect(base, size, PROT_READ | PROT_EXEC)
        return (first | second) == 0
    }

    /// TXM（TrustedExecutionMonitor）存在 = iOS 26+ 的严格签名环境。
    private static func deviceHasTXM() -> Bool {
        guard let dir = opendir("/private/preboot") else { return false }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            var record = entry.pointee
            let name = withUnsafeBytes(of: &record.d_name) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name.utf8.count == 96 {
                let txmPath = "/private/preboot/\(name)/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4"
                return access(txmPath, F_OK) == 0
            }
        }
        return false
    }
}


// dyld 图片遍历函数不在 Swift 的 Darwin 模块 overlay 里，直接绑定系统符号。
@_silgen_name("_dyld_image_count")
private func dyldImageCount() -> UInt32

@_silgen_name("_dyld_get_image_name")
private func dyldImageName(_ image_index: UInt32) -> UnsafePointer<CChar>?
