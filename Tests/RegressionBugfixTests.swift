import XCTest
@testable import YZLLauncher

/// 2026-11-06 缺陷修复的回归测试。
/// 这些用例刻意使用 Mojang 官方的 `value`（单数）格式与含 `/` 的 Maven specID，
/// 因为旧测试的 fixture 被裁剪 / 用的是自造 `values`，把真实格式的解码问题漏掉了。
final class RegressionBugfixTests: XCTestCase {

    // MARK: - Helpers

    private func context(userType: String = "msa") -> ArgumentResolver.Context {
        // Context.userType 带默认值，本工具链的合成成员初始化器不接受显式标签传参，
        // 因此构造后赋值（与 LaunchPlanBuilder 的做法一致）。
        var value = ArgumentResolver.Context(
            accountName: "Steve",
            uuid: "069a79f4-44e9-4726-a5be-fca90e38aaf5",
            accessToken: "tok",
            xuid: "",
            versionID: "1.20.1",
            versionType: "release",
            assetsDir: "/assets",
            gameDir: "/game",
            nativesDir: "/natives",
            launcherName: "YZL Launcher",
            launcherVersion: "0.1",
            classpath: "/real/cp",
            assetsIndexName: "5",
            width: nil,
            height: nil
        )
        value.userType = userType
        return value
    }

    private func decode(_ json: String) throws -> VersionDetail {
        try JSONDecoder().decode(VersionDetail.self, from: Data(json.utf8))
    }

    // MARK: - A1: 官方 ruled token 用 `value`，且可为单字符串或数组

    func testOfficialRuledValueAsSingleStringDecodes() throws {
        let detail = try decode("""
        {"id":"1.20.1","type":"release","arguments":{
          "game":[{"rules":[{"action":"allow","features":{"is_demo_user":true}}],"value":"--demo"}],
          "jvm":["-Xss1M"]
        }}
        """)
        guard case .ruled(let values, let rules) = detail.arguments?.game?.first else {
            return XCTFail("官方 value 单字符串未解码成 ruled token")
        }
        XCTAssertEqual(values, ["--demo"])
        XCTAssertEqual(rules.count, 1)
    }

    func testOfficialRuledValueAsArrayDecodes() throws {
        let detail = try decode("""
        {"id":"1.20.1","type":"release","arguments":{
          "game":[{"rules":[{"action":"allow"}],"value":["--width","${resolution_width}"]}]
        }}
        """)
        guard case .ruled(let values, _) = detail.arguments?.game?.first else {
            return XCTFail("官方 value 数组未解码成 ruled token")
        }
        XCTAssertEqual(values, ["--width", "${resolution_width}"])
    }

    func testLegacyValuesKeyStillDecodes() throws {
        let detail = try decode("""
        {"id":"1.20.1","type":"release","arguments":{
          "game":[{"rules":[{"action":"allow"}],"values":["--demo"]}]
        }}
        """)
        guard case .ruled(let values, _) = detail.arguments?.game?.first else {
            return XCTFail("旧 values 格式失去兼容")
        }
        XCTAssertEqual(values, ["--demo"])
    }

    // MARK: - B1: 离线 userType 必须在官方 arguments 路径也生效

    func testUserTypePlaceholderResolvesInModernArguments() throws {
        let detail = try decode("""
        {"id":"1.20.1","type":"release","arguments":{
          "game":["--userType","${user_type}","--username","${auth_player_name}"]
        }}
        """)
        let args = ArgumentResolver.gameArguments(version: detail, context: context(userType: "mojang"))
        guard let index = args.firstIndex(of: "--userType") else {
            return XCTFail("缺少 --userType")
        }
        XCTAssertEqual(args[index + 1], "mojang")
        XCTAssertFalse(args.contains("${user_type}"))
    }

    func testUserTypePlaceholderResolvesForPremiumAccount() throws {
        let detail = try decode("""
        {"id":"1.20.1","type":"release","arguments":{"game":["--userType","${user_type}"]}}
        """)
        let args = ArgumentResolver.gameArguments(version: detail, context: context())
        XCTAssertEqual(args, ["--userType", "msa"])
    }

    // MARK: - B2: ${classpath} / -cp 必须在替换前剥离

    func testClasspathTokensAreStrippedBeforeSubstitution() throws {
        let detail = try decode("""
        {"id":"1.20.1","type":"release","arguments":{
          "jvm":["-Xss1M","-cp","${classpath}","-Djava.class.path=${classpath}"],
          "game":[]
        }}
        """)
        let jvm = ArgumentResolver.jvmArguments(version: detail, context: context())
        XCTAssertTrue(jvm.contains("-Xss1M"))
        XCTAssertFalse(jvm.contains("-cp"), "版本自带的 -cp 不应进入 jvmArguments")
        XCTAssertFalse(jvm.contains("/real/cp"), "classpath 不应被重复展开")
        XCTAssertFalse(jvm.contains { $0.contains("${classpath}") })
    }

    // MARK: - A2: 空的 arguments.game 应回退，不能生成空命令行

    func testEmptyGameArgumentsFallsBackToSafeDefaults() throws {
        let detail = try decode("""
        {"id":"1.20.1","type":"release","arguments":{"game":[],"jvm":[]}}
        """)
        let args = ArgumentResolver.gameArguments(version: detail, context: context(userType: "mojang"))
        XCTAssertTrue(args.contains("--username"))
        XCTAssertTrue(args.contains("--accessToken"))
        XCTAssertEqual(args[args.firstIndex(of: "--userType")! + 1], "mojang")
    }

    // MARK: - A3: specID 含 `/` 时断点状态仍可落盘回读

    func testResumeStateStoreHandlesSlashInSpecID() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yzl-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ResumeStateStore(directory: directory)
        let specID = "lib-org/ow2/asm/9.8/asm-9.8.jar"
        let spec = DownloadSpec(
            id: specID,
            url: URL(string: "https://example.com/asm-9.8.jar")!,
            destination: directory.appendingPathComponent("asm-9.8.jar"),
            expectedSHA1: nil,
            expectedSize: nil
        )
        let segment = DownloadSegment(start: 0, end: 1023)

        XCTAssertEqual(store.stateURL(for: specID).deletingLastPathComponent().lastPathComponent,
                       directory.lastPathComponent,
                       "state 文件不能落进未创建的子目录")
        XCTAssertEqual(store.partURL(for: spec, segment: segment).deletingLastPathComponent().lastPathComponent,
                       directory.lastPathComponent,
                       "分片文件不能落进未创建的子目录")

        store.save(DownloadState(spec: spec, segments: [segment], updatedAt: Date()))
        XCTAssertNotNil(store.load(specID), "含 / 的 specID 应能写回并读回断点状态")

        try Data("part".utf8).write(to: store.partURL(for: spec, segment: segment))
        store.clear(specID)
        XCTAssertNil(store.load(specID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.partURL(for: spec, segment: segment).path),
                       "clear 应能按安全化后的前缀清掉分片")
    }
}
