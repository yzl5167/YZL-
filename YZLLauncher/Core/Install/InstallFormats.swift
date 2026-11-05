import Foundation

enum InstallFormats {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(max(0, bytesPerSecond))) + "/s"
    }
}
