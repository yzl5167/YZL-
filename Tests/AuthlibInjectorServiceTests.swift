import XCTest
@testable import YZLLauncher

/// authlib-injector：latest.json 解析（download_url / version / checksums.sha256）、
/// JVM 参数组装与 LaunchPlanBuilder 的追加。
final class AuthlibInjectorServiceTests: XCTestCase {
    // MARK: - latest.json 解析

    func testParseLatestWithStringSHA256() throws {
        let data = "{"
            + "\"build_number\": \"56\", "
            + "\"version\": \"1.2.8\", "
            + "\"release_time\": \"2024-01-01T00:00:00\", "
            + "\"download_url\": \"https://authlib-injector.yushi.moe/artifact/56/authlib-injector-1.2.8.jar\", "
            + "\"checksums\": {\"sha256\": [\"aabbcc\"]}"
            + "}".data(using: .utf8)!

        let artifact = try XCTUnwrap(AuthlibInjector.parseLatest(data))
        XCTAssertEqual(artifact.version, "1.2.8")
        XCTAssertEqual(
            artifact.downloadURL.absoluteString,
            "https://authlib-injector.yushi.moe/artifact/56/authlib-injector-1.2.8.jar"
        )
        XCTAssertEqual(artifact.sha256, "aabbcc", "checksums.sha256 是数组，取第一个")
    }

    func testParseLatestWithStringChecksumAndMissingFields() throws {
        // 有些镜像把 sha256 直接给成字符串。
        let flat = "{\"version\": \"1.2.5\", \"download_url\": \"https://x/y.jar\", \"checksums\": {\"sha256\": \"ff00\"}}"
            .data(using: .utf8)!
        XCTAssertEqual(AuthlibInjector.parseLatest(flat)?.sha256, "ff00")

        // 缺 download_url / version → nil。
        XCTAssertNil(AuthlibInjector.parseLatest(Data("{\"version\": \"1.2.5\"}".utf8)))
        XCTAssertNil(AuthlibInjector.parseLatest(Data("{\"download_url\": \"https://x/y.jar\"}".utf8)))
        XCTAssertNil(AuthlibInjector.parseLatest(Data("not json".utf8)))
    }

    // MARK: - JVM 参数

    func testJVMArgumentsShape() {
        let arguments = AuthlibInjector.jvmArguments(
            jarPath: "/tmp/authlib-injector-1.2.8.jar",
            serverURL: "https://littleskin.cn/api/yggdrasil"
        )
        XCTAssertEqual(arguments.count, 2)
        XCTAssertEqual(
            arguments[0],
            "-javaagent:/tmp/authlib-injector-1.2.8.jar=https://littleskin.cn/api/yggdrasil"
        )
        XCTAssertEqual(arguments[1], "-Dauthlibinjector.side=client")
    }

    func testIsInjectorArgument() {
        XCTAssertTrue(AuthlibInjector.isInjectorArgument("-javaagent:/x.jar=https://littleskin.cn/api/yggdrasil"))
        XCTAssertTrue(AuthlibInjector.isInjectorArgument("-Dauthlibinjector.side=client"))
        XCTAssertFalse(AuthlibInjector.isInjectorArgument("-Xmx4096M"))
        XCTAssertFalse(AuthlibInjector.isInjectorArgument("-Djava.library.path=/natives"))
    }

    // MARK: - LaunchPlanBuilder 追加

    func testLaunchPlanBuilderAppendsAuthlibArguments() throws {
        let detailData = try XCTUnwrap(Data(
            "{\"id\": \"1.20.1\", \"type\": \"release\", \"mainClass\": \"net.minecraft.client.main.Main\"}".utf8
        ))
        let detail = try JSONDecoder().decode(VersionDetail.self, from: detailData)
        let version = MinecraftVersion(
            id: "1.20.1",
            type: "release",
            url: URL(string: "https://piston-meta.mojang.com/v1/packages/x/1.20.1.json")!,
            time: "",
            releaseTime: ""
        )
        let layout = InstallLayout(versionID: "1.20.1", root: URL(fileURLWithPath: "/tmp/yzl-authlib-test"))
        let account = MicrosoftAccount(id: "uuid", name: "Steve", skinURL: nil)

        let plan = try LaunchPlanBuilder.build(
            detail: detail,
            version: version,
            layout: layout,
            account: account,
            accessToken: "token",
            memoryMB: 2048,
            maxHeapMB: 4096,
            userType: "mojang",
            authlibArguments: AuthlibInjector.jvmArguments(
                jarPath: "/tmp/authlib-injector-1.2.8.jar",
                serverURL: "https://littleskin.cn/api/yggdrasil"
            )
        )

        // 注入参数必须在 jvmArguments 末尾（-javaagent 排在 -cp 之前符合 JVM 语义）。
        XCTAssertEqual(plan.jvmArguments.suffix(2), [
            "-javaagent:/tmp/authlib-injector-1.2.8.jar=https://littleskin.cn/api/yggdrasil",
            "-Dauthlibinjector.side=client"
        ])
        // 默认不追加：不带参数的调用不应出现 -javaagent。
        let plain = try LaunchPlanBuilder.build(
            detail: detail,
            version: version,
            layout: layout,
            account: account,
            accessToken: "token",
            memoryMB: 2048
        )
        XCTAssertFalse(plain.jvmArguments.contains { AuthlibInjector.isInjectorArgument($0) })
    }
}
