import Foundation

/// 每个游戏版本的独立设置（对齐 PC 端「版本设置」页）。
///
/// PC 端允许为某个版本单独设：内存、JVM 参数、窗口宽高、全屏、Java 版本锁定。
/// iOS 端把这些存进 `Documents/YZLVersionSettings/settings.json`，按版本 id 索引。
/// 所有字段都可空：空表示「跟随全局 / 自动」，与 PC 端「不填就用默认」一致。
struct PerVersionSettings: Codable, Identifiable, Equatable {
    /// 版本 id（Minecraft 版本标识，如 `1.20.1` / `neoforge-26.3.0.101`），兼作字典键。
    var versionID: String
    /// 单独的内存（MB）。nil = 用设置页的全局内存。
    var memoryMB: Int?
    /// 用户额外 JVM 参数（自由文本，空格分隔）。引擎只转发安全子集。
    var customJVMArguments: String
    /// 窗口宽度（像素）。nil = 跟随引擎默认。
    var windowWidth: Int?
    /// 窗口高度（像素）。
    var windowHeight: Int?
    /// 全屏启动。
    var fullscreen: Bool
    /// 锁定的 Java 大版本。nil = 自动（按版本推荐）。
    var lockedJavaMajor: Int?

    var id: String { versionID }

    /// 把自由文本拆成参数数组：按空白切分，去掉空串，去掉首尾引号。
    var customJVMArgumentList: [String] {
        customJVMArguments
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    /// 是否真的定制过（用于 UI 上给「已自定义」标记，以及决定是否落盘）。
    var hasCustomization: Bool {
        memoryMB != nil
        || !customJVMArguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || windowWidth != nil
        || windowHeight != nil
        || fullscreen
        || lockedJavaMajor != nil
    }

    init(versionID: String,
         memoryMB: Int? = nil,
         customJVMArguments: String = "",
         windowWidth: Int? = nil,
         windowHeight: Int? = nil,
         fullscreen: Bool = false,
         lockedJavaMajor: Int? = nil) {
        self.versionID = versionID
        self.memoryMB = memoryMB
        self.customJVMArguments = customJVMArguments
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.fullscreen = fullscreen
        self.lockedJavaMajor = lockedJavaMajor
    }

    /// 未定制时的默认值。
    static let `default` = PerVersionSettings(versionID: "")
}

/// 每个版本设置的持久化。范式与 `ServerListStore` 一致：
/// 只在本地落盘、不进任何令牌、不进 UserDefaults。键是版本 id。
final class VersionSettingsStore {
    let fileURL: URL
    private let fileManager = FileManager.default

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("YZLVersionSettings", isDirectory: true)
            self.fileURL = dir.appendingPathComponent("settings.json")
        }
    }

    /// 全部设置（键 = 版本 id）。
    func all() -> [String: PerVersionSettings] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: PerVersionSettings].self, from: data) else {
            return [:]
        }
        return dict
    }

    /// 取某版本的设置；没有则返回「未定制」默认值。
    func settings(for versionID: String) -> PerVersionSettings {
        all()[versionID] ?? PerVersionSettings(versionID: versionID)
    }

    /// 写入或更新某版本的设置。全部字段都为默认时直接删除该版本条目（保持文件精简）。
    func update(_ settings: PerVersionSettings) {
        var dict = all()
        if settings.versionID.isEmpty || !settings.hasCustomization {
            dict.removeValue(forKey: settings.versionID)
        } else {
            dict[settings.versionID] = settings
        }
        save(dict)
    }

    /// 删除某版本的自定义设置（恢复默认）。
    func reset(_ versionID: String) {
        var dict = all()
        dict.removeValue(forKey: versionID)
        save(dict)
    }

    private func save(_ dict: [String: PerVersionSettings]) {
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(dict) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
