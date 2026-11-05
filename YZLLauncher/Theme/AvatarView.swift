import SwiftUI
import UIKit

enum SkinTexture {
    /// Mojang 皮肤贴图（新版 64×64、旧版 64×32）的头部 8×8 像素固定在 (8,8)。
    /// 返回按实际贴图宽度缩放后的裁剪框；贴图太小则视为无效。
    static func headCrop(width: Int, height: Int) -> CGRect? {
        guard width >= 16, height >= 16 else { return nil }
        let ratio = CGFloat(width) / 64.0
        guard ratio > 0 else { return nil }
        return CGRect(x: 8 * ratio, y: 8 * ratio, width: 8 * ratio, height: 8 * ratio)
    }

    /// 本地裁出头部并放大，不经过任何第三方头像服务。
    static func head(from texture: UIImage, targetSize: CGFloat) -> UIImage? {
        guard let cgImage = texture.cgImage,
              let crop = headCrop(width: cgImage.width, height: cgImage.height),
              let cropped = cgImage.cropping(to: crop) else {
            return nil
        }

        let side = max(1, Int(targetSize.rounded()))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { context in
            // Swift 的 CGContext 用属性赋值；ObjC 里那个同名 C 函数在此不可用。
            context.cgContext.interpolationQuality = .none
            UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// 异步拉取皮肤贴图。裁剪头部需要 UIImage 的像素数据，
    /// 而 AsyncImage 的 phase.image 是 SwiftUI.Image，无法转换为 UIImage。
    /// 这里只走 Mojang 官方贴图地址，不把玩家信息发给第三方头像服务。
    static func load(from url: URL) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                return nil
            }
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}

/// 用户真实 Minecraft 皮肤头像，登录后可显示；未登录时用干净的占位头像。
struct AvatarView: View {
    let size: CGFloat
    let account: MicrosoftAccount?

    @State private var texture: UIImage?

    private var skinURL: String? { account?.skinURL }

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
                placeholder
            }
        }
        .task(id: skinURL) {
            await reloadTexture()
        }
    }

    /// 账号或皮肤地址变化时重新取图；任务被 SwiftUI 自动取消，不会写回旧头像。
    @MainActor
    private func reloadTexture() async {
        texture = nil
        guard let raw = skinURL, let url = URL(string: raw) else { return }
        texture = await SkinTexture.load(from: url)
    }

    private var placeholder: some View {
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

/// 展示整张 64×64 皮肤贴图（纹理表，不是立体模型）。
struct SkinBodyView: View {
    let size: CGFloat
    let account: MicrosoftAccount?

    var body: some View {
        if let account, let url = URL(string: account.skinURL ?? "") {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .interpolation(.none)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    AvatarView(size: size, account: account)
                }
            }
        } else {
            AvatarView(size: size, account: account)
        }
    }
}
