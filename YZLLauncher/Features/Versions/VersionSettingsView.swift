import SwiftUI

/// 版本设置页（对齐 PC 端「版本设置」：每版本独立的内存 / JVM 参数 /
/// 窗口宽高 / 全屏 / Java 版本锁定）。所有项都可空，空 = 跟随全局 / 自动。
///
/// 改动即时写回 `Documents/YZLVersionSettings/settings.json`（按版本 id 索引），
/// 下次启动自检与真正拉起引擎时都会读到这里的值。
struct VersionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let version: MinecraftVersion

    @State private var settings: PerVersionSettings
    /// 内存：是否跟随全局设置。
    @State private var useGlobalMemory: Bool
    /// 窗口宽高：是否覆盖默认。
    @State private var overrideWindow: Bool

    init(version: MinecraftVersion) {
        self.version = version
        let loaded = VersionSettingsStore().settings(for: version.id)
        _settings = State(initialValue: loaded)
        _useGlobalMemory = State(initialValue: loaded.memoryMB == nil)
        _overrideWindow = State(initialValue: loaded.windowWidth != nil || loaded.windowHeight != nil)
    }

    /// 版本默认推荐的 Java 大版本，给用户一个参照。
    private var recommendedJava: Int {
        JavaEnvironment.recommendedMajor(gameVersion: version.id)
    }

    // 内存滑块在「跟随全局」关闭时，给一个合理的初值（全局值或 2048）。
    private var effectiveInitialMemory: Int {
        let global = Int(UserDefaults.standard.double(forKey: "memoryMB"))
        return global > 0 ? global : 2048
    }

    var body: some View {
        ZStack {
            PageBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    memoryCard
                    jvmCard
                    windowCard
                    javaCard
                    resetCard
                    Text("设置仅对本版本（\(version.id)）生效，保存在本机，不影响其它版本。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(YZLTheme.lightMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { doneBar }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("版本设置")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                Text(version.id)
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }
            Spacer()
            Button {
                VersionSettingsStore().update(settings)
                dismiss()
            } label: {
                Text("完成")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(YZLTheme.accentText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(YZLTheme.accentSoft))
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(YZLTheme.page.opacity(0.96))
    }

    private var doneBar: some View {
        Button {
            VersionSettingsStore().update(settings)
            dismiss()
        } label: {
            Text("保存并关闭")
        }
        .buttonStyle(PrimaryButtonStyle())
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(YZLTheme.page.opacity(0.96))
    }

    // MARK: - 内存

    private var memoryCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("游戏内存")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(YZLTheme.text)
                    Spacer()
                    if let mb = settings.memoryMB {
                        Text("\(mb) MB")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(YZLTheme.accentText)
                    } else {
                        Text("跟随全局")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(YZLTheme.muted)
                    }
                }

                Toggle("跟随全局内存设置", isOn: $useGlobalMemory)
                    .font(.system(size: 12))
                    .tint(YZLTheme.accent)
                    .onChange(of: useGlobalMemory) { on in
                        settings.memoryMB = on ? nil : effectiveInitialMemory
                    }

                if !useGlobalMemory {
                    Slider(value: memoryBinding, in: 1024...4096, step: 512)
                        .tint(YZLTheme.accent)
                    Text("只为这个版本单独设内存；数百模组的整合包建议 3072–4096 MB。超过本机安全上限仍会被自动夹住。")
                        .font(.system(size: 10))
                        .foregroundStyle(YZLTheme.muted)
                        .lineSpacing(3)
                }
            }
        }
    }

    private var memoryBinding: Binding<Double> {
        Binding(
            get: { Double(settings.memoryMB ?? effectiveInitialMemory) },
            set: { settings.memoryMB = Int($0) }
        )
    }

    // MARK: - JVM 参数

    private var jvmCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("额外 JVM 参数")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)

                TextEditor(text: $settings.customJVMArguments)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 64, maxHeight: 120)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(YZLTheme.field)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(YZLTheme.border, lineWidth: 1)
                    )

                Text("在这些参数前会自动带上引擎自己的堆与 GC 设置；路径类参数（-Djava.library.path 等）会被忽略，避免把 Windows 原生库指给 iOS。示例：-XX:+UseZGC -Dexample.flag=true")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)
            }
        }
    }

    // MARK: - 窗口

    private var windowCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("窗口与全屏")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(YZLTheme.text)
                    Spacer()
                    Toggle("全屏启动", isOn: $settings.fullscreen)
                        .font(.system(size: 12))
                        .tint(YZLTheme.accent)
                        .fixedSize()
                }

                Toggle("覆盖默认窗口大小", isOn: $overrideWindow)
                    .font(.system(size: 12))
                    .tint(YZLTheme.accent)
                    .onChange(of: overrideWindow) { on in
                        if on {
                            if settings.windowWidth == nil { settings.windowWidth = 854 }
                            if settings.windowHeight == nil { settings.windowHeight = 480 }
                        } else {
                            settings.windowWidth = nil
                            settings.windowHeight = nil
                        }
                    }

                if overrideWindow {
                    HStack(spacing: 12) {
                        windowField("宽度", binding: widthBinding)
                        windowField("高度", binding: heightBinding)
                    }
                }
            }
        }
    }

    private func windowField(_ title: String, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(YZLTheme.muted)
            TextField("像素", text: binding)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(YZLTheme.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(YZLTheme.border, lineWidth: 1)
                )
        }
    }

    private var widthBinding: Binding<String> {
        Binding(
            get: { settings.windowWidth.map(String.init) ?? "" },
            set: { settings.windowWidth = Int($0.filter { $0.isNumber }) }
        )
    }

    private var heightBinding: Binding<String> {
        Binding(
            get: { settings.windowHeight.map(String.init) ?? "" },
            set: { settings.windowHeight = Int($0.filter { $0.isNumber }) }
        )
    }

    // MARK: - Java 版本锁定

    private var javaCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Java 版本")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)

                Picker("Java 大版本", selection: $settings.lockedJavaMajor) {
                    Text("自动（推荐 Java \(recommendedJava)）").tag(Int?.none)
                    Text("Java 8").tag(8 as Int?)
                    Text("Java 17").tag(17 as Int?)
                    Text("Java 21").tag(21 as Int?)
                    Text("Java 25").tag(25 as Int?)
                }
                .pickerStyle(.menu)
                .tint(YZLTheme.accent)

                let available = JavaEnvironment.availableMajors()
                if settings.lockedJavaMajor != nil,
                   let locked = settings.lockedJavaMajor,
                   !available.contains(locked) {
                    Text("当前没有 Java \(locked) 运行时。需要它的版本启动会失败，请安装含该 JRE 的引擎包，或把 iOS 版 JRE 放到 Documents/YZLJavaRuntimes/java-\(locked)-openjdk/。")
                        .font(.system(size: 10))
                        .foregroundStyle(YZLTheme.warningText)
                        .lineSpacing(3)
                } else {
                    Text("锁定后，这个版本启动时会强制用选定的 Java；选「自动」则按版本推荐（\(version.id) 推荐 Java \(recommendedJava)）。")
                        .font(.system(size: 10))
                        .foregroundStyle(YZLTheme.muted)
                        .lineSpacing(3)
                }
            }
        }
    }

    // MARK: - 恢复默认

    private var resetCard: some View {
        YZLCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("恢复默认")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(YZLTheme.text)
                    Text(settings.hasCustomization ? "本版本已自定义，点右边清除全部设置" : "本版本使用全局 / 自动设置")
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.muted)
                        .lineSpacing(3)
                }
                Spacer(minLength: 8)
                Button {
                    VersionSettingsStore().reset(version.id)
                    settings = VersionSettingsStore().settings(for: version.id)
                    useGlobalMemory = true
                    overrideWindow = false
                } label: {
                    Text("恢复默认")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
                .disabled(!settings.hasCustomization)
            }
        }
    }
}
