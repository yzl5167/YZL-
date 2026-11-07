import Foundation
import Compression

/// ZIP 容器的一个条目（由中央目录解析而来）。
/// `dataOffset` 是压缩数据在 zip 文件内的绝对偏移（已跳过本地头的变长 name/extra）。
struct ZIPEntry: Equatable {
    /// 相对路径，`/` 分隔；目录条目以 `/` 结尾。
    let name: String
    let isDirectory: Bool
    let uncompressedSize: Int64
    let compressedSize: Int64
    /// 0 = store（不压缩），8 = deflate。加密位在 flags 里单独检查。
    let method: UInt16
    let flags: UInt16
    let dataOffset: Int64
}

enum ZIPError: LocalizedError {
    case notAZip
    case encrypted
    case unsupportedCompression(UInt16)
    case unsupportedZip64
    case corrupt(String)
    case pathTraversal(String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .notAZip:
            return "这个文件不是有效的 ZIP 压缩包。"
        case .encrypted:
            return "压缩包带密码加密，iOS 端暂不支持，请先解密后再导入。"
        case .unsupportedCompression(let method):
            return "压缩包使用了不支持的压缩方式（method \(method)）。"
        case .unsupportedZip64:
            return "压缩包超过 4GB（ZIP64），iOS 端暂不支持。"
        case .corrupt(let detail):
            return "压缩包已损坏：\(detail)"
        case .pathTraversal(let name):
            return "压缩包内包含非法路径 \(name)，已拒绝解压（防止目录穿越）。"
        case .decodeFailed:
            return "解压数据失败：deflate 数据损坏。"
        }
    }
}

/// 纯 Swift ZIP 读取器（与 VersionExporter 里的 ZIPWriter 配对）：
/// EOCD 尾部扫描 → 中央目录解析 → 本地头定位，支持 store 与 deflate
///（deflate 用系统 Compression framework，COMPRESSION_ZLIB 即 raw deflate，
/// 与 ZIP 规范一致）。不支持的：加密包、ZIP64（>4GB）。
enum ZIPReader {
    // MARK: - 常量

    private static let eocdSignature: UInt32 = 0x0605_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50
    private static let localSignature: UInt32 = 0x0403_4B50
    /// EOCD 固定 22 字节 + 注释最长 65535。
    private static let eocdScanWindow = 22 + 65_535
    private static let storeMethod: UInt16 = 0
    private static let deflateMethod: UInt16 = 8
    /// flags 第 0 位 = 加密。
    private static let encryptedFlag: UInt16 = 0x0001

    // MARK: - 条目枚举

    static func entries(at zipURL: URL) throws -> [ZIPEntry] {
        let file = try FileHandle(forReadingFrom: zipURL)
        defer { try? file.close() }

        // seekToEnd 返回 UInt64，统一收成 Int64（后面偏移计算全用 Int64）。
        let fileSize = Int64(try file.seekToEnd())
        guard fileSize >= 22 else {
            throw ZIPError.notAZip
        }

        // 从尾部窗口里倒序找 EOCD 签名（容忍注释里恰好出现同字节序列的情况：
        // 取「其后 commentLen 正好到文件尾」的那个）。
        let scanStart = max(0, Int(fileSize) - eocdScanWindow)
        try file.seek(toOffset: UInt64(scanStart))
        let tail = try file.readToEnd() ?? Data()
        let tailBytes = [UInt8](tail)

        var eocdOffsetInTail = -1
        guard tailBytes.count >= 22 else { throw ZIPError.notAZip }
        var index = tailBytes.count - 22
        while index >= 0 {
            if readU32(tailBytes, index) == eocdSignature {
                let commentLength = Int(readU16(tailBytes, index + 20))
                if scanStart + index + 22 + commentLength == Int(fileSize) {
                    eocdOffsetInTail = index
                    break
                }
            }
            index -= 1
        }
        guard eocdOffsetInTail >= 0 else {
            throw ZIPError.notAZip
        }

        let entryCount = Int(readU16(tailBytes, eocdOffsetInTail + 10))
        let cdSize = Int64(readU32(tailBytes, eocdOffsetInTail + 12))
        let cdOffset = Int64(readU32(tailBytes, eocdOffsetInTail + 16))
        // 0xFFFFFFFF 是 ZIP64 标记；iOS 端明确不支持（整合包不该有 4GB 包体）。
        if cdSize >= Int64(UInt32.max) || cdOffset >= Int64(UInt32.max) {
            throw ZIPError.unsupportedZip64
        }

        try file.seek(toOffset: UInt64(cdOffset))
        // cdSize == 0（零条目的空包）时 read(upToCount: 0) 可能返回 nil，这里显式兜住。
        let centralDirectory: Data
        if cdSize == 0 {
            centralDirectory = Data()
        } else {
            guard let data = try file.read(upToCount: Int(cdSize)), data.count == Int(cdSize) else {
                throw ZIPError.corrupt("中央目录不完整")
            }
            centralDirectory = data
        }
        let cd = [UInt8](centralDirectory)

        var entries: [ZIPEntry] = []
        entries.reserveCapacity(entryCount)
        var cursor = 0
        for _ in 0..<entryCount {
            guard cursor + 46 <= cd.count else {
                throw ZIPError.corrupt("中央目录条目越界")
            }
            guard readU32(cd, cursor) == centralSignature else {
                throw ZIPError.corrupt("中央目录签名错误")
            }
            let flags = readU16(cd, cursor + 8)
            let method = readU16(cd, cursor + 10)
            let compressedSize = Int64(readU32(cd, cursor + 20))
            let uncompressedSize = Int64(readU32(cd, cursor + 24))
            let nameLength = Int(readU16(cd, cursor + 28))
            let extraLength = Int(readU16(cd, cursor + 30))
            let commentLength = Int(readU16(cd, cursor + 32))
            let localOffset = Int64(readU32(cd, cursor + 42))
            guard cursor + 46 + nameLength <= cd.count else {
                throw ZIPError.corrupt("中央目录文件名越界")
            }
            let name = String(decoding: cd[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)

            let isDirectory = name.hasSuffix("/")
            // 数据在本地头之后：30 字节固定头 + 本地 name/extra（可能与中央目录不同长，必须重读）。
            let dataOffset = try localDataOffset(file: file, localOffset: localOffset, fileSize: fileSize)

            entries.append(ZIPEntry(
                name: isDirectory ? String(name.dropLast()) : name,
                isDirectory: isDirectory,
                uncompressedSize: uncompressedSize,
                compressedSize: compressedSize,
                method: method,
                flags: flags,
                dataOffset: dataOffset
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// 读本地头，拿到变长字段后的真实数据偏移。
    private static func localDataOffset(file: FileHandle, localOffset: Int64, fileSize: Int64) throws -> Int64 {
        guard localOffset + 30 <= fileSize else {
            throw ZIPError.corrupt("本地头偏移越界")
        }
        try file.seek(toOffset: UInt64(localOffset))
        guard let header = try file.read(upToCount: 30), header.count == 30 else {
            throw ZIPError.corrupt("本地头不完整")
        }
        let bytes = [UInt8](header)
        guard readU32(bytes, 0) == localSignature else {
            throw ZIPError.corrupt("本地头签名错误")
        }
        let nameLength = Int(readU16(bytes, 26))
        let extraLength = Int(readU16(bytes, 28))
        return localOffset + 30 + Int64(nameLength + extraLength)
    }

    // MARK: - 数据读取

    /// 读出一个条目的完整内容（整合包条目最大也就几十 MB，一次读入可接受）。
    static func readData(_ entry: ZIPEntry, from zipURL: URL) throws -> Data {
        guard entry.flags & encryptedFlag == 0 else {
            throw ZIPError.encrypted
        }
        let file = try FileHandle(forReadingFrom: zipURL)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(entry.dataOffset))
        guard let compressed = try file.read(upToCount: Int(entry.compressedSize)),
              compressed.count == Int(entry.compressedSize) else {
            throw ZIPError.corrupt("条目 \(entry.name) 数据不完整")
        }

        switch entry.method {
        case storeMethod:
            return compressed
        case deflateMethod:
            return try inflate(compressed, expectedSize: Int(entry.uncompressedSize), name: entry.name)
        default:
            throw ZIPError.unsupportedCompression(entry.method)
        }
    }

    /// raw deflate 一次性解压：目标大小由中央目录给出，正好是
    /// compression_decode_buffer 需要的 dst 容量。
    private static func inflate(_ compressed: Data, expectedSize: Int, name: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let result = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstBase.assumingMemoryBound(to: UInt8.self),
                    expectedSize,
                    srcBase.assumingMemoryBound(to: UInt8.self),
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard result == expectedSize else {
            throw ZIPError.corrupt("条目 \(name) 解压后大小不符（\(result) / \(expectedSize)）")
        }
        return output
    }

    // MARK: - 解压落盘

    /// 把一个条目解压到 `directory` 下（保持 zip 内相对路径）。
    /// 带路径穿越防护：名字含 `..` 段、绝对路径或反斜杠的一律拒绝。
    static func extract(_ entry: ZIPEntry, from zipURL: URL, to directory: URL,
                        fileManager: FileManager = .default) throws {
        guard isSafeRelativePath(entry.name) else {
            throw ZIPError.pathTraversal(entry.name)
        }
        let target = directory.appendingPathComponent(entry.name)

        if entry.isDirectory {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            return
        }
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try readData(entry, from: zipURL)
        try data.write(to: target, options: .atomic)
    }

    /// 相对路径安全性：拒绝绝对路径、`..` 段与空段路径。
    static func isSafeRelativePath(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\") else { return false }
        let components = name.split(separator: "/")
        guard !components.isEmpty else { return false }
        return components.allSatisfy { $0 != ".." && $0 != "." }
    }

    // MARK: - 字节读取

    private static func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
