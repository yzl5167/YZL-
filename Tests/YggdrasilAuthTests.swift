import XCTest
@testable import YZLLauncher

/// 皮肤站（Yggdrasil）协议：地址规范化、UUID 格式化、
/// authenticate / refresh / textures 响应解析与 multipart 皮肤上传体。
final class YggdrasilAuthTests: XCTestCase {
    // MARK: - 地址规范化

    func testNormalizeServer() {
        // 空串用默认（LittleSkin）。
        XCTAssertEqual(YggdrasilAuth.normalizeServer(""), YggdrasilAuth.defaultServer)
        XCTAssertEqual(YggdrasilAuth.normalizeServer("   "), YggdrasilAuth.defaultServer)

        // 只填域名：补 scheme 与 API 路径。
        XCTAssertEqual(
            YggdrasilAuth.normalizeServer("littleskin.cn"),
            "https://littleskin.cn/api/yggdrasil"
        )

        // 已带 scheme 但缺路径。
        XCTAssertEqual(
            YggdrasilAuth.normalizeServer("https://mcskin.example.com"),
            "https://mcskin.example.com/api/yggdrasil"
        )

        // 完整 API Root 原样保留（含 http 自建站）。
        XCTAssertEqual(
            YggdrasilAuth.normalizeServer("https://littleskin.cn/api/yggdrasil"),
            "https://littleskin.cn/api/yggdrasil"
        )
        XCTAssertEqual(
            YggdrasilAuth.normalizeServer("http://192.168.1.10:8080/api/yggdrasil"),
            "http://192.168.1.10:8080/api/yggdrasil"
        )

        // 尾部斜杠去掉。
        XCTAssertEqual(
            YggdrasilAuth.normalizeServer("littleskin.cn/"),
            "https://littleskin.cn/api/yggdrasil"
        )
        XCTAssertEqual(
            YggdrasilAuth.normalizeServer("https://littleskin.cn/api/yggdrasil/"),
            "https://littleskin.cn/api/yggdrasil"
        )
    }

    // MARK: - UUID 格式化

    func testFormatUUID() {
        XCTAssertEqual(
            YggdrasilAuth.formatUUID(raw: "0123456789abcdef0123456789abcdef"),
            "01234567-89ab-cdef-0123-456789abcdef"
        )
        // 大写转小写。
        XCTAssertEqual(
            YggdrasilAuth.formatUUID(raw: "0123456789ABCDEF0123456789ABCDEF"),
            "01234567-89ab-cdef-0123-456789abcdef"
        )
        // 不是 32 位就原样返回。
        XCTAssertEqual(YggdrasilAuth.formatUUID(raw: "abc"), "abc")
        XCTAssertEqual(
            YggdrasilAuth.formatUUID(raw: "01234567-89ab-cdef-0123-456789abcdef"),
            "01234567-89ab-cdef-0123-456789abcdef"
        )
    }

    // MARK: - authenticate 响应

    func testParseAuthenticateSuccessWithSelectedProfile() throws {
        let data = Data(#"""
        {
          "accessToken": "randomAccessToken",
          "clientToken": "serverClientToken",
          "selectedProfile": {"id": "0123456789abcdef0123456789abcdef", "name": "Steve"},
          "availableProfiles": [
            {"id": "ffffffffffffffffffffffffffffffff", "name": "Other"}
          ]
        }
        """#.utf8)

        let result = try YggdrasilAuthService.parseAuthenticateResponse(data, fallbackClientToken: "local")
        XCTAssertEqual(result.profileID, "01234567-89ab-cdef-0123-456789abcdef")
        XCTAssertEqual(result.profileName, "Steve")
        XCTAssertEqual(result.accessToken, "randomAccessToken")
        XCTAssertEqual(result.clientToken, "serverClientToken", "优先用服务器回带的 clientToken")
    }

    func testParseAuthenticateFallsBackToFirstAvailableProfile() throws {
        let data = Data(#"""
        {
          "accessToken": "t",
          "availableProfiles": [
            {"id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "name": "First"},
            {"id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "name": "Second"}
          ]
        }
        """#.utf8)

        let result = try YggdrasilAuthService.parseAuthenticateResponse(data, fallbackClientToken: "local")
        XCTAssertEqual(result.profileName, "First")
        XCTAssertEqual(result.clientToken, "local", "服务器没回带时沿用本地 clientToken")
    }

    func testParseAuthenticateErrorBodySurfacesServerMessage() {
        let data = Data(#"""
        {"error": "ForbiddenOperationException", "errorMessage": "Invalid credentials. Invalid username or password."}
        """#.utf8)

        XCTAssertThrowsError(try YggdrasilAuthService.parseAuthenticateResponse(data, fallbackClientToken: "local")) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("Invalid credentials"), "要把皮肤站的人话错误带出来：\(message)")
        }
    }

    func testParseAuthenticateRequiresAccessToken() {
        let data = Data(#"""
        {"clientToken": "c", "selectedProfile": {"id": "0123456789abcdef0123456789abcdef", "name": "Steve"}}
        """#.utf8)

        XCTAssertThrowsError(try YggdrasilAuthService.parseAuthenticateResponse(data, fallbackClientToken: "local")) { error in
            guard case YggdrasilAuthError.missingToken = error else {
                return XCTFail("应报「没有返回登录令牌」，实际：\(error)")
            }
        }
    }

    func testParseAuthenticateWithoutProfilesReportsNoProfile() {
        let data = Data(#"{"accessToken": "t"}"#.utf8)

        XCTAssertThrowsError(try YggdrasilAuthService.parseAuthenticateResponse(data, fallbackClientToken: "local")) { error in
            guard case YggdrasilAuthError.noProfile = error else {
                return XCTFail("应报「请先去皮肤站网页创建角色」，实际：\(error)")
            }
        }
    }

    // MARK: - refresh 响应

    func testParseRefreshSuccessAndFailure() {
        let ok = Data(#"{"accessToken": "newToken"}"#.utf8)
        XCTAssertEqual(try? YggdrasilAuthService.parseRefreshResponse(ok), "newToken")

        // 空 accessToken → 会话失效。
        let empty = Data(#"{"accessToken": ""}"#.utf8)
        XCTAssertThrowsError(try YggdrasilAuthService.parseRefreshResponse(empty)) { error in
            guard case YggdrasilAuthError.sessionExpired = error else {
                return XCTFail("应报会话失效，实际：\(error)")
            }
        }

        // 服务器明确拒绝 → 带出人话错误。
        let denied = Data(#"{"error": "ForbiddenOperationException", "errorMessage": "Invalid token."}"#.utf8)
        XCTAssertThrowsError(try YggdrasilAuthService.parseRefreshResponse(denied)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("Invalid token"), message)
        }
    }

    // MARK: - sessionserver textures

    /// 构造 sessionserver 响应：properties[].textures 的 value 是 Base64 编码的 JSON。
    private func texturesPayload(skinModel: String?, cape: Bool) -> Data {
        var skin = "{\"url\": \"https://skin.example.com/texture.png\""
        if let skinModel {
            skin += ", \"metadata\": {\"model\": \"\(skinModel)\"}"
        }
        skin += "}"

        var textures = "{\"SKIN\": \(skin)"
        if cape {
            textures += ", \"CAPE\": {\"url\": \"https://skin.example.com/cape.png\"}"
        }
        textures += "}"

        let value = Data(textures.utf8).base64EncodedString()
        return Data("{\"properties\": [{\"name\": \"textures\", \"value\": \"\(value)\"}]}".utf8)
    }

    func testParseTexturesSlimModelAndCape() {
        let parsed = YggdrasilAuthService.parseTexturesResponse(texturesPayload(skinModel: "slim", cape: true))
        XCTAssertEqual(parsed?.skinURL, "https://skin.example.com/texture.png")
        XCTAssertEqual(parsed?.skinModel, "alex", "slim 模型 → alex")
        XCTAssertEqual(parsed?.capeURL, "https://skin.example.com/cape.png")
    }

    func testParseTexturesClassicDefaultsToSteve() {
        let classic = YggdrasilAuthService.parseTexturesResponse(texturesPayload(skinModel: "classic", cape: false))
        XCTAssertEqual(classic?.skinModel, "steve")
        XCTAssertNil(classic?.capeURL)

        // 没有 metadata 也按 steve。
        let noMetadata = YggdrasilAuthService.parseTexturesResponse(texturesPayload(skinModel: nil, cape: false))
        XCTAssertEqual(noMetadata?.skinModel, "steve")
    }

    func testParseTexturesReturnsNilWhenMissing() {
        XCTAssertNil(YggdrasilAuthService.parseTexturesResponse(Data(#"{"properties": []}"#.utf8)))
        XCTAssertNil(YggdrasilAuthService.parseTexturesResponse(Data("not json".utf8)))
        XCTAssertNil(YggdrasilAuthService.parseTexturesResponse(Data(#"{"properties": [{"name": "uploadableTextures", "value": "eA=="}]}"#.utf8)))
    }

    // MARK: - multipart 皮肤上传

    func testSkinUploadBodyStructure() throws {
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let (body, contentType) = YggdrasilAuthService.skinUploadBody(imageData: pngMagic, model: "slim")

        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = contentType.components(separatedBy: "boundary=").last ?? ""
        XCTAssertFalse(boundary.isEmpty)

        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains(#"Content-Disposition: form-data; name="file"; filename="skin.png""#))
        XCTAssertTrue(text.contains("Content-Type: image/png"))
        XCTAssertTrue(text.contains(#"Content-Disposition: form-data; name="model""#))
        XCTAssertTrue(text.contains("\r\nslim\r\n"), "model 字段值应为 slim")
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
        // PNG 数据要原封不动嵌进去（multipart 直接拼字节）。
        XCTAssertTrue(body.range(of: pngMagic) != nil)
    }

    // MARK: - 错误文案优先级

    func testErrorMessagePriority() {
        let prioritized = Data(#"""
        {"error": "E", "errorMessage": "EM", "message": "M"}
        """#.utf8)
        XCTAssertEqual(YggdrasilAuthService.errorMessage(in: prioritized), "EM")

        let legacyOnly = Data(#"{"error": "E", "message": "M"}"#.utf8)
        XCTAssertEqual(YggdrasilAuthService.errorMessage(in: legacyOnly), "M")

        let errorOnly = Data(#"{"error": "E"}"#.utf8)
        XCTAssertEqual(YggdrasilAuthService.errorMessage(in: errorOnly), "E")

        XCTAssertNil(YggdrasilAuthService.errorMessage(in: Data("{}".utf8)))
    }

    // MARK: - 账号模型

    func testAccountAdaptersAndHelpers() {
        var account = YggdrasilAccount(
            id: "01234567-89ab-cdef-0123-456789abcdef",
            name: "Steve",
            serverURL: "https://littleskin.cn/api/yggdrasil",
            skinURL: nil,
            skinModel: "steve",
            capeURL: nil
        )
        XCTAssertEqual(account.rawUUID, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(account.serverHost, "littleskin.cn")

        let adapted = account.asMicrosoftAccount
        XCTAssertEqual(adapted.id, account.id)
        XCTAssertEqual(adapted.name, "Steve")
        XCTAssertNil(adapted.skinURL)

        account = account.updatingTextures(YggdrasilTextures(
            skinURL: "https://skin.example.com/t.png",
            skinModel: "alex",
            capeURL: "https://skin.example.com/c.png"
        ))
        XCTAssertEqual(account.skinModel, "alex")
        XCTAssertEqual(account.skinURL, "https://skin.example.com/t.png")
        XCTAssertEqual(account.capeURL, "https://skin.example.com/c.png")
    }
}
