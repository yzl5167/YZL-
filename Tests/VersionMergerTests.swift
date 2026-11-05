import XCTest
@testable import YZLLauncher

final class VersionMergerTests: XCTestCase {
    private func lib(_ name: String) -> VersionDetail.Library {
        VersionDetail.Library(
            name: name,
            url: nil,
            rules: nil,
            downloads: VersionDetail.Library.DownloadInfo(
                artifact: VersionDetail.Library.ArtifactEntry(
                    path: "\(name).jar",
                    sha1: nil,
                    size: nil,
                    url: URL(string: "https://example.com/\(name).jar")!
                ),
                classifiers: nil
            )
        )
    }

    private func version(id: String,
                         inheritsFrom: String? = nil,
                         mainClass: String? = nil,
                         libraries: [VersionDetail.Library] = [],
                         clientURL: URL? = nil,
                         arguments: VersionDetail.VersionArguments? = nil) -> VersionDetail {
        let downloads: VersionDetail.Downloads?
        if let clientURL {
            downloads = VersionDetail.Downloads(client: VersionDetail.Artifact(sha1: "x", size: 1, url: clientURL))
        } else {
            downloads = nil
        }
        return VersionDetail(
            id: id,
            type: "release",
            downloads: downloads,
            javaVersion: VersionDetail.JavaVersion(component: nil, majorVersion: 17),
            mainClass: mainClass,
            libraries: libraries,
            assetIndex: nil,
            assets: "5",
            inheritsFrom: inheritsFrom,
            minecraftArguments: nil,
            arguments: arguments
        )
    }

    func testMergesLibrariesAndUsesChildMainClass() throws {
        let parent = version(id: "1.20.1", mainClass: "net.minecraft.client.main.Main", libraries: [lib("a"), lib("b")])
        let child = version(
            id: "forge-1.20.1",
            inheritsFrom: "1.20.1",
            mainClass: "cpw.mods.bootstraplauncher.BootstrapLauncher",
            libraries: [lib("c")]
        )

        let merged = VersionMerger.merge(root: child) { id in
            XCTAssertEqual(id, "1.20.1")
            return parent
        }

        XCTAssertNil(merged.inheritsFrom)
        XCTAssertEqual(merged.mainClass, "cpw.mods.bootstraplauncher.BootstrapLauncher")
        XCTAssertEqual(merged.libraries?.count ?? 0, 3)
        XCTAssertEqual(Set(merged.libraries?.map(\.name) ?? []), ["a", "b", "c"])
        XCTAssertEqual(merged.assets, "5")
    }

    func testChildWithoutClientUsesParentClient() throws {
        let parent = version(id: "1.20.1", clientURL: URL(string: "https://example.com/1.20.1.jar")!)
        let child = version(id: "forge-1.20.1", inheritsFrom: "1.20.1")

        let merged = VersionMerger.merge(root: child) { _ in parent }

        XCTAssertEqual(merged.downloads?.client.url.absoluteString, "https://example.com/1.20.1.jar")
    }

    func testChildArgumentsOverrideParent() throws {
        let parentArgs = VersionDetail.VersionArguments(jvm: [.string("-Xmx1G")], game: nil)
        let childArgs = VersionDetail.VersionArguments(jvm: [.string("-Xmx2G")], game: nil)
        let parent = version(id: "1.20.1", arguments: parentArgs)
        let child = version(id: "forge-1.20.1", inheritsFrom: "1.20.1", arguments: childArgs)

        let merged = VersionMerger.merge(root: child) { _ in parent }
        XCTAssertEqual(merged.arguments?.jvm, [.string("-Xmx2G")])
    }

    func testMissingParentReturnsRoot() throws {
        let child = version(id: "forge-1.20.1", inheritsFrom: "1.20.1", mainClass: "forge")
        let merged = VersionMerger.merge(root: child) { _ in nil }
        XCTAssertEqual(merged.mainClass, "forge")
        // 父版本取不到时无法合并，保留原始 inheritsFrom，启动自检会据此提示缺父版本。
        XCTAssertEqual(merged.inheritsFrom, "1.20.1")
    }

    func testMultiLevelInheritance() throws {
        let grand = version(id: "1.20.1", mainClass: "mc", libraries: [lib("base")])
        let mid = version(id: "fabric-1.20.1", inheritsFrom: "1.20.1", libraries: [lib("fabric")])
        let child = version(id: "modpack", inheritsFrom: "fabric-1.20.1", libraries: [lib("pack")])

        let merged = VersionMerger.merge(root: child) { id in
            if id == "1.20.1" { return grand }
            if id == "fabric-1.20.1" { return mid }
            return nil
        }
        XCTAssertEqual(merged.libraries?.count ?? 0, 3)
        XCTAssertEqual(merged.mainClass, "mc")
    }
}
