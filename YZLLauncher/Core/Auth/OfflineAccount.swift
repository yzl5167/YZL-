import Foundation
import CryptoKit

/// FCL / Pojav 式「离线账号」（伪正版）：不需要任何微软令牌，
/// 用固定算法从用户名算出离线 UUID，单人 / LAN 直接进入游戏。
///
/// 没有正版 Minecraft 的玩家也能下载客户端、离线启动；
/// 在线正版服务器（online-mode=true）会拒绝，这是预期行为。
struct OfflineAccount: Codable, Identifiable, Equatable {
    /// 离线 UUID（见 `offlineUUID(for:)`），同时作为存储主键。
    var id: String
    var name: String
    /// 皮肤模型：`"steve"` / `"alex"` / `"custom"`。
    var skinModel: String
    /// 自定义皮肤地址（可选）。
    var skinURL: String?

    init(name: String, skinModel: String = "steve", skinURL: String? = nil) {
        self.name = name
        self.skinModel = skinModel
        self.skinURL = skinURL
        self.id = OfflineAccount.offlineUUID(for: name)
    }

    /// 伪装成正版档案，启动参数拼装层（LaunchPlanBuilder / ArgumentResolver）
    /// 只认 `MicrosoftAccount`，离线账号直接套一层即可，无需改动下游。
    var asMicrosoftAccount: MicrosoftAccount {
        MicrosoftAccount(id: id, name: name, skinURL: skinURL)
    }

    /// Minecraft 离线 UUID 算法：MD5("OfflinePlayer:" + name)，
    /// 再按 UUID 版本位 / 变体位置位修正，与官方 Launcher 完全一致。
    static func offlineUUID(for name: String) -> String {
        let digest = Insecure.MD5.hash(data: Data("OfflinePlayer:\(name)".utf8))
        var bytes = Array(digest)
        bytes[6] = (bytes[6] & 0x0F) | 0x30   // version 3 (name-based, MD5)
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let start = hex.startIndex
        let p0 = String(hex[start..<hex.index(start, offsetBy: 8)])
        let p1 = String(hex[hex.index(start, offsetBy: 8)..<hex.index(start, offsetBy: 12)])
        let p2 = String(hex[hex.index(start, offsetBy: 12)..<hex.index(start, offsetBy: 16)])
        let p3 = String(hex[hex.index(start, offsetBy: 16)..<hex.index(start, offsetBy: 20)])
        let p4 = String(hex[hex.index(start, offsetBy: 20)...])
        return "\(p0)-\(p1)-\(p2)-\(p3)-\(p4)"
    }
}

/// 离线账号的本地持久化：写到 App Support 下的 JSON，与 Keychain 里的正版会话互不干扰。
struct OfflineAccountStore {
    private let file: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.file = dir.appendingPathComponent("offline-accounts.json")
    }

    func load() -> [OfflineAccount] {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([OfflineAccount].self, from: data) else {
            return []
        }
        return list
    }

    func save(_ accounts: [OfflineAccount]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
