import SwiftUI
import UIKit

/// 控制台日志（对齐 Windows 端 PageConsole）：启动器日志 / 游戏日志切换，
/// 查看、搜索、自动滚底、清空、分享。真机无 Xcode 时这是取证主路径。
struct ConsoleView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = AppearanceStore.shared
    @State private var source: GameLogService.Source
    @State private var logText = ""
    @State private var byteCount: Int64 = 0
    @State private var searchText = ""
    @State private var showClearConfirm = false
    @State private var showShare = false
    @State private var shareItems: [Any] = []

    init(initialSource: GameLogService.Source = .boot) {
        _source = State(initialValue: initialSource)
    }

    private var displayedLines: [String] {
        let lines = logText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            sourcePicker

            if displayedLines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(YZLTheme.lightMuted)
                    Text(searchText.isEmpty
                         ? "暂无日志。启动一次游戏后再来看。"
                         : "没有匹配「\(searchText)」的日志行")
                        .font(.system(size: 12))
                        .foregroundStyle(YZLTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                logScrollView
            }
        }
        .background(PageBackground())
        .task { refresh() }
        .alert("清空启动器日志？", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) {
                YZLBootLog.reset()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { refresh() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除 YZL-boot.log 的全部内容，之后的操作会重新记录。游戏日志不受影响。")
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: shareItems)
        }
        // 主题切换时（跟随系统）强制重绘本 sheet。
        .id(appearance.styleVersion)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("控制台日志")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                Text("\(source.title) · \(InstallFormats.bytes(byteCount))")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
            }
            Spacer()
            HStack(spacing: 4) {
                iconButton("arrow.clockwise") { refresh() }
                iconButton("magnifyingglass") { /* 搜索框常驻，图标仅占位提示 */ }
                iconButton("square.and.arrow.up") { prepareShare() }
                if source == .boot {
                    iconButton("trash", destructive: true) { showClearConfirm = true }
                }
                iconButton("xmark") { dismiss() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private func iconButton(_ name: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13))
                .foregroundStyle(destructive ? YZLTheme.danger : YZLTheme.muted)
                .frame(width: 32, height: 32)
                .background(Circle().fill(YZLTheme.card))
                .overlay(Circle().stroke(YZLTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var sourcePicker: some View {
        VStack(spacing: 6) {
            Picker("日志源", selection: $source) {
                ForEach(GameLogService.Source.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: source) { _ in refresh() }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
                TextField("过滤日志（关键字）", text: $searchText)
                    .font(.system(size: 11))
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(YZLTheme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(YZLTheme.border, lineWidth: 1))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var logScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(displayedLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(YZLTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .textSelection(.enabled)
            }
            .onAppear {
                if let last = displayedLines.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .onChange(of: logText) { _ in
                if let last = displayedLines.indices.last {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func refresh() {
        switch source {
        case .boot:
            logText = YZLBootLog.readText()
            byteCount = YZLBootLog.byteCount
        case .game:
            logText = GameLogService.readText(versionID: nil)
            byteCount = GameLogService.byteCount(versionID: nil)
        }
    }

    /// 分享守卫：有文件分享文件，没有就分享文本内容。
    private func prepareShare() {
        switch source {
        case .boot:
            if FileManager.default.fileExists(atPath: YZLBootLog.fileURL.path) {
                shareItems = [YZLBootLog.fileURL]
            } else {
                shareItems = [logText.isEmpty ? "（无启动器日志）" : logText]
            }
        case .game:
            if let url = GameLogService.latestLogURL(versionID: nil) {
                shareItems = [url]
            } else {
                shareItems = [logText.isEmpty ? "（无游戏日志）" : logText]
            }
        }
        showShare = true
    }
}

/// UIActivityViewController 的 SwiftUI 包装。
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
