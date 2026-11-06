import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("memoryMB") private var memoryMB: Double = 2048
    @AppStorage(MicrosoftAuth.clientIdKey) private var clientId = MicrosoftAuth.defaultClientId
    @AppStorage(MirrorPolicy.storageKey) private var downloadSource = DownloadSource.official.rawValue

    var body: some View {
        ZStack {
            PageBackground()

            ScrollView {
                VStack(spacing: 14) {
                    accountCard
                    launchCard
                    downloadCard
                    diagnosticsCard
                    aboutCard
                    Text("YZL Launcher 与 Amethyst / PojavLauncher 团队无隶属关系。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(YZLTheme.lightMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            pageHeader
        }
    }

    /// 下载源切换（对照 Android / Windows 端的「下载源」设置）。
    /// 清单、版本详情、加载器 Meta、依赖库与资源对象的请求都会按这里的选择改写。
    private var downloadCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("下载源")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)

                Picker("下载源", selection: $downloadSource) {
                    ForEach(DownloadSource.allCases) { source in
                        Text(source.displayName).tag(source.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(DownloadSource(rawValue: downloadSource)?.hint ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)
            }
        }
    }

    private var pageHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("设置")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                Text("下载、外观、账号与本地数据")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(YZLTheme.page.opacity(0.96))
    }

    private var accountCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("账户")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)

                TextField("Azure 公共客户端 ID", text: $clientId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(YZLTheme.field)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(YZLTheme.border, lineWidth: 1)
                    )

                Text("默认已内置与安卓版相同的公共客户端 ID；也可以换成自己的 Azure 公共客户端。该 ID 是公开标识，不是密钥。")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)

                Button {
                    appState.overlay = .account
                } label: {
                    Text(appState.displayAccount == nil ? "打开账号管理" : "管理账号 · \(appState.displayAccount?.name ?? "")")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
        }
    }

    private var launchCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("启动")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(YZLTheme.text)
                    Spacer()
                    Text("\(Int(memoryMB)) MB")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(YZLTheme.accentText)
                }

                Slider(value: $memoryMB, in: 1024...4096, step: 512)
                    .tint(YZLTheme.accent)

                Text("游戏内存。启动自检会读取这个值并生成 -Xmx 参数；iPhone 建议先取 1024–2048 MB，超过设备限制会被系统终止。")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)
            }
        }
    }

    private var diagnosticsCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 9) {
                Text("诊断")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                infoRow("设备", DeviceInfo.modelIdentifier)
                infoRow("系统", DeviceInfo.systemVersion)
                infoRow("构建号", DeviceCapabilities.osBuild)
                infoRow("安装路线", DeviceCapabilities.routeHint)
                infoRow("部署档位", DeviceCapabilities.deploymentProfile.title)
                infoRow("电脑依赖", DeviceCapabilities.deploymentProfile.computerRequirement)
                infoRow("建议安装包", DeviceCapabilities.deploymentProfile.packageName)
                infoRow("进程内存上限", "\(DeviceCapabilities.processMemoryLimitMB) MB")
                infoRow("建议堆内存", "\(DeviceCapabilities.recommendedHeapMB) MB")
                infoRow("启动器", "\(DeviceInfo.appVersion) (\(DeviceInfo.buildNumber))")
                infoRow("构建", DeviceInfo.isDebugBuild ? "Debug" : "Release")
                infoRow("JIT", appState.jitStatus.title)
                infoRow("Java", appState.javaStatus.title)
                infoRow("引擎", appState.engineStatus.title)
                infoRow("已安装版本", "\(appState.installedVersions.count) 个")
                infoRow("当前版本", currentVersionText)
                Text("JIT 状态会在 M2 接入内核后由引擎实际检测，当前显示为未知。内存上限来自 os_proc_available_memory，能直接反映 increased-memory-limit 是否真的生效。")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)
                    .padding(.top, 2)
            }
        }
    }

    private var aboutCard: some View {
        YZLCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("关于")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(YZLTheme.text)
                    Text("版本说明、里程碑与开源许可")
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.muted)
                }
                Spacer()
                Button {
                    appState.overlay = .about
                } label: {
                    Text("查看")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
                .frame(width: 74)

                Link(destination: URL(string: "https://github.com/AngelAuraMC/Amethyst-iOS")!) {
                    Text("Amethyst")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(YZLTheme.accentText)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(YZLTheme.accentSoft)
                        )
                }
            }
        }
    }

    private var currentVersionText: String {
        guard let version = appState.selectedVersion else { return "未选择" }
        return appState.isInstalled(version.id) ? "\(version.id) · 已安装" : "\(version.id) · 未安装"
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(YZLTheme.text)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(YZLTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 2)
    }
}
