import XCTest
@testable import YZLLauncher

/// 联机：服务器模型解析与收藏列表持久化。对齐 PC 端 MainWindow.Multiplayer。
final class ServerListTests: XCTestCase {

    // MARK: - 地址解析

    func testParseWithExplicitPort() {
        let (host, port) = MinecraftServer.parse("mc.example.com:25567")
        XCTAssertEqual(host, "mc.example.com")
        XCTAssertEqual(port, 25567)
    }

    func testParseDefaultsTo25565() {
        let (host, port) = MinecraftServer.parse("mc.example.com")
        XCTAssertEqual(host, "mc.example.com")
        XCTAssertEqual(port, 25565)
    }

    func testParseInvalidPortFallsBack() {
        let (host, port) = MinecraftServer.parse("mc.example.com:99999")
        XCTAssertEqual(host, "mc.example.com")
        XCTAssertEqual(port, 25565)
    }

    func testParseEmptyReturnsDefaults() {
        let (host, port) = MinecraftServer.parse("   ")
        XCTAssertEqual(host, "")
        XCTAssertEqual(port, 25565)
    }

    // MARK: - 字段计算

    func testHostStripsPort() {
        let server = MinecraftServer(name: "服", address: "play.x.com:25565")
        XCTAssertEqual(server.host, "play.x.com")
        XCTAssertEqual(server.connectAddress, "play.x.com:25565")
    }

    func testConnectAddressReflectsPortChange() {
        var server = MinecraftServer(name: "服", address: "play.x.com:25565")
        server.port = 25567
        XCTAssertEqual(server.connectAddress, "play.x.com:25567")
    }

    func testNameFallsBackToAddress() {
        let server = MinecraftServer(name: "", address: "fallback.com:25565")
        XCTAssertEqual(server.name, "fallback.com:25565")
    }

    // MARK: - 持久化

    func testStoreStartsEmpty() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ServerListStore(fileURL: url).load().isEmpty)
    }

    func testStoreRoundTripAndFavoriteFirst() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ServerListStore(fileURL: url)
        let favorite = MinecraftServer(name: "A", address: "a.com:25565", isFavorite: true)
        let normal = MinecraftServer(name: "B", address: "b.com:25566")
        store.save([normal, favorite])

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        // 收藏置顶。
        XCTAssertEqual(loaded.first?.name, "A")
        XCTAssertTrue(loaded.first?.isFavorite ?? false)
        XCTAssertEqual(loaded.last?.connectAddress, "b.com:25566")
    }

    func testPersistenceAcrossInstances() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        ServerListStore(fileURL: url).save([MinecraftServer(name: "X", address: "x.com:25565")])
        let reloaded = ServerListStore(fileURL: url).load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.name, "X")
    }

    private func temporaryStoreURL() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-test-servers-\(UUID().uuidString).json")
    }
}
