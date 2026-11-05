import Foundation
import Combine

@MainActor
final class VersionDetailViewModel: ObservableObject {
    @Published var detail: VersionDetail?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isPreparingInstall = false
    @Published var installSummary: String?

    private let version: MinecraftVersion
    private let service = VersionDetailService()
    private let assetIndexService = AssetIndexService()

    init(version: MinecraftVersion) {
        self.version = version
    }

    var versionID: String { version.id }
    var minecraftVersion: MinecraftVersion { version }

    var specID: String {
        "client-\(DownloadPaths.sanitize(version.id))"
    }

    func load() async {
        guard detail == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            detail = try await service.fetch(detailURL: version.url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func makeSpec() -> DownloadSpec? {
        guard let detail else { return nil }
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
    func prepareInstall() async -> [DownloadSpec]? {
        guard let detail else { return nil }
        guard persistDetail() else { return nil }
        isPreparingInstall = true
        defer { isPreparingInstall = false }

        let layout = InstallLayout.forVersion(detail.id)
        let base = InstallPlanner.plan(detail: detail, layout: layout)
        var specs = base.specs
        var objectCount = 0
        var objectBytes: Int64 = 0

        if let index = detail.assetIndex {
            do {
                let document = try await assetIndexService.fetch(indexURL: index.url)
                let objects = InstallPlanner.assetObjectPlan(
                    document: document,
                    layout: layout,
                    versionID: detail.id
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

    func startInstall(using queue: DownloadQueue, onFinished: ((VersionDetail, Int, Int64) -> Void)? = nil) {
        Task {
            guard let specs = await self.prepareInstall(), let detail = self.detail else { return }
            let fileCount = specs.count
            let totalBytes = specs.reduce(Int64(0)) { $0 + ($1.expectedSize ?? 0) }
            queue.start(specs, batchID: self.version.id) {
                onFinished?(detail, fileCount, totalBytes)
            }
        }
    }

    /// 把版本 JSON 落到版本目录。启动阶段不依赖网络，直接从这里读主类、依赖库和资源索引名。
    @discardableResult
    func persistDetail() -> Bool {
        guard let detail else { return false }
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
