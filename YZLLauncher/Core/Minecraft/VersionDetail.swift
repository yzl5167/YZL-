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
        /// Fabric / Forge 等加载器 profile 用 Maven 坐标（`name` + `url` 仓库根）描述库，
        /// 哈希与大小直接放在库对象顶层，而不是 Mojang 的 `downloads.artifact` 里。
        var sha1: String?
        var size: Int64?

        enum CodingKeys: String, CodingKey {
            case name, url, rules, downloads, sha1, size
        }

        init(name: String,
             url: URL?,
             rules: [Rule]? = nil,
             downloads: DownloadInfo? = nil,
             sha1: String? = nil,
             size: Int64? = nil) {
            self.name = name
            self.url = url
            self.rules = rules
            self.downloads = downloads
            self.sha1 = sha1
            self.size = size
        }
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
    /// Mojang 官方版本必有 `downloads`；Fabric / Forge 等继承类 profile 没有这个键，
    /// 客户端 jar 等信息由父版本（`inheritsFrom`）提供，因此必须是可选。
    let downloads: Downloads?
    let javaVersion: JavaVersion?
    let mainClass: String?
    let libraries: [Library]?
    let assetIndex: AssetIndexRef?
    /// 1.6 之后的版本 JSON 顶层都带 `assets`，值就是资源索引名（常见为 "5"）。
    let assets: String?

    /// ISO 8601 时间串，Mojang 官方与 Fabric profile 都有；仅用于展示与安装记录。
    /// 带默认值，既有的构造点（VersionMerger / 测试）不需要跟着改。
    var time: String? = nil
    var releaseTime: String? = nil

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

        /// Mojang 1.13+ 的 ruled token 用 `value`（单数），值可以是单个字符串，
        /// 也可以是字符串数组。工程早期测试样本用过 `values`，这里一并兼容，
        /// 但编码时统一输出官方的 `value` 格式。
        private struct RuledPayload: Codable {
            let values: [String]
            let rules: [Library.Rule]?

            enum CodingKeys: String, CodingKey {
                case value
                case values
                case rules
            }

            init(values: [String], rules: [Library.Rule]?) {
                self.values = values
                self.rules = rules
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let single = try? container.decode(String.self, forKey: .value) {
                    values = [single]
                } else if let list = try? container.decode([String].self, forKey: .value) {
                    values = list
                } else if let legacyList = try? container.decode([String].self, forKey: .values) {
                    values = legacyList
                } else if let legacySingle = try? container.decode(String.self, forKey: .values) {
                    values = [legacySingle]
                } else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .value,
                        in: container,
                        debugDescription: "ruled argument 缺少 value / values"
                    )
                }
                rules = try container.decodeIfPresent([Library.Rule].self, forKey: .rules)
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(values, forKey: .value)
                try container.encodeIfPresent(rules, forKey: .rules)
            }
        }
    }

    struct VersionArguments: Codable, Equatable {
        /// JVM 参数；元素是纯字符串，或带 `rules` 的对象（按平台过滤）。
        let jvm: [ArgumentToken]?
        /// 游戏参数；占位符由 `ArgumentResolver` 替换。
        let game: [ArgumentToken]?
    }

    var clientArtifact: Artifact? {
        downloads?.client
    }

    var assetIndexName: String {
        assets ?? assetIndex?.id ?? "legacy"
    }

    var javaRequirement: String {
        guard let javaVersion else { return "Java 要求未知" }
        return "Java \(javaVersion.majorVersion)（\(javaVersion.component ?? "未标注组件")）"
    }
}
