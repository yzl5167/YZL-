import XCTest
import UIKit
@testable import YZLLauncher

/// PCL 风格 2D 头像渲染：脸层/帽层合成、灰描边、归一化与占位。
final class PclAvatarTests: XCTestCase {
    /// 造 scale=1 的皮肤贴图（UIGraphicsImageRenderer 默认带设备 scale，必须显式 1）。
    private func skin(_ painter: (CGContext) -> Void, width: Int = 64, height: Int = 64) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            painter(context.cgContext)
        }
    }

    private func fill(_ cg: CGContext, _ rect: CGRect, _ color: UIColor) {
        cg.setFillColor(color.cgColor)
        cg.fill(rect)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let ctx = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let buffer = ctx.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        let offset = (y * image.width + x) * 4
        return (Int(buffer[offset]), Int(buffer[offset + 1]), Int(buffer[offset + 2]), Int(buffer[offset + 3]))
    }

    // MARK: - 输出尺寸与描边

    func testRenderOutputSizeAndOutlineColor() throws {
        let skin = skin { cg in
            fill(cg, CGRect(x: 8, y: 8, width: 8, height: 8), .red)          // 脸层
            fill(cg, CGRect(x: 40, y: 8, width: 8, height: 8), .blue)        // 帽层
        }
        let avatar = try XCTUnwrap(PclAvatarRenderer.render(skin: skin))

        // 64 皮肤 → scale 1 → 输出 60×60。
        XCTAssertEqual(avatar.cgImage?.width, 60)
        XCTAssertEqual(avatar.cgImage?.height, 60)

        let cg = try XCTUnwrap(avatar.cgImage)
        // 四角是透明余量（描边只出现在实体轮廓外一圈）。
        XCTAssertEqual(pixel(cg, x: 0, y: 0).a, 0)
        // 头顶上方 1px 应是 #AEB8C6 描边（帽子在合成区顶行，其上方一行属于描边带）。
        let top = pixel(cg, x: 30, y: 1)
        XCTAssertEqual(top.r, 0xAE, "描边红分量")
        XCTAssertEqual(top.g, 0xB8, "描边绿分量")
        XCTAssertEqual(top.b, 0xC6, "描边蓝分量")
        XCTAssertEqual(top.a, 255)
    }

    func testFaceLayerSitsUnderHatLayer() throws {
        let skin = skin { cg in
            fill(cg, CGRect(x: 8, y: 8, width: 8, height: 8), .red)
            fill(cg, CGRect(x: 40, y: 8, width: 8, height: 8), .blue)
        }
        let avatar = try XCTUnwrap(PclAvatarRenderer.render(skin: skin))
        let cg = try XCTUnwrap(avatar.cgImage)

        // 合成区中心 = 帽层（蓝，后画覆盖脸层）。
        let center = pixel(cg, x: 30, y: 30)
        XCTAssertEqual(center.b, 255)
        XCTAssertEqual(center.r, 0)
    }

    /// 64×32 旧皮肤没有帽层：合成区应只有脸层。
    func testLegacySkinSkipsHatLayer() throws {
        let skin = skin({ cg in
            fill(cg, CGRect(x: 8, y: 8, width: 8, height: 8), .red)
        }, width: 64, height: 32)
        let avatar = try XCTUnwrap(PclAvatarRenderer.render(skin: skin))
        let cg = try XCTUnwrap(avatar.cgImage)

        let center = pixel(cg, x: 30, y: 30)
        XCTAssertEqual(center.r, 255, "无帽层时中心应为脸层红色")
        XCTAssertEqual(center.b, 0)
    }

    // MARK: - 归一化

    func testNormalizationKeepsLegalSizesAndScalesOthers() throws {
        let standard = skin({ _ in }, width: 64, height: 64)
        XCTAssertEqual(PclAvatarRenderer.normalizedBase(standard)?.width, 64)

        let legacy = skin({ _ in }, width: 64, height: 32)
        XCTAssertEqual(PclAvatarRenderer.normalizedBase(legacy)?.height, 32)

        let hd = skin({ _ in }, width: 128, height: 128)
        XCTAssertEqual(PclAvatarRenderer.normalizedBase(hd)?.width, 128, "128×128 高清皮肤按 scale 2 保留")

        let odd = skin({ _ in }, width: 100, height: 100)
        XCTAssertEqual(PclAvatarRenderer.normalizedBase(odd)?.width, 64, "非法尺寸缩到 64×64")
    }

    // MARK: - 占位与默认皮肤

    func testDefaultSkinRendersPclAvatar() throws {
        let avatar = try XCTUnwrap(PclAvatarRenderer.render(skin: Skin3DModel.defaultSkin()))
        let cg = try XCTUnwrap(avatar.cgImage)
        XCTAssertEqual(cg.width, 60)

        // 有内容（中心附近应是不透明像素）。
        XCTAssertTrue(pixel(cg, x: 30, y: 30).a > 200)
    }
}
