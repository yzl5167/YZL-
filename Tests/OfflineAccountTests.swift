import XCTest
@testable import YZLLauncher

final class OfflineAccountTests: XCTestCase {

    /// 离线 UUID 必须是标准 8-4-4-4-12 格式，且与官方 Launcher 算法一致（版本 3 / RFC4122 变体）。
    func testOfflineUUIDFormatAndBits() {
        let uuid = OfflineAccount.offlineUUID(for: "Steve")
        let parts = uuid.split(separator: "-").map(String.init)
        XCTAssertEqual(parts.count, 5, "UUID 必须是 8-4-4-4-12 五段")
        XCTAssertEqual(parts[0].count, 8)
        XCTAssertEqual(parts[1].count, 4)
        XCTAssertEqual(parts[2].count, 4)
        XCTAssertEqual(parts[3].count, 4)
        XCTAssertEqual(parts[4].count, 12)

        // 第三段首字符应为 "3"（版本 3）。
        XCTAssertEqual(parts[2].prefix(1), "3")
        // 第四段首字符应为 "8"/"9"/"a"/"b"（RFC 4122 变体）。
        let fourth = parts[3].prefix(1)
        XCTAssertTrue(["8", "9", "a", "b"].contains(String(fourth)))
    }

    func testOfflineUUIDDeterministicAndNameBased() {
        let a = OfflineAccount.offlineUUID(for: "Notch")
        let b = OfflineAccount.offlineUUID(for: "Notch")
        let c = OfflineAccount.offlineUUID(for: "notch")
        XCTAssertEqual(a, b, "同名必须稳定生成同一个 UUID")
        XCTAssertNotEqual(a, c, "大小写不同视为不同玩家")
    }

    /// 同一名字生成的账号 id 与 offlineUUID 一致，可直接作为存储主键与启动 uuid。
    func testAccountIdentity() {
        let account = OfflineAccount(name: "Alex")
        XCTAssertEqual(account.id, OfflineAccount.offlineUUID(for: "Alex"))
        XCTAssertEqual(account.name, "Alex")
        XCTAssertEqual(account.skinModel, "steve")
        XCTAssertNil(account.skinURL)
    }

    func testAccountWithCustomSkin() {
        let account = OfflineAccount(name: "Hero", skinModel: "custom", skinURL: "https://example.com/skin.png")
        XCTAssertEqual(account.skinModel, "custom")
        XCTAssertEqual(account.skinURL, "https://example.com/skin.png")
    }

    /// 套一层 MicrosoftAccount 后，下游启动参数拼装层无需改动即可使用。
    func testAdaptsToMicrosoftAccount() {
        let offline = OfflineAccount(name: "Steve", skinModel: "alex")
        let microsoft = offline.asMicrosoftAccount
        XCTAssertEqual(microsoft.id, offline.id)
        XCTAssertEqual(microsoft.name, offline.name)
        XCTAssertEqual(microsoft.skinURL, offline.skinURL)
    }

    /// 离线启动用 mojang 账号类型、占位令牌，能生成可展示的启动参数。
    /// 版本 JSON 不提供任何参数时走兜底路径，其中会注入 --userType 与 --accessToken。
    func testOfflineLaunchPlanUsesMojangUserType() throws {
        let json = """
        {
          "id": "1.20.1",
          "type": "release",
          "mainClass": "net.minecraft.client.main.Main"
        }
        """
        let detail = try JSONDecoder().decode(VersionDetail.self, from: Data(json.utf8))

        let layout = InstallLayout(versionID: "1.20.1", root: URL(fileURLWithPath: "/tmp/yzl-offline-test"))
        let version = MinecraftVersion(
            id: "1.20.1",
            type: "release",
            url: URL(string: "https://example.com/1.20.1.json")!,
            time: "2023-06-07T14:24:30+00:00",
            releaseTime: "2023-06-07T14:24:30+00:00"
        )
        let offline = OfflineAccount(name: "Steve")
        let plan = try LaunchPlanBuilder.build(
            detail: detail,
            version: version,
            layout: layout,
            account: offline.asMicrosoftAccount,
            accessToken: "offline",
            memoryMB: 1024,
            maxHeapMB: 2048,
            userType: "mojang"
        )
        XCTAssertTrue(plan.gameArguments.contains("--userType"), "应注入 --userType")
        XCTAssertTrue(plan.gameArguments.contains("mojang"), "离线应使用 mojang 账号类型")
        XCTAssertTrue(plan.gameArguments.contains("--accessToken"), "应注入 --accessToken")
        XCTAssertTrue(plan.gameArguments.contains("offline"), "离线用占位令牌")
        XCTAssertTrue(plan.gameArguments.contains(offline.id), "离线 UUID 应作为 --uuid 值")
    }
}
