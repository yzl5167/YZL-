import XCTest
@testable import YZLLauncher

/// 资源市场：Modrinth v2 模型解析（camelCase 字段映射）、最佳版本挑选、
/// 中文判定。用真实 API 形状的样本，防止字段改名后静默解析成空。
final class ResourceMarketTests: XCTestCase {

    private let searchJSON = """
    {
      "hits": [
        {
          "project_id": "P7dR8mSH",
          "slug": "fabric-api",
          "title": "Fabric API",
          "description": "The essential library for mods",
          "categories": ["fabric", "optimization"],
          "client_side": "required",
          "server_side": "required",
          "icon_url": "https://cdn.modrinth.com/data/P7dR8mSH/icon.png",
          "downloads": 123456789,
          "date_modified": "2025-01-01T00:00:00.000000Z",
          "versions": ["1.21.4", "1.20.1"]
        }
      ],
      "limit": 30,
      "offset": 0,
      "total_hits": 1
    }
    """

    private let versionsJSON = """
    [
      {
        "id": "v-release",
        "project_id": "P7dR8mSH",
        "name": "Fabric API 0.20.1",
        "version_number": "0.20.1+1.21.4",
        "game_versions": ["1.21.4"],
        "loaders": ["fabric"],
        "version_type": "release",
        "date_published": "2025-01-01T00:00:00.000000Z",
        "files": [
          {
            "hashes": {"sha1": "abc123", "sha512": "def456"},
            "url": "https://cdn.modrinth.com/data/x/fabric-api.jar",
            "filename": "fabric-api-0.20.1.jar",
            "primary": true,
            "size": 1234567
          }
        ],
        "dependencies": [
          {"project_id": "dep-id", "version_id": null, "dependency_type": "required"},
          {"project_id": "opt-id", "version_id": null, "dependency_type": "optional"}
        ]
      },
      {
        "id": "v-beta",
        "project_id": "P7dR8mSH",
        "name": "Fabric API beta",
        "version_number": "0.21.0+1.21.4",
        "game_versions": ["1.21.4"],
        "loaders": ["fabric"],
        "version_type": "beta",
        "date_published": "2025-02-01T00:00:00.000000Z",
        "files": [],
        "dependencies": []
      }
    ]
    """

    func testSearchResponseDecoding() throws {
        let response = try JSONDecoder().decode(
            ModrinthSearchResponse.self, from: Data(searchJSON.utf8)
        )
        XCTAssertEqual(response.hits.count, 1)
        XCTAssertEqual(response.totalHits, 1)
        let project = try XCTUnwrap(response.hits.first)
        XCTAssertEqual(project.projectID, "P7dR8mSH")
        XCTAssertEqual(project.slug, "fabric-api")
        XCTAssertEqual(project.downloads, 123_456_789)
        XCTAssertEqual(project.categories?.first, "fabric")
    }

    func testVersionDecodingAndPrimaryFile() throws {
        let versions = try JSONDecoder().decode(
            [ModrinthVersion].self, from: Data(versionsJSON.utf8)
        )
        XCTAssertEqual(versions.count, 2)
        let release = try XCTUnwrap(versions.first)
        XCTAssertTrue(release.isRelease)
        XCTAssertEqual(release.primaryFile?.hashes?.sha1, "abc123")
        XCTAssertEqual(release.primaryFile?.filename, "fabric-api-0.20.1.jar")
        XCTAssertEqual(release.dependencies.filter(\.isRequired).count, 1)
    }

    func testPickBestPrefersMatchingRelease() throws {
        let versions = try JSONDecoder().decode(
            [ModrinthVersion].self, from: Data(versionsJSON.utf8)
        )
        let best = ModrinthService.pickBest(
            versions, gameVersion: "1.21.4", loader: "fabric"
        )
        let picked = try XCTUnwrap(best)
        XCTAssertEqual(picked.version.id, "v-release")
        XCTAssertTrue(picked.exact)
    }

    func testChineseDetection() {
        XCTAssertTrue(ResourceTranslation.hasChinese("以太"))
        XCTAssertTrue(ResourceTranslation.hasChinese("JEI 物品管理器"))
        XCTAssertFalse(ResourceTranslation.hasChinese("Fabric API"))
        XCTAssertFalse(ResourceTranslation.hasChinese("12345"))
    }

    func testCategoryTargetDirectories() {
        XCTAssertEqual(ResourceCategory.mod.targetSubdirectory, "mods")
        XCTAssertEqual(ResourceCategory.shader.targetSubdirectory, "shaderpacks")
        XCTAssertEqual(ResourceCategory.resourcepack.targetSubdirectory, "resourcepacks")
        XCTAssertNil(ResourceCategory.modpack.targetSubdirectory)
    }
}
