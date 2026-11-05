import SwiftUI

/// iOS 16 才有的 API 统一收口在这里，保证同一个二进制能装到 iOS 15 的老设备上
/// （TrollStore 兼容区里还有大量 15.x / 16.x 机器，降最低版本等于扩大受众）。
extension View {
    @ViewBuilder
    func yzlLargeSheet() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.large])
        } else {
            self
        }
    }

    @ViewBuilder
    func yzlClearListBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
