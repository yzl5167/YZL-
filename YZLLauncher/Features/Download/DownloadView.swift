import SwiftUI

/// 下载页（对齐 Android 端 DownloadScreen）：Mojang 清单浏览 + 筛选 + 安装弹层。
/// 与版本页分离——这里只管「从清单选一个版本装上」，已装版本的管理在版本页。
struct DownloadView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = VersionListViewModel()
    @State private var searchText = ""
    @State private var sheetVersion: MinecraftVersion?

    private var searched: [MinecraftVersion] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return viewModel.filtered }
        let needle = trimmed.lowercased()
        return viewModel.filtered.filter { version in
            version.id.lowercased().contains(needle)
                || version.typeLabel.lowercased().contains(needle)
        }
    }

    var body: some View {
        ZStack {
            PageBackground()
            VStack(spacing: 0) {
                pageHeader
                filterBar
                content
            }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .refreshable {
            await viewModel.reload()
        }
        .sheet(item: $sheetVersion) { version in
            DownloadSheet(version: version, queue: appState.installQueue)
                .environmentObject(appState)
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("下载游戏")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                Text("选择版本后，可安装原版或 Fabric")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }
            Spacer()
            Button {
                Task { await viewModel.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(YZLTheme.muted)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white))
                    .overlay(Circle().stroke(YZLTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(VersionFilter.allCases) { filter in
                    filterPill(filter)
                }
                Spacer()
                if let latest = viewModel.latestReleaseID {
                    Text("最新 \(latest)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(YZLTheme.lightMuted)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(YZLTheme.muted)
                TextField("搜索版本号，例如 1.21.4", text: $searchText)
                    .font(.system(size: 12))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(YZLTheme.lightMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(YZLTheme.field))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(YZLTheme.border, lineWidth: 1))
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private func filterPill(_ filter: VersionFilter) -> some View {
        let selected = viewModel.filter == filter
        return Button {
            viewModel.filter = filter
        } label: {
            Text(filter.title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? YZLTheme.accentText : YZLTheme.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? YZLTheme.accentSoft : Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(selected ? YZLTheme.accent.opacity(0.4) : YZLTheme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.versions.isEmpty {
            loadingView
        } else if let error = viewModel.errorMessage, viewModel.versions.isEmpty {
            errorView(message: error)
        } else if searched.isEmpty {
            emptyView
        } else {
            versionGrid
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text("正在获取版本列表…")
                .font(.system(size: 12))
                .foregroundStyle(YZLTheme.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(YZLTheme.lightMuted)
            Text("获取版本清单失败")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(YZLTheme.text)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(YZLTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("重试") {
                Task { await viewModel.reload() }
            }
            .buttonStyle(PrimaryButtonStyle(prominent: false))
            .padding(.horizontal, 40)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(searchText.isEmpty ? "没有可显示的版本" : "没有匹配的版本")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(YZLTheme.text)
            Text(searchText.isEmpty ? "换个筛选条件试试" : "换一个版本号关键词，或切换到「全部」")
                .font(.system(size: 11))
                .foregroundStyle(YZLTheme.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// 横屏两列网格（对照 Android 端 DownloadScreen 的横屏布局）。
    private var versionGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(searched) { version in
                    Button {
                        sheetVersion = version
                    } label: {
                        DownloadVersionCard(
                            version: version,
                            isInstalled: appState.isInstalled(version.id)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 22)
        }
    }
}

// MARK: - 版本卡片

private struct DownloadVersionCard: View {
    let version: MinecraftVersion
    let isInstalled: Bool

    var body: some View {
        HStack(spacing: 11) {
            YZLTheme.icon(version.type == "release" ? "GrassBlock" : "CommandBlock")
                .resizable()
                .interpolation(.none)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(version.id)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(YZLTheme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if isInstalled {
                        StatusBadge(text: "已安装", tone: .success)
                    }
                }
                Text("\(version.typeLabel) · \(version.releaseDateText)")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            Image(systemName: "chevron.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(YZLTheme.lightMuted)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(YZLTheme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - 安装弹层（对照 Android DownloadSheet）

private struct DownloadSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var queue: DownloadQueue

    let version: MinecraftVersion
    @StateObject private var model: VersionDetailViewModel

    @State private var loaderIsFabric = false
    @State private var loaderEntries: [LoaderEntry] = []
    @State private var loaderVersionID: String?
    @State private var loadersState: LoadersState = .idle
    @State private var isPreparing = false
    @State private var prepareError: String?

    private enum LoadersState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    init(version: MinecraftVersion, queue: DownloadQueue) {
        self.version = version
        _queue = ObservedObject(wrappedValue: queue)
        _model = StateObject(wrappedValue: VersionDetailViewModel(version: version))
    }

    private var queueBusy: Bool { queue.state.phase == .running }
    private var installed: Bool { appState.isInstalled(version.id) }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    loaderSection
                    installNotes
                    installButton
                    if let prepareError {
                        Text(prepareError)
                            .font(.system(size: 11))
                            .foregroundStyle(YZLTheme.danger)
                            .lineSpacing(3)
                    }
                    Text("安装进度会在全局弹窗中显示，切到其他页面不会中断。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(YZLTheme.lightMuted)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(PageBackground())
            .navigationTitle("安装版本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task(id: version.id) {
            await model.load()
        }
        .onChange(of: loaderIsFabric) { isFabric in
            if isFabric { Task { await loadLoaders() } }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            YZLTheme.icon(version.type == "release" ? "GrassBlock" : "CommandBlock")
                .resizable()
                .interpolation(.none)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(version.id)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                Text("\(version.typeLabel) · \(version.releaseDateText)")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }
            Spacer()
            if installed {
                StatusBadge(text: "已安装", tone: .success)
            }
        }
        .padding(.top, 12)
    }

    private var loaderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("加载器")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(YZLTheme.text)

            Picker("加载器", selection: $loaderIsFabric) {
                Text("原版").tag(false)
                Text("Fabric").tag(true)
            }
            .pickerStyle(.segmented)

            Text("Forge / NeoForge 暂不支持：它们的安装器需要运行 Java 字节码，iOS 端要等启动内核接入后才能安装。")
                .font(.system(size: 10))
                .foregroundStyle(YZLTheme.muted)
                .lineSpacing(3)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(YZLTheme.field))

            if loaderIsFabric {
                fabricLoaderPicker
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var fabricLoaderPicker: some View {
        switch loadersState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("正在获取 Fabric 加载器版本…")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.danger)
                Button("重试") {
                    Task { await loadLoaders() }
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
        case .loaded:
            if loaderEntries.isEmpty {
                Text("没有找到适配 \(version.id) 的 Fabric 版本")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            } else {
                Picker("Fabric 加载器版本", selection: $loaderVersionID) {
                    ForEach(loaderEntries) { entry in
                        Text(entry.isStable ? "\(entry.version)（稳定）" : entry.version)
                            .tag(entry.version as String?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var installNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(installed ? "已安装：将补全缺失文件" : "将安装完整游戏文件")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(YZLTheme.text)
            Text("包含客户端、依赖库、资源文件与日志配置\(loaderIsFabric ? "，以及 Fabric 库文件" : "")。已有文件按大小跳过，不会重复下载。现代版本通常需要 300–600 MB 存储空间，实际以版本清单为准。")
                .font(.system(size: 10))
                .foregroundStyle(YZLTheme.muted)
                .lineSpacing(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(YZLTheme.field))
    }

    private var installButton: some View {
        Button {
            startInstall()
        } label: {
            HStack(spacing: 8) {
                if isPreparing {
                    ProgressView().tint(.white)
                }
                Text(buttonTitle)
            }
        }
        .buttonStyle(PrimaryButtonStyle(prominent: true))
        .frame(maxWidth: .infinity)
        .disabled(installDisabled)
    }

    private var buttonTitle: String {
        if queueBusy { return "已有安装任务正在进行" }
        if isPreparing { return "正在统计安装清单…" }
        return installed ? "补全缺失文件" : "下载并安装"
    }

    private var installDisabled: Bool {
        queueBusy || isPreparing || (loaderIsFabric && (loaderVersionID == nil || loaderVersionID!.isEmpty))
    }

    private func loadLoaders() async {
        loadersState = .loading
        do {
            let entries = try await LoaderService().fetchLoaders(kind: .fabric, gameVersion: version.id)
            loaderEntries = entries
            loaderVersionID = entries.first { $0.isStable }?.version ?? entries.first?.version
            loadersState = .loaded
        } catch {
            loadersState = .failed(error.localizedDescription)
        }
    }

    private func startInstall() {
        guard !isPreparing, !queueBusy else { return }
        isPreparing = true
        prepareError = nil

        Task { @MainActor in
            do {
                let detail: VersionDetail
                var versionRef = version
                if loaderIsFabric {
                    guard let chosen = loaderVersionID, !chosen.isEmpty else {
                        throw InstallPreparationError(message: "先选择一个 Fabric 加载器版本。")
                    }
                    let profileURL = LoaderKind.fabric.profileURL(gameVersion: version.id, loaderVersion: chosen)
                    detail = try await VersionDetailService().fetch(detailURL: profileURL)
                    versionRef = MinecraftVersion(
                        id: detail.id,
                        type: "release",
                        url: profileURL,
                        time: detail.time ?? "",
                        releaseTime: detail.releaseTime ?? ""
                    )
                } else {
                    // 原版：详情已在 sheet 打开时 load 过；兜底再 load 一次（幂等）。
                    if model.detail == nil {
                        await model.load()
                    }
                    guard let loaded = model.detail else {
                        throw InstallPreparationError(message: model.errorMessage ?? "版本详情获取失败。")
                    }
                    detail = loaded
                }

                // 继承链拍平 + 资源对象展开（与版本详情页同一套状态机）。
                let installModel = VersionDetailViewModel(version: versionRef, preloadedDetail: detail)
                guard let specs = await installModel.prepareInstall() else {
                    throw InstallPreparationError(message: installModel.errorMessage ?? "安装清单生成失败。")
                }

                let fileCount = specs.count
                let totalBytes = specs.reduce(Int64(0)) { $0 + ($1.expectedSize ?? 0) }
                let appState = self.appState
                queue.start(specs, batchID: detail.id) {
                    appState.recordInstall(
                        detail: detail,
                        version: versionRef,
                        fileCount: fileCount,
                        totalBytes: totalBytes
                    )
                }
                dismiss()
            } catch {
                prepareError = error.localizedDescription
            }
            isPreparing = false
        }
    }
}
