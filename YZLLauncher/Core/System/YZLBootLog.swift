import Foundation

/// 启动链路落盘日志（真机无 Xcode 时唯一的现场证据）。
///
/// 背景：fork-overlay 包里的 YZL 界面全部在 `YZLUI.framework`，由 Amethyst 的
/// `SceneDelegate` 动态装载后接管根视图。一旦装载失败就回落上游原生界面，
/// 而上游界面在没有 JIT 的真机上就是纯黑——用户看到的现象与「毫无 UI」一致，
/// 但拿不到任何错误信息（NSLog 需要 Mac + Console）。
///
/// 因此把启动各个关键点写进 App 沙盒的 `Documents/YZL-boot.log`：
/// App 的 Info.plist 已开 `UIFileSharingEnabled`，用户可直接在「文件」App 里
/// 取出来发给我们，不需要越狱机连电脑。
///
/// 约定：**永不抛错、永不阻塞**。日志写失败不能影响启动。
enum YZLBootLog {
    static let fileName = "YZL-boot.log"

    /// 沙盒 Documents 下的日志路径。取不到时退回 tmp。
    static var fileURL: URL {
        let manager = FileManager.default
        if let docs = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs.appendingPathComponent(fileName)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
    }

    /// 追加一行（带启动相对时间与序号，方便判断卡在哪一步）。
    static func write(_ message: String) {
        let line = "\(stamp()) \(message)\n"
        NSLog("[YZL] %@", message)

        let url = fileURL
        let manager = FileManager.default
        guard let data = line.data(using: .utf8) else { return }

        if !manager.fileExists(atPath: url.path) {
            // 首行写个环境头，省得用户还要另外描述机型和系统。
            let header = """
            === YZL boot log ===
            bundle: \(Bundle.main.bundleURL.lastPathComponent)
            bundleID: \(Bundle.main.bundleIdentifier ?? "(nil)")
            system: \(ProcessInfo.processInfo.operatingSystemVersionString)
            device: \(deviceModel())
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

    /// 清空日志。每次热启动重开一份，避免日志无限增长把沙盒撑大。
    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static var sequence: Int = 0

    private static func stamp() -> String {
        sequence += 1
        let elapsed = Date().timeIntervalSince(bootDate)
        return String(format: "[%3d +%6.2fs]", sequence, elapsed)
    }

    private static let bootDate = Date()

    /// 硬件标识（`iPhone16,1` 这种），诊断「老机型内存不够」时有用。
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
