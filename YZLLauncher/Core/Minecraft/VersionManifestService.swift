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
        // 下载源设置在这里统一生效（清单与版本详情都走 Mojang 元数据域）。
        var request = URLRequest(url: MirrorPolicy.rewrite(url))
        request.timeoutInterval = 20
        request.setValue("YZLLauncher/0.1 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw VersionServiceError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw VersionServiceError.badStatus(http.statusCode)
        }
        return data
    }
}

enum VersionServiceError: LocalizedError {
    case invalidResponse
    case badStatus(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无法识别的响应"
        case .badStatus(let code):
            return "服务器返回 HTTP \(code)"
        case .decodingFailed:
            return "版本清单格式解析失败"
        }
    }
}
