import SwiftUI

struct InstallCardView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: VersionDetailViewModel
    @ObservedObject var queue: DownloadQueue
    var onInstalled: ((VersionDetail, Int, Int64) -> Void)?
    /// 卡片标题与说明：原版安装与 Fabric 安装共用同一套进度/状态 UI。
    var title: String = "安装原版文件"
    var subtitle: String = "客户端 jar + iOS 适用的依赖库 + 资源索引 + 资源对象。全部文件通过 SHA-1 后才会记为“已安装”，之后主页的启动按钮才会放行。"

    var body: some View {
        YZLCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)

                if let note = model.inheritanceNote {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.accentText)
                        .lineSpacing(2)
                }

                if let summary = model.installSummary {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.accentText)
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.danger)
                }

                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isPreparingInstall {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在统计安装清单…")
                    .font(.system(size: 12))
                    .foregroundStyle(YZLTheme.muted)
            }
        } else if isCurrentBatch, queue.state.phase == .running {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: queue.state.progress)
                    .tint(YZLTheme.accent)
                Text(queueText(queue.state))
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
                Button("取消安装") {
                    queue.cancel()
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
        } else if isCurrentBatch, case .finished = queue.state.phase {
            installedContent
        } else if isInstalled {
            installedContent
        } else if queue.state.phase == .running {
            Text("另一个版本正在安装（\(queue.state.batchID ?? "未知")），完成后再开始。")
                .font(.system(size: 11))
                .foregroundStyle(YZLTheme.muted)
        } else if isCurrentBatch, case .failed(let message) = queue.state.phase {
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.danger)
                Button("重试未完成部分") {
                    startInstall()
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
        } else if isCurrentBatch, case .cancelled = queue.state.phase {
            VStack(alignment: .leading, spacing: 6) {
                Text("已取消，已下完的文件保留，重试只补差额")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
                Button("继续安装") {
                    startInstall()
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
        } else {
            Button("开始安装") {
                startInstall()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.detail == nil)
        }

        if isCurrentBatch, !queue.state.failures.isEmpty {
            Text(queue.state.failures.prefix(2).joined(separator: "\n"))
                .font(.system(size: 10))
                .foregroundStyle(YZLTheme.danger.opacity(0.85))
                .lineLimit(2)
        }
    }

    private var installedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("已安装并通过 SHA-1 校验", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(YZLTheme.success)

            if let record = appState.installedVersion(for: model.versionID) {
                Text("\(record.fileCount) 个文件 · \(record.sizeText) · \(record.installedAtText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(YZLTheme.muted)
            }

            Button {
                appState.requestLaunch(version: model.minecraftVersion)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("启动游戏")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var isInstalled: Bool {
        appState.isInstalled(model.versionID)
    }

    private var isCurrentBatch: Bool {
        queue.state.batchID == model.versionID
    }

    private func startInstall() {
        let handler = onInstalled
        model.startInstall(using: queue) { detail, fileCount, bytes in
            handler?(detail, fileCount, bytes)
        }
    }

    private func queueText(_ state: QueueState) -> String {
        let bytes = "\(InstallFormats.bytes(state.doneBytes)) / \(InstallFormats.bytes(state.totalBytes))"
        return "\(state.doneFiles)/\(state.totalFiles) 个文件 · \(bytes) · \(InstallFormats.speed(state.speedBytesPerSecond)) · 并发 \(state.activeFiles)"
    }
}
