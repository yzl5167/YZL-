import Foundation

struct VersionManifest: Decodable {
    struct Latest: Decodable {
        let release: String
        let snapshot: String
    }

    let latest: Latest
    let versions: [MinecraftVersion]
}

struct MinecraftVersion: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let url: URL
    let time: String
    let releaseTime: String

    var typeLabel: String {
        switch type {
        case "release": return "正式版"
        case "snapshot": return "快照"
        case "old_beta": return "历史 Beta"
        case "old_alpha": return "历史 Alpha"
        default: return type
        }
    }

    var subtitle: String {
        "\(typeLabel) · \(releaseDateText)"
    }

    /// 加载器 profile 的标识徽章（Fabric / Forge / Quilt / NeoForge）。
    /// Mojang 官方版本返回 nil。对照 Android / Windows 端的加载器标识。
    var loaderLabel: String? {
        if id.hasPrefix("fabric-loader-") { return "Fabric" }
        if id.hasPrefix("forge-") { return "Forge" }
        if id.hasPrefix("neoforge-") { return "NeoForge" }
        if id.hasPrefix("quilt-loader-") { return "Quilt" }
        return nil
    }

    var releaseDate: Date? {
        Self.isoFormatter.date(from: releaseTime)
    }

    var releaseDateText: String {
        guard let date = releaseDate else { return releaseTime }
        return Self.displayFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
