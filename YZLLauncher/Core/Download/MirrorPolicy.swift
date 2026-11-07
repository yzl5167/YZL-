import Foundation

/// 下载源三档（对齐 Android 端设置页）：自动 = 镜像优先失败回退官方；
/// 镜像 / 官方 = 固定优先级。候选序见 `MirrorPolicy.candidateOrder`。
enum DownloadSource: String, CaseIterable, Identifiable {
    case auto
    case mirror
    case official

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .mirror: return "镜像"
        case .official: return "官方"
        }
    }

    var hint: String {
        switch self {
        case .auto: return "镜像优先，失败自动回退官方。国内网络推荐。"
        case .mirror: return "优先使用 BMCLAPI 等国内镜像，适合校园网和代理环境。"
        case .official: return "优先 Mojang 官方地址，镜像只作为失败兜底。"
        }
    }
}

enum MirrorPolicy {
    static let storageKey = "downloadSource"

    /// 当前生效的下载源。默认「自动」由 AppState 在 App 首次启动时写入设置项，
    /// 这里保持「未设置=自动」的纯函数行为，避免单元测试被隐式改写下载地址。
    static var current: DownloadSource {
        source(UserDefaults.standard.string(forKey: storageKey))
    }

    static func source(_ raw: String?) -> DownloadSource {
        DownloadSource(rawValue: raw ?? "") ?? .auto
    }

    /// 候选顺序（与 Android 端 Mirrors.candidates 一致）：
    /// 自动 / 镜像 → [镜像, 官方]；官方 → [官方, 镜像]。
    static func candidateOrder(for source: DownloadSource) -> [DownloadSource] {
        source == .official ? [.official, .mirror] : [.mirror, .official]
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
    /// 自动档与镜像档同映射（镜像优先），区别在展示语义与候选兜底顺序。
    /// `source` 传 nil 时读当前设置；单测传显式值保证确定性。
    ///
    /// 资源索引（`/v1/packages/...`）也走镜像：BMCLAPI 该路径曾出现 TLS 抖动，
    /// 但现在能正常返回；即使再次失败，调用方会立刻回退官方源，比只留一条路更稳。
    static func rewrite(_ url: URL, source: DownloadSource? = nil) -> URL {
        let active = source ?? current
        guard active != .official else { return url }
        let raw = url.absoluteString
        for mapping in mirrorMappings where raw.hasPrefix(mapping.prefix) {
            let suffix = String(raw.dropFirst(mapping.prefix.count))
            if let rewritten = URL(string: mapping.replacement + suffix) {
                return rewritten
            }
        }
        return url
    }
}
