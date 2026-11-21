import SwiftUI

/// 资源详情与安装弹层：列版本 → 选已安装游戏版本 → 下载安装（含前置依赖）。
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

    private var selectedVersion: ModrinthVersion? {
        versions.first { $0.id == selectedVersionID }
    }

    private var installedVersions: [InstalledVersion] { appState.installedVersions }

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

                    versionPicker
                    targetPicker

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
                    ForEach(versions) { v in
                        Button {
                            selectedVersionID = v.id
                        } label: {
                            Text("\(v.versionNumber) · \(v.gameVersions.prefix(2).joined(separator: ","))")
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
                        Button { targetVersionID = installed.id } label: {
                            Text(installed.id)
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
            }
        }
    }

    private var installButton: some View {
        Button {
            Task { await install() }
        } label: {
            if queue.state.phase == .running {
                Text("正在安装…")
            } else {
                Text("安装\(category.title)")
            }
        }
        .buttonStyle(PrimaryButtonStyle(prominent: true))
        .disabled(
            selectedVersion == nil || targetVersionID == nil
                || queue.state.phase == .running
        )
    }

    private func loadVersions() async {
        do {
            let list = try await ModrinthService.versions(for: project.id)
            let game = gameVersion.isEmpty ? nil : gameVersion
            let loader = (category == .mod || category == .modpack) ? appStateSelectedLoader() : nil
            let best = ModrinthService.pickBest(list, gameVersion: game, loader: loader)
            versions = list
            selectedVersionID = best?.version.id ?? list.first?.id
            isLoadingVersions = false
            if targetVersionID == nil { targetVersionID = appState.selectedVersion?.id }
        } catch {
            loadError = error.localizedDescription
            isLoadingVersions = false
        }
    }

    /// 详情弹层不直接持有筛选加载器；用项目 categories 猜一个，主要影响"最佳版本"排序。
    private func appStateSelectedLoader() -> String? {
        let known = ["fabric", "forge", "neoforge", "quilt"]
        return project.categories?.first(where: { known.contains($0.lowercased()) })
    }

    private func install() async {
        guard let version = selectedVersion, let targetID = targetVersionID else { return }
        if category == .modpack {
            installMessage = "整合包请用版本页的「导入整合包」安装（需要 Java 安装器）。"
            return
        }
        let result = await ResourceInstaller.specs(
            for: version,
            category: category,
            gameVersion: gameVersion.isEmpty ? nil : gameVersion,
            installedVersionID: targetID
        )
        guard !result.specs.isEmpty else {
            installMessage = result.summary.isEmpty ? "没有可安装的文件。" : result.summary
            return
        }
        installMessage = result.summary
        queue.start(result.specs, batchID: "resource:\(project.id)") {
            YZLBootLog.write("resource install done | \(project.slug) → \(targetID)")
        }
    }
}
