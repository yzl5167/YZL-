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

    func stateURL(for specID: String) -> URL {
        directory.appendingPathComponent("state-\(specID).json")
    }

    func partURL(for spec: DownloadSpec, segment: DownloadSegment) -> URL {
        directory.appendingPathComponent("\(spec.id)-\(segment.partName)")
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
        let prefix = "\(specID)-seg-"
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
