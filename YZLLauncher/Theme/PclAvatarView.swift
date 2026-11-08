import SwiftUI
import UIKit

/// 用户头像（全端统一）：从皮肤贴图裁剪头部 8×8 像素放大显示。
/// 离线/未登录时用内置真 Steve/Alex 默认皮肤（从官方客户端 jar 提取）。
/// 这是之前在设备上验证过的方式，安全可靠。
struct AvatarView: View {
    let size: CGFloat
    let account: MicrosoftAccount?
    /// 无自定义皮肤时的默认皮肤模型："steve" / "alex"。
    var defaultModel: String = "steve"

    @State private var texture: UIImage?

    private var skinReference: String? { account?.skinURL }

    var body: some View {
        Group {
            if let texture,
               let head = SkinTexture.head(from: texture, targetSize: size * 3) {
                Image(uiImage: head)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                            .stroke(YZLTheme.border, lineWidth: 1)
                    )
            } else {
                // 无皮肤：内置真 Steve/Alex 默认皮肤的头像。
                if let defaultHead = defaultHead {
                    Image(uiImage: defaultHead)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                                .stroke(YZLTheme.border, lineWidth: 1)
                        )
                } else {
                    // 最终兜底：系统图标。
                    ZStack {
                        Circle()
                            .fill(YZLTheme.accentSoft)
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: size * 0.42, weight: .light))
                            .foregroundStyle(YZLTheme.accent.opacity(0.6))
                    }
                    .frame(width: size, height: size)
                    .overlay(Circle().stroke(YZLTheme.border, lineWidth: 1))
                }
            }
        }
        .task(id: skinReference) {
            await reload()
        }
    }

    /// 加载内置默认皮肤并裁出头像。
    private var defaultHead: UIImage? {
        guard let skin = Skin3DModel.defaultSkin(model: defaultModel),
              let head = SkinTexture.head(from: skin, targetSize: size * 3) else {
            return nil
        }
        return head
    }

    /// 账号或皮肤地址变化时重新取图；先清空旧图，避免切换账号时闪现上一个账号的皮肤。
    /// `yzl-local-skin://` 引用一律只读本地文件，绝不对自定义 scheme 发网络请求。
    @MainActor
    private func reload() async {
        texture = nil
        guard let raw = skinReference, let url = URL(string: raw) else { return }
        if url.scheme?.lowercased() == LocalSkinStore.scheme {
            texture = LocalSkinStore().load(from: url)
            return
        }
        texture = await SkinTexture.load(from: url)
    }
}

/// 主页大头像：与 AvatarView 相同渲染，只是尺寸更大。
struct PclAvatarView: View {
    let size: CGFloat
    let account: MicrosoftAccount?
    var defaultModel: String = "steve"

    var body: some View {
        AvatarView(size: size, account: account, defaultModel: defaultModel)
    }
}
