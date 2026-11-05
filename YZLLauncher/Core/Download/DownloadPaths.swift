import Foundation

enum DownloadPaths {
    static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") }
        let result = String(mapped)
        return result.isEmpty ? "version" : result
    }

    static func versionsDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("YZLVersions", isDirectory: true)
    }
}
