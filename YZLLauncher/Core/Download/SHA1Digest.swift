import Foundation
import CryptoKit

enum SHA1Digest {
    static func hex(of fileURL: URL, chunkSize: Int = 1_048_576) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        var hasher = Insecure.SHA1()
        defer { try? handle.close() }
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
