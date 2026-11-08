import SwiftUI

/// 联机：服务器收藏与管理。对齐 PC 端 `MainWindow.Multiplayer`。
/// 作为首页弹层（sheet）打开，不新增底部 tab，保持 FCL 式 5-tab 结构。
struct ServerListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var servers: [MinecraftServer] = []
    @State private var editing: MinecraftServer? = nil
    @State private var showingEditor = false

    private let store = ServerListStore()

    var body: some View {
        NavigationView {
            content
                .navigationTitle("服务器")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            editing = MinecraftServer(name: "", address: "")
                            showingEditor = true
                        } label: { Image(systemName: "plus") }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("完成") { dismiss() }
                    }
                }
                .sheet(isPresented: $showingEditor) {
                    if let editing {
                        ServerEditorSheet(server: editing) { saved in
                            persist(saved)
                            showingEditor = false
                        }
                    }
                }
        }
        .onAppear { servers = store.load() }
    }

    private var content: some View {
        Group {
            if servers.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 40))
                .foregroundStyle(YZLTheme.muted)
            Text("还没有收藏的服务器")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(YZLTheme.text)
            Text("点右上角 + 添加，或从游戏内直接连入。")
                .font(.system(size: 13))
                .foregroundStyle(YZLTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(servers) { server in
                    serverRow(server)
                }
            }
        }
    }

    private func serverRow(_ server: MinecraftServer) -> some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        toggleFavorite(server)
                    } label: {
                        Image(systemName: server.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(server.isFavorite ? YZLTheme.warningText : YZLTheme.muted)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(YZLTheme.text)
                        Text(server.connectAddress)
                            .font(.system(size: 12))
                            .foregroundStyle(YZLTheme.muted)
                    }
                    Spacer()
                    Button {
                        join(server)
                    } label: {
                        Text("加入")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(YZLTheme.accent)
                            )
                    }
                }
                if !server.note.isEmpty {
                    Text(server.note)
                        .font(.system(size: 12))
                        .foregroundStyle(YZLTheme.lightMuted)
                }
                HStack(spacing: 16) {
                    Button { edit(server) } label: {
                        Label("编辑", systemImage: "pencil")
                            .font(.system(size: 12))
                            .foregroundStyle(YZLTheme.accentText)
                    }
                    Button { delete(server) } label: {
                        Label("删除", systemImage: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(YZLTheme.danger)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - 操作

    private func persist(_ server: MinecraftServer) {
        var list = servers
        if let idx = list.firstIndex(where: { $0.id == server.id }) {
            list[idx] = server
        } else {
            list.append(server)
        }
        servers = list
        store.save(servers)
    }

    private func toggleFavorite(_ server: MinecraftServer) {
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[idx].isFavorite.toggle()
        store.save(servers)
    }

    private func edit(_ server: MinecraftServer) {
        editing = server
        showingEditor = true
    }

    private func delete(_ server: MinecraftServer) {
        servers.removeAll { $0.id == server.id }
        store.save(servers)
    }

    private func join(_ server: MinecraftServer) {
        dismiss()
        appState.joinServer(server)
    }
}

/// 新增 / 编辑单台服务器的表单。地址只填主机，端口单独一行（默认 25565）。
struct ServerEditorSheet: View {
    let original: MinecraftServer
    var onSave: (MinecraftServer) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var address: String
    @State private var portText: String
    @State private var note: String
    @State private var isFavorite: Bool

    init(server: MinecraftServer, onSave: @escaping (MinecraftServer) -> Void) {
        self.original = server
        self.onSave = onSave
        _name = State(initialValue: server.name)
        _address = State(initialValue: server.host)
        _portText = State(initialValue: String(server.port))
        _note = State(initialValue: server.note)
        _isFavorite = State(initialValue: server.isFavorite)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("名称（留空用地址）", text: $name)
                    TextField("服务器地址", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)
                }
                Section {
                    TextField("备注（可选）", text: $note)
                    Toggle("收藏到顶部", isOn: $isFavorite)
                }
            }
            .navigationTitle(original.name.isEmpty && original.address.isEmpty ? "添加服务器" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = (Int(portText.trimmingCharacters(in: .whitespaces))).flatMap { (1...65535).contains($0) ? $0 : nil } ?? 25565
        let finalAddress = "\(host):\(port)"
        var result = original
        result.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? finalAddress : name.trimmingCharacters(in: .whitespaces)
        result.address = finalAddress
        result.port = port
        result.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        result.isFavorite = isFavorite
        onSave(result)
        dismiss()
    }
}
