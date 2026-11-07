import Foundation

/// 下载源健康状态：会话内记录每个 host 的失败次数，用于给镜像候选排序，
/// 让这次会话里已超时/5xx 的源自动排到最后，避免每个资源都白等一次超时。
///
/// 动机与 Android 端 `net/SourceHealth.kt` 完全一致：BMCLAPI 会 302 到不同的
/// CDN，个别 CDN 不可达时，整包安装的 3000+ 个资源对象如果不去记住「这个
/// host 刚刚失败过」，每个文件都要等 30 秒请求超时才换备用源。
/// 状态只存活于本次进程，不落盘——网络恢复后下次启动自然重新开始。
final class SourceHealth {
    static let shared = SourceHealth()

    private let lock = NSLock()
    private var failuresByHost: [String: Int] = [:]

    init() {}

    // MARK: - 记录

    func recordSuccess(_ url: URL) {
        lock.lock()
        failuresByHost.removeValue(forKey: host(of: url))
        lock.unlock()
    }

    /// 记一次失败。`reason` 传错误描述；4xx（文件真的不存在/请求参数错）不视为
    /// 「源坏了」，不计数——这与 Android 端的启发式一致（错误文案含 "HTTP 4" 即跳过），
    /// 否则一个 404 会把整条镜像拉黑，剩下的安装全走官方源。
    func recordFailure(_ url: URL, reason: String? = nil) {
        if let reason, reason.contains("HTTP 4") {
            return
        }
        lock.lock()
        failuresByHost[host(of: url), default: 0] += 1
        lock.unlock()
    }

    // MARK: - 查询

    func failureCount(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return failuresByHost[host(of: url)] ?? 0
    }

    func isBad(_ url: URL) -> Bool {
        failureCount(for: url) > 0
    }

    /// 排序权重：健康 0，带失败记录 1。给候选源做稳定排序用。
    func rank(_ url: URL) -> Int {
        isBad(url) ? 1 : 0
    }

    /// 按 rank 稳定排序（健康源在前，坏源排后，同权重保持原顺序）。
    /// Swift 的 `sorted` 不保证稳定，这里用下标兜底，保证同权重候选不被乱序。
    func ordered(_ urls: [URL]) -> [URL] {
        urls
            .enumerated()
            .sorted { lhs, rhs in
                let lr = rank(lhs.element)
                let rr = rank(rhs.element)
                return lr != rr ? lr < rr : lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    /// 清空全部记录（单元测试与设置页「重新测速」用）。
    func reset() {
        lock.lock()
        failuresByHost.removeAll()
        lock.unlock()
    }

    private func host(of url: URL) -> String {
        url.host ?? url.absoluteString
    }

    // MARK: - 主动探测

    /// GET 探测一次，返回是否成功与耗时（毫秒）。只做测量，不写健康记录；
    /// 调用方（设置页测速）拿到结果后自行决定 recordSuccess / recordFailure。
    static func probe(_ url: URL, timeout: TimeInterval = 8) async -> (ok: Bool, milliseconds: Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("YZLLauncher/0.1 (iOS)", forHTTPHeaderField: "User-Agent")

        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            return (ok, elapsed)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            return (false, elapsed)
        }
    }
}
