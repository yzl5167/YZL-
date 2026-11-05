import Foundation

struct AssetIndexDocument: Decodable {
    struct AssetObject: Decodable {
        let hash: String
        let size: Int64
    }

    let objects: [String: AssetObject]
}

struct AssetIndexService {
    func fetch(indexURL: URL) async throws -> AssetIndexDocument {
        var request = URLRequest(url: indexURL)
        request.timeoutInterval = 30
        request.setValue("YZLLauncher/0.1 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VersionServiceError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw VersionServiceError.badStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(AssetIndexDocument.self, from: data)
        } catch {
            throw VersionServiceError.decodingFailed
        }
    }
}
