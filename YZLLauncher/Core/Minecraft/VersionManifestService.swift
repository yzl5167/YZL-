import Foundation

struct VersionManifestService {
    private let manifestURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!

    func fetchManifest() async throws -> VersionManifest {
        do {
            let data = try await fetch(url: manifestURL)
            let manifest = try decodeManifest(data)
            cache(data)
            return manifest
        } catch let error as VersionServiceError {
            // 网络失败时退回上一次成功拉取的清单：已安装版本仍然可选、可启动，
            // 版本页不再因为一次断网就整页变成「获取版本清单失败」。
            if let cached = cachedManifest() { return cached }
            throw error
        } catch {
            if let cached = cachedManifest() { return cached }
            throw error
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

    private func decodeManifest(_ data: Data) throws -> VersionManifest {
        do {
            return try JSONDecoder().decode(VersionManifest.self, from: data)
        } catch {
            throw VersionServiceError.decodingFailed
        }
    }

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("YZLLauncher", isDirectory: true)
            .appendingPathComponent("version_manifest_v2.json")
    }

    private func cache(_ data: Data) {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // 缓存失败不影响本次版本列表展示。
        }
    }

    private func cachedManifest() -> VersionManifest? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? decodeManifest(data)
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
