import XCTest
@testable import YZLLauncher

/// 两个真机回归：
/// 1) 资源索引在镜像模式下必须保持官方地址，且获取失败能回退到另一条源；
/// 2) 默认公共客户端必须走 v1.0 网页授权码流，设备码流只能用于自定义 Azure 应用。
final class LoginAndIndexRegressionTests: XCTestCase {

    // MARK: - 资源索引

    func testAssetIndexCandidatesDedupeToOfficial() throws {
        let index = try XCTUnwrap(URL(string: "https://piston-meta.mojang.com/v1/packages/abc/5.json"))
        let candidates = AssetIndexService.candidateURLs(for: index, sources: [.mirror, .official])
        XCTAssertEqual(candidates.count, 1, "索引只走官方，两个源应去重成一个")
        XCTAssertEqual(candidates.first?.host, "piston-meta.mojang.com")
    }

    func testOrdinaryFileHasPrimaryAndFallbackSources() throws {
        let jar = try XCTUnwrap(URL(string: "https://piston-data.mojang.com/v1/objects/abc/client.jar"))
        let candidates = AssetIndexService.candidateURLs(for: jar, sources: [.mirror, .official])
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates[0].host?.contains("bangbang93") == true)
        XCTAssertEqual(candidates[1].host, "piston-data.mojang.com")
    }

    func testAssetIndexErrorIsActionable() {
        let message = VersionServiceError.assetIndexUnavailable("bmclapi2.bangbang93.com：HTTP 502").errorDescription ?? ""
        XCTAssertTrue(message.contains("官方源与镜像源"))
        XCTAssertTrue(message.contains("下载源"), "失败信息应告诉用户去哪里切换下载源")
    }

    func testMetadataCandidatesAlwaysIncludeOfficialFallback() throws {
        let manifest = try XCTUnwrap(URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"))
        let candidates = MetadataFetcher.candidates(for: manifest)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(
            candidates.contains { $0.host == "piston-meta.mojang.com" },
            "无论当前下载源是官方还是镜像，官方地址都必须在候选里"
        )
    }

    func testMetadataErrorIsActionable() {
        let message = VersionServiceError.metadataUnavailable("HTTP 502").errorDescription ?? ""
        XCTAssertTrue(message.contains("官方源与镜像源"))
        XCTAssertTrue(message.contains("下载源"))
    }

    // MARK: - 微软登录分支

    func testDefaultClientUsesBrowserAuthorizationCodeFlow() throws {
        let service = MicrosoftAuthService(clientId: MicrosoftAuth.defaultClientId)
        XCTAssertTrue(service.usesBrowserSignIn)
        XCTAssertEqual(service.rpsTicketPrefixes(), ["", "d"], "MBI_SSL 令牌是预成型 RPS ticket，应裸传优先")

        let url = try XCTUnwrap(service.authorizationURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        XCTAssertEqual(components.host, "login.live.com")
        XCTAssertEqual(components.path, "/oauth20_authorize.srf")
        XCTAssertEqual(items.first { $0.name == "client_id" }?.value, MicrosoftAuth.defaultClientId)
        XCTAssertEqual(items.first { $0.name == "response_type" }?.value, "code")
        XCTAssertEqual(items.first { $0.name == "redirect_uri" }?.value, MicrosoftAuthService.redirectURI)
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "service::user.auth.xboxlive.com::MBI_SSL")
    }

    func testCustomAzureClientKeepsDeviceCodeFlow() {
        let service = MicrosoftAuthService(clientId: "11111111-2222-3333-4444-555555555555")
        XCTAssertFalse(service.usesBrowserSignIn)
        XCTAssertNil(service.authorizationURL)
        XCTAssertEqual(service.rpsTicketPrefixes(), ["t", "d"])
    }

    func testParseAuthorizationCallbackCode() throws {
        let url = try XCTUnwrap(URL(string: "https://login.live.com/oauth20_desktop.srf?code=M.C123_BL2&lc=1033"))
        XCTAssertEqual(MicrosoftAuthService.parseAuthorizationCallback(url), .code("M.C123_BL2"))
    }

    func testParseAuthorizationCallbackError() throws {
        let url = try XCTUnwrap(URL(string: "https://login.live.com/oauth20_desktop.srf?error=access_denied&error_description=User%20cancelled"))
        guard let parsed = MicrosoftAuthService.parseAuthorizationCallback(url),
              case .failure(let message) = parsed else {
            XCTFail("应解析为失败")
            return
        }
        XCTAssertTrue(message.contains("access_denied"))
    }

    func testParseAuthorizationCallbackIgnoresOtherURLs() throws {
        let url = try XCTUnwrap(URL(string: "https://login.live.com/oauth20_authorize.srf?client_id=abc"))
        XCTAssertNil(MicrosoftAuthService.parseAuthorizationCallback(url))
    }

    func testReauthenticationErrorExplainsNextStep() {
        let message = MicrosoftAuthError
            .reauthenticationRequired("interaction_required：The user could not be authenticated")
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("重新完成交互式授权"))
        XCTAssertTrue(message.contains("退出其它微软账号"))
    }
}
