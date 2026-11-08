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
        // iOS 涓嶅湪 Mojang 瀹樻柟涓夊钩鍙板唴锛屽甫 os 瑙勫垯鐨勫簱浼氳杩囨护锛?        // 1.12.2 瀹為檯淇濈暀 32 涓紙姣旀闈㈡竻鍗曞皯 1 涓?11,055 瀛楄妭鐨勫簱锛夈€?        XCTAssertEqual(plan.count(of: .library), 32)
        XCTAssertEqual(plan.count(of: .assetIndex), 1)
        XCTAssertEqual(plan.totalBytes, 10_180_113 + 40_459_559 + 143_136)
    }

    func testLargeFilesGetConnectionsSmallFilesGetOne() throws {
        let detail = try decodeDetail("VersionDetail_1.20.1")
        let plan = InstallPlanner.plan(detail: detail, layout: layout)

        let jar = try XCTUnwrap(plan.specs.first { $0.id.hasPrefix("client-") })
        XCTAssertEqual(jar.maxConnections, 16)

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
            // 瀹樻柟 CDN 涓?BMCLAPI 闀滃儚鐨勬湯娈甸兘鏄?<鍓?浣?/<hash>锛?            // 杩欓噷楠岃瘉璺緞缁撴瀯锛屼笉缁戞鍏蜂綋鍩熷悕锛堜笅杞芥簮鍙湪璁剧疆閲屽垏鎹級銆?            XCTAssertTrue(file.spec.url.absoluteString.hasSuffix(prefix + "/" + hash))
            XCTAssertTrue(file.spec.destination.path.hasSuffix("assets/objects/" + prefix + "/" + hash))
            XCTAssertEqual(file.spec.maxConnections, file.spec.expectedSize ?? 0 > InstallPlanner.smallFileThreshold ? 16 : 1)
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
