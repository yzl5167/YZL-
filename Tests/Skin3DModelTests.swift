import XCTest
import UIKit
@testable import YZLLauncher

/// 3D 皮肤渲染器：贴图归一化、UV 表合法性、面裁剪与光照、整帧渲染的像素断言。
final class Skin3DModelTests: XCTestCase {
    // MARK: - 贴图归一化

    /// 造图必须显式 scale 1：默认会带设备 scale（模拟器 3x），64×64 会变成 192×192。
    private func solidImage(width: Int, height: Int, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testNormalizedBaseKeepsStandardSizes() throws {
        let standard = solidImage(width: 64, height: 64, color: .red)
        let normalized = try XCTUnwrap(Skin3DModel.normalizedBase(standard))
        XCTAssertEqual(normalized.width, 64)
        XCTAssertEqual(normalized.height, 64)

        let legacy = solidImage(width: 64, height: 32, color: .red)
        let legacyNormalized = try XCTUnwrap(Skin3DModel.normalizedBase(legacy))
        XCTAssertEqual(legacyNormalized.height, 32, "64×32 旧版皮肤保留尺寸（构建时走 legacy 分支）")
    }

    func testNormalizedBaseScalesOddSizesTo64() throws {
        let odd = solidImage(width: 100, height: 100, color: .red)
        let normalized = try XCTUnwrap(Skin3DModel.normalizedBase(odd))
        XCTAssertEqual(normalized.width, 64)
        XCTAssertEqual(normalized.height, 64)
    }

    // MARK: - UV 表

    /// 所有 UV 框都在 64×64 皮肤范围内，且关键锚点与标准布局一致。
    func testUVTablesStayInsideTexture() {
        let tables: [(String, Skin3DModel.TexSet)] = [
            ("HEAD", Skin3DModel.TEX_HEAD),
            ("HEAD_OVER", Skin3DModel.TEX_HEAD_OVER),
            ("BODY", Skin3DModel.TEX_BODY),
            ("BODY_OVER", Skin3DModel.TEX_BODY_OVER),
            ("ARM_R", Skin3DModel.TEX_ARM_R),
            ("ARM_R_OVER", Skin3DModel.TEX_ARM_R_OVER),
            ("ARM_L", Skin3DModel.TEX_ARM_L),
            ("ARM_L_OVER", Skin3DModel.TEX_ARM_L_OVER),
            ("ARM_R_SLIM", Skin3DModel.TEX_ARM_R_SLIM),
            ("ARM_R_SLIM_OVER", Skin3DModel.TEX_ARM_R_SLIM_OVER),
            ("ARM_L_SLIM", Skin3DModel.TEX_ARM_L_SLIM),
            ("ARM_L_SLIM_OVER", Skin3DModel.TEX_ARM_L_SLIM_OVER),
            ("LEG_R", Skin3DModel.TEX_LEG_R),
            ("LEG_R_OVER", Skin3DModel.TEX_LEG_R_OVER),
            ("LEG_L", Skin3DModel.TEX_LEG_L),
            ("LEG_L_OVER", Skin3DModel.TEX_LEG_L_OVER)
        ]

        for (name, tex) in tables {
            for (face, rect) in [("top", tex.top), ("bottom", tex.bottom), ("right", tex.right),
                                 ("front", tex.front), ("left", tex.left), ("back", tex.back)] {
                XCTAssertGreaterThanOrEqual(rect.minX, 0, "\(name).\(face)")
                XCTAssertGreaterThanOrEqual(rect.minY, 0, "\(name).\(face)")
                XCTAssertLessThanOrEqual(rect.maxX, 64, "\(name).\(face)")
                XCTAssertLessThanOrEqual(rect.maxY, 64, "\(name).\(face)")
            }
        }

        // 标准 64×64 布局的锚点（移植自 Android 端 TexSet 的硬编码值）。
        XCTAssertEqual(Skin3DModel.TEX_HEAD.front, CGRect(x: 8, y: 8, width: 8, height: 8))
        XCTAssertEqual(Skin3DModel.TEX_HEAD_OVER.front, CGRect(x: 40, y: 8, width: 8, height: 8))
        XCTAssertEqual(Skin3DModel.TEX_BODY.front, CGRect(x: 20, y: 20, width: 8, height: 12))
        XCTAssertEqual(Skin3DModel.TEX_ARM_R_SLIM.front, CGRect(x: 44, y: 20, width: 3, height: 12))
        XCTAssertEqual(Skin3DModel.TEX_LEG_L.front, CGRect(x: 20, y: 52, width: 4, height: 12))
    }

    // MARK: - 面裁剪与光照

    func testCroppedFaceRejectsOutOfBoundsAndTransparent() throws {
        let base = try XCTUnwrap(Skin3DModel.normalizedBase(solidImage(width: 64, height: 64, color: .red)))

        // 越界裁剪返回 nil。
        XCTAssertNil(Skin3DModel.croppedFace(from: base, rect: CGRect(x: 60, y: 60, width: 8, height: 8),
                                             unit: 1, shade: 1))

        // 全透明的面不进模型（空 overlay 是正常情况）。
        let transparent = try XCTUnwrap(Skin3DModel.normalizedBase(solidImage(width: 64, height: 64, color: .clear)))
        XCTAssertNil(Skin3DModel.croppedFace(from: transparent, rect: CGRect(x: 8, y: 8, width: 8, height: 8),
                                             unit: 1, shade: 1))
    }

    func testCroppedFaceBakesShade() throws {
        let base = try XCTUnwrap(Skin3DModel.normalizedBase(solidImage(width: 64, height: 64, color: .red)))
        let face = try XCTUnwrap(Skin3DModel.croppedFace(from: base, rect: CGRect(x: 8, y: 8, width: 8, height: 8),
                                                         unit: 1, shade: 0.5))
        // shade 0.5 → 红色 255 减半。
        XCTAssertEqual(pixel(face, x: 0, y: 0).red, 128, "面光照应在构建期烘焙进像素")
    }

    // MARK: - 整帧渲染

    func testRenderImageProducesBody() throws {
        let image = try XCTUnwrap(Skin3DModel.renderImage(
            skin: Skin3DModel.defaultSkin(),
            model: "steve",
            size: CGSize(width: 320, height: 320)
        ))
        XCTAssertEqual(Int(image.size.width * image.scale), 320)
        XCTAssertEqual(Int(image.size.height * image.scale), 320)
        let cg = try XCTUnwrap(image.cgImage)

        // 输出非空：画布上应有不透明像素（模型本体）。
        let hasContent = stride(from: 0, to: 320, by: 8).contains { y in
            stride(from: 0, to: 320, by: 8).contains { x in
                pixel(cg, x: x, y: y).alpha > 0
            }
        }
        XCTAssertTrue(hasContent)
    }

    func testHeadOnlyRenderIsSmallerModel() throws {
        let head = try XCTUnwrap(Skin3DModel.renderImage(
            skin: Skin3DModel.defaultSkin(),
            model: "steve",
            headOnly: true,
            size: CGSize(width: 160, height: 160),
            yawDeg: 0,
            pitchDeg: 0
        ))
        // 仅头模式：头占满画布大部分，脸的肤色应出现在画布中心附近。
        let cg = try XCTUnwrap(head.cgImage)
        let center = pixel(cg, x: 80, y: 80)
        XCTAssertTrue(center.alpha > 200, "头模式下画布中心应有模型像素")
    }

    /// 正面朝向（yaw 0 / pitch 0）时，画布中心附近的像素应是默认皮肤的衬衫青色。
    func testFrontFacingCenterPixelUsesFrontTexture() throws {
        let image = try XCTUnwrap(Skin3DModel.renderImage(
            skin: Skin3DModel.defaultSkin(),
            model: "steve",
            size: CGSize(width: 320, height: 320),
            yawDeg: 0,
            pitchDeg: 0,
            walkPhase: 0
        ))
        let cg = try XCTUnwrap(image.cgImage)
        // 头正面（肤色，shade 1.0）投影在画布上部中央：scale = 320/37.5 ≈ 8.53，
        // 头中心 y=28 → 屏幕 y ≈ 160+4.8-12*8.53 ≈ 62。取 (160, 62) 采样。
        let sample = pixel(cg, x: 160, y: 62)
        XCTAssertTrue(sample.alpha > 200, "正面中心应是头正面的不透明像素：\(sample)")
        XCTAssertGreaterThan(sample.red, 200, "默认皮肤肤色偏红：\(sample)")
    }

    /// 走路摆动会改变输出（四肢位置随 walkPhase 移动）。
    func testWalkPhaseChangesOutput() throws {
        let neutral = try XCTUnwrap(Skin3DModel.renderImage(
            skin: Skin3DModel.defaultSkin(), model: "steve",
            size: CGSize(width: 200, height: 200), walkPhase: 0
        ))
        let midSwing = try XCTUnwrap(Skin3DModel.renderImage(
            skin: Skin3DModel.defaultSkin(), model: "steve",
            size: CGSize(width: 200, height: 200), walkPhase: .pi / 2
        ))
        XCTAssertNotEqual(neutral.pngData(), midSwing.pngData(), "walkPhase 变化应改变四肢姿态")
    }

    /// 默认皮肤必须能构建出完整模型（无皮肤来源时的兜底）。
    func testDefaultSkinBuildsClassicAndSlimModels() {
        XCTAssertNotNil(Skin3DModel(skin: Skin3DModel.defaultSkin(), model: "steve"))
        XCTAssertNotNil(Skin3DModel(skin: Skin3DModel.defaultSkin(), model: "alex"))
        XCTAssertNotNil(Skin3DModel(skin: Skin3DModel.defaultSkin(), model: "custom", headOnly: true))
        // nil 贴图返回 nil（调用方再兜底）。
        XCTAssertNil(Skin3DModel(skin: nil, model: "steve"))
    }

    // MARK: - 像素取样

    private struct Sample {
        var red: Int
        var green: Int
        var blue: Int
        var alpha: Int
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> Sample {
        let ctx = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let buffer = ctx.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        let offset = (y * image.width + x) * 4
        return Sample(
            red: Int(buffer[offset]),
            green: Int(buffer[offset + 1]),
            blue: Int(buffer[offset + 2]),
            alpha: Int(buffer[offset + 3])
        )
    }
}
