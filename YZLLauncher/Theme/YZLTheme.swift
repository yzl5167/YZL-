import SwiftUI

enum YZLTheme {
    static let page = Color(red: 0.957, green: 0.965, blue: 0.984)
    static let card = Color.white
    static let field = Color(red: 0.973, green: 0.980, blue: 0.992)
    static let text = Color(red: 0.145, green: 0.188, blue: 0.267)
    static let muted = Color(red: 0.486, green: 0.541, blue: 0.627)
    static let lightMuted = Color(red: 0.635, green: 0.682, blue: 0.753)
    static let border = Color(red: 0.894, green: 0.914, blue: 0.949)
    static let accent = Color(red: 0.231, green: 0.510, blue: 0.965)
    static let accentDark = Color(red: 0.173, green: 0.435, blue: 0.878)
    static let accentText = Color(red: 0.114, green: 0.298, blue: 0.620)
    static let accentSoft = Color(red: 0.918, green: 0.949, blue: 1.0)
    static let success = Color(red: 0.133, green: 0.773, blue: 0.369)
    static let successSoft = Color(red: 0.914, green: 0.976, blue: 0.937)
    static let danger = Color(red: 0.937, green: 0.267, blue: 0.267)
    static let warningSoft = Color(red: 1.0, green: 0.957, blue: 0.898)
    static let warningText = Color(red: 0.698, green: 0.416, blue: 0.0)

    static let cardCorner: CGFloat = 14
    static let controlCorner: CGFloat = 8
}

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
        case .danger: return Color(red: 0.996, green: 0.925, blue: 0.925)
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var prominent: Bool = true
    var large: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 16 : 14, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : YZLTheme.accentText)
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
