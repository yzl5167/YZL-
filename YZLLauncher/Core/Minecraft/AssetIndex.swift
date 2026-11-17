import Foundation

struct AssetIndexDocument: Decodable {
    struct AssetObject: Decodable {
        let hash: String
        let size: Int64
    }

    let objects: [String: AssetObject]
}

/// 资源索引获取：本地缓存 → 当前下载源 → 备用源，每个源最多两次请求。
///
/// 以前这里只发一次请求、没有重试也没有回退：BMCLAPI 不镜像
/// `/v1/packages/...`（资源索引），官方源偶发抖动也会让一次失败直接中止整个
/// 版本安装，用户看到的就是「资源索引获取失败」。现在任一条路能通就继续，
/// 成功后写回本地缓存，重试安装时连这次请求都省掉。
/// 资源索引获取结果：网络成功/失败，或硬看门狗到点。
private enum AssetIndexFetchOutcome {
    case success(Data, AssetIndexDocument)
    case failure(String)
    case watchdog
}

struct AssetIndexService {
    private static let attemptsPerSource = 2
    /// 硬看门狗上限（秒）：无论 URLSession 底层怎么挂起，资源索引阶段最多等这些秒。
    /// 真机上 waitsForConnectivity + DNS/TLS 卡死曾让这里无限等待，
    /// 用户永远停在「正在统计安装清单」。超时后强制取消并给出明确错误。
    static let hardTimeoutSeconds: Double = 20

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 9
            config.timeoutIntervalForResource = 22
            // 关键：waitsForConnectivity=true 时，系统判定「无连接」会挂起请求，
            // 期间 timeoutInterval 不计时 —— 真机上会永久卡住安装准备。
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            config.httpAdditionalHeaders = ["User-Agent": "YZLLauncher/0.1 (iOS)"]
            self.session = URLSession(configuration: config)
        }
    }

    /// - Parameters:
    ///   - indexURL: 版本 JSON 里的资源索引地址（官方地址，尚未改写）。
    ///   - cacheURL: 已落盘的索引文件；内容有效时直接复用，完全不联网。
    ///   - expectedSHA1: 可选，用于确认本地缓存就是同一份索引。
    func fetch(indexURL: URL,
               cacheURL: URL? = nil,
               expectedSHA1: String? = nil,
               hardTimeout: Double = AssetIndexService.hardTimeoutSeconds) async throws -> AssetIndexDocument {
        if let cacheURL, let cached = loadCache(at: cacheURL, expectedSHA1: expectedSHA1) {
            return cached
        }

        let active = MirrorPolicy.current
        let alternate: DownloadSource = active == .mirror ? .official : .mirror
        let candidates = Self.candidateURLs(for: indexURL, sources: [active, alternate])
        var reasons: [String] = []

        // 镜像与官方同时起跑：索引只有一条路径能通时，用户也不必等前一条超时。
        // 再加一个硬看门狗任务：即使两个源都被系统挂起（waitsForConnectivity /
        // DNS / TLS 卡死），也会在上限时间强制结束，UI 一定能退出「统计清单」。
        let budget = max(0.2, hardTimeout)
        let fetched: (Data, AssetIndexDocument)? = await withTaskGroup(
            of: AssetIndexFetchOutcome.self
        ) { group in
            for url in candidates {
                group.addTask {
                    switch await self.fetchWithRetry(url) {
                    case .success(let pair):
                        return .success(pair.0, pair.1)
                    case .failure(let error):
                        return .failure(error.localizedDescription)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                return .watchdog
            }

            loop: while let outcome = await group.next() {
                switch outcome {
                case .success(let data, let document):
                    group.cancelAll()
                    return (data, document)
                case .failure(let reason):
                    reasons.append(reason)
                case .watchdog:
                    reasons.append("资源索引请求超过 \(Int(budget)) 秒未完成，已取消；请切换下载源后重试")
                    group.cancelAll()
                    break loop
                }
            }
            return nil
        }

        if let (data, document) = fetched {
            if let cacheURL {
                writeCache(data, to: cacheURL)
            }
            return document
        }

        throw VersionServiceError.assetIndexUnavailable(reasons.joined(separator: "；"))
    }

    private func fetchWithRetry(_ url: URL) async -> Result<(Data, AssetIndexDocument), Error> {
        var lastReason = "\(url.host ?? "未知源")：未知错误"
        for attempt in 1...Self.attemptsPerSource {
            // 看门狗 cancelAll 后尽快退出，别在已取消的任务里继续重试。
            if Task.isCancelled {
                return .failure(VersionServiceError.assetIndexUnavailable("请求已取消"))
            }
            do {
                let pair = try await fetchOnce(url)
                return .success(pair)
            } catch {
                lastReason = "\(url.host ?? "未知源")：\(error.localizedDescription)"
                if attempt < Self.attemptsPerSource {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
                }
            }
        }
        return .failure(VersionServiceError.assetIndexUnavailable(lastReason))
    }

    /// 候选地址：当前源优先、备用源兜底，地址相同（例如索引只走官方）时去重。
    /// 纯函数，便于单测覆盖回退顺序。
    static func candidateURLs(for url: URL, sources: [DownloadSource]) -> [URL] {
        var result: [URL] = []
        for source in sources {
            let candidate = MirrorPolicy.rewrite(url, source: source)
            if !result.contains(candidate) {
                result.append(candidate)
            }
        }
        return result
    }

    private func fetchOnce(_ url: URL) async throws -> (Data, AssetIndexDocument) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 9
        request.setValue("YZLLauncher/0.1 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VersionServiceError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw VersionServiceError.badStatus(http.statusCode)
        }

        let document: AssetIndexDocument
        do {
            document = try JSONDecoder().decode(AssetIndexDocument.self, from: data)
        } catch {
            throw VersionServiceError.decodingFailed
        }
        guard !document.objects.isEmpty else {
            throw VersionServiceError.decodingFailed
        }
        return (data, document)
    }

    private func loadCache(at url: URL, expectedSHA1: String?) -> AssetIndexDocument? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }

        if let expectedSHA1, !expectedSHA1.isEmpty,
           let actual = SHA1Digest.hex(of: url),
           actual.caseInsensitiveCompare(expectedSHA1) != .orderedSame {
            return nil
        }
        guard let document = try? JSONDecoder().decode(AssetIndexDocument.self, from: data),
              !document.objects.isEmpty else { return nil }
        return document
    }

    private func writeCache(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
