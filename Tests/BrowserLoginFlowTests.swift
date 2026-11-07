import XCTest
import CryptoKit
@testable import YZLLauncher

/// 浏览器授权码流（默认公共客户端）：PKCE 生成、授权页参数、回调解析。
/// 参数形状对齐 Windows 端 v2.3.8.1 已实跑验证的 MicrosoftAuth.StartLogin。
final class BrowserLoginFlowTests: XCTestCase {
    // MARK: - base64url

    func testBase64URL() {
        XCTAssertEqual(MicrosoftAuthService.base64URL(Data("abc".utf8)), "YWJj")
        // + / = 必须被替换：字节 0xFB 0xEF 0xBE 编码含 + 与 =。
        let data = Data([0xFB, 0xEF, 0xBE])
        let encoded = MicrosoftAuthService.base64URL(data)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        // 与标准 base64 的对应关系。
        XCTAssertEqual(encoded, data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: ""))
    }

    // MARK: - 授权页参数

    func testMakeBrowserLoginURLShape() throws {
        let service = MicrosoftAuthService(clientId: MicrosoftAuth.defaultClientId)
        let login = try XCTUnwrap(service.makeBrowserLogin())

        let components = try XCTUnwrap(URLComponents(url: login.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "login.live.com")
        XCTAssertEqual(components.path, "/oauth20_authorize.srf")

        let query = try XCTUnwrap(components.queryItems)
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value
        }
        XCTAssertEqual(value("client_id"), MicrosoftAuth.defaultClientId)
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("redirect_uri"), MicrosoftAuthService.redirectURI)
        // 浏览器流程的作用域与设备码 / 刷新的 MBI_SSL 不同（Windows 端实测结论）。
        XCTAssertEqual(value("scope"), MicrosoftAuthService.browserScope)
        XCTAssertEqual(MicrosoftAuthService.browserScope, "XboxLive.signin offline_access")
        XCTAssertEqual(value("prompt"), "select_account")
        XCTAssertEqual(value("code_challenge_method"), "S256")

        // PKCE 对：challenge 必须等于 base64url(sha256(verifier))。
        XCTAssertNil(value("code_verifier"), "code_verifier 绝不能出现在授权页 URL 里")
        let challenge = try XCTUnwrap(value("code_challenge"))
        let expected = MicrosoftAuthService.base64URL(Data(SHA256.hash(data: Data(login.codeVerifier.utf8))))
        XCTAssertEqual(challenge, expected)
        XCTAssertNotEqual(challenge, login.codeVerifier)

        // state 存在且是 base64url 形状。
        let state = try XCTUnwrap(value("state"))
        XCTAssertFalse(state.isEmpty)
        XCTAssertFalse(state.contains("="))
    }

    func testMakeBrowserLoginReturnsNilForCustomAzureClient() {
        let custom = MicrosoftAuthService(clientId: "12345678-1234-1234-1234-123456789abc")
        XCTAssertFalse(custom.usesBrowserSignIn)
        XCTAssertNil(custom.makeBrowserLogin())
    }

    // MARK: - 回调解析

    func testParseAuthorizationCallback() throws {
        let codeURL = try XCTUnwrap(URL(string:
            "https://login.live.com/oauth20_desktop.srf?code=CAQE-ABC123&lc=2052"))
        XCTAssertEqual(
            MicrosoftAuthService.parseAuthorizationCallback(codeURL),
            .code("CAQE-ABC123")
        )

        let errorURL = try XCTUnwrap(URL(string:
            "https://login.live.com/oauth20_desktop.srf?error=access_denied&error_description=用户取消了授权"))
        XCTAssertEqual(
            MicrosoftAuthService.parseAuthorizationCallback(errorURL),
            .failure("access_denied：用户取消了授权")
        )

        // 授权页本身与无关地址都不是回调。
        let authorize = try XCTUnwrap(URL(string:
            "https://login.live.com/oauth20_authorize.srf?client_id=x"))
        XCTAssertNil(MicrosoftAuthService.parseAuthorizationCallback(authorize))
        XCTAssertNil(MicrosoftAuthService.parseAuthorizationCallback(try XCTUnwrap(URL(string: "https://www.microsoft.com/link"))))
    }
}
