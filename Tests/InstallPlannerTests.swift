import XCTest
@testable import YZLLauncher

final class InstallPlannerTests: XCTestCase {
    private let layout = InstallLayout(versionID: "1.20.1", root: URL(fileURLWithPath: "/tmp/yzl-install-test"))

    private func decodeRules(_ json: String) throws -> [VersionDetail.Library.Rule] {
        let data = Data("[\(json)]".utf8)
        return try JSONDecoder().decode([VersionDetail.Library.Rule].self, from: data)
    }

    func testNoRulesMeansRequired() throws {
        XCTAssertTrue(InstallPlanner.isAllowed(rules: nil, osName: "ios"))
        XCTAssertTrue(InstallPlanner.isAllowed(rules: [], osName: "ios"))
    }

    func testOSAllowRulesDoNotMatchIOS() throws {
        for name in ["osx", "windows", "linux"] {
            let rules = try decodeRules("{\"action\":\"allow\",\"os\":{\"name\":\"\(name)\"}}")
            XCTAssertFalse(InstallPlanner.isAllowed(rules: rules, osName: "ios"), name)
        }
    }

    func testUnconditionalAllowRuleMatchesIOS() throws {
        let rules = try decodeRules("{\"action\":\"allow\"}")
        XCTAssertTrue(InstallPlanner.isAllowed(rules: rules, osName: "ios"))
    }

    func testLastMatchingRuleWins() throws {
        let rules = try decodeRules("""
        {"action":"allow"},{"action":"disallow","os":{"name":"osx"}}
        """)
        XCTAssertTrue(InstallPlanner.isAllowed(rules: rules, osName: "ios"))
    }

    func testNoMatchingRuleMeansNotRequired() throws {
        let rules = try decodeRules("{\"action\":\"disallow\",\"os\":{\"name\":\"osx\"}}")
        XCTAssertFalse(InstallPlanner.isAllowed(rules: rules, osName: "ios"))
    }

    func testRealJava17PlanCountsAndBytes() throws {
        let detail = try decodeDetail("VersionDetail_1.20.1")
        let plan = InstallPlanner.plan(detail: detail, layout: layout)

        XCTAssertEqual(plan.files.count, 45)
        XCTAssertEqual(plan.count(of: .clientJar), 1)
        XCTAssertEqual(plan.count(of: .library), 43)
        XCTAssertEqual(plan.count(of: .assetIndex), 1)
        XCTAssertEqual(plan.totalBytes, 23_028_853 + 56_765_207 + 413_067)

        XCTAssertTrue(plan.specs.allSatisfy { !$0.url.absoluteString.isEmpty })
        XCTAssertFalse(plan.specs.contains { $0.destination.path.contains("natives") })
    }

    func testRealJava8PlanCountsAndBytes() throws {
        let detail = try decodeDetail("VersionDetail_1.12.2")
        let plan = InstallPlanner.plan(detail: detail, layout: InstallLayout(versionID: "1.12.2", root: URL(fileURLWithPath: "/tmp/yzl-install-test")))

        XCTAssertEqual(plan.count(of: .clientJar), 1)
        XCTAssertEqual(plan.count(of: .library), 33)
        XCTAssertEqual(plan.count(of: .assetIndex), 1)
        XCTAssertEqual(plan.totalBytes, 10_180_113 + 40_470_614 + 143_136)
    }

    func testLargeFilesGetConnectionsSmallFilesGetOne() throws {
        let detail = try decodeDetail("VersionDetail_1.20.1")
        let plan = InstallPlanner.plan(detail: detail, layout: layout)

        let jar = try XCTUnwrap(plan.specs.first { $0.id.hasPrefix("client-") })
        XCTAssertEqual(jar.maxConnections, 8)

        let small = try XCTUnwrap(plan.specs.first { ($0.expectedSize ?? 0) < InstallPlanner.smallFileThreshold })
        XCTAssertEqual(small.maxConnections, 1)
    }

    func testAssetObjectPlanPathsAndSingleConnection() throws {
        let document = try decodeAssetIndex("AssetIndex_5.sample")
        XCTAssertEqual(document.objects.count, 40)

        let plan = InstallPlanner.assetObjectPlan(document: document, layout: layout, versionID: "1.20.1")
        XCTAssertEqual(plan.files.count, 40)

        for file in plan.files {
            let hash = file.spec.expectedSHA1 ?? ""
            let prefix = String(hash.prefix(2))
            XCTAssertTrue(file.spec.url.absoluteString.hasPrefix("https://resources.download.minecraft.net/" + prefix + "/"))
            XCTAssertTrue(file.spec.destination.path.hasSuffix("assets/objects/" + prefix + "/" + hash))
            XCTAssertEqual(file.spec.maxConnections, 1)
        }
    }

    func testAssetObjectPlanDeduplicatesSameHash() {
        let document = AssetIndexDocument(objects: [
            "a.png": AssetIndexDocument.AssetObject(hash: "aa11bb22cc33dd44ee55ff6677889900aabbccdd", size: 100),
            "b.png": AssetIndexDocument.AssetObject(hash: "aa11bb22cc33dd44ee55ff6677889900aabbccdd", size: 100),
            "c.png": AssetIndexDocument.AssetObject(hash: "bb11bb22cc33dd44ee55ff6677889900aabbccdd", size: 200)
        ])

        let plan = InstallPlanner.assetObjectPlan(document: document, layout: layout, versionID: "1.20.1")
        XCTAssertEqual(plan.files.count, 2)
        XCTAssertEqual(plan.totalBytes, 300)
    }

    private func decodeDetail(_ sample: String) throws -> VersionDetail {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: sample, withExtension: "json"))
        return try JSONDecoder().decode(VersionDetail.self, from: Data(contentsOf: url))
    }

    private func decodeAssetIndex(_ sample: String) throws -> AssetIndexDocument {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: sample, withExtension: "json"))
        return try JSONDecoder().decode(AssetIndexDocument.self, from: Data(contentsOf: url))
    }
}
