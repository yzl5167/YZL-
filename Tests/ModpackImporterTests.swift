import XCTest
@testable import YZLLauncher

/// 整合包导入：五种格式判定、rootPrefix 剥离、mrpack env 过滤、
/// CurseForge manifest 解析与 forge 拦截、overrides 解压规则、buildPackID。
final class ModpackImporterTests: XCTestCase {
    // MARK: - 造包工具

    /// 用 store 模式造一个整合包 zip（内容都是小文件，无需 deflate）。
    private func makePack(_ entries: [(name: String, data: String)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-pack-\(UUID().uuidString).zip")
        try ZIPWriter.write(
            entries: entries.map { ZIPWriter.Entry(name: $0.name, data: Data($0.data.utf8)) },
            to: url
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - YZL 自家导出格式

    func testInspectYZLExport() throws {
        let url = try makePack([
            ("yzl.modpack.json", "{\"format\": 1, \"name\": \"DarkRPG\", \"version\": \"1.0\", \"minecraft\": \"1.20.1\", \"loader\": \"Fabric\", \"loaderVersion\": \"0.16.14\", \"baseVersionId\": \"1.20.1\", \"exportedAt\": \"2026-11-07T00:00:00Z\"}"),
            ("PCL/Setup.ini", "[Setup]\nVersion=1.20.1\nLoader=Fabric"),
            ("DarkRPG-1.20.1.json", "{\"id\": \"DarkRPG-1.20.1\", \"type\": \"release\", \"inheritsFrom\": \"1.20.1\"}"),
            ("DarkRPG-1.20.1-client.jar", "jar-bytes"),
            ("mods/fabric-api.jar", "mod-bytes"),
            ("saves/world/level.dat", "level-bytes")
        ])

        let plan = try ModpackImporter.inspect(zipURL: url)
        XCTAssertEqual(plan.format, .yzl)
        XCTAssertEqual(plan.packName, "DarkRPG")
        XCTAssertEqual(plan.minecraftVersion, "1.20.1")
        XCTAssertEqual(plan.loader, .fabric)
        XCTAssertEqual(plan.loaderVersion, "0.16.14")

        // 本地解压清单：mods / saves 进包；元数据、PCL/、根上的版本 JSON 与客户端 jar 不进。
        let paths = plan.extractItems.map(\.relativePath)
        XCTAssertTrue(paths.contains("mods/fabric-api.jar"))
        XCTAssertTrue(paths.contains("saves/world/level.dat"))
        XCTAssertFalse(paths.contains { $0.hasSuffix(".json") && !$0.contains("/") })
        XCTAssertFalse(paths.contains { $0.hasSuffix(".jar") && !$0.contains("/") })
        XCTAssertFalse(paths.contains { $0.hasPrefix("PCL/") })
        XCTAssertTrue(plan.onlineSource.isDirectEmpty)
        XCTAssertEqual(plan.localFileCount, 2)
    }

    // MARK: - Modrinth .mrpack

    func testInspectModrinthFiltersEnvAndKeepsURLOrder() throws {
        let index = "{"
            + "\"formatVersion\": 1, \"game\": \"minecraft\", \"versionId\": \"2.3\", \"name\": \"Fabulously\", "
            + "\"dependencies\": {\"minecraft\": \"1.21.1\", \"fabric-loader\": \"0.16.9\"}, "
            + "\"files\": ["
            + "{\"path\": \"mods/keep.jar\", \"downloads\": [\"https://cdn.modrinth.com/a/keep.jar\", \"https://mirror.example/keep.jar\"], \"hashes\": {\"sha1\": \"abc123\"}, \"fileSize\": 4096, \"env\": {\"client\": \"required\", \"server\": \"required\"}}, "
            + "{\"path\": \"mods/server-only.jar\", \"downloads\": [\"https://cdn.modrinth.com/b/server-only.jar\"], \"fileSize\": 1, \"env\": {\"client\": \"unsupported\", \"server\": \"required\"}}"
            + "], "
            + "\"overrides\": \"overrides\"}"
        let url = try makePack([
            ("modrinth.index.json", index),
            ("overrides/config/opts.txt", "viewDistance=4"),
            ("client-overrides/config/opts.txt", "viewDistance=2"),
            ("overrides/config/server.txt", "server")
        ])

        let plan = try ModpackImporter.inspect(zipURL: url)
        XCTAssertEqual(plan.format, .modrinth)
        XCTAssertEqual(plan.minecraftVersion, "1.21.1")
        XCTAssertEqual(plan.loader, .fabric)
        XCTAssertEqual(plan.loaderVersion, "0.16.9")

        // env.client == unsupported 的文件被过滤。
        guard case .direct(let files) = plan.onlineSource else {
            return XCTFail("应为 direct 在线文件源")
        }
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].relativePath, "mods/keep.jar")
        XCTAssertEqual(files[0].sha1, "abc123")
        XCTAssertEqual(files[0].urls.count, 2)
        XCTAssertEqual(files[0].urls[0].absoluteString, "https://cdn.modrinth.com/a/keep.jar")

        // overrides 先解、client-overrides 后解（后者覆盖前者）；顺序必须保证。
        let configIndex = try XCTUnwrap(plan.extractItems.firstIndex { $0.relativePath == "config/opts.txt" && $0.entry.name.hasPrefix("overrides/") })
        let clientIndex = try XCTUnwrap(plan.extractItems.firstIndex { $0.relativePath == "config/opts.txt" && $0.entry.name.hasPrefix("client-overrides/") })
        XCTAssertLessThan(configIndex, clientIndex, "client-overrides 应排在 overrides 之后，解压时覆盖前者")
    }

    func testInspectModrinthRejectsNonMinecraft() throws {
        let url = try makePack([
            ("modrinth.index.json", "{\"game\": \"other-game\", \"dependencies\": {\"minecraft\": \"1.20.1\"}}")
        ])
        XCTAssertThrowsError(try ModpackImporter.inspect(zipURL: url)) { error in
            guard case ModpackError.notMinecraftModpack = error else {
                return XCTFail("应报 notMinecraftModpack，实际：\(error)")
            }
        }
    }

    // MARK: - CurseForge manifest

    func testInspectCurseForgeManifest() throws {
        let manifest = "{"
            + "\"manifestType\": \"minecraftModpack\", \"manifestVersion\": 1, "
            + "\"name\": \"CF Pack\", \"version\": \"3.1\", "
            + "\"minecraft\": {"
            + "\"version\": \"1.20.1\", "
            + "\"modLoaders\": [{\"id\": \"forge-47.2.0\"}, {\"id\": \"fabric-0.16.14\", \"primary\": true}]"
            + "}, "
            + "\"files\": ["
            + "{\"projectID\": 238222, \"fileID\": 4912540, \"required\": true}, "
            + "{\"projectID\": 111, \"fileID\": 222, \"required\": false}, "
            + "{\"projectID\": 333, \"fileID\": 444}, "
            + "{\"projectID\": 333, \"fileID\": 444}"
            + "]}"
        let url = try makePack([
            ("manifest.json", manifest),
            ("overrides/mods/jei.jar", "jei")
        ])

        let plan = try ModpackImporter.inspect(zipURL: url)
        XCTAssertEqual(plan.format, .curseforge)
        XCTAssertEqual(plan.packName, "CF Pack")
        XCTAssertEqual(plan.minecraftVersion, "1.20.1")
        XCTAssertEqual(plan.loader, .fabric, "primary 的 fabric 优先于 forge 条目")
        XCTAssertEqual(plan.loaderVersion, "0.16.14")

        guard case .curseForge(let refs) = plan.onlineSource else {
            return XCTFail("应为 curseForge 文件源")
        }
        // required=false 被过滤、非法 ID 被跳过、重复去重。
        XCTAssertEqual(refs, [CurseForgeFileRef(projectID: 238222, fileID: 4912540),
                              CurseForgeFileRef(projectID: 333, fileID: 444)])
    }

    func testInspectCurseForgeForgeLoaderIsRejected() throws {
        let manifest = "{"
            + "\"name\": \"ForgePack\", \"version\": \"1\", "
            + "\"minecraft\": {\"version\": \"1.20.1\", \"modLoaders\": [{\"id\": \"forge-47.2.0\", \"primary\": true}]}, "
            + "\"files\": []}"
        let url = try makePack([("manifest.json", manifest)])
        XCTAssertThrowsError(try ModpackImporter.inspect(zipURL: url)) { error in
            guard case ModpackError.unsupportedLoader = error else {
                return XCTFail("应报 unsupportedLoader，实际：\(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("Forge"), error.localizedDescription)
        }
    }

    // MARK: - MMC / PCL

    func testInspectMMCPack() throws {
        let pack = "{"
            + "\"formatVersion\": 1, "
            + "\"components\": ["
            + "{\"uid\": \"net.minecraft\", \"version\": \"1.20.1\"}, "
            + "{\"uid\": \"net.fabricmc.fabric-loader\", \"version\": \"0.16.14\"}"
            + "]}"
        let url = try makePack([
            ("mmc-pack.json", pack),
            ("instance.cfg", "name=MyMMCInstance\nInstanceType=OneSix"),
            (".minecraft/mods/old.jar", "x")
        ])

        let plan = try ModpackImporter.inspect(zipURL: url)
        XCTAssertEqual(plan.format, .mmc)
        XCTAssertEqual(plan.minecraftVersion, "1.20.1")
        XCTAssertEqual(plan.loader, .fabric)
        XCTAssertEqual(plan.packName, "MyMMCInstance")
        // MMC 包不是 only-overrides：.minecraft/ 前缀会被剥成普通内容。
        XCTAssertTrue(plan.extractItems.contains { $0.relativePath == "mods/old.jar" })
    }

    func testInspectPCLSetupIni() throws {
        let url = try makePack([
            ("PCL/Setup.ini", "[Setup]\nVersion=1.20.1\nLoader=Fabric\nLoaderVersion=0.16.14"),
            ("mods/a.jar", "a")
        ])
        let plan = try ModpackImporter.inspect(zipURL: url)
        XCTAssertEqual(plan.format, .pcl)
        XCTAssertEqual(plan.minecraftVersion, "1.20.1")
        XCTAssertEqual(plan.loader, .fabric)
        XCTAssertEqual(plan.loaderVersion, "0.16.14")
    }

    // MARK: - 通用 ZIP 与空壳拦截

    func testGenericZipWithoutVersionFails() throws {
        let url = try makePack([
            ("mods/a.jar", "a"),
            ("config/b.txt", "b")
        ])
        XCTAssertThrowsError(try ModpackImporter.inspect(zipURL: url)) { error in
            guard case ModpackError.missingMinecraftVersion = error else {
                return XCTFail("应报 missingMinecraftVersion，实际：\(error)")
            }
        }
    }

    func testEmptyArchiveIsRejected() throws {
        let url = try makePack([("readme.txt", "no content here")])
        XCTAssertThrowsError(try ModpackImporter.inspect(zipURL: url)) { error in
            guard case ModpackError.emptyArchive = error else {
                return XCTFail("应报 emptyArchive，实际：\(error)")
            }
        }
    }

    // MARK: - 公共顶层前缀剥离

    func testRootPrefixStripping() throws {
        let url = try makePack([
            ("MyPack/manifest.json", "{"
                + "\"name\": \"Nested\", \"version\": \"1\", "
                + "\"minecraft\": {\"version\": \"1.20.1\", \"modLoaders\": []}, "
                + "\"files\": []}"),
            ("MyPack/overrides/mods/a.jar", "a"),
            ("MyPack/overrides/config/b.txt", "b")
        ])

        let plan = try ModpackImporter.inspect(zipURL: url)
        XCTAssertEqual(plan.format, .curseforge)
        let paths = plan.extractItems.map(\.relativePath)
        XCTAssertTrue(paths.contains("mods/a.jar"), "公共顶层前缀应剥掉：\(paths)")
        XCTAssertFalse(paths.contains { $0.hasPrefix("MyPack/") })
    }

    // MARK: - buildPackID

    func testBuildPackIDSanitizeTruncateAndSuffix() {
        XCTAssertEqual(ModpackImporter.buildPackID(name: "DarkRPG", version: "2.0"), "DarkRPG-2.0")
        // 非法字符与空格 → -。
        XCTAssertEqual(ModpackImporter.buildPackID(name: "a/b:c d", version: "1"), "a-b-c-d-1")
        // 截断到 56 字符。
        let longName = String(repeating: "x", count: 80)
        XCTAssertLessThanOrEqual(ModpackImporter.buildPackID(name: longName, version: "1").count, 56)

        // 已有同名版本：同包复用，不同包加时间后缀。
        let fm = FileManager.default
        let existing = InstallLayout.forVersion("DarkRPG-2.0")
        try? fm.createDirectory(at: existing.root, withIntermediateDirectories: true)
        let reusedJSON = "{\"id\": \"DarkRPG-2.0\", \"type\": \"release\", \"yzlModpack\": true, \"yzlModpackName\": \"DarkRPG\"}"
        try? Data(reusedJSON.utf8).write(to: existing.versionJSON)
        defer { try? fm.removeItem(at: existing.root) }

        XCTAssertEqual(ModpackImporter.buildPackID(name: "DarkRPG", version: "2.0"), "DarkRPG-2.0", "同包重装应复用")

        // 不同包撞名：先造一个占用 "别的包-2.0" 的旧版本（yzlModpackName 不同），
        // 再导入新包应加 -MMddHHmm 后缀。
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 7
        components.hour = 12
        let date = Calendar.current.date(from: components)!
        let occupied = InstallLayout.forVersion("别的包-2.0")
        try? fm.createDirectory(at: occupied.root, withIntermediateDirectories: true)
        let otherJSON = "{\"id\": \"别的包-2.0\", \"type\": \"release\", \"yzlModpack\": true, \"yzlModpackName\": \"更早的包\"}"
        try? Data(otherJSON.utf8).write(to: occupied.versionJSON)
        defer { try? fm.removeItem(at: occupied.root) }

        let suffixed = ModpackImporter.buildPackID(name: "别的包", version: "2.0", date: date)
        XCTAssertTrue(suffixed.hasPrefix("别的包-2.0-1107"), "不同包重名应加 MMddHHmm 后缀：\(suffixed)")
    }

    // MARK: - CF URL 规则与 MCIM 兜底

    func testForgeCDNCandidates() {
        // downloadUrl 为空时按规则拼 edge.forgecdn.net（fileId/1000/fileId%1000/文件名）。
        let candidates = ModpackImporter.forgeCDNCandidates(fileID: 4912540, fileName: "JEI 1.20.1.jar", downloadURL: nil)
        XCTAssertEqual(candidates.first?.absoluteString, "https://edge.forgecdn.net/files/4912/540/JEI%201.20.1.jar")
        // 链里有 mediafilez 与 MCIM 兜底。
        XCTAssertTrue(candidates.contains { $0.host == "mediafilez.forgecdn.net" })
        XCTAssertTrue(candidates.contains { $0.host == "mod.mcimirror.top" })

        // 有 downloadUrl 时它排第一。
        let explicit = ModpackImporter.forgeCDNCandidates(
            fileID: 123, fileName: "a.jar",
            downloadURL: URL(string: "https://mediafilez.forgecdn.net/files/0/123/a.jar")
        )
        XCTAssertEqual(explicit.first?.host, "mediafilez.forgecdn.net")
    }

    func testMCIMCandidateOnlyMirrorsKnownCDNHosts() throws {
        let modrinth = try XCTUnwrap(URL(string: "https://cdn.modrinth.com/data/A/versions/1/file.jar"))
        XCTAssertEqual(
            ModpackImporter.mcimCandidate(of: modrinth)?.absoluteString,
            "https://mod.mcimirror.top/data/A/versions/1/file.jar"
        )
        let mojang = try XCTUnwrap(URL(string: "https://piston-data.mojang.com/v1/objects/abc/client.jar"))
        XCTAssertNil(ModpackImporter.mcimCandidate(of: mojang), "Mojang 域名走 MirrorPolicy，不走 MCIM")
    }
}

extension ModpackOnlineSource {
    /// 测试辅助：direct 源且为空。
    var isDirectEmpty: Bool {
        if case .direct(let files) = self { return files.isEmpty }
        return false
    }
}
