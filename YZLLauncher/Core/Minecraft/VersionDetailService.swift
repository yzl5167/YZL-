import Foundation

struct VersionDetailService {
    func fetch(detailURL: URL) async throws -> VersionDetail {
        var request = URLRequest(url: detailURL)
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
            return try JSONDecoder().decode(VersionDetail.self, from: data)
        } catch {
            throw VersionServiceError.decodingFailed
        }
    }
}
