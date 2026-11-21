import SwiftUI
import UIKit

@main
struct YZLLauncherApp: App {
    @StateObject private var appState = AppState()

    init() {
        Self.configureBars()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
    }

    private static func configureBars() {
        // 用动态 UIColor：系统切深/浅时导航栏自动换色，避免写死白底黑字。
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
