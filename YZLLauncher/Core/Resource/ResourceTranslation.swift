import Foundation

/// 资源中文名/简介翻译。对齐 Windows 端 `McmodService`（MC百科按英文名反查）：
/// Modrinth 返回的多是英文标题，这里用 MC百科搜索接口按 slug/英文名找中文条目。
/// 全程 best-effort：查不到或网络失败就返回 nil，绝不阻塞资源列表展示。
enum ResourceTranslation {
    private static let searchURL = "https://www.mcmod.cn/api/search/minecraft_mod"
    private static let userAgent = "YZLLauncher/0.1 (iOS)"

    struct Hit: Decodable {
        let id: Int?
        let title: String?
        let description: String?
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

    /// 按英文名搜索，返回 (中文名, 中文简介)。只接受真正含中文的结果。
    static func translate(
        query: String,
        session: URLSession = .shared
    ) async -> (title: String?, description: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }

        guard var components = URLComponents(string: searchURL) else { return (nil, nil) }
        components.queryItems = [
            URLQueryItem(name: "filter", value: trimmed),
            URLQueryItem(name: "page", value: "1")
        ]
        guard let url = components.url else { return (nil, nil) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        guard let data = try? await session.data(for: request).0 else { return (nil, nil) }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return (nil, nil) }
        guard let hit = decoded.data?.first(where: { hasChinese($0.title ?? "") }) else {
            return (nil, nil)
        }
        let zhTitle = hit.title.flatMap { hasChinese($0) ? $0 : nil }
        let zhDesc = hit.description.flatMap { hasChinese($0) ? $0 : nil }
        return (zhTitle, zhDesc)
    }
}
