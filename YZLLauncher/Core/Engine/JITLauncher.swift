import Foundation

/// 资源锚点：编译进 YZLUI.framework 时 `Bundle(for:)` 返回框架包，
/// 编译进独立外壳 App 时返回主包；两边都能找到同一份 UniversalJIT26.js。
private final class JITLauncherResourceAnchor {}

/// 把「开 JIT」压成一次点击：启动器直接把深链丢给系统里的 JIT 助手，
/// 用户不需要知道 JIT 是什么，也不需要自己去系统里翻哪个 App、点哪个按钮。
///
/// 为什么一定要带 `pid`：StikDebug 只拿到 bundle-id 时会先把目标 App 冷启动、
/// 附加、再 detach，但目标自己的 JIT 内存池还没建好就被断开了，回来仍是「未启用」。
/// 带上当前进程 pid 才是「附加到正在运行的进程」，一次就能成。
///
/// iOS 26+ 为什么一定要带 `script-data`：Amethyst 上游在 JLI_Launch 之前会先用
/// `brk #0x69` 探测脚本。**只有 UniversalJIT26.js** 会给这条旧断点返回
/// `0xE0000069` 哨兵，引擎收到后才会继续加载 UniversalJIT26Extension.js 并启动 JVM。
/// 如果只带 `script-name=universal` / 完全不带脚本，助手会给 Amethyst 套用旧的
/// Amethyst-MeloNX.js：0x69 返回一个真地址，引擎判定「legacy script」后直接退出，
/// 表现就是「JIT 显示已开，但一点启动就秒闪退」。因此脚本内容必须随深链显式传入。
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
        /// 是否携带了与 Amethyst 匹配的 UniversalJIT26 脚本内容。
        let carriesUniversalScript: Bool

        init(scheme: String,
             url: URL,
             appName: String,
             carriesUniversalScript: Bool = false) {
            self.scheme = scheme
            self.url = url
            self.appName = appName
            self.carriesUniversalScript = carriesUniversalScript
        }
    }

    /// 依次尝试，最可能成功的排前面。
    /// - Parameters:
    ///   - osMajor: 系统大版本，用来决定要不要带 iOS 26+ 的脚本参数。
    static func candidates(bundleID: String, pid: Int32, osMajor: Int) -> [Candidate] {
        guard !bundleID.isEmpty else { return [] }
        var list: [Candidate] = []

        if osMajor >= 26 {
            // 首选：把脚本内容直接塞进深链。旧版 StikJIT 只认 script-data，
            // 新版 StikDebug 也兼容；这条路径不依赖用户在助手里给 Amethyst
            // 分配过什么脚本，最不容易被 legacy 脚本坑到。
            if let scriptData = universalJITScriptData() {
                for scheme in ["stikdebug", "stikjit"] {
                    guard let url = enableURL(scheme: scheme,
                                              bundleID: bundleID,
                                              pid: pid,
                                              scriptData: scriptData) else { continue }
                    let appName = scheme == "stikdebug" ? "StikDebug" : "StikJIT"
                    list.append(Candidate(scheme: scheme,
                                          url: url,
                                          appName: appName,
                                          carriesUniversalScript: true))
                }
            }
            // 兜底：助手版本较新但恰好没读到内嵌资源时，用内置脚本名再试一次。
            if let url = enableURL(scheme: "stikdebug",
                                   bundleID: bundleID,
                                   pid: pid,
                                   scriptName: "universal") {
                list.append(Candidate(scheme: "stikdebug", url: url, appName: "StikDebug"))
            }
        }

        // 旧系统 / 老助手的普通候选；iOS 26 上放在带脚本候选之后，仍保留兜底。
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

    /// 与 Amethyst fork 内置资源同版本的 UniversalJIT26.js。
    /// 必须随深链传给助手，不能依赖助手里给 Amethyst 分配的脚本。
    static func universalJITScriptData() -> Data? {
        let bundles = [Bundle(for: JITLauncherResourceAnchor.self), Bundle.main]
        for bundle in bundles {
            guard let url = bundle.url(forResource: "UniversalJIT26", withExtension: "js"),
                  let data = try? Data(contentsOf: url),
                  data.count > 4096,
                  let text = String(data: data, encoding: .utf8),
                  text.contains("Universal JIT Script"),
                  text.contains("legacyCommands[0x69]") else { continue }
            return data
        }
        return nil
    }

    static func enableURL(
        scheme: String,
        bundleID: String,
        pid: Int32?,
        scriptName: String? = nil,
        scriptData: Data? = nil
    ) -> URL? {
        guard !scheme.isEmpty, !bundleID.isEmpty else { return nil }
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "enable-jit"
        var items = [URLQueryItem(name: "bundle-id", value: bundleID)]
        if let pidValue = pid {
            items.append(URLQueryItem(name: "pid", value: String(pidValue)))
        }
        // StikDebug 收到 script-data 后优先用它，script-name 只在没有 data 时查本地脚本。
        if let scriptData = scriptData, !scriptData.isEmpty {
            items.append(URLQueryItem(name: "script-data",
                                      value: scriptData.base64EncodedString()))
        } else if let scriptName = scriptName, !scriptName.isEmpty {
            items.append(URLQueryItem(name: "script-name", value: scriptName))
        }
        comps.queryItems = items
        return comps.url
    }
}
