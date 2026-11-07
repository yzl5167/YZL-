import SwiftUI

struct AboutView: View {
    var body: some View {
        ZStack {
            PageBackground()
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 14) {
                        brandCard
                        milestoneCard
                        releaseNotesCard
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    VStack(spacing: 14) {
                        runtimeCard
                        thanksCard
                        licenseCard
                        Text("仅用于学习与自用。游戏资源从 Mojang 官方下载，用户需自备正版账户。")
                            .font(.system(size: 10))
                            .foregroundStyle(YZLTheme.lightMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .padding(20)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var brandCard: some View {
        YZLCard {
            HStack(spacing: 14) {
                YZLTheme.icon("BrandIcon")
                    .resizable()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("YZL Launcher iOS")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(YZLTheme.text)
                    Text("版本 \(DeviceInfo.appVersion) (\(DeviceInfo.buildNumber))")
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.muted)
                    StatusBadge(text: "M1 开发预览", tone: .warning)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var milestoneCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 9) {
                Text("里程碑")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                milestone(index: 0, text: "工程骨架、界面、版本清单", done: true)
                milestone(index: 1, text: "微软登录、版本安装、下载器、启动自检", done: true)
                milestone(index: 2, text: "JRE + 启动内核，进入主菜单")
                milestone(index: 3, text: "整合包 / 模组（联机待做）", done: true)
            }
        }
    }

    /// 更新日志（硬编码历史，与 Windows / Android 端同模式）。
    private var releaseNotesCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 9) {
                Text("更新日志")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)

                ForEach(Array(ReleaseNotes.history.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text("v\(entry.version)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(YZLTheme.text)
                            if entry.version == ReleaseNotes.currentVersion {
                                StatusBadge(text: "当前", tone: .success)
                            }
                        }
                        ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                            Text("• \(item)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(YZLTheme.muted)
                                .lineSpacing(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var runtimeCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("运行条件")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                Text("iOS 不允许 App Store 应用使用 JIT。TrollStore 兼容设备可以免电脑安装并自动开启 JIT；iOS 17.0.1 及以上需要电脑辅助配对/附加。")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(4)
            }
        }
    }

    /// 特别感谢（对齐 Android 端关于页）：给启动器提供基础能力、数据或参考的项目。
    private var thanksCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("特别感谢")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                Text("以下软件、服务和社区为 YZL 启动器提供了基础能力、数据或参考。")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)

                ForEach(Self.thanks) { entry in
                    HStack(spacing: 10) {
                        Text(entry.monogram)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(entry.color)
                            .frame(width: 38, height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(entry.color.opacity(0.14))
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(YZLTheme.text)
                            Text(entry.description)
                                .font(.system(size: 9))
                                .foregroundStyle(YZLTheme.muted)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private struct ThanksEntry: Identifiable {
        let monogram: String
        let name: String
        let description: String
        let color: Color

        var id: String { name }
    }

    private static let thanks: [ThanksEntry] = [
        ThanksEntry(monogram: "P", name: "PCL / Plain Craft Launcher", description: "界面风格与头像渲染的参考", color: Color(red: 0.231, green: 0.510, blue: 0.965)),
        ThanksEntry(monogram: "F", name: "Fold Craft Launcher (FCL)", description: "安卓端启动内核与界面思路", color: Color(red: 0.078, green: 0.722, blue: 0.651)),
        ThanksEntry(monogram: "A", name: "Amethyst-iOS", description: "iOS 启动内核（GPLv3）", color: Color(red: 0.545, green: 0.361, blue: 0.965)),
        ThanksEntry(monogram: "C", name: "CmlLib.Core", description: "PC 端版本安装与启动库", color: Color(red: 0.043, green: 0.647, blue: 0.914)),
        ThanksEntry(monogram: "B", name: "BMCLAPI", description: "国内下载镜像", color: Color(red: 0.133, green: 0.773, blue: 0.369)),
        ThanksEntry(monogram: "M", name: "Modrinth / CurseForge", description: "模组与整合包来源", color: Color(red: 0.063, green: 0.725, blue: 0.506)),
        ThanksEntry(monogram: "L", name: "LittleSkin", description: "皮肤站与 authlib-injector 生态", color: Color(red: 0.925, green: 0.282, blue: 0.600)),
        ThanksEntry(monogram: "M", name: "Minecraft / Mojang", description: "游戏本体的版权归 Mojang 所有", color: Color(red: 0.396, green: 0.639, blue: 0.051))
    ]

    private var licenseCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("开源与许可")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                Text("当前外壳为项目自有代码。若 M2 复用 Amethyst / Pojav 系与 Boardwalk（GPLv3），相关部分及衍生作品将按 GPLv3 开源。")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(4)
            }
        }
    }

    private func milestone(index: Int, text: String, done: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(done ? YZLTheme.success : YZLTheme.lightMuted)
            Text("M\(index) · \(text)")
                .font(.system(size: 11))
                .foregroundStyle(done ? YZLTheme.text : YZLTheme.muted)
        }
    }
}
