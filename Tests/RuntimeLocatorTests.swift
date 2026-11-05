import XCTest
@testable import YZLLauncher

final class RuntimeLocatorTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeMarker(_ root: URL, _ relativePath: String) throws {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("jre".utf8).write(to: file)
    }

    func testEmptyRootReportsMissingRuntime() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(RuntimeLocator.javaHome(roots: [root]))
        XCTAssertFalse(RuntimeLocator.javaRuntime(roots: [root]).isReady)
    }

    func testDirectoryWithoutJREMarkersIsNotAccepted() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("empty-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)

        XCTAssertNil(RuntimeLocator.javaHome(roots: [root]))
    }

    func testValidJRERootIsDetected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMarker(root, "jre-17/lib/jli/libjli.dylib")

        let home = RuntimeLocator.javaHome(roots: [root])
        XCTAssertEqual(home?.lastPathComponent, "jre-17")
        XCTAssertTrue(RuntimeLocator.javaRuntime(roots: [root]).isReady)
    }

    func testAllKnownMarkersAreRecognized() throws {
        for marker in RuntimeLocator.jreMarkerPaths {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeMarker(root, "jre-test/\(marker)")
            XCTAssertNotNil(
                RuntimeLocator.javaHome(roots: [root]),
                "marker \(marker) should be recognized"
            )
        }
    }

    func testEngineStatusRequiresBothJREAndNatives() throws {
        let bundle = try makeRoot()
        defer { try? FileManager.default.removeItem(at: bundle) }
        try writeMarker(bundle, "java_runtimes/jre-17/lib/jli/libjli.dylib")

        let roots = [bundle.appendingPathComponent("java_runtimes", isDirectory: true)]
        XCTAssertFalse(RuntimeLocator.engineStatus(roots: roots, bundleURL: bundle).isReady)

        let natives = bundle.appendingPathComponent("natives", isDirectory: true)
        try FileManager.default.createDirectory(at: natives, withIntermediateDirectories: true)
        try Data("glfw".utf8).write(to: natives.appendingPathComponent("libglfw.dylib"))

        XCTAssertTrue(RuntimeLocator.engineStatus(roots: roots, bundleURL: bundle).isReady)
    }
}
