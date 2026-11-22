import SwiftUI

/// 资源市场状态机：搜索、异步中文翻译、分页、版本详情。
@MainActor
final class ResourceMarketViewModel: ObservableObject {
    @Published var category: ResourceCategory = .mod
    @Published var searchText = ""
    @Published var gameVersion = ""
    @Published var loader = "fabric"
    @Published var categoryTag = ""
    @Published var sort = "downloads"
    @Published private(set) var results: [ModrinthProject] = []
    @Published private(set) var translations: [String: (title: String?, description: String?)] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var totalHits = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var versionOptions: [String] = []

    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var requestID = 0

    static let loaderOptions = ["fabric", "forge", "neoforge", "quilt"]
    static let sortOptions: [(value: String, title: String)] = [
        ("downloads", "下载量"), ("follow_count", "关注数"),
        ("newest", "最新发布"), ("updated", "最近更新")
    ]
    static let fallbackGameVersions = [
        "1.21.4", "1.21.1", "1.20.4", "1.20.1", "1.19.4", "1.19.2",
        "1.18.2", "1.17.1", "1.16.5", "1.12.2"
    ]

    /// 由 View 注入已安装版本 id，生成动态游戏版本筛选（对齐 Windows 从实例派生）。
    func setInstalledVersions(_ ids: [String]) {
        var set = Set(ids)
        for v in Self.fallbackGameVersions { set.insert(v) }
        let sorted = set.sorted { lhs, rhs in
            Self.versionRank(lhs) > Self.versionRank(rhs)
        }
        versionOptions = sorted
    }

    /// 粗略版本号排序（1.21.4 > 1.20.1 > 1.12.2），够 UI 用。
    private static func versionRank(_ id: String) -> Double {
        let parts = id.split(separator: ".").compactMap { Double($0) }
        var rank = 0.0
        for (i, p) in parts.enumerated() {
            rank += p / pow(100, Double(i))
        }
        return rank
    }

    /// 防抖搜索：文本变化 250ms 后自动搜，避免每敲一个字就发请求。
    func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.search()
        }
    }

    /// 立即搜索：真正持有并取消旧任务，requestID 守卫防过期结果覆盖。
    func search() async {
        debounceTask?.cancel()
        searchTask?.cancel()
        let myID = requestID + 1
        requestID = myID
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        searchTask = Task { [weak self] in
            await self?.performSearch(myID, offset: 0, append: false)
        }
        // 等这次任务结束再返回，调用方 .task 里能正确结束 loading。
        await searchTask?.value
    }

    /// 加载更多：复用同一 requestID，offset = 当前条数，结果追加。
    func loadMore() async {
        guard !isLoading, !isLoadingMore, results.count < totalHits else { return }
        let myID = requestID
        isLoadingMore = true
        await performSearch(myID, offset: results.count, append: true)
    }

    private func performSearch(_ myID: Int, offset: Int, append: Bool) async {
        let rawQuery = searchText.trimmingCharacters(in: .whitespaces)
        let cat = category
        let gv = gameVersion.isEmpty ? nil : gameVersion
        let ld = (cat == .mod || cat == .modpack) ? loader : nil
        let tag = categoryTag.isEmpty ? nil : categoryTag

        // 中文查询先翻成英文再搜（Windows 同款，命中率关键）。
        let query = await ModrinthService.englishQuery(for: rawQuery)
        guard myID == requestID, !Task.isCancelled else { return }

        let fetched: ModrinthSearchResponse
        do {
            fetched = try await ModrinthService.search(
                query: query, category: cat, gameVersion: gv, loader: ld,
                categoryTag: tag, sort: sort, limit: 30, offset: offset
            )
        } catch is CancellationError {
            return
        } catch {
            // URLSession 取消抛 URLError(.cancelled)，视为静默取消，不落错误页。
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
            guard myID == requestID else { return }
            errorMessage = error.localizedDescription
            if !append { results = [] }
            isLoading = false
            isLoadingMore = false
            return
        }
        guard myID == requestID, !Task.isCancelled else { return }
        totalHits = fetched.totalHits ?? fetched.hits.count
        if append {
            // 去重追加（offset 分页偶有重复项）。
            let existing = Set(results.map(\.id))
            results.append(contentsOf: fetched.hits.filter { !existing.contains($0.id) })
        } else {
            results = fetched.hits
        }
        errorMessage = nil
        isLoading = false
        isLoadingMore = false
        if !append { await translateVisible(requestID: myID) }
    }

    /// 只翻译当前页，带 requestID 守卫防旧结果覆盖；新页先清空跨类残留。
    private func translateVisible(requestID: Int) async {
        if translations.isEmpty == false { translations = [:] }
        let snapshot = results
        for project in snapshot {
            guard requestID == self.requestID, !Task.isCancelled else { return }
            let translated = await ResourceTranslation.translate(query: project.title)
            guard requestID == self.requestID, !Task.isCancelled else { return }
            if translated.title != nil || translated.description != nil {
                translations[project.id] = translated
            }
        }
    }

    func translatedTitle(for project: ModrinthProject) -> String {
        translations[project.id]?.title ?? project.title
    }

    func translatedDescription(for project: ModrinthProject) -> String {
        translations[project.id]?.description ?? project.description
    }

    /// 切换类别时清空旧结果，避免光影页残留模组数据，并立即重搜。
    func selectCategory(_ new: ResourceCategory) {
        guard new != category else { return }
        category = new
        results = []
        totalHits = 0
        errorMessage = nil
    }
}
