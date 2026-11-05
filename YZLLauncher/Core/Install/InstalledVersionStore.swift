import Foundation

/// 本机已完成的版本安装记录。只有整包下载并通过逐文件 SHA-1 校验后才会写入；
/// 启动前的自检会读取这里和版本 JSON，避免把“选中过”误当成“已安装”。
struct InstalledVersion: Codable, Identifiable, Equatable {
    let id: String
    let type: String
    let releaseTime: String
    let detailURL: URL
    let javaMajor: Int
    let assetIndex: String
    let installedAt: Date
    let fileCount: Int
    let totalBytes: Int64

    var minecraftVersion: MinecraftVersion {
        MinecraftVersion(
            id: id,
            type: type,
            url: detailURL,
            time: releaseTime,
            releaseTime: releaseTime
        )
    }

    var installedAtText: String {
        Self.formatter.string(from: installedAt)
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// `installed.json` 只存索引；版本 JSON、jar、libraries、assets 仍在各自的版本目录里。
final class InstalledVersionStore {
    private let root: URL
    private let fileURL: URL
    private let fileManager = FileManager.default

    init(root: URL = DownloadPaths.versionsDirectory()) {
        self.root = root
        self.fileURL = root.appendingPathComponent("installed.json")
    }

    func load() -> [InstalledVersion] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([InstalledVersion].self, from: data))?
            .sorted { $0.installedAt > $1.installedAt } ?? []
    }

    func save(_ versions: [InstalledVersion]) {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(versions.sorted { $0.installedAt > $1.installedAt }) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
