import Foundation

/// M2 引擎资源定位：只回答「JRE / natives 在不在」，不负责启动。
///
/// 兼容两种放置方式：随 IPA 打进 App Bundle 的 `java_runtimes/`，
/// 或用户后来放进 Documents 的 `YZLJavaRuntimes/`。
/// 空目录不算可用 JRE —— 必须能找到 libjli / libjvm 这类真实标记文件。
enum RuntimeLocator {
    static let jreMarkerPaths = [
        "lib/jli/libjli.dylib",
        "lib/server/libjvm.dylib",
        "lib/libjli.dylib",
        "bin/java"
    ]

    static func javaRoots(fileManager: FileManager = .default,
                          bundleURL: URL? = nil) -> [URL] {
        let bundle = bundleURL ?? Bundle.main.bundleURL
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        return [
            bundle.appendingPathComponent("java_runtimes", isDirectory: true),
            documents?.appendingPathComponent("YZLJavaRuntimes", isDirectory: true)
        ].compactMap { $0 }
    }

    static func isValidJRE(_ root: URL, fileManager: FileManager = .default) -> Bool {
        jreMarkerPaths.contains {
            fileManager.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    /// `roots` 可注入，方便单元测试用临时目录构造场景。
    static func javaHome(roots: [URL]? = nil,
                         fileManager: FileManager = .default) -> URL? {
        let candidates = roots ?? javaRoots(fileManager: fileManager)
        for root in candidates {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for entry in entries {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory, isValidJRE(entry, fileManager: fileManager) else { continue }
                return entry
            }
        }
        return nil
    }

    static func javaRuntime(roots: [URL]? = nil,
                            fileManager: FileManager = .default) -> JavaRuntimeStatus {
        guard let home = javaHome(roots: roots, fileManager: fileManager) else {
            return .missing
        }
        return .ready(home.lastPathComponent)
    }

    /// 引擎资源是否齐备。JRE 与 natives 同时存在才算「已就位」，
    /// 但桥接层未注入时仍不能启动，状态文字里如实标注。
    static func engineStatus(roots: [URL]? = nil,
                             bundleURL: URL? = nil,
                             fileManager: FileManager = .default) -> EngineStatus {
        let bundle = bundleURL ?? Bundle.main.bundleURL
        guard javaHome(roots: roots, fileManager: fileManager) != nil else {
            return .notInstalled
        }
        let natives = bundle.appendingPathComponent("natives", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(atPath: natives.path),
              !files.isEmpty else {
            return .notInstalled
        }
        return .ready("JRE + \(files.count) 项 natives 已就位（桥接层待接入）")
    }
}
