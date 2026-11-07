import XCTest
import Compression
@testable import YZLLauncher

/// ZIP 读取器：与 ZIPWriter 的 store 回读、手工组装的 deflate 包、
/// 加密包拒绝、路径穿越防护、目录条目与带注释 EOCD。
final class ZIPReaderTests: XCTestCase {
    // MARK: - 组装器（测试内部用；store/deflate/加密注释都支持）

    struct ZipSpec {
        let name: String
        let data: Data
        var method: UInt16 = 0
        var encrypted = false
    }

    /// 给测试文件复用的 zip 字节组装器（ModpackImporterTests 也用）。
    static func assembleZip(_ specs: [ZipSpec], comment: String = "") -> Data {
        func le16(_ value: UInt16, into data: inout Data) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }
        func le32(_ value: UInt32, into data: inout Data) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
        }

        var local = Data()
        var central = Data()
        var localOffsets: [Int] = []

        for spec in specs {
            localOffsets.append(local.count)
            let crc = CRC32.checksum(spec.data)
            let payload: Data
            switch spec.method {
            case 8: payload = deflate(spec.data)
            default: payload = spec.data
            }
            let nameBytes = Data(spec.name.utf8)
            var flags: UInt16 = 0x0800
            if spec.encrypted { flags |= 0x0001 }

            le32(0x0403_4B50, into: &local)
            le16(20, into: &local)
            le16(flags, into: &local)
            le16(spec.method, into: &local)
            le16(0, into: &local)
            le16(0x2100, into: &local)
            le32(crc, into: &local)
            le32(UInt32(payload.count), into: &local)
            le32(UInt32(spec.data.count), into: &local)
            le16(UInt16(nameBytes.count), into: &local)
            le16(0, into: &local)
            local.append(nameBytes)
            local.append(payload)

            le32(0x0201_4B50, into: &central)
            le16(20, into: &central)
            le16(20, into: &central)
            le16(flags, into: &central)
            le16(spec.method, into: &central)
            le16(0, into: &central)
            le16(0x2100, into: &central)
            le32(crc, into: &central)
            le32(UInt32(payload.count), into: &central)
            le32(UInt32(spec.data.count), into: &central)
            le16(UInt16(nameBytes.count), into: &central)
            le16(0, into: &central)
            le16(0, into: &central)
            le16(0, into: &central)
            le16(0, into: &central)
            le32(0, into: &central)
            le32(UInt32(localOffsets.last!), into: &central)
            central.append(nameBytes)
        }

        var zip = local
        let centralOffset = zip.count
        zip.append(central)
        let commentBytes = Data(comment.utf8)
        le32(0x0605_4B50, into: &zip)
        le16(0, into: &zip)
        le16(0, into: &zip)
        le16(UInt16(specs.count), into: &zip)
        le16(UInt16(specs.count), into: &zip)
        le32(UInt32(central.count), into: &zip)
        le32(UInt32(centralOffset), into: &zip)
        le16(UInt16(commentBytes.count), into: &zip)
        zip.append(commentBytes)
        return zip
    }

    static func deflate(_ data: Data) -> Data {
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let size = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return 0 }
                return compression_encode_buffer(
                    dstBase.assumingMemoryBound(to: UInt8.self),
                    capacity,
                    srcBase.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        return output.prefix(size)
    }

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-zip-\(UUID().uuidString).zip")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - store 回读（与自家 ZIPWriter 配对）

    func testStoreRoundtripWithOwnWriter() throws {
        let entries: [ZIPWriter.Entry] = [
            ZIPWriter.Entry(name: "mods/fabric-api.jar", data: Data("mod-content".utf8)),
            ZIPWriter.Entry(name: "config/opts.txt", data: Data("key=value".utf8)),
            ZIPWriter.Entry(name: "saves/", data: Data())
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-writer-\(UUID().uuidString).zip")
        try ZIPWriter.write(entries: entries, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let parsed = try ZIPReader.entries(at: url)
        XCTAssertEqual(parsed.count, 3)
        let mod = try XCTUnwrap(parsed.first { $0.name == "mods/fabric-api.jar" })
        XCTAssertFalse(mod.isDirectory)
        XCTAssertEqual(mod.uncompressedSize, Int64("mod-content".utf8.count))
        XCTAssertEqual(try ZIPReader.readData(mod, from: url), Data("mod-content".utf8))

        let saves = try XCTUnwrap(parsed.first { $0.name == "saves" })
        XCTAssertTrue(saves.isDirectory)
    }

    // MARK: - deflate

    func testDeflateRoundtrip() throws {
        let payload = Data(String(repeating: "压缩测试 compress me ", count: 200).utf8)
        let zip = Self.assembleZip([
            ZipSpec(name: "big/mod.jar", data: payload, method: 8)
        ])
        let url = try writeTemp(zip)

        let parsed = try ZIPReader.entries(at: url)
        let entry = try XCTUnwrap(parsed.first)
        XCTAssertEqual(entry.method, 8)
        XCTAssertEqual(entry.uncompressedSize, Int64(payload.count))
        // 压缩流应真的更小（重复文本压缩率高），证明走的不是 store。
        XCTAssertLessThan(entry.compressedSize, entry.uncompressedSize)
        XCTAssertEqual(try ZIPReader.readData(entry, from: url), payload)
    }

    // MARK: - EOCD 注释与损坏包

    func testEOCDWithComment() throws {
        let zip = Self.assembleZip([
            ZipSpec(name: "a.txt", data: Data("hello".utf8))
        ], comment: "some archiver left a comment here")
        let url = try writeTemp(zip)

        let parsed = try ZIPReader.entries(at: url)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].name, "a.txt")
    }

    func testGarbageFileThrowsNotAZip() throws {
        let url = try writeTemp(Data("definitely not a zip".utf8))
        XCTAssertThrowsError(try ZIPReader.entries(at: url)) { error in
            guard case ZIPError.notAZip = error else {
                return XCTFail("应报 notAZip，实际：\(error)")
            }
        }
    }

    // MARK: - 加密包

    func testEncryptedEntryIsRejected() throws {
        let zip = Self.assembleZip([
            ZipSpec(name: "secret.txt", data: Data("encrypted-ish".utf8), encrypted: true)
        ])
        let url = try writeTemp(zip)

        // 枚举能过（加密包照样能列目录），读数据时拒绝。
        let parsed = try ZIPReader.entries(at: url)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertThrowsError(try ZIPReader.readData(parsed[0], from: url)) { error in
            guard case ZIPError.encrypted = error else {
                return XCTFail("应报 encrypted，实际：\(error)")
            }
        }
    }

    // MARK: - 路径穿越

    func testPathTraversalIsRejectedOnExtract() throws {
        let zip = Self.assembleZip([
            ZipSpec(name: "../evil.txt", data: Data("boom".utf8))
        ])
        let url = try writeTemp(zip)

        let parsed = try ZIPReader.entries(at: url)
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-extract-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: target) }

        XCTAssertThrowsError(try ZIPReader.extract(parsed[0], from: url, to: target)) { error in
            guard case ZIPError.pathTraversal = error else {
                return XCTFail("应报 pathTraversal，实际：\(error)")
            }
        }
        // 目标目录里不应该出现任何东西。
        let survived = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
        XCTAssertTrue(survived.isEmpty, "穿越路径不应落盘：\(survived)")
    }

    func testIsSafeRelativePath() {
        XCTAssertTrue(ZIPReader.isSafeRelativePath("mods/a.jar"))
        XCTAssertTrue(ZIPReader.isSafeRelativePath("config/one/two.json"))
        XCTAssertFalse(ZIPReader.isSafeRelativePath("../evil"))
        XCTAssertFalse(ZIPReader.isSafeRelativePath("mods/../../evil"))
        XCTAssertFalse(ZIPReader.isSafeRelativePath("/absolute"))
        XCTAssertFalse(ZIPReader.isSafeRelativePath("back\\slash"))
        XCTAssertFalse(ZIPReader.isSafeRelativePath(""))
    }

    // MARK: - 目录条目

    func testDirectoryEntryCreatesFolderOnly() throws {
        let zip = Self.assembleZip([
            ZipSpec(name: "mods/", data: Data()),
            ZipSpec(name: "mods/inner.jar", data: Data("x".utf8))
        ])
        let url = try writeTemp(zip)

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("yzl-extract-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: target) }

        for entry in try ZIPReader.entries(at: url) {
            try ZIPReader.extract(entry, from: url, to: target)
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("mods").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("mods/inner.jar").path))
    }
}
