import XCTest
@testable import YZLLauncher

final class SkinTextureTests: XCTestCase {
    func testHeadCropForModern64x64Texture() {
        let crop = SkinTexture.headCrop(width: 64, height: 64)
        XCTAssertEqual(crop, CGRect(x: 8, y: 8, width: 8, height: 8))
    }

    func testHeadCropForLegacy64x32Texture() {
        let crop = SkinTexture.headCrop(width: 64, height: 32)
        XCTAssertEqual(crop, CGRect(x: 8, y: 8, width: 8, height: 8))
    }

    func testHeadCropScalesWithTextureWidth() {
        let crop = SkinTexture.headCrop(width: 128, height: 128)
        XCTAssertEqual(crop, CGRect(x: 16, y: 16, width: 16, height: 16))
    }

    func testHeadCropRejectsTooSmallTextures() {
        XCTAssertNil(SkinTexture.headCrop(width: 8, height: 8))
        XCTAssertNil(SkinTexture.headCrop(width: 64, height: 8))
    }
}
