import XCTest
@testable import YZLLauncher

/// 微软官方皮肤 / 披风 API 的纯函数：multipart 字段顺序（variant 在前）、
/// 装备披风请求体、profile 解析与错误文案优先级。
final class MicrosoftProfileServiceTests: XCTestCase {
    // MARK: - multipart 上传体

    func testSkinUploadBodyPutsVariantBeforeFile() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let (body, contentType) = MicrosoftProfileService.skinUploadBody(pngData: png, variant: "slim")

        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let text = String(decoding: body, as: UTF8.self)
        // Mojang API 的字段名是 variant（不是 Yggdrasil 的 model），且必须在 file 之前。
        let variantRange = text.range(of: "name=\"variant\"")
        let fileRange = text.range(of: "name=\"file\"")
        XCTAssertNotNil(variantRange)
        XCTAssertNotNil(fileRange)
        XCTAssertLessThan(variantRange!.lowerBound, fileRange!.lowerBound)
        XCTAssertTrue(text.contains("\r\nslim\r\n"))
        // PNG 原始字节要完整嵌进去。
        XCTAssertEqual(body.range(of: png) != nil, true)
        XCTAssertTrue(text.hasSuffix("--" + (contentType.components(separatedBy: "boundary=").last ?? "") + "--\r\n"))
    }

    // MARK: - 披风请求体

    func testEquipCapeBody() throws {
        let data = MicrosoftProfileService.equipCapeBody(capeID: "cape-uuid-1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["capeId"] as? String, "cape-uuid-1")
        XCTAssertEqual(object.count, 1, "装备披风的请求体只有 capeId 一个字段")
    }

    // MARK: - profile 解析

    func testParseProfilePicksActiveSkinAndCapes() throws {
        let data = try XCTUnwrap("{"
            + "\"id\": \"abc\", \"name\": \"Steve\", "
            + "\"skins\": ["
            + "{\"id\": \"s1\", \"state\": \"ACTIVE\", \"url\": \"http://textures.minecraft.net/steve.png\", \"variant\": \"SLIM\"}, "
            + "{\"id\": \"s2\", \"state\": \"\", \"url\": \"http://textures.minecraft.net/old.png\", \"variant\": \"CLASSIC\"}"
            + "], "
            + "\"capes\": ["
            + "{\"id\": \"cape1\", \"alias\": \"Migrator\", \"state\": \"ACTIVE\", \"url\": \"http://capes/migrator.png\"}, "
            + "{\"id\": \"cape2\", \"alias\": \"Pan\", \"state\": \"\", \"url\": \"http://capes/pan.png\"}"
            + "]}".data(using: .utf8))

        let profile = try XCTUnwrap(MicrosoftProfileService.parseProfile(data))
        XCTAssertEqual(profile.skinURL, "http://textures.minecraft.net/steve.png", "只取 state == ACTIVE 的皮肤")
        XCTAssertEqual(profile.skinVariant, "SLIM")
        XCTAssertEqual(profile.capes.count, 2)
        XCTAssertEqual(profile.capes[0].id, "cape1")
        XCTAssertEqual(profile.capes[0].alias, "Migrator")
        XCTAssertTrue(profile.capes[0].isActive)
        XCTAssertFalse(profile.capes[1].isActive)
    }

    func testParseProfileHandlesMissingSections() throws {
        let empty = MicrosoftProfileService.parseProfile(Data("{}".utf8))
        XCTAssertNotNil(empty)
        XCTAssertNil(empty?.skinURL)
        XCTAssertTrue(empty?.capes.isEmpty ?? false)

        // 没有 ACTIVE 皮肤时回退到第一项（与 Windows 端语义一致）。
        let fallback = MicrosoftProfileService.parseProfile(Data(
            "{\"skins\": [{\"state\": \"\", \"url\": \"http://x/fallback.png\"}]}".utf8
        ))
        XCTAssertEqual(fallback?.skinURL, "http://x/fallback.png")

        XCTAssertNil(MicrosoftProfileService.parseProfile(Data("not json".utf8)))
    }

    // MARK: - 错误文案

    func testErrorMessagePriority() {
        let prioritized = "{\"errorMessage\": \"EM\", \"error\": \"E\", \"errorType\": \"T\"}".data(using: .utf8)!
        XCTAssertEqual(MicrosoftProfileService.errorMessage(in: prioritized, status: 400), "EM")

        let errorOnly = "{\"error\": \"E\", \"errorType\": \"T\"}".data(using: .utf8)!
        XCTAssertEqual(MicrosoftProfileService.errorMessage(in: errorOnly, status: 400), "E")

        let typeOnly = "{\"errorType\": \"T\"}".data(using: .utf8)!
        XCTAssertEqual(MicrosoftProfileService.errorMessage(in: typeOnly, status: 400), "T")

        let raw = MicrosoftProfileService.errorMessage(in: Data("plain text".utf8), status: 500)
        XCTAssertTrue(raw.contains("plain text"))
    }
}
