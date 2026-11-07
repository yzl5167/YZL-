import SwiftUI
import UniformTypeIdentifiers

struct VersionsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedVersion: MinecraftVersion?
    @State private var showModpackPicker = false
    @State private var pickedModpackURL: URL?

    /// 版本页只管本地已安装版本（对齐 Android 端 VersionsScreen）；
    /// 从清单挑新版本去「下载」页。
    private var installedVersions: [MinecraftVersion] {
        appState.installedVersions.map(\.minecraftVersion)
    }

    var body: some View {
        ZStack {
            PageBackground()
            VStack(spacing: 0) {
                pageHeader
                HStack(spacing: 0) {
                    content
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
            if let pending = appState.pendingInstallVersionID,
               let match = installedVersions.first(where: { $0.id == pending }) {
                selectedVersion = match
            } else if selectedVersion == nil || !installedVersions.contains(where: { $0.id == selectedVersion?.id }) {
                selectedVersion = appState.selectedVersion.flatMap { version in
                    installedVersions.first { $0.id == version.id }
                } ?? installedVersions.first
            }
        }
        .sheet(isPresented: $showModpackPicker) {
            ModpackFilePicker { url in
                pickedModpackURL = url
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: Binding(
            get: { pickedModpackURL != nil },
            set: { if !$0 { pickedModpackURL = nil } }
        )) {
            if let pickedModpackURL {
                ModpackImportSheet(
                    queue: appState.installQueue,
                    zipURL: pickedModpackURL,
                    onFinished: { self.pickedModpackURL = nil }
                )
                .environmentObject(appState)
            }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("版本管理")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                Text(installedVersions.isEmpty
                     ? "还没有安装版本"
                     : "共 \(installedVersions.count) 个本地版本 · 选中后才能导出或删除")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }
            Spacer()
            Button {
                showModpackPicker = true
            } label: {
                Text("导入整合包")
            }
            .buttonStyle(PrimaryButtonStyle(prominent: false))
            .frame(width: 106)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if installedVersions.isEmpty {
            emptyState
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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(YZLTheme.lightMuted)
            Text("还没有安装版本")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(YZLTheme.text)
            Text("去下载页选择一个版本，支持原版和 Fabric；也可以导入整合包。")
                .font(.system(size: 11))
                .foregroundStyle(YZLTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("去下载游戏") {
                appState.selectedTab = .download
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var versionList: some View {
        List {
            ForEach(installedVersions) { version in
                Button {
                    selectedVersion = version
                } label: {
                    VersionRow(
                        version: version,
                        isCurrent: appState.selectedVersion?.id == version.id,
                        isInstalled: true,
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
    }
}

private struct VersionRow: View {
    let version: MinecraftVersion
    let isCurrent: Bool
    let isInstalled: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            YZLTheme.icon(version.type == "release" ? "GrassBlock" : "CommandBlock")
                .resizable()
                .interpolation(.none)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(version.id)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? YZLTheme.accentText : YZLTheme.text)
                    if let loader = version.loaderLabel {
                        StatusBadge(text: loader, tone: .neutral)
                    }
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
                if let notice = installQueue.notice {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(YZLTheme.accentText)
                        Text(notice)
                            .font(.system(size: 11.5))
                            .foregroundStyle(YZLTheme.text)
                            .lineSpacing(3)
                        Spacer(minLength: 4)
                        Button("知道了") { installQueue.clearNotice() }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(YZLTheme.accentText)
                            .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(YZLTheme.accentSoft)
                    )
                }
                InstallCardView(model: model, queue: installQueue) { detail, fileCount, bytes in
                    appState.recordInstall(
                        detail: detail,
                        version: version,
                        fileCount: fileCount,
                        totalBytes: bytes
                    )
                }
                if isVanillaVersion {
                    FabricInstallCardView(baseVersion: version, queue: installQueue)
                }
                if appState.isInstalled(version.id) {
                    installedActionsCard
                    modsCard
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
            YZLTheme.icon(version.type == "release" ? "GrassBlock" : "CommandBlock")
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

    /// 只有 Mojang 官方版本（从清单选中的）才显示 Fabric 加载器卡；
    /// 加载器 profile 自身（如 fabric-loader-x.y.z-1.20.1）不再叠加安装卡。
    private var isVanillaVersion: Bool {
        version.loaderLabel == nil
            && ["release", "snapshot", "old_beta", "old_alpha"].contains(version.type)
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

    // MARK: - 已安装版本管理（导出 / 删除，对照 Android 端版本页操作条）

    @State private var isExporting = false
    @State private var exportMessage: String?
    @State private var exportDocument: ZipExportDocument?
    @State private var exportFileName = ""
    @State private var showFileExporter = false
    @State private var showDeleteConfirm = false
    @State private var showModLibrary = false

    /// 模组管理卡：整合包场景下开关 / 删除模组是最常用的操作。
    private var modsCard: some View {
        YZLCard(padding: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("模组")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(YZLTheme.text)
                    Text(modsSummary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.muted)
                        .lineLimit(2)
                }
                Spacer()
                Button("管理模组") {
                    showModLibrary = true
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
        }
        .sheet(isPresented: $showModLibrary) {
            ModLibrarySheet(gameDirectory: InstallLayout.forVersion(version.id).gameDirectory)
        }
    }

    private var modsSummary: String {
        let mods = MobileCompat.listMods(in: InstallLayout.forVersion(version.id).gameDirectory)
        guard !mods.isEmpty else {
            return "没有模组。导入整合包或在 game/mods 里放 jar 后会出现在这里。"
        }
        let enabled = mods.filter(\.isEnabled).count
        let bytes = mods.reduce(Int64(0)) { $0 + $1.size }
        return "\(mods.count) 个模组（启用 \(enabled) · 关闭 \(mods.count - enabled)）· \(formatBytes(bytes))"
    }

    private var installedActionsCard: some View {
        YZLCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("版本管理")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)

                Text("导出成 ZIP 整合包（含 yzl.modpack.json 与 PCL 兼容标记），可与 PCL / YZL 安卓端互通；mods 与存档一并打包，依赖库与资源由接收方重新下载。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)

                HStack(spacing: 10) {
                    Button {
                        startExport()
                    } label: {
                        Label(isExporting ? "正在打包…" : "导出 ZIP", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: true))
                    .disabled(isExporting)

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除版本", systemImage: "trash")
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                }

                if let message = exportMessage {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.text)
                        .lineSpacing(3)
                }
            }
        }
        .confirmationDialog(
            "删除 \(version.id)？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除版本", role: .destructive) {
                appState.removeInstalledVersion(id: version.id)
                exportMessage = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除这个版本目录里的全部内容（版本 JSON、客户端 jar、模组、存档与资源），无法恢复；以后想玩需要重新完整安装。")
        }
        .fileExporter(
            isPresented: $showFileExporter,
            document: exportDocument,
            contentType: .zip,
            defaultFilename: exportFileName,
            onCompletion: { result in
                switch result {
                case .success:
                    exportMessage = "导出完成。"
                case .failure(let error):
                    exportMessage = "导出失败：\(error.localizedDescription)"
                }
                exportDocument = nil
            }
        )
    }

    /// 先在 tmp 里打包（可能要几秒，期间按钮禁用），打包完成后弹系统文件面板选目的地。
    private func startExport() {
        guard !isExporting else { return }
        isExporting = true
        exportMessage = nil
        let versionID = version.id
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("YZLExport-\(UUID().uuidString)")
            .appendingPathComponent(VersionExporter.suggestedName(for: versionID))

        Task { @MainActor in
            do {
                let result = try VersionExporter.export(versionID: versionID, to: destination)
                exportDocument = ZipExportDocument(sourceURL: destination)
                exportFileName = VersionExporter.suggestedName(for: versionID)
                showFileExporter = true
                exportMessage = "打包完成：\(result.fileCount) 个文件 · \(formatBytes(result.totalBytes))，请在弹出的面板里选择保存位置。"
            } catch {
                exportMessage = "打包失败：\(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    @ViewBuilder
    private var downloadCard: some View {
        if let detail = model.detail, let client = detail.clientArtifact {
            YZLCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("客户端 jar（单独下载）")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(YZLTheme.text)

                    Text("只下载 jar，不会写入安装记录；完整安装请用上方的「开始安装」。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.muted)
                        .lineSpacing(2)

                    infoRow("大小", formatBytes(client.size))
                    infoRow("Java", detail.javaRequirement)
                    infoRow("SHA-1", client.sha1)

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

// MARK: - 导出文件包装

/// `.fileExporter` 的文档载体：打包已在 tmp 完成，这里只负责把现成的 zip 复制到用户选的位置。
/// `init(configuration:)` 仅为满足 FileDocument 协议（本流程从不读入）。
private struct ZipExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    let sourceURL: URL

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    init(configuration: ReadConfiguration) throws {
        // 只用于写出；占位指向临时目录，读入路径在本流程中不会被触发。
        sourceURL = FileManager.default.temporaryDirectory
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: sourceURL, options: .immediate)
    }
}
