import Foundation
import Security

// MARK: - 账号模型

/// 皮肤站账号（authlib-injector / Blessing Skin / LittleSkin 的 Yggdrasil 协议）。
/// 档案本身不含令牌：accessToken / clientToken 按 `id` 存 Keychain（见 YggdrasilSessionStore），
/// 与「微软会话进 Keychain、离线账号进 JSON」的分层保持一致。
struct YggdrasilAccount: Codable, Identifiable, Equatable {
    /// 角色档案 UUID（8-4-4-4-12 带横杠格式），同时作为存储主键。
    var id: String
    var name: String
    /// 规范化后的 API Root（见 `YggdrasilAuth.normalizeServer`）。
    var serverURL: String
    var skinURL: String?
    /// "steve" / "alex"。
    var skinModel: String
    var capeURL: String?

    /// 伪装成正版档案，让 LaunchPlanBuilder / 头像渲染等下游零改动（同 OfflineAccount 适配器）。
    var asMicrosoftAccount: MicrosoftAccount {
        MicrosoftAccount(id: id, name: name, skinURL: skinURL)
    }

    /// 32 位无横杠形式，sessionserver / 上传接口都用它。
    var rawUUID: String {
        id.replacingOccurrences(of: "-", with: "")
    }

    /// 卡片上展示用的主机名（「littleskin.cn」比整串 API Root 好认）。
    var serverHost: String {
        URL(string: serverURL)?.host ?? serverURL
    }

    func updatingTextures(_ textures: YggdrasilTextures) -> YggdrasilAccount {
        var next = self
        next.skinURL = textures.skinURL
        next.skinModel = textures.skinModel
        next.capeURL = textures.capeURL
        return next
    }
}

/// sessionserver 解析出的材质三元组（抽出来便于单测）。
struct YggdrasilTextures: Equatable {
    let skinURL: String?
    let skinModel: String
    let capeURL: String?
}

/// Keychain 里的皮肤站令牌对。Yggdrasil 的 refreshToken 字段其实存的是
/// clientToken（与 Android 端一致），这里显式分名，避免误当 OAuth refresh token 用。
struct YggdrasilSession: Codable {
    var accessToken: String
    var clientToken: String
    var updatedAt: Date
}

/// 皮肤站账号档案的本地持久化：App Support 下的 JSON 数组。
/// 令牌不在这里——只有档案字段，泄露面与离线账号列表同级。
struct YggdrasilAccountStore {
    private let file: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.file = dir.appendingPathComponent("yggdrasil-accounts.json")
    }

    func load() -> [YggdrasilAccount] {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([YggdrasilAccount].self, from: data) else {
            // 读失败（首启无文件 / 文件损坏）按空列表处理：账号丢了可以重新登录，
            // 不能因此让 App 启动崩溃。
            return []
        }
        return list
    }

    func save(_ accounts: [YggdrasilAccount]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Keychain

/// 皮肤站令牌的 Keychain 存取：每个账号一条（account = 账号 id），
/// 模板照抄 MicrosoftAuth.swift 的 AuthSessionStore（delete-then-add）。
struct YggdrasilSessionStore {
    private let service = "com.yzl.launcher.yggdrasil"

    init() {}

    func save(_ session: YggdrasilSession, accountID: String) {
        guard let data = try? JSONEncoder().encode(session) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    func load(accountID: String) -> YggdrasilSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let session = try? JSONDecoder().decode(YggdrasilSession.self, from: data) else {
            return nil
        }
        return session
    }

    func clear(accountID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 协议常量与纯函数

enum YggdrasilAuth {
    /// 与 Android / Windows 端一致的默认皮肤站（LittleSkin 的 Yggdrasil API Root）。
    static let defaultServer = "https://littleskin.cn/api/yggdrasil"

    /// 规范化用户输入的皮肤站地址：
    /// 空串用默认；无 scheme 补 https://；去尾部斜杠；不以 /api/yggdrasil 结尾则追加。
    /// 这样「littleskin.cn」「https://mcskin.xyz」以及完整 API Root 都能填。
    static func normalizeServer(_ input: String) -> String {
        var server = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if server.isEmpty {
            return defaultServer
        }
        if !server.hasPrefix("http://") && !server.hasPrefix("https://") {
            server = "https://" + server
        }
        while server.hasSuffix("/") {
            server.removeLast()
        }
        if !server.hasSuffix("/api/yggdrasil") {
            server += "/api/yggdrasil"
        }
        return server
    }

    /// 32 位 hex → 8-4-4-4-12 小写横杠格式；不是 32 位就原样返回。
    static func formatUUID(raw: String) -> String {
        let hex = raw.lowercased()
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit }) else { return raw }
        let start = hex.startIndex
        let p0 = String(hex[start..<hex.index(start, offsetBy: 8)])
        let p1 = String(hex[hex.index(start, offsetBy: 8)..<hex.index(start, offsetBy: 12)])
        let p2 = String(hex[hex.index(start, offsetBy: 12)..<hex.index(start, offsetBy: 16)])
        let p3 = String(hex[hex.index(start, offsetBy: 16)..<hex.index(start, offsetBy: 20)])
        let p4 = String(hex[hex.index(start, offsetBy: 20)...])
        return "\(p0)-\(p1)-\(p2)-\(p3)-\(p4)"
    }

    /// 本地生成的 clientToken（32 位无横杠 UUID），服务器没回带时沿用本地值。
    static func newClientToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

enum YggdrasilAuthError: LocalizedError {
    case badResponse(String)
    case missingToken
    case noProfile
    case sessionExpired
    case invalidProfileID

    var errorDescription: String? {
        switch self {
        case .badResponse(let message):
            return "皮肤站登录失败：\(message)"
        case .missingToken:
            return "皮肤站没有返回登录令牌，请稍后重试。"
        case .noProfile:
            return "该皮肤站账号还没有角色，请先去皮肤站网页创建角色后再登录。"
        case .sessionExpired:
            return "皮肤站登录已失效，请重新登录。"
        case .invalidProfileID:
            return "角色 UUID 格式异常，无法继续操作。"
        }
    }
}

// MARK: - 服务

/// Yggdrasil 协议服务：登录 / 刷新 / 材质同步 / 皮肤上传与重置。
/// 协议与字段严格对照 Android 端 `accounts/SkinStationAuth.kt` 的实测行为。
struct YggdrasilAuthService {
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    var session: URLSession = YggdrasilAuthService.defaultSession

    // MARK: 登录

    struct LoginResult {
        let profileID: String
        let profileName: String
        let accessToken: String
        let clientToken: String
    }

    /// Yggdrasil authenticate。用户名是皮肤站的邮箱或用户名，密码只在皮肤站
    /// 与本机之间传输，不经第三方；clientToken 用响应回带的（没有就用本地生成的）。
    func authenticate(server: String, username: String, password: String) async throws -> LoginResult {
        let apiRoot = YggdrasilAuth.normalizeServer(server)
        let localClientToken = YggdrasilAuth.newClientToken()

        let payload: [String: Any] = [
            "username": username,
            "password": password,
            "clientToken": localClientToken,
            "agent": ["name": "Minecraft", "version": 1],
            "requestUser": false
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)

        let data = try await post(
            url: try Self.endpoint("\(apiRoot)/authserver/authenticate"),
            body: body,
            contentType: "application/json"
        )
        return try Self.parseAuthenticateResponse(data, fallbackClientToken: localClientToken)
    }

    /// Yggdrasil refresh：accessToken 过期后用 clientToken 换新的。
    /// accessToken 为空直接抛失效（不自动重登，与 Android 端一致）。
    func refresh(server: String, accessToken: String, clientToken: String) async throws -> YggdrasilSession {
        guard !accessToken.isEmpty else {
            throw YggdrasilAuthError.sessionExpired
        }
        let apiRoot = YggdrasilAuth.normalizeServer(server)
        let payload: [String: Any] = [
            "accessToken": accessToken,
            "clientToken": clientToken,
            "requestUser": false
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)

        let data = try await post(
            url: try Self.endpoint("\(apiRoot)/authserver/refresh"),
            body: body,
            contentType: "application/json"
        )
        let parsed = try Self.parseRefreshResponse(data)
        return YggdrasilSession(
            accessToken: parsed,
            clientToken: clientToken,
            updatedAt: Date()
        )
    }

    // MARK: 材质

    /// sessionserver 拉取皮肤 / 披风。任何失败返回 nil，由调用方静默保留旧值
    /// （皮肤站偶发 5xx 不该让登录流程整体失败）。
    func fetchTextures(server: String, rawUUID: String) async -> YggdrasilTextures? {
        let apiRoot = YggdrasilAuth.normalizeServer(server)
        guard let url = URL(string: "\(apiRoot)/sessionserver/session/minecraft/profile/\(rawUUID)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("YZLLauncher/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return Self.parseTexturesResponse(data)
        } catch {
            return nil
        }
    }

    // MARK: 皮肤上传 / 重置（Yggdrasil API 扩展，Bearer 鉴权）

    /// 上传皮肤：multipart（file=skin.png + model），成功后调用方应重新 fetchTextures。
    func uploadSkin(server: String, rawUUID: String, accessToken: String, model: String, imageData: Data) async throws {
        let url = try skinEndpoint(server: server, rawUUID: rawUUID)
        let multipart = Self.skinUploadBody(imageData: imageData, model: model)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 60
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.body

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw YggdrasilAuthError.badResponse("上传皮肤被拒绝（HTTP \(status)）")
        }
    }

    /// 重置为皮肤站默认皮肤。
    func resetSkin(server: String, rawUUID: String, accessToken: String) async throws {
        let url = try skinEndpoint(server: server, rawUUID: rawUUID)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw YggdrasilAuthError.badResponse("重置皮肤被拒绝（HTTP \(status)）")
        }
    }

    private func skinEndpoint(server: String, rawUUID: String) throws -> URL {
        guard rawUUID.count == 32 else {
            throw YggdrasilAuthError.invalidProfileID
        }
        let apiRoot = YggdrasilAuth.normalizeServer(server)
        return try Self.endpoint("\(apiRoot)/api/user/profile/\(rawUUID)/skin")
    }

    /// 用户手输的皮肤站地址可能带空格等非法字符：URL 构造失败要报错而不是崩。
    private static func endpoint(_ raw: String) throws -> URL {
        guard let url = URL(string: raw) else {
            throw YggdrasilAuthError.badResponse("皮肤站地址无法解析：\(raw)")
        }
        return url
    }

    // MARK: HTTP 骨架

    private func post(url: URL, body: Data, contentType: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("YZLLauncher/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YggdrasilAuthError.badResponse("服务器返回了无法识别的响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 优先把皮肤站的 errorMessage 带给用户（比如「密码错误」「邮箱不存在」）。
            let message = Self.errorMessage(in: data) ?? "HTTP \(http.statusCode)"
            throw YggdrasilAuthError.badResponse(message)
        }
        return data
    }

    // MARK: - 纯解析函数（抽出来给单测，不碰网络）

    /// authenticate 响应：2xx 且无 error 字段才算成功；角色优先 selectedProfile，
    /// 没有则取 availableProfiles[0]；两者皆无视为「还没创建角色」。
    static func parseAuthenticateResponse(_ data: Data, fallbackClientToken: String) throws -> LoginResult {
        let payload = try? JSONDecoder().decode(AuthenticatePayload.self, from: data)
        if let error = payload?.apiError, !error.isEmpty {
            let message = payload?.apiErrorMessage ?? payload?.legacyMessage ?? error
            throw YggdrasilAuthError.badResponse(message)
        }
        guard let payload else {
            throw YggdrasilAuthError.badResponse("响应不是有效的 Yggdrasil 格式")
        }
        guard let token = payload.accessToken, !token.isEmpty else {
            throw YggdrasilAuthError.missingToken
        }

        let profile: AuthenticatePayload.Profile
        if let selected = payload.selectedProfile {
            profile = selected
        } else if let first = payload.availableProfiles?.first {
            profile = first
        } else {
            throw YggdrasilAuthError.noProfile
        }

        return LoginResult(
            profileID: YggdrasilAuth.formatUUID(raw: profile.id),
            profileName: profile.name,
            accessToken: token,
            clientToken: payload.clientToken ?? fallbackClientToken
        )
    }

    /// refresh 响应：必须回带新的 accessToken。
    static func parseRefreshResponse(_ data: Data) throws -> String {
        let payload = try? JSONDecoder().decode(RefreshPayload.self, from: data)
        if let error = payload?.apiError, !error.isEmpty {
            let message = payload?.apiErrorMessage ?? payload?.legacyMessage ?? error
            throw YggdrasilAuthError.badResponse(message)
        }
        guard let token = payload?.accessToken, !token.isEmpty else {
            throw YggdrasilAuthError.sessionExpired
        }
        return token
    }

    /// sessionserver 响应：properties 里 name == "textures" 的 value 是
    /// Base64 编码的 JSON，内含 SKIN / CAPE 两类材质与 slim 模型标记。
    /// 找不到 textures 属性或解码失败返回 nil。
    static func parseTexturesResponse(_ data: Data) -> YggdrasilTextures? {
        guard let payload = try? JSONDecoder().decode(TexturesPayload.self, from: data),
              let property = payload.properties?.first(where: { $0.name == "textures" }),
              let decoded = Data(base64Encoded: property.value),
              let envelope = try? JSONDecoder().decode(TextureEnvelope.self, from: decoded) else {
            return nil
        }

        let skin = envelope.textures?["SKIN"]
        let model = skin?.metadata?.model
        // 与 Android 端一致：slim（忽略大小写）→ alex，其余一律 steve。
        let skinModel = (model?.caseInsensitiveCompare("slim") == .orderedSame) ? "alex" : "steve"
        // 已知支持 TLS 的贴图域名升级 https（Mojang CDN 返回 http，ATS 会拦）。
        let skinURL = (skin?.url).flatMap(URL.init(string:)).map { SkinTexture.upgradedToHTTPS($0) }?.absoluteString
        let capeURL = (envelope.textures?["CAPE"]?.url).flatMap(URL.init(string:))
            .map { SkinTexture.upgradedToHTTPS($0) }?.absoluteString
        return YggdrasilTextures(
            skinURL: skinURL,
            skinModel: skinModel,
            capeURL: capeURL
        )
    }

    /// 上传皮肤的 multipart body（字段顺序与 Android 端一致：先 file 后 model）。
    static func skinUploadBody(imageData: Data, model: String) -> (body: Data, contentType: String) {
        let boundary = "yzl-" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"skin.png\"\r\n".utf8))
        body.append(Data("Content-Type: image/png\r\n\r\n".utf8))
        body.append(imageData)
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8))
        body.append(Data("\(model)\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    /// 从错误体里按 errorMessage → message → error 的顺序取人话文案。
    static func errorMessage(in data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(RefreshPayload.self, from: data) else { return nil }
        if let message = payload.apiErrorMessage, !message.isEmpty { return message }
        if let legacy = payload.legacyMessage, !legacy.isEmpty { return legacy }
        if let error = payload.apiError, !error.isEmpty { return error }
        return nil
    }
}

// MARK: - 私有解码模型

private struct AuthenticatePayload: Decodable {
    struct Profile: Decodable {
        let id: String
        let name: String
    }

    let accessToken: String?
    let clientToken: String?
    let selectedProfile: Profile?
    let availableProfiles: [Profile]?
    let apiError: String?
    let apiErrorMessage: String?
    let legacyMessage: String?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case clientToken
        case selectedProfile
        case availableProfiles
        case apiError = "error"
        case apiErrorMessage = "errorMessage"
        case legacyMessage = "message"
    }
}

private struct RefreshPayload: Decodable {
    let accessToken: String?
    let apiError: String?
    let apiErrorMessage: String?
    let legacyMessage: String?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case apiError = "error"
        case apiErrorMessage = "errorMessage"
        case legacyMessage = "message"
    }
}

private struct TexturesPayload: Decodable {
    struct Property: Decodable {
        let name: String
        let value: String
    }

    let properties: [Property]?
}

private struct TextureEnvelope: Decodable {
    struct TextureInfo: Decodable {
        struct Metadata: Decodable {
            let model: String?
        }

        let url: String?
        let metadata: Metadata?
    }

    let textures: [String: TextureInfo]?
}
