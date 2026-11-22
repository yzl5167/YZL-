import SwiftUI

/// 主题色板。所有颜色都根据当前外观模式（浅/深）与用户选择的主题色动态计算，
/// 因此全 App 的 `YZLTheme.xxx` 引用无需逐处改写即可支持深色模式与换色。
///
/// 深浅取值与跨端对齐：浅色沿用原版（#F4F6FB 页面 / 白卡片 / #3B82F6 蓝）；
/// 深色取 YZL 跨端 `yzl_page_dark` = #10151F 一族。
enum YZLTheme {
    /// 是否深色。收口到 AppearanceStore 单例，静态属性也能拿到正确值。
    private static var isDark: Bool { AppearanceStore.shared.isDarkEffective }
    private static var accentChoice: AccentChoice { AppearanceStore.shared.accent }

    // MARK: - 当前色板（动态）

    static var page: Color {
        isDark ? pageDark : Color(red: 0.957, green: 0.965, blue: 0.984)
    }

    static var card: Color { isDark ? cardDark : Color.white }

    static var field: Color {
        isDark ? fieldDark : Color(red: 0.973, green: 0.980, blue: 0.992)
    }

    static var text: Color {
        isDark ? textOnDark : Color(red: 0.145, green: 0.188, blue: 0.267)
    }

    static var muted: Color {
        isDark ? mutedOnDark : Color(red: 0.486, green: 0.541, blue: 0.627)
    }

    static var lightMuted: Color {
        isDark
            ? Color(red: 0.470, green: 0.525, blue: 0.604)
            : Color(red: 0.635, green: 0.682, blue: 0.753)
    }

    static var border: Color {
        isDark ? borderDark : Color(red: 0.894, green: 0.914, blue: 0.949)
    }

    /// 主色：跟随主题色选择，深色下用提亮版。
    static var accent: Color {
        let rgb = isDark ? accentChoice.accentDarkRGB : accentChoice.accentRGB
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    /// 与 accent 同源（保留旧调用兼容），深色下同样提亮。
    static var accentDark: Color { accent }

    static var accentText: Color { accent }

    /// 主色的浅底：跟随主题色（用 accent.opacity），换草方块/熔岩/樱花时不会残留蓝底。
    static var accentSoft: Color {
        isDark ? accent.opacity(0.20) : accent.opacity(0.12)
    }

    /// 叠在主色上的前景色：按主色亮度自动选深/浅，保证对比度 ≥ WCAG AA。
    static var onAccent: Color {
        let rgb = isDark ? accentChoice.accentDarkRGB : accentChoice.accentRGB
        let luminance = 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
        return luminance > 0.62
            ? Color(red: 0.063, green: 0.082, blue: 0.122)
            : Color.white
    }

    static var success: Color {
        isDark
            ? Color(red: 0.478, green: 0.850, blue: 0.565)
            : Color(red: 0.133, green: 0.773, blue: 0.369)
    }

    static var successSoft: Color {
        isDark
            ? Color(red: 0.133, green: 0.773, blue: 0.369).opacity(0.20)
            : Color(red: 0.914, green: 0.976, blue: 0.937)
    }

    static var danger: Color {
        isDark
            ? Color(red: 0.965, green: 0.400, blue: 0.400)
            : Color(red: 0.937, green: 0.267, blue: 0.267)
    }

    /// 错误的浅底：深色用透明度自适应，不再写死浅粉以免暗背景刺眼。
    static var dangerSoft: Color {
        isDark ? danger.opacity(0.18) : Color(red: 0.996, green: 0.925, blue: 0.925)
    }

    static var warningSoft: Color {
        isDark
            ? Color(red: 1.0, green: 0.700, blue: 0.200).opacity(0.18)
            : Color(red: 1.0, green: 0.957, blue: 0.898)
    }

    static var warningText: Color {
        isDark
            ? Color(red: 1.0, green: 0.780, blue: 0.400)
            : Color(red: 0.698, green: 0.416, blue: 0.0)
    }

    // MARK: - 尺寸

    static let cardCorner: CGFloat = 14
    static let controlCorner: CGFloat = 8

    /// YZL 品牌渐变（与 Android `ic_launcher_background` 一致：#5AA2FF → #2F6FE0）。
    static let brandGradient = LinearGradient(
        colors: [
            Color(red: 0.353, green: 0.635, blue: 1.0),
            Color(red: 0.184, green: 0.435, blue: 0.878)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - 深色基准常量（yzl_page_dark = #10151F 一族）

    static let pageDark = Color(red: 0.063, green: 0.082, blue: 0.122)
    static let cardDark = Color(red: 0.106, green: 0.129, blue: 0.180)
    static let textOnDark = Color(red: 0.918, green: 0.937, blue: 0.965)
    static let mutedOnDark = Color(red: 0.596, green: 0.651, blue: 0.733)
    static let borderDark = Color(red: 0.180, green: 0.208, blue: 0.267)
    static let fieldDark = Color(red: 0.149, green: 0.176, blue: 0.231)

    /// 兼容旧调用：显式按 colorScheme 取主色。
    static func accent(for colorScheme: ColorScheme) -> Color {
        let rgb = colorScheme == .dark ? accentChoice.accentDarkRGB : accentChoice.accentRGB
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    /// bundle 感知的图标加载：独立 App 里图标在主 bundle；
    /// M2-b fork 里外壳以 YZLUI.framework 注入，图标在 framework bundle。
    /// SwiftUI 的 Image(name) 只查主 bundle，所以 framework 命中时
    /// 先解析成 UIImage 再包装；两侧都未命中时退回主 bundle 查找（布局不塌）。
    static func icon(_ name: String) -> Image {
        if let image = UIImage(named: name, in: Bundle(for: BundleToken.self), compatibleWith: nil) {
            return Image(uiImage: image)
        }
        if let image = UIImage(named: name, in: .main, compatibleWith: nil) {
            return Image(uiImage: image)
        }
        return Image(systemName: "photo")
    }
}

/// 私有标记类：只为 Bundle(for:) 提供定位锚点。
private final class BundleToken {}

struct PageBackground: View {
    var body: some View {
        ZStack {
            YZLTheme.page
            RadialGradient(
                colors: [YZLTheme.accent.opacity(0.08), Color.clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 460
            )
        }
        .ignoresSafeArea()
    }
}

struct YZLCard<Content: View>: View {
    var padding: CGFloat
    var content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: YZLTheme.cardCorner, style: .continuous)
                    .fill(YZLTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: YZLTheme.cardCorner, style: .continuous)
                    .stroke(YZLTheme.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.035), radius: 8, x: 0, y: 2)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(YZLTheme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum BadgeTone {
    case neutral
    case success
    case warning
    case danger
}

struct StatusBadge: View {
    let text: String
    var tone: BadgeTone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(foregroundColor)
            .background(Capsule().fill(backgroundColor))
    }

    private var foregroundColor: Color {
        switch tone {
        case .neutral: return YZLTheme.muted
        case .success: return YZLTheme.success
        case .warning: return YZLTheme.warningText
        case .danger: return YZLTheme.danger
        }
    }

    private var backgroundColor: Color {
        switch tone {
        case .neutral: return YZLTheme.field
        case .success: return YZLTheme.successSoft
        case .warning: return YZLTheme.warningSoft
        case .danger: return YZLTheme.dangerSoft
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var prominent: Bool = true
    var large: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 16 : 14, weight: .semibold))
            .foregroundStyle(prominent ? YZLTheme.onAccent : YZLTheme.accentText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, large ? 16 : 11)
            .background(
                RoundedRectangle(cornerRadius: large ? 12 : YZLTheme.controlCorner, style: .continuous)
                    .fill(prominent ? YZLTheme.accent : YZLTheme.accentSoft)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
