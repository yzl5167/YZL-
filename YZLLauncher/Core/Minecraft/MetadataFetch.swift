import Foundation

/// 版本清单 / 版本详情 JSON 的共用获取策略：当前下载源优先 → 备用源兜底，
/// 每个源最多两次请求。
///
/// 这些请求以前都只发一次：BMCLAPI 偶发 502/超时、官方源偶发抖动，都会让
/// 版本页或安装准备直接报错。元数据文件都很小（清单 ~280KB、版本 JSON ~30KB），
/// 多试一条路的成本远低于让用户手动重试整次安装。
enum MetadataFetcher {
    static let attemptsPerSource = 2

    static func candidates(for url: URL) -> [URL] {
        let active = MirrorPolicy.current
        let alternate: DownloadSource = active == .mirror ? .official : .mirror
        var result: [URL] = []
        for source in [active, alternate] {
            let candidate = MirrorPolicy.rewrite(url, source: source)
            if !result.contains(candidate) {
                result.append(candidate)
            }
        }
        return result
    }

    static func data(for url: URL, session: URLSession = .shared) async throws -> Data {
        var lastReason = "未知错误"
        for candidate in candidates(for: url) {
            for attempt in 1...attemptsPerSource {
                do {
                    var request = URLRequest(url: candidate)
                    request.timeoutInterval = 20
                    request.setValue("YZLLauncher/0.1 (iOS)", forHTTPHeaderField: "User-Agent")

                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw VersionServiceError.invalidResponse
                    }
                    guard http.statusCode == 200 else {
                        throw VersionServiceError.badStatus(http.statusCode)
                    }
                    guard !data.isEmpty else {
                        throw VersionServiceError.invalidResponse
                    }
                    return data
                } catch {
                    lastReason = "\(candidate.host ?? "未知源")：\(error.localizedDescription)"
                    if attempt < attemptsPerSource {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
                    }
                }
            }
        }
        throw VersionServiceError.metadataUnavailable(lastReason)
    }
}
