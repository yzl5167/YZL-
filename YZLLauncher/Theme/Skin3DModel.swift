import UIKit

/// 纯软件 3D 皮肤渲染器，逐行照 Android 端 `skin/Skin3DModel.kt` 移植：
/// 把 64×64 皮肤拆成头/身体/手臂/腿的基础层与帽子/外套/袖子/裤子的叠加层，
/// 做 Y/X 轴旋转、四肢走路摆动、深度排序（画家算法）与面光照，输出到 CGContext。
///
/// 与 Android 的差异只有一处实现方式：Android 用 ColorMatrix 缩放每个面的 RGB，
/// 这里在**构建期**把光照乘进面贴图像素（面都只有几个像素大，一次性的代价），
/// 绘制期就是纯仿射 blit，正交投影下每个面恰好是平行四边形。
final class Skin3DModel {
    struct Vec3 {
        var x: CGFloat
        var y: CGFloat
        var z: CGFloat
    }

    private enum Limb {
        case head, body, armR, armL, legR, legL
    }

    private enum FaceKind {
        case front, back, right, left, top, bottom
    }

    /// 一个部件六面的 UV 框（64×64 皮肤坐标，1×2/1×1 像素框也按 CGRect 表达）。
    struct TexSet {
        let top: CGRect
        let bottom: CGRect
        let right: CGRect
        let front: CGRect
        let left: CGRect
        let back: CGRect
    }

    private struct Face {
        let image: CGImage
        let corners: [Vec3]
        let limb: Limb
        let pivot: Vec3?
    }

    let headOnly: Bool
    private let faces: [Face]

    // MARK: - 构建

    /// `model` 传 "alex" 用纤细手臂（slim），其余（含 "steve" / "custom"）用经典手臂。
    /// 非 64×32 / 64×64 / 128×128 的贴图会缩放到 64×64（与 Android 端一致）。
    init?(skin: UIImage?, model: String, headOnly: Bool = false) {
        guard let skin, let base = Self.normalizedBase(skin) else { return nil }

        let slim = model == "alex"
        let unit = CGFloat(base.width) / 64.0
        let legacy = base.height < 64
        var faces: [Face] = []

        func crop(_ rect: CGRect, shade: CGFloat) -> CGImage? {
            Self.croppedFace(from: base, rect: rect, unit: unit, shade: shade)
        }

        func addFace(_ corners: [Vec3], _ image: CGImage?, _ limb: Limb, _ pivot: Vec3?) {
            guard let image else { return }
            faces.append(Face(image: image, corners: corners, limb: limb, pivot: pivot))
        }

        func addPart(_ cx: CGFloat, _ cy: CGFloat, _ cz: CGFloat,
                     _ w: CGFloat, _ h: CGFloat, _ d: CGFloat,
                     _ baseTex: TexSet?, _ overlayTex: TexSet?,
                     _ grow: CGFloat, _ limb: Limb) {
            let pivot: Vec3?
            switch limb {
            case .armR, .armL: pivot = Vec3(x: cx, y: 24, z: cz)
            case .legR, .legL: pivot = Vec3(x: cx, y: 12, z: cz)
            default: pivot = nil
            }

            if let baseTex {
                let hx = w / 2, hy = h / 2, hz = d / 2
                addFace(Self.partCorners(.front, cx, cy, cz, hx, hy, hz), crop(baseTex.front, shade: Self.SHADE_FRONT), limb, pivot)
                addFace(Self.partCorners(.back, cx, cy, cz, hx, hy, hz), crop(baseTex.back, shade: Self.SHADE_BACK), limb, pivot)
                addFace(Self.partCorners(.right, cx, cy, cz, hx, hy, hz), crop(baseTex.right, shade: Self.SHADE_RIGHT), limb, pivot)
                addFace(Self.partCorners(.left, cx, cy, cz, hx, hy, hz), crop(baseTex.left, shade: Self.SHADE_LEFT), limb, pivot)
                addFace(Self.partCorners(.top, cx, cy, cz, hx, hy, hz), crop(baseTex.top, shade: Self.SHADE_TOP), limb, pivot)
                addFace(Self.partCorners(.bottom, cx, cy, cz, hx, hy, hz), crop(baseTex.bottom, shade: Self.SHADE_BOTTOM), limb, pivot)
            }
            // 64×32 旧版皮肤没有叠加层纹理。
            if !legacy, let overlayTex, grow > 0 {
                let hx = w / 2 + grow, hy = h / 2 + grow, hz = d / 2 + grow
                addFace(Self.partCorners(.front, cx, cy, cz, hx, hy, hz), crop(overlayTex.front, shade: 1.00), limb, pivot)
                addFace(Self.partCorners(.back, cx, cy, cz, hx, hy, hz), crop(overlayTex.back, shade: 0.90), limb, pivot)
                addFace(Self.partCorners(.right, cx, cy, cz, hx, hy, hz), crop(overlayTex.right, shade: 0.94), limb, pivot)
                addFace(Self.partCorners(.left, cx, cy, cz, hx, hy, hz), crop(overlayTex.left, shade: 0.82), limb, pivot)
                addFace(Self.partCorners(.top, cx, cy, cz, hx, hy, hz), crop(overlayTex.top, shade: 1.00), limb, pivot)
                addFace(Self.partCorners(.bottom, cx, cy, cz, hx, hy, hz), crop(overlayTex.bottom, shade: 0.70), limb, pivot)
            }
        }

        let headY: CGFloat = headOnly ? 0 : 28
        addPart(0, headY, 0, 8, 8, 8, Self.TEX_HEAD, legacy ? nil : Self.TEX_HEAD_OVER, 0.55, .head)
        if !headOnly {
            addPart(0, 18, 0, 8, 12, 4, Self.TEX_BODY, legacy ? nil : Self.TEX_BODY_OVER, 0.30, .body)
            if slim {
                addPart(-5.5, 18, 0, 3, 12, 4, Self.TEX_ARM_R_SLIM, legacy ? nil : Self.TEX_ARM_R_SLIM_OVER, 0.25, .armR)
                addPart(5.5, 18, 0, 3, 12, 4, Self.TEX_ARM_L_SLIM, legacy ? nil : Self.TEX_ARM_L_SLIM_OVER, 0.25, .armL)
            } else {
                addPart(-6, 18, 0, 4, 12, 4, Self.TEX_ARM_R, legacy ? nil : Self.TEX_ARM_R_OVER, 0.25, .armR)
                addPart(6, 18, 0, 4, 12, 4, Self.TEX_ARM_L, legacy ? nil : Self.TEX_ARM_L_OVER, 0.25, .armL)
            }
            if legacy {
                // 旧版皮肤没有左腿纹理，两侧腿都复用右腿贴图。
                addPart(-2, 6, 0, 4, 12, 4, Self.TEX_LEG_R, nil, 0, .legR)
                addPart(2, 6, 0, 4, 12, 4, Self.TEX_LEG_R, nil, 0, .legL)
            } else {
                addPart(-2, 6, 0, 4, 12, 4, Self.TEX_LEG_R, Self.TEX_LEG_R_OVER, 0.25, .legR)
                addPart(2, 6, 0, 4, 12, 4, Self.TEX_LEG_L, Self.TEX_LEG_L_OVER, 0.25, .legL)
            }
        }

        self.faces = faces
        self.headOnly = headOnly
    }

    // MARK: - 绘制

    /// 把模型画进给定的 CGContext（UIGraphicsImageRenderer 的 y 向下坐标系，与 Android Canvas 一致）。
    func draw(into context: CGContext, size: CGSize,
              yawDeg: CGFloat, pitchDeg: CGFloat, walkPhase: CGFloat = 0) {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return }

        let yaw = yawDeg * .pi / 180
        let pitch = pitchDeg * .pi / 180
        let cosY = cos(yaw), sinY = sin(yaw)
        let cosP = cos(pitch), sinP = sin(pitch)
        let pivotY: CGFloat = headOnly ? 0 : 16
        let scale: CGFloat = headOnly
            ? min(width, height) / 11.2
            : min(width / 22.5, height / 37.5)
        let cx = width / 2
        let cy = height / 2 + (headOnly ? 0 : height * 0.015)

        let legAngle = sin(walkPhase) * 26 * .pi / 180
        let armAngle = sin(walkPhase) * 22 * .pi / 180

        struct Projected {
            let face: Face
            let points: [CGPoint]
            let z: CGFloat
        }

        let projected: [Projected] = faces.map { face in
            var sumZ: CGFloat = 0
            var points: [CGPoint] = []
            points.reserveCapacity(4)

            let swing: CGFloat
            switch face.limb {
            case .legR: swing = -legAngle
            case .legL: swing = legAngle
            case .armR: swing = armAngle
            case .armL: swing = -armAngle
            default: swing = 0
            }
            let swingCos = cos(swing), swingSin = sin(swing)

            for corner in face.corners {
                var vx = corner.x
                var vy = corner.y
                var vz = corner.z
                if let pivot = face.pivot, swing != 0 {
                    let dy = vy - pivot.y
                    let dz = vz - pivot.z
                    vy = pivot.y + dy * swingCos - dz * swingSin
                    vz = pivot.z + dy * swingSin + dz * swingCos
                }
                let x1 = vx * cosY + vz * sinY
                let z1 = -vx * sinY + vz * cosY
                let y1 = (vy - pivotY) * cosP - z1 * sinP
                let z2 = (vy - pivotY) * sinP + z1 * cosP
                points.append(CGPoint(x: cx + x1 * scale, y: cy - y1 * scale))
                sumZ += z2
            }
            return Projected(face: face, points: points, z: sumZ / CGFloat(face.corners.count))
        }.sorted { $0.z < $1.z }

        context.setAllowsAntialiasing(true)
        for item in projected {
            let image = item.face.image
            let w = CGFloat(image.width)
            let h = CGFloat(image.height)
            guard w > 0, h > 0 else { continue }
            let p = item.points
            // 纹理 (0,0)/(w,0)/(0,h) → 角点 0/1/3：正交投影下面是平行四边形，
            // 三个角唯一确定仿射变换（Android setPolyToPoly 的 3 点模式）。
            let transform = CGAffineTransform(
                a: (p[1].x - p[0].x) / w,
                b: (p[1].y - p[0].y) / w,
                c: (p[3].x - p[0].x) / h,
                d: (p[3].y - p[0].y) / h,
                tx: p[0].x,
                ty: p[0].y
            )
            context.saveGState()
            context.concatenate(transform)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            context.restoreGState()
        }
    }

    /// 便捷入口：渲成 UIImage（单测与静态预览用）。
    /// 显式 scale 1：像素级断言与画布坐标都按 1:1 假设，不能跟设备 scale 走。
    static func renderImage(skin: UIImage, model: String, headOnly: Bool = false,
                            size: CGSize, yawDeg: CGFloat = 0, pitchDeg: CGFloat = 4,
                            walkPhase: CGFloat = 0) -> UIImage? {
        guard let model3d = Skin3DModel(skin: skin, model: model, headOnly: headOnly) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            model3d.draw(into: context.cgContext, size: size,
                         yawDeg: yawDeg, pitchDeg: pitchDeg, walkPhase: walkPhase)
        }
    }

    // MARK: - 面光照常量（与 Android 端一致）

    private static let SHADE_FRONT: CGFloat = 1.00
    private static let SHADE_BACK: CGFloat = 0.84
    private static let SHADE_RIGHT: CGFloat = 0.90
    private static let SHADE_LEFT: CGFloat = 0.76
    private static let SHADE_TOP: CGFloat = 0.98
    private static let SHADE_BOTTOM: CGFloat = 0.64

    // MARK: - 位图处理

    /// 归一化成 RGBA8 的 CGImage；尺寸不在 64×32 / 64×64 / 128×128 内则缩放到 64×64。
    static func normalizedBase(_ image: UIImage) -> CGImage? {
        guard let cg = image.cgImage else { return nil }
        let rgba = toRGBA(cg)
        if cg.width == 64 && (cg.height == 32 || cg.height == 64) { return rgba }
        if cg.width == 128 && cg.height == 128 { return rgba }
        guard let ctx = makeContext(width: 64, height: 64) else { return rgba }
        ctx.interpolationQuality = .none
        ctx.draw(rgba, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()
    }

    /// 裁出 UV 框对应的面，烘焙面光照后返回；全透明或越界的面返回 nil。
    static func croppedFace(from base: CGImage, rect: CGRect, unit: CGFloat, shade: CGFloat) -> CGImage? {
        let left = Int(rect.minX * unit)
        let top = Int(rect.minY * unit)
        let w = Int(rect.width * unit)
        let h = Int(rect.height * unit)
        guard w > 0, h > 0, left >= 0, top >= 0,
              left + w <= base.width, top + h <= base.height,
              let cropped = base.cropping(to: CGRect(x: left, y: top, width: w, height: h)) else {
            return nil
        }
        guard hasVisiblePixels(cropped) else { return nil }
        guard shade < 0.9999 else { return cropped }
        return shaded(cropped, shade: shade)
    }

    private static func shaded(_ image: CGImage, shade: CGFloat) -> CGImage {
        guard let ctx = makeContext(width: image.width, height: image.height),
              let data = ctx.data else {
            return image
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let count = image.width * image.height * 4
        let buffer = data.bindMemory(to: UInt8.self, capacity: count)
        // 预乘 alpha 的像素把 RGB 乘 shade 后依然满足预乘约束（a 不变）。
        for offset in stride(from: 0, to: count, by: 4) {
            buffer[offset] = UInt8((Double(buffer[offset]) * shade).rounded())
            buffer[offset + 1] = UInt8((Double(buffer[offset + 1]) * shade).rounded())
            buffer[offset + 2] = UInt8((Double(buffer[offset + 2]) * shade).rounded())
        }
        return ctx.makeImage() ?? image
    }

    private static func hasVisiblePixels(_ image: CGImage) -> Bool {
        guard let ctx = makeContext(width: image.width, height: image.height),
              let data = ctx.data else {
            return true
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let buffer = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        var y = 0
        while y < image.height {
            var x = 0
            while x < image.width {
                if buffer[(y * image.width + x) * 4 + 3] != 0 { return true }
                x += 2
            }
            y += 2
        }
        return false
    }

    private static func toRGBA(_ image: CGImage) -> CGImage {
        guard let ctx = makeContext(width: image.width, height: image.height) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
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

    // MARK: - 部件几何

    /// 一个面在部件局部坐标里的 4 个角点（顺序 = 纹理左上、右上、右下、左下）。
    private static func partCorners(_ kind: FaceKind, _ cx: CGFloat, _ cy: CGFloat, _ cz: CGFloat,
                                    _ hx: CGFloat, _ hy: CGFloat, _ hz: CGFloat) -> [Vec3] {
        func v(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> Vec3 {
            Vec3(x: cx + x, y: cy + y, z: cz + z)
        }
        switch kind {
        case .front:
            return [v(-hx, hy, hz), v(hx, hy, hz), v(hx, -hy, hz), v(-hx, -hy, hz)]
        case .back:
            return [v(hx, hy, -hz), v(-hx, hy, -hz), v(-hx, -hy, -hz), v(hx, -hy, -hz)]
        case .right:
            return [v(hx, hy, -hz), v(hx, hy, hz), v(hx, -hy, hz), v(hx, -hy, -hz)]
        case .left:
            return [v(-hx, hy, hz), v(-hx, hy, -hz), v(-hx, -hy, -hz), v(-hx, -hy, hz)]
        case .top:
            return [v(-hx, hy, -hz), v(hx, hy, -hz), v(hx, hy, hz), v(-hx, hy, hz)]
        case .bottom:
            return [v(-hx, -hy, hz), v(hx, -hy, hz), v(hx, -hy, -hz), v(-hx, -hy, -hz)]
        }
    }

    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - UV 表（与 Android 端 TexSet 逐项一致，64×64 皮肤坐标）

    static let TEX_HEAD = TexSet(
        top: rect(8, 0, 8, 8), bottom: rect(16, 0, 8, 8),
        right: rect(0, 8, 8, 8), front: rect(8, 8, 8, 8),
        left: rect(16, 8, 8, 8), back: rect(24, 8, 8, 8)
    )
    static let TEX_HEAD_OVER = TexSet(
        top: rect(40, 0, 8, 8), bottom: rect(48, 0, 8, 8),
        right: rect(32, 8, 8, 8), front: rect(40, 8, 8, 8),
        left: rect(48, 8, 8, 8), back: rect(56, 8, 8, 8)
    )
    static let TEX_BODY = TexSet(
        top: rect(20, 16, 8, 4), bottom: rect(28, 16, 8, 4),
        right: rect(16, 20, 4, 12), front: rect(20, 20, 8, 12),
        left: rect(28, 20, 4, 12), back: rect(32, 20, 8, 12)
    )
    static let TEX_BODY_OVER = TexSet(
        top: rect(20, 32, 8, 4), bottom: rect(28, 32, 8, 4),
        right: rect(16, 36, 4, 12), front: rect(20, 36, 8, 12),
        left: rect(28, 36, 4, 12), back: rect(32, 36, 8, 12)
    )
    static let TEX_ARM_R = TexSet(
        top: rect(44, 16, 4, 4), bottom: rect(48, 16, 4, 4),
        right: rect(40, 20, 4, 12), front: rect(44, 20, 4, 12),
        left: rect(48, 20, 4, 12), back: rect(52, 20, 4, 12)
    )
    static let TEX_ARM_R_OVER = TexSet(
        top: rect(44, 32, 4, 4), bottom: rect(48, 32, 4, 4),
        right: rect(40, 36, 4, 12), front: rect(44, 36, 4, 12),
        left: rect(48, 36, 4, 12), back: rect(52, 36, 4, 12)
    )
    static let TEX_ARM_L = TexSet(
        top: rect(36, 48, 4, 4), bottom: rect(40, 48, 4, 4),
        right: rect(32, 52, 4, 12), front: rect(36, 52, 4, 12),
        left: rect(40, 52, 4, 12), back: rect(44, 52, 4, 12)
    )
    static let TEX_ARM_L_OVER = TexSet(
        top: rect(52, 48, 4, 4), bottom: rect(56, 48, 4, 4),
        right: rect(48, 52, 4, 12), front: rect(52, 52, 4, 12),
        left: rect(56, 52, 4, 12), back: rect(60, 52, 4, 12)
    )
    static let TEX_ARM_R_SLIM = TexSet(
        top: rect(44, 16, 3, 4), bottom: rect(47, 16, 3, 4),
        right: rect(40, 20, 4, 12), front: rect(44, 20, 3, 12),
        left: rect(47, 20, 4, 12), back: rect(51, 20, 3, 12)
    )
    static let TEX_ARM_R_SLIM_OVER = TexSet(
        top: rect(44, 32, 3, 4), bottom: rect(47, 32, 3, 4),
        right: rect(40, 36, 4, 12), front: rect(44, 36, 3, 12),
        left: rect(47, 36, 4, 12), back: rect(51, 36, 3, 12)
    )
    static let TEX_ARM_L_SLIM = TexSet(
        top: rect(36, 48, 3, 4), bottom: rect(39, 48, 3, 4),
        right: rect(32, 52, 4, 12), front: rect(36, 52, 3, 12),
        left: rect(39, 52, 4, 12), back: rect(43, 52, 3, 12)
    )
    static let TEX_ARM_L_SLIM_OVER = TexSet(
        top: rect(52, 48, 3, 4), bottom: rect(55, 48, 3, 4),
        right: rect(48, 52, 4, 12), front: rect(52, 52, 3, 12),
        left: rect(55, 52, 4, 12), back: rect(59, 52, 3, 12)
    )
    static let TEX_LEG_R = TexSet(
        top: rect(4, 16, 4, 4), bottom: rect(8, 16, 4, 4),
        right: rect(0, 20, 4, 12), front: rect(4, 20, 4, 12),
        left: rect(8, 20, 4, 12), back: rect(12, 20, 4, 12)
    )
    static let TEX_LEG_R_OVER = TexSet(
        top: rect(4, 32, 4, 4), bottom: rect(8, 32, 4, 4),
        right: rect(0, 36, 4, 12), front: rect(4, 36, 4, 12),
        left: rect(8, 36, 4, 12), back: rect(12, 36, 4, 12)
    )
    static let TEX_LEG_L = TexSet(
        top: rect(20, 48, 4, 4), bottom: rect(24, 48, 4, 4),
        right: rect(16, 52, 4, 12), front: rect(20, 52, 4, 12),
        left: rect(24, 52, 4, 12), back: rect(28, 52, 4, 12)
    )
    static let TEX_LEG_L_OVER = TexSet(
        top: rect(4, 48, 4, 4), bottom: rect(8, 48, 4, 4),
        right: rect(0, 52, 4, 12), front: rect(4, 52, 4, 12),
        left: rect(8, 52, 4, 12), back: rect(12, 52, 4, 12)
    )

    // MARK: - 默认皮肤

    /// 内置真 Steve / Alex 皮肤（从官方客户端 jar 提取，与 Android 端
    /// default_steve.png / default_alex.png 资产同源），资源缺失时回退程序化皮肤。
    static func defaultSkin(model: String = "steve") -> UIImage {
        if let embedded = embeddedDefaultSkin(model: model) {
            return embedded
        }
        return programmaticFallbackSkin()
    }

    /// Bundle 感知加载：独立 App 资源在主 bundle，M2-b fork 外壳编译进
    /// YZLUI.framework、资源在 framework bundle（与 YZLTheme.icon 同一套路）。
    static func embeddedDefaultSkin(model: String) -> UIImage? {
        let name = model == "alex" ? "default_alex" : "default_steve"
        if let image = UIImage(named: name, in: Bundle(for: BundleToken.self), compatibleWith: nil) {
            return image
        }
        if let image = UIImage(named: name, in: .main, compatibleWith: nil) {
            return image
        }
        return nil
    }

    private final class BundleToken {}

    /// 资源缺失时的应急程序化皮肤（正常情况不会走到这里）。
    private static func programmaticFallbackSkin() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cg = context.cgContext
            // 透明底
            cg.clear(CGRect(x: 0, y: 0, width: 64, height: 64))

            func fill(_ rect: CGRect, _ color: UIColor) {
                cg.setFillColor(color.cgColor)
                cg.fill(rect)
            }

            let skinTone = UIColor(red: 0.976, green: 0.769, blue: 0.608, alpha: 1)
            let hair = UIColor(red: 0.243, green: 0.145, blue: 0.078, alpha: 1)
            let shirt = UIColor(red: 0.0, green: 0.686, blue: 0.678, alpha: 1)
            let pants = UIColor(red: 0.271, green: 0.243, blue: 0.658, alpha: 1)
            let shoes = UIColor(red: 0.353, green: 0.220, blue: 0.125, alpha: 1)

            // 头：整块肤色 + 头发盖顶 + 简单的脸
            fill(CGRect(x: 8, y: 0, width: 24, height: 8), hair)
            fill(CGRect(x: 0, y: 8, width: 32, height: 8), skinTone)
            fill(CGRect(x: 9, y: 12, width: 2, height: 2), UIColor(red: 0.271, green: 0.412, blue: 0.851, alpha: 1))
            fill(CGRect(x: 13, y: 12, width: 2, height: 2), UIColor(red: 0.271, green: 0.412, blue: 0.851, alpha: 1))
            fill(CGRect(x: 11, y: 14, width: 2, height: 1), UIColor(red: 0.643, green: 0.478, blue: 0.376, alpha: 1))
            // 身体（基础层 16..40，含正反面 20..40）
            fill(CGRect(x: 16, y: 16, width: 24, height: 16), shirt)
            // 手臂（经典 4 宽）
            fill(CGRect(x: 40, y: 16, width: 16, height: 16), shirt)
            fill(CGRect(x: 40, y: 20, width: 16, height: 12), skinTone)
            // 腿
            fill(CGRect(x: 0, y: 16, width: 16, height: 16), pants)
            fill(CGRect(x: 4, y: 28, width: 8, height: 4), shoes)
            // 左腿 / 左臂（64×64 布局）
            fill(CGRect(x: 16, y: 48, width: 16, height: 16), pants)
            fill(CGRect(x: 20, y: 60, width: 8, height: 4), shoes)
            fill(CGRect(x: 32, y: 48, width: 16, height: 16), shirt)
            fill(CGRect(x: 32, y: 52, width: 16, height: 12), skinTone)
        }
    }
}
