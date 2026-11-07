import XCTest
@testable import YZLLauncher

/// 覆盖「PC 能进、iOS 卡在正在加载地形」这条链路上的三处修复：
/// 画质/光影的移动端收敛、模组搬运与恢复、以及堆大小真的写进引擎偏好。
final class MobileCompatTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-compat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root = root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    // MARK: - 画质

    func testPatchesOptionsAndKeepsOtherKeys() throws {
        let options = """
        version:3465
        renderDistance:12
        maxFps:260
        renderClouds:"true"
        lang:zh_cn
        """
        try options.write(to: root.appendingPathComponent("options.txt"), atomically: true, encoding: .utf8)

        let report = try MobileCompat.apply(to: root, aggressive: false)
        let text = try String(contentsOf: root.appendingPathComponent("options.txt"), encoding: .utf8)

        XCTAssertTrue(text.contains("renderDistance:4"))
        XCTAssertTrue(text.contains("maxFps:60"))
        XCTAssertTrue(text.contains("renderClouds:\"false\""))
        XCTAssertFalse(text.contains("renderDistance:12"))
        XCTAssertTrue(text.contains("lang:zh_cn"), "不认识的键必须原样保留")
        XCTAssertTrue(report.lines.contains { $0.contains("画质") })
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".yzl-compat-backup/options.txt").path
            ),
            "改动前必须留备份"
        )
    }

    func testSecondRunIsNoOp() throws {
        try "renderDistance:12\nmaxFps:260\n".write(
            to: root.appendingPathComponent("options.txt"), atomically: true, encoding: .utf8
        )
        _ = try MobileCompat.apply(to: root, aggressive: false)
        let second = try MobileCompat.apply(to: root, aggressive: false)
        XCTAssertTrue(second.isEmpty, "幂等：第二次不应该再产生改动")
    }

    // MARK: - 光影

    func testDisablesIrisShadersAndKeepsPackName() throws {
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let iris = "enableShaders=true\nshaderPack=Windswept-Fantasy-Shaders-v0.8.3.zip\n"
        try iris.write(to: config.appendingPathComponent("iris.properties"), atomically: true, encoding: .utf8)

        _ = try MobileCompat.apply(to: root, aggressive: false)
        let text = try String(contentsOf: config.appendingPathComponent("iris.properties"), encoding: .utf8)

        XCTAssertTrue(text.contains("enableShaders=false"))
        XCTAssertTrue(text.contains("shaderPack=Windswept-Fantasy-Shaders-v0.8.3.zip"), "光影包名字要留着，桌面端还能开回来")
    }

    // MARK: - Sodium

    func testLowersSodiumStagingBuffers() throws {
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let json = """
        {"quality":{"weather_quality":"FAST"},"advanced":{"use_advanced_staging_buffers":true,"cpu_render_ahead_limit":3}}
        """
        try json.write(to: config.appendingPathComponent("sodium-options.json"), atomically: true, encoding: .utf8)

        _ = try MobileCompat.apply(to: root, aggressive: false)
        let data = try Data(contentsOf: config.appendingPathComponent("sodium-options.json"))
        let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        let advanced = object?["advanced"] as? [String: Any]

        XCTAssertEqual(advanced?["use_advanced_staging_buffers"] as? Bool, false)
        XCTAssertEqual((advanced?["cpu_render_ahead_limit"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((object?["quality"] as? [String: Any])?["weather_quality"] as? String, "FAST")
    }

    // MARK: - 模组搬运

    func testAggressiveQuarantinesRenderModsAndRestoreBringsThemBack() throws {
        let mods = root.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        let names = [
            "iris-1.7.6+mc1.20.1.jar",
            "sodium-fabric-0.5.13+mc1.20.1.jar",
            "appleskin-fabric-mc1.20.1-2.5.2.jar"
        ]
        for name in names {
            try Data([0x50, 0x4b]).write(to: mods.appendingPathComponent(name))
        }

        let report = try MobileCompat.apply(to: root, aggressive: true)
        XCTAssertEqual(report.quarantined, ["iris-1.7.6+mc1.20.1.jar", "sodium-fabric-0.5.13+mc1.20.1.jar"])
        XCTAssertEqual(MobileCompat.modCount(in: root), 1)

        let restored = try MobileCompat.restoreAll(in: root)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(MobileCompat.modCount(in: root), 3)
    }

    func testNonAggressivePutsSodiumBackButKeepsIrisOff() throws {
        let mods = root.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        for name in ["iris-1.7.6+mc1.20.1.jar", "sodium-fabric-0.5.13+mc1.20.1.jar", "appleskin-fabric-mc1.20.1-2.5.2.jar"] {
            try Data([0x50, 0x4b]).write(to: mods.appendingPathComponent(name))
        }

        _ = try MobileCompat.apply(to: root, aggressive: true)
        let second = try MobileCompat.apply(to: root, aggressive: false)

        XCTAssertTrue(second.restored.contains("sodium-fabric-0.5.13+mc1.20.1.jar"))
        XCTAssertEqual(MobileCompat.modCount(in: root), 2, "Sodium 回来了，Iris 仍然留在 mods-ios-off")
    }
}

/// 堆大小必须落在 Amethyst 真正读的那份偏好里，否则 UI 上写 4 GB、JVM 里还是 1 GB。
final class AmethystPreferencesTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-ame-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let home = home {
            try? FileManager.default.removeItem(at: home)
        }
        home = nil
    }

    func testWritesHeapIntoFreshHomeAndReadsBack() throws {
        XCTAssertTrue(try AmethystPreferences.apply(heapMB: 3072, homeDirectory: home))
        XCTAssertEqual(AmethystPreferences.currentHeapMB(homeDirectory: home), 3072)
        XCTAssertFalse(try AmethystPreferences.apply(heapMB: 3072, homeDirectory: home), "同样的堆不该重复写盘")
    }

    func testKeepsOtherSectionsIntact() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "video": ["renderer": "libmobileglues.dylib"],
            "java": ["auto_ram": true, "allocated_memory": 1024]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: existing, format: .xml, options: 0)
        try data.write(to: home.appendingPathComponent(AmethystPreferences.fileName))

        XCTAssertTrue(try AmethystPreferences.apply(heapMB: 4096, homeDirectory: home))

        let raw = try Data(contentsOf: home.appendingPathComponent(AmethystPreferences.fileName))
        let parsed = try PropertyListSerialization.propertyList(from: raw, options: [], format: nil) as? [String: Any]
        XCTAssertEqual((parsed?["video"] as? [String: Any])?["renderer"] as? String, "libmobileglues.dylib")
        XCTAssertEqual(AmethystPreferences.currentHeapMB(homeDirectory: home), 4096)
    }

    func testRendererRiskDetection() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let existing: [String: Any] = ["video": ["renderer": "libgl4es_114.dylib"]]
        let data = try PropertyListSerialization.data(fromPropertyList: existing, format: .xml, options: 0)
        try data.write(to: home.appendingPathComponent(AmethystPreferences.fileName))

        XCTAssertEqual(AmethystPreferences.rendererName(homeDirectory: home), "libgl4es_114.dylib")
        XCTAssertTrue(AmethystPreferences.isSodiumUnsafe(renderer: "auto"), "auto 在 1.20.1 上落到 gl4es")
        XCTAssertTrue(AmethystPreferences.isSodiumUnsafe(renderer: "libgl4es_114.dylib"))
        XCTAssertTrue(AmethystPreferences.isSodiumUnsafe(renderer: nil), "没写过偏好就是 Amethyst 默认值")
        XCTAssertFalse(AmethystPreferences.isSodiumUnsafe(renderer: "libmobileglues.dylib"))
    }
}

/// 转发给 fork 的 JVM 参数：堆要生效，Windows natives 路径绝不能带过去。
final class EngineJVMArgumentsTests: XCTestCase {
    func testBuildsHeapAndSkipsNativePaths() {
        let arguments = EngineJVMArguments.build(heapMB: 4096, javaMajor: 17)
        XCTAssertEqual(arguments.first, "-Xmx4096M")
        XCTAssertTrue(arguments.contains("-XX:+UseG1GC"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("-Djava.library.path") })
    }

    func testSanitizerDropsClasspathAndLibraryPath() {
        let raw = ["-Xss1M", "-Djava.library.path=/tmp/natives", "-cp", "/a.jar", "-Djava.class.path=/b.jar"]
        XCTAssertEqual(EngineJVMArguments.sanitized(from: raw), ["-Xss1M"])
    }
}
