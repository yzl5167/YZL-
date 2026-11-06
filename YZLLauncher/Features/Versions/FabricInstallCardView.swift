import SwiftUI

/// 版本详情页里的「加载器」安装卡（Fabric / Quilt）。
///
/// 对照 Android 端 DownloadScreen 的加载器选择与 Windows 端的加载器下拉：
/// 从官方 Meta（fabric v2 / quilt v3）取加载器列表，选中后拉取 profile JSON
/// （`inheritsFrom` 指向当前原版），走与原版完全相同的整包安装链路
/// （继承链解析 → 拍平落盘 → 分片下载 → SHA-1 → 安装记录）。
struct FabricInstallCardView: View {
    let baseVersion: MinecraftVersion
    @EnvironmentObject private var appState: AppState
    @ObservedObject var queue: DownloadQueue

    @State private var loaderKind: LoaderKind = .fabric
    @State private var loaders: [LoaderEntry] = []
    @State private var isLoadingLoaders = false
    @State private var loadersErrorMessage: String?
    @State private var selectedLoaderID: String?
    @State private var isFetchingProfile = false
    @State private var activeModel: VersionDetailViewModel?
    @State private var activeVersion: MinecraftVersion?

    private let service = LoaderService()

    var body: some View {
        YZLCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if let model = activeModel {
                    installCard(model)
                } else {
                    pickerContent
                }
            }
        }
        .task(id: baseVersion.id) {
            resetForVersion()
            await loadLoaders()
        }
    }

    // MARK: - 加载器选择

    @ViewBuilder
    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("安装加载器")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                Spacer()
                Text("官方 Meta")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.lightMuted)
            }

            Picker("加载器", selection: $loaderKind) {
                ForEach(LoaderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: loaderKind) { _ in
                Task { await loadLoaders() }
            }

            Text("在 \(baseVersion.id) 上加装 \(loaderKind.displayName)。安装时会自动取回并合并它继承的原版文件（客户端 jar、资源、Java 要求），装完就是可启动的独立版本。")
                .font(.system(size: 11))
                .foregroundStyle(YZLTheme.muted)
                .lineSpacing(3)

            if isLoadingLoaders {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在获取 \(loaderKind.displayName) 加载器列表…")
                        .font(.system(size: 12))
                        .foregroundStyle(YZLTheme.muted)
                }
            } else if let message = loadersErrorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.danger)
                    Button("重试") {
                        Task { await loadLoaders() }
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                }
            } else if !loaders.isEmpty {
                Picker("\(loaderKind.displayName) 版本", selection: $selectedLoaderID) {
                    ForEach(loaders) { entry in
                        Text(label(for: entry)).tag(Optional(entry.version))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    startInstall()
                } label: {
                    if isFetchingProfile {
                        HStack(spacing: 7) {
                            ProgressView()
                            Text("正在获取 \(loaderKind.displayName) 版本信息…")
                        }
                    } else {
                        Text("安装 \(loaderKind.displayName) \(selectedLoaderID ?? "")")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selectedLoaderID == nil || isFetchingProfile || queue.state.phase == .running)
            }
        }
    }

    private func label(for entry: LoaderEntry) -> String {
        entry.isStable ? "\(entry.version) · 稳定" : "\(entry.version)"
    }

    // MARK: - 安装（复用 InstallCardView 的状态机）

    private func installCard(_ model: VersionDetailViewModel) -> some View {
        // 闭包要捕获「点击安装时」的版本，而不是可变的 @State：
        // 用户中途点「换成其它版本」会把 activeVersion 置 nil，
        // 若闭包里再读 @State，队列跑完会跳过 recordInstall，装完却查不到记录。
        let installedVersion = activeVersion
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(loaderKind.displayName) \(model.versionID)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                Spacer()
                Button("换成其它版本") {
                    activeModel = nil
                    activeVersion = nil
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(YZLTheme.accentText)
                .buttonStyle(.plain)
            }
            InstallCardView(
                model: model,
                queue: queue,
                onInstalled: { detail, fileCount, bytes in
                    guard let installedVersion else { return }
                    appState.recordInstall(
                        detail: detail,
                        version: installedVersion,
                        fileCount: fileCount,
                        totalBytes: bytes
                    )
                },
                title: "安装 \(loaderKind.displayName) 文件",
                subtitle: "\(loaderKind.displayName) 库 + 继承的原版客户端 jar / 依赖库 / 资源。全部通过 SHA-1 后记为已安装。"
            )
        }
    }

    // MARK: - 数据

    private func resetForVersion() {
        loaderKind = .fabric
        loaders = []
        loadersErrorMessage = nil
        selectedLoaderID = nil
        isFetchingProfile = false
        activeModel = nil
        activeVersion = nil
    }

    private func loadLoaders() async {
        guard !baseVersion.id.isEmpty else { return }
        isLoadingLoaders = true
        loadersErrorMessage = nil
        defer { isLoadingLoaders = false }
        do {
            loaders = try await service.fetchLoaders(kind: loaderKind, gameVersion: baseVersion.id)
            selectedLoaderID = loaders.first(where: { $0.isStable })?.version ?? loaders.first?.version
        } catch {
            loadersErrorMessage = "获取 \(loaderKind.displayName) 加载器失败：\(error.localizedDescription)"
        }
    }

    private func startInstall() {
        guard let loaderID = selectedLoaderID else { return }
        let kind = loaderKind
        isFetchingProfile = true
        Task {
            defer { isFetchingProfile = false }
            do {
                let profile = try await service.fetchProfile(kind: kind, gameVersion: baseVersion.id, loaderVersion: loaderID)
                let profileVersion = MinecraftVersion(
                    id: profile.id,
                    type: profile.type.isEmpty ? "release" : profile.type,
                    url: kind.profileURL(gameVersion: baseVersion.id, loaderVersion: loaderID),
                    time: profile.time ?? baseVersion.time,
                    releaseTime: profile.releaseTime ?? baseVersion.releaseTime
                )
                activeVersion = profileVersion
                activeModel = VersionDetailViewModel(version: profileVersion, preloadedDetail: profile)
            } catch {
                loadersErrorMessage = "获取 \(kind.displayName) profile 失败：\(error.localizedDescription)"
            }
        }
    }
}
