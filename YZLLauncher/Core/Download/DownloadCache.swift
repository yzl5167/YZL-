import Foundation

/// 「清理下载缓存」的统一入口（对照 Android 端设置页的数据与存储卡）。
/// 只删除可再生的临时数据：断点续传分片、版本清单缓存、tmp 里的导出中间产物；
/// 已安装的游戏文件、账号、皮肤一概不动。
enum DownloadCache {
    /// 断点续传分片与状态文件目录（ResumeStateStore 默认位置）。
    static func resumeDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("YZLDownloads", isDirectory: true)
    }

    /// 版本清单缓存文件（VersionManifestService 写入）。
    static func manifestCacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("YZLLauncher", isDirectory: true)
            .appendingPathComponent("version_manifest_v2.json")
    }

    struct ClearResult {
        /// 实际删除的字节数（按清理前统计）。
        let bytesRemoved: Int64
        /// 各项的人话结果，设置页直接回显。
        let lines: [String]
    }

    /// 统计将要清理的缓存体积（确认弹窗里展示）。
    static func pendingBytes() -> Int64 {
        size(of: resumeDirectory()) + size(of: manifestCacheURL().deletingLastPathComponent())
    }

    /// 执行清理。正在进行的下载会被打断（调用前应确认队列空闲）。
    @discardableResult
    static func clear(fileManager: FileManager = .default) -> ClearResult {
        var lines: [String] = []
        var total: Int64 = 0

        let resume = resumeDirectory()
        let resumeBytes = size(of: resume)
        if resumeBytes > 0 {
            try? fileManager.removeItem(at: resume)
            total += resumeBytes
            lines.append("已清理分片与断点状态（\(InstallFormats.bytes(resumeBytes))）")
        } else {
            lines.append("没有分片缓存")
        }

        let manifest = manifestCacheURL()
        let manifestBytes = size(of: manifest)
        if manifestBytes > 0 {
            try? fileManager.removeItem(at: manifest)
            total += manifestBytes
            lines.append("已清理版本清单缓存")
        } else {
            lines.append("没有清单缓存")
        }

        // tmp 里的导出/导入中间目录（YZLExport-*、YZLExport- 前缀由导出流程创建）。
        let tmp = fileManager.temporaryDirectory
        if let items = try? fileManager.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            var removed = 0
            for item in items where item.lastPathComponent.hasPrefix("YZLExport-")
                || item.lastPathComponent.hasPrefix("yzl-export-test-")
                || item.lastPathComponent.hasPrefix("YZLExport") {
                guard (try? fileManager.removeItem(at: item)) != nil else { continue }
                removed += 1
            }
            lines.append(removed > 0 ? "已清理 \(removed) 个临时导出目录" : "没有临时导出目录")
        }

        return ClearResult(bytesRemoved: total, lines: lines)
    }

    static func size(of url: URL, fileManager: FileManager = .default) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let items = try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        ) else {
            return 0
        }
        return items.reduce(Int64(0)) { sum, item in
            sum + size(of: item, fileManager: fileManager)
        }
    }
}
