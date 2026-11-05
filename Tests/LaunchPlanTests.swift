import XCTest
@testable import YZLLauncher

final class LaunchPlanTests: XCTestCase {
    private let layout = InstallLayout(
        versionID: "1.20.1",
        root: URL(fileURLWithPath: "/tmp/yzl-launch-plan-test")
    )

    private let account = MicrosoftAccount(
        id: "069a79f4-44e9-4726-a5be-fca90e38aaf5",
        name: "Steve",
        skinURL: nil
    )

    func testClasspathMatchesInstallPlanLibraryCount() throws {
        let detail = try decodeDetail("VersionDetail_1.20.1")
        let installPlan = InstallPlanner.plan(detail: detail, layout: layout)
        let classpath = LaunchPlanBuilder.classpath(detail: detail, layout: layout)

        XCTAssertEqual(classpath.count, installPlan.count(of: .library) + 1)
        XCTAssertEqual(classpath.first, layout.clientJar)
        XCTAssertTrue(classpath.allSatisfy { $0.path.hasPrefix(layout.root.path) })
    }

    func testBuildsJava17LaunchArguments() throws {
        let detail = try decodeDetail("VersionDetail_1.20.1")
        let version = makeVersion(id: "1.20.1", type: "release")
        let plan = try LaunchPlanBuilder.build(
            detail: detail,
            version: version,
            layout: layout,
            account: account,
            accessToken: "test-token-value",
            memoryMB: 1536
        )

        XCTAssertEqual(plan.mainClass, "net.minecraft.client.main.Main")
        XCTAssertEqual(plan.assetIndexName, "5")
        XCTAssertEqual(plan.memoryMB, 1536)
        XCTAssertEqual(plan.classpath.count, 44)
        XCTAssertTrue(plan.jvmArguments.contains("-Xmx1536M"))
        XCTAssertTrue(plan.jvmArguments.contains("-XX:+UseG1GC"))
        XCTAssertTrue(plan.jvmArguments.contains { $0.hasPrefix("-Djava.library.path=") })
        XCTAssertTrue(plan.gameArguments.contains("--accessToken"))
        XCTAssertTrue(plan.gameArguments.contains("test-token-value"))
        XCTAssertTrue(plan.gameArguments.contains("--userType"))
        XCTAssertFalse(plan.summary.contains("test-token-value"))
    }

    func testJava8DoesNotUseG1() throws {
        let detail = try decodeDetail("VersionDetail_1.12.2")
        let plan = try LaunchPlanBuilder.build(
            detail: detail,
            version: makeVersion(id: "1.12.2", type: "release"),
            layout: InstallLayout(versionID: "1.12.2", root: URL(fileURLWithPath: "/tmp/yzl-launch-plan-test")),
            account: account,
            accessToken: "test-token-value",
            memoryMB: 1024
        )

        XCTAssertFalse(plan.jvmArguments.contains("-XX:+UseG1GC"))
        XCTAssertTrue(plan.jvmArguments.contains("-Xmx1024M"))
    }

    func testMemoryIsClampedToSupportedRange() throws {
        let detail = try decodeDetail("VersionDetail_1.20.1")
        let low = try LaunchPlanBuilder.build(
            detail: detail,
            version: makeVersion(id: "1.20.1", type: "release"),
            layout: layout,
            account: account,
            accessToken: "token",
            memoryMB: 128
        )
        let high = try LaunchPlanBuilder.build(
            detail: detail,
            version: makeVersion(id: "1.20.1", type: "release"),
            layout: layout,
            account: account,
            accessToken: "token",
            memoryMB: 16_384
        )

        XCTAssertEqual(low.memoryMB, 512)
        XCTAssertEqual(high.memoryMB, 4096)
    }

    func testHeapHonorsDeviceSafeCeiling() throws {
        let detail = try decodeDetail("VersionDetail_1.20.1")
        let plan = try LaunchPlanBuilder.build(
            detail: detail,
            version: makeVersion(id: "1.20.1", type: "release"),
            layout: layout,
            account: account,
            accessToken: "token",
            memoryMB: 4096,
            maxHeapMB: 1536
        )

        XCTAssertEqual(plan.memoryMB, 1536)
        XCTAssertTrue(plan.jvmArguments.contains("-Xmx1536M"))
    }

    func testHeapCeilingNeverBelowMinimum() throws {
        let detail = try decodeDetail("VersionDetail_1.20.1")
        let plan = try LaunchPlanBuilder.build(
            detail: detail,
            version: makeVersion(id: "1.20.1", type: "release"),
            layout: layout,
            account: account,
            accessToken: "token",
            memoryMB: 4096,
            maxHeapMB: 128
        )

        XCTAssertEqual(plan.memoryMB, 512)
    }

    func testEmptyAccessTokenIsRejected() throws {
        let detail = try decodeDetail("VersionDetail_1.20.1")
        XCTAssertThrowsError(
            try LaunchPlanBuilder.build(
                detail: detail,
                version: makeVersion(id: "1.20.1", type: "release"),
                layout: layout,
                account: account,
                accessToken: "",
                memoryMB: 1024
            )
        )
    }

    func testVersionDetailCodableRoundTripKeepsLaunchFields() throws {
        let detail = try decodeDetail("VersionDetail_1.20.1")
        let data = try JSONEncoder().encode(detail)
        let decoded = try JSONDecoder().decode(VersionDetail.self, from: data)

        let plan = try LaunchPlanBuilder.build(
            detail: decoded,
            version: makeVersion(id: "1.20.1", type: "release"),
            layout: layout,
            account: account,
            accessToken: "test-token-value",
            memoryMB: 1024
        )

        XCTAssertEqual(plan.mainClass, "net.minecraft.client.main.Main")
        XCTAssertEqual(plan.assetIndexName, "5")
        XCTAssertEqual(plan.classpath.count, 44)
        XCTAssertEqual(plan.jvmArguments.first, "-Xmx1024M")
    }

    func testInstalledVersionRecordRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-installed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let record = InstalledVersion(
            id: "1.20.1",
            type: "release",
            releaseTime: "2023-06-12T12:00:00+00:00",
            detailURL: URL(string: "https://piston-meta.mojang.com/v1/packages/1.20.1.json")!,
            javaMajor: 17,
            assetIndex: "5",
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileCount: 3_620,
            totalBytes: 732_000_000
        )

        let store = InstalledVersionStore(root: root)
        store.save([record])

        let loaded = store.load()
        XCTAssertEqual(loaded, [record])
        XCTAssertEqual(loaded.first?.minecraftVersion.id, "1.20.1")
    }

    func testMinecraftVersionSelectionRoundTrip() throws {
        let version = makeVersion(id: "1.20.1", type: "release")
        let data = try JSONEncoder().encode(version)
        let decoded = try JSONDecoder().decode(MinecraftVersion.self, from: data)
        XCTAssertEqual(decoded, version)
    }

    private func makeVersion(id: String, type: String) -> MinecraftVersion {
        MinecraftVersion(
            id: id,
            type: type,
            url: URL(string: "https://piston-meta.mojang.com/v1/packages/\(id).json")!,
            time: "2023-06-12T12:00:00+00:00",
            releaseTime: "2023-06-12T12:00:00+00:00"
        )
    }

    private func decodeDetail(_ sample: String) throws -> VersionDetail {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: sample, withExtension: "json"))
        return try JSONDecoder().decode(VersionDetail.self, from: Data(contentsOf: url))
    }
}
