import XCTest
@testable import YZLLauncher

/// 版本导出：CRC32 向量、ZIP 结构回读、导出清单字段、加载器识别与目录排除规则。
final class VersionExporterTests: XCTestCase {
    // MARK: - CRC32（已知向量）

    func testCRC32KnownVectors() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)), 0x414F_A339)
        XCTAssertEqual(CRC32.checksum(Data()), 0x0000_0000)
    }

    /// 分段喂入与一次性喂入结果一致（流式读取依赖这一点）。
    func testCRC32IncrementalUpdate() {
        let data = Data("123456789".utf8)
        var crc = CRC32()
        crc.update(data.prefix(4))
        crc.update(data.dropFirst(4))
        XCTAssertEqual(crc.checksum, 0xCBF4_3926)
    }

    // MARK: - 文件名与清单

    func testSuggestedNameSanitizesAndFormats() {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 7
        components.hour = 12
        let date = Calendar.current.date(from: components)!

        XCTAssertEqual(VersionExporter.suggestedName(for: "1.20.1", date: date), "1.20.1-20261107.zip")
        // 含非法字符的版本号逐个替换成下划线（与 Android 端同一张黑名单）。
        XCTAssertEqual(
            VersionExporter.suggestedName(for: "a/b:c*\"d", date: date),
            "a_b_c__d-20261107.zip"
        )
    }

    func testModpackManifestFieldsMatchAndroidFormat() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 7
        components.hour = 12
        let date = Calendar.current.date(from: components)!

        let data = VersionExporter.modpackManifest(
            name: "1.20.1",
            minecraft: "1.20.1",
            loader: "Fabric",
            loaderVersion: "0.16.14",
            baseVersionId: "1.20.1",
            exportedAt: date
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["format"] as? Int, 1)
        XCTAssertEqual(object["name"] as? String, "1.20.1")
        XCTAssertEqual(object["version"] as? String, "1.0")
        XCTAssertEqual(object["minecraft"] as? String, "1.20.1")
        XCTAssertEqual(object["loader"] as? String, "Fabric")
        XCTAssertEqual(object["loaderVersion"] as? String, "0.16.14")
        XCTAssertEqual(object["baseVersionId"] as? String, "1.20.1")
        XCTAssertNotNil(object["exportedAt"] as? String)
    }

    /// 原版导出 loaderVersion 为空串但键仍存在（与 Android 端「可空」语义一致）。
    func testModpackManifestAllowsEmptyLoaderVersion() throws {
        let data = VersionExporter.modpackManifest(
            name: "1.12.2", minecraft: "1.12.2", loader: "原版",
            loaderVersion: nil, baseVersionId: "1.12.2", exportedAt: Date()
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["loader"] as? String, "原版")
        XCTAssertEqual(object["loaderVersion"] as? String, "")
    }

    func testPCLSetupIni() {
        let ini = String(
            decoding: VersionExporter.pclSetupIni(minecraft: "1.20.1", loader: "Fabric", loaderVersion: "0.16.14"),
            as: UTF8.self
        )
        XCTAssertTrue(ini.contains("[Setup]"))
        XCTAssertTrue(ini.contains("Version=1.20.1"))
        XCTAssertTrue(ini.contains("Loader=Fabric"))
        XCTAssertTrue(ini.contains("LoaderVersion=0.16.14"))
    }

    // MARK: - 加载器识别

    private func decodeDetail(_ json: String) throws -> VersionDetail {
        try JSONDecoder().decode(VersionDetail.self, from: Data(json.utf8))
    }

    func testDetectLoaderVanilla() throws {
        let detail = try decodeDetail("{\"id\": \"1.20.1\", \"type\": \"release\"}")
        let loader = VersionExporter.detectLoader(detail: detail)
        XCTAssertEqual(loader.name, "原版")
        XCTAssertNil(loader.version)
        XCTAssertEqual(loader.baseVersion, "1.20.1")
    }

    func testDetectLoaderFabric() throws {
        let detail = try decodeDetail(
            "{"
            + "\"id\": \"fabric-loader-0.16.14-1.20.1\", "
            + "\"type\": \"release\", "
            + "\"inheritsFrom\": \"1.20.1\", "
            + "\"libraries\": [{\"name\": \"net.fabricmc:fabric-loader:0.16.14\", \"url\": \"https://maven.fabricmc.net/\"}]"
            + "}"
        )
        let loader = VersionExporter.detectLoader(detail: detail)
        XCTAssertEqual(loader.name, "Fabric")
        XCTAssertEqual(loader.version, "0.16.14")
        XCTAssertEqual(loader.baseVersion, "1.20.1")
    }

    func testDetectLoaderQuilt() throws {
        let detail = try decodeDetail(
            "{"
            + "\"id\": \"quilt-loader-0.24.0-1.20.1\", "
            + "\"type\": \"release\", "
            + "\"inheritsFrom\": \"1.20.1\", "
            + "\"libraries\": [{\"name\": \"org.quiltmc:quilt-loader:0.24.0\", \"url\": \"https://maven.quiltmc.org/repository/release/\"}]"
            + "}"
        )
        let loader = VersionExporter.detectLoader(detail: detail)
        XCTAssertEqual(loader.name, "Quilt")
        XCTAssertEqual(loader.version, "0.24.0")
    }

    // MARK: - ZIP 结构回读

    private struct ZipEntry {
        let name: String
        let crc: UInt32
        let data: Data
    }

    private func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// 手写 mini 解析器：EOCD → 中央目录 → 本地头 → 数据，逐条校验。
    private func readZipEntries(at url: URL) throws -> [ZipEntry] {
        let bytes = Array(try Data(contentsOf: url))
        XCTAssertTrue(bytes.count > 22)

        let eocdStart = bytes.count - 22
        XCTAssertEqual(Array(bytes[eocdStart..<(eocdStart + 4)]), [0x50, 0x4B, 0x05, 0x06], "EOCD 签名")
        let entryCount = Int(readU16(bytes, eocdStart + 10))
        let cdSize = Int(readU32(bytes, eocdStart + 12))
        let cdOffset = Int(readU32(bytes, eocdStart + 16))
        XCTAssertEqual(cdOffset + cdSize + 22, bytes.count, "EOCD 之后的偏移应该正好收尾")

        var entries: [ZipEntry] = []
        var cursor = cdOffset
        for _ in 0..<entryCount {
            XCTAssertEqual(readU32(bytes, cursor), 0x0201_4B50, "中央目录签名")
            let nameLength = Int(readU16(bytes, cursor + 28))
            let extraLength = Int(readU16(bytes, cursor + 30))
            let commentLength = Int(readU16(bytes, cursor + 32))
            let localOffset = Int(readU32(bytes, cursor + 42))
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)

            XCTAssertEqual(readU32(bytes, localOffset), 0x0403_4B50, "本地头签名")
            let crc = readU32(bytes, localOffset + 14)
            let size = readU32(bytes, localOffset + 18)
            let localNameLength = Int(readU16(bytes, localOffset + 26))
            let localExtraLength = Int(readU16(bytes, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            let data = Data(bytes[dataStart..<(dataStart + Int(size))])

            XCTAssertEqual(crc, CRC32.checksum(data), "\(name) 的 CRC 应与数据一致")
            entries.append(ZipEntry(name: name, crc: crc, data: data))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        XCTAssertEqual(cursor, cdOffset + cdSize, "中央目录应正好遍历完")
        return entries
    }

    // MARK: - 端到端导出

    func testExportEndToEndCollectsGameFilesAndExcludesNoise() throws {
        let versionID = "yzl-export-test-\(UUID().uuidString.lowercased())"
        let layout = InstallLayout.forVersion(versionID)
        let root = layout.root
        let fm = FileManager.default

        // 造一个 Fabric 加载器版本的目录结构。
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let detailJSON = "{"
            + "\"id\": \"\(versionID)\", "
            + "\"type\": \"release\", "
            + "\"inheritsFrom\": \"1.20.1\", "
            + "\"libraries\": [{\"name\": \"net.fabricmc:fabric-loader:0.16.14\"}]"
            + "}"
        try Data(detailJSON.utf8).write(to: layout.versionJSON)
        let jarBytes = Data("fake-client-jar-bytes".utf8)
        try jarBytes.write(to: layout.clientJar)

        let game = layout.gameDirectory
        try fm.createDirectory(at: game.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try fm.createDirectory(at: game.appendingPathComponent("saves/world"), withIntermediateDirectories: true)
        try fm.createDirectory(at: game.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: game.appendingPathComponent("crash-reports"), withIntermediateDirectories: true)
        let modBytes = Data("mod-jar-content".utf8)
        try modBytes.write(to: game.appendingPathComponent("mods/fabric-api.jar"))
        try Data("level".utf8).write(to: game.appendingPathComponent("saves/world/level.dat"))
        try Data("log".utf8).write(to: game.appendingPathComponent("logs/latest.log"))
        try Data("crash".utf8).write(to: game.appendingPathComponent("crash-reports/crash.txt"))
        try Data("junk".utf8).write(to: game.appendingPathComponent(".DS_Store"))

        let exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-export-test-\(UUID().uuidString)", isDirectory: true)

        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: exportDir)
        }

        let destination = exportDir.appendingPathComponent(VersionExporter.suggestedName(for: versionID))
        let result = try VersionExporter.export(versionID: versionID, to: destination)

        // 2 个元数据 + 版本 JSON + 客户端 jar（改名）+ mod + 存档 = 6 个条目；
        // logs / crash-reports / 隐藏文件不进包。
        let entries = try readZipEntries(at: destination)
        XCTAssertEqual(entries.count, 6)
        XCTAssertEqual(result.fileCount, 6)

        let names = Set(entries.map(\.name))
        let safe = layout.safeName
        XCTAssertTrue(names.contains("yzl.modpack.json"))
        XCTAssertTrue(names.contains("PCL/Setup.ini"))
        XCTAssertTrue(names.contains("\(safe).json"))
        XCTAssertTrue(names.contains("\(safe).jar"), "客户端 jar 应改名为 {id}.jar")
        XCTAssertFalse(names.contains("\(safe)-client.jar"))
        XCTAssertTrue(names.contains("mods/fabric-api.jar"))
        XCTAssertTrue(names.contains("saves/world/level.dat"))
        XCTAssertFalse(names.contains(where: { $0.hasPrefix("logs/") }))
        XCTAssertFalse(names.contains(where: { $0.hasPrefix("crash-reports/") }))
        XCTAssertFalse(names.contains(where: { $0.hasPrefix(".") }))

        // 数据逐字节一致。
        XCTAssertEqual(entries.first(where: { $0.name == "mods/fabric-api.jar" })?.data, modBytes)
        XCTAssertEqual(entries.first(where: { $0.name == "\(safe).jar" })?.data, jarBytes)

        // 元数据内容以生成值为准，识别为 Fabric。
        let manifest = entries.first(where: { $0.name == "yzl.modpack.json" })
        let manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(manifest).data) as? [String: Any]
        )
        XCTAssertEqual(manifestObject["loader"] as? String, "Fabric")
        XCTAssertEqual(manifestObject["loaderVersion"] as? String, "0.16.14")
        XCTAssertEqual(manifestObject["baseVersionId"] as? String, "1.20.1")
    }

    func testExportWithoutVersionJSONFails() {
        let versionID = "yzl-export-empty-\(UUID().uuidString.lowercased())"
        let exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-export-test-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: InstallLayout.forVersion(versionID).root)
            try? FileManager.default.removeItem(at: exportDir)
        }
        XCTAssertThrowsError(try VersionExporter.export(versionID: versionID, to: exportDir)) { error in
            guard case VersionExporter.ExportError.versionJSONMissing = error else {
                return XCTFail("应报版本 JSON 缺失，实际：\(error)")
            }
        }
    }
}
