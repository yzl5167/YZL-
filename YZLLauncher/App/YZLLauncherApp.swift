import SwiftUI
import UIKit

@main
struct YZLLauncherApp: App {
    @StateObject private var appState = AppState()

    init() {
        YZLBootLog.resetForNewSessionIfNeeded()
        AppearanceStore.shared.syncSystemScheme(
            UITraitCollection.current.userInterfaceStyle == .dark
        )
        Self.configureBars()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
    }

    private static func configureBars() {
        // 导航栏/标签栏动态配色与 fork 宿主共用同一份实现，避免深浅不一致。
        AppearanceStore.configureBars()

        // iOS 15 没有 scrollContentBackground(.hidden)：InsetGroupedListStyle 的
        // tableView 会保留系统灰底，光靠 listRowBackground 刷白行会留下灰色间隙。
        // 在 appearance 层统一清掉；iOS 16+ 仍优先用 YZLCompat 的原生 API。
        if #available(iOS 16.0, *) {
            // YZLCompat.yzlClearListBackground() 处理。
        } else {
            UITableView.appearance().backgroundColor = .clear
        }
    }
}
