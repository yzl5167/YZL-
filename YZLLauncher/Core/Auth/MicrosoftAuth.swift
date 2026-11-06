import Foundation
import Security

struct MicrosoftAccount: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let skinURL: String?
}

/// 设备代码流返回的登录会话。
/// Live Connect（oauth20_connect.srf）实测不返回 `message`，只有 Azure v2.0 的
/// `oauth2/v2.0/devicecode` 才带；因此 message 必须可选，否则真实登录会解码失败。
struct DeviceCode: Codable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int
    let message: String?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
        case message
    }
}

struct OAuthToken: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

/// 只保存在本机 Keychain 的登录结果。
struct StoredSession: Codable {
    let account: MicrosoftAccount
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

enum MicrosoftAuthError: LocalizedError {
    case notConfigured
    case badResponse(String)
    case oauth(String)
    case xbox(String)
    case noProfile
    case expired
    /// 微软要求重新完成交互式登录（设备码流无法自行重试 /authorize）。
    case reauthenticationRequired(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "未配置 Azure 公共客户端 ID。请到「设置 → 账户」填入客户端 ID。"
        case .badResponse(let message):
            return "服务器响应异常：\(message)"
        case .oauth(let message):
            return "微软登录失败：\(message)"
        case .xbox(let message):
            return "Xbox 验证失败：\(message)"
        case .noProfile:
            return "该微软账户没有 Minecraft: Java Edition 档案（未购买或授权未同步）。没有正版也可以在账号页创建离线（伪正版）账号。"
        case .expired:
            return "登录代码已过期，请重新登录。"
        case .reauthenticationRequired(let detail):
            return "微软要求重新完成交互式授权：请关闭本页重新发起登录，并先在浏览器里退出其它微软账号、重新输入密码并同意授权。原始错误：\(detail)"
        }
    }
}

/// v1.0 授权码流的回调解析结果，抽成纯函数便于单测。
enum MicrosoftAuthorizationCallback: Equatable {
    case code(String)
    case failure(String)
}

enum MicrosoftAuth {
    /// 与安卓端使用同一个公共客户端 ID（Pojav 系设备码流），开箱即可登录。
    /// 用户也可以在设置页换成自己的 Azure 公共客户端 ID。
    static let defaultClientId = "00000000402b5328"
    static let clientIdKey = "microsoftClientId"

    static var clientId: String {
        let saved = UserDefaults.standard.string(forKey: clientIdKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? defaultClientId : saved
    }

    static var isConfigured: Bool {
        !clientId.isEmpty
    }
}

struct MicrosoftAuthService {
    /// 微软端点在国内偶发高延迟：请求超时 30s、整资源 120s，并允许等待网络恢复，
    /// 避免一次抖动就被映射成「登录失败」。
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    /// 该公共客户端在微软侧登记的固定回调地址，WebView 拦截后不真正加载。
    static let redirectURI = "https://login.live.com/oauth20_desktop.srf"

    let clientId: String
    var session: URLSession = MicrosoftAuthService.defaultSession

    /// Pojav 系默认公共客户端走 Live Connect；自定义 Azure 客户端走 v2.0 consumers。
    private var usesLiveConnect: Bool {
        clientId.caseInsensitiveCompare(MicrosoftAuth.defaultClientId) == .orderedSame
    }

    /// 默认客户端是 MSA v1.0 原生客户端，只支持浏览器授权码流；
    /// 自定义 Azure 应用才支持 v2.0 设备码流。
    var usesBrowserSignIn: Bool { usesLiveConnect }

    private var scope: String {
        usesLiveConnect ? "service::user.auth.xboxlive.com::MBI_SSL" : "XboxLive.signin offline_access"
    }

    private var deviceCodeURL: URL {
        URL(string: usesLiveConnect
            ? "https://login.live.com/oauth20_connect.srf"
            : "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode")!
    }

    private var tokenURL: URL {
        URL(string: usesLiveConnect
            ? "https://login.live.com/oauth20_token.srf"
            : "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!
    }

    /// Live Connect v1.0 授权码流登录页。设备码端点虽然也会发 code，但用户授权后
    /// token 端点会返回 interaction_required（MSA v1.0 客户端不在 AAD 目录），
    /// 因此默认客户端必须走这里。
    var authorizationURL: URL? {
        guard usesLiveConnect else { return nil }
        var components = URLComponents(string: "https://login.live.com/oauth20_authorize.srf")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI)
        ]
        return components?.url
    }

    /// 解析 `oauth20_desktop.srf` 回调；非回调地址返回 nil，WebView 照常加载。
    static func parseAuthorizationCallback(_ url: URL) -> MicrosoftAuthorizationCallback? {
        guard url.path.lowercased().contains("oauth20_desktop.srf") else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return .code(code)
        }
        let error = items.first(where: { $0.name == "error" })?.value ?? "授权未完成"
        let description = items.first(where: { $0.name == "error_description" })?.value
        return .failure([error, description].compactMap { $0 }.joined(separator: "："))
    }

    private static let xboxURL = URL(string: "https://user.auth.xboxlive.com/user/authenticate")!
    private static let xstsURL = URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!
    private static let minecraftLoginURL = URL(string: "https://api.minecraftservices.com/authentication/login_with_xbox")!
    private static let profileURL = URL(string: "https://api.minecraftservices.com/minecraft/profile")!

    func requestDeviceCode() async throws -> DeviceCode {
        try validateClientId()

        var request = URLRequest(url: deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = [
            "client_id": clientId,
            "scope": scope
        ]
        if usesLiveConnect {
            form["response_type"] = "device_code"
        }
        request.httpBody = formBody(form)

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw MicrosoftAuthError.oauth(errorMessage(from: data, status: response.statusCode))
        }
        return try decode(DeviceCode.self, from: data)
    }

    /// 轮询 token 端点，直到用户完成授权或代码过期。
    func waitForToken(deviceCode: DeviceCode) async throws -> OAuthToken {
        let deadline = Date().addingTimeInterval(TimeInterval(max(deviceCode.expiresIn, 60)))
        var interval = max(deviceCode.interval, 1)

        while Date() < deadline {
            try Task.checkCancellation()

            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody([
                "client_id": clientId,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": deviceCode.deviceCode
            ])

            let (data, response) = try await send(request)
            if response.statusCode == 200 {
                return try decode(OAuthToken.self, from: data)
            }

            let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data)
            let oauthError = body?.error ?? ""
            switch oauthError {
            case "authorization_pending":
                break
            case "slow_down":
                interval += 5
            case "temporarily_unavailable", "server_error":
                // 服务端瞬时故障：继续轮询，别把一次抖动判成登录失败。
                interval = min(interval + 5, 30)
            case "expired_token", "bad_verification_code":
                throw MicrosoftAuthError.expired
            case "access_denied", "authorization_declined":
                throw MicrosoftAuthError.oauth("用户取消了授权")
            case "interaction_required", "consent_required", "login_required", "invalid_grant":
                // The user could not be authenticated or user interaction is required…
                // 设备码流无法自行重试 /authorize，只能给出可操作的中文指引。
                let raw = [oauthError, body?.errorDescription]
                    .compactMap { $0 }
                    .joined(separator: "：")
                throw MicrosoftAuthError.reauthenticationRequired(raw)
            default:
                let raw = [oauthError.isEmpty ? nil : oauthError, body?.errorDescription]
                    .compactMap { $0 }
                    .joined(separator: "：")
                throw MicrosoftAuthError.oauth(raw.isEmpty ? "HTTP \(response.statusCode)" : raw)
            }

            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
        }

        throw MicrosoftAuthError.expired
    }

    /// 启动时用保存的刷新令牌续期。
    func refresh(refreshToken: String) async throws -> OAuthToken {
        try validateClientId()

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": scope
        ])

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw MicrosoftAuthError.oauth(errorMessage(from: data, status: response.statusCode))
        }
        return try decode(OAuthToken.self, from: data)
    }

    /// v1.0 授权码 → 访问令牌。与设备码流共用同一个 token 端点，
    /// 只是 grant_type 换成 authorization_code，并带上微软登记的 redirect_uri。
    func exchangeAuthorizationCode(_ code: String) async throws -> OAuthToken {
        try validateClientId()

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": clientId,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": Self.redirectURI,
            "scope": scope
        ])

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw MicrosoftAuthError.oauth(errorMessage(from: data, status: response.statusCode))
        }
        return try decode(OAuthToken.self, from: data)
    }

    /// OAuth 访问令牌 → Xbox Live → XSTS → Minecraft 档案。
    func makeSession(from token: OAuthToken) async throws -> StoredSession {
        let xbox = try await authenticateXbox(accessToken: token.accessToken)
        let xsts = try await authorizeXSTS(xboxToken: xbox.token)
        let minecraft = try await loginMinecraft(uhs: xsts.uhs, xstsToken: xsts.token)
        let profile = try await fetchProfile(accessToken: minecraft.accessToken)

        return StoredSession(
            account: profile,
            accessToken: minecraft.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(minecraft.expiresIn))
        )
    }

    /// `MBI_SSL` scope 换到的是预成型 RPS ticket，XBL 要求裸传（无前缀）；
    /// Azure v2.0 `XboxLive.signin` 拿到的是普通 access token，用 `t=`。
    /// 两条路都保留 `d=` 回退，避免服务端策略差异导致登录必败。
    func rpsTicketPrefixes() -> [String] {
        usesLiveConnect ? ["", "d"] : ["t", "d"]
    }

    private func authenticateXbox(accessToken: String) async throws -> XboxToken {
        var lastError: Error?
        for prefix in rpsTicketPrefixes() {
            let ticket = prefix.isEmpty ? accessToken : "\(prefix)=\(accessToken)"
            do {
                let payload: [String: Any] = [
                    "Properties": [
                        "AuthMethod": "RPS",
                        "SiteName": "user.auth.xboxlive.com",
                        "RpsTicket": ticket
                    ],
                    "RelyingParty": "http://auth.xboxlive.com",
                    "TokenType": "JWT"
                ]
                return try await postJSON(XboxToken.self, to: Self.xboxURL, payload: payload)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MicrosoftAuthError.xbox("Xbox 认证失败")
    }

    private func authorizeXSTS(xboxToken: String) async throws -> XSTSToken {
        let payload: [String: Any] = [
            "RelyingParty": "rp://api.minecraftservices.com/",
            "TokenType": "JWT",
            "Properties": [
                "SandboxId": "RETAIL",
                "UserTokens": [xboxToken]
            ]
        ]

        var request = URLRequest(url: Self.xstsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            if let error = try? JSONDecoder().decode(XSTSError.self, from: data) {
                throw MicrosoftAuthError.xbox(xstsMessage(for: error.xerr))
            }
            throw MicrosoftAuthError.xbox("HTTP \(response.statusCode)")
        }

        let token = try decode(XSTSToken.self, from: data)
        guard let uhs = token.displayClaims.xui.first?.uhs else {
            throw MicrosoftAuthError.xbox("响应里没有用户哈希（UHS）")
        }
        return XSTSToken(token: token.token, uhs: uhs, displayClaims: token.displayClaims)
    }

    private func loginMinecraft(uhs: String, xstsToken: String) async throws -> MinecraftToken {
        let payload: [String: Any] = [
            "identityToken": "XBL3.0 x=\(uhs);\(xstsToken)"
        ]

        var request = URLRequest(url: Self.minecraftLoginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw MicrosoftAuthError.oauth("Minecraft 登录失败 · \(errorDetail(from: data, status: response.statusCode))")
        }
        return try decode(MinecraftToken.self, from: data)
    }

    private func fetchProfile(accessToken: String) async throws -> MicrosoftAccount {
        var request = URLRequest(url: Self.profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 404 {
                throw MicrosoftAuthError.noProfile
            }
            throw MicrosoftAuthError.oauth("获取 Minecraft 档案失败 · \(errorDetail(from: data, status: response.statusCode))")
        }
        let profile = try decode(MinecraftProfile.self, from: data)
        let skinURL = profile.skins?.first(where: { ($0.state ?? "ACTIVE").uppercased() == "ACTIVE" })?.url
            ?? profile.skins?.first?.url
        return MicrosoftAccount(id: profile.id, name: profile.name, skinURL: skinURL)
    }

    // MARK: - HTTP helpers

    private func validateClientId() throws {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MicrosoftAuthError.notConfigured }
        if trimmed.caseInsensitiveCompare(MicrosoftAuth.defaultClientId) != .orderedSame {
            let pattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
            guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
                throw MicrosoftAuthError.oauth("设置里的微软客户端 ID 不是合法 GUID")
            }
        }
    }

    private func postJSON<T: Decodable>(_ type: T.Type, to url: URL, payload: [String: Any]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw MicrosoftAuthError.xbox(errorDetail(from: data, status: response.statusCode))
        }
        return try decode(T.self, from: data)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MicrosoftAuthError.badResponse("不是 HTTP 响应")
            }
            return (data, http)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MicrosoftAuthError {
            throw error
        } catch {
            throw MicrosoftAuthError.badResponse(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MicrosoftAuthError.badResponse(error.localizedDescription)
        }
    }

    /// 把服务端原始错误体带出来：Xbox / XSTS / Minecraft 各自的失败原因都不一样，
    /// 只报「HTTP 4xx」用户无从排查。响应不是 OAuth 格式时退回原文前 240 字节。
    private func errorDetail(from data: Data, status: Int) -> String {
        if let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data) {
            let suffix = body.errorDescription.map { " · \($0)" } ?? ""
            return "HTTP \(status) · \(body.error)\(suffix)"
        }
        let text = (String(data: data.prefix(240), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "HTTP \(status)" : "HTTP \(status) · \(text)"
    }

    private func errorMessage(from data: Data, status: Int) -> String {
        errorDetail(from: data, status: status)
    }

    private func formBody(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private func xstsMessage(for code: Int?) -> String {
        guard let code else { return "XSTS 返回错误 未知" }
        switch code {
        case 2148916233:
            return "该微软账户还没有 Xbox 账户，请先在 xbox.com 创建。"
        case 2148916235:
            return "Xbox Live 在你所在地区不可用。"
        case 2148916236, 2148916237:
            return "该账户需要完成年龄验证。"
        case 2148916238:
            return "儿童账户需要先加入 Microsoft 家庭组。"
        default:
            return "XSTS 返回错误 \(code)"
        }
    }
}

// MARK: - Response models

private struct OAuthErrorBody: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// `/user/authenticate` 只用 Token。DisplayClaims 在部分响应里缺失或不带 uhs，
/// 强制解码会让整个登录在拿到有效 token 后仍失败；UHS 一律从 XSTS 响应取。
struct XboxToken: Decodable {
    let token: String

    enum CodingKeys: String, CodingKey {
        case token = "Token"
    }
}

struct XSTSToken: Decodable {
    let token: String
    let uhs: String
    let displayClaims: DisplayClaims

    struct DisplayClaims: Decodable {
        let xui: [XUI]
    }

    struct XUI: Decodable {
        let uhs: String
    }

    enum CodingKeys: String, CodingKey {
        case token = "Token"
        case displayClaims = "DisplayClaims"
    }

    init(token: String, uhs: String, displayClaims: DisplayClaims) {
        self.token = token
        self.uhs = uhs
        self.displayClaims = displayClaims
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        displayClaims = try container.decode(DisplayClaims.self, forKey: .displayClaims)
        guard let uhs = displayClaims.xui.first?.uhs else {
            throw DecodingError.dataCorruptedError(
                forKey: .displayClaims,
                in: container,
                debugDescription: "XSTS response has no uhs"
            )
        }
        self.uhs = uhs
    }
}

private struct XSTSError: Decodable {
    let xerr: Int?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case xerr = "XErr"
        case message = "Message"
    }
}

private struct MinecraftToken: Decodable {
    let accessToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

private struct MinecraftProfile: Decodable {
    let id: String
    let name: String
    let skins: [Skin]?

    struct Skin: Decodable {
        let url: String
        let variant: String?
        let state: String?

        enum CodingKeys: String, CodingKey {
            case url
            case variant
            case state
        }
    }
}

// MARK: - Keychain

struct AuthSessionStore {
    private let service = "com.yzl.launcher.auth"
    private let account = "session"

    init() {}

    func save(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    func load() -> StoredSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let session = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            return nil
        }
        return session
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
