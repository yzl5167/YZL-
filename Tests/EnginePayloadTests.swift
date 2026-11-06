import XCTest
@testable import YZLLauncher

/// M2-b 引擎层测试：payload 扫描与启动契约（YZL_LAUNCH_PLAN.json）。
final class EnginePayloadTests: XCTestCase {
    private var tempBundle: URL!
    private var fileManager: FileManager!

    override func setUpWithError() throws {
        fileManager = .default
        tempBundle = fileManager.temporaryDirectory
            .appendingPathComponent("yzl-payload-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempBundle, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempBundle)
    }

    // MARK: - 扫描

    func testEmptyBundleReportsAllMissing() {
        let payload = EnginePayloadLocator.scan(bundleURL: tempBundle, fileManager: fileManager)

        XCTAssertFalse(payload.isLaunchable)
        XCTAssertEqual(
            Set(payload.missingKinds),
            [.javaRuntimes, .frameworks, .libs, .caciocavallo17],
            "caciocavallo8 只在 Java 8 需要，不算硬缺失"
        )
        XCTAssertTrue(payload.summary.contains("缺引擎件"))
    }

    func testCompletePayloadIsLaunchable() throws {
        try makeJavaRuntime("java-17-openjdk")
        try makeJavaRuntime("java-8-openjdk")
        try fileManager.createDirectory(at: tempBundle.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: tempBundle.appendingPathComponent("libs"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: tempBundle.appendingPathComponent("libs_caciocavallo"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: tempBundle.appendingPathComponent("libs_caciocavallo17"), withIntermediateDirectories: true)
        try Data().write(to: tempBundle.appendingPathComponent("Frameworks/libpojavexec.dylib"))
        try Data().write(to: tempBundle.appendingPathComponent("Frameworks/libgl4es_114.dylib"))
        try Data().write(to: tempBundle.appendingPathComponent("libs/PojavLauncher.jar"))
        try Data().write(to: tempBundle.appendingPathComponent("libs_caciocavallo17/cacio.jar"))
        // libs_caciocavallo（Java 8 版）留空——不算硬缺失。

        let payload = EnginePayloadLocator.scan(bundleURL: tempBundle, fileManager: fileManager)

        XCTAssertTrue(payload.isLaunchable)
        XCTAssertTrue(payload.summary.contains("引擎件齐备"))
        XCTAssertEqual(Set(payload.javaRuntimeNames), ["java-8-openjdk", "java-17-openjdk"])
        XCTAssertEqual(payload.frameworkCount, 2)
    }

    func testEmptyJavaRuntimeDirectoryDoesNotCount() throws {
        // java_runtimes 存在但里面没有可用 JRE（无 libjli 标记）——与 RuntimeLocator 一致，不算可用。
        try fileManager.createDirectory(
            at: tempBundle.appendingPathComponent("java_runtimes/fake-jre"),
            withIntermediateDirectories: true
        )
        try makeFrameworksWithDylib()
        try makeLibsWithJar()
        try makeCacio17()

        let payload = EnginePayloadLocator.scan(bundleURL: tempBundle, fileManager: fileManager)

        XCTAssertFalse(payload.isLaunchable)
        XCTAssertTrue(payload.missingKinds.contains(.javaRuntimes))
    }

    // MARK: - 启动契约

    func testContractDocumentFromLaunchPlan() throws {
        let plan = try makePlan()
        let document = try EngineLaunchContract.document(from: plan, accessToken: "token-123", xuid: "x-1")

        XCTAssertEqual(document.mainClass, "net.minecraft.client.main.Main")
        XCTAssertEqual(document.classpath.first, plan.layout.clientJar.path)
        XCTAssertEqual(document.accountName, "Steve")
        XCTAssertEqual(document.accessToken, "token-123")
        XCTAssertEqual(document.javaMajor, 17)
        XCTAssertEqual(document.memoryMB, 1024)
        XCTAssertTrue(document.gameArguments.contains("token-123"))
    }

    func testContractRejectsEmptyToken() throws {
        let plan = try makePlan(gameArguments: ["--username", "Steve"])
        XCTAssertThrowsError(try EngineLaunchContract.document(from: plan, accessToken: ""))
    }

    func testContractWriteRemoveRoundTrip() throws {
        let plan = try makePlan()
        let document = try EngineLaunchContract.document(from: plan, accessToken: "token-123")
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("yzl-contract-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let url = try EngineLaunchContract.write(document, homeDirectory: home)
        XCTAssertEqual(url.lastPathComponent, "yzl-launch-plan.json")
        XCTAssertTrue(fileManager.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(EngineLaunchContract.LaunchPlanDocument.self, from: data)
        XCTAssertEqual(decoded, document)

        EngineLaunchContract.remove(homeDirectory: home)
        XCTAssertFalse(fileManager.fileExists(atPath: url.path))
    }

    func testAccessTokenExtractionFromGameArguments() throws {
        let withToken = try makePlan(gameArguments: ["--username", "Steve", "--accessToken", "secret-token"])
        XCTAssertEqual(YZLEngineHost.accessTokenFromPlan(withToken), "secret-token")

        let offline = try makePlan(gameArguments: ["--username", "Steve", "--userType", "mojang"])
        XCTAssertEqual(YZLEngineHost.accessTokenFromPlan(offline), "offline", "离线计划回退固定占位值")

        let bare = try makePlan(gameArguments: ["--username", "Steve"])
        XCTAssertEqual(YZLEngineHost.accessTokenFromPlan(bare), "")
    }

    // MARK: - 工厂

    func testFactoryFallsBackToSeamEngineWhenSymbolsMissing() {
        // 测试进程里没有 launchJVM 符号（非 fork 构建）——工厂应回退到 M2 接缝实现。
        let engine = LauncherEngineFactory.make()
        XCTAssertFalse(engine.isAvailable)
        XCTAssertFalse(engine.name.contains("fork"), "无 fork 符号时不应选中 YZLEngineHost")
    }

    // MARK: - 造件工具

    private func makeJavaRuntime(_ name: String) throws {
        let jre = tempBundle.appendingPathComponent("java_runtimes/\(name)", isDirectory: true)
        try fileManager.createDirectory(at: jre.appendingPathComponent("lib/jli"), withIntermediateDirectories: true)
        try Data().write(to: jre.appendingPathComponent("lib/jli/libjli.dylib"))
    }

    private func makeFrameworksWithDylib() throws {
        let dir = tempBundle.appendingPathComponent("Frameworks", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("libpojavexec.dylib"))
    }

    private func makeLibsWithJar() throws {
        let dir = tempBundle.appendingPathComponent("libs", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("PojavLauncher.jar"))
    }

    private func makeCacio17() throws {
        let dir = tempBundle.appendingPathComponent("libs_caciocavallo17", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("cacio.jar"))
    }

    private func makePlan(gameArguments: [String]? = nil) throws -> LaunchPlan {
        let layout = InstallLayout(versionID: "1.20.1", root: URL(fileURLWithPath: "/tmp/yzl-engine-contract-test"))
        let version = MinecraftVersion(
            id: "1.20.1",
            type: "release",
            url: URL(string: "https://piston-meta.mojang.com/v1/packages/1.20.1.json")!,
            time: "2023-06-12T12:00:00+00:00",
            releaseTime: "2023-06-12T12:00:00+00:00"
        )
        let detail = VersionDetail(
            id: "1.20.1",
            type: "release",
            downloads: VersionDetail.Downloads(client: VersionDetail.Artifact(
                sha1: "abc",
                size: 1,
                url: URL(string: "https://example.com/client.jar")!
            )),
            javaVersion: VersionDetail.JavaVersion(component: nil, majorVersion: 17),
            mainClass: "net.minecraft.client.main.Main",
            libraries: [],
            assetIndex: nil,
            assets: "5"
        )
        return LaunchPlan(
            version: version,
            detail: detail,
            layout: layout,
            classpath: [layout.clientJar],
            assetIndexName: "5",
            mainClass: "net.minecraft.client.main.Main",
            memoryMB: 1024,
            jvmArguments: ["-Xmx1024M"],
            gameArguments: gameArguments ?? ["--username", "Steve", "--accessToken", "secret-token"],
            accountName: "Steve",
            uuid: "069a79f4-44e9-4726-a5be-fca90e38aaf5"
        )
    }
}
