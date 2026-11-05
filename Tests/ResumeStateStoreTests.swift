import XCTest
@testable import YZLLauncher

final class ResumeStateStoreTests: XCTestCase {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("YZLTests-\(UUID().uuidString)", isDirectory: true)
    }

    func testStateRoundTripAndClear() throws {
        let directory = makeDirectory()
        let store = ResumeStateStore(directory: directory)
        let spec = DownloadSpec(
            id: "client-1-20-1",
            url: URL(string: "https://piston-data.mojang.com/v1/objects/0c3ec587af28e5a785c0b4a7b8a30f9a8f78f838/client.jar")!,
            destination: directory.appendingPathComponent("client.jar"),
            expectedSHA1: "0c3ec587af28e5a785c0b4a7b8a30f9a8f78f838",
            expectedSize: 23_028_853
        )
        let segments = SegmentPlanner.plan(totalBytes: spec.expectedSize ?? 0, segmentSize: spec.segmentSize)
        XCTAssertEqual(segments.count, 22)

        store.save(DownloadState(spec: spec, segments: segments, updatedAt: Date()))
        let loaded = try XCTUnwrap(store.load(spec.id))
        XCTAssertEqual(loaded.spec, spec)
        XCTAssertEqual(loaded.segments.count, segments.count)

        store.clear(spec.id)
        XCTAssertNil(store.load(spec.id))
    }

    func testPartNamesAreUniquePerRange() {
        let first = DownloadSegment(start: 0, end: 1_048_575)
        let second = DownloadSegment(start: 1_048_576, end: 2_097_151)
        XCTAssertNotEqual(first.partName, second.partName)
        XCTAssertTrue(first.partName.hasPrefix("seg-0-"))
    }

    func testSanitizeKeepsFileSystemSafeNames() {
        XCTAssertEqual(DownloadPaths.sanitize("26.4-snapshot-7"), "26.4-snapshot-7")
        XCTAssertEqual(DownloadPaths.sanitize("a/b:c"), "a-b-c")
        XCTAssertFalse(DownloadPaths.sanitize("").isEmpty)
    }
}
