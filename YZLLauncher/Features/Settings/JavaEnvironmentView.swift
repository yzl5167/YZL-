import SwiftUI

/// Java 环境管理页：iOS 上对齐 PC 端「Java 管理」的可做部分。
///
/// 不能做的只有「在线下载安装 JRE」——iOS 不允许下载并执行未签名代码，
/// 且 Mojang 官方清单给的是 Windows/Linux/macOS 二进制，架构与平台标记都不对。
/// 其余能力都在：列出全部 JRE、显示真实版本/体积/来源/可用状态、
/// 按当前游戏版本给出推荐与匹配结果、手动导入路径、重新扫描。
struct JavaEnvironmentView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var runtimes: [JavaEnvironment.Runtime] = []

    private var requiredMajor: Int {
        JavaEnvironment.recommendedMajor(gameVersion: appState.selectedVersion?.id)
    }

    private var statusText: String {
        switch JavaEnvironment.selection(for: requiredMajor, runtimes: runtimes) {
        case .exact(let runtime):
            return "已匹配 \(runtime.displayName)（\(runtime.versionText)），启动时会写进 JAVA_HOME。"
        case .fallback(let runtime, let required):
            return "需要 Java \(required)，当前只有 \(runtime.displayName)。Java 向后兼容可以试，但老版本模组可能受模块化限制影响。"
        case .missing(let required, let available):
            return JavaEnvironment.missingHint(required: required, available: available)
        }
    }

    private var statusColor: Color {
        switch JavaEnvironment.selection(for: requiredMajor, runtimes: runtimes) {
        case .exact: return YZLTheme.success
        case .fallback: return YZLTheme.warningText
        case .missing: return YZLTheme.danger
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                PageBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        summaryCard
                        runtimesCard
                        importCard
                    }
                    .padding(24)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Java 环境")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("重新扫描") { reload() }
                }
            }
        }
        .onAppear { reload() }
    }

    private var summaryCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 9) {
                Text("当前游戏与所需 Java")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                infoRow("游戏版本", appState.selectedVersion?.id ?? "未选择")
                infoRow("需要", "Java \(requiredMajor)")
                Text(statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(statusColor)
                    .lineSpacing(3)
                Text("判定规则：优先用版本 JSON 里的 javaVersion.majorVersion；没有时按 1.16 及以下 → Java 8、1.17–1.20 → Java 17、1.21+ → Java 21。需要 Java 8 的版本不会拿 17 顶替。")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)
            }
        }
    }

    private var runtimesCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("已发现的 Java 运行时（\(runtimes.count)）")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                if runtimes.isEmpty {
                    Text("没有找到任何 JRE 目录。请确认装的是完整引擎包，或按下方说明手动导入。")
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.muted)
                } else {
                    ForEach(runtimes) { runtime in
                        runtimeRow(runtime)
                    }
                }
            }
        }
    }

    private func runtimeRow(_ runtime: JavaEnvironment.Runtime) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(runtime.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                Text(runtime.versionText)
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
                Spacer()
                Text(runtime.stateText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(runtime.isUsable ? YZLTheme.success : YZLTheme.warningText)
            }
            Text("\(runtime.sourceText) · \(runtime.sizeText)")
                .font(.system(size: 10))
                .foregroundStyle(YZLTheme.muted)
            Text(runtime.root.path)
                .font(.system(size: 9))
                .foregroundStyle(YZLTheme.lightMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .background(YZLTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var importCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("与 PC 端的差别 / 手动导入")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                Text("PC 端能从 Mojang 官方清单在线下载并安装任意 Java 版本；iOS 不允许下载执行未签名代码，且官方清单里没有 iOS 平台的 JRE。所以 iOS 的 Java 要么随引擎包内置，要么手动放进 App 的 Documents 目录。")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)
                Text("导入路径：文件 App → YZL → Documents/\(JavaEnvironment.manualDirectoryName)/java-N-openjdk/")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(YZLTheme.accentText)
                Text("目录里必须有 release，以及 lib/jli/libjli.dylib（Java 8）或 lib/server/libjvm.dylib（Java 17+）；只有空目录不会被当作可用 JRE。放好后点右上角「重新扫描」。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)
                Text("内存（-Xmx）在设置页「启动」里调整，启动前会写进引擎偏好并追加到 jvm_processed；GC 参数按 Java 大版本自动选择。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)
            }
        }
    }

    private func reload() {
        runtimes = JavaEnvironment.scan()
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(YZLTheme.text)
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(YZLTheme.muted)
        }
    }
}
