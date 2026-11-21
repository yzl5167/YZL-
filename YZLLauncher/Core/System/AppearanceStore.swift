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
/// 设计要点：`YZLTheme` 里的颜色是静态计算属性，拿不到 SwiftUI 的 `@Environment`。
/// 因此把所有"当前是否深色"的判断收口到本单例的 `isDarkEffective`：
/// - 强制浅/深：直接返回；
/// - 跟随系统：读 `UITraitCollection.current.userInterfaceStyle`，
///   系统外观变化时由 App 的 `deviceScheme` 回调刷新。
/// 切换模式/主题色时 `objectWillChange.send()` + `styleVersion += 1`，
/// RootView 用 `.id(styleVersion)` 重建整棵树，让所有静态颜色重新计算。
final class AppearanceStore: ObservableObject {
    static let shared = AppearanceStore()

    @AppStorage("yzl.appearance.mode") var mode: AppearanceMode = .system
    @AppStorage("yzl.appearance.accent") var accent: AccentChoice = .blue

    /// 视图树版本号：外观变化后 +1，强制重建根视图。
    @Published private(set) var styleVersion: Int = 0

    /// 系统当前外观（跟随系统模式时用）。由 RootView 的 @Environment 回写。
    @Published private(set) var systemIsDark: Bool = false

    private init() {}

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
        mode = newMode
        bumpStyle()
    }

    func setAccent(_ newAccent: AccentChoice) {
        accent = newAccent
        bumpStyle()
    }

    /// 由 RootView 在 @Environment(\.colorScheme) 变化时调用，仅跟随系统模式需要。
    func syncSystemScheme(_ isDark: Bool) {
        guard mode == .system, systemIsDark != isDark else { return }
        systemIsDark = isDark
        bumpStyle()
    }

    private func bumpStyle() {
        styleVersion += 1
        objectWillChange.send()
    }
}
