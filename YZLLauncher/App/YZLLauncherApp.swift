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
                .preferredColorScheme(.light)
        }
    }

    private static func configureBars() {
        let pageColor = UIColor(red: 0.957, green: 0.965, blue: 0.984, alpha: 1)
        let textColor = UIColor(red: 0.145, green: 0.188, blue: 0.267, alpha: 1)
        let borderColor = UIColor(red: 0.894, green: 0.914, blue: 0.949, alpha: 1)

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = .white
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
