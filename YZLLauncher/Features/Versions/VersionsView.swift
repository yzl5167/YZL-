import SwiftUI

struct VersionsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = VersionListViewModel()
    @State private var selectedVersion: MinecraftVersion?
    @State private var searchText = ""

    var body: some View {
        ZStack {
            PageBackground()
            VStack(spacing: 0) {
                pageHeader
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        filterBar
                        content
                    }
                    .frame(width: 360)

                    Rectangle()
                        .fill(YZLTheme.border)
                        .frame(width: 1)

                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .task {
            await viewModel.loadIfNeeded()
            if let pending = appState.pendingInstallVersionID,
               let match = viewModel.versions.first(where: { $0.id == pending }) {
                selectedVersion = match
            } else if selectedVersion == nil {
                selectedVersion = appState.selectedVersion ?? viewModel.filtered.first
            }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("版本管理")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                Text("Mojang 版本清单 · 已安装的版本会走启动自检")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }
            Spacer()
            Button {
                Task { await viewModel.reload() }
            } label: {
                Text("刷新")
            }
            .buttonStyle(PrimaryButtonStyle(prominent: false))
            .frame(width: 74)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(viewModel.versions.isEmpty ? "Mojang 版本清单" : "共 \(searched.count) 个版本")
                    .font(.system(size: 12))
                    .foregroundStyle(YZLTheme.muted)

                Spacer()

                Picker("版本类型", selection: $viewModel.showSnapshots) {
                    Text("正式版").tag(false)
                    Text("全部").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(YZLTheme.muted)

                TextField("搜索版本号，例如 1.21.10", text: $searchText)
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
                    .accessibilityLabel("清空搜索")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(YZLTheme.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(YZLTheme.border, lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var searched: [MinecraftVersion] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return viewModel.filtered }
        let needle = trimmed.lowercased()
        return viewModel.filtered.filter { version in
            version.id.lowercased().contains(needle)
                || version.typeLabel.lowercased().contains(needle)
                || version.releaseDateText.lowercased().contains(needle)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.versions.isEmpty {
            loadingView
        } else if let error = viewModel.errorMessage, viewModel.versions.isEmpty {
            errorView(message: error)
        } else if searched.isEmpty {
            emptySearchView
        } else {
            versionList
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let version = selectedVersion {
            VersionDetailPane(
                version: version,
                downloads: appState.downloads,
                installQueue: appState.installQueue,
                pendingInstallID: $appState.pendingInstallVersionID
            )
            .id(version.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(YZLTheme.lightMuted)
                Text("选择一个版本查看详情")
                    .font(.system(size: 13))
                    .foregroundStyle(YZLTheme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text("正在从 Mojang 获取版本清单…")
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

    private var emptySearchView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(YZLTheme.lightMuted)
            Text("没有匹配的版本")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(YZLTheme.text)
            Text(searchText.isEmpty ? "换个筛选条件试试" : "换个版本号或类型关键词搜索")
                .font(.system(size: 10.5))
                .foregroundStyle(YZLTheme.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var versionList: some View {
        List {
            ForEach(searched) { version in
                Button {
                    selectedVersion = version
                    if appState.pendingInstallVersionID != version.id {
                        appState.pendingInstallVersionID = nil
                    }
                } label: {
                    VersionRow(
                        version: version,
                        isCurrent: appState.selectedVersion?.id == version.id,
                        isInstalled: appState.isInstalled(version.id),
                        isSelected: selectedVersion?.id == version.id
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    selectedVersion?.id == version.id ? YZLTheme.accentSoft : Color.white
                )
                .listRowSeparatorTint(YZLTheme.border)
            }
        }
        .listStyle(.insetGrouped)
        .yzlClearListBackground()
        .refreshable {
            await viewModel.reload()
        }
    }
}

private struct VersionRow: View {
    let version: MinecraftVersion
    let isCurrent: Bool
    let isInstalled: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(version.type == "release" ? "GrassBlock" : "CommandBlock")
                .resizable()
                .interpolation(.none)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(version.id)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? YZLTheme.accentText : YZLTheme.text)
                    if isCurrent {
                        StatusBadge(text: "当前", tone: isInstalled ? .success : .warning)
                    } else if isInstalled {
                        StatusBadge(text: "已安装", tone: .success)
                    }
                }
                Text(version.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? YZLTheme.accent : YZLTheme.lightMuted)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct VersionDetailPane: View {
    let version: MinecraftVersion
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var downloads: DownloadManager
    @ObservedObject private var installQueue: DownloadQueue
    @Binding var pendingInstallID: String?
    @StateObject private var model: VersionDetailViewModel

    init(version: MinecraftVersion,
         downloads: DownloadManager,
         installQueue: DownloadQueue,
         pendingInstallID: Binding<String?>) {
        self.version = version
        self.downloads = downloads
        self.installQueue = installQueue
        _pendingInstallID = pendingInstallID
        _model = StateObject(wrappedValue: VersionDetailViewModel(version: version))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                InstallCardView(model: model, queue: installQueue) { detail, fileCount, bytes in
                    appState.recordInstall(
                        detail: detail,
                        version: version,
                        fileCount: fileCount,
                        totalBytes: bytes
                    )
                }
                downloadCard
                infoCard
                noteCard
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .task {
            await model.load()
            autoInstallIfRequested()
        }
        .onChange(of: pendingInstallID) { _ in
            autoInstallIfRequested()
        }
    }

    /// 主页「下载游戏」只设置一次意图；进入对应版本详情后自动开始安装。
    private func autoInstallIfRequested() {
        guard pendingInstallID == version.id,
              model.detail != nil,
              !appState.isInstalled(version.id),
              !model.isPreparingInstall,
              installQueue.state.phase != .running else { return }
        pendingInstallID = nil
        model.startInstall(using: installQueue) { detail, fileCount, bytes in
            appState.recordInstall(
                detail: detail,
                version: version,
                fileCount: fileCount,
                totalBytes: bytes
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(version.type == "release" ? "GrassBlock" : "CommandBlock")
                .resizable()
                .interpolation(.none)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(version.id)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                Text(version.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }

            Spacer()

            if appState.isInstalled(version.id) {
                Button {
                    appState.requestLaunch(version: version)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("启动")
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(YZLTheme.accent))
                .buttonStyle(.plain)
            }

            if appState.selectedVersion?.id == version.id {
                StatusBadge(
                    text: appState.isInstalled(version.id) ? "当前版本" : "当前 · 未安装",
                    tone: appState.isInstalled(version.id) ? .success : .warning
                )
            } else if appState.isInstalled(version.id) {
                Button("设为当前") {
                    appState.selectedVersion = version
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(YZLTheme.accentText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(YZLTheme.accentSoft))
                .buttonStyle(.plain)
            } else {
                StatusBadge(text: "未安装", tone: .neutral)
            }
        }
    }

    private var infoCard: some View {
        YZLCard(padding: 12) {
            VStack(spacing: 8) {
                infoRow("版本类型", version.typeLabel)
                Divider()
                infoRow("发布日期", version.releaseDateText)
                Divider()
                infoRow("资源来源", "Mojang 官方")
            }
        }
    }

    @ViewBuilder
    private var downloadCard: some View {
        if let detail = model.detail {
            YZLCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("客户端 jar（单独下载）")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(YZLTheme.text)

                    Text("只下载 jar，不会写入安装记录；完整安装请用上方的「开始安装」。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.muted)
                        .lineSpacing(2)

                    infoRow("大小", formatBytes(detail.clientArtifact.size))
                    infoRow("Java", detail.javaRequirement)
                    infoRow("SHA-1", detail.clientArtifact.sha1)

                    Divider()

                    if let job = downloads.job(for: model.specID) {
                        jobView(job)
                    } else {
                        Button("仅下载 jar") {
                            model.startDownload(using: downloads)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(installQueue.state.phase == .running && installQueue.state.batchID == version.id)
                    }
                }
            }
        } else if model.isLoading {
            YZLCard(padding: 14) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在获取版本详情…")
                        .font(.system(size: 12))
                        .foregroundStyle(YZLTheme.muted)
                }
            }
        } else if let error = model.errorMessage {
            YZLCard(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("获取版本详情失败")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(YZLTheme.text)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.muted)
                    Button("重试") {
                        Task { await model.load() }
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                }
            }
        }
    }

    @ViewBuilder
    private func jobView(_ job: DownloadJob) -> some View {
        switch job.phase {
        case .queued, .probing:
            HStack(spacing: 8) {
                ProgressView()
                Text("正在探测 Range 支持…")
                    .font(.system(size: 12))
                    .foregroundStyle(YZLTheme.muted)
            }
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: job.progress)
                    .tint(YZLTheme.accent)
                Text(progressText(job))
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
                Button("取消下载") {
                    downloads.cancel(job.id)
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView()
                Text("正在校验 SHA-1…")
                    .font(.system(size: 12))
                    .foregroundStyle(YZLTheme.muted)
            }
        case .finished(let url):
            VStack(alignment: .leading, spacing: 6) {
                Label("已下载并通过 SHA-1 校验", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YZLTheme.success)
                Text(url.path)
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
                    .lineLimit(2)
                Button("重新下载") {
                    model.startDownload(using: downloads)
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.danger)
                Button("重试") {
                    model.startDownload(using: downloads)
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
        case .cancelled:
            VStack(alignment: .leading, spacing: 6) {
                Text("已取消，分片进度保留在本地")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
                Button("继续下载") {
                    model.startDownload(using: downloads)
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
        }
    }

    private var noteCard: some View {
        YZLCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("这一步能做什么")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                Text("单个文件下载走分片 + 断点续传；整包安装会列出全部文件与真实总字节，全部通过 SHA-1 后才写入安装记录。依赖库中的 Windows/macOS/Linux 原生件按规则排除，iOS 原生库由 M2 的引擎提供。")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)
            }
        }
    }

    private func progressText(_ job: DownloadJob) -> String {
        let done = formatBytes(job.downloaded)
        let speed = formatBytes(Int64(job.speedBytesPerSecond))
        if job.total <= 0 {
            return "\(done) · \(speed)/s"
        }
        let total = formatBytes(job.total)
        if job.segmented {
            return "\(done) / \(total) · \(speed)/s · 并发 \(job.activeSegments)"
        }
        return "\(done) / \(total) · \(speed)/s · 单连接（服务器不支持 Range）"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(YZLTheme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(YZLTheme.text)
                .lineLimit(1)
        }
    }
}
