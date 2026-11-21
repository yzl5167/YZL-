import SwiftUI

/// 资源市场状态机：搜索、异步中文翻译、版本详情与安装。
@MainActor
final class ResourceMarketViewModel: ObservableObject {
    @Published var category: ResourceCategory = .mod
    @Published var searchText = ""
    @Published var gameVersion = ""
    @Published var loader = "fabric"
    @Published private(set) var results: [ModrinthProject] = []
    @Published private(set) var translations: [String: (title: String?, description: String?)] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var searchTask: Task<Void, Never>?
    private var requestID = 0

    /// 游戏版本下拉候选：常见大版本，够用即可（资源市场筛选不必列全 900 个）。
    static let gameVersionOptions = [
        "", "1.21.4", "1.21.1", "1.20.4", "1.20.1", "1.19.4", "1.19.2",
        "1.18.2", "1.17.1", "1.16.5", "1.12.2"
    ]
    static let loaderOptions = ["fabric", "forge", "neoforge", "quilt"]

    func search() async {
        searchTask?.cancel()
        let myID = requestID + 1
        requestID = myID
        isLoading = true
        errorMessage = nil
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let cat = category
        let gv = gameVersion.isEmpty ? nil : gameVersion
        let ld = (cat == .mod || cat == .modpack) ? loader : nil

        let fetched: ModrinthSearchResponse
        do {
            fetched = try await ModrinthService.search(
                query: query, category: cat, gameVersion: gv, loader: ld
            )
        } catch {
            if error is CancellationError { return }
            errorMessage = error.localizedDescription
            results = []
            isLoading = false
            return
        }
        guard myID == requestID else { return }
        results = fetched.hits
        isLoading = false
        await translateVisible()
    }

    /// 只对当前页结果做中文翻译，best-effort，失败不留痕。
    private func translateVisible() async {
        let snapshot = results
        for project in snapshot {
            let id = project.id
            let query = project.title
            let translated = await ResourceTranslation.translate(query: query)
            guard !Task.isCancelled else { return }
            if translated.title != nil || translated.description != nil {
                translations[id] = translated
            }
        }
    }

    func translatedTitle(for project: ModrinthProject) -> String {
        translations[project.id]?.title ?? project.title
    }

    func translatedDescription(for project: ModrinthProject) -> String {
        translations[project.id]?.description ?? project.description
    }

    /// 切换类别时清空旧结果，避免光影页残留模组数据。
    func selectCategory(_ new: ResourceCategory) {
        guard new != category else { return }
        category = new
        results = []
        errorMessage = nil
    }
}
