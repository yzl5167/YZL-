import Foundation

/// 游戏日志读取（对齐 Windows 端 `logs/latest.log` 与崩溃摘要）：
/// 真机无 Xcode 时，游戏崩溃原因只能从这里取。只读尾部，避免大文件 OOM。
enum GameLogService {
    /// 最多读取尾部字节数 + 最多渲染行数。
    private static let maxReadBytes = 256 * 1024
    private static let maxLines = 400

    /// 日志源：启动器日志 / 游戏日志。
    enum Source: String, CaseIterable, Identifiable {
        case boot
        case game

        var id: String { rawValue }
        var title: String { self == .boot ? "启动器日志" : "游戏日志" }
    }

    /// 某已安装版本的 latest.log 路径；找不到返回 nil。
    static func latestLogURL(versionID: String?) -> URL? {
        let fm = FileManager.default
        if let vid = versionID, !vid.isEmpty {
            let layout = InstallLayout.forVersion(vid)
            let url = layout.gameDirectory
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("latest.log")
            if fm.fileExists(atPath: url.path) { return url }
        }
        // 兜底：扫描所有已安装版本，取最近修改的 latest.log。
        let root = DownloadPaths.versionsDirectory()
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        ) else { return nil }
        let candidates = dirs.compactMap { dir -> URL? in
            let url = dir.appendingPathComponent("game/logs/latest.log")
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        return candidates.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
    }

    /// 游戏日志真实字节数；无日志返回 0。
    static func byteCount(versionID: String?) -> Int64 {
        guard let url = latestLogURL(versionID: versionID),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// 读取游戏日志尾部（有损解码，坏字节不丢整份）。
    static func readText(versionID: String?) -> String {
        guard let url = latestLogURL(versionID: versionID),
              let data = try? Data(contentsOf: url) else {
            return "没有找到游戏日志（logs/latest.log）。请先启动一次游戏。"
        }
        let tail = data.count > maxReadBytes ? Data(data.suffix(maxReadBytes)) : data
        return String(decoding: tail, as: UTF8.self)
    }

    /// 崩溃摘要：只取 Error/Exception/Caused by 行，最多 6 行、每行 140 字（对齐 Windows）。
    static func crashSummary(versionID: String?) -> String {
        let text = readText(versionID: versionID)
        let lines = text.split(separator: "\n")
            .suffix(maxLines)
            .filter { line in
                line.contains("Exception") || line.contains("Error") || line.contains("Caused by")
            }
            .suffix(6)
            .map { String($0.prefix(140)) }
        return lines.isEmpty
            ? "没有从日志中提取到明确错误，请打开完整游戏日志。"
            : lines.joined(separator: "\n")
    }
}
