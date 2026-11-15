import Foundation

/// 把「开 JIT」压成一次点击：启动器直接把深链丢给系统里的 JIT 助手，
/// 用户不需要知道 JIT 是什么，也不需要自己去系统里翻哪个 App、点哪个按钮。
///
/// 为什么一定要带 `pid`：StikDebug 只拿到 bundle-id 时会先把目标 App 冷启动、
/// 附加、再 detach，但目标自己的 JIT 内存池还没建好就被断开了，回来仍是「未启用」。
/// 带上当前进程 pid 才是「附加到正在运行的进程」，一次就能成。
///
/// 这里只负责拼 URL，不做 UI、不判状态，方便单测覆盖。
enum JITLauncher {
    struct Candidate: Equatable {
        /// 用于 `canOpenURL`；必须在 Info.plist 的 `LSApplicationQueriesSchemes` 里声明，
        /// 否则查询恒为 false，会被误判成「没装助手」。
        let scheme: String
        let url: URL
        /// 给用户看的名字，例如「StikDebug」。
        let appName: String
    }

    /// 依次尝试，最可能成功的排前面。
    /// - Parameters:
    ///   - osMajor: 系统大版本，用来决定要不要带 iOS 26+ 的脚本参数。
    static func candidates(bundleID: String, pid: Int32, osMajor: Int) -> [Candidate] {
        guard !bundleID.isEmpty else { return [] }
        var list: [Candidate] = []

        // iOS 26 起 JIT 走 TXM + 脚本协议，必须带 script-name；
        // 旧系统带上会被当成「找不到该脚本」而失败，所以按版本分流。
        if osMajor >= 26,
           let url = enableURL(scheme: "stikdebug", bundleID: bundleID, pid: pid, scriptName: "universal") {
            list.append(Candidate(scheme: "stikdebug", url: url, appName: "StikDebug"))
        }
        if let url = enableURL(scheme: "stikdebug", bundleID: bundleID, pid: pid, scriptName: nil) {
            list.append(Candidate(scheme: "stikdebug", url: url, appName: "StikDebug"))
        }
        // 改名前的旧包还在用的不少，留一条兜底。
        if let url = enableURL(scheme: "stikjit", bundleID: bundleID, pid: pid, scriptName: nil) {
            list.append(Candidate(scheme: "stikjit", url: url, appName: "StikJIT"))
        }
        // TrollStore 不用 pid：它给进程补 entitlement，由系统在下次启动时生效。
        if let url = enableURL(scheme: "apple-magnifier", bundleID: bundleID, pid: nil, scriptName: nil) {
            list.append(Candidate(scheme: "apple-magnifier", url: url, appName: "TrollStore"))
        }
        return list
    }

    static func enableURL(
        scheme: String,
        bundleID: String,
        pid: Int32?,
        scriptName: String?
    ) -> URL? {
        guard !scheme.isEmpty, !bundleID.isEmpty else { return nil }
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "enable-jit"
        var items = [URLQueryItem(name: "bundle-id", value: bundleID)]
        if let pidValue = pid {
            items.append(URLQueryItem(name: "pid", value: String(pidValue)))
        }
        if let scriptName = scriptName, !scriptName.isEmpty {
            items.append(URLQueryItem(name: "script-name", value: scriptName))
        }
        comps.queryItems = items
        return comps.url
    }
}
