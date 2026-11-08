import Foundation

/// 一个 Minecraft 多人服务器收藏。对齐 PC 端 `MainWindow.Multiplayer` 的服务器条目：
/// 名称、地址（可带端口）、收藏状态、上次游玩时间。iOS 上「联机」仅负责收藏与快速进服，
/// 真正的服务器列表/好友/局域网扫描在游戏内由 LWJGL 网络栈完成（Pojav/Amethyst 已支持）。
struct MinecraftServer: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// 用户输入的地址，可能带端口，如 `mc.example.com` 或 `mc.example.com:25567`。
    var address: String
    var port: Int
    var isFavorite: Bool
    var lastPlayed: Date?
    var note: String

    init(id: UUID = UUID(),
         name: String,
         address: String,
         port: Int = 25565,
         isFavorite: Bool = false,
         lastPlayed: Date? = nil,
         note: String = "") {
        self.id = id
        self.name = name.isEmpty ? address : name
        self.address = address
        self.port = port
        self.isFavorite = isFavorite
        self.lastPlayed = lastPlayed
        self.note = note
    }

    /// 去掉可能附带的端口后的纯主机名（传给游戏的 `--server` 只需要主机）。
    var host: String {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = raw.firstIndex(of: ":") {
            return String(raw[raw.startIndex..<range])
        }
        return raw
    }

    /// 写入启动参数的连接串 `"host:port"`，与游戏内直连框一致。
    var connectAddress: String { "\(host):\(port)" }

    /// 从用户输入（`mc.x:25567` / `mc.x`）解析出主机与端口，缺省 25565。
    static func parse(_ input: String) -> (host: String, port: Int) {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return ("", 25565) }
        if let colon = raw.firstIndex(of: ":"),
           let p = Int(raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)),
           (1...65535).contains(p) {
            return (String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces), p)
        }
        return (raw, 25565)
    }
}
