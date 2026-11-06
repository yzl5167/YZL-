import SwiftUI
import UIKit

/// M2-b fork 注入点（对应 fork 补丁③）：
/// Amethyst fork 的根视图装配处用 `NSClassFromString("YZLUIRootController")`
/// 实例化本类并设为窗口根控制器，YZL SwiftUI 外壳即接管整个 UI。
///
/// - framework 内自带完整的 YZL 外壳（主页 / 版本 / 账号 / 皮肤 / 设置），
///   与独立 App 版共享同一份源码（project.yml 的 YZLUI target）；
/// - 启动游戏走 `LauncherEngineFactory`：fork 进程内 dlsym 命中
///   `launchJVM` → `YZLEngineHost` 真启动；framework 单独跑（无引擎）时
///   如实报未接入；
/// - framework 未注入（dlopen 失败）时 fork 回退原生 UI，永不卡死构建。
@objc(YZLUIRootController)
public final class YZLUIRootController: UIViewController {
    private let appState = AppState()
    private var hostingController: UIHostingController<AnyView>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        Self.configureBars()

        let root = RootView()
            .environmentObject(appState)
            .preferredColorScheme(.light)
        let hosting = UIHostingController(rootView: AnyView(root))
        hosting.view.backgroundColor = UIColor(red: 0.957, green: 0.965, blue: 0.984, alpha: 1)

        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        hostingController = hosting
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hostingController?.view.frame = view.bounds
    }

    /// fork 是横屏应用；独立预览场景下也保持一致。
    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .landscape
    }

    /// 沿用独立 App 的外观配置（与 YZLLauncherApp.configureBars 等价；
    /// 复制而非引用，因为 @main 入口文件不进 framework target）。
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
