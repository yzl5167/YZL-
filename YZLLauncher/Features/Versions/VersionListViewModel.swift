import Foundation
import Combine

@MainActor
final class VersionListViewModel: ObservableObject {
    @Published var versions: [MinecraftVersion] = []
    @Published var isLoading = false
    @Published var showSnapshots = false
    @Published var errorMessage: String?

    private let service = VersionManifestService()

    var filtered: [MinecraftVersion] {
        showSnapshots ? versions : versions.filter { $0.type == "release" }
    }

    func loadIfNeeded() async {
        guard versions.isEmpty, !isLoading else { return }
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let manifest = try await service.fetchManifest()
            versions = manifest.versions
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "当前没有网络连接"
            case .timedOut:
                return "请求超时，请检查网络后重试"
            default:
                return "网络错误：\(urlError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}
