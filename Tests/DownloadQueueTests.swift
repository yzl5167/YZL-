import XCTest
@testable import YZLLauncher

/// 安装完成面板的「完成」按钮回归：终态 .finished 必须能被关闭。
final class DownloadQueueTests: XCTestCase {

    @MainActor
    func testDismissFinishedResetsToIdle() async {
        let queue = DownloadQueue()

        // 空队列会直接走到 execute 的终态分支：没有失败文件且 doneFiles == totalFiles，
        // 因此 phase 变为 .finished，无需任何网络 mock。
        queue.start([])

        let deadline = Date().addingTimeInterval(5)
        while queue.state.phase != .finished, Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(queue.state.phase, .finished)

        queue.dismissTerminalState()
        XCTAssertEqual(queue.state.phase, .idle)
    }
}
