import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - 文件选择器

/// 任意文件类型的文档选择器（拷贝模式）。
/// 不用 `.fileImporter`：.mrpack 没有系统 UTType 声明，按 UTType 过滤会选不中；
/// `asCopy: true` 会把文件拷进临时目录，后续读取与生命周期都安全。
struct ModpackFilePicker: UIViewControllerRepresentable {
    var onPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.data], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void

        init(onPicked: @escaping (URL) -> Void) {
            self.onPicked = onPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPicked(url)
        }
    }
}

// MARK: - 导入流程

/// 导入整合包：文件选择 → 本地解析预览 → 准备（基础版本 + 解压 + spec）→ 下载队列 → 安装记录。
/// 下载进度复用共享的 installQueue（与原版安装同一套 UI 数据源）。
struct ModpackImportSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var queue: DownloadQueue
    let zipURL: URL
    let onFinished: () -> Void

    @State private var isInspecting = false
    @State private var plan: ModpackPlan?
    @State private var inspectError: String?
    @State private var isPreparing = false
    @State private var prepareError: String?
    @State private var startedPackID: String?

    var body: some View {
        NavigationView {
            Group {
                if isInspecting {
                    centeredStatus("正在读取整合包…")
                } else if let inspectError {
                    failureView(inspectError)
                } else if let plan {
                    planView(plan)
                } else {
                    centeredStatus("准备导入…")
                }
            }
            .background(PageBackground())
            .navigationTitle("导入整合包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onFinished() }
                }
            }
        }
        .task {
            await inspect()
        }
    }

    private func centeredStatus(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(YZLTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(YZLTheme.warningText)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(YZLTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 460)
            Button("关闭") { onFinished() }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func planView(_ plan: ModpackPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryCard(plan)

                if startedPackID != nil {
                    progressCard
                } else {
                    installCard(plan)
                }

                if let prepareError {
                    Text(prepareError)
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.danger)
                        .lineSpacing(3)
                }
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private func summaryCard(_ plan: ModpackPlan) -> some View {
        YZLCard(padding: 16) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(plan.packName)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(YZLTheme.text)
                        .lineLimit(2)
                    Spacer()
                    StatusBadge(text: formatLabel(plan.format), tone: .neutral)
                }

                if !plan.packVersion.isEmpty {
                    Text("整合包版本 \(plan.packVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.muted)
                }

                Divider()

                infoRow("Minecraft", plan.minecraftVersion)
                infoRow("加载器", loaderLabel(plan))
                switch plan.onlineSource {
                case .direct(let files):
                    infoRow("在线文件", files.isEmpty ? "无（内容都在压缩包里）" : "\(files.count) 个")
                case .curseForge(let refs):
                    infoRow("CurseForge 文件", "\(refs.count) 个（走 MCIM 镜像）")
                }
                infoRow("本地内容", "\(plan.localFileCount) 个文件 · \(InstallFormats.bytes(plan.localBytes))")
            }
        }
    }

    private func installCard(_ plan: ModpackPlan) -> some View {
        YZLCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("安装说明")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)

                Text(explainText(plan))
                    .font(.system(size: 10.5))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)

                Button {
                    startInstall(plan)
                } label: {
                    Text(isPreparing ? "正在准备…" : "开始安装")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: true))
                .disabled(isPreparing || queue.state.phase == .running)
            }
        }
    }

    private var progressCard: some View {
        YZLCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("正在安装整合包")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)

                ProgressView(value: queue.state.progress)
                    .tint(YZLTheme.accent)

                Text(progressText)
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)

                switch queue.state.phase {
                case .finished:
                    Label("安装完成，已设为当前版本", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(YZLTheme.success)
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.danger)
                    Text("分片进度已保留，重新点「开始安装」会从断点续传。")
                        .font(.system(size: 10))
                        .foregroundStyle(YZLTheme.muted)
                case .cancelled:
                    Text("已取消，分片进度保留在本地。")
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.muted)
                default:
                    EmptyView()
                }
            }
        }
    }

    // MARK: - 动作

    private func inspect() async {
        isInspecting = true
        inspectError = nil
        defer { isInspecting = false }
        do {
            plan = try ModpackImporter.inspect(zipURL: zipURL)
        } catch {
            inspectError = error.localizedDescription
        }
    }

    private func startInstall(_ plan: ModpackPlan) {
        guard !isPreparing else { return }
        isPreparing = true
        prepareError = nil
        Task { @MainActor in
            do {
                let receipt = try await ModpackImporter.prepare(plan: plan, zipURL: zipURL)
                startedPackID = receipt.packID
                let appState = self.appState
                queue.start(receipt.specs, batchID: receipt.packID) {
                    // 队列只在「全部成功」时回调 completion（DownloadQueue 语义）。
                    ModpackImporter.extractSavedWorlds(receipt)
                    if !appState.isInstalled(receipt.baseVersionID) {
                        appState.recordInstall(
                            detail: receipt.baseDetail,
                            version: receipt.baseVersion,
                            fileCount: receipt.baseFileCount,
                            totalBytes: receipt.baseBytes
                        )
                    }
                    appState.recordInstall(
                        detail: receipt.modpackDetail,
                        version: receipt.modpackVersion,
                        fileCount: receipt.modpackFileCount,
                        totalBytes: receipt.modpackBytes
                    )
                }
            } catch {
                prepareError = error.localizedDescription
            }
            isPreparing = false
        }
    }

    // MARK: - 展示辅助

    private var progressText: String {
        let state = queue.state
        let done = InstallFormats.bytes(state.doneBytes)
        let total = InstallFormats.bytes(state.totalBytes)
        let speed = InstallFormats.bytes(Int64(state.speedBytesPerSecond))
        return "\(state.doneFiles) / \(state.totalFiles) 个文件 · \(done) / \(total) · \(speed)/s"
    }

    private func formatLabel(_ format: ModpackFormat) -> String {
        switch format {
        case .modrinth: return "Modrinth"
        case .curseforge: return "CurseForge"
        case .yzl: return "YZL 导出"
        case .mmc: return "MMC / Prism"
        case .pcl: return "PCL"
        case .generic: return "通用 ZIP"
        }
    }

    private func loaderLabel(_ plan: ModpackPlan) -> String {
        guard let loader = plan.loader else { return "原版" }
        let name = loader == .fabric ? "Fabric" : "Quilt"
        if let version = plan.loaderVersion, !version.isEmpty {
            return "\(name) \(version)"
        }
        return "\(name)（自动选最新稳定版）"
    }

    private func explainText(_ plan: ModpackPlan) -> String {
        var lines = ["基础版本（\(plan.minecraftVersion)\(plan.loader == nil ? "" : " + " + loaderLabel(plan))）会自动安装，压缩包里的 mods / config / 存档直接解压进整合包自己的游戏目录，全部文件通过 SHA-1 后才写入安装记录。"]
        switch plan.onlineSource {
        case .curseForge:
            lines.append("CurseForge 的模组文件通过 MCIM 镜像获取（免 API key）；世界 ZIP 会在下载完成后自动解压到 saves。")
        case .direct(let files) where files.isEmpty:
            lines.append("这个包没有在线文件，全部内容随压缩包解压。")
        default:
            break
        }
        lines.append("装完会自动做移动端适配（关光影、压画质），几百个模组的整合包建议在设置里把内存调到 3072 MB 以上。")
        return lines.joined(separator: "\n")
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
                .minimumScaleFactor(0.8)
        }
    }
}
