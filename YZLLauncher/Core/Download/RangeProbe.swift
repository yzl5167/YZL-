import Foundation

enum RangeProbe {
    static func evaluate(statusCode: Int, acceptRanges: String?, contentLength: Int64?) -> ProbeResult {
        let rangesOK = (acceptRanges ?? "").lowercased().contains("bytes")
        let lengthOK = (contentLength ?? 0) > 0
        let segmented = statusCode == 200 && rangesOK && lengthOK
        return ProbeResult(supportsRange: segmented, totalBytes: contentLength)
    }
}
