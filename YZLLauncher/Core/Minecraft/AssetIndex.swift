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
struct AssetIndexService {
    private static let attemptsPerSource = 2

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 60
            config.waitsForConnectivity = true
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
               expectedSHA1: String? = nil) async throws -> AssetIndexDocument {
        if let cacheURL, let cached = loadCache(at: cacheURL, expectedSHA1: expectedSHA1) {
            return cached
        }

        let active = MirrorPolicy.current
        let alternate: DownloadSource = active == .mirror ? .official : .mirror
        let candidates = Self.candidateURLs(for: indexURL, sources: [active, alternate])
        var lastReason = "未知错误"

        for url in candidates {
            for attempt in 1...Self.attemptsPerSource {
                do {
                    let (data, document) = try await fetchOnce(url)
                    if let cacheURL {
                        writeCache(data, to: cacheURL)
                    }
                    return document
                } catch {
                    lastReason = "\(url.host ?? "未知源")：\(error.localizedDescription)"
                    if attempt < Self.attemptsPerSource {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
                    }
                }
            }
        }

        throw VersionServiceError.assetIndexUnavailable(lastReason)
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
        request.timeoutInterval = 20
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
