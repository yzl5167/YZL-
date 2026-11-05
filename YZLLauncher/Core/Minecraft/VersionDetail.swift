import Foundation

struct VersionDetail: Codable {
    struct Artifact: Codable, Equatable {
        let sha1: String
        let size: Int64
        let url: URL
    }

    struct Downloads: Codable {
        let client: Artifact
    }

    struct JavaVersion: Codable {
        let component: String?
        let majorVersion: Int
    }

    struct Library: Codable {
        struct Rule: Codable, Equatable {
            struct OS: Codable, Equatable {
                let name: String?
                let arch: String?
                let version: String?
            }

            /// `arguments` 里的规则用 `features` 控制（如 demo 用户、自定义分辨率），
            /// 库规则用不到但共用同一结构，缺失即视为无 feature 限制。iOS 不是官方三平台之一，
            /// 任何带 `os` 规则的项都会在 iOS 上被过滤掉。
            struct Features: Codable, Equatable {
                let isDemoUser: Bool?
                let hasCustomResolution: Bool?

                enum CodingKeys: String, CodingKey {
                    case isDemoUser = "is_demo_user"
                    case hasCustomResolution = "has_custom_resolution"
                }
            }

            let action: String
            let os: OS?
            let features: Features?
        }

        struct ArtifactEntry: Codable {
            let path: String?
            let sha1: String?
            let size: Int64?
            let url: URL
        }

        struct DownloadInfo: Codable {
            let artifact: ArtifactEntry?
            let classifiers: [String: ArtifactEntry]?
        }

        let name: String
        let url: URL?
        let rules: [Rule]?
        let downloads: DownloadInfo?
    }

    struct AssetIndexRef: Codable {
        let id: String
        let sha1: String
        let size: Int64?
        let totalSize: Int64?
        let url: URL
    }

    let id: String
    let type: String
    let downloads: Downloads
    let javaVersion: JavaVersion?
    let mainClass: String?
    let libraries: [Library]?
    let assetIndex: AssetIndexRef?
    /// 1.6 之后的版本 JSON 顶层都带 `assets`，值就是资源索引名（常见为 "5"）。
    let assets: String?

    /// 部分版本（如 Forge / Fabric / Quilt 的版本 JSON）通过 `inheritsFrom` 继承某个父版本，
    /// 自身只描述差异。启动时由 `VersionMerger` 递归拍平成一个自包含的完整版本。
    let inheritsFrom: String?

    /// 1.12.2 及更早版本用空格分隔的参数串；1.13+ 改用结构化的 `arguments`。
    let minecraftArguments: String?

    /// 1.13+ 的结构化参数。占位符（如 `${auth_player_name}`）由 `ArgumentResolver` 在启动前替换。
    let arguments: VersionArguments?

    /// `arguments` 数组里的单个 token，可能是字符串，也可能是「带平台规则的若干值」。
    enum ArgumentToken: Codable, Equatable {
        case string(String)
        case ruled(values: [String], rules: [Library.Rule])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) {
                self = .string(s)
                return
            }
            let ruled = try container.decode(RuledPayload.self)
            self = .ruled(values: ruled.values, rules: ruled.rules ?? [])
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let s):
                try container.encode(s)
            case .ruled(let values, let rules):
                try container.encode(RuledPayload(values: values, rules: rules))
            }
        }

        private struct RuledPayload: Codable {
            let values: [String]
            let rules: [Library.Rule]?
        }
    }

    struct VersionArguments: Codable, Equatable {
        /// JVM 参数；元素是纯字符串，或带 `rules` 的对象（按平台过滤）。
        let jvm: [ArgumentToken]?
        /// 游戏参数；占位符由 `ArgumentResolver` 替换。
        let game: [ArgumentToken]?
    }

    var clientArtifact: Artifact {
        downloads.client
    }

    var assetIndexName: String {
        assets ?? assetIndex?.id ?? "legacy"
    }

    var javaRequirement: String {
        guard let javaVersion else { return "Java 要求未知" }
        return "Java \(javaVersion.majorVersion)（\(javaVersion.component ?? "未标注组件")）"
    }
}
