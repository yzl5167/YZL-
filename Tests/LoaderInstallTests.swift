import XCTest
@testable import YZLLauncher

/// 加载器（Fabric）安装链路测试：profile 解码 → Maven 坐标推导 →
/// 继承链解析 → 拍平合并 → 安装清单。数据来自真实 Fabric Meta 样本。
final class LoaderInstallTests: XCTestCase {
    private let fabricLayout = InstallLayout(
        versionID: "fabric-loader-0.16.14-1.20.1",
        root: URL(fileURLWithPath: "/tmp/yzl-loader-test")
    )

    // MARK: - profile 解码

    func testDecodesFabricProfileWithoutDownloads() throws {
        let detail = try decodeDetail("FabricProfile_1.20.1.sample")

        XCTAssertNil(detail.downloads, "Fabric profile 没有 downloads 键，解码不得失败")
        XCTAssertNil(detail.clientArtifact)
        XCTAssertEqual(detail.id, "fabric-loader-0.16.14-1.20.1")
        XCTAssertEqual(detail.inheritsFrom, "1.20.1")
        XCTAssertEqual(detail.mainClass, "net.fabricmc.loader.impl.launch.knot.KnotClient")
        XCTAssertEqual(detail.libraries?.count, 8)
        XCTAssertNil(detail.javaVersion, "Java 要求继承自父版本")
        XCTAssertNil(detail.assetIndex)

        // 顶层 sha1 / size（Fabric Meta 格式）。
        let asm = try XCTUnwrap(detail.libraries?.first { $0.name == "org.ow2.asm:asm:9.8" })
        XCTAssertEqual(asm.sha1, "dc19ecb3f7889b7860697215cae99c0f9b6f6b4b")
        XCTAssertEqual(asm.size, 126113)
        // intermediary / fabric-loader 连 sha1 都没有——下载时跳过哈希校验。
        let loader = try XCTUnwrap(detail.libraries?.first { $0.name == "net.fabricmc:fabric-loader:0.16.14" })
        XCTAssertNil(loader.sha1)
        XCTAssertNil(loader.size)
        XCTAssertNil(loader.downloads)
    }

    // MARK: - Maven 坐标

    func testMavenCoordinatesDeriveArtifactPath() throws {
        let mixin = try XCTUnwrap(MavenCoordinates("net.fabricmc:sponge-mixin:0.15.5+mixin.0.8.7"))
        XCTAssertEqual(
            mixin.artifactPath,
            "net/fabricmc/sponge-mixin/0.15.5+mixin.0.8.7/sponge-mixin-0.15.5+mixin.0.8.7.jar"
        )

        let withClassifier = try XCTUnwrap(MavenCoordinates("org.lwjgl:lwjgl:3.3.3:natives-ios"))
        XCTAssertEqual(
            withClassifier.artifactPath,
            "org/lwjgl/lwjgl/3.3.3/lwjgl-3.3.3-natives-ios.jar"
        )
    }

    func testMavenCoordinatesRejectBadNames() {
        XCTAssertNil(MavenCoordinates("not-a-coordinate"))
        XCTAssertNil(MavenCoordinates("a:b"))
        XCTAssertNil(MavenCoordinates("a::c"))
    }

    func testMavenFileURLJoinsRepoBase() throws {
        let coordinates = try XCTUnwrap(MavenCoordinates("net.fabricmc:fabric-loader:0.16.14"))
        let url = try XCTUnwrap(coordinates.fileURL(repoBase: "https://maven.fabricmc.net/"))
        XCTAssertEqual(
            url.absoluteString,
            "https://maven.fabricmc.net/net/fabricmc/fabric-loader/0.16.14/fabric-loader-0.16.14.jar"
        )
        // 仓库根没有斜杠也能拼对。
        let withoutSlash = try XCTUnwrap(coordinates.fileURL(repoBase: "https://maven.fabricmc.net"))
        XCTAssertEqual(withoutSlash.absoluteString, url.absoluteString)
        XCTAssertNil(coordinates.fileURL(repoBase: nil))
    }

    // MARK: - 拍平后的安装清单

    func testMergedFabricPlanUsesParentClientAndMavenLibraries() throws {
        let parent = try decodeDetail("VersionDetail_1.20.1")
        let fabric = try decodeDetail("FabricProfile_1.20.1.sample")

        let merged = VersionMerger.merge(root: fabric) { $0 == "1.20.1" ? parent : nil }

        XCTAssertEqual(merged.inheritsFrom, nil)
        XCTAssertEqual(merged.mainClass, "net.fabricmc.loader.impl.launch.knot.KnotClient")
        XCTAssertEqual(merged.javaVersion?.majorVersion, 17, "Java 要求来自父版本")
        XCTAssertEqual(merged.assetIndex?.id, "5", "资源索引来自父版本")
        XCTAssertEqual(merged.libraries?.count, 96, "父版本全部 88 条 + Fabric 8 条；平台过滤在安装器里做")

        let plan = InstallPlanner.plan(detail: merged, layout: fabricLayout)

        XCTAssertEqual(plan.count(of: .clientJar), 1, "客户端 jar 从父版本带下来")
        let jar = try XCTUnwrap(plan.specs.first { $0.id.hasPrefix("client-") })
        XCTAssertEqual(jar.url.host, "piston-data.mojang.com")
        XCTAssertEqual(jar.destination, fabricLayout.clientJar)

        XCTAssertEqual(plan.count(of: .library), 51)
        XCTAssertEqual(plan.count(of: .assetIndex), 1)

        // Maven 坐标库：URL 由仓库根 + 推导路径拼出，sha1 透传顶层字段。
        let asm = try XCTUnwrap(plan.specs.first { $0.id == "lib-org/ow2/asm/9.8/asm-9.8.jar" })
        XCTAssertEqual(asm.url.absoluteString, "https://maven.fabricmc.net/org/ow2/asm/9.8/asm-9.8.jar")
        XCTAssertEqual(asm.expectedSHA1, "dc19ecb3f7889b7860697215cae99c0f9b6f6b4b")
        XCTAssertEqual(asm.expectedSize, 126113)

        // 没有 sha1 的库仍然可下载（跳过哈希校验），maxConnections 为 1。
        let loaderLib = try XCTUnwrap(plan.specs.first {
            $0.id == "lib-net/fabricmc/fabric-loader/0.16.14/fabric-loader-0.16.14.jar"
        })
        XCTAssertNil(loaderLib.expectedSHA1)
        XCTAssertEqual(loaderLib.maxConnections, 1)

        // 字节统计：父版本 80,207,127 + Fabric 有 size 的 6 个库 1,880,449。
        XCTAssertEqual(plan.totalBytes, 80_207_127 + 1_880_449)
    }

    // MARK: - 继承链解析

    private func version(id: String, inheritsFrom: String?) -> VersionDetail {
        VersionDetail(
            id: id,
            type: "release",
            downloads: nil,
            javaVersion: nil,
            mainClass: id,
            libraries: [],
            assetIndex: nil,
            assets: nil,
            inheritsFrom: inheritsFrom,
            minecraftArguments: nil,
            arguments: nil
        )
    }

    func testResolverReturnsTopDownChain() async throws {
        let child = version(id: "fabric-1.20.1", inheritsFrom: "1.20.1")
        let parent = version(id: "1.20.1", inheritsFrom: nil)

        let chain = try await VersionInheritanceResolver.chain(root: child) { id in
            id == "1.20.1" ? parent : nil
        }

        XCTAssertEqual(chain.map(\.id), ["1.20.1", "fabric-1.20.1"])
    }

    func testResolverMissingParentThrows() async {
        let child = version(id: "fabric-1.20.1", inheritsFrom: "1.20.1")
        do {
            _ = try await VersionInheritanceResolver.chain(root: child) { _ in nil }
            XCTFail("父版本缺失应当抛错")
        } catch let error as VersionInheritanceResolver.ResolverError {
            XCTAssertEqual(error, .missingAncestor("1.20.1"))
        } catch {
            XCTFail("意外的错误类型：\(error)")
        }
    }

    func testResolverDetectsCycle() async {
        let a = version(id: "a", inheritsFrom: "b")
        let b = version(id: "b", inheritsFrom: "a")
        do {
            _ = try await VersionInheritanceResolver.chain(root: a) { id in
                id == "a" ? a : (id == "b" ? b : nil)
            }
            XCTFail("循环继承应当抛错")
        } catch let error as VersionInheritanceResolver.ResolverError {
            XCTAssertEqual(error, .cycleDetected("a"))
        } catch {
            XCTFail("意外的错误类型：\(error)")
        }
    }

    func testResolverDepthCap() async {
        // 造一条超过 maxDepth 的链：v12 → v11 → … → v1。
        var versions: [String: VersionDetail] = [:]
        for index in 1...14 {
            let id = "v\(index)"
            versions[id] = version(id: id, inheritsFrom: index > 1 ? "v\(index - 1)" : nil)
        }
        do {
            _ = try await VersionInheritanceResolver.chain(root: versions["v14"]!) { versions[$0] }
            XCTFail("超过深度上限应当抛错")
        } catch let error as VersionInheritanceResolver.ResolverError {
            guard case .cycleDetected = error else {
                return XCTFail("应为 cycleDetected，实际 \(error)")
            }
        } catch {
            XCTFail("意外的错误类型：\(error)")
        }
    }

    func testFlattenedResolvesMultiLevelChain() async throws {
        let grand = VersionDetail(
            id: "1.20.1",
            type: "release",
            downloads: VersionDetail.Downloads(client: VersionDetail.Artifact(
                sha1: "client-sha",
                size: 100,
                url: URL(string: "https://example.com/client.jar")!
            )),
            javaVersion: VersionDetail.JavaVersion(component: "java-runtime-gamma", majorVersion: 17),
            mainClass: "net.minecraft.client.main.Main",
            libraries: [],
            assetIndex: nil,
            assets: "5",
            inheritsFrom: nil,
            minecraftArguments: nil,
            arguments: nil
        )
        let mid = version(id: "fabric-1.20.1", inheritsFrom: "1.20.1")
        let child = version(id: "pack", inheritsFrom: "fabric-1.20.1")

        let flattened = try await VersionInheritanceResolver.flattened(root: child) { id in
            switch id {
            case "1.20.1": return grand
            case "fabric-1.20.1": return mid
            default: return nil
            }
        }

        XCTAssertNil(flattened.inheritsFrom)
        XCTAssertEqual(flattened.mainClass, "pack", "越具体的层主类优先")
        XCTAssertEqual(flattened.downloads?.client.sha1, "client-sha", "客户端 jar 从顶层祖先带下来")
        XCTAssertEqual(flattened.assets, "5")
    }

    // MARK: - 拍平结果落盘往返

    func testFlattenedDetailRoundTripsThroughJSON() throws {
        let parent = try decodeDetail("VersionDetail_1.20.1")
        let fabric = try decodeDetail("FabricProfile_1.20.1.sample")
        let merged = VersionMerger.merge(root: fabric) { $0 == "1.20.1" ? parent : nil }

        let data = try JSONEncoder().encode(merged)
        let decoded = try JSONDecoder().decode(VersionDetail.self, from: data)

        XCTAssertEqual(decoded.id, merged.id)
        XCTAssertNil(decoded.inheritsFrom)
        XCTAssertEqual(decoded.libraries?.count, merged.libraries?.count)
        XCTAssertEqual(decoded.clientArtifact?.sha1, merged.clientArtifact?.sha1)
    }

    // MARK: - classpath 一致性

    func testClasspathIncludesMavenLibraries() throws {
        let parent = try decodeDetail("VersionDetail_1.20.1")
        let fabric = try decodeDetail("FabricProfile_1.20.1.sample")
        let merged = VersionMerger.merge(root: fabric) { $0 == "1.20.1" ? parent : nil }

        let classpath = LaunchPlanBuilder.classpath(detail: merged, layout: fabricLayout)

        XCTAssertEqual(classpath.first, fabricLayout.clientJar)
        // 1 个客户端 jar + 51 个库，且与安装清单逐项一致（路径与去重规则同源）。
        XCTAssertEqual(classpath.count, 52)
        XCTAssertTrue(classpath.contains(
            fabricLayout.libraryURL(path: "net/fabricmc/fabric-loader/0.16.14/fabric-loader-0.16.14.jar")
        ))
    }

    // MARK: - 工具

    private func decodeDetail(_ sample: String) throws -> VersionDetail {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: sample, withExtension: "json"))
        return try JSONDecoder().decode(VersionDetail.self, from: Data(contentsOf: url))
    }
}
