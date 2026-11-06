import XCTest
import UIKit
@testable import YZLLauncher

/// 下载源镜像（BMCLAPI）改写、加载器 Meta 条目解码与本地皮肤存储的测试。
final class MirrorPolicyTests: XCTestCase {
    // MARK: - 官方源原样返回

    func testOfficialSourceKeepsURLsUntouched() throws {
        let urls = [
            "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json",
            "https://piston-data.mojang.com/v1/objects/abc/client.jar",
            "https://resources.download.minecraft.net/b6/b62ca8ec10d07e6bf5ac8dae0c8c1d2e6a1e3356",
            "https://meta.fabricmc.net/v2/versions/loader/1.20.1"
        ]
        for raw in urls {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(MirrorPolicy.rewrite(url, source: .official).absoluteString, raw)
        }
    }

    // MARK: - 镜像改写（与 Android 端 Mirrors.kt 同一张映射表）

    func testMirrorRewritesMojangHosts() throws {
        let cases: [(String, String)] = [
            ("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json",
             "https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json"),
            ("https://piston-meta.mojang.com/v1/packages/abc/1.20.1.json",
             "https://bmclapi2.bangbang93.com/v1/packages/abc/1.20.1.json"),
            ("https://piston-data.mojang.com/v1/objects/abc/client.jar",
             "https://bmclapi2.bangbang93.com/v1/objects/abc/client.jar"),
            ("https://resources.download.minecraft.net/b6/b62ca8ec10d07e6bf5ac8dae0c8c1d2e6a1e3356",
             "https://bmclapi2.bangbang93.com/assets/b6/b62ca8ec10d07e6bf5ac8dae0c8c1d2e6a1e3356"),
            ("https://libraries.minecraft.net/com/google/guava/guava/32.0/guava-32.0.jar",
             "https://bmclapi2.bangbang93.com/maven/com/google/guava/guava/32.0/guava-32.0.jar")
        ]
        for (official, mirrored) in cases {
            let url = try XCTUnwrap(URL(string: official))
            XCTAssertEqual(
                MirrorPolicy.rewrite(url, source: .mirror).absoluteString,
                mirrored,
                official
            )
        }
    }

    func testMirrorRewritesLoaderMetaHosts() throws {
        let fabricList = try XCTUnwrap(URL(string: "https://meta.fabricmc.net/v2/versions/loader/1.20.1"))
        XCTAssertEqual(
            MirrorPolicy.rewrite(fabricList, source: .mirror).absoluteString,
            "https://bmclapi2.bangbang93.com/fabric-meta/v2/versions/loader/1.20.1"
        )

        let quiltProfile = try XCTUnwrap(URL(string: "https://meta.quiltmc.org/v3/versions/loader/1.20.1/0.24.0/profile/json"))
        XCTAssertEqual(
            MirrorPolicy.rewrite(quiltProfile, source: .mirror).absoluteString,
            "https://bmclapi2.bangbang93.com/quilt-meta/v3/versions/loader/1.20.1/0.24.0/profile/json"
        )

        let fabricMaven = try XCTUnwrap(URL(string: "https://maven.fabricmc.net/net/fabricmc/fabric-loader/0.16.14/fabric-loader-0.16.14.jar"))
        XCTAssertEqual(
            MirrorPolicy.rewrite(fabricMaven, source: .mirror).absoluteString,
            "https://bmclapi2.bangbang93.com/maven/net/fabricmc/fabric-loader/0.16.14/fabric-loader-0.16.14.jar"
        )
    }

    func testMirrorLeavesUnknownHostsAlone() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/some/file.jar"))
        XCTAssertEqual(
            MirrorPolicy.rewrite(url, source: .mirror).absoluteString,
            "https://example.com/some/file.jar"
        )
    }

    func testSourceFallsBackToOfficialOnBadValue() {
        XCTAssertEqual(MirrorPolicy.source(nil), .official)
        XCTAssertEqual(MirrorPolicy.source(""), .official)
        XCTAssertEqual(MirrorPolicy.source("whatever"), .official)
        XCTAssertEqual(MirrorPolicy.source("mirror"), .mirror)
    }

    // MARK: - 加载器条目解码（Fabric 有 stable，Quilt 没有）

    func testFabricEntryDecodesStableFlag() throws {
        let json = Data(#"{"loader":{"version":"0.16.14","maven":"net.fabricmc:fabric-loader:0.16.14","stable":true}}"#.utf8)
        let entry = try JSONDecoder().decode(LoaderEntry.self, from: json)
        XCTAssertEqual(entry.version, "0.16.14")
        XCTAssertTrue(entry.isStable)
    }

    func testQuiltEntryWithoutStableUsesBetaHeuristic() throws {
        let beta = try JSONDecoder().decode(
            LoaderEntry.self,
            from: Data(#"{"loader":{"version":"0.20.0-beta.9","maven":"org.quiltmc:quilt-loader:0.20.0-beta.9"}}"#.utf8)
        )
        XCTAssertFalse(beta.isStable, "Quilt 没有稳定标记，beta 版本号应判为非稳定")

        let release = try JSONDecoder().decode(
            LoaderEntry.self,
            from: Data(#"{"loader":{"version":"0.24.0","maven":"org.quiltmc:quilt-loader:0.24.0"}}"#.utf8)
        )
        XCTAssertTrue(release.isStable)
    }

    // MARK: - 加载器 Meta URL（v2 / v3 分流）

    func testLoaderKindURLs() throws {
        XCTAssertEqual(
            LoaderKind.fabric.loaderListURL(gameVersion: "1.20.1").absoluteString,
            "https://meta.fabricmc.net/v2/versions/loader/1.20.1"
        )
        XCTAssertEqual(
            LoaderKind.quilt.loaderListURL(gameVersion: "1.20.1").absoluteString,
            "https://meta.quiltmc.org/v3/versions/loader/1.20.1"
        )
        XCTAssertEqual(
            LoaderKind.quilt.profileURL(gameVersion: "1.20.1", loaderVersion: "0.24.0").absoluteString,
            "https://meta.quiltmc.org/v3/versions/loader/1.20.1/0.24.0/profile/json"
        )
    }

    // MARK: - 本地皮肤存储

    private func image(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testSkinTextureSizeValidation() {
        XCTAssertTrue(LocalSkinStore.isValidSkinTexture(image(width: 64, height: 32)))
        XCTAssertTrue(LocalSkinStore.isValidSkinTexture(image(width: 64, height: 64)))
        XCTAssertTrue(LocalSkinStore.isValidSkinTexture(image(width: 128, height: 64)))
        XCTAssertTrue(LocalSkinStore.isValidSkinTexture(image(width: 128, height: 128)))

        XCTAssertFalse(LocalSkinStore.isValidSkinTexture(image(width: 100, height: 100)))
        XCTAssertFalse(LocalSkinStore.isValidSkinTexture(image(width: 32, height: 32)))
        XCTAssertFalse(LocalSkinStore.isValidSkinTexture(image(width: 64, height: 96)))
    }

    func testLocalSkinSaveLoadRemoveRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-skin-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LocalSkinStore(directory: directory)
        let accountID = "069a79f4-44e9-4726-a5be-fca90e38aaf5"

        // 非法尺寸不落盘。
        XCTAssertThrowsError(try store.save(image: image(width: 100, height: 100), accountID: accountID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(fileName: "\(accountID).png").path))

        // 合法尺寸：保存 → 引用 → 取回 → 删除。
        let reference = try store.save(image: image(width: 64, height: 64), accountID: accountID)
        XCTAssertTrue(reference.hasPrefix("\(LocalSkinStore.scheme)://\(accountID).png?v="))
        XCTAssertTrue(reference.contains("?v="), "重复导入时引用必须变化，UI 才会重新取图")

        let url = try XCTUnwrap(URL(string: reference))
        XCTAssertEqual(url.host, "\(accountID).png", "文件名取自 host，查询参数不参与路径")
        let loaded = try XCTUnwrap(store.load(from: url))
        XCTAssertEqual(loaded.cgImage?.width, 64)

        store.remove(accountID: accountID)
        XCTAssertNil(store.load(from: url))
    }

    func testLocalSkinStoreIgnoresForeignSchemes() throws {
        let store = LocalSkinStore(directory: FileManager.default.temporaryDirectory)
        let remote = try XCTUnwrap(URL(string: "https://textures.minecraft.net/texture/abc"))
        XCTAssertNil(store.load(from: remote))
    }
}
