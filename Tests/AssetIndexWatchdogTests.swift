import XCTest
import Foundation
@testable import YZLLauncher

/// 复现并锁死「安装版本卡在正在统计安装清单」的回归：
/// 资源索引请求在真机上可能因为 DNS/TLS/系统 connectivity 判断而永久挂起，
/// 此时必须靠硬看门狗在有限时间内返回错误，绝不能让 withTaskGroup 无限等待。
final class AssetIndexWatchdogTests: XCTestCase {

    /// 命中所有请求但永不回调的协议：模拟 URLSession 请求永久挂起。
    private final class HangingProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            // 故意什么都不做：既不返回数据，也不报错。
        }
        override func stopLoading() {}
    }

    /// 核心回归：网络永久挂起时，看门狗必须在上限时间附近强制返回，
    /// 而不是让 prepareInstall() 永远停住。
    func testWatchdogBreaksPermanentlyHangingRequest() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingProtocol.self]
        let session = URLSession(configuration: config)
        let service = AssetIndexService(session: session)
        let url = try XCTUnwrap(URL(string: "https://example.invalid/index.json"))

        let start = Date()
        do {
            _ = try await service.fetch(indexURL: url, hardTimeout: 0.4)
            XCTFail("永久挂起时必须抛错，不能成功返回")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertGreaterThan(elapsed, 0.25, "不应早于看门狗时间返回")
            XCTAssertLessThan(elapsed, 5.0, "看门狗必须在有限时间内强制返回，实测 \(elapsed)s")
        }
    }

    /// 有合法本地缓存时完全不联网，自然也不会被网络挂起拖住。
    func testValidCacheReturnsWithoutNetwork() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let json = #"{"objects":{"a":{"hash":"abc","size":1}}}"#
        try json.write(to: tmp, atomically: true, encoding: .utf8)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingProtocol.self]
        let service = AssetIndexService(session: URLSession(configuration: config))
        let url = try XCTUnwrap(URL(string: "https://example.invalid/index.json"))

        let doc = try await service.fetch(indexURL: url, cacheURL: tmp)
        XCTAssertEqual(doc.objects.count, 1)
    }

    /// 候选地址去重 + 当前源优先顺序（决定看门狗要监控几条并发请求）。
    func testCandidateURLsDedupAndOrder() throws {
        let url = try XCTUnwrap(URL(string: "https://piston-data.mojang.com/v1/packages/ab/index.json"))
        let official = url
        let mirror = try XCTUnwrap(URL(string: "https://bmclapi2.bangbang93.com/v1/packages/ab/index.json"))
        XCTAssertEqual(
            AssetIndexService.candidateURLs(for: url, sources: [.mirror, .official]),
            [mirror, official]
        )
        XCTAssertEqual(
            AssetIndexService.candidateURLs(for: url, sources: [.official, .official]),
            [official]
        )
    }
}
