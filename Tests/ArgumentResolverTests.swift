import XCTest
@testable import YZLLauncher

final class ArgumentResolverTests: XCTestCase {
    private let layout = InstallLayout(versionID: "1.20.1", root: URL(fileURLWithPath: "/tmp/yzl-args-test"))
    private let account = MicrosoftAccount(
        id: "069a79f4-44e9-4726-a5be-fca90e38aaf5",
        name: "Steve",
        skinURL: nil
    )

    private func context(classpath: String = "/cp", width: Int? = nil, height: Int? = nil) -> ArgumentResolver.Context {
        ArgumentResolver.Context(
            accountName: account.name,
            uuid: account.id,
            accessToken: "tok",
            xuid: "",
            versionID: "1.20.1",
            versionType: "release",
            assetsDir: layout.assetsDirectory.path,
            gameDir: layout.gameDirectory.path,
            nativesDir: layout.nativesDirectory.path,
            launcherName: "YZL Launcher",
            launcherVersion: "0.1",
            classpath: classpath,
            assetsIndexName: "5",
            width: width,
            height: height
        )
    }

    /// 1.20.1 真实 `arguments` 结构（节选），用于覆盖新格式路径。
    private func detailWithArguments() throws -> VersionDetail {
        let json = """
        {
          "id": "1.20.1",
          "type": "release",
          "mainClass": "net.minecraft.client.main.Main",
          "arguments": {
            "game": [
              "--username", "${auth_player_name}",
              "--version", "${version_name}",
              "--gameDir", "${game_directory}",
              "--assetsDir", "${assets_root}",
              "--assetIndex", "${assets_index_name}",
              "--uuid", "${auth_uuid}",
              "--accessToken", "${auth_access_token}",
              "--session", "${auth_session}",
              "--versionType", "${version_type}",
              {"rules":[{"action":"allow","features":{"is_demo_user":true}}],"values":["--demo"]},
              {"rules":[{"action":"allow","features":{"has_custom_resolution":true}}],"values":["--width","${resolution_width}","--height","${resolution_height}"]}
            ],
            "jvm": [
              "-Xss1M",
              "-Djava.library.path=${natives_directory}",
              "-Dminecraft.launcher.brand=${launcher_name}",
              "-Dminecraft.launcher.version=${launcher_version}",
              {"rules":[{"action":"allow","os":{"name":"osx"}}],"values":["-Xdock:name=Test","-Xdock:icon=icon.png"]},
              "-cp", "${classpath}"
            ]
          }
        }
        """.data(using: .utf8)!
        return try JSONDecoder().decode(VersionDetail.self, from: json)
    }

    func testModernGameArgumentsResolvePlaceholders() throws {
        let detail = try detailWithArguments()
        let args = ArgumentResolver.gameArguments(version: detail, context: context())

        XCTAssertTrue(args.contains("--username"))
        XCTAssertEqual(args[args.firstIndex(of: "--username")! + 1], "Steve")
        XCTAssertFalse(args.contains("${auth_player_name}"))
        XCTAssertEqual(args[args.firstIndex(of: "--accessToken")! + 1], "tok")
        XCTAssertEqual(args[args.firstIndex(of: "--assetIndex")! + 1], "5")
        XCTAssertEqual(args[args.firstIndex(of: "--uuid")! + 1], account.id)
        // 我们始终用正版账户，不是 demo 用户，--demo 应被 feature 规则过滤掉。
        XCTAssertFalse(args.contains("--demo"))
    }

    func testCustomResolutionAppearsOnlyWhenProvided() throws {
        let detail = try detailWithArguments()
        var args = ArgumentResolver.gameArguments(version: detail, context: context())
        XCTAssertFalse(args.contains("--width"))

        args = ArgumentResolver.gameArguments(version: detail, context: context(width: 854, height: 480))
        XCTAssertEqual(args[args.firstIndex(of: "--width")! + 1], "854")
        XCTAssertEqual(args[args.firstIndex(of: "--height")! + 1], "480")
    }

    func testJVMArgumentsStripClasspathAndFilterOSRules() throws {
        let detail = try detailWithArguments()
        let args = ArgumentResolver.jvmArguments(version: detail, context: context(classpath: "/real/cp"))

        XCTAssertTrue(args.contains("-Xss1M"))
        XCTAssertTrue(args.contains { $0.hasPrefix("-Djava.library.path=") })
        XCTAssertTrue(args.contains("-Dminecraft.launcher.brand=YZL Launcher"))
        // macOS 专用 dock 参数在 iOS 上应被 os 规则过滤掉。
        XCTAssertFalse(args.contains("-Xdock:name=Test"))
        // 由 ${classpath} 派生的项被剥离，最终由 LaunchCommand 用 -cp 统一注入。
        XCTAssertFalse(args.contains { $0.contains("${classpath}") })
        XCTAssertFalse(args.contains("-cp"))
    }

    func testLegacyMinecraftArgumentsFormat() throws {
        let json = """
        {"id":"1.12.2","type":"release","mainClass":"x","minecraftArguments":"--username ${auth_player_name} --version ${version_name} --accessToken ${auth_access_token}"}
        """.data(using: .utf8)!
        let detail = try JSONDecoder().decode(VersionDetail.self, from: json)
        let args = ArgumentResolver.gameArguments(version: detail, context: context())

        XCTAssertEqual(args[args.firstIndex(of: "--username")! + 1], "Steve")
        XCTAssertEqual(args[args.firstIndex(of: "--accessToken")! + 1], "tok")
        XCTAssertFalse(args.contains("${auth_player_name}"))
    }

    func testFallbackWhenNoArgumentsProvided() throws {
        let json = """
        {"id":"custom","type":"release","mainClass":"x"}
        """.data(using: .utf8)!
        let detail = try JSONDecoder().decode(VersionDetail.self, from: json)
        let args = ArgumentResolver.gameArguments(version: detail, context: context())

        XCTAssertEqual(args[args.firstIndex(of: "--username")! + 1], "Steve")
        XCTAssertEqual(args[args.firstIndex(of: "--accessToken")! + 1], "tok")
        XCTAssertTrue(args.contains("--userType"))
    }
}
