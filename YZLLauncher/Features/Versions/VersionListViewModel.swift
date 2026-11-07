import Foundation
import Combine

/// 下载页的版本清单筛选（对齐 Android 端三个筛选 Pill：正式版 / 快照 / 全部）。
enum VersionFilter: String, CaseIterable, Identifiable {
    case release
    case snapshot
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .release: return "正式版"
        case .snapshot: return "快照"
        case .all: return "全部"
        }
    }

    func matches(_ version: MinecraftVersion) -> Bool {
        switch self {
        case .release: return version.type == "release"
        case .snapshot: return version.type == "snapshot"
        case .all: return true
        }
    }
}

@MainActor
final class VersionListViewModel: ObservableObject {
    @Published var versions: [MinecraftVersion] = []
    @Published var isLoading = false
    /// 下载页的三段筛选（正式版 / 快照 / 全部），默认正式版。
    @Published var filter: VersionFilter = .release
    @Published var errorMessage: String?
    /// 清单来自本地缓存时为 true，下载页据此提示「可点右上角刷新最新」。
    @Published var fromCache = false
    @Published var latestReleaseID: String?

    private let service = VersionManifestService()

    var filtered: [MinecraftVersion] {
        versions.filter { filter.matches($0) }
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
            latestReleaseID = manifest.latest.release
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
