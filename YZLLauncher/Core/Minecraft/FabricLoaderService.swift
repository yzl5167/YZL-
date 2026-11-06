import Foundation

/// 加载器 Meta：Fabric（meta.fabricmc.net v2）与 Quilt（meta.quiltmc.org v3）。
///
/// 两家的 profile 端点都返回带 `inheritsFrom` 的 Mojang 格式版本 JSON，
/// 正好接进现有的 VersionMerger / 安装器链路；Android 端（DownloadScreen）与
/// Windows 端（CmlLib）也走同一批 Meta。
enum LoaderKind: String, CaseIterable, Identifiable {
    case fabric
    case quilt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fabric: return "Fabric"
        case .quilt: return "Quilt"
        }
    }

    func loaderListURL(gameVersion: String) -> URL {
        switch self {
        case .fabric:
            return URL(string: "https://meta.fabricmc.net/v2/versions/loader/\(gameVersion)")!
        case .quilt:
            return URL(string: "https://meta.quiltmc.org/v3/versions/loader/\(gameVersion)")!
        }
    }

    /// 加载器 profile（Mojang 版本 JSON 格式，`inheritsFrom` 指向原版）。
    func profileURL(gameVersion: String, loaderVersion: String) -> URL {
        switch self {
        case .fabric:
            return URL(string: "https://meta.fabricmc.net/v2/versions/loader/\(gameVersion)/\(loaderVersion)/profile/json")!
        case .quilt:
            return URL(string: "https://meta.quiltmc.org/v3/versions/loader/\(gameVersion)/\(loaderVersion)/profile/json")!
        }
    }
}

/// 某个游戏版本的加载器列表条目。
/// Fabric 条目带 `stable`；Quilt v3 没有，用版本号是否含 beta 兜底判断。
struct LoaderEntry: Decodable, Equatable, Identifiable {
    struct Loader: Decodable, Equatable {
        let version: String
        let stable: Bool?
    }

    let loader: Loader

    var id: String { loader.version }
    var version: String { loader.version }
    var isStable: Bool {
        loader.stable ?? !loader.version.lowercased().contains("beta")
    }
}

struct LoaderService {
    /// 取加载器版本列表；`limit` 限制条数（Meta 默认按构建时间倒序）。
    func fetchLoaders(kind: LoaderKind, gameVersion: String, limit: Int = 8) async throws -> [LoaderEntry] {
        var request = URLRequest(url: MirrorPolicy.rewrite(kind.loaderListURL(gameVersion: gameVersion)))
        request.timeoutInterval = 20
        request.setValue("YZLLauncher/0.1 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VersionServiceError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw VersionServiceError.badStatus(http.statusCode)
        }
        do {
            let entries = try JSONDecoder().decode([LoaderEntry].self, from: data)
            // 稳定版排前面，同档保持接口给的原顺序。
            let sorted = entries.sorted { lhs, rhs in
                if lhs.isStable != rhs.isStable { return lhs.isStable }
                return false
            }
            return Array(sorted.prefix(limit))
        } catch {
            throw VersionServiceError.decodingFailed
        }
    }

    /// 取加载器 profile 版本 JSON（复用通用的版本详情解码，镜像改写也在其中生效）。
    func fetchProfile(kind: LoaderKind, gameVersion: String, loaderVersion: String) async throws -> VersionDetail {
        let service = VersionDetailService()
        return try await service.fetch(
            detailURL: kind.profileURL(gameVersion: gameVersion, loaderVersion: loaderVersion)
        )
    }
}
