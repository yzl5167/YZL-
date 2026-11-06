import Foundation

struct VersionDetailService {
    func fetch(detailURL: URL) async throws -> VersionDetail {
        // 版本详情可能来自 Mojang（piston-meta）或加载器 Meta（fabric/quilt），
        // 两者都在镜像映射表里，由 MetadataFetcher 统一改写 + 双源回退重试。
        let data = try await MetadataFetcher.data(for: detailURL)

        do {
            return try JSONDecoder().decode(VersionDetail.self, from: data)
        } catch {
            throw VersionServiceError.decodingFailed
        }
    }
}
