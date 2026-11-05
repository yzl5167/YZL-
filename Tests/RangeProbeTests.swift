import XCTest
@testable import YZLLauncher

final class RangeProbeTests: XCTestCase {
    func testHeadWithRangesAndLengthAllowsSegmenting() {
        let result = RangeProbe.evaluate(statusCode: 200, acceptRanges: "bytes", contentLength: 23_028_853)
        XCTAssertTrue(result.supportsRange)
        XCTAssertEqual(result.totalBytes, 23_028_853)
    }

    func testHeadWithoutRangesFallsBackToSingleConnection() {
        let result = RangeProbe.evaluate(statusCode: 200, acceptRanges: nil, contentLength: 1_000)
        XCTAssertFalse(result.supportsRange)
    }

    func testHeadWithoutLengthFallsBackToSingleConnection() {
        let result = RangeProbe.evaluate(statusCode: 200, acceptRanges: "bytes", contentLength: nil)
        XCTAssertFalse(result.supportsRange)
    }

    func testNonOKStatusFallsBackToSingleConnection() {
        let result = RangeProbe.evaluate(statusCode: 405, acceptRanges: "bytes", contentLength: 1_000)
        XCTAssertFalse(result.supportsRange)
    }
}
