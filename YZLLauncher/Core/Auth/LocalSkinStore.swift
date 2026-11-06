import Foundation
import UIKit

/// 离线账号的本地皮肤存储：`Documents/YZLSkins/<账号 id>.png`。
///
/// 对照 Android 端 SkinScreen 的本地导入：从相册选图 → 校验尺寸 → 存 PNG。
/// 引用统一写成 `yzl-local-skin://<文件名>?v=<时间戳>` 塞进 `skinURL`，
/// AvatarView / SkinBodyView 看到这个 scheme 就走本地文件，不走网络。
/// 时间戳参数让重复导入时引用变化，UI 的 `.task(id:)` 会重新取图。
struct LocalSkinStore {
    /// 本地皮肤引用的自定义 scheme（不是真实网络协议）。
    static let scheme = "yzl-local-skin"

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.directory = docs.appendingPathComponent("YZLSkins", isDirectory: true)
        }
    }

    /// 合法皮肤贴图尺寸：64×32（旧版）、64×64（新版）、128×64 / 128×128（高清）。
    /// 与 Android 端 SkinScreen 的校验规则一致。
    static func isValidSkinTexture(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = cgImage.width
        let height = cgImage.height
        guard width == 64 || width == 128 else { return false }
        return height == width || height * 2 == width
    }

    func fileURL(fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// 账号 id 对应的本地皮肤引用（写入 skinURL 的值）。
    func reference(accountID: String) -> String {
        "\(Self.scheme)://\(accountID).png?v=\(Int(Date().timeIntervalSince1970))"
    }

    /// 保存 PNG 并返回引用串；尺寸不合法抛错，不落盘。
    @discardableResult
    func save(image: UIImage, accountID: String) throws -> String {
        guard Self.isValidSkinTexture(image), let data = image.pngData() else {
            throw SkinStoreError.invalidTexture
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(fileName: "\(accountID).png"), options: .atomic)
        return reference(accountID: accountID)
    }

    func remove(accountID: String) {
        try? FileManager.default.removeItem(at: fileURL(fileName: "\(accountID).png"))
    }

    /// AvatarView / SkinBodyView 的本地取图入口：引用形如 `yzl-local-skin://<id>.png?v=…`。
    func load(from url: URL) -> UIImage? {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let fileName = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !fileName.isEmpty else { return nil }
        guard let data = try? Data(contentsOf: fileURL(fileName: fileName)) else { return nil }
        return UIImage(data: data)
    }
}

enum SkinStoreError: LocalizedError {
    case invalidTexture

    var errorDescription: String? {
        switch self {
        case .invalidTexture:
            return "皮肤贴图尺寸不合法：需要 64×32、64×64、128×64 或 128×128。"
        }
    }
}
