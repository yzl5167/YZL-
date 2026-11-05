import XCTest
@testable import YZLLauncher

final class DeviceCapabilitiesTests: XCTestCase {
    func testTrollStoreZoneFrom15Through1661() {
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 15, minor: 0, build: "19A341"), .trollStore)
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 15, minor: 8, build: "19H380"), .trollStore)
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 16, minor: 0, build: "20A362"), .trollStore)
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 16, minor: 6, build: "20G75"), .trollStore)
    }

    func test167OnlyRcIsSupported() {
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 16, minor: 7, build: "20H18"), .trollStore)
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 16, minor: 7, build: "20H19"), .computerSign)
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 16, minor: 7, build: ""), .computerSign)
    }

    func test17OnlyInitialReleaseIsSupported() {
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 17, minor: 0, build: "21A327"), .trollStore)
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 17, minor: 0, build: "21A326"), .trollStore)
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 17, minor: 1, build: "21B101"), .computerSign)
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 17, minor: 5, build: "21F79"), .computerSign)
    }

    func testModernSystemsNeedComputer() {
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 18, minor: 7, build: "22H300"), .computerSign)
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 26, minor: 1, build: "23B80"), .computerSign)
    }

    func testBelowMinimumIsUnsupported() {
        XCTAssertEqual(DeviceCapabilities.installRoute(major: 14, minor: 8, build: "18H392"), .unsupportedOld)
    }

    func testRecommendedHeapUsesProcessLimit() {
        XCTAssertEqual(DeviceCapabilities.recommendedHeapMB(processLimitMB: 2048, physicalMB: 6144), 819)
        XCTAssertEqual(DeviceCapabilities.recommendedHeapMB(processLimitMB: 6144, physicalMB: 8192), 2048)
        XCTAssertEqual(DeviceCapabilities.recommendedHeapMB(processLimitMB: 512, physicalMB: 3072), 512)
    }

    func testRecommendedHeapFallsBackWhenLimitUnknown() {
        // 拿不到进程上限时按物理内存一半估算，再取 40%
        XCTAssertEqual(DeviceCapabilities.recommendedHeapMB(processLimitMB: 0, physicalMB: 4096), 819)
        XCTAssertEqual(DeviceCapabilities.recommendedHeapMB(processLimitMB: 0, physicalMB: 2048), 512)
    }

    func testLiveProcessLimitIsPositiveOnDevice() {
        // 真机/模拟器上 os_proc_available_memory 必须返回正数，否则诊断页会显示 0 MB
        XCTAssertGreaterThan(DeviceCapabilities.processMemoryLimitMB, 0)
    }

    func testMaxSafeHeapCapsByAvailableMemory() {
        // 通用包的核心：同一个二进制在低内存设备上自动收敛堆上限
        XCTAssertEqual(DeviceCapabilities.maxSafeHeapMB(processLimitMB: 2048), 1228)
        XCTAssertEqual(DeviceCapabilities.maxSafeHeapMB(processLimitMB: 3000), 1800)
        XCTAssertEqual(DeviceCapabilities.maxSafeHeapMB(processLimitMB: 10_000), 4096)
    }

    func testMaxSafeHeapNeverDropsBelowMinimumOrExceedsCeiling() {
        XCTAssertEqual(DeviceCapabilities.maxSafeHeapMB(processLimitMB: 500), 1024)
        XCTAssertEqual(DeviceCapabilities.maxSafeHeapMB(processLimitMB: 99_999), 4096)
    }

    func testMaxSafeHeapFallsBackWhenReadingUnavailable() {
        XCTAssertEqual(DeviceCapabilities.maxSafeHeapMB(processLimitMB: 0), 4096)
        XCTAssertEqual(DeviceCapabilities.maxSafeHeapMB(processLimitMB: -1), 4096)
    }

    func testDeploymentProfileSplitsBySystemVersion() {
        // 14.0–15.4.1：TrollHelperOTA 全程零电脑
        XCTAssertEqual(DeviceCapabilities.deploymentProfile(major: 15, minor: 4, build: "19E241"), .permanentNoComputer)

        // TrollStore 永久签，但装它时首次要电脑侧载一次
        XCTAssertEqual(DeviceCapabilities.deploymentProfile(major: 15, minor: 5, build: "19F77"), .oneTimeComputerThenPermanent)
        XCTAssertEqual(DeviceCapabilities.deploymentProfile(major: 16, minor: 6, build: "20G75"), .oneTimeComputerThenPermanent)
        XCTAssertEqual(DeviceCapabilities.deploymentProfile(major: 17, minor: 0, build: "21A327"), .oneTimeComputerThenPermanent)

        // StikDebug 覆盖不到的中间地带：电脑持续参与
        XCTAssertEqual(DeviceCapabilities.deploymentProfile(major: 16, minor: 7, build: "20H19"), .computerAttached)
        XCTAssertEqual(DeviceCapabilities.deploymentProfile(major: 17, minor: 2, build: "21D123"), .computerAttached)

        // 17.4 – 18.x：一次配对后手机自维持
        XCTAssertEqual(DeviceCapabilities.deploymentProfile(major: 17, minor: 4, build: "21E123"), .oneTimePairing)
        XCTAssertEqual(DeviceCapabilities.deploymentProfile(major: 18, minor: 7, build: "22H300"), .oneTimePairing)

        // iOS 26+：JIT 需 App 侧适配
        XCTAssertEqual(DeviceCapabilities.deploymentProfile(major: 26, minor: 1, build: "23B80"), .appJITAdaptation)
        XCTAssertEqual(DeviceCapabilities.deploymentProfile(major: 14, minor: 8, build: "18H392"), .unsupportedOld)
    }

    func testDeploymentProfileHintsAndPackage() {
        XCTAssertTrue(DeviceCapabilities.deploymentProfile(major: 15, minor: 4, build: "19E241").unattendedAfterSetup)
        XCTAssertTrue(DeviceCapabilities.deploymentProfile(major: 16, minor: 6, build: "20G75").unattendedAfterSetup)
        XCTAssertTrue(DeviceCapabilities.deploymentProfile(major: 18, minor: 7, build: "22H300").unattendedAfterSetup)
        XCTAssertFalse(DeviceCapabilities.deploymentProfile(major: 26, minor: 1, build: "23B80").unattendedAfterSetup)
        XCTAssertFalse(DeviceCapabilities.deploymentProfile(major: 17, minor: 2, build: "21D123").unattendedAfterSetup)
        XCTAssertEqual(
            DeviceCapabilities.deploymentProfile(major: 16, minor: 6, build: "20G75").packageName,
            "com.yzl.launcher.tipa"
        )
        XCTAssertTrue(
            DeviceCapabilities.deploymentProfile(major: 18, minor: 7, build: "22H300").packageName
                .contains("unsigned")
        )
    }
}
