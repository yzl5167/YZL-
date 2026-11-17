import XCTest
@testable import YZLLauncher

/// 默认虚拟键位（FCL / Pojav 同款）：确保 YZL 的 AME_HOME 下总有一份可用的
/// default.json，游戏里才看得到悬浮按键 / 抽屉 / 摇杆。
final class ControlLayoutTests: XCTestCase {

    private func tempHome(_ name: String = UUID().uuidString) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("YZLControlTest-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testBuiltinLayoutIsValidVersion8JSON() throws {
        let data = try XCTUnwrap(AmethystPreferences.builtinDefaultLayout.data(using: .utf8))
        let obj = try JSONSerialization.jsonObject(with: data)
        let dict = try XCTUnwrap(obj as? [String: Any])
        XCTAssertEqual((dict["version"] as? Int), 8)
        XCTAssertNotNil(dict["mControlDataList"])
        XCTAssertNotNil(dict["mDrawerDataList"])
        XCTAssertNotNil(dict["mJoystickDataList"])
    }

    func testBuiltinLayoutHasEssentialButtons() throws {
        let data = try XCTUnwrap(AmethystPreferences.builtinDefaultLayout.data(using: .utf8))
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let controls = try XCTUnwrap(dict["mControlDataList"] as? [[String: Any]])
        let names = controls.compactMap { $0["name"] as? String }
        for required in ["Jump", "Pause", "Inventory", "Left\nClick", "Right\nClick", "Hide\nGUI"] {
            XCTAssertTrue(names.contains(required), "缺少关键按钮: \(required)")
        }
        // Jump 必须是空格键 (GLFW 32)
        let jump = controls.first { ($0["name"] as? String) == "Jump" }
        let jumpKeys = try XCTUnwrap(jump?["keycodes"] as? [Int])
        XCTAssertEqual(jumpKeys.first, 32)
    }

    func testBuiltinLayoutSpecialButtonsUseNegativeKeycodes() throws {
        let data = try XCTUnwrap(AmethystPreferences.builtinDefaultLayout.data(using: .utf8))
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let controls = try XCTUnwrap(dict["mControlDataList"] as? [[String: Any]])
        // Pojav utils.h: SPECIALBTN_* 都是负数，写成正数会导致功能按钮失效。
        let menu = controls.first { ($0["name"] as? String) == "Runtime\nMenu" }
        XCTAssertEqual((try XCTUnwrap(menu?["keycodes"] as? [Int])).first, -9)
        let hideGUI = controls.first { ($0["name"] as? String) == "Hide\nGUI" }
        XCTAssertEqual((try XCTUnwrap(hideGUI?["keycodes"] as? [Int])).first, -2)
    }

    func testBuiltinLayoutHasFloatingDrawerAndJoystick() throws {
        let data = try XCTUnwrap(AmethystPreferences.builtinDefaultLayout.data(using: .utf8))
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let drawers = try XCTUnwrap(dict["mDrawerDataList"] as? [[String: Any]])
        XCTAssertFalse(drawers.isEmpty, "缺少悬浮抽屉按钮")
        let props = try XCTUnwrap(drawers.first?["properties"] as? [String: Any])
        XCTAssertEqual(props["name"] as? String, "More")
        let items = try XCTUnwrap(drawers.first?["buttonProperties"] as? [[String: Any]])
        XCTAssertFalse(items.isEmpty, "抽屉里应有子按钮")
        let joysticks = try XCTUnwrap(dict["mJoystickDataList"] as? [[String: Any]])
        XCTAssertFalse(joysticks.isEmpty, "缺少虚拟摇杆")
    }

    func testEnsureLayoutGeneratesBuiltinWhenMissing() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = AmethystPreferences.ensureDefaultControlLayout(homeDirectory: home)
        XCTAssertEqual(source, "generated-builtin")
        let target = home.appendingPathComponent(AmethystPreferences.controlMapRelativePath)
        let data = try XCTUnwrap(try? Data(contentsOf: target), "未生成 default.json")
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data))
    }

    func testEnsureLayoutKeepsExistingUserConfig() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent(AmethystPreferences.controlMapRelativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 写入一份"用户自定义"布局
        let custom: [String: Any] = ["version": 8, "mControlDataList": [["name": "MyButton"] as [String: Any]]]
        let customData = try JSONSerialization.data(withJSONObject: custom)
        try customData.write(to: target)

        let source = AmethystPreferences.ensureDefaultControlLayout(homeDirectory: home)
        XCTAssertEqual(source, "kept-existing")
        let after = try XCTUnwrap(try? Data(contentsOf: target))
        XCTAssertEqual(after, customData, "已有键位不应被覆盖")
    }

    func testEnsureLayoutRejectsGarbageFile() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent(AmethystPreferences.controlMapRelativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".data(using: .utf8)!.write(to: target)

        let source = AmethystPreferences.ensureDefaultControlLayout(homeDirectory: home)
        XCTAssertNotEqual(source, "kept-existing", "损坏的文件必须被替换")
        let data = try XCTUnwrap(try? Data(contentsOf: target))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: data))
    }
}
