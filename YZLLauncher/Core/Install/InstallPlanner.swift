import Foundation

enum InstallPlanner {
    static let smallFileThreshold: Int64 = 4_194_304
    static let assetsBaseURL = "https://resources.download.minecraft.net/"

    enum Kind: String, Equatable {
        case clientJar
        case library
        case assetIndex
        case assetObject
    }

    struct PlannedFile: Equatable {
        let kind: Kind
        let spec: DownloadSpec
    }

    struct Plan: Equatable {
        let versionID: String
        let files: [PlannedFile]

        var specs: [DownloadSpec] {
            files.map(\.spec)
        }

        var totalBytes: Int64 {
            files.reduce(Int64(0)) { $0 + ($1.spec.expectedSize ?? 0) }
        }

        func count(of kind: Kind) -> Int {
            files.filter { $0.kind == kind }.count
        }
    }

    /// Mojang 规则语义：没有规则即必需；有规则时以最后一条匹配规则为准，
    /// 没有任何规则匹配则视为不必需。iOS 上 osx/windows/linux 的专用库因此全部被排除。
    static func isAllowed(rules: [VersionDetail.Library.Rule]?, osName: String) -> Bool {
        guard let rules, !rules.isEmpty else { return true }
        var allowed = false
        for rule in rules {
            let matches: Bool
            if let os = rule.os {
                matches = os.name == nil || os.name == osName
            } else {
                matches = true
            }
            if matches {
                allowed = rule.action == "allow"
            }
        }
        return allowed
    }

    static func plan(detail: VersionDetail, layout: InstallLayout, osName: String = "ios") -> Plan {
        var files: [PlannedFile] = []

        // Mojang 官方版本有客户端 jar；继承类 profile（Fabric/Forge）没有，
        // 客户端 jar 由父版本提供——安装时调用方应先拍平继承链再进来。
        if let client = detail.clientArtifact {
            files.append(PlannedFile(
                kind: .clientJar,
                spec: makeSpec(
                    id: "client-\(layout.safeName)",
                    url: client.url,
                    destination: layout.clientJar,
                    sha1: client.sha1,
                    size: client.size
                )
            ))
        }

        var seenLibraryPaths = Set<String>()
        for library in detail.libraries ?? [] {
            guard isAllowed(rules: library.rules, osName: osName) else { continue }
            guard let resolved = resolveLibrary(library) else { continue }
            guard !seenLibraryPaths.contains(resolved.path) else { continue }
            seenLibraryPaths.insert(resolved.path)

            files.append(PlannedFile(
                kind: .library,
                spec: makeSpec(
                    id: "lib-\(resolved.path)",
                    url: resolved.url,
                    destination: layout.libraryURL(path: resolved.path),
                    sha1: resolved.sha1,
                    size: resolved.size
                )
            ))
        }

        if let index = detail.assetIndex {
            files.append(PlannedFile(
                kind: .assetIndex,
                spec: makeSpec(
                    id: "asset-index-\(index.id)",
                    url: index.url,
                    destination: layout.assetIndexURL(id: index.id),
                    sha1: index.sha1,
                    size: index.size
                )
            ))
        }

        return Plan(versionID: detail.id, files: files)
    }

    static func assetObjectPlan(document: AssetIndexDocument, layout: InstallLayout, versionID: String) -> Plan {
        let ordered = document.objects.values.sorted { $0.hash < $1.hash }
        var seenHashes = Set<String>()
        var files: [PlannedFile] = []

        for object in ordered where !seenHashes.contains(object.hash) {
            seenHashes.insert(object.hash)
            let prefix = String(object.hash.prefix(2))
            guard let url = URL(string: assetsBaseURL + prefix + "/" + object.hash) else { continue }
            files.append(PlannedFile(
                kind: .assetObject,
                spec: makeSpec(
                    id: "asset-\(object.hash)",
                    url: url,
                    destination: layout.assetObjectURL(hash: object.hash),
                    sha1: object.hash,
                    size: object.size
                )
            ))
        }

        return Plan(versionID: versionID, files: files)
    }

    /// 解析后的库文件信息：Mojang 官方格式走 `downloads.artifact`，
    /// 加载器 profile（只有 `name` + `url` 仓库根 + 顶层 sha1/size）走 Maven 坐标推导。
    struct ResolvedLibrary: Equatable {
        let path: String
        let url: URL
        let sha1: String?
        let size: Int64?
    }

    /// 把一条版本库条目解析成可下载的文件；两种格式都解析不出来时返回 nil。
    static func resolveLibrary(_ library: VersionDetail.Library) -> ResolvedLibrary? {
        if let artifact = library.downloads?.artifact, let path = artifact.path, !path.isEmpty {
            return ResolvedLibrary(
                path: path,
                url: artifact.url,
                sha1: artifact.sha1 ?? library.sha1,
                size: artifact.size ?? library.size
            )
        }
        // artifact 有 url 但没有 path 的罕见情形：从 Maven 坐标补 path。
        if let artifact = library.downloads?.artifact, artifact.path == nil || artifact.path?.isEmpty == true {
            guard let coordinates = MavenCoordinates(library.name) else { return nil }
            return ResolvedLibrary(
                path: coordinates.artifactPath,
                url: artifact.url,
                sha1: artifact.sha1 ?? library.sha1,
                size: artifact.size ?? library.size
            )
        }
        // 加载器 profile 格式：只有 Maven 坐标 + 仓库根，jar 地址按 Maven 布局推导。
        guard let coordinates = MavenCoordinates(library.name),
              let url = coordinates.fileURL(repoBase: library.url?.absoluteString) else {
            return nil
        }
        return ResolvedLibrary(
            path: coordinates.artifactPath,
            url: url,
            sha1: library.sha1,
            size: library.size
        )
    }

    private static func makeSpec(id: String, url: URL, destination: URL, sha1: String?, size: Int64?) -> DownloadSpec {
        // 下载源统一在生成 spec 时改写：客户端 jar / 库 / 资源对象分别来自
        // piston-data、libraries.minecraft.net（或 maven）、resources.download.minecraft.net，
        // 全部命中 MirrorPolicy 的映射表。
        let bytes = size ?? 0
        return DownloadSpec(
            id: id,
            url: MirrorPolicy.rewrite(url),
            destination: destination,
            expectedSHA1: sha1,
            expectedSize: size,
            segmentSize: 1_048_576,
            maxConnections: bytes > smallFileThreshold ? 8 : 1
        )
    }
}
