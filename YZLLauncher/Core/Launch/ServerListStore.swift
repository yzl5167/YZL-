import Foundation

/// 服务器收藏列表持久化。数据落在 `Documents/YZLServers/servers.json`，
/// 范式与 `InstalledVersionStore` 一致：只在本地落盘、不进任何令牌、不进 UserDefaults。
final class ServerListStore {
    private let fileURL: URL
    private let fileManager = FileManager.default

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("YZLServers", isDirectory: true)
            self.fileURL = dir.appendingPathComponent("servers.json")
        }
    }

    func load() -> [MinecraftServer] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([MinecraftServer].self, from: data) else { return [] }
        // 收藏置顶，其余按名称排序，体验与 PC 端服务器列表一致。
        return list.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }

    func save(_ servers: [MinecraftServer]) {
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(servers) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
