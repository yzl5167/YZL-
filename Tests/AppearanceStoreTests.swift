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

    /// 三态判定：强制模式直接返回，跟随系统读 systemIsDark。测后恢复原值避免污染。
    func testIsDarkEffectiveFollowsMode() {
        let store = AppearanceStore.shared
        let savedMode = store.mode
        let savedDark = store.systemIsDark
        defer {
            store.mode = savedMode
            store.syncSystemScheme(savedDark)
        }

        store.setMode(.light)
        XCTAssertFalse(store.isDarkEffective)
        store.setMode(.dark)
        XCTAssertTrue(store.isDarkEffective)
        store.syncSystemScheme(true)
        store.setMode(.system)
        XCTAssertTrue(store.isDarkEffective, "跟随系统应取 systemIsDark")
        store.syncSystemScheme(false)
        XCTAssertFalse(store.isDarkEffective)
    }

    /// 强制模式下系统外观变化不应改变 isDarkEffective，但 systemIsDark 仍要更新，
    /// 这样切回"跟随系统"能立刻拿到最新值。
    func testSystemSchemeTrackedEvenInForcedMode() {
        let store = AppearanceStore.shared
        let savedMode = store.mode
        let savedDark = store.systemIsDark
        defer {
            store.mode = savedMode
            store.syncSystemScheme(savedDark)
        }

        store.setMode(.light)
        store.syncSystemScheme(true)
        XCTAssertFalse(store.isDarkEffective, "强制浅色不受系统深色影响")
        store.setMode(.system)
        XCTAssertTrue(store.isDarkEffective, "切回跟随系统应立即用刚记录的系统深色")
    }
}
