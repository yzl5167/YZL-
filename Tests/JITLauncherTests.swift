import XCTest
@testable import YZLLauncher

/// 一键开性能模式：URL 组装 + 等待调试器生效。
/// 这块的目标不是「让 iOS 不需要 JIT」，而是把用户要做的动作压到一次点击。
final class JITLauncherTests: XCTestCase {

    // MARK: - URL 组装

    func testStikDebugURLHasBundleAndPID() {
        let list = JITLauncher.candidates(bundleID: "com.yzl.launcher", pid: 4321, osMajor: 18)
        guard let first = list.first else { return XCTFail("至少应有 StikDebug 候选") }
        XCTAssertEqual(first.scheme, "stikdebug")
        XCTAssertEqual(first.url.absoluteString,
                       "stikdebug://enable-jit?bundle-id=com.yzl.launcher&pid=4321")
        // 旧系统不能带 script-name，否则助手会报「找不到脚本」。
        XCTAssertFalse(first.url.absoluteString.contains("script-name"))
    }

    func testIOS26PrefersScriptVariant() {
        let list = JITLauncher.candidates(bundleID: "com.yzl.launcher", pid: 99, osMajor: 26)
        guard list.count >= 2 else { return XCTFail("iOS 26 应先给带脚本的候选，再给通用的") }
        XCTAssertTrue(list[0].url.absoluteString.contains("script-name=universal"))
        XCTAssertFalse(list[1].url.absoluteString.contains("script-name"))
    }

    func testOlderSystemHasNoScriptCandidate() {
        let list = JITLauncher.candidates(bundleID: "com.yzl.launcher", pid: 1, osMajor: 17)
        XCTAssertFalse(list.contains { $0.url.absoluteString.contains("script-name") })
    }

    func testLegacyStikJitSchemeKeptForOldInstall() {
        let list = JITLauncher.candidates(bundleID: "com.yzl.launcher", pid: 7, osMajor: 18)
        XCTAssertTrue(list.contains { $0.scheme == "stikjit" })
    }

    func testTrollStoreCandidateHasNoPID() {
        let list = JITLauncher.candidates(bundleID: "com.yzl.launcher", pid: 7, osMajor: 16)
        guard let last = list.last else { return XCTFail("应有 TrollStore 兜底候选") }
        XCTAssertEqual(last.scheme, "apple-magnifier")
        // TrollStore 是给进程补 entitlement，不认 pid。
        XCTAssertFalse(last.url.absoluteString.contains("pid="))
        XCTAssertTrue(last.url.absoluteString.contains("bundle-id=com.yzl.launcher"))
    }

    func testEmptyBundleIDYieldsNothing() {
        XCTAssertTrue(JITLauncher.candidates(bundleID: "", pid: 1, osMajor: 18).isEmpty)
        XCTAssertNil(JITLauncher.enableURL(scheme: "stikdebug", bundleID: "", pid: 1, scriptName: nil))
    }

    func testBundleIDWithDashIsPreserved() {
        let url = JITLauncher.enableURL(scheme: "stikdebug",
                                        bundleID: "com.angelauramc.amethyst-yzl",
                                        pid: 12,
                                        scriptName: nil)
        XCTAssertEqual(url?.absoluteString,
                       "stikdebug://enable-jit?bundle-id=com.angelauramc.amethyst-yzl&pid=12")
    }

    // MARK: - 等待生效

    func testWaitTimesOutWhenNeverEnabled() async {
        let start = Date()
        let ok = await JITProbe.waitUntilEnabled(timeout: 0.3, interval: 0.1) { false }
        XCTAssertFalse(ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testWaitSucceedsAfterRetries() async {
        final class Box { var hits = 0 }
        let box = Box()
        let ok = await JITProbe.waitUntilEnabled(timeout: 3, interval: 0.1) {
            box.hits += 1
            return box.hits >= 3
        }
        XCTAssertTrue(ok)
        XCTAssertGreaterThanOrEqual(box.hits, 3)
    }

    func testWaitReturnsImmediatelyWhenAlreadyEnabled() async {
        final class Box { var hits = 0 }
        let box = Box()
        let start = Date()
        let ok = await JITProbe.waitUntilEnabled(timeout: 3, interval: 0.5) {
            box.hits += 1
            return true
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(box.hits, 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
