import Foundation

enum SegmentPlanner {
    static let minSegmentLength: Int64 = 262_144

    static func plan(totalBytes: Int64, segmentSize: Int64) -> [DownloadSegment] {
        guard totalBytes > 0 else { return [] }
        let chunk = max(minSegmentLength, segmentSize)
        var segments: [DownloadSegment] = []
        var start: Int64 = 0
        while start < totalBytes {
            let end = min(start + chunk - 1, totalBytes - 1)
            segments.append(DownloadSegment(start: start, end: end))
            start = end + 1
        }
        return segments
    }

    static func halves(of segment: DownloadSegment) -> [DownloadSegment]? {
        guard segment.length >= minSegmentLength * 2 else { return nil }
        let mid = segment.start + segment.length / 2
        return [
            DownloadSegment(start: segment.start, end: mid - 1),
            DownloadSegment(start: mid, end: segment.end)
        ]
    }

    static func writtenBytes(segments: [DownloadSegment], partSizes: [String: Int64]) -> Int64 {
        segments.reduce(Int64(0)) { total, segment in
            let written = min(partSizes[segment.partName] ?? 0, segment.length)
            return total + written
        }
    }
}
