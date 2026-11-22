import SwiftUI

/// 资源详情与安装弹层：选目标游戏版本 → 列兼容版本 → 下载安装（含递归前置依赖）。
/// 关键：从"目标已安装实例"派生 MC 版本/加载器，避免装上不兼容版本导致游戏崩溃（对齐 Windows）。
struct ResourceDetailSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let project: ModrinthProject
    let category: ResourceCategory
    let gameVersion: String
    @ObservedObject var viewModel: ResourceMarketViewModel
    @ObservedObject var queue: DownloadQueue

    @State private var versions: [ModrinthVersion] = []
    @State private var selectedVersionID: String?
    @State private var targetVersionID: String?
    @State private var isLoadingVersions = true
    @State private var loadError: String?
    @State private var installMessage: String?
    @State private var compatibilityWarning: String?

    private var selectedVersion: ModrinthVersion? {
        versions.first { $0.id == selectedVersionID }
    }

    private var installedVersions: [InstalledVersion] { appState.installedVersions }

    /// 目标实例（决定 MC 版本与加载器，而不是市场页的筛选值）。
    private var targetInstalled: InstalledVersion? {
        installedVersions.first { $0.id == targetVersionID }
    }

    /// 从实例 id 前缀推断加载器（与 VersionManifest.loaderLabel 同源）：
    /// `fabric-loader-* / forge-* / neoforge-* / quilt-loader-*`，原版则无前缀。
    private var targetLoader: String? {
        guard category == .mod || category == .modpack else { return nil }
        let id = (targetInstalled?.id ?? "").lowercased()
        for known in ["neoforge", "forge", "fabric", "quilt"] {
            if id.hasPrefix(known) { return known }
        }
        // 原版实例不该装模组，但用户可能就是想下 Mod 备用；用市场页筛选兜底。
        return viewModel.loader
    }

    /// 目标实例的 MC 版本。Fabric/Forge 版本 id 形如
    /// `fabric-loader-0.16.14-1.20.1`，真正要与 Modrinth game_versions 比对的是末段 `1.20.1`。
    private var targetMCVersion: String? {
        let id = targetInstalled?.id ?? ""
        guard !id.isEmpty else { return gameVersion.isEmpty ? nil : gameVersion }
        if let match = id.range(of: "\\d+\\.\\d+(\\.\\d+)?$", options: .regularExpression) {
            return String(id[match])
        }
        return id
    }

    private var isThisBatchRunning: Bool {
        queue.state.phase == .running && queue.state.batchID == "resource:\(project.id)"
    }

    var body: some View {
        VStack(spacing: 0) {
            OverlayHeader(title: viewModel.translatedTitle(for: project), subtitle: project.slug) {
                dismiss()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(viewModel.translatedDescription(for: project))
                        .font(.system(size: 12))
                        .foregroundStyle(YZLTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    targetPicker
                    versionPicker

                    if let warning = compatibilityWarning {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(YZLTheme.warningText)
                            Text(warning)
                                .font(.system(size: 10.5))
                                .foregroundStyle(YZLTheme.warningText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let message = installMessage {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(YZLTheme.accentText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    installButton
                }
                .padding(20)
            }
        }
        .background(PageBackground())
        .task { await loadVersions() }
    }

    private var versionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("资源版本")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(YZLTheme.text)
            if isLoadingVersions {
                ProgressView().frame(maxWidth: .infinity)
            } else if let loadError {
                Text(loadError)
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.danger)
            } else {
                Menu {
                    ForEach(groupedVersions, id: \.key) { group in
                        Section(group.key) {
                            ForEach(group.items) { v in
                                Button {
                                    selectedVersionID = v.id
                                    updateCompatibility(for: v)
                                } label: {
                                    Text(v.versionNumber)
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedVersion?.versionNumber ?? "选择版本")
                            .font(.system(size: 12))
                        Spacer()
                        Image(systemName: "chevron.down")
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(YZLTheme.field))
                    .foregroundStyle(YZLTheme.text)
                }
                if let v = selectedVersion, !v.isRelease {
                    Text("这是快照/测试版，建议选正式版。")
                        .font(.system(size: 10))
                        .foregroundStyle(YZLTheme.warningText)
                }
            }
        }
    }

    /// 按 MC 版本分组，每组内保持发布时间倒序（Modrinth 原序）。
    private var groupedVersions: [(key: String, items: [ModrinthVersion])] {
        var groups: [(key: String, items: [ModrinthVersion])] = []
        for v in versions {
            let key = v.gameVersions.first ?? "其它"
            if let idx = groups.firstIndex(where: { $0.key == key }) {
                groups[idx].items.append(v)
            } else {
                groups.append((key, [v]))
            }
        }
        return groups
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("安装到游戏版本")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(YZLTheme.text)
            if installedVersions.isEmpty {
                Text("还没有已安装版本，请先在「下载」页安装一个游戏版本。")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.warningText)
            } else {
                Menu {
                    ForEach(installedVersions) { installed in
                        Button {
                            targetVersionID = installed.id
                            Task { await loadVersions() }
                        } label: {
                            Text("\(installed.id) · \(installed.type)")
                        }
                    }
                } label: {
                    HStack {
                        Text(targetVersionID ?? "选择已安装版本")
                            .font(.system(size: 12))
                        Spacer()
                        Image(systemName: "chevron.down")
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(YZLTheme.field))
                    .foregroundStyle(YZLTheme.text)
                }
                Text("检测到的加载器：\(targetLoader ?? "未识别") · MC \(targetMCVersion ?? "未知")")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
            }
        }
    }

    private var installButton: some View {
        Button {
            Task { await install() }
        } label: {
            if isThisBatchRunning {
                Text("正在安装…")
            } else {
                Text(installButtonTitle)
            }
        }
        .buttonStyle(PrimaryButtonStyle(prominent: true))
        .disabled(
            selectedVersion == nil || targetVersionID == nil
                || queue.state.phase == .running
        )
    }

    private var installButtonTitle: String {
        if category == .modpack { return "整合包请到版本页导入" }
        return "安装\(category.title)"
    }

    @MainActor
    private func loadVersions() async {
        if targetVersionID == nil { targetVersionID = appState.selectedVersion?.id }
        do {
            let list = try await ModrinthService.versions(for: project.id)
            let best = ModrinthService.pickBest(
                list, gameVersion: targetMCVersion, loader: targetLoader
            )
            versions = list
            selectedVersionID = best?.version.id ?? list.first?.id
            updateCompatibility(for: best?.version)
            isLoadingVersions = false
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            isLoadingVersions = false
        }
    }

    private func updateCompatibility(for version: ModrinthVersion?) {
        guard let version else {
            compatibilityWarning = "没有可用版本。"
            return
        }
        if let mc = targetMCVersion, !version.gameVersions.contains(mc) {
            compatibilityWarning = "所选版本不支持 MC \(mc)（支持 \(version.gameVersions.prefix(3).joined(separator: "/"))），安装后可能无法加载。"
        } else if let loader = targetLoader, !version.loaders.isEmpty,
                  !version.loaders.contains(where: { $0.lowercased() == loader }) {
            compatibilityWarning = "所选版本不支持 \(loader) 加载器，安装后可能无法加载。"
        } else {
            compatibilityWarning = nil
        }
    }

    @MainActor
    private func install() async {
        guard let version = selectedVersion, let targetID = targetVersionID else { return }
        if category == .modpack {
            dismiss()
            return
        }
        let result = await ResourceInstaller.specs(
            for: version,
            category: category,
            gameVersion: targetMCVersion,
            loader: targetLoader,
            installedVersionID: targetID
        )
        guard !result.specs.isEmpty else {
            installMessage = result.summary.isEmpty ? "没有可安装的文件。" : result.summary
            return
        }
        installMessage = result.summary
        queue.start(result.specs, batchID: "resource:\(project.id)") {
            YZLBootLog.write("resource install done | \(project.slug) → \(targetID)")
            // 通知模组列表刷新（ModLibrarySheet 每次 appear 也会 reload，这里是即时闭环）。
            NotificationCenter.default.post(name: .yzlModLibraryDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let yzlModLibraryDidChange = Notification.Name("yzlModLibraryDidChange")
}
