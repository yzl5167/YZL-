import Foundation
import Combine

/// 安装准备阶段的本地错误（版本 JSON 落盘失败等），文案直接面向用户。
struct InstallPreparationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class VersionDetailViewModel: ObservableObject {
    @Published var detail: VersionDetail?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isPreparingInstall = false
    @Published var installSummary: String?
    /// 安装继承类版本（Fabric / Forge）时展示解析到的父版本链，便于用户理解装了什么。
    @Published var inheritanceNote: String?

    private let version: MinecraftVersion
    private let service = VersionDetailService()
    private let assetIndexService = AssetIndexService()
    private let manifestService = VersionManifestService()

    /// - Parameters:
    ///   - version: 版本清单条目（或由加载器 profile 合成的版本）。
    ///   - preloadedDetail: 已经拿到的版本 JSON（如 Fabric profile），非 nil 时 `load()` 直接用它。
    init(version: MinecraftVersion, preloadedDetail: VersionDetail? = nil) {
        self.version = version
        self.detail = preloadedDetail
    }

    var versionID: String { version.id }
    var minecraftVersion: MinecraftVersion { version }

    var specID: String {
        "client-\(DownloadPaths.sanitize(version.id))"
    }

    /// 安装是否依赖继承链（子版本只描述差异，客户端 jar / 资源来自父版本）。
    var isInheritedVersion: Bool {
        detail?.inheritsFrom != nil
    }

    /// 已拍平（可直接安装/启动）的版本：无继承，或继承链已解析完成。
    private var resolvedDetail: VersionDetail?

    func load() async {
        guard detail == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // 本地已装过的版本直接读落盘的版本 JSON（含拍平后的加载器 profile），
        // 断网也能看到详情与安装状态；读不到再联网。
        let layout = InstallLayout.forVersion(version.id)
        if let data = try? Data(contentsOf: layout.versionJSON),
           let local = try? JSONDecoder().decode(VersionDetail.self, from: data) {
            detail = local
            resolvedDetail = local.inheritsFrom == nil ? local : nil
            return
        }

        do {
            detail = try await service.fetch(detailURL: version.url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func makeSpec() -> DownloadSpec? {
        guard let detail, detail.clientArtifact != nil else { return nil }
        let layout = InstallLayout.forVersion(detail.id)
        let plan = InstallPlanner.plan(detail: detail, layout: layout)
        return plan.files.first(where: { $0.kind == .clientJar })?.spec
    }

    func startDownload(using manager: DownloadManager) {
        guard let spec = makeSpec() else { return }
        manager.start(spec)
    }

    /// 生成完整安装清单：客户端 jar + iOS 适用依赖库 + 资源索引，
    /// 再按资源索引展开去重后的资源对象。
    /// 继承类版本（Fabric / Forge）会先取回整条父版本链并拍平，客户端 jar、
    /// 资源索引与 Java 要求都从父版本带下来。
    func prepareInstall() async -> [DownloadSpec]? {
        guard var workingDetail = detail else { return nil }
        isPreparingInstall = true
        defer { isPreparingInstall = false }
        inheritanceNote = nil

        do {
            if workingDetail.inheritsFrom != nil {
                workingDetail = try await resolveInheritance(workingDetail)
            } else {
                guard persistDetail(workingDetail) else { return nil }
            }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        resolvedDetail = workingDetail
        let layout = InstallLayout.forVersion(workingDetail.id)
        let base = InstallPlanner.plan(detail: workingDetail, layout: layout)
        var specs = base.specs
        var objectCount = 0
        var objectBytes: Int64 = 0

        if let index = workingDetail.assetIndex {
            do {
                let document = try await assetIndexService.fetch(indexURL: index.url)
                let objects = InstallPlanner.assetObjectPlan(
                    document: document,
                    layout: layout,
                    versionID: workingDetail.id
                )
                specs.append(contentsOf: objects.specs)
                objectCount = objects.files.count
                objectBytes = objects.totalBytes
            } catch {
                errorMessage = "资源索引获取失败：\(error.localizedDescription)"
                return nil
            }
        }

        installSummary = """
        \(specs.count) 个文件 · \(InstallFormats.bytes(base.totalBytes + objectBytes))
        依赖库 \(base.count(of: .library)) 个 · 资源对象 \(objectCount) 个
        """
        return specs
    }

    /// 解析继承链：本地已装父版本直接复用，否则从 Mojang 清单取回并逐层落盘，
    /// 最后把拍平结果存成本版本的 JSON。安装与启动都不再需要网络。
    private func resolveInheritance(_ child: VersionDetail) async throws -> VersionDetail {
        let chain = try await VersionInheritanceResolver.chain(root: child) { parentID in
            let parentLayout = InstallLayout.forVersion(parentID)
            if let data = try? Data(contentsOf: parentLayout.versionJSON),
               let local = try? JSONDecoder().decode(VersionDetail.self, from: data) {
                return local
            }
            guard let url = try await self.manifestService.detailURL(for: parentID) else {
                return nil
            }
            return try await self.service.fetch(detailURL: url)
        }

        // 祖先层（链里除子版本外的每一层）落盘到各自版本目录；
        // 来自本地的天然已存在，重复写也无害，这里统一覆盖保证一致。
        for ancestor in chain.dropLast() {
            try? FileManager.default.createDirectory(at: InstallLayout.forVersion(ancestor.id).root, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(ancestor) {
                try? data.write(to: InstallLayout.forVersion(ancestor.id).versionJSON, options: .atomic)
            }
        }

        let byID = Dictionary(uniqueKeysWithValues: chain.map { ($0.id, $0) })
        let flattened = VersionMerger.merge(root: child) { byID[$0] }
        guard persistDetail(flattened) else {
            throw InstallPreparationError(message: errorMessage ?? "版本元数据写入失败，无法继续安装。")
        }

        let parentNames = chain.dropLast().map(\.id).joined(separator: " ← ")
        inheritanceNote = "继承自 \(parentNames)，已合并父版本文件清单。"
        return flattened
    }

    func startInstall(using queue: DownloadQueue, onFinished: ((VersionDetail, Int, Int64) -> Void)? = nil) {
        Task {
            guard let specs = await self.prepareInstall(), let detail = self.resolvedDetail ?? self.detail else { return }
            let fileCount = specs.count
            let totalBytes = specs.reduce(Int64(0)) { $0 + ($1.expectedSize ?? 0) }
            queue.start(specs, batchID: self.version.id) {
                onFinished?(detail, fileCount, totalBytes)
            }
        }
    }

    /// 把版本 JSON 落到版本目录。启动阶段不依赖网络，直接从这里读主类、依赖库和资源索引名。
    /// 拍平后的加载器 profile 也存这里，`inheritsFrom` 已被清空。
    @discardableResult
    func persistDetail(_ detail: VersionDetail? = nil) -> Bool {
        guard let detail = detail ?? self.detail else { return false }
        let layout = InstallLayout.forVersion(detail.id)
        do {
            try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(detail)
            try data.write(to: layout.versionJSON, options: .atomic)
            return true
        } catch {
            errorMessage = "版本元数据写入失败：\(error.localizedDescription)"
            return false
        }
    }
}
