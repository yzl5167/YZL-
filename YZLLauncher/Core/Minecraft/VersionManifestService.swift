import Foundation

struct VersionManifestService {
    private let manifestURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!

    func fetchManifest() async throws -> VersionManifest {
        let data = try await fetch(url: manifestURL)
        do {
            return try JSONDecoder().decode(VersionManifest.self, from: data)
        } catch {
            throw VersionServiceError.decodingFailed
        }
    }

    /// 按版本 id 在 Mojang 清单里找版本详情 JSON 的地址。
    /// 加载器 profile（Fabric / Forge）的 `inheritsFrom` 指向的原版版本就用它解析。
    func detailURL(for versionID: String) async throws -> URL? {
        let manifest = try await fetchManifest()
        return manifest.versions.first { $0.id == versionID }?.url
    }

    private func fetch(url: URL) async throws -> Data {
        // 下载源改写 + 双源回退重试，避免一次网络抖动就让版本列表加载失败。
        try await MetadataFetcher.data(for: url)
    }
}

enum VersionServiceError: LocalizedError {
    case invalidResponse
    case badStatus(Int)
    case decodingFailed
    case metadataUnavailable(String)
    case assetIndexUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无法识别的响应"
        case .badStatus(let code):
            return "服务器返回 HTTP \(code)"
        case .decodingFailed:
            return "版本清单格式解析失败"
        case .metadataUnavailable(let reason):
            return "版本元数据获取失败（已依次尝试官方源与镜像源）：\(reason)。可在「设置 → 下载源」切换后重试。"
        case .assetIndexUnavailable(let reason):
            return "资源索引获取失败（已依次尝试官方源与镜像源）：\(reason)。可在「设置 → 下载源」切换后重试。"
        }
    }
}
