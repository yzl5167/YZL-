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

        let client = detail.clientArtifact
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

        var seenLibraryPaths = Set<String>()
        for library in detail.libraries ?? [] {
            guard isAllowed(rules: library.rules, osName: osName) else { continue }
            guard let artifact = library.downloads?.artifact, let path = artifact.path else { continue }
            guard !seenLibraryPaths.contains(path) else { continue }
            seenLibraryPaths.insert(path)

            files.append(PlannedFile(
                kind: .library,
                spec: makeSpec(
                    id: "lib-\(path)",
                    url: artifact.url,
                    destination: layout.libraryURL(path: path),
                    sha1: artifact.sha1,
                    size: artifact.size
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

    private static func makeSpec(id: String, url: URL, destination: URL, sha1: String?, size: Int64?) -> DownloadSpec {
        let bytes = size ?? 0
        return DownloadSpec(
            id: id,
            url: url,
            destination: destination,
            expectedSHA1: sha1,
            expectedSize: size,
            segmentSize: 1_048_576,
            maxConnections: bytes > smallFileThreshold ? 8 : 1
        )
    }
}
