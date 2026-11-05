import Foundation

struct VersionManifestService {
    private let manifestURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!

    func fetchManifest() async throws -> VersionManifest {
        var request = URLRequest(url: manifestURL)
        request.timeoutInterval = 20
        request.setValue("YZLLauncher/0.1 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw VersionServiceError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw VersionServiceError.badStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(VersionManifest.self, from: data)
        } catch {
            throw VersionServiceError.decodingFailed
        }
    }
}

enum VersionServiceError: LocalizedError {
    case invalidResponse
    case badStatus(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无法识别的响应"
        case .badStatus(let code):
            return "服务器返回 HTTP \(code)"
        case .decodingFailed:
            return "版本清单格式解析失败"
        }
    }
}
