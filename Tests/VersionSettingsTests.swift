import XCTest
@testable import YZLLauncher

/// 版本设置：每版本内存 / JVM 参数 / 窗口 / 全屏 / Java 锁定的模型与持久化。
/// 对齐 PC 端「版本设置」页。
final class VersionSettingsTests: XCTestCase {

    // MARK: - 模型

    func testDefaultHasNoCustomization() {
        let settings = PerVersionSettings(versionID: "1.20.1")
        XCTAssertFalse(settings.hasCustomization)
        XCTAssertTrue(settings.customJVMArgumentList.isEmpty)
        XCTAssertNil(settings.memoryMB)
        XCTAssertNil(settings.lockedJavaMajor)
        XCTAssertFalse(settings.fullscreen)
    }

    func testCustomJVMArgumentListParsing() {
        let settings = PerVersionSettings(
            versionID: "1.20.1",
            customJVMArguments: "  -XX:+UseG1GC   -Dexample.flag=true  \"-Dquoted=1\""
        )
        XCTAssertEqual(
            settings.customJVMArgumentList,
            ["-XX:+UseG1GC", "-Dexample.flag=true", "-Dquoted=1"]
        )
    }

    func testHasCustomizationReflectsEachField() {
        XCTAssertTrue(PerVersionSettings(versionID: "a", memoryMB: 4096).hasCustomization)
        XCTAssertTrue(PerVersionSettings(versionID: "a", fullscreen: true).hasCustomization)
        XCTAssertTrue(PerVersionSettings(versionID: "a", lockedJavaMajor: 17).hasCustomization)
        XCTAssertTrue(PerVersionSettings(versionID: "a", windowWidth: 854).hasCustomization)
        XCTAssertTrue(PerVersionSettings(versionID: "a", customJVMArguments: " -Xmx2G ").hasCustomization)
    }

    func testCodableRoundTrip() throws {
        let settings = PerVersionSettings(
            versionID: "neoforge-26.3.0.101",
            memoryMB: 3072,
            customJVMArguments: "-XX:+UseZGC",
            windowWidth: 1280,
            windowHeight: 720,
            fullscreen: true,
            lockedJavaMajor: 21
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PerVersionSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.versionID, "neoforge-26.3.0.101")
        XCTAssertEqual(decoded.memoryMB, 3072)
        XCTAssertEqual(decoded.windowWidth, 1280)
        XCTAssertEqual(decoded.windowHeight, 720)
        XCTAssertTrue(decoded.fullscreen)
        XCTAssertEqual(decoded.lockedJavaMajor, 21)
    }

    // MARK: - 持久化

    func testStoreStartsEmpty() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(VersionSettingsStore(fileURL: url).all().isEmpty)
    }

    func testStoreRoundTripAndOverride() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VersionSettingsStore(fileURL: url)

        store.update(PerVersionSettings(versionID: "1.20.1", memoryMB: 2048, lockedJavaMajor: 17))
        store.update(PerVersionSettings(versionID: "1.16.5", memoryMB: 1024))

        var loaded = store.all()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded["1.20.1"]?.memoryMB, 2048)
        XCTAssertEqual(loaded["1.20.1"]?.lockedJavaMajor, 17)
        XCTAssertEqual(loaded["1.16.5"]?.memoryMB, 1024)

        // 覆盖同一版本。
        store.update(PerVersionSettings(versionID: "1.20.1", memoryMB: 4096))
        loaded = store.all()
        XCTAssertEqual(loaded["1.20.1"]?.memoryMB, 4096)
        XCTAssertEqual(loaded.count, 2)
    }

    func testUpdateRemovesWhenNoCustomization() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VersionSettingsStore(fileURL: url)

        store.update(PerVersionSettings(versionID: "1.20.1", memoryMB: 4096))
        XCTAssertEqual(store.all().count, 1)

        // 改回默认：应从文件里删除该条目。
        store.update(PerVersionSettings(versionID: "1.20.1"))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testResetRemovesEntry() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VersionSettingsStore(fileURL: url)

        store.update(PerVersionSettings(versionID: "1.21", lockedJavaMajor: 21, fullscreen: true))
        XCTAssertEqual(store.all().count, 1)

        store.reset("1.21")
        XCTAssertTrue(store.all().isEmpty)
    }

    func testPersistenceAcrossInstances() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        VersionSettingsStore(fileURL: url).update(
            PerVersionSettings(versionID: "1.20.1", windowWidth: 854, windowHeight: 480)
        )
        let reloaded = VersionSettingsStore(fileURL: url).settings(for: "1.20.1")
        XCTAssertEqual(reloaded.windowWidth, 854)
        XCTAssertEqual(reloaded.windowHeight, 480)
    }

    private func temporaryStoreURL() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-test-version-settings-\(UUID().uuidString).json")
    }
}
