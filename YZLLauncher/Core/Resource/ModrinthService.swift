import Foundation

/// Modrinth v2 API 客户端。对齐 Windows 端 ModrinthClient：
/// 搜索项目、列版本、按游戏版本/加载器筛选，供资源市场安装。
/// Modrinth 是公开 API，无需 key，官方直连；只做一次 GET，失败由调用方重试。
enum ModrinthService {
    private static let base = "https://api.modrinth.com/v2"
    private static let userAgent = "YZLLauncher/0.1 (iOS; +https://github.com/yzl5167/YZL-)"

    enum ServiceError: LocalizedError {
        case badStatus(Int)
        case decoding(String)
        case offline

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "Modrinth 返回 HTTP \(code)"
            case .decoding(let detail): return "Modrinth 数据解析失败：\(detail)"
            case .offline: return "无法连接 Modrinth，请检查网络后重试"
            }
        }
    }

    /// 搜索资源。facets 用 Modrinth 的 JSON 字符串数组语法：
    /// [["categories:forge","categories:fabric"],["versions:1.20.1"],["project_type:mod"]]
    static func search(
        query: String,
        category: ResourceCategory,
        gameVersion: String?,
        loader: String?,
        limit: Int = 30,
        offset: Int = 0,
        session: URLSession = .shared
    ) async throws -> ModrinthSearchResponse {
        var components = URLComponents(string: "\(base)/search")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "index", value: "downloads")
        ]
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "query", value: query))
        }

        var facets: [[String]] = []
        // 项目类型永远限定，避免光影页混进模组。
        facets.append(["project_type:\(category.modrinthType)"])
        if let gameVersion, !gameVersion.isEmpty {
            facets.append(["versions:\(gameVersion)"])
        }
        if let loader, !loader.isEmpty, category == .mod || category == .modpack {
            facets.append(["categories:\(loader.lowercased())"])
        }
        if let facetJSON = try? JSONSerialization.data(withJSONObject: facets),
           let facetString = String(data: facetJSON, encoding: .utf8) {
            items.append(URLQueryItem(name: "facets", value: facetString))
        }
        components.queryItems = items

        let data = try await get(components.url!, session: session)
        do {
            return try JSONDecoder().decode(ModrinthSearchResponse.self, from: data)
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
    }

    /// 某项目的全部版本（Modrinth 已按发布时间倒序）。
    static func versions(for projectID: String, session: URLSession = .shared) async throws -> [ModrinthVersion] {
        let escaped = projectID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectID
        let url = URL(string: "\(base)/project/\(escaped)/version")!
        let data = try await get(url, session: session)
        do {
            return try JSONDecoder().decode([ModrinthVersion].self, from: data)
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
    }

    /// 按游戏版本与加载器挑最合适的版本：优先 release、游戏版本精确匹配、加载器命中。
    /// 找不到完全匹配时退回列表第一个，并由调用方在 UI 上提示兼容性。
    static func pickBest(
        _ versions: [ModrinthVersion],
        gameVersion: String?,
        loader: String?
    ) -> (version: ModrinthVersion, exact: Bool)? {
        guard !versions.isEmpty else { return nil }

        func score(_ v: ModrinthVersion) -> Int {
            var s = 0
            if v.isRelease { s += 4 }
            if let gv = gameVersion, v.gameVersions.contains(gv) { s += 4 }
            if let loader, !loader.isEmpty {
                let wanted = loader.lowercased()
                if v.loaders.contains(where: { $0.lowercased() == wanted }) { s += 2 }
            }
            return s
        }

        let sorted = versions.sorted { score($0) > score($1) }
        guard let best = sorted.first else { return nil }
        let exact = score(best) >= 8
        return (best, exact)
    }

    /// GET + 状态码校验 + User-Agent。避免用 URLSession.shared 的默认 UA 被限流。
    private static func get(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServiceError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw ServiceError.offline }
        guard http.statusCode == 200 else { throw ServiceError.badStatus(http.statusCode) }
        return data
    }
}
