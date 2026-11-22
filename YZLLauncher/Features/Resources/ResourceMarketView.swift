import SwiftUI

/// 资源市场（对齐 Windows 端 Mods / Shaders / ResourcePacks 页）：
/// 从 Modrinth 在线浏览、搜索、筛选并安装模组/光影/资源包到已安装版本。
/// 整合包不在此安装（iOS 无 Java 安装器），点开会给出明确指引而非死路。
struct ResourceMarketView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ResourceMarketViewModel()
    @State private var detailProject: ModrinthProject?
    @State private var showModpackHint = false

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
            viewModel.setInstalledVersions(appState.installedVersions.map(\.id))
            if viewModel.results.isEmpty { await viewModel.search() }
        }
        .sheet(item: $detailProject) { project in
            ResourceDetailSheet(
                project: project,
                category: viewModel.category,
                gameVersion: viewModel.gameVersion,
                viewModel: viewModel,
                queue: appState.installQueue
            )
            .environmentObject(appState)
        }
        .alert("整合包请在版本页导入", isPresented: $showModpackHint) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("iOS 上整合包需要 Java 安装器，请在「版本 → 导入整合包」里安装 .mrpack / ZIP。这里可浏览整合包介绍，但点安装会引导到版本页。")
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("资源市场")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                Text("从 Modrinth 搜索并安装模组、光影与资源包")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }
            Spacer()
            Button {
                Task { await viewModel.search() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(YZLTheme.muted)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(YZLTheme.card))
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
                ForEach(ResourceCategory.allCases) { cat in
                    Button {
                        viewModel.selectCategory(cat)
                        Task { await viewModel.search() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: cat.icon)
                                .font(.system(size: 12))
                            Text(cat.title)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(viewModel.category == cat ? YZLTheme.onAccent : YZLTheme.text)
                        .background(
                            Capsule().fill(viewModel.category == cat ? YZLTheme.accent : YZLTheme.card)
                        )
                        .overlay(Capsule().stroke(YZLTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(YZLTheme.muted)
                TextField("搜索 \(viewModel.category.title)（支持中文）", text: $viewModel.searchText)
                    .font(.system(size: 12))
                    .autocorrectionDisabled()
                    // 250ms 防抖自动搜索，对齐 Windows 端 TextChanged 行为。
                    .onChange(of: viewModel.searchText) { _ in viewModel.scheduleSearch() }
                    .onSubmit { Task { await viewModel.search() } }

                Picker("游戏版本", selection: $viewModel.gameVersion) {
                    Text("全部版本").tag("")
                    ForEach(viewModel.versionOptions, id: \.self) { v in
                        Text(v).tag(v)
                    }
                }
                .frame(width: 110)
                .onChange(of: viewModel.gameVersion) { _ in
                    Task { await viewModel.search() }
                }

                if viewModel.category == .mod || viewModel.category == .modpack {
                    Picker("加载器", selection: $viewModel.loader) {
                        ForEach(ResourceMarketViewModel.loaderOptions, id: \.self) { l in
                            Text(l).tag(l)
                        }
                    }
                    .frame(width: 90)
                    .onChange(of: viewModel.loader) { _ in
                        Task { await viewModel.search() }
                    }
                }

                Picker("排序", selection: $viewModel.sort) {
                    ForEach(ResourceMarketViewModel.sortOptions, id: \.value) { opt in
                        Text(opt.title).tag(opt.value)
                    }
                }
                .frame(width: 90)
                .onChange(of: viewModel.sort) { _ in
                    Task { await viewModel.search() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(YZLTheme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(YZLTheme.border, lineWidth: 1))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.results.isEmpty {
            ProgressView("正在搜索 Modrinth…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage, viewModel.results.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 30))
                    .foregroundStyle(YZLTheme.muted)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(YZLTheme.muted)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await viewModel.search() } }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                    .frame(width: 120)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(YZLTheme.lightMuted)
                Text("没有找到结果，换个关键词或放宽筛选试试")
                    .font(.system(size: 12))
                    .foregroundStyle(YZLTheme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(viewModel.results) { project in
                        ResourceCard(project: project, viewModel: viewModel) {
                            if viewModel.category == .modpack {
                                showModpackHint = true
                            } else {
                                detailProject = project
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)

                if viewModel.results.count < viewModel.totalHits {
                    Button {
                        Task { await viewModel.loadMore() }
                    } label: {
                        HStack {
                            if viewModel.isLoadingMore { ProgressView() }
                            Text("加载更多（已显示 \(viewModel.results.count) / \(viewModel.totalHits)）")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                    .frame(width: 280)
                    .padding(.vertical, 16)
                    .disabled(viewModel.isLoadingMore)
                }
            }
            .padding(.bottom, 24)
        }
    }
}

private struct ResourceCard: View {
    let project: ModrinthProject
    @ObservedObject var viewModel: ResourceMarketViewModel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    if let icon = project.iconURL, let url = URL(string: icon) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit()
                            } else {
                                Image(systemName: "square.grid.2x2.fill")
                                    .foregroundStyle(YZLTheme.muted)
                            }
                        }
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 8).fill(YZLTheme.field))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.translatedTitle(for: project))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(YZLTheme.text)
                            .lineLimit(2)
                        Text(project.slug)
                            .font(.system(size: 9))
                            .foregroundStyle(YZLTheme.lightMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                Text(viewModel.translatedDescription(for: project))
                    .font(.system(size: 10.5))
                    .foregroundStyle(YZLTheme.muted)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    if let downloads = project.downloads {
                        Label(Self.compact(downloads), systemImage: "arrow.down.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(YZLTheme.lightMuted)
                    }
                    if let cats = project.categories, let first = cats.first {
                        Text(first)
                            .font(.system(size: 9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(YZLTheme.field))
                            .foregroundStyle(YZLTheme.muted)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(YZLTheme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(YZLTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
