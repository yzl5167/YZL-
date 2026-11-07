import XCTest
@testable import YZLLauncher

/// 清理下载缓存：只删分片/清单缓存与临时导出目录，已安装版本不受影响。
final class DownloadCacheTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.sandbox) }
    }

    func testClearRemovesResumeAndManifestCacheOnly() throws {
        // 断点分片目录（传显式路径需要 ResumeStateStore 也落在这里——直接按 DownloadCache 的默认结构造）。
        let resume = DownloadCache.resumeDirectory()
        try FileManager.default.createDirectory(at: resume, withIntermediateDirectories: true)
        try Data("part".utf8).write(to: resume.appendingPathComponent("state-abc.json"))
        try Data("part".utf8).write(to: resume.appendingPathComponent("seg-0-99.part"))

        // 清单缓存。
        let manifest = DownloadCache.manifestCacheURL()
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: manifest)

        // 已安装版本（必须不受影响）。
        let layout = InstallLayout.forVersion("yzl-cache-keep")
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try Data("game".utf8).write(to: layout.versionJSON)
        defer { try? FileManager.default.removeItem(at: layout.root) }

        let result = DownloadCache.clear()
        XCTAssertGreaterThan(result.bytesRemoved, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resume.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.versionJSON.path), "已安装版本不能被清理")
        XCTAssertTrue(result.lines.contains { $0.contains("分片") })
    }

    func testPendingBytesReflectsCacheSize() throws {
        let before = DownloadCache.pendingBytes()
        let resume = DownloadCache.resumeDirectory()
        try FileManager.default.createDirectory(at: resume, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: resume.appendingPathComponent("seg.part"))
        let after = DownloadCache.pendingBytes()
        XCTAssertEqual(after - before, 4096)
        // 清掉，不污染其它测试。
        _ = DownloadCache.clear()
    }

    func testClearIsIdempotentOnEmptyState() {
        let result = DownloadCache.clear()
        XCTAssertTrue(result.lines.contains { $0.contains("没有") })
        XCTAssertEqual(result.bytesRemoved, 0)
    }
}
