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
