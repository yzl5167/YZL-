import XCTest
@testable import YZLLauncher

/// 外观：模式 → preferredColorScheme 映射、主题色选择、中文标题。
final class AppearanceStoreTests: XCTestCase {

    func testModeColorSchemeMapping() {
        XCTAssertNil(AppearanceMode.system.preferredColorScheme)
        XCTAssertEqual(AppearanceMode.light.preferredColorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.preferredColorScheme, .dark)
    }

    func testModeTitles() {
        XCTAssertEqual(AppearanceMode.system.title, "跟随系统")
        XCTAssertEqual(AppearanceMode.light.title, "浅色")
        XCTAssertEqual(AppearanceMode.dark.title, "深色")
    }

    func testAllAccentsHaveDistinctColors() {
        let choices = AccentChoice.allCases
        XCTAssertEqual(choices.count, 5)
        var seen = Set<String>()
        for choice in choices {
            let rgb = choice.accentRGB
            let key = "\(rgb.0),\(rgb.1),\(rgb.2)"
            XCTAssertFalse(seen.contains(key), "主题色 \(choice.title) 与其它重复")
            seen.insert(key)
            // 深色版必须比浅色版亮（任一分量更大），否则暗背景发闷。
            let dark = choice.accentDarkRGB
            XCTAssertTrue(dark.0 >= rgb.0 && dark.1 >= rgb.1 && dark.2 >= rgb.2)
        }
    }

    func testAccentTitles() {
        XCTAssertEqual(AccentChoice.blue.title, "YZL 蓝")
        XCTAssertEqual(AccentChoice.grass.title, "草方块")
        XCTAssertEqual(AccentChoice.amethyst.title, "紫水晶")
        XCTAssertEqual(AccentChoice.lava.title, "熔岩")
        XCTAssertEqual(AccentChoice.sakura.title, "樱花")
    }
}
