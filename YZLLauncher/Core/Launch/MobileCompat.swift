import Foundation

/// iOS 侧的整合包兼容层：把「按 PC 习惯配好的整合包」收敛成手机上能进游戏的样子。
///
/// 为什么需要它：同一个整合包在 Windows 的 PCL 上能正常进世界，在 iOS 上却停在
/// 「正在加载地形」。这一屏是 `ReceivingLevelScreen`——客户端已经拿到世界，正等
/// 渲染线程把出生点那一块地形建出来。移动端在这条路径上有三处和桌面不同：
///
/// 1. **光影**：Iris 会在收到地形时编译整套 shader 管线，而 iOS 走的是
///    GLES/Metal 翻译层（gl4es / MobileGlues / ANGLE），缺 compute、SSBO、
///    持久映射缓冲等特性，编译线程会一直等下去——表现就是永远停在加载地形。
/// 2. **Sodium 的 staging buffer**：`use_advanced_staging_buffers` 依赖 GL 4.4
///    的持久映射，翻译层上不一定有，区块构建会卡在等 fence。
/// 3. **桌面画质档**：260 FPS、云层、生物群系过渡在手机上只会抢走渲染线程时间。
///
/// 所以这里做四件事：关光影、关高级 staging、把画质调到移动端档位、以及在
/// 「极端兼容」下把整个 Sodium 渲染组移出 mods。所有改动都先备份、可重复执行。
enum MobileCompat {

    // MARK: - 设置

    struct Settings: Equatable {
        /// 启动前自动做移动端适配（默认开）。
        var enabled: Bool = true
        /// 极端兼容：把 Sodium / Iris 一整组渲染模组移出 mods，只留原版渲染器。
        var aggressive: Bool = false

        static let enabledKey = "compat.mobile.enabled"
        static let aggressiveKey = "compat.mobile.aggressive"

        static func load(from defaults: UserDefaults = .standard) -> Settings {
            defaults.register(defaults: [enabledKey: true, aggressiveKey: false])
            return Settings(
                enabled: defaults.bool(forKey: enabledKey),
                aggressive: defaults.bool(forKey: aggressiveKey)
            )
        }

        func save(to defaults: UserDefaults = .standard) {
            defaults.set(enabled, forKey: Settings.enabledKey)
            defaults.set(aggressive, forKey: Settings.aggressiveKey)
        }
    }

    // MARK: - 结果

    struct Report: Equatable {
        /// 逐条人话描述，直接给 UI 展示。
        var lines: [String] = []
        /// 被移出 mods 的模组文件名。
        var quarantined: [String] = []
        /// 被移回 mods 的模组文件名。
        var restored: [String] = []

        var isEmpty: Bool {
            lines.isEmpty && quarantined.isEmpty && restored.isEmpty
        }

        var summary: String {
            if isEmpty { return "已是移动端适配状态，无需改动。" }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - 常量

    /// mods 之外的中转目录；和 mods 同级，方便用户自己看/手动搬回。
    static let quarantineDirectoryName = "mods-ios-off"
    /// 备份目录（放在实例目录下，不进 mods）。
    static let backupDirectoryName = ".yzl-compat-backup"

    /// 手机上按这个档位跑：解析度降不了，就把视图距离和后期效果压下来。
    static let optionsOverrides: [(key: String, value: String)] = [
        ("renderDistance", "4"),
        ("simulationDistance", "4"),
        ("maxFps", "60"),
        ("enableVsync", "true"),
        ("graphicsMode", "0"),
        ("ao", "false"),
        ("particles", "1"),
        ("biomeBlendRadius", "0"),
        ("renderClouds", "\"false\""),
        ("entityShadows", "false"),
        ("entityDistanceScaling", "0.5"),
        ("mipmapLevels", "0")
    ]

    /// Iris 的开关文件：关掉光影，保留用户选的整合包名字，回桌面端还能一键开回来。
    static let irisOverrides: [(key: String, value: String)] = [
        ("enableShaders", "false")
    ]

    /// 无论如何都要关的模组前缀（小写）：Iris 与它的搜索附加件都依赖 shader 管线。
    static let alwaysOffModPrefixes = ["iris"]

    /// 极端兼容下额外关掉的渲染模组前缀：Sodium 全家桶 + FRAPI 桥。
    static let aggressiveModPrefixes = ["sodium", "indium", "reeses_sodium_options"]

    // MARK: - 入口

    /// 对一个实例的游戏目录做移动端适配。可重复调用（幂等）。
    @discardableResult
    static func apply(to gameDirectory: URL,
                      aggressive: Bool,
                      fileManager: FileManager = .default) throws -> Report {
        var report = Report()
        let backupRoot = gameDirectory.appendingPathComponent(backupDirectoryName, isDirectory: true)

        // 1) options.txt：移动端画质档
        let optionsURL = gameDirectory.appendingPathComponent("options.txt")
        if let text = try? String(contentsOf: optionsURL, encoding: .utf8) {
            let patched = patchDelimited(contents: text, separator: ":", overrides: optionsOverrides)
            if !patched.changes.isEmpty {
                try backupIfNeeded(optionsURL, name: "options.txt", root: backupRoot, fileManager: fileManager)
                try patched.text.write(to: optionsURL, atomically: true, encoding: .utf8)
                report.lines.append("画质：" + patched.changes.joined(separator: "，"))
            }
        }

        // 2) Iris：关光影（保留 shaderPack 名字）
        let irisURL = gameDirectory.appendingPathComponent("config").appendingPathComponent("iris.properties")
        if let text = try? String(contentsOf: irisURL, encoding: .utf8) {
            let patched = patchDelimited(contents: text, separator: "=", overrides: irisOverrides)
            if !patched.changes.isEmpty {
                try backupIfNeeded(irisURL, name: "iris.properties", root: backupRoot, fileManager: fileManager)
                try patched.text.write(to: irisURL, atomically: true, encoding: .utf8)
                report.lines.append("光影：已关闭 Iris shader 管线（移动端会在加载地形时卡死）")
            }
        }

        // 3) Sodium：关掉依赖 GL 4.4 持久映射的高级 staging buffer
        if !aggressive {
            let sodiumURL = gameDirectory.appendingPathComponent("config").appendingPathComponent("sodium-options.json")
            if let changes = try? patchSodiumOptions(at: sodiumURL, fileManager: fileManager), !changes.isEmpty {
                report.lines.append("Sodium：" + changes.joined(separator: "，"))
            }
        }

        // 4) 模组：Iris 必关；极端兼容再加 Sodium 组
        var prefixes = alwaysOffModPrefixes
        if aggressive {
            prefixes.append(contentsOf: aggressiveModPrefixes)
        }
        let moved = try quarantineMods(in: gameDirectory, prefixes: prefixes, fileManager: fileManager)
        if !moved.isEmpty {
            report.quarantined = moved
            report.lines.append("已移出 mods（\(quarantineDirectoryName)）：" + moved.joined(separator: "、"))
        }

        // 5) 非极端模式：把上次极端模式移走的 Sodium 组搬回来
        if !aggressive {
            let back = try restoreMods(in: gameDirectory,
                                       prefixes: aggressiveModPrefixes,
                                       fileManager: fileManager)
            if !back.isEmpty {
                report.restored = back
                report.lines.append("已移回 mods：" + back.joined(separator: "、"))
            }
        }

        return report
    }

    /// 把中转目录里的模组全部搬回 mods（用户点「恢复原样」时用）。
    @discardableResult
    static func restoreAll(in gameDirectory: URL, fileManager: FileManager = .default) throws -> [String] {
        try restoreMods(in: gameDirectory, prefixes: nil, fileManager: fileManager)
    }

    /// 统计实例里装了多少个模组 jar，用于「整合包规模」自检。
    static func modCount(in gameDirectory: URL, fileManager: FileManager = .default) -> Int {
        let mods = gameDirectory.appendingPathComponent("mods", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: mods, includingPropertiesForKeys: nil) else {
            return 0
        }
        return entries.filter { $0.pathExtension.lowercased() == "jar" }.count
    }

    // MARK: - 键值文件

    /// 行式 `key:value` / `key=value` 打补丁：只改认识的键，顺序与其余内容原样保留。
    static func patchDelimited(contents: String,
                               separator: Character,
                               overrides: [(key: String, value: String)]) -> (text: String, changes: [String]) {
        var remaining = overrides
        var changes: [String] = []
        var lines = contents.components(separatedBy: "\n")

        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let separatorIndex = line.firstIndex(of: separator) else { continue }
            let key = String(line[line.startIndex..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            guard let overrideIndex = remaining.firstIndex(where: { $0.key == key }) else { continue }
            let desired = remaining.remove(at: overrideIndex).value
            let current = String(line[line.index(after: separatorIndex)...])
            if current == desired { continue }
            changes.append("\(key) \(current) → \(desired)")
            lines[index] = "\(key)\(separator)\(desired)"
        }

        if !remaining.isEmpty {
            var extra = remaining.map { "\($0.key)\(separator)\($0.value)" }
            if let last = lines.last, last.isEmpty {
                lines.insert(contentsOf: extra, at: lines.count - 1)
            } else {
                extra.insert("", at: 0)
                lines.append(contentsOf: extra)
            }
            for item in remaining {
                changes.append("\(item.key) (缺省) → \(item.value)")
            }
        }

        return (lines.joined(separator: "\n"), changes)
    }

    // MARK: - Sodium

    /// Sodium 的配置是 JSON；只动 `advanced` 段里的两个键，其余原样写回。
    static func patchSodiumOptions(at url: URL, fileManager: FileManager = .default) throws -> [String] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let parsed = object as? [String: Any] else {
            return []
        }
        var root = parsed
        var advanced = parsed["advanced"] as? [String: Any] ?? [:]
        var changes: [String] = []

        if (advanced["use_advanced_staging_buffers"] as? Bool) != false {
            advanced["use_advanced_staging_buffers"] = false
            changes.append("关闭高级 staging buffer（GL 4.4 持久映射在翻译层不可靠）")
        }
        let ahead = (advanced["cpu_render_ahead_limit"] as? NSNumber)?.intValue
        if ahead == nil || ahead! > 2 {
            advanced["cpu_render_ahead_limit"] = 2
            changes.append("渲染预排降到 2（降低内存峰值）")
        }
        guard !changes.isEmpty else { return [] }

        root["advanced"] = advanced
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let backupRoot = url.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(backupDirectoryName, isDirectory: true)
        try backupIfNeeded(url, name: "sodium-options.json", root: backupRoot, fileManager: fileManager)
        try output.write(to: url, options: .atomic)
        return changes
    }

    // MARK: - 模组搬运

    static func quarantineMods(in gameDirectory: URL,
                               prefixes: [String],
                               fileManager: FileManager = .default) throws -> [String] {
        let mods = gameDirectory.appendingPathComponent("mods", isDirectory: true)
        let off = gameDirectory.appendingPathComponent(quarantineDirectoryName, isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: mods, includingPropertiesForKeys: nil) else {
            return []
        }
        let targets = entries.filter { url in
            guard url.pathExtension.lowercased() == "jar" else { return false }
            let name = url.lastPathComponent.lowercased()
            return prefixes.contains { name.hasPrefix($0) }
        }
        guard !targets.isEmpty else { return [] }

        try fileManager.createDirectory(at: off, withIntermediateDirectories: true)
        var moved: [String] = []
        for url in targets.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let destination = off.appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) { continue }
            try fileManager.moveItem(at: url, to: destination)
            moved.append(url.lastPathComponent)
        }
        return moved
    }

    /// `prefixes` 为 nil 表示把中转目录里的全部 jar 搬回 mods。
    static func restoreMods(in gameDirectory: URL,
                            prefixes: [String]?,
                            fileManager: FileManager = .default) throws -> [String] {
        let mods = gameDirectory.appendingPathComponent("mods", isDirectory: true)
        let off = gameDirectory.appendingPathComponent(quarantineDirectoryName, isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: off, includingPropertiesForKeys: nil) else {
            return []
        }
        let targets = entries.filter { url in
            guard url.pathExtension.lowercased() == "jar" else { return false }
            guard let prefixes = prefixes else { return true }
            let name = url.lastPathComponent.lowercased()
            return prefixes.contains { name.hasPrefix($0) }
        }
        guard !targets.isEmpty else { return [] }

        try fileManager.createDirectory(at: mods, withIntermediateDirectories: true)
        var restored: [String] = []
        for url in targets.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let destination = mods.appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) { continue }
            try fileManager.moveItem(at: url, to: destination)
            restored.append(url.lastPathComponent)
        }
        return restored
    }

    // MARK: - 模组清单与管理

    /// 一个模组文件的清单条目；`isEnabled` = 位于 mods 目录（关闭的模组在 mods-ios-off）。
    struct ModEntry: Equatable, Identifiable {
        let name: String
        let size: Int64
        let isEnabled: Bool

        var id: String { (isEnabled ? "on:" : "off:") + name }
    }

    /// 列出某版本的全部模组（mods + mods-ios-off，按文件名排序）。
    /// 整合包动辄几百个 jar，这里只做清单，UI 层自己决定分页 / 搜索。
    static func listMods(in gameDirectory: URL, fileManager: FileManager = .default) -> [ModEntry] {
        let mods = gameDirectory.appendingPathComponent("mods", isDirectory: true)
        let off = gameDirectory.appendingPathComponent(quarantineDirectoryName, isDirectory: true)
        var result: [ModEntry] = []
        result.append(contentsOf: jarEntries(at: mods, enabled: true, fileManager: fileManager))
        result.append(contentsOf: jarEntries(at: off, enabled: false, fileManager: fileManager))
        return result.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func jarEntries(at directory: URL, enabled: Bool, fileManager: FileManager) -> [ModEntry] {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return []
        }
        return items.compactMap { url in
            guard url.pathExtension.lowercased() == "jar" else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return ModEntry(name: url.lastPathComponent, size: Int64(size), isEnabled: enabled)
        }
    }

    /// 开 / 关一个模组（mods ↔ mods-ios-off 搬移）。
    /// 两边同名时加时间戳后缀，绝不覆盖用户文件。
    static func setModEnabled(in gameDirectory: URL, name: String, enabled: Bool,
                              fileManager: FileManager = .default) throws {
        let mods = gameDirectory.appendingPathComponent("mods", isDirectory: true)
        let off = gameDirectory.appendingPathComponent(quarantineDirectoryName, isDirectory: true)
        let source = enabled ? off.appendingPathComponent(name) : mods.appendingPathComponent(name)
        let targetDirectory = enabled ? mods : off
        guard fileManager.fileExists(atPath: source.path) else { return }

        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        var destination = targetDirectory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: destination.path) {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            destination = targetDirectory.appendingPathComponent("\(stem)-\(Int(Date().timeIntervalSince1970)).\(ext)")
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    /// 删除一个模组；`isEnabled` 决定从哪个目录找，找不到静默返回。
    static func deleteMod(in gameDirectory: URL, name: String, isEnabled: Bool,
                          fileManager: FileManager = .default) {
        let directory = isEnabled
            ? gameDirectory.appendingPathComponent("mods", isDirectory: true)
            : gameDirectory.appendingPathComponent(quarantineDirectoryName, isDirectory: true)
        try? fileManager.removeItem(at: directory.appendingPathComponent(name))
    }

    // MARK: - 备份

    /// 第一次改动前留一份原文件，之后不再覆盖（保证备份始终是用户最初的配置）。
    static func backupIfNeeded(_ url: URL,
                               name: String,
                               root: URL,
                               fileManager: FileManager = .default) throws {
        let destination = root.appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.copyItem(at: url, to: destination)
    }
}
