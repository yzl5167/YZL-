import Foundation

/// 资源市场类别。对齐 Windows 端 OpenResourcePage(mode:) 的 mod / shader / resourcepack，
/// 再加整合包（modpack）对应 Windows 独立的整合包页。
enum ResourceCategory: String, CaseIterable, Identifiable {
    case mod
    case shader
    case resourcepack
    case modpack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mod: return "模组"
        case .shader: return "光影"
        case .resourcepack: return "资源包"
        case .modpack: return "整合包"
        }
    }

    var icon: String {
        switch self {
        case .mod: return "puzzlepiece.fill"
        case .shader: return "sun.max.fill"
        case .resourcepack: return "square.grid.2x2.fill"
        case .modpack: return "shippingbox.fill"
        }
    }

    /// Modrinth project_type 过滤值。Modrinth 的 shader 类型叫 "shader"，
    /// resourcepack 叫 "resourcepack"；整合包叫 "modpack"。
    var modrinthType: String { rawValue }

    /// 安装到游戏目录下的子目录；modpack 走整合包导入流程，不落这里。
    var targetSubdirectory: String? {
        switch self {
        case .mod: return "mods"
        case .shader: return "shaderpacks"
        case .resourcepack: return "resourcepacks"
        case .modpack: return nil
        }
    }
}

/// Modrinth v2 `/v2/search` 返回的项目条目。
struct ModrinthProject: Codable, Identifiable, Hashable {
    let projectID: String
    let slug: String
    let title: String
    let description: String
    let categories: [String]?
    let clientSide: String?
    let serverSide: String?
    let iconURL: String?
    let downloads: Int?
    let dateModified: String?
    let versions: [String]?

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case slug, title, description, categories
        case clientSide = "client_side"
        case serverSide = "server_side"
        case iconURL = "icon_url"
        case downloads
        case dateModified = "date_modified"
        case versions
    }

    var id: String { projectID }

    /// 中文显示名：有翻译时用翻译，否则原标题。翻译由 ResourceTranslation 提供。
    func displayTitle(translation: String?) -> String {
        if let translation, !translation.isEmpty { return translation }
        return title
    }
}

/// Modrinth v2 `/v2/search` 的响应外壳。
struct ModrinthSearchResponse: Codable {
    let hits: [ModrinthProject]
    let limit: Int?
    let offset: Int?
    let totalHits: Int?

    enum CodingKeys: String, CodingKey {
        case hits, limit, offset
        case totalHits = "total_hits"
    }
}

/// Modrinth v2 `/v2/project/{id}/version` 返回的版本条目。
struct ModrinthVersion: Codable, Identifiable, Hashable {
    let id: String
    let projectID: String
    let name: String
    let versionNumber: String
    let gameVersions: [String]
    let loaders: [String]
    let files: [ModrinthFile]
    let dependencies: [ModrinthDependency]
    let datePublished: String?
    let versionType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case name
        case versionNumber = "version_number"
        case gameVersions = "game_versions"
        case loaders, files, dependencies
        case datePublished = "date_published"
        case versionType = "version_type"
    }

    var isRelease: Bool { versionType == "release" }

    /// 主文件：primary = true 的那个；没有则取第一个。
    var primaryFile: ModrinthFile? {
        files.first { $0.primary == true } ?? files.first
    }
}

struct ModrinthFile: Codable, Hashable {
    let hashes: ModrinthHashes?
    let url: String
    let filename: String
    let primary: Bool?
    let size: Int64?

    struct ModrinthHashes: Codable, Hashable {
        let sha1: String?
        let sha512: String?
    }
}

/// Modrinth 版本依赖：用于前置模组自动补装。
/// dependency_type 取值 required / optional / incompatible；只自动补 required。
struct ModrinthDependency: Codable, Hashable {
    let projectID: String?
    let versionID: String?
    let dependencyType: String

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case versionID = "version_id"
        case dependencyType = "dependency_type"
    }

    var isRequired: Bool { dependencyType == "required" }
}

/// 资源详情（项目 + 版本 + 已解析的中文名/简介）供 UI 展示。
struct ResourceDetail: Identifiable {
    let project: ModrinthProject
    let translatedTitle: String?
    let translatedDescription: String?

    var id: String { project.id }
}
