import SwiftUI
import UIKit

/// 全端统一头像（PCL 同款 2D）：`AvatarView` 现在只是 `PclAvatarView` 的别名，
/// 定义在 Theme/AvatarView.swift。这里只保留主页大头像的真实实现，
/// 不再有第二份「裁 8×8 头部放大」的旧渲染，避免同名类型和样式分叉。

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
