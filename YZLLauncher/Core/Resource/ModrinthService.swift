import Foundation

/// Modrinth v2 API 客户端。对齐 Windows 端 ModrinthClient：
/// 搜索项目、列版本、按游戏版本/加载器筛选，供资源市场安装。
/// Modrinth 是公开 API，无需 key，官方直连。
enum ModrinthService {
    private static let base = "https://api.modrinth.com/v2"
    private static let userAgent = "YZLLauncher/0.1 (iOS; +https://github.com/yzl5167/YZL-)"

    enum ServiceError: LocalizedError {
        case badStatus(Int)
        case decoding(String)
        case offline(String?)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code):
                if code == 429 { return "Modrinth 请求过于频繁（HTTP 429），请稍后再试" }
                return "Modrinth 返回 HTTP \(code)"
            case .decoding(let detail): return "Modrinth 数据解析失败：\(detail)"
            case .offline(let reason):
                if let reason, !reason.isEmpty { return "无法连接 Modrinth：\(reason)" }
                return "无法连接 Modrinth，请检查网络后重试"
            }
        }
    }

    /// 搜索资源。facets 用 Modrinth 的 JSON 字符串数组语法：
    /// [["categories:forge","categories:fabric"],["versions:1.20.1"],["project_type:mod"]]
    /// - Parameters:
    ///   - offset: 分页偏移，用于"加载更多"。
    ///   - categoryTag: 额外分类标签（如 optimization / adventure），对齐 Windows 分类筛选。
    ///   - sort: Modrinth index，downloads / follow_count / newest / updated / relevance。
    static func search(
        query: String,
        category: ResourceCategory,
        gameVersion: String?,
        loader: String?,
        categoryTag: String? = nil,
        sort: String = "downloads",
        limit: Int = 30,
        offset: Int = 0,
        session: URLSession = .shared
    ) async throws -> ModrinthSearchResponse {
        var components = URLComponents(string: "\(base)/search")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "index", value: sort)
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
        if let tag = categoryTag, !tag.isEmpty {
            facets.append(["categories:\(tag)"])
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
    /// exact 只在"游戏版本精确匹配"时为真——这是避免装错版本导致游戏崩溃的关键信号。
    static func pickBest(
        _ versions: [ModrinthVersion],
        gameVersion: String?,
        loader: String?
    ) -> (version: ModrinthVersion, exact: Bool)? {
        guard !versions.isEmpty else { return nil }

        func score(_ v: ModrinthVersion) -> Int {
            var s = 0
            if v.isRelease { s += 4 }
            if let gv = gameVersion, !gv.isEmpty, v.gameVersions.contains(gv) { s += 4 }
            if let loader, !loader.isEmpty {
                let wanted = loader.lowercased()
                if v.loaders.contains(where: { $0.lowercased() == wanted }) { s += 2 }
            }
            return s
        }

        let sorted = versions.sorted { score($0) > score($1) }
        guard let best = sorted.first else { return nil }
        // exact 只看 MC 版本是否精确匹配（不因加载器缺失就谎报兼容）。
        let exact = gameVersion.map { !$0.isEmpty && best.gameVersions.contains($0) } ?? false
        return (best, exact)
    }

    /// 中文查询 → 英文名映射，带进程内缓存。对齐 Windows 端 Mcmod 反查。
    /// Modrinth 对中文命中率极低，必须先把中文翻成英文再搜。
    static func englishQuery(for chinese: String) async -> String {
        guard ResourceTranslation.hasChinese(chinese) else { return chinese }
        if let cached = ResourceTranslation.cachedQuery(for: chinese) { return cached }
        let mapped = await ResourceTranslation.englishName(for: chinese)
        // Windows 端 "A / B" 只取第一段。
        let clean = mapped.split(separator: "/").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let result = clean.isEmpty ? chinese : clean
        ResourceTranslation.cacheQuery(result, for: chinese)
        return result
    }

    /// GET + 状态码校验 + User-Agent + 429/5xx 退避重试。
    /// CancellationError 原样透传，绝不折叠成 offline（否则旧搜索会误报网络故障）。
    private static func get(_ url: URL, session: URLSession) async throws -> Data {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                // 取消必须原样透传：iOS 上 URLSession 被取消抛 URLError(.cancelled)，
                // 不是 CancellationError，两者都要识别，否则旧搜索会误报"无法连接"。
                if error is CancellationError { throw error }
                if let urlError = error as? URLError, urlError.code == .cancelled { throw error }
                guard attempt < maxAttempts else {
                    throw ServiceError.offline(error.localizedDescription)
                }
                // sleep 被取消时也立即透传，避免空转。
                do {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
                } catch {
                    throw error
                }
                continue
            }
            guard let http = response as? HTTPURLResponse else {
                throw ServiceError.offline("响应无效")
            }
            if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                if attempt < maxAttempts {
                    // 尊重 Retry-After，但夹紧到 0.5~3 秒，避免无限等待。
                    let retry = http.value(forHTTPHeaderField: "Retry-After")
                        .flatMap(Double.init).map { min(max($0, 0.5), 3.0) } ?? Double(attempt)
                    try? await Task.sleep(nanoseconds: UInt64(retry * 1_000_000_000))
                    continue
                }
                throw ServiceError.badStatus(http.statusCode)
            }
            guard http.statusCode == 200 else { throw ServiceError.badStatus(http.statusCode) }
            return data
        }
        throw ServiceError.offline(nil)
    }
}
