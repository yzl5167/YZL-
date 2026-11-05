import Foundation

struct DownloadSpec: Codable, Equatable {
    let id: String
    let url: URL
    let destination: URL
    let expectedSHA1: String?
    let expectedSize: Int64?
    var segmentSize: Int64
    var maxConnections: Int

    init(id: String,
         url: URL,
         destination: URL,
         expectedSHA1: String?,
         expectedSize: Int64?,
         segmentSize: Int64 = 1_048_576,
         maxConnections: Int = 8) {
        self.id = id
        self.url = url
        self.destination = destination
        self.expectedSHA1 = expectedSHA1
        self.expectedSize = expectedSize
        self.segmentSize = segmentSize
        self.maxConnections = min(max(maxConnections, 1), 16)
    }
}

struct DownloadSegment: Codable, Equatable, Hashable {
    let start: Int64
    let end: Int64

    var length: Int64 { end - start + 1 }

    var partName: String { "seg-\(start)-\(end).part" }
}

struct ProbeResult: Equatable {
    let supportsRange: Bool
    let totalBytes: Int64?
}

enum DownloadEvent: Equatable {
    case probing
    case planned(totalBytes: Int64, segments: Int, segmented: Bool)
    case progress(downloaded: Int64, total: Int64, active: Int)
    case verifying
    case finished(destination: URL, downloaded: Int64)
}

enum DownloadFailure: LocalizedError, Equatable {
    case rejectedRange
    case missingContentLength
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case segmentExhausted(start: Int64, end: Int64, attempts: Int)
    case ioFailure(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .rejectedRange:
            return "服务器不支持 Range 分片，已改用单连接"
        case .missingContentLength:
            return "服务器没有返回文件大小"
        case .sizeMismatch(let expected, let actual):
            return "大小不符：期望 \(expected) 字节，实际 \(actual) 字节"
        case .checksumMismatch(let expected, let actual):
            return "SHA-1 校验失败：期望 \(expected)，实际 \(actual)"
        case .segmentExhausted(let start, let end, let attempts):
            return "分片 \(start)-\(end) 重试 \(attempts) 次仍失败"
        case .ioFailure(let message):
            return "本地文件操作失败：\(message)"
        case .cancelled:
            return "下载已取消"
        }
    }
}
