import SwiftUI
import UIKit

/// PCL 风格 2D 像素头像渲染器（逐行对照 Android 端 `PclAvatarRenderer`）：
/// 脸层（皮肤 8,8 起 8×8）放大到 48×48 居中；帽层（皮肤 40,8 起 8×8）放大到
/// 56×56 压在脸层上；裁 56×56 后四边加 2px 透明边，再对轮廓填 `#AEB8C6` 1px 描边。
/// 全程最近邻采样（锐利像素风），无背景板、无圆角——与 Android 主页大头像完全一致。
enum PclAvatarRenderer {
    static let outlineColor = UIColor(red: 0xAE / 255.0, green: 0xB8 / 255.0, blue: 0xC6 / 255.0, alpha: 1)

    /// 生成 PCL 风格头像；贴图无法解码时返回 nil（调用方用占位）。
    static func render(skin: UIImage) -> UIImage? {
        guard let base = normalizedBase(skin) else { return nil }
        let scale = base.width / 64
        let compositeSize = 56 * scale   // 裁剪后的头（含帽层）
        let outputSize = 60 * scale      // 四边各加 2px 描边余量
        let origin = 2 * scale           // 合成图在输出画布中的偏移

        guard let output = makeContext(size: outputSize), let outData = output.data else { return nil }
        output.interpolationQuality = .none

        // 脸层：源 (8,8,8,8) → 逻辑 (8,8)-(56,56)；输出画布原点对应逻辑 (4,4)，落点即 (4s, 4s)。
        if let face = base.cropping(to: CGRect(x: 8 * scale, y: 8 * scale, width: 8 * scale, height: 8 * scale)) {
            output.draw(face, in: CGRect(x: origin + 4 * scale, y: origin + 4 * scale,
                                         width: 48 * scale, height: 48 * scale))
        }
        // 帽层：源 (40,8,8,8) → 逻辑 (4,4)-(60,60)，即画布 (0,0) 起 56s。64×32 旧皮肤没有帽层。
        if base.height >= 64 {
            if let hat = base.cropping(to: CGRect(x: 40 * scale, y: 8 * scale, width: 8 * scale, height: 8 * scale)) {
                output.draw(hat, in: CGRect(x: origin, y: origin, width: 56 * scale, height: 56 * scale))
            }
        }

        let buffer = outData.bindMemory(to: UInt8.self, capacity: outputSize * outputSize * 4)

        // 先给合成区域拍 alpha 快照：描边只能基于「原始合成内容」判定，
        // 否则先画出的描边像素会被后面的邻居判定当成实体，轮廓会向外扩散一圈。
        var alphaMap = [Bool](repeating: false, count: compositeSize * compositeSize)
        for y in 0..<compositeSize {
            for x in 0..<compositeSize {
                alphaMap[y * compositeSize + x] = buffer[((y + origin) * outputSize + (x + origin)) * 4 + 3] != 0
            }
        }

        func opaque(_ cx: Int, _ cy: Int) -> Bool {
            guard cx >= 0, cx < compositeSize, cy >= 0, cy < compositeSize else { return false }
            return alphaMap[cy * compositeSize + cx]
        }

        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        outlineColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        for y in 0..<outputSize {
            for x in 0..<outputSize {
                let offset = (y * outputSize + x) * 4
                guard buffer[offset + 3] == 0 else { continue }
                let cx = x - origin
                let cy = y - origin
                var touches = false
                search: for dy in -1...1 {
                    for dx in -1...1 {
                        if opaque(cx + dx, cy + dy) {
                            touches = true
                            break search
                        }
                    }
                }
                guard touches else { continue }
                buffer[offset] = UInt8((red * 255).rounded())
                buffer[offset + 1] = UInt8((green * 255).rounded())
                buffer[offset + 2] = UInt8((blue * 255).rounded())
                buffer[offset + 3] = 255
            }
        }

        guard let outlined = output.makeImage() else { return nil }
        return UIImage(cgImage: outlined)
    }

    /// 归一化：宽 ≥64 且是 64 的倍数、高 ∈ {32, 64, =宽} 的贴图原样保留，其余缩放到 64×64。
    static func normalizedBase(_ image: UIImage) -> CGImage? {
        guard let cg = image.cgImage else { return nil }
        let rgba = toRGBA(cg)
        let width = cg.width
        let height = cg.height
        if width >= 64, width % 64 == 0, height == 32 || height == 64 || height == width {
            return rgba
        }
        guard let ctx = makeContext(size: 64) else { return rgba }
        ctx.interpolationQuality = .none
        ctx.draw(rgba, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()
    }

    private static func toRGBA(_ image: CGImage) -> CGImage {
        // 上下文必须按图片实际尺寸建（64×32 旧皮肤是非正方形的，正方形上下文会破坏内容）。
        guard let ctx = makeContext(width: max(1, image.width), height: max(1, image.height)) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    private static func makeContext(size: Int) -> CGContext? {
        makeContext(width: size, height: size)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}

// MARK: - SwiftUI 视图

/// 主页大头像：PCL 风格 2D 像素合成（无底板、无圆角，与 Android 端一致）。
struct PclAvatarView: View {
    let size: CGFloat
    let account: MicrosoftAccount?

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

    /// 无皮肤时的占位：用程序化默认皮肤直接渲一遍 PCL 头像。
    private var placeholder: UIImage {
        if let cached = Self.placeholderImage { return cached }
        let generated = PclAvatarRenderer.render(skin: Skin3DModel.defaultSkin()) ?? UIImage()
        Self.placeholderImage = generated
        return generated
    }

    private static var placeholderImage: UIImage?

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
        rendered = PclAvatarRenderer.render(skin: texture) ?? PclAvatarRenderer.render(skin: Skin3DModel.defaultSkin())
    }
}
