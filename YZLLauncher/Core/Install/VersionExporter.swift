import Foundation

// MARK: - CRC32

/// ZIP 用的 CRC-32（IEEE 802.3，多项式 0xEDB88320 反射形式）。
/// 纯 Swift 查表实现，零依赖、可单测（已知向量 "123456789" → 0xCBF43926）。
struct CRC32 {
    private var value: UInt32 = 0xFFFFFFFF

    static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var c = UInt32(index)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    mutating func update(_ byte: UInt8) {
        value = Self.table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for offset in 0..<data.count {
                update(base[offset])
            }
        }
    }

    var checksum: UInt32 { value ^ 0xFFFFFFFF }

    /// 一次性计算整段数据的 CRC-32。
    static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.checksum
    }
}

// MARK: - ZIP 写入（store 模式）

/// 手写的 ZIP 容器（不压缩的 store 模式）：本地文件头 + 中央目录 + EOCD。
/// 不引第三方库；客户端 jar 等本身已经是压缩格式，store 不吃亏，
/// mods / 配置等文本文件体积可接受（导出优先正确性）。
enum ZIPWriter {
    struct Entry {
        /// zip 内相对路径，统一用 `/` 分隔。
        let name: String
        let source: Source

        enum Source {
            case file(URL)
            case data(Data)
        }

        init(name: String, file: URL) {
            self.name = name
            self.source = .file(file)
        }

        init(name: String, data: Data) {
            self.name = name
            self.source = .data(data)
        }
    }

    enum ZIPError: LocalizedError {
        case unreadableFile(String)

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let path):
                return "无法读取待打包文件：\(path)"
            }
        }
    }

    private enum Constants {
        static let localHeaderSignature: UInt32 = 0x0403_4B50
        static let centralHeaderSignature: UInt32 = 0x0201_4B50
        static let endRecordSignature: UInt32 = 0x0605_4B50
        static let versionNeeded: UInt16 = 20
        static let versionMadeBy: UInt16 = 20
        /// 第 11 位：文件名按 UTF-8 解码。中文模组名 / 存档名必须带，否则解压乱码。
        static let utf8Flag: UInt16 = 0x0800
        static let storeMethod: UInt16 = 0
        /// 流式读取的块大小：1 MiB，单个 23 MB 的客户端 jar 也只会常驻这么点内存。
        static let chunkSize = 1 << 20
    }

    /// 把 entries 写成 ZIP 文件。条目按名字排序后写入，保证同一份内容产出字节级一致的包。
    static func write(entries: [Entry], to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        fm.createFile(atPath: destination.path, contents: Data())

        guard let output = FileHandle(forWritingAtPath: destination.path) else {
            throw ZIPError.unreadableFile(destination.path)
        }
        defer { try? output.close() }

        let (dosTime, dosDate) = dosDateTime(Date())
        var centralRecords = Data()
        var entryCount = 0

        for entry in entries.sorted(by: { $0.name < $1.name }) {
            let nameData = Data(entry.name.utf8)
            let localHeaderOffset = UInt32(output.offsetInFile)
            let crc: UInt32
            let size: UInt32

            switch entry.source {
            case .data(let data):
                crc = CRC32.checksum(data)
                size = UInt32(data.count)
                try output.write(header(
                    nameData: nameData,
                    crc: crc,
                    size: size,
                    dosTime: dosTime,
                    dosDate: dosDate
                ))
                try output.write(data)
            case .file(let url):
                guard let handle = FileHandle(forReadingAtPath: url.path) else {
                    throw ZIPError.unreadableFile(url.path)
                }
                defer { try? handle.close() }
                // 先扫一遍算 CRC 与总大小（ZIP 本地头要求提前写死这两个值）。
                var crcState = CRC32()
                var total: UInt64 = 0
                while let chunk = try handle.read(upToCount: Constants.chunkSize) {
                    crcState.update(chunk)
                    total += UInt64(chunk.count)
                }
                crc = crcState.checksum
                size = UInt32(total)

                try output.write(header(
                    nameData: nameData,
                    crc: crc,
                    size: size,
                    dosTime: dosTime,
                    dosDate: dosDate
                ))

                try handle.seek(toOffset: 0)
                while let chunk = try handle.read(upToCount: Constants.chunkSize) {
                    try output.write(chunk)
                }
            }

            centralRecords.append(centralHeader(
                nameData: nameData,
                crc: crc,
                size: size,
                dosTime: dosTime,
                dosDate: dosDate,
                localHeaderOffset: localHeaderOffset
            ))
            entryCount += 1
        }

        let centralOffset = UInt32(output.offsetInFile)
        try output.write(centralRecords)

        var end = Data()
        end.appendLE(Constants.endRecordSignature)
        end.appendLE(UInt16(0))                  // 磁盘号
        end.appendLE(UInt16(0))                  // 中央目录起始磁盘
        end.appendLE(UInt16(entryCount))         // 本磁盘条目数
        end.appendLE(UInt16(entryCount))         // 总条目数
        end.appendLE(UInt32(centralRecords.count))
        end.appendLE(centralOffset)
        end.appendLE(UInt16(0))                  // 注释长度
        try output.write(end)
    }

    private static func header(nameData: Data, crc: UInt32, size: UInt32,
                               dosTime: UInt16, dosDate: UInt16) -> Data {
        var header = Data()
        header.appendLE(Constants.localHeaderSignature)
        header.appendLE(Constants.versionNeeded)
        header.appendLE(Constants.utf8Flag)
        header.appendLE(Constants.storeMethod)
        header.appendLE(dosTime)
        header.appendLE(dosDate)
        header.appendLE(crc)
        header.appendLE(size)      // compressed（store 模式两者相同）
        header.appendLE(size)      // uncompressed
        header.appendLE(UInt16(nameData.count))
        header.appendLE(UInt16(0)) // extra 长度
        header.append(nameData)
        return header
    }

    private static func centralHeader(nameData: Data, crc: UInt32, size: UInt32,
                                      dosTime: UInt16, dosDate: UInt16,
                                      localHeaderOffset: UInt32) -> Data {
        var header = Data()
        header.appendLE(Constants.centralHeaderSignature)
        header.appendLE(Constants.versionMadeBy)
        header.appendLE(Constants.versionNeeded)
        header.appendLE(Constants.utf8Flag)
        header.appendLE(Constants.storeMethod)
        header.appendLE(dosTime)
        header.appendLE(dosDate)
        header.appendLE(crc)
        header.appendLE(size)
        header.appendLE(size)
        header.appendLE(UInt16(nameData.count))
        header.appendLE(UInt16(0)) // extra
        header.appendLE(UInt16(0)) // comment
        header.appendLE(UInt16(0)) // 起始磁盘
        header.appendLE(UInt16(0)) // 内部属性
        header.appendLE(UInt32(0)) // 外部属性
        header.appendLE(localHeaderOffset)
        header.append(nameData)
        return header
    }

    /// Date → ZIP 的 DOS 时间 / 日期（本地时区，2 秒精度）。
    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let year = max(components.year ?? 1980, 1980)
        let dateValue = UInt16(
            (year - 1980) << 9 | (components.month ?? 1) << 5 | (components.day ?? 1)
        )
        let timeValue = UInt16(
            (components.hour ?? 0) << 11 | (components.minute ?? 0) << 5 | (components.second ?? 0) / 2
        )
        return (timeValue, dateValue)
    }
}

private extension Data {
    /// 小端追加（ZIP 全部字段是小端序）。
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

// MARK: - 版本导出

struct VersionExportResult: Equatable {
    let fileCount: Int
    let totalBytes: Int64
}

/// 把已安装版本导出成 ZIP 整合包，格式与 Android 端 `core/VersionExporter.kt` 一致：
/// zip 根 = 版本目录内容 + `yzl.modpack.json`（强制的元数据入口）+ `PCL/Setup.ini`（PCL 兼容标记）。
/// assets / libraries / natives 不进包——接收方按版本 JSON 重新下载，几百 MB 不该塞进 zip。
enum VersionExporter {
    enum ExportError: LocalizedError {
        case versionJSONMissing
        case nothingToExport

        var errorDescription: String? {
            switch self {
            case .versionJSONMissing:
                return "版本 JSON 不存在，无法导出。请先完成安装。"
            case .nothingToExport:
                return "版本目录里没有可导出的文件。"
            }
        }
    }

    /// 导出文件名：非法字符替换成下划线，格式 `{id}-{yyyyMMdd}.zip`（与 Android 端一致）。
    static func suggestedName(for versionID: String, date: Date = Date()) -> String {
        let forbidden = "\\/:*?\"<>|"
        let sanitized = versionID
            .map { forbidden.contains($0) ? "_" : String($0) }
            .joined()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return "\(sanitized)-\(formatter.string(from: date)).zip"
    }

    /// 从版本 JSON 推断加载器（iOS 的安装记录没有单独存 loader 字段）。
    static func detectLoader(detail: VersionDetail) -> (name: String, version: String?, baseVersion: String) {
        let base = detail.inheritsFrom ?? detail.id
        guard detail.inheritsFrom != nil else {
            return ("原版", nil, base)
        }
        let names = (detail.libraries ?? []).compactMap { $0.name ?? nil }
        if let fabric = names.first(where: { $0.hasPrefix("net.fabricmc:fabric-loader:") }) {
            return ("Fabric", fabric.components(separatedBy: ":").dropFirst(2).first, base)
        }
        if let quilt = names.first(where: { $0.hasPrefix("org.quiltmc:quilt-loader:") }) {
            return ("Quilt", quilt.components(separatedBy: ":").dropFirst(2).first, base)
        }
        if names.contains(where: { $0.lowercased().contains("forge") }) {
            return ("Forge", nil, base)
        }
        return ("原版", nil, base)
    }

    /// `yzl.modpack.json`：格式 1，字段与 Android 端逐字对齐（2 空格缩进）。
    static func modpackManifest(name: String, minecraft: String, loader: String,
                                loaderVersion: String?, baseVersionId: String,
                                exportedAt: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: exportedAt)
        // 手写 JSON 保证与 Android 端完全相同的字段与缩进（没有 loaderVersion 也要出键，值为空串）。
        let loaderLine = "\"loaderVersion\": \"\(loaderVersion ?? "")\","
        let json = """
        {
          "format": 1,
          "name": "\(escapeJSON(name))",
          "version": "1.0",
          "minecraft": "\(escapeJSON(minecraft))",
          "loader": "\(escapeJSON(loader))",
          \(loaderLine)
          "baseVersionId": "\(escapeJSON(baseVersionId))",
          "exportedAt": "\(timestamp)"
        }
        """
        return Data(json.utf8)
    }

    /// `PCL/Setup.ini`：PCL 识别整合包用的标记文件。
    static func pclSetupIni(minecraft: String, loader: String, loaderVersion: String?) -> Data {
        let ini = """
        [Setup]
        Version=\(minecraft)
        Loader=\(loader)
        LoaderVersion=\(loaderVersion ?? "")
        """
        return Data(ini.utf8)
    }

    /// 收集要进 zip 的文件条目（zip 根 = 版本目录内容，与 Android 端布局一致，game/ 前缀拍平）：
    /// - 版本 JSON（原名）+ 客户端 jar（改名为 `{id}.jar`，对齐 PCL 的 versions/{id}/{id}.jar 约定）；
    /// - `game/` 整棵树的内容（mods / saves / config 都在里面），剔除 logs、crash-reports、
    ///   兼容备份与隐藏文件；
    /// - 排除 assets / libraries / natives（接收方按版本 JSON 重新下载）。
    static func collectEntries(versionID: String, layout: InstallLayout,
                               gameDirectoryExclusions: Set<String> = defaultGameExclusions) throws -> [ZIPWriter.Entry] {
        let fm = FileManager.default
        let safeName = layout.safeName
        var entries: [ZIPWriter.Entry] = []

        guard fm.fileExists(atPath: layout.versionJSON.path) else {
            throw ExportError.versionJSONMissing
        }
        entries.append(ZIPWriter.Entry(name: "\(safeName).json", file: layout.versionJSON))

        if fm.fileExists(atPath: layout.clientJar.path) {
            entries.append(ZIPWriter.Entry(name: "\(safeName).jar", file: layout.clientJar))
        }

        let gameRoot = layout.gameDirectory
        if fm.fileExists(atPath: gameRoot.path) {
            // prefix 传空串：第一层目录名直接成为 zip 根条目，排除名单在这一层生效。
            entries.append(contentsOf: collectDirectory(gameRoot, relativeTo: gameRoot, prefix: "",
                                                        exclusions: gameDirectoryExclusions))
        }

        guard !entries.isEmpty else {
            throw ExportError.nothingToExport
        }
        return entries
    }

    /// 递归收集目录内容为 zip 条目；跳过排除名单（只对第一层目录名生效）与隐藏文件。
    static func collectDirectory(_ directory: URL, relativeTo root: URL, prefix: String,
                                 exclusions: Set<String>) -> [ZIPWriter.Entry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        var entries: [ZIPWriter.Entry] = []
        for item in items.sorted { $0.lastPathComponent < $1.lastPathComponent } {
            let name = item.lastPathComponent
            if name.hasPrefix(".") { continue }
            let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"

            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                if prefix.isEmpty && exclusions.contains(name) {
                    // 只在第一层生效：logs / crash-reports / .yzl-compat-backup 不进包。
                    continue
                }
                entries.append(contentsOf: collectDirectory(item, relativeTo: root,
                                                            prefix: relative, exclusions: exclusions))
            } else {
                entries.append(ZIPWriter.Entry(name: relative, file: item))
            }
        }
        return entries
    }

    static let defaultGameExclusions: Set<String> = ["logs", "crash-reports", ".yzl-compat-backup"]

    /// 导出整包到指定位置（一般先写到 tmp，再让用户用文件面板选目的地）。
    /// 返回导出前的文件统计（文件数与原始字节），供完成提示使用。
    @discardableResult
    static func export(versionID: String, to destination: URL, date: Date = Date()) throws -> VersionExportResult {
        let layout = InstallLayout.forVersion(versionID)
        let entries = try collectEntries(versionID: versionID, layout: layout)

        // 元数据文件以生成内容为准（版本目录里万一有同名旧文件，跳过不进包）。
        let metadataNames: Set<String> = ["yzl.modpack.json", "PCL/Setup.ini"]
        let payload = entries.filter { !metadataNames.contains($0.name) }

        var detail: VersionDetail?
        if let data = try? Data(contentsOf: layout.versionJSON) {
            detail = try? JSONDecoder().decode(VersionDetail.self, from: data)
        }
        let loader = detail.map { detectLoader(detail: $0) } ?? ("原版", nil, versionID)

        var all: [ZIPWriter.Entry] = [
            ZIPWriter.Entry(
                name: "yzl.modpack.json",
                data: modpackManifest(
                    name: versionID,
                    minecraft: loader.baseVersion,
                    loader: loader.name,
                    loaderVersion: loader.version,
                    baseVersionId: loader.baseVersion,
                    exportedAt: date
                )
            ),
            ZIPWriter.Entry(
                name: "PCL/Setup.ini",
                data: pclSetupIni(
                    minecraft: loader.baseVersion,
                    loader: loader.name,
                    loaderVersion: loader.version
                )
            )
        ]
        all.append(contentsOf: payload)

        try ZIPWriter.write(entries: all, to: destination)

        var totalBytes: Int64 = 0
        for entry in payload {
            switch entry.source {
            case .file(let url):
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                totalBytes += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            case .data(let data):
                totalBytes += Int64(data.count)
            }
        }
        return VersionExportResult(fileCount: all.count, totalBytes: totalBytes)
    }

    private static func escapeJSON(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
