import Foundation

/// iOS 端的 Java 环境管理（对齐 PC 端「Java 管理」的功能面）。
///
/// 平台差异说明：iOS 不能像 PC 那样下载 Mojang 官方 Windows/Linux JRE 后直接运行
/// （CPU 架构、平台标记、代码签名、App Store 2.5.2 都不允许）。所以「在线下载安装」
/// 这一项做不到；其余 PC 端有的能力都在这里落地：
///   · 扫描并列出所有 JRE（内置 `java_runtimes/` + 手动导入的 Documents 目录）；
///   · 读取 `release` 里的真实版本号、目录体积、可用状态；
///   · 按游戏版本推荐所需 Java 大版本；
///   · 启动前**精确选择**对应 JRE，而不是拿第一个目录凑数；
///   · 缺失/不匹配时给出可操作提示（含手动导入路径）。
enum JavaEnvironment {
    struct Runtime: Identifiable, Equatable {
        let major: Int
        /// `release` 里的 JAVA_VERSION，例如 `17.0.9` / `1.8.0_392`。
        let version: String
        let root: URL
        /// 有 libjli / libjvm 等真实标记文件才算可用；空壳目录只展示不参与选择。
        let isUsable: Bool
        let bytes: Int64
        /// 来自 Documents 的是用户手动导入，来自 App Bundle 的是引擎内置。
        let isManual: Bool

        var id: String { root.path }
        var displayName: String { "Java \(major)" }
        var versionText: String { version.isEmpty ? "版本未知" : version }
        var sourceText: String { isManual ? "手动导入" : "引擎内置" }
        var stateText: String { isUsable ? "可用" : "空壳（缺 JVM 二进制）" }
        var sizeText: String {
            guard bytes > 0 else { return "—" }
            return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
        }
    }

    enum Selection: Equatable {
        /// 找到与游戏要求完全一致的大版本。
        case exact(Runtime)
        /// 只有更高的 Java（Java 向后兼容），能试但可能有模组兼容风险。
        case fallback(Runtime, required: Int)
        /// 没有能跑该游戏版本的 JRE。
        case missing(required: Int, available: [Int])

        var runtime: Runtime? {
            switch self {
            case .exact(let runtime), .fallback(let runtime, _): return runtime
            case .missing: return nil
            }
        }
    }

    static let manualDirectoryName = "YZLJavaRuntimes"

    /// 全部 JRE（含空壳），按大版本升序；管理页直接消费。
    /// `includeSize=false` 用于启动路径，避免每次启动都遍历几百个文件。
    static func scan(bundleURL: URL? = nil,
                     includeSize: Bool = true,
                     fileManager: FileManager = .default) -> [Runtime] {
        let roots = RuntimeLocator.javaRoots(fileManager: fileManager, bundleURL: bundleURL)
        var result: [Runtime] = []
        for root in roots {
            let isManual = root.lastPathComponent == manualDirectoryName
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            ) else { continue }
            for entry in entries {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory, let major = major(of: entry, fileManager: fileManager) else { continue }
                result.append(Runtime(
                    major: major,
                    version: versionString(of: entry, fileManager: fileManager) ?? "",
                    root: entry,
                    isUsable: RuntimeLocator.isValidJRE(entry, fileManager: fileManager),
                    bytes: includeSize ? directorySize(entry, fileManager: fileManager) : 0,
                    isManual: isManual
                ))
            }
        }
        return result.sorted { lhs, rhs in
            lhs.major == rhs.major ? lhs.root.path < rhs.root.path : lhs.major < rhs.major
        }
    }

    static func availableMajors(fileManager: FileManager = .default) -> [Int] {
        scan(includeSize: false, fileManager: fileManager)
            .filter(\.isUsable)
            .map(\.major)
    }

    /// 按游戏版本推荐 Java 大版本。
    /// 优先用版本 JSON 里的 `javaVersion.majorVersion`（最准），没有才按版本号推断。
    static func recommendedMajor(gameVersion: String?, declaredMajor: Int? = nil) -> Int {
        if let declaredMajor, declaredMajor > 0 { return declaredMajor }
        guard let gameVersion, gameVersion.hasPrefix("1.") else { return 17 }
        let parts = gameVersion.split(separator: ".")
        guard parts.count >= 2, let minor = Int(parts[1].prefix(while: { $0.isNumber })) else {
            return 17
        }
        if minor <= 16 { return 8 }
        if minor <= 20 { return 17 }
        return 21
    }

    /// 为游戏挑 JRE：精确匹配优先；Java 17+ 游戏缺对应版本时允许更高的 Java；
    /// 需要 Java 8 的游戏绝不拿 17 顶替（反射/模块化会直接崩），直接报缺失。
    static func selection(for requiredMajor: Int,
                          runtimes: [Runtime]? = nil,
                          fileManager: FileManager = .default) -> Selection {
        let usable = (runtimes ?? scan(includeSize: false, fileManager: fileManager))
            .filter(\.isUsable)
        if let exact = usable.first(where: { $0.major == requiredMajor }) {
            return .exact(exact)
        }
        if requiredMajor >= 17,
           let higher = usable.filter({ $0.major > requiredMajor }).min(by: { $0.major < $1.major }) {
            return .fallback(higher, required: requiredMajor)
        }
        return .missing(required: requiredMajor, available: usable.map(\.major))
    }

    /// 启动链路用的便捷入口：返回应该写进 `JAVA_HOME` 的目录。
    static func home(for requiredMajor: Int, fileManager: FileManager = .default) -> URL? {
        selection(for: requiredMajor, fileManager: fileManager).runtime?.root
    }

    /// 缺失时的可操作提示（PC 端「请安装 Java」在 iOS 上的等价物）。
    static func missingHint(required: Int, available: [Int]) -> String {
        let list = available.isEmpty ? "无" : available.map(String.init).joined(separator: " / ")
        return "需要 Java \(required)，当前可用：Java \(list)。请安装包含该 JRE 的引擎包，"
            + "或把 iOS 版 JRE 放到 Documents/\(manualDirectoryName)/java-\(required)-openjdk/"
            + "（目录内需有 release 与 lib/jli/libjli.dylib 或 lib/server/libjvm.dylib）。"
    }

    // MARK: - 解析

    /// 目录名形如 `java-17-openjdk`；目录名不规范时回退读 release。
    static func major(of root: URL, fileManager: FileManager = .default) -> Int? {
        let parts = root.lastPathComponent.split(separator: "-")
        if parts.count >= 2, parts[0] == "java", let value = Int(parts[1]) {
            return value
        }
        guard let version = versionString(of: root, fileManager: fileManager) else { return nil }
        return major(fromVersion: version)
    }

    static func major(fromVersion version: String) -> Int? {
        let parts = version.split(separator: ".")
        guard let first = parts.first else { return nil }
        if first == "1", parts.count >= 2 { return Int(parts[1].prefix(while: { $0.isNumber })) }
        return Int(first.prefix(while: { $0.isNumber }))
    }

    static func versionString(of root: URL, fileManager: FileManager = .default) -> String? {
        let release = root.appendingPathComponent("release")
        guard fileManager.fileExists(atPath: release.path),
              let text = try? String(contentsOf: release, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let key = "JAVA_VERSION="
            guard line.hasPrefix(key) else { continue }
            return String(line.dropFirst(key.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    private static func directorySize(_ root: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
