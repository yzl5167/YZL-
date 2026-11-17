import Foundation

/// fork 引擎（Amethyst）的偏好文件读写。
///
/// 关键点：**JVM 的 `-Xmx` 是在 `launchJVM` 里由 Amethyst 自己算的**，不是我们命令行
/// 传进去的。它读 `java.auto_ram` / `java.allocated_memory` 两个键：
/// - `auto_ram = true` 时按物理内存的 25%（有 memorystatus 能力时 40%）取；
/// - 否则用 `allocated_memory`。
///
/// 整合包（尤其是几百个模组的 RPG 包）在 1 GB 堆上会一路 GC 到「正在加载地形」就再也
/// 动不了——PC 上 PCL 给 8 GB 当然没事。所以启动前必须把用户选定的堆写进这里，
/// 让 Amethyst 的 `-Xmx` 和启动器 UI 上显示的数字真正一致。
///
/// 偏好文件是 `$AME_HOME/launcher_preferences_v2.plist`，结构是分节的字典
/// （`java` / `video` / `general` …）。这里只改 `java` 段，其余原样保留；
/// 文件不存在时写一份只含 `java` 段的 plist 也安全——Amethyst 的
/// `setDefaultsForPref:` 会把缺失的节补齐成默认值。
///
/// 时机说明：Amethyst 在 `main.m:301` 就把偏好读进内存了，所以这里写盘**本次启动
/// 还不会生效**，要下次启动才由它自己算出更大的 `-Xmx`。本次启动靠
/// `EngineJVMArguments` 往 `jvm_processed` 里补的那条 `-Xmx`（拼在 Amethyst
/// 自己的参数之后，最后一条生效）。两条路径一起写，才不会出现「UI 说 4 GB、
/// JVM 里 1 GB」这种自欺欺人的状态。
enum AmethystPreferences {
    static let fileName = "launcher_preferences_v2.plist"

    /// 把堆大小写进偏好，返回是否真的改动了文件。
    @discardableResult
    static func apply(heapMB: Int,
                      homeDirectory: URL,
                      fileManager: FileManager = .default) throws -> Bool {
        let heap = max(512, heapMB)
        let url = homeDirectory.appendingPathComponent(fileName)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dictionary = parsed as? [String: Any] {
            root = dictionary
        }

        var java = root["java"] as? [String: Any] ?? [:]
        let currentAuto = (java["auto_ram"] as? NSNumber)?.boolValue ?? true
        let currentHeap = (java["allocated_memory"] as? NSNumber)?.intValue ?? 0
        if !currentAuto && currentHeap == heap {
            return false
        }

        java["auto_ram"] = false
        java["allocated_memory"] = heap
        root["java"] = java

        try fileManager.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        return true
    }

    /// 读回当前生效的堆（MB）；没写过偏好时返回 nil，便于自检展示真实值。
    static func currentHeapMB(homeDirectory: URL, fileManager: FileManager = .default) -> Int? {
        let url = homeDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = parsed as? [String: Any],
              let java = root["java"] as? [String: Any],
              let value = java["allocated_memory"] as? NSNumber,
              (java["auto_ram"] as? NSNumber)?.boolValue == false else {
            return nil
        }
        return value.intValue
    }

    // MARK: - 默认虚拟键位布局（FCL / Pojav 同款）

    /// 相对 AME_HOME 的键位文件位置。引擎 `init_setupCustomControls()` 与
    /// `SurfaceViewController loadCustomControls` 都认这个固定相对路径。
    static let controlMapRelativePath = "controlmap/default.json"

    /// 确保 YZL 使用的 AME_HOME 下有一份默认键位文件，否则游戏里看不到任何悬浮按键。
    ///
    /// 根因：引擎主二进制在 `main()` 的 pre-init 里调用 `init_setupCustomControls()`，
    /// 把默认布局写到它自己算出的 AME_HOME（`$HOME/Documents[/AngelAuraAmethyst]`）。
    /// 但 YZL 在启动前 `setenv("AME_HOME", Documents/YZLEngineHome)` 换成了另一个目录，
    /// `SurfaceViewController.loadCustomControls` 读的正是这个新目录 → 找不到 default.json
    /// → ctrlView 没有任何按键。
    ///
    /// 策略（不动用户已有配置）：
    ///   1. 目标已存在且是合法 JSON → 原样保留（玩家自定义过的键位绝不被覆盖）；
    ///   2. 否则尝试从引擎生成的目录复制（沙箱 / 非沙箱两种路径都试）；
    ///   3. 都不存在 → 用内置 FCL 同款布局生成，保证至少有一套可用键位。
    ///
    /// 返回写入来源，便于写进 YZLBootLog 做真机诊断。
    @discardableResult
    static func ensureDefaultControlLayout(homeDirectory: URL,
                                           fileManager: FileManager = .default) -> String {
        let target = homeDirectory.appendingPathComponent(controlMapRelativePath)
        if isValidLayout(target, fileManager: fileManager) {
            return "kept-existing"
        }

        let targetDir = target.deletingLastPathComponent()
        try? fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // 2. 从引擎自己生成的目录复制（它就是最正宗的 FCL 同款布局，键位码全对）。
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let engineCandidates = [
            documents.appendingPathComponent("AngelAuraAmethyst/controlmap/default.json"),
            documents.appendingPathComponent("controlmap/default.json")
        ]
        for candidate in engineCandidates {
            if isValidLayout(candidate, fileManager: fileManager),
               let data = try? Data(contentsOf: candidate),
               (try? data.write(to: target, options: .atomic)) != nil {
                return "copied-from-engine(\(candidate.lastPathComponent))"
            }
        }

        // 3. 内置兜底布局。
        if let data = Self.builtinDefaultLayout.data(using: .utf8),
           (try? data.write(to: target, options: .atomic)) != nil {
            return "generated-builtin"
        }
        return "failed"
    }

    /// 文件存在、非空、且能解析成带控件数组的字典才算有效布局。
    private static func isValidLayout(_ url: URL, fileManager: FileManager) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return false }
        // version 8 布局用 mControlDataList；老版本可能有 controls。至少有一个数组即可。
        return dict["mControlDataList"] != nil || dict["controls"] != nil
    }

    /// 内置 FCL 同款默认布局（version 8，与 Amethyst generateAndSaveDefaultControl 同构）。
    /// 只在引擎目录找不到现成布局时兜底使用；动态 X/Y 用引擎支持的 `${...}` 表达式，
    /// 由 ControlLayout 在加载时按屏幕尺寸求值，适配任意横屏分辨率。
    /// keycodes 用 GLFW 标准值；特殊按钮用 Pojav 的 SPECIALBTN_* 负值（见 utils.h）。
    static let builtinDefaultLayout: String = {
        // 按钮构造器：name / keycodes[4] / dynamicX / dynamicY / 尺寸 / 开关标志
        func button(_ name: String,
                    _ keys: [Int],
                    x: String, y: String,
                    w: Double = 69.6, h: Double = 69.6,
                    toggle: Bool = false, swipe: Bool = false,
                    inGame: Bool = true, inMenu: Bool = true,
                    stroke: Double = 0) -> [String: Any] {
            var k = keys
            while k.count < 4 { k.append(0) }
            return [
                "name": name,
                "keycodes": Array(k.prefix(4)),
                "dynamicX": x, "dynamicY": y,
                "width": w, "height": h,
                "opacity": 1,
                "cornerRadius": 100,
                "bgColor": 0x4d000000,
                "isToggle": toggle,
                "isSwipeable": swipe,
                "displayInGame": inGame,
                "displayInMenu": inMenu,
                "passThruEnabled": false,
                "strokeColor": -1,
                "strokeWidth": stroke
            ]
        }
        // GLFW keycodes（与 Amethyst glfw_keycodes.h 一致）
        let K_SPACE = 32, K_ESC = 256, K_LSHIFT = 340, K_LCTRL = 341
        let K_E = 69, K_T = 84, K_TAB = 258, K_F3 = 292, K_F5 = 294
        // 特殊功能键：Pojav utils.h 的 SPECIALBTN_*（均为负值）
        // KEYBOARD=-1 TOGGLECTRL=-2 MOUSEPRI=-3 MOUSESEC=-4 VIRTUALMOUSE=-5
        // MOUSEMID=-6 SCROLLUP=-7 SCROLLDOWN=-8 MENU=-9
        let S_MENU = -9, S_MOUSEPRI = -3, S_MOUSEMID = -6, S_MOUSESEC = -4
        let S_VIRTMOUSE = -5, S_KEYBOARD = -1, S_TOGGLECTRL = -2

        let rightCol = "0.94878495 * ${screen_width} - ${width} - ${margin}"
        let topRow = "0.0 * ${screen_height}"
        let midRow = "0.31131014 * ${screen_height}"
        let bottomRight = "1.0 * ${screen_width} - ${width} - ${margin}"

        var controls: [[String: Any]] = [
            button("Jump", [K_SPACE], x: rightCol, y: midRow),
            button("Runtime\nMenu", [S_MENU], x: bottomRight, y: topRow, w: 104.8, h: 39.2, inMenu: false),
            button("Shift", [K_LSHIFT], x: rightCol, y: midRow, toggle: true, inMenu: false),
            button("Right\nClick", [S_MOUSESEC], x: "0.8756154 * ${screen_width} - ${width}", y: "0.8178498 * ${screen_height} - ${height}", inMenu: false),
            button("Left\nClick", [S_MOUSEPRI], x: "0.7756397 * ${screen_width} - ${width}", y: "0.8224885 * ${screen_height} - ${height}", inMenu: false),
            button("Middle\nClick", [S_MOUSEMID], x: "0.83548373 * ${screen_width} - ${width}", y: "0.67798775 * ${screen_height} - ${height}", inMenu: false),
            button("Sprint", [K_LCTRL], x: "0.94878495 * ${screen_width} - ${width} * 2 - ${margin} * 2", y: midRow, toggle: true, inMenu: false),
            button("Hide\nGUI", [S_TOGGLECTRL], x: bottomRight, y: topRow, w: 69.6, h: 40.0, inMenu: false),
            button("Pause", [K_ESC], x: "0.94878495 * ${screen_width} - ${width} * 2 - ${margin} * 3", y: topRow, w: 104.8, h: 39.2),
            button("Inventory", [K_E], x: "0.90 * ${screen_width} - ${width}", y: topRow, w: 100.0, h: 40.0),
            button("Exit\nMenu", [K_ESC], x: "0.88 * ${screen_width} - ${width}", y: topRow, w: 104.8, h: 39.2, inGame: false)
        ]

        // 悬浮可展开抽屉（图标按钮）：Third person / Debug / 虚拟鼠标 / 聊天 / 键盘 / 玩家列表
        let drawerItems: [[String: Any]] = [
            button("Third\nperson", [K_F5], x: "${width} + ${margin}", y: "0.003 * ${screen_height}", w: 96, h: 40, inMenu: false),
            button("Debug\nMenu", [K_F3], x: "${width} * 2 + ${margin} * 2", y: "0.003 * ${screen_height}", w: 96, h: 40, inMenu: false),
            button("Mouse\nToggle", [S_VIRTMOUSE], x: "${width} + ${margin}", y: "0.003 * ${screen_height} + ${height} + ${margin}", w: 96, h: 40, inMenu: false),
            button("Chat", [K_T], x: "0.0 * ${screen_width}", y: "0.003 * ${screen_height} + ${height} + ${margin}", w: 96, h: 40, inMenu: false),
            button("Keyboard", [S_KEYBOARD], x: "${width} * 2 + ${margin} * 2", y: "0.003 * ${screen_height} + ${height} + ${margin}", w: 96, h: 40, inMenu: false),
            button("Player\nList", [K_TAB], x: "${width} + ${margin}", y: "0.003 * ${screen_height} + (${height} + ${margin}) * 2", w: 96, h: 40, inMenu: false)
        ]
        let drawer: [String: Any] = [
            "orientation": "FREE",
            "properties": button("More", [0], x: "0.0 * ${screen_width}", y: "0.0 * ${screen_height}", w: 96, h: 40, inMenu: false, stroke: 1.5),
            "buttonProperties": drawerItems
        ]

        // 虚拟摇杆
        var joystick = button("button", [0], x: "0.02326631 * ${screen_width}", y: "0.9753418 * ${screen_height} - ${height}", w: 204.8, h: 204.8, inMenu: false)
        joystick["absolute"] = false
        joystick["forwardLock"] = false
        joystick["cornerRadius"] = 0
        joystick["strokeColor"] = 1291845632

        let layout: [String: Any] = [
            "version": 8,
            "scaledAt": 100,
            "mControlDataList": controls,
            "mDrawerDataList": [drawer],
            "mJoystickDataList": [joystick]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{}"
    }()

    /// 当前渲染器名：`auto` / `libgl4es_114.dylib` / `libmobileglues.dylib` / `libtinygl4angle.dylib`。
    static func rendererName(homeDirectory: URL, fileManager: FileManager = .default) -> String? {
        let url = homeDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = parsed as? [String: Any],
              let video = root["video"] as? [String: Any] else {
            return nil
        }
        return video["renderer"] as? String
    }

    /// Sodium 0.5.x 在 gl4es 这一档上跑不起来（Pojav 官方不兼容清单：
    /// 必须关掉它的 terrain 优化 mixin），而 Amethyst 的 `auto` 对 1.20.1
    /// 会落到 gl4es。所以「auto / gl4es + 原版 Sodium」要在自检里提醒开极端兼容。
    static func isSodiumUnsafe(renderer: String?) -> Bool {
        guard let renderer = renderer else { return true }
        let name = renderer.lowercased()
        return name == "auto" || name.contains("gl4es")
    }
}
