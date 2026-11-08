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

    /// Mojang 档案返回的贴图地址是 **http://**（明文），iOS 的 ATS 会直接拦截该请求，
    /// 导致正版登录后皮肤永远加载失败（Windows / Android 无此限制）。
    /// 已知支持 TLS 的贴图域名统一升级 https；其它皮肤站的 http 地址不动
    /// （部分 authlib 皮肤站的存储不支持 https，盲目升级反而打不开）。
    static func upgradedToHTTPS(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http" else { return url }
        let host = url.host?.lowercased() ?? ""
        let tlsHosts = ["textures.minecraft.net", "storage.littleskin.cn"]
        guard tlsHosts.contains(host) else { return url }
        return URL(string: "https://" + url.absoluteString.dropFirst("http://".count)) ?? url
    }

    /// 异步拉取皮肤贴图。裁剪头部需要 UIImage 的像素数据，
    /// 而 AsyncImage 的 phase.image 是 SwiftUI.Image，无法转换为 UIImage。
    /// 这里只走 Mojang 官方贴图地址，不把玩家信息发给第三方头像服务。
    static func load(from url: URL) async -> UIImage? {
        let upgraded = upgradedToHTTPS(url)
        do {
            let (data, response) = try await URLSession.shared.data(from: upgraded)
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

/// 用户真实 Minecraft 皮肤头像：与主页大头像同一条 PCL 渲染链
/// （脸层 + 帽层 + 灰描边），保证侧栏 / 账号页 / 设置页与主页完全一致。
/// 未登录或无皮肤时显示内置真 Steve 默认皮肤。
struct AvatarView: View {
    let size: CGFloat
    let account: MicrosoftAccount?
    /// 无自定义皮肤时的默认皮肤模型："steve" / "alex"。
    var defaultModel: String = "steve"

    var body: some View {
        PclAvatarView(size: size, account: account, defaultModel: defaultModel)
    }
}

/// 展示整张皮肤贴图（纹理表，不是立体模型）。
/// 统一走 UIImage 加载，才能按贴图原始比例渲染：旧皮肤是 64×32（2:1），
/// 强制塞进正方形 frame 会把整张纹理表纵向拉伸 2 倍。
struct SkinBodyView: View {
    let size: CGFloat
    let account: MicrosoftAccount?

    @State private var texture: UIImage?

    private var skinReference: String? { account?.skinURL }

    var body: some View {
        Group {
            if let texture {
                Image(uiImage: texture)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                AvatarView(size: size, account: account)
            }
        }
        .task(id: skinReference) {
            await reload()
        }
    }

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
