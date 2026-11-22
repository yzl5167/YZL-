import XCTest
@testable import YZLLauncher

/// 修复助手 + 日志：动作语义、启动日志有损解码与冷启动重置。
final class DiagnosticsAndLogTests: XCTestCase {

    func testFixActionAutoFixSemantics() {
        XCTAssertTrue(DiagnosticItem.FixAction.clearDownloadCache.isAutoFix)
        XCTAssertTrue(DiagnosticItem.FixAction.resetSourceHealth.isAutoFix)
        XCTAssertFalse(DiagnosticItem.FixAction.openAccount.isAutoFix)
        XCTAssertFalse(DiagnosticItem.FixAction.openJavaSettings.isAutoFix)
        XCTAssertFalse(DiagnosticItem.FixAction.openMobileCompat.isAutoFix)
        XCTAssertFalse(DiagnosticItem.FixAction.openDownloadPage.isAutoFix)
    }

    func testFixActionButtonTitles() {
        XCTAssertEqual(DiagnosticItem.FixAction.clearDownloadCache.buttonTitle, "清理")
        XCTAssertEqual(DiagnosticItem.FixAction.openAccount.buttonTitle, "去登录")
        XCTAssertEqual(DiagnosticItem.FixAction.openJavaSettings.buttonTitle, "去管理")
    }

    func testStatusRawValues() {
        XCTAssertEqual(DiagnosticItem.Status.ok.rawValue, "ok")
        XCTAssertEqual(DiagnosticItem.Status.warning.rawValue, "warning")
        XCTAssertEqual(DiagnosticItem.Status.failed.rawValue, "failed")
    }

    func testGameLogSourceTitles() {
        XCTAssertEqual(GameLogService.Source.boot.title, "启动器日志")
        XCTAssertEqual(GameLogService.Source.game.title, "游戏日志")
        XCTAssertEqual(GameLogService.Source.allCases.count, 2)
    }

    /// 启动日志写入后能读回（异步串行，稍等；有损解码不因坏字节丢整份）。
    func testBootLogWriteAndRead() {
        YZLBootLog.resetForNewSessionIfNeeded()
        let marker = "unit-test-marker-\(UUID().uuidString)"
        YZLBootLog.write(marker)
        let got = expectation(description: "boot log async write")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { got.fulfill() }
        wait(for: [got], timeout: 2.0)
        XCTAssertTrue(YZLBootLog.readText().contains(marker), "写入的标记应出现在日志尾部")
    }
}
