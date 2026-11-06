import Foundation

/// 下载源：Mojang 官方 / BMCLAPI 镜像。对照 Android 端 `net/Mirrors.kt` 的同一张映射表，
/// 镜像端点已实测（清单 278,772 字节与官方一致、资源对象与 fabric-meta 均 200）。
enum DownloadSource: String, CaseIterable, Identifiable {
    case official
    case mirror

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .official: return "Mojang 官方"
        case .mirror: return "BMCLAPI 镜像"
        }
    }

    var hint: String {
        switch self {
        case .official: return "直连 Mojang 官方 CDN，海外或网络通畅时更快。"
        case .mirror: return "国内镜像（bmclapi2.bangbang93.com），官方源连不上或很慢时切换。"
        }
    }
}

enum MirrorPolicy {
    static let storageKey = "downloadSource"

    /// 当前生效的下载源；未设置或值非法时回退官方。
    static var current: DownloadSource {
        source(UserDefaults.standard.string(forKey: storageKey))
    }

    static func source(_ raw: String?) -> DownloadSource {
        DownloadSource(rawValue: raw ?? "") ?? .official
    }

    /// 官方前缀 → 镜像前缀。顺序即匹配优先级（长前缀在前，避免误吞）。
    static let mirrorMappings: [(prefix: String, replacement: String)] = [
        ("https://launchermeta.mojang.com/", "https://bmclapi2.bangbang93.com/"),
        ("https://piston-meta.mojang.com/", "https://bmclapi2.bangbang93.com/"),
        ("https://piston-data.mojang.com/", "https://bmclapi2.bangbang93.com/"),
        ("https://launcher.mojang.com/", "https://bmclapi2.bangbang93.com/"),
        ("https://resources.download.minecraft.net/", "https://bmclapi2.bangbang93.com/assets/"),
        ("https://libraries.minecraft.net/", "https://bmclapi2.bangbang93.com/maven/"),
        ("https://maven.minecraftforge.net/", "https://bmclapi2.bangbang93.com/maven/"),
        ("https://files.minecraftforge.net/maven/", "https://bmclapi2.bangbang93.com/maven/"),
        ("https://maven.fabricmc.net/", "https://bmclapi2.bangbang93.com/maven/"),
        ("https://meta.fabricmc.net/", "https://bmclapi2.bangbang93.com/fabric-meta/"),
        ("https://meta.quiltmc.org/", "https://bmclapi2.bangbang93.com/quilt-meta/"),
        ("https://maven.quiltmc.org/repository/release/", "https://bmclapi2.bangbang93.com/maven/"),
        ("https://maven.neoforged.net/releases/", "https://bmclapi2.bangbang93.com/maven/")
    ]

    /// 按下载源改写地址；官方源原样返回，不在映射表里的 host 也原样返回。
    /// `source` 传 nil 时读当前设置；单测传显式值保证确定性。
    static func rewrite(_ url: URL, source: DownloadSource? = nil) -> URL {
        let active = source ?? current
        guard active == .mirror else { return url }
        let raw = url.absoluteString
        for mapping in mirrorMappings where raw.hasPrefix(mapping.prefix) {
            if let rewritten = URL(string: mapping.replacement + raw.dropFirst(mapping.prefix.count)) {
                return rewritten
            }
        }
        return url
    }
}
