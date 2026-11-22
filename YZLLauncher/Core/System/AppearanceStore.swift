import SwiftUI
import UIKit

/// 外观模式：跟随系统 / 强制浅色 / 强制深色。
/// 对齐 Windows 端「个性化 → 模式」与 Android 端 `ThemeMode { SYSTEM, LIGHT, DARK }`。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// nil 表示跟随系统（SwiftUI preferredColorScheme 约定）。
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 主题色：对齐 Android 端 `Theme.kt` 的 `AccentOptions`
/// （YZL蓝 / 草方块 / 紫水晶 / 熔岩 / 樱花）。
enum AccentChoice: String, CaseIterable, Identifiable {
    case blue
    case grass
    case amethyst
    case lava
    case sakura

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: return "YZL 蓝"
        case .grass: return "草方块"
        case .amethyst: return "紫水晶"
        case .lava: return "熔岩"
        case .sakura: return "樱花"
        }
    }

    /// 浅色模式主色 RGB。
    var accentRGB: (Double, Double, Double) {
        switch self {
        case .blue: return (0.231, 0.510, 0.965)
        case .grass: return (0.404, 0.686, 0.278)
        case .amethyst: return (0.612, 0.373, 0.804)
        case .lava: return (0.898, 0.380, 0.208)
        case .sakura: return (0.910, 0.494, 0.639)
        }
    }

    /// 深色模式主色：比浅色版亮一档，避免在暗背景上发闷。
    var accentDarkRGB: (Double, Double, Double) {
        switch self {
        case .blue: return (0.380, 0.639, 1.0)
        case .grass: return (0.545, 0.827, 0.416)
        case .amethyst: return (0.741, 0.522, 0.898)
        case .lava: return (0.976, 0.545, 0.353)
        case .sakura: return (0.965, 0.639, 0.749)
        }
    }
}

/// 全局外观设置（单例）。
///
/// `YZLTheme` 的颜色是静态计算属性，拿不到 SwiftUI 的 `@Environment`，
/// 因此"当前是否深色"统一收口到本单例的 `isDarkEffective`：
/// - 强制浅/深：直接返回；
/// - 跟随系统：读 `systemIsDark`，由 App / fork 宿主启动与 `colorScheme` 变化时回写。
/// 切换模式/主题色时 `styleVersion += 1`（@Published 自动发 objectWillChange），
/// RootView 只把 `.id(styleVersion)` 挂在内容区，让静态颜色重算但不销毁侧栏/弹层状态。
final class AppearanceStore: ObservableObject {
    static let shared = AppearanceStore()

    @AppStorage("yzl.appearance.mode") var mode: AppearanceMode = .system
    @AppStorage("yzl.appearance.accent") var accent: AccentChoice = .blue

    /// 内容区视图版本号：外观变化后 +1，强制重算 YZLTheme 静态颜色。
    @Published private(set) var styleVersion: Int = 0

    /// 系统当前外观。由宿主在启动与 trait 变化时回写（跟随系统模式用）。
    @Published private(set) var systemIsDark: Bool = false

    private init() {
        // 冷启动即用当前系统 trait 初始化，避免"跟随系统 + 系统深色"首帧闪白。
        systemIsDark = UITraitCollection.current.userInterfaceStyle == .dark
    }

    var preferredColorScheme: ColorScheme? { mode.preferredColorScheme }

    /// YZLTheme 读取的唯一"当前是否深色"真相源。
    var isDarkEffective: Bool {
        switch mode {
        case .system: return systemIsDark
        case .light: return false
        case .dark: return true
        }
    }

    func setMode(_ newMode: AppearanceMode) {
        guard mode != newMode else { return }
        mode = newMode
        bumpStyle()
    }

    func setAccent(_ newAccent: AccentChoice) {
        guard accent != newAccent else { return }
        accent = newAccent
        bumpStyle()
    }

    /// 系统外观变化时调用。无条件更新 systemIsDark（是否影响界面由 isDarkEffective 按 mode 决定），
    /// 这样从"强制模式"切回"跟随系统"时能立刻拿到最新系统外观。
    func syncSystemScheme(_ isDark: Bool) {
        guard systemIsDark != isDark else { return }
        systemIsDark = isDark
        if mode == .system { bumpStyle() }
    }

    private func bumpStyle() {
        // @Published 会自动发 objectWillChange，不再手动 send，避免双发。
        styleVersion += 1
    }

    // MARK: - 系统栏外观（独立 App 与 fork 宿主共用）

    /// 动态 UIColor：系统切深/浅时导航栏自动换色。两处入口共用，避免深浅不一致。
    static func configureBars() {
        let pageColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.063, green: 0.082, blue: 0.122, alpha: 1)
                : UIColor(red: 0.957, green: 0.965, blue: 0.984, alpha: 1)
        }
        let textColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.918, green: 0.937, blue: 0.965, alpha: 1)
                : UIColor(red: 0.145, green: 0.188, blue: 0.267, alpha: 1)
        }
        let borderColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.180, green: 0.208, blue: 0.267, alpha: 1)
                : UIColor(red: 0.894, green: 0.914, blue: 0.949, alpha: 1)
        }

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = pageColor
        tab.shadowColor = borderColor
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = pageColor
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: textColor]
        nav.largeTitleTextAttributes = [.foregroundColor: textColor]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}
