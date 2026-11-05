import XCTest
@testable import YZLLauncher

private final class RecordingBridge: EngineBridge {
    let isAvailable: Bool
    private(set) var received: LaunchCommand?

    init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    func launch(_ command: LaunchCommand) async throws {
        received = command
    }
}

final class EngineIntegrationTests: XCTestCase {
    private let fakeJavaHome = URL(fileURLWithPath: "/tmp/yzl-fake-jre")

    private func makePlan() throws -> LaunchPlan {
        let client = VersionDetail.Artifact(
            sha1: "abc",
            size: 1,
            url: URL(string: "https://example.com/client.jar")!
        )
        let detail = VersionDetail(
            id: "1.20.1",
            type: "release",
            downloads: VersionDetail.Downloads(client: client),
            javaVersion: VersionDetail.JavaVersion(component: nil, majorVersion: 17),
            mainClass: "net.minecraft.client.main.Main",
            libraries: [],
            assetIndex: nil,
            assets: "5"
        )
        let version = MinecraftVersion(
            id: "1.20.1",
            type: "release",
            url: URL(string: "https://example.com/1.20.1.json")!,
            time: "2023-06-12T12:00:00+00:00",
            releaseTime: "2023-06-12T12:00:00+00:00"
        )
        let account = MicrosoftAccount(id: "uuid", name: "Steve", skinURL: nil)
        let layout = InstallLayout(versionID: "1.20.1", root: URL(fileURLWithPath: "/tmp/yzl-engine-test"))
        return try LaunchPlanBuilder.build(
            detail: detail,
            version: version,
            layout: layout,
            account: account,
            accessToken: "engine-secret-token",
            memoryMB: 1024
        )
    }

    func testInjectedJITProbeDrivesStatus() {
        XCTAssertEqual(JITProbe.detect(using: { true }), .enabled)
        XCTAssertEqual(JITProbe.detect(using: { false }), .disabled)
    }

    func testEngineIsUnavailableWithoutBridge() {
        let engine = AmethystEngine(javaHome: { self.fakeJavaHome }, probe: { true })
        XCTAssertFalse(engine.isAvailable)
    }

    func testMissingRuntimeFailsBeforeAnythingElse() async throws {
        let engine = AmethystEngine(
            bridge: RecordingBridge(),
            javaHome: { nil },
            probe: { true }
        )
        await assertLaunchError(engine, expected: .runtimeMissing)
    }

    func testDisabledJITBlocksLaunch() async throws {
        let engine = AmethystEngine(
            bridge: RecordingBridge(),
            javaHome: { self.fakeJavaHome },
            probe: { false }
        )
        await assertLaunchError(engine, expected: .jitDisabled)
    }

    func testMissingBridgeReportsNotIntegrated() async throws {
        let engine = AmethystEngine(
            javaHome: { self.fakeJavaHome },
            probe: { true }
        )
        await assertLaunchError(engine, expected: .notIntegrated)
    }

    func testBridgeReceivesFullyAssembledCommand() async throws {
        let bridge = RecordingBridge()
        let engine = AmethystEngine(
            bridge: bridge,
            javaHome: { self.fakeJavaHome },
            probe: { true }
        )

        try await engine.launch(makePlan())

        let command = try XCTUnwrap(bridge.received)
        XCTAssertEqual(command.javaHome, fakeJavaHome)
        XCTAssertTrue(command.arguments.contains("engine-secret-token"))
        XCTAssertFalse(command.redactedArguments.contains("engine-secret-token"))
        XCTAssertTrue(command.arguments.contains("-cp"))
    }

    private func assertLaunchError(_ engine: AmethystEngine,
                                   expected: EngineError,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) async {
        do {
            try await engine.launch(makePlan())
            XCTFail("Expected a launch failure", file: file, line: line)
        } catch let error as EngineError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
