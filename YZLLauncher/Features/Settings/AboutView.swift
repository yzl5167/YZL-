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
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    VStack(spacing: 14) {
                        runtimeCard
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
                Image("BrandIcon")
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
                milestone(index: 1, text: "微软登录、版本安装、下载器、启动自检")
                milestone(index: 2, text: "JRE + 启动内核，进入主菜单")
                milestone(index: 3, text: "模组 / 整合包与联机")
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
