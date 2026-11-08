import XCTest
@testable import YZLLauncher

final class JavaEnvironmentTests: XCTestCase {

    func testMajorFromReleaseVersionString() {
        XCTAssertEqual(JavaEnvironment.major(fromVersion: "1.8.0_392"), 8)
        XCTAssertEqual(JavaEnvironment.major(fromVersion: "17.0.9"), 17)
        XCTAssertEqual(JavaEnvironment.major(fromVersion: "21.0.1"), 21)
        XCTAssertNil(JavaEnvironment.major(fromVersion: ""))
    }

    func testRecommendedMajorByGameVersion() {
        XCTAssertEqual(JavaEnvironment.recommendedMajor(gameVersion: "1.16.5"), 8)
        XCTAssertEqual(JavaEnvironment.recommendedMajor(gameVersion: "1.12.2"), 8)
        XCTAssertEqual(JavaEnvironment.recommendedMajor(gameVersion: "1.17.1"), 17)
        XCTAssertEqual(JavaEnvironment.recommendedMajor(gameVersion: "1.20.1"), 17)
        XCTAssertEqual(JavaEnvironment.recommendedMajor(gameVersion: "1.21"), 21)
        // 快照版本不以 1. 开头，保守落到 17
        XCTAssertEqual(JavaEnvironment.recommendedMajor(gameVersion: "23w43a"), 17)
        XCTAssertEqual(JavaEnvironment.recommendedMajor(gameVersion: nil), 17)
    }

    func testDeclaredJavaVersionWins() {
        XCTAssertEqual(
            JavaEnvironment.recommendedMajor(gameVersion: "1.20.1", declaredMajor: 21), 21)
        XCTAssertEqual(
            JavaEnvironment.recommendedMajor(gameVersion: "1.20.1", declaredMajor: nil), 17)
    }

    func testScanAndVersionAwareSelection() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("YZLJavaEnv-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        func makeJRE(_ name: String, version: String, usable: Bool) throws -> JavaEnvironment.Runtime {
            let dir = root.appendingPathComponent("java_runtimes/\(name)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("JAVA_VERSION=\"\(version)\"\n".utf8).write(to: dir.appendingPathComponent("release"))
            if usable {
                let lib = dir.appendingPathComponent("lib/server", isDirectory: true)
                try fm.createDirectory(at: lib, withIntermediateDirectories: true)
                try Data("macho".utf8).write(to: lib.appendingPathComponent("libjvm.dylib"))
            }
            let major = try XCTUnwrap(JavaEnvironment.major(of: dir))
            return JavaEnvironment.Runtime(
                major: major, version: version, root: dir, isUsable: usable,
                bytes: 0, isManual: false)
        }

        let j8 = try makeJRE("java-8-openjdk", version: "1.8.0_392", usable: true)
        let j17 = try makeJRE("java-17-openjdk", version: "17.0.9", usable: true)
        let j21 = try makeJRE("java-21-openjdk", version: "21.0.1", usable: false)

        // scan 能读出真实版本号，并把空壳标成不可用。
        let scanned = JavaEnvironment.scan(bundleURL: root, includeSize: false)
            .filter { $0.root.path.hasPrefix(root.path) }
        XCTAssertEqual(scanned.count, 3)
        XCTAssertEqual(scanned.first(where: { $0.major == 8 })?.version, "1.8.0_392")
        XCTAssertFalse(scanned.first(where: { $0.major == 21 })?.isUsable ?? true)

        // 精确匹配优先。
        guard case .exact(let exact8) = JavaEnvironment.selection(for: 8, runtimes: scanned) else {
            return XCTFail("Java 8 应精确命中")
        }
        XCTAssertEqual(exact8.root.lastPathComponent, "java-8-openjdk")

        guard case .exact(let exact17) = JavaEnvironment.selection(for: 17, runtimes: scanned) else {
            return XCTFail("Java 17 应精确命中")
        }
        XCTAssertEqual(exact17.root.lastPathComponent, "java-17-openjdk")

        // 空壳不参与选择，1.21+ 明确报缺失而不是拿 Java 8 顶。
        guard case .missing(let required, let available) =
                JavaEnvironment.selection(for: 21, runtimes: scanned) else {
            return XCTFail("Java 21 空壳应判缺失")
        }
        XCTAssertEqual(required, 21)
        XCTAssertEqual(available, [8, 17])
        XCTAssertTrue(JavaEnvironment.missingHint(required: required, available: available)
            .contains("YZLJavaRuntimes"))

        // 需要 Java 8 时绝不拿 17 顶替（反射/模块化会崩）。
        guard case .missing = JavaEnvironment.selection(for: 8, runtimes: [j17]) else {
            return XCTFail("要求 Java 8 时不应回退到 Java 17")
        }

        // Java 17+ 缺精确版本时允许用更高的可用 Java 顶替，但要标记。
        let j21usable = JavaEnvironment.Runtime(
            major: 21, version: "21.0.1", root: j21.root, isUsable: true,
            bytes: 0, isManual: false)
        guard case .fallback(let fallback, let wanted) =
                JavaEnvironment.selection(for: 17, runtimes: [j21usable]) else {
            return XCTFail("Java 17 要求应允许 Java 21 向后兼容顶替")
        }
        XCTAssertEqual(fallback.major, 21)
        XCTAssertEqual(wanted, 17)
    }
}
