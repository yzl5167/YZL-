import SwiftUI

/// 模组管理列表：开关（mods ↔ mods-ios-off 搬移）、搜索、滑动删除。
/// 数据源是 MobileCompat.listMods 的文件清单，不做任何缓存——每次操作后重扫目录。
struct ModLibrarySheet: View {
    let gameDirectory: URL
    @Environment(\.dismiss) private var dismiss

    @State private var mods: [MobileCompat.ModEntry] = []
    @State private var searchText = ""
    @State private var pendingDelete: MobileCompat.ModEntry?
    @State private var errorMessage: String?

    private var filtered: [MobileCompat.ModEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return mods }
        return mods.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        NavigationView {
            Group {
                if mods.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(YZLTheme.lightMuted)
                        Text("这个版本还没有模组")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(YZLTheme.text)
                        Text("导入整合包，或把 jar 放进版本的 game/mods 目录。")
                            .font(.system(size: 11))
                            .foregroundStyle(YZLTheme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    modList
                }
            }
            .background(PageBackground())
            .navigationTitle("模组管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索模组")
        }
        .onAppear { reload() }
        .alert("删除模组？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let target = pendingDelete {
                    MobileCompat.deleteMod(in: gameDirectory, name: target.name, isEnabled: target.isEnabled)
                    reload()
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("会从本机删除 \(pendingDelete?.name ?? "")，无法恢复。")
        }
    }

    private var modList: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.danger)
            }
            Section {
                ForEach(filtered) { entry in
                    modRow(entry)
                }
                .onDelete { offsets in
                    guard let first = offsets.first, filtered.indices.contains(first) else { return }
                    pendingDelete = filtered[first]
                }
            } footer: {
                Text("关闭的模组会移到 mods-ios-off（游戏不会加载）；「极端兼容」开关移动的 Sodium / Iris 也在这里管理。删除不可恢复。")
            }
        }
        .listStyle(.insetGrouped)
        .yzlClearListBackground()
    }

    private func modRow(_ entry: MobileCompat.ModEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(YZLTheme.text)
                    .lineLimit(2)
                Text("\(entry.isEnabled ? "已启用" : "已关闭") · \(InstallFormats.bytes(entry.size))")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { _ in toggle(entry) }
            ))
            .labelsHidden()
            .tint(YZLTheme.accent)
        }
    }

    private func toggle(_ entry: MobileCompat.ModEntry) {
        do {
            try MobileCompat.setModEnabled(in: gameDirectory, name: entry.name, enabled: !entry.isEnabled)
            errorMessage = nil
        } catch {
            errorMessage = "搬移失败：\(error.localizedDescription)"
        }
        reload()
    }

    private func reload() {
        mods = MobileCompat.listMods(in: gameDirectory)
    }
}
