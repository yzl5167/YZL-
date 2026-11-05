import SwiftUI

/// 横屏下限制内容宽度并居中，避免阅读型页面被拉得太宽。
struct YZLReadableModifier: ViewModifier {
    var maxWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    func yzlReadable(maxWidth: CGFloat = 720) -> some View {
        modifier(YZLReadableModifier(maxWidth: maxWidth))
    }
}
