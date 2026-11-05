import Foundation

struct InstallLayout {
    let versionID: String
    let root: URL

    static func forVersion(_ versionID: String) -> InstallLayout {
        InstallLayout(
            versionID: versionID,
            root: DownloadPaths.versionsDirectory().appendingPathComponent(DownloadPaths.sanitize(versionID))
        )
    }

    var safeName: String {
        DownloadPaths.sanitize(versionID)
    }

    var clientJar: URL {
        root.appendingPathComponent("\(safeName)-client.jar")
    }

    /// 保存版本 JSON 原文（编码后的 VersionDetail）；启动时离线读取主类、依赖库与资源索引。
    var versionJSON: URL {
        root.appendingPathComponent("\(safeName).json")
    }

    var gameDirectory: URL {
        root.appendingPathComponent("game", isDirectory: true)
    }

    var assetsDirectory: URL {
        root.appendingPathComponent("assets", isDirectory: true)
    }

    var nativesDirectory: URL {
        root.appendingPathComponent("natives", isDirectory: true)
    }

    func libraryURL(path: String) -> URL {
        root.appendingPathComponent("libraries").appendingPathComponent(path)
    }

    func assetIndexURL(id: String) -> URL {
        root.appendingPathComponent("assets/indexes").appendingPathComponent("\(id).json")
    }

    func assetObjectURL(hash: String) -> URL {
        let prefix = String(hash.prefix(2))
        return root
            .appendingPathComponent("assets/objects")
            .appendingPathComponent(prefix)
            .appendingPathComponent(hash)
    }
}
