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
    /// `Skin3DModel.defaultSkin(model:)` 返回非 Optional 的 UIImage（找不到内置
    /// 皮肤时会退回程序化生成的兜底图），所以不能对它用 `guard let`。
    private var defaultHead: UIImage? {
        let skin = Skin3DModel.defaultSkin(model: defaultModel)
        guard let head = SkinTexture.head(from: skin, targetSize: size * 3) else {
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

// MARK: - SwiftUI 视图

/// 主页大头像：PCL 风格 2D 像素合成（无底板、无圆角，与 Android 端一致）。
struct PclAvatarView: View {
    let size: CGFloat
    let account: MicrosoftAccount?
    /// 无自定义皮肤时的默认皮肤模型："steve" / "alex"。
    var defaultModel: String = "steve"

    @State private var rendered: UIImage?

    private var skinReference: String? { account?.skinURL }

    var body: some View {
        Image(uiImage: rendered ?? placeholder)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(width: size, height: size)
            .task(id: skinReference) {
                await reload()
            }
    }

    /// 无皮肤时的占位：内置真 Steve / Alex 默认皮肤渲一遍 PCL 头像。
    private var placeholder: UIImage {
        let key = defaultModel
        if let cached = Self.placeholderCache[key] { return cached }
        let generated = PclAvatarRenderer.render(skin: Skin3DModel.defaultSkin(model: key)) ?? UIImage()
        Self.placeholderCache[key] = generated
        return generated
    }

    private static var placeholderCache: [String: UIImage] = [:]

    @MainActor
    private func reload() async {
        rendered = nil
        guard let raw = skinReference, let url = URL(string: raw) else { return }
        let texture: UIImage?
        if url.scheme?.lowercased() == LocalSkinStore.scheme {
            // 自定义 scheme 一律只读本地文件，绝不对它发网络请求。
            texture = LocalSkinStore().load(from: url)
        } else {
            texture = await SkinTexture.load(from: url)
        }
        guard let texture else { return }
        rendered = PclAvatarRenderer.render(skin: texture)
            ?? PclAvatarRenderer.render(skin: Skin3DModel.defaultSkin(model: defaultModel))
    }
}
