import XCTest
@testable import YZLLauncher

final class AuthModelsTests: XCTestCase {
    /// 字段集合取自 2026-11-04 对 login.live.com/oauth20_connect.srf 的真实响应：
    /// 只有 user_code / device_code / verification_uri / interval / expires_in，没有 message。
    func testLiveConnectDeviceCodeDecodesWithoutMessage() throws {
        let json = """
        {
          "user_code": "8GWRQHU6",
          "device_code": "synthetic-live-connect-device-code",
          "verification_uri": "https://www.microsoft.com/link",
          "interval": 5,
          "expires_in": 900
        }
        """.data(using: .utf8)!

        let code = try JSONDecoder().decode(DeviceCode.self, from: json)
        XCTAssertNil(code.message)
        XCTAssertEqual(code.userCode, "8GWRQHU6")
        XCTAssertEqual(code.verificationUri, "https://www.microsoft.com/link")
        XCTAssertEqual(code.expiresIn, 900)
        XCTAssertEqual(code.interval, 5)
    }

    /// 自定义 Azure 客户端走 v2.0，那边会多一个 message 字段。
    func testAzureV2DeviceCodeDecoding() throws {
        let json = """
        {
          "device_code": "device-123",
          "user_code": "ABCD-EFGH",
          "verification_uri": "https://microsoft.com/link",
          "expires_in": 900,
          "interval": 5,
          "message": "Open the page and enter the code"
        }
        """.data(using: .utf8)!

        let code = try JSONDecoder().decode(DeviceCode.self, from: json)
        XCTAssertEqual(code.deviceCode, "device-123")
        XCTAssertEqual(code.userCode, "ABCD-EFGH")
        XCTAssertEqual(code.expiresIn, 900)
        XCTAssertEqual(code.interval, 5)
        XCTAssertNotNil(code.message)
    }

    func testXboxTokenDecoding() throws {
        let json = """
        {
          "Token": "xbox-token",
          "DisplayClaims": { "xui": [{ "uhs": "user-hash" }] }
        }
        """.data(using: .utf8)!

        let token = try JSONDecoder().decode(XboxToken.self, from: json)
        XCTAssertEqual(token.token, "xbox-token")
        XCTAssertEqual(token.displayClaims.xui.first?.uhs, "user-hash")
    }

    func testXSTSTokenDecoding() throws {
        let json = """
        {
          "Token": "xsts-token",
          "DisplayClaims": { "xui": [{ "uhs": "user-hash" }] }
        }
        """.data(using: .utf8)!

        let token = try JSONDecoder().decode(XSTSToken.self, from: json)
        XCTAssertEqual(token.token, "xsts-token")
        XCTAssertEqual(token.uhs, "user-hash")
    }

    func testStoredSessionRoundTrip() throws {
        let session = StoredSession(
            account: MicrosoftAccount(id: "uuid", name: "Steve", skinURL: "https://textures.minecraft.net/texture/example"),
            accessToken: "minecraft-token",
            refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(StoredSession.self, from: data)
        XCTAssertEqual(decoded.account, session.account)
        XCTAssertEqual(decoded.accessToken, session.accessToken)
        XCTAssertEqual(decoded.refreshToken, session.refreshToken)
    }
}
