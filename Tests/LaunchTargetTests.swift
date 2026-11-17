import XCTest
@testable import YZLLauncher

/// 启动契约的 launchTarget 完整性：同一个字典同时给 SurfaceViewController 的
/// metadata 和 native launchJVM 用。缺 id / jvm_processed 会让 JavaLauncher.m
/// 把 NULL 塞进 JVM argv，是「一启动就闪退」的直接原因，必须有单测锁死。
final class LaunchTargetTests: XCTestCase {

    func testLaunchTargetHasIdJavaVersionAndJVMArguments() {
        let target = EngineLaunchContract.launchTarget(
            versionID: "1.20.1",
            javaMajor: 17,
            jvmArguments: ["-Xmx2048M", "-XX:+UseG1GC"]
        )

        XCTAssertEqual(target["id"] as? String, "1.20.1")
        let java = target["javaVersion"] as? [String: Any]
        XCTAssertEqual(java?["majorVersion"] as? Int, 17)
        let args = (target["arguments"] as? [String: Any])?["jvm_processed"] as? [String]
        XCTAssertEqual(args, ["-Xmx2048M", "-XX:+UseG1GC"])
    }

    /// 即使额外 JVM 参数为空，三个关键键也必须在——NULL id 比没有参数更致命。
    func testLaunchTargetIsWellFormedWithEmptyArguments() {
        let target = EngineLaunchContract.launchTarget(
            versionID: "1.16.5", javaMajor: 8, jvmArguments: []
        )
        XCTAssertNotNil(target["id"])
        XCTAssertNotNil(target["javaVersion"])
        XCTAssertNotNil(target["arguments"])
    }

    /// 只接一个 int 的原始 metadata 已不再被使用：确保新 builder 不回退到
    /// 只有 javaVersion 的残缺形态（那是双启动崩溃的元凶）。
    func testLaunchTargetNeverOmitsId() {
        for major in [8, 17, 21] {
            let target = EngineLaunchContract.launchTarget(
                versionID: "v\(major)", javaMajor: major, jvmArguments: ["-Xmx1024M"]
            )
            XCTAssertFalse((target["id"] as? String ?? "").isEmpty, "Java \(major) 的 id 不能为空")
        }
    }
}
