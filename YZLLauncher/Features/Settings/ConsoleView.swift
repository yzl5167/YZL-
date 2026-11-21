import SwiftUI
import UIKit

/// 控制台日志（对齐 Windows 端 PageConsole）：查看 YZL-boot.log、刷新、清空、分享。
/// 真机没有 Xcode 时，这是把启动现场发给开发者的主要途径。
struct ConsoleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText = ""
    @State private var showClearConfirm = false
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("控制台日志")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(YZLTheme.text)
                    Text("YZL-boot.log · \(InstallFormats.bytes(YZLBootLog.byteCount))")
                        .font(.system(size: 10))
                        .foregroundStyle(YZLTheme.muted)
                }
                Spacer()
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                        .foregroundStyle(YZLTheme.muted)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(YZLTheme.card))
                        .overlay(Circle().stroke(YZLTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { showShare = true } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14))
                        .foregroundStyle(YZLTheme.muted)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(YZLTheme.card))
                        .overlay(Circle().stroke(YZLTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(YZLTheme.card))
                        .overlay(Circle().stroke(YZLTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(YZLTheme.muted)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(YZLTheme.card))
                        .overlay(Circle().stroke(YZLTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if logText.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(YZLTheme.lightMuted)
                    Text("暂无日志。启动一次游戏后再来看。")
                        .font(.system(size: 12))
                        .foregroundStyle(YZLTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(logText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(YZLTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(16)
                }
            }
        }
        .background(PageBackground())
        .task { refresh() }
        .alert("清空日志？", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) {
                YZLBootLog.reset()
                refresh()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除 YZL-boot.log 里的全部内容，之后的操作会重新记录。")
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [YZLBootLog.fileURL])
        }
    }

    private func refresh() {
        logText = YZLBootLog.readText()
    }
}

/// UIActivityViewController 的 SwiftUI 包装，用于把日志文件分享出去。
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
