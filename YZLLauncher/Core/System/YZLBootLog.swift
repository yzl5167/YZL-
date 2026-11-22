import Foundation

/// 启动链路落盘日志（真机无 Xcode 时唯一的现场证据）。
///
/// fork-overlay 包里的 YZL 界面全部在 `YZLUI.framework`，由 Amethyst 的
/// `SceneDelegate` 动态装载后接管根视图。装载失败就回落上游原生界面，
/// 而无 JIT 的真机上原生界面是纯黑——用户看不到任何错误信息。
/// 因此把启动各关键点写进 App 沙盒的 `Documents/YZL-boot.log`，
/// Info.plist 已开 `UIFileSharingEnabled`，可在「文件」App 取出。
///
/// 约定：**永不抛错、永不阻塞**。写失败不能影响启动。
enum YZLBootLog {
    static let fileName = "YZL-boot.log"
    /// 控制台最多读取的尾部字节数，防止大文件 OOM。
    private static let maxReadBytes = 256 * 1024

    static var fileURL: URL {
        let manager = FileManager.default
        if let docs = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs.appendingPathComponent(fileName)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
    }

    // 串行队列 + 锁：YZLEngineHost（异步）、安装回调、UI 都可能从不同线程写，
    // 不串行会出现序号重复、行交错、header 重复写。
    private static let writeQueue = DispatchQueue(label: "yzl.bootlog", qos: .utility)
    private static let lock = NSLock()
    private static var sequence: Int = 0
    private static var sessionStarted = false

    /// 追加一行（带启动相对时间与序号）。异步串行，绝不阻塞调用方。
    static func write(_ message: String) {
        NSLog("[YZL] %@", message)
        writeQueue.async {
            lock.lock()
            defer { lock.unlock() }
            // stamp 在锁内生成，sequence 自增串行化。
            guard let data = "\(stamp()) \(message)\n".data(using: .utf8) else { return }
            append(data)
        }
    }

    /// 每个冷启动会话调用一次：重开日志，避免无限增长（对齐 Windows 每次刷新重开）。
    /// 用进程内 flag 保证只重置一次；多进程（独立 App 与 fork）各自有一份。
    static func resetForNewSessionIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        if sessionStarted { return }
        sessionStarted = true
        try? FileManager.default.removeItem(at: fileURL)
        sequence = 0
        let header = """
        === YZL boot log ===
        bundle: \(Bundle.main.bundleURL.lastPathComponent)
        bundleID: \(Bundle.main.bundleIdentifier ?? "(nil)")
        system: \(ProcessInfo.processInfo.operatingSystemVersionString)
        device: \(deviceModel())
        === end header ===

        """
        if let data = header.data(using: .utf8) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 清空日志（用户手动）。异步串行，重置后写一行头。
    static func reset() {
        writeQueue.async {
            lock.lock()
            defer { lock.unlock() }
            try? FileManager.default.removeItem(at: fileURL)
            sequence = 0
        }
    }

    /// 读取尾部日志（有损 UTF-8 解码：坏字节替换而非整份丢弃）。
    static func readText(tailLimit maxBytes: Int = maxReadBytes) -> String {
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        let tail = data.count > maxBytes ? Data(data.suffix(maxBytes)) : data
        return String(decoding: tail, as: UTF8.self)
    }

    /// 日志字节数（诊断页展示）。
    static var byteCount: Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// 追加一条分隔线，便于在控制台里区分多次诊断。
    static func separator(_ label: String) {
        write("—— \(label) ——")
    }

    // MARK: - 内部（调用方须持锁）

    private static func append(_ data: Data) {
        let url = fileURL
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            let header = """
            === YZL boot log (session cont.) ===
            system: \(ProcessInfo.processInfo.operatingSystemVersionString)
            === end header ===

            """
            try? header.data(using: .utf8)?.write(to: url, options: .atomic)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static func stamp() -> String {
        sequence += 1
        let elapsed = Date().timeIntervalSince(bootDate)
        // 用 %ld 配 Int（64-bit），%d 配 Int 属未定义行为。
        return String(format: "[%3ld +%6.2fs]", sequence, elapsed)
    }

    private static let bootDate = Date()

    private static func deviceModel() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }
}
