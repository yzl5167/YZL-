import XCTest
@testable import YZLLauncher

/// 下载源健康检查：失败计数、成功清零、候选稳定排序与 4xx 豁免。
final class SourceHealthTests: XCTestCase {
    private var health: SourceHealth!
    private let official = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!
    private let mirror = URL(string: "https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json")!

    override func setUp() {
        super.setUp()
        // 每个用例独立实例，互不污染，也不碰进程级 shared。
        health = SourceHealth()
    }

    // MARK: - 计数

    func testFailureCountingAndSuccessReset() {
        XCTAssertFalse(health.isBad(mirror))
        health.recordFailure(mirror)
        health.recordFailure(mirror)
        XCTAssertEqual(health.failureCount(for: mirror), 2)
        XCTAssertTrue(health.isBad(mirror))
        XCTAssertEqual(health.rank(mirror), 1)

        // 一次成功即清零（该 host 恢复健康）。
        health.recordSuccess(mirror)
        XCTAssertEqual(health.failureCount(for: mirror), 0)
        XCTAssertEqual(health.rank(mirror), 0)
    }

    /// 4xx 是「这个文件不存在 / 请求错了」，不是「源坏了」：不把 host 拉黑。
    func testHTTP4xxDoesNotBlacklistHost() {
        health.recordFailure(mirror, reason: "bmclapi2.bangbang93.com：服务器返回 HTTP 404")
        XCTAssertEqual(health.failureCount(for: mirror), 0, "含 HTTP 4 前缀的失败不应计数")

        // 5xx / 超时正常计数。
        health.recordFailure(mirror, reason: "bmclapi2.bangbang93.com：服务器返回 HTTP 502")
        XCTAssertEqual(health.failureCount(for: mirror), 1)
        health.recordFailure(mirror, reason: "请求超时")
        XCTAssertEqual(health.failureCount(for: mirror), 2)
    }

    /// 失败按 host 维度记录：同一 host 的另一个 URL 共享状态，别的 host 不受影响。
    func testFailureCountsArePerHost() throws {
        let sameHostOtherPath = URL(string: "https://bmclapi2.bangbang93.com/mc/game/version_manifest.json")!
        health.recordFailure(mirror)
        XCTAssertEqual(health.failureCount(for: sameHostOtherPath), 1)
        XCTAssertEqual(health.failureCount(for: official), 0)
    }

    // MARK: - 排序

    func testOrderedPutsBrokenSourceLast() {
        health.recordFailure(mirror)
        let candidates = [mirror, official]
        XCTAssertEqual(health.ordered(candidates), [official, mirror])

        // 反向传入结果也应一致（坏源永远排最后）。
        XCTAssertEqual(health.ordered(candidates.reversed()), [official, mirror])
    }

    /// 同权重候选保持原顺序（Swift 的 sorted 不保证稳定，这里必须稳定）。
    func testOrderedIsStableForHealthySources() throws {
        let a = URL(string: "https://a.example.com/1")!
        let b = URL(string: "https://b.example.com/1")!
        let c = URL(string: "https://c.example.com/1")!
        XCTAssertEqual(health.ordered([a, b, c]), [a, b, c])
        XCTAssertEqual(health.ordered([c, b, a]), [c, b, a])
    }

    func testResetClearsEverything() {
        health.recordFailure(mirror)
        health.recordFailure(official)
        health.reset()
        XCTAssertFalse(health.isBad(mirror))
        XCTAssertFalse(health.isBad(official))
    }
}
