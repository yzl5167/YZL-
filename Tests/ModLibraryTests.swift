import XCTest
@testable import YZLLauncher

/// 模组管理：清单（mods + mods-ios-off）、开关搬移（重名不覆盖）、删除。
final class ModLibraryTests: XCTestCase {
    private var root: URL!
    private var mods: URL { root.appendingPathComponent("mods", isDirectory: true) }
    private var off: URL { root.appendingPathComponent("mods-ios-off", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-modlib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: off, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.root) }
    }

    private func touch(_ directory: URL, _ name: String, content: String = "jar") throws {
        try Data(content.utf8).write(to: directory.appendingPathComponent(name))
    }

    // MARK: - 清单

    func testListModsMergesBothDirectories() throws {
        try touch(mods, "b.jar", content: "12345")
        try touch(mods, "a.jar")
        try touch(off, "sodium.jar")
        // 非 jar 文件不算模组。
        try touch(mods, "notes.txt")

        let list = MobileCompat.listMods(in: root)
        XCTAssertEqual(list.map(\.name), ["a.jar", "b.jar", "sodium.jar"], "按文件名排序，混合两个目录")
        XCTAssertEqual(list.first { $0.name == "a.jar" }?.isEnabled, true)
        XCTAssertEqual(list.first { $0.name == "sodium.jar" }?.isEnabled, false)
        XCTAssertEqual(list.first { $0.name == "b.jar" }?.size, 5)
    }

    // MARK: - 开关

    func testSetModEnabledMovesBetweenDirectories() throws {
        try touch(mods, "iris.jar")
        try touch(off, "sodium.jar")

        // 关：mods → mods-ios-off。
        try MobileCompat.setModEnabled(in: root, name: "iris.jar", enabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mods.appendingPathComponent("iris.jar").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: off.appendingPathComponent("iris.jar").path))

        // 开：mods-ios-off → mods。
        try MobileCompat.setModEnabled(in: root, name: "sodium.jar", enabled: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mods.appendingPathComponent("sodium.jar").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: off.appendingPathComponent("sodium.jar").path))
    }

    func testSetModEnabledNeverOverwritesExistingFile() throws {
        try touch(mods, "x.jar", content: "new")
        try touch(off, "x.jar", content: "old")

        try MobileCompat.setModEnabled(in: root, name: "x.jar", enabled: true)

        let entries = MobileCompat.listMods(in: root).filter { $0.name.hasPrefix("x") }
        XCTAssertEqual(entries.count, 2, "两边同名时搬移后应各留一份（不覆盖）")
        // mods 里的新文件保持原样，off 里的旧文件搬到 mods 后带时间戳后缀。
        XCTAssertEqual(try String(contentsOf: mods.appendingPathComponent("x.jar"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: off.appendingPathComponent("x.jar").path))
    }

    func testSetModEnabledIgnoresMissingFile() throws {
        // 找不到源文件时静默返回（UI 状态与磁盘短暂不一致的兜底）。
        try MobileCompat.setModEnabled(in: root, name: "ghost.jar", enabled: true)
        try MobileCompat.setModEnabled(in: root, name: "ghost.jar", enabled: false)
    }

    // MARK: - 删除

    func testDeleteModRemovesFromCorrectDirectory() throws {
        try touch(mods, "keep.jar")
        try touch(off, "gone.jar")

        MobileCompat.deleteMod(in: root, name: "gone.jar", isEnabled: false)
        MobileCompat.deleteMod(in: root, name: "missing.jar", isEnabled: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: mods.appendingPathComponent("keep.jar").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: off.appendingPathComponent("gone.jar").path))
    }

    // MARK: - 与「极端兼容」中转目录协同

    func testQuarantineAndListWorkTogether() throws {
        try touch(mods, "iris-1.6.jar")
        try touch(mods, "sodium-0.5.jar")
        try touch(mods, "fabric-api.jar")

        // 极端兼容把 Sodium 系移出 mods，模组清单应如实反映。
        let moved = try MobileCompat.quarantineMods(in: root, prefixes: MobileCompat.aggressiveModPrefixes)
        XCTAssertEqual(Set(moved), ["sodium-0.5.jar"])

        let list = MobileCompat.listMods(in: root)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list.filter { !$0.isEnabled }.map(\.name), ["sodium-0.5.jar"])
        // 全部恢复后 mods-ios-off 清空。
        _ = try MobileCompat.restoreAll(in: root)
        XCTAssertTrue(MobileCompat.listMods(in: root).allSatisfy(\.isEnabled))
    }
}
