import Foundation

/// 资源中文名/简介翻译。对齐 Windows 端 `McmodService`（MC百科按英文名反查）：
/// Modrinth 返回的多是英文标题，这里用 MC百科搜索接口做双向映射：
/// - 中文查询 → 英文名（给 Modrinth 搜索用，命中率关键）；
/// - 英文标题 → 中文名/简介（展示用）。
/// 全程 best-effort：查不到或网络失败返回 nil/原值，绝不阻塞资源列表。
enum ResourceTranslation {
    private static let searchURL = "https://www.mcmod.cn/api/search/minecraft_mod"
    private static let userAgent = "YZLLauncher/0.1 (iOS)"

    /// 缓存访问在 nonisolated async 函数里发生（SE-0338 不继承调用方 MainActor），
    /// 旧搜索取消 / 换页会并发读写，必须用锁保护，否则 Dictionary 并发写会崩。
    private static let cacheLock = NSLock()
    private static var queryCacheDict: [String: String] = [:]
    private static var displayCacheDict: [String: (title: String?, description: String?)] = [:]

    /// 中文→英文 查询映射（线程安全）。
    static func cachedQuery(for key: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return queryCacheDict[key]
    }

    static func cacheQuery(_ value: String, for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        queryCacheDict[key] = value
    }

    struct Hit: Decodable {
        let id: Int?
        let title: String?
        let description: String?
        /// MC百科英文名字段（不同版本 API 可能是 en_name / name）。
        let enName: String?

        enum CodingKeys: String, CodingKey {
            case id, title, description
            case enName = "en_name"
        }

        enum AltKeys: String, CodingKey { case name }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(Int.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            if let en = try c.decodeIfPresent(String.self, forKey: .enName) {
                enName = en
            } else {
                let alt = try decoder.container(keyedBy: AltKeys.self)
                enName = try alt.decodeIfPresent(String.self, forKey: .name)
            }
        }
    }

    struct Response: Decodable {
        let data: [Hit]?
    }

    /// 是否含中文字符。Windows 端 `HasChinese` 的等价实现。
    static func hasChinese(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF { return true }
        }
        return false
    }

    /// 中文关键词 → 英文名（MC百科命中项的 en_name）。查不到返回空串。
    static func englishName(for chinese: String, session: URLSession = .shared) async -> String {
        guard let hits = await searchHits(chinese, session: session) else { return "" }
        for hit in hits {
            if let en = hit.enName, !en.isEmpty, !hasChinese(en) { return en }
        }
        if let title = hits.first?.title {
            // 退路：从标题里抓连续的 ASCII 单词（如 "机械动力 Create" → "Create"）。
            if let match = title.range(of: "[A-Za-z][A-Za-z0-9_-]{2,}", options: .regularExpression) {
                return String(title[match])
            }
        }
        return ""
    }

    /// 英文标题 → (中文名, 中文简介)。只接受真正含中文的结果，带缓存。
    static func translate(
        query: String,
        session: URLSession = .shared
    ) async -> (title: String?, description: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }
        cacheLock.lock()
        let cached = displayCacheDict[trimmed]
        cacheLock.unlock()
        if let cached { return cached }

        guard let hits = await searchHits(trimmed, session: session) else { return (nil, nil) }
        guard let hit = hits.first(where: { hasChinese($0.title ?? "") }) else {
            let result: (title: String?, description: String?) = (nil, nil)
            cacheLock.lock(); displayCacheDict[trimmed] = result; cacheLock.unlock()
            return result
        }
        let zhTitle = hit.title.flatMap { hasChinese($0) ? $0 : nil }
        let zhDesc = hit.description.flatMap { hasChinese($0) ? $0 : nil }
        let result = (zhTitle, zhDesc)
        cacheLock.lock(); displayCacheDict[trimmed] = result; cacheLock.unlock()
        return result
    }

    /// MC百科搜索底层：单次 GET，超时 8s，失败返回 nil。
    private static func searchHits(_ keyword: String, session: URLSession) async -> [Hit]? {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: searchURL) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "filter", value: trimmed),
            URLQueryItem(name: "page", value: "1")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let data = try? await session.data(for: request).0 else { return nil }
        return (try? JSONDecoder().decode(Response.self, from: data))?.data
    }

    /// 清空翻译缓存（切换数据源等场景）。
    static func clearCache() {
        cacheLock.lock()
        queryCacheDict.removeAll()
        displayCacheDict.removeAll()
        cacheLock.unlock()
    }
}
