import XCTest
@testable import YZLLauncher

final class VersionDetailTests: XCTestCase {
    func testDecodesRealJava17Sample() throws {
        let detail = try decode(sample: "VersionDetail_1.20.1")
        XCTAssertEqual(detail.id, "1.20.1")
        XCTAssertEqual(detail.type, "release")
        XCTAssertEqual(detail.mainClass, "net.minecraft.client.main.Main")
        XCTAssertEqual(detail.javaVersion?.majorVersion, 17)
        let client17 = try XCTUnwrap(detail.clientArtifact, "官方版本必须带客户端 jar")
        XCTAssertEqual(client17.size, 23_028_853)
        XCTAssertEqual(client17.sha1, "0c3ec587af28e5a785c0b4a7b8a30f9a8f78f838")
        XCTAssertEqual(client17.url.host, "piston-data.mojang.com")
        XCTAssertTrue(detail.javaRequirement.contains("Java 17"))
        XCTAssertEqual(detail.libraries?.count, 88)
        XCTAssertEqual(detail.assetIndex?.id, "5")
        XCTAssertEqual(detail.assetIndex?.size, 413_067)
        XCTAssertEqual(detail.assetIndex?.totalSize, 651_970_283)
    }

    func testDecodesRealJava8Sample() throws {
        let detail = try decode(sample: "VersionDetail_1.12.2")
        XCTAssertEqual(detail.id, "1.12.2")
        XCTAssertEqual(detail.javaVersion?.majorVersion, 8)
        let client8 = try XCTUnwrap(detail.clientArtifact)
        XCTAssertEqual(client8.size, 10_180_113)
        XCTAssertEqual(client8.sha1, "0f275bc1547d01fa5f56ba34bdc87d981ee12daf")
    }

    private func decode(sample: String) throws -> VersionDetail {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: sample, withExtension: "json"),
            "测试资源 \(sample).json 未打进测试 bundle"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VersionDetail.self, from: data)
    }
}
