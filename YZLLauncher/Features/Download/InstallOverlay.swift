import SwiftUI

/// 全局安装进度弹窗（对照 Android 端 InstallOverlay）：
/// 任何页面触发的安装都在这里统一显示运行 / 成功 / 失败 / 取消四种状态。
/// 运行中不允许点击外部关闭（防误触打断下载）。
struct InstallOverlay: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var queue: DownloadQueue

    var body: some View {
        if queue.state.phase != .idle {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {}   // 吃掉点击，运行中不可穿透

                panel
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 16)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .animation(.easeInOut(duration: 0.18), value: queue.state.phase)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch queue.state.phase {
            case .running:
                runningBody
            case .finished:
                finishedBody
            case .failed(let message):
                failedBody(message: message, danger: true)
            case .cancelled:
                failedBody(message: "安装已取消，已下载的分片会保留。", danger: false)
            case .idle:
                EmptyView()
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(YZLTheme.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 6)
    }

    private var header: some View {
        HStack(spacing: 12) {
            YzlLogoMark(size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(stateTitle)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                if let batchID = queue.state.batchID {
                    Text(batchID)
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.muted)
                        .lineLimit(1)
                }
            }
            Spacer()
            statusBadge
        }
    }

    private var stateTitle: String {
        switch queue.state.phase {
        case .running: return "正在安装"
        case .finished: return "安装完成"
        case .failed: return "安装失败"
        case .cancelled: return "安装已暂停"
        case .idle: return ""
        }
    }

    private var statusBadge: some View {
        let success = queue.state.phase == .finished
        return Image(systemName: success ? "checkmark.circle.fill" : "info.circle.fill")
            .font(.system(size: 19))
            .foregroundStyle(success ? YZLTheme.success : YZLTheme.danger)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(success ? YZLTheme.successSoft : YZLTheme.danger.opacity(0.10))
            )
    }

    private var runningBody: some View {
        let state = queue.state
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("正在下载游戏文件")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(YZLTheme.text)
                Spacer()
                Text("\(Int((state.progress * 100).rounded()))%")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(YZLTheme.accentText)
            }

            ProgressView(value: state.progress)
                .tint(YZLTheme.accent)

            Text(progressLine)
                .font(.system(size: 10))
                .foregroundStyle(YZLTheme.lightMuted)

            Text("下载会继续进行，锁屏或切到其他应用也不会中断。")
                .font(.system(size: 9))
                .foregroundStyle(YZLTheme.lightMuted)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(YZLTheme.field))

            Button {
                queue.cancel()
            } label: {
                Text("取消安装")
            }
            .buttonStyle(PrimaryButtonStyle(prominent: false))
            .tint(YZLTheme.danger)
            .frame(maxWidth: .infinity)
        }
    }

    private var finishedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(queue.state.batchID ?? "版本") 安装完成")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(YZLTheme.text)
            Text("文件已完整 · \(InstallFormats.bytes(queue.state.doneBytes))")
                .font(.system(size: 10))
                .foregroundStyle(YZLTheme.muted)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(YZLTheme.successSoft))

            Button {
                queue.dismissTerminalState()
                appState.selectedTab = .versions
            } label: {
                Text("查看已安装版本")
            }
            .buttonStyle(PrimaryButtonStyle(prominent: true))
            .frame(maxWidth: .infinity)

            Button {
                queue.dismissTerminalState()
            } label: {
                Text("完成")
            }
            .buttonStyle(PrimaryButtonStyle(prominent: false))
            .frame(maxWidth: .infinity)
        }
    }

    private func failedBody(message: String, danger: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(danger ? YZLTheme.danger : YZLTheme.muted)
                .lineSpacing(3)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(danger ? YZLTheme.danger.opacity(0.10) : YZLTheme.field)
                )
            Button {
                queue.dismissTerminalState()
            } label: {
                Text("关闭")
            }
            .buttonStyle(PrimaryButtonStyle(prominent: false))
            .frame(maxWidth: .infinity)
        }
    }

    private var progressLine: String {
        let state = queue.state
        let done = InstallFormats.bytes(state.doneBytes)
        let total = InstallFormats.bytes(state.totalBytes)
        let speed = InstallFormats.bytes(Int64(state.speedBytesPerSecond))
        return "\(state.doneFiles) / \(state.totalFiles) 个文件 · \(done) / \(total) · \(speed)/s"
    }
}
