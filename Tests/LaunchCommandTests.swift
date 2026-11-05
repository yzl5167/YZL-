import XCTest
@testable import YZLLauncher

final class LaunchCommandTests: XCTestCase {
    private func makePlan(token: String = "secret-token-123") throws -> LaunchPlan {
        let client = VersionDetail.Artifact(
            sha1: "0123456789abcdef",
            size: 23_028_853,
            url: URL(string: "https://piston-data.mojang.com/v1/objects/client.jar")!
        )
        let detail = VersionDetail(
            id: "1.20.1",
            type: "release",
            downloads: VersionDetail.Downloads(client: client),
            javaVersion: VersionDetail.JavaVersion(component: "java-runtime-delta", majorVersion: 17),
            mainClass: "net.minecraft.client.main.Main",
            libraries: [],
            assetIndex: nil,
            assets: "5"
        )
        let version = MinecraftVersion(
            id: "1.20.1",
            type: "release",
            url: URL(string: "https://piston-meta.mojang.com/v1/packages/1.20.1.json")!,
            time: "2023-06-12T12:00:00+00:00",
            releaseTime: "2023-06-12T12:00:00+00:00"
        )
        let account = MicrosoftAccount(
            id: "069a79f4-44e9-4726-a5be-fca90e38aaf5",
            name: "Steve",
            skinURL: nil
        )
        let layout = InstallLayout(
            versionID: "1.20.1",
            root: URL(fileURLWithPath: "/tmp/yzl-launch-command-test")
        )
        return try LaunchPlanBuilder.build(
            detail: detail,
            version: version,
            layout: layout,
            account: account,
            accessToken: token,
            memoryMB: 1024
        )
    }

    func testJVMArgumentsPrecedeClasspathAndMainClass() throws {
        let plan = try makePlan()
        let command = LaunchCommand.make(plan: plan)

        let cpIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-cp"))
        let mainIndex = try XCTUnwrap(command.arguments.firstIndex(of: plan.mainClass))
        let tokenIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--accessToken"))

        XCTAssertEqual(command.arguments.first, "-Xmx1024M")
        XCTAssertEqual(command.arguments[cpIndex + 1], plan.classpathString)
        XCTAssertEqual(mainIndex, cpIndex + 2)
        XCTAssertGreaterThan(tokenIndex, mainIndex)
        XCTAssertEqual(command.arguments.count, plan.jvmArguments.count + 3 + plan.gameArguments.count)
        XCTAssertEqual(command.mainClass, "net.minecraft.client.main.Main")
    }

    func testAccessTokenIsRedactedEverywhere() throws {
        let command = LaunchCommand.make(plan: try makePlan())

        XCTAssertTrue(command.arguments.contains("secret-token-123"))
        XCTAssertFalse(command.redactedArguments.contains("secret-token-123"))
        XCTAssertTrue(command.redactedArguments.contains("<redacted>"))
        XCTAssertFalse(command.redactedDescription.contains("secret-token-123"))
    }

    func testRedactionHandlesRepeatedTokens() {
        let arguments = ["--accessToken", "dup-token", "-Dfoo=dup-token", "--username", "Steve"]
        let redacted = LaunchCommand.redact(arguments)

        XCTAssertEqual(redacted[1], "<redacted>")
        XCTAssertFalse(redacted.contains("dup-token"))
        XCTAssertEqual(redacted[3], "--username")
    }

    func testEnvironmentNeverCarriesToken() throws {
        let command = LaunchCommand.make(
            plan: try makePlan(),
            javaHome: URL(fileURLWithPath: "/tmp/jre-17")
        )

        XCTAssertFalse(command.environment.values.contains("secret-token-123"))
        XCTAssertEqual(command.environment["JAVA_HOME"], "/tmp/jre-17")
        XCTAssertTrue(command.environment["YZL_GAME_DIR"]?.hasSuffix("/game") == true)
        XCTAssertTrue(command.environment["YZL_NATIVES_DIR"]?.hasSuffix("/natives") == true)
    }

    func testJavaHomeIsOptional() throws {
        let command = LaunchCommand.make(plan: try makePlan())
        XCTAssertNil(command.javaHome)
        XCTAssertNil(command.environment["JAVA_HOME"])
    }
}
