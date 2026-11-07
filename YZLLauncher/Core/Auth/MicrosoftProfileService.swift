import Foundation

// MARK: - 档案模型

/// Minecraft Services 档案里的披风条目。
struct MinecraftCape: Equatable, Identifiable {
    let id: String
    let alias: String?
    let url: String?
    let state: String

    var isActive: Bool { state.uppercased() == "ACTIVE" }
}

/// GET /minecraft/profile 的解析结果（skins 里只关心 ACTIVE 项）。
struct MicrosoftProfile: Equatable {
    /// 当前装备皮肤贴图 URL（Mojang 官方 CDN）。
    let skinURL: String?
    /// "SLIM" / "CLASSIC"（原始大小写，展示时自行转换）。
    let skinVariant: String?
    let capes: [MinecraftCape]
}

enum MicrosoftProfileError: LocalizedError {
    case badResponse(String)
    case invalidToken

    var errorDescription: String? {
        switch self {
        case .badResponse(let message):
            return "微软档案操作失败：\(message)"
        case .invalidToken:
            return "登录已过期，请重新登录微软账号。"
        }
    }
}

// MARK: - 服务

/// 微软官方皮肤上传 / 披风管理（Minecraft Services API）。
/// 协议与 Windows 端 `MinecraftSkinService.cs` 逐条对齐：
/// - 上传皮肤：multipart 字段名是 **variant**（slim/classic）+ file（不是 Yggdrasil 的 model！）；
/// - 恢复默认皮肤：DELETE /minecraft/profile/skins/active；
/// - 装备披风：PUT /minecraft/profile/capes/active，body {"capeId": "..."}；
/// - 隐藏披风：DELETE /minecraft/profile/capes/active（没有 capeId:null 的写法）；
/// - 错误文案从 errorMessage → error → errorType 依次取。
struct MicrosoftProfileService {
    static let baseURL = "https://api.minecraftservices.com"

    var session: URLSession = MicrosoftProfileService.defaultSession

    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    // MARK: 上传 / 重置皮肤

    /// 上传皮肤：PNG 原始字节直接进 multipart（不做转码，与 Windows 端一致）。
    func uploadSkin(token: String, pngData: Data, variant: String) async throws {
        let multipart = Self.skinUploadBody(pngData: pngData, variant: variant)
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/minecraft/profile/skins")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.body
        _ = try await expectSuccess(request, action: "上传皮肤")
    }

    /// 恢复为微软默认皮肤。
    func resetSkin(token: String) async throws {
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/minecraft/profile/skins/active")!)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await expectSuccess(request, action: "恢复默认皮肤")
    }

    // MARK: 披风

    /// 装备披风。端点是 /capes/active（不是 /capes），body 只有 capeId。
    func equipCape(token: String, capeID: String) async throws {
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/minecraft/profile/capes/active")!)
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.equipCapeBody(capeID: capeID)
        _ = try await expectSuccess(request, action: "装备披风")
    }

    /// 取消装备（隐藏）披风。
    func hideCape(token: String) async throws {
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/minecraft/profile/capes/active")!)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await expectSuccess(request, action: "隐藏披风")
    }

    // MARK: 档案

    /// 拉取档案（皮肤 + 披风列表）。上传 / 换披风后调用方用它刷新本地会话。
    func fetchProfile(token: String) async throws -> MicrosoftProfile {
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/minecraft/profile")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftProfileError.badResponse("服务器返回了无法识别的响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw MicrosoftProfileError.invalidToken
            }
            throw MicrosoftProfileError.badResponse(Self.errorMessage(in: data, status: http.statusCode))
        }
        guard let profile = Self.parseProfile(data) else {
            throw MicrosoftProfileError.badResponse("档案 JSON 解析失败")
        }
        return profile
    }

    // MARK: HTTP 骨架

    private func expectSuccess(_ request: URLRequest, action: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftProfileError.badResponse("服务器返回了无法识别的响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw MicrosoftProfileError.invalidToken
            }
            throw MicrosoftProfileError.badResponse(Self.errorMessage(in: data, status: http.statusCode))
        }
        return data
    }

    // MARK: - 纯函数（抽出来给单测，不碰网络）

    /// 上传皮肤的 multipart body（字段顺序照 Windows 端：先 variant 后 file）。
    static func skinUploadBody(pngData: Data, variant: String) -> (body: Data, contentType: String) {
        let boundary = "yzl-" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"variant\"\r\n\r\n".utf8))
        body.append(Data("\(variant)\r\n".utf8))
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"skin.png\"\r\n".utf8))
        body.append(Data("Content-Type: image/png\r\n\r\n".utf8))
        body.append(pngData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    /// 装备披风的请求体。
    static func equipCapeBody(capeID: String) -> Data {
        let object: [String: Any] = ["capeId": capeID]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// profile 响应解析：skins 里取 state == "ACTIVE" 的 url / variant（SLIM 原样保留）。
    static func parseProfile(_ data: Data) -> MicrosoftProfile? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var skinURL: String?
        var skinVariant: String?
        if let skins = object["skins"] as? [[String: Any]] {
            let active = skins.first { ($0["state"] as? String)?.uppercased() == "ACTIVE" } ?? skins.first
            skinURL = active?["url"] as? String
            skinVariant = active?["variant"] as? String
        }

        var capes: [MinecraftCape] = []
        if let capeList = object["capes"] as? [[String: Any]] {
            for cape in capeList {
                guard let id = cape["id"] as? String else { continue }
                capes.append(MinecraftCape(
                    id: id,
                    alias: cape["alias"] as? String,
                    url: cape["url"] as? String,
                    state: (cape["state"] as? String) ?? ""
                ))
            }
        }
        return MicrosoftProfile(skinURL: skinURL, skinVariant: skinVariant, capes: capes)
    }

    /// 错误文案：errorMessage → error → errorType → 原文前 220 字符（与 Windows 端一致）。
    static func errorMessage(in data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["errorMessage", "error", "errorType"] {
                if let message = object[key] as? String, !message.isEmpty {
                    return message
                }
            }
        }
        let raw = String(decoding: data.prefix(220), as: UTF8.self)
        return raw.isEmpty ? "HTTP \(status)" : "HTTP \(status)：\(raw)"
    }
}
