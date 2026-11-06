import Foundation

struct DownloadState: Codable, Equatable {
    var spec: DownloadSpec
    var segments: [DownloadSegment]
    var updatedAt: Date
}

final class ResumeStateStore {
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("YZLDownloads", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// specID 可能是 Maven 路径（如 `lib-org/ow2/asm/9.8/asm-9.8.jar`），
    /// 直接拼进文件名会写进未创建的子目录，导致断点状态与分片全部落盘失败。
    /// 统一安全化并加一段稳定哈希，避免不同路径 sanitize 后碰撞。
    private func fileKey(_ specID: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in specID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 16777619
        }
        return "\(DownloadPaths.sanitize(specID))-\(String(hash, radix: 16))"
    }

    func stateURL(for specID: String) -> URL {
        directory.appendingPathComponent("state-\(fileKey(specID)).json")
    }

    func partURL(for spec: DownloadSpec, segment: DownloadSegment) -> URL {
        directory.appendingPathComponent("\(fileKey(spec.id))-\(segment.partName)")
    }

    func load(_ specID: String) -> DownloadState? {
        guard let data = try? Data(contentsOf: stateURL(for: specID)) else { return nil }
        return try? JSONCodec.decoder.decode(DownloadState.self, from: data)
    }

    func save(_ state: DownloadState) {
        guard let data = try? JSONCodec.encoder.encode(state) else { return }
        try? data.write(to: stateURL(for: state.spec.id), options: .atomic)
    }

    func clearParts(for specID: String) {
        let prefix = "\(fileKey(specID))-seg-"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for item in items where item.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(item))
        }
    }

    func clear(_ specID: String) {
        try? FileManager.default.removeItem(at: stateURL(for: specID))
        clearParts(for: specID)
    }
}

enum JSONCodec {
    /// 下载队列会并发调用，JSONEncoder/Decoder 不是线程安全的；每次新建实例。
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
