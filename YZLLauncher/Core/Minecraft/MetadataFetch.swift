import Foundation

/// 版本清单 / 版本详情 JSON 的共用获取策略：镜像与官方同时起跑，
/// 谁先成功用谁，另一条立刻取消。
///
/// 以前是「当前源失败两次 → 再换备用源」：当前源如果被网络卡住，
/// 用户要白等 40 秒才看到兜底成功，甚至两次都超时后直接报
/// 「版本元数据获取失败」。元数据文件都很小（清单 ~280KB、版本 JSON ~30KB），
/// 同时请求两条路的成本远低于串行等待。
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
        // 会话内失败过的源排到最后：镜像 CDN 偶发不可达时，
        // 后续每个元数据请求都不必再陪跑一次已知超时的源。
        return SourceHealth.shared.ordered(result)
    }

    static func data(for url: URL, session: URLSession = .shared) async throws -> Data {
        let candidates = candidates(for: url)
        var reasons: [String] = []

        let firstSuccess: Data? = await withTaskGroup(of: (URL, Result<Data, Error>).self) { group in
            for candidate in candidates {
                group.addTask {
                    (candidate, await fetch(candidate, session: session))
                }
            }

            while let (candidate, result) = await group.next() {
                switch result {
                case .success(let data):
                    SourceHealth.shared.recordSuccess(candidate)
                    group.cancelAll()
                    return data
                case .failure(let error):
                    SourceHealth.shared.recordFailure(candidate, reason: error.localizedDescription)
                    reasons.append(error.localizedDescription)
                }
            }
            return nil
        }

        if let firstSuccess { return firstSuccess }
        throw VersionServiceError.metadataUnavailable(reasons.joined(separator: "；"))
    }

    private static func fetch(_ url: URL, session: URLSession) async -> Result<Data, Error> {
        var lastReason = "\(url.host ?? "未知源")：未知错误"
        for attempt in 1...attemptsPerSource {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
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
                return .success(data)
            } catch {
                lastReason = "\(url.host ?? "未知源")：\(error.localizedDescription)"
                if attempt < attemptsPerSource {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
                }
            }
        }
        return .failure(VersionServiceError.metadataUnavailable(lastReason))
    }
}
