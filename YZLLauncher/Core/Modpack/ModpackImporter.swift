import Foundation

// MARK: - 错误

enum ModpackError: LocalizedError {
    case emptyArchive
    case noMetadata
    case notMinecraftModpack
    case missingMinecraftVersion
    case metadataCorrupt(String)
    case unsupportedLoader(String)
    case baseVersionUnavailable(String)
    case curseForgeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyArchive:
            return "压缩包里没有可安装的整合包内容（既没有元数据，也没有 mods / config / 存档等内容目录）。"
        case .noMetadata:
            return "没有识别出整合包元数据，也不是常见的整合包目录结构。"
        case .notMinecraftModpack:
            return "这不是 Minecraft 整合包（modrinth.index.json 的 game 字段不是 minecraft）。"
        case .missingMinecraftVersion:
            return "整合包没有指定 Minecraft 版本，无法自动安装基础版本。"
        case .metadataCorrupt(let detail):
            return "整合包元数据解析失败：\(detail)"
        case .unsupportedLoader(let name):
            return "\(name) 暂不支持：它的安装器需要运行 Java 字节码，iOS 端无法执行。请改用 Fabric / Quilt 整合包。"
        case .baseVersionUnavailable(let name):
            return "基础版本（\(name)）信息获取失败，请检查网络后重试。"
        case .curseForgeUnavailable(let detail):
            return "CurseForge 文件信息获取失败：\(detail)。MCIM 镜像不可用时请稍后再试。"
        }
    }
}

// MARK: - 计划模型

/// 整合包格式（判定顺序与 Windows 端 ReadModpackPlan 一致）。
enum ModpackFormat: String {
    case modrinth
    case curseforge
    case yzl
    case mmc
    case pcl
    case generic
}

/// 需要在线下载的一个文件（解析元数据得到；CurseForge 的 URL 在 prepare 阶段解析）。
struct ModpackOnlineFile {
    /// 实例 game 目录内的相对路径（`/` 分隔），如 `mods/fabric-api.jar`。
    let relativePath: String
    /// 顺序即重试顺序：第 1 条进主源，第 2 条进 fallbackURL。
    let urls: [URL]
    let sha1: String?
    let size: Int64?
}

/// CurseForge 在线文件引用（URL 要按 projectID/fileID 向 MCIM 查询）。
struct CurseForgeFileRef: Equatable {
    let projectID: Int
    let fileID: Int
}

enum ModpackOnlineSource {
    case direct([ModpackOnlineFile])
    case curseForge([CurseForgeFileRef])
}

/// 一个「从 zip 解压到 game/」的条目；relativePath 已完成
/// 公共顶层前缀 / .minecraft / overrides 剥离，直接对应 game 目录内路径。
struct ModpackExtractItem {
    let entry: ZIPEntry
    let relativePath: String
}

/// inspect 的产出：导入前的完整计划（预览卡展示 + prepare 消费）。
struct ModpackPlan {
    let format: ModpackFormat
    let packName: String
    let packVersion: String
    let minecraftVersion: String
    /// nil = 原版；forge / neoforge 在 inspect 阶段就抛错，不会走到这里。
    let loader: LoaderKind?
    let loaderVersion: String?
    let onlineSource: ModpackOnlineSource
    let extractItems: [ModpackExtractItem]
    let localFileCount: Int
    let localBytes: Int64
}

/// prepare 的产出：版本目录已建好、基础版本与整合包 JSON 已落盘、下载清单已生成，
/// 交给调用方 queue.start(specs, batchID: packID) 启动下载。
struct ModpackInstallReceipt {
    let packID: String
    let baseVersionID: String
    let specs: [DownloadSpec]
    let baseDetail: VersionDetail
    let baseVersion: MinecraftVersion
    let baseFileCount: Int
    let baseBytes: Int64
    let modpackDetail: VersionDetail
    let modpackVersion: MinecraftVersion
    let modpackFileCount: Int
    let modpackBytes: Int64
    /// CurseForge 世界 ZIP：下载完成后解压到 saves/。
    let savedWorldZips: [(zipURL: URL, targetDirectory: URL)]
}

// MARK: - 导入器

enum ModpackImporter {
    /// 内容根目录名：作为 zip 唯一顶层文件夹时不视为包装层（与 Windows 端一致）。
    private static let contentRoots: Set<String> = [
        "mods", "config", "defaultconfigs", "resourcepacks", "shaderpacks",
        "saves", "scripts", "kubejs", "PCL", "overrides", "client-overrides",
        "server-overrides", ".minecraft"
    ]
    /// 普通包解压时跳过的顶层目录（引擎运行产物 / 下载缓存，接收方自己会生成）。
    private static let noiseDirectories: Set<String> = [
        "versions", "assets", "libraries", "runtime", "logs",
        "crash-reports", "downloads", ".cache", "screenshots"
    ]
    /// 元数据文件名：解压时跳过（信息已进计划，不需要落进 game 目录）。
    private static let metadataFileNames: Set<String> = [
        "modrinth.index.json", "manifest.json", "mmc-pack.json",
        "minecraftinstance.json", "instance.cfg", "Setup.ini",
        "yzl.modpack.json", "icon.png", "cover.png"
    ]

    // MARK: 格式判定与解析

    /// 识别整合包（纯本地操作，不联网）。判定顺序：
    /// modrinth.index.json → yzl.modpack.json → mmc-pack.json → manifest.json → Setup.ini → 内容目录兜底。
    static func inspect(zipURL: URL) throws -> ModpackPlan {
        let entries = try ZIPReader.entries(at: zipURL)
        guard !entries.isEmpty else {
            throw ModpackError.emptyArchive
        }

        let rootPrefix = detectRootPrefix(entries)
        // 剥掉公共顶层前缀后的相对名字（兼容「整合包名/manifest.json」套一层的情况）。
        let stripped = entries.map { (entry: $0, relative: stripPrefix($0.name, prefix: rootPrefix)) }

        // 元数据查找：名字完全等于候选或以 / 候选结尾。
        func find(_ name: String) -> ZIPEntry? {
            stripped.first { !$0.entry.isDirectory && ($0.relative == name || $0.relative.hasSuffix("/" + name)) }?.entry
        }

        var partial = PartialPlan()
        var format = ModpackFormat.generic

        if let entry = find("modrinth.index.json") {
            format = .modrinth
            partial = try parseModrinth(try ZIPReader.readData(entry, from: zipURL), partial: partial)
        } else if let entry = find("yzl.modpack.json") {
            format = .yzl
            partial = try parseYZLManifest(try ZIPReader.readData(entry, from: zipURL), partial: partial)
        } else if let entry = find("mmc-pack.json") {
            format = .mmc
            partial = try parseMMC(try ZIPReader.readData(entry, from: zipURL), partial: partial)
        } else if let entry = find("manifest.json") {
            format = .curseforge
            partial = try parseCurseForge(try ZIPReader.readData(entry, from: zipURL), partial: partial)
        }

        // 其余元数据按 Windows 的「读到了就填空、不覆盖已有值」补齐。
        if let entry = find("yzl.modpack.json"), format != .yzl {
            partial = try parseYZLManifest(try ZIPReader.readData(entry, from: zipURL), partial: partial)
        }
        if let entry = find("mmc-pack.json"), format != .mmc {
            partial = try parseMMC(try ZIPReader.readData(entry, from: zipURL), partial: partial)
        }
        if let entry = find("manifest.json"), format != .curseforge {
            partial = try parseCurseForge(try ZIPReader.readData(entry, from: zipURL), partial: partial)
        }
        if let entry = find("Setup.ini"), partial.minecraftVersion.isEmpty {
            partial = parsePCL(try ZIPReader.readData(entry, from: zipURL), partial: partial)
            if partial.loader != nil || !partial.minecraftVersion.isEmpty, format == .generic {
                format = .pcl
            }
        }
        if let entry = find("instance.cfg"), partial.packName.isEmpty {
            partial = parseInstanceCfg(try ZIPReader.readData(entry, from: zipURL), partial: partial)
        }

        // 加载器护栏：Forge / NeoForge 安装器需要运行 Java 字节码，iOS 端不支持。
        if partial.loader == nil, let rawLoader = partial.rawLoader?.lowercased(),
           rawLoader.contains("forge") || rawLoader.contains("neoforge") {
            throw ModpackError.unsupportedLoader(rawLoader.contains("neo") ? "NeoForge" : "Forge")
        }

        guard !partial.minecraftVersion.isEmpty else {
            throw ModpackError.missingMinecraftVersion
        }
        if partial.loader == nil, let rawLoader = partial.rawLoader?.lowercased() {
            partial.loader = loaderKind(from: rawLoader)
        }

        let extractItems = buildExtractItems(stripped: stripped, format: format)
        guard !extractItems.isEmpty || partial.onlineFiles != nil || partial.curseForgeFiles != nil else {
            throw ModpackError.emptyArchive
        }

        let onlineSource: ModpackOnlineSource
        if let files = partial.onlineFiles {
            onlineSource = .direct(files)
        } else if let refs = partial.curseForgeFiles {
            onlineSource = .curseForge(refs)
        } else {
            onlineSource = .direct([])
        }

        let localBytes = extractItems.reduce(Int64(0)) { $0 + $1.entry.uncompressedSize }
        return ModpackPlan(
            format: format,
            packName: partial.packName.isEmpty ? fallbackPackName(zipURL) : partial.packName,
            packVersion: partial.packVersion,
            minecraftVersion: partial.minecraftVersion,
            loader: partial.loader,
            loaderVersion: partial.loaderVersion,
            onlineSource: onlineSource,
            extractItems: extractItems,
            localFileCount: extractItems.count,
            localBytes: localBytes
        )
    }

    private struct PartialPlan {
        var packName = ""
        var packVersion = ""
        var minecraftVersion = ""
        var loader: LoaderKind?
        var loaderVersion: String?
        /// 元数据里出现的原始加载器名（forge 等，用于抛错与兜底识别）。
        var rawLoader: String?
        var onlineFiles: [ModpackOnlineFile]?
        var curseForgeFiles: [CurseForgeFileRef]?
    }

    /// 所有 entry 的顶层文件夹唯一且不是内容根时，视为包装层剥掉。
    static func detectRootPrefix(_ entries: [ZIPEntry]) -> String {
        let tops = Set(entries.compactMap { entry -> String? in
            let parts = entry.name.split(separator: "/")
            return parts.count > 1 ? String(parts[0]) : nil
        })
        guard tops.count == 1, let top = tops.first, !contentRoots.contains(top) else { return "" }
        return top + "/"
    }

    private static func stripPrefix(_ name: String, prefix: String) -> String {
        guard !prefix.isEmpty, name.hasPrefix(prefix) else { return name }
        return String(name.dropFirst(prefix.count))
    }

    private static func fallbackPackName(_ zipURL: URL) -> String {
        zipURL.deletingPathExtension().lastPathComponent
    }

    // MARK: 解析器（全部用 JSONSerialization，键名与 Windows 端逐字对齐）

    private static func jsonDict(_ data: Data, context: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw ModpackError.metadataCorrupt(context)
        }
        return dict
    }

    private static func parseModrinth(_ data: Data, partial: PartialPlan) throws -> PartialPlan {
        var next = partial
        let dict = try jsonDict(data, context: "modrinth.index.json")
        guard let game = dict["game"] as? String, game.lowercased() == "minecraft" else {
            throw ModpackError.notMinecraftModpack
        }
        if next.packName.isEmpty, let name = dict["name"] as? String { next.packName = name }
        if next.packVersion.isEmpty, let version = dict["versionId"] as? String { next.packVersion = version }
        guard let dependencies = dict["dependencies"] as? [String: Any],
              let mc = dependencies["minecraft"] as? String, !mc.isEmpty else {
            throw ModpackError.missingMinecraftVersion
        }
        if next.minecraftVersion.isEmpty { next.minecraftVersion = mc }

        // 加载器依赖键优先级与 Windows 端一致：fabric-loader > quilt-loader > neoforge > forge。
        for (key, value) in dependencies {
            let raw = (value as? String) ?? ""
            switch key {
            case "fabric-loader":
                next.loader = .fabric
                next.loaderVersion = raw.isEmpty ? nil : raw
            case "quilt-loader":
                if next.loader == nil {
                    next.loader = .quilt
                    next.loaderVersion = raw.isEmpty ? nil : raw
                }
            case "neoforge", "forge":
                if next.loader == nil {
                    next.rawLoader = key
                }
            default:
                break
            }
        }

        // files[]：跳过 env.client == "unsupported"（纯服务端文件）。
        var files: [ModpackOnlineFile] = []
        if let list = dict["files"] as? [[String: Any]] {
            for item in list {
                guard let path = item["path"] as? String, !path.isEmpty else { continue }
                if let env = item["env"] as? [String: Any],
                   let client = env["client"] as? String,
                   client.lowercased() == "unsupported" {
                    continue
                }
                let urls = ((item["downloads"] as? [Any])?.compactMap { ($0 as? String).flatMap(URL.init(string:)) }) ?? []
                guard !urls.isEmpty else { continue }
                let sha1 = (item["hashes"] as? [String: Any])?["sha1"] as? String
                let size = (item["fileSize"] as? NSNumber)?.int64Value
                files.append(ModpackOnlineFile(relativePath: path, urls: urls, sha1: sha1, size: size))
            }
        }
        next.onlineFiles = files
        return next
    }

    private static func parseYZLManifest(_ data: Data, partial: PartialPlan) throws -> PartialPlan {
        var next = partial
        let dict = try jsonDict(data, context: "yzl.modpack.json")
        if next.packName.isEmpty, let name = dict["name"] as? String { next.packName = name }
        if next.packVersion.isEmpty, let version = dict["version"] as? String { next.packVersion = version }
        if next.minecraftVersion.isEmpty {
            next.minecraftVersion = (dict["minecraft"] as? String) ?? (dict["minecraftVersion"] as? String) ?? ""
        }
        if next.loader == nil, let loader = dict["loader"] as? String {
            next.rawLoader = loader
            next.loader = loaderKind(from: loader)
            if next.loaderVersion == nil, let version = dict["loaderVersion"] as? String, !version.isEmpty {
                next.loaderVersion = version
            }
        }
        return next
    }

    private static func parseMMC(_ data: Data, partial: PartialPlan) throws -> PartialPlan {
        var next = partial
        let dict = try jsonDict(data, context: "mmc-pack.json")
        guard let components = dict["components"] as? [[String: Any]] else {
            return next
        }
        for component in components {
            guard let uid = component["uid"] as? String else { continue }
            let version = (component["version"] as? String) ?? ""
            if uid == "net.minecraft" || uid == "com.mojang.minecraft" {
                if next.minecraftVersion.isEmpty { next.minecraftVersion = version }
            } else if uid.contains("fabric-loader") {
                next.loader = .fabric
                if version.isEmpty == false { next.loaderVersion = version }
            } else if uid.contains("quilt-loader") {
                next.loader = .quilt
                if version.isEmpty == false { next.loaderVersion = version }
            } else if uid.contains("neoforge") || uid.contains("minecraftforge") || uid == "net.minecraftforge" {
                next.rawLoader = uid.contains("neo") ? "NeoForge" : "Forge"
            }
        }
        return next
    }

    private static func parseCurseForge(_ data: Data, partial: PartialPlan) throws -> PartialPlan {
        var next = partial
        let dict = try jsonDict(data, context: "manifest.json")
        if next.packName.isEmpty, let name = dict["name"] as? String { next.packName = name }
        if next.packVersion.isEmpty, let version = dict["version"] as? String { next.packVersion = version }
        guard let minecraft = dict["minecraft"] as? [String: Any],
              let mc = minecraft["version"] as? String, !mc.isEmpty else {
            throw ModpackError.missingMinecraftVersion
        }
        if next.minecraftVersion.isEmpty { next.minecraftVersion = mc }

        // modLoaders[]：primary 优先取第一个；id 形如 "fabric-0.16.14" / "forge-47.2.0"。
        if let modLoaders = minecraft["modLoaders"] as? [[String: Any]] {
            let sorted = modLoaders.sorted { ($0["primary"] as? Bool ?? false) && !($1["primary"] as? Bool ?? false) }
            for loaderDict in sorted {
                guard let id = loaderDict["id"] as? String else { continue }
                let parts = id.split(separator: "-", maxSplits: 1).map(String.init)
                let kindName = parts.first?.lowercased() ?? ""
                let version = parts.count > 1 ? parts[1] : nil
                if kindName == "fabric" || kindName == "quilt" {
                    next.loader = kindName == "fabric" ? .fabric : .quilt
                    next.loaderVersion = version
                    next.rawLoader = kindName
                    break
                } else if kindName.contains("forge") || kindName.contains("neo") {
                    next.rawLoader = kindName.contains("neo") ? "NeoForge" : "Forge"
                    break
                }
            }
        }

        // files[]：只装 required（缺省 true，显式 false 才算可选），按 (projectID, fileID) 去重。
        var refs: [CurseForgeFileRef] = []
        var seen = Set<CurseForgeFileRef>()
        if let files = dict["files"] as? [[String: Any]] {
            for file in files {
                let required = file["required"] as? Bool ?? true
                guard required else { continue }
                guard let projectID = (file["projectID"] as? NSNumber)?.intValue,
                      let fileID = (file["fileID"] as? NSNumber)?.intValue,
                      projectID > 0, fileID > 0 else { continue }
                let ref = CurseForgeFileRef(projectID: projectID, fileID: fileID)
                if seen.insert(ref).inserted {
                    refs.append(ref)
                }
            }
        }
        next.curseForgeFiles = refs
        return next
    }

    /// PCL 的 Setup.ini：分隔符冒号与等号都认，键名小写化。
    private static func parsePCL(_ data: Data, partial: PartialPlan) -> PartialPlan {
        var next = partial
        let text = String(decoding: data, as: UTF8.self)
        var values: [String: String] = [:]
        for line in text.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("[") else { continue }
            // 取先出现者：Windows 端语义（冒号与等号都支持）。
            let colon = trimmed.firstIndex(of: ":")
            let equal = trimmed.firstIndex(of: "=")
            let separator: (index: String.Index, char: String)?
            switch (colon, equal) {
            case (let c?, let e?):
                separator = (min(c, e), String(trimmed[min(c, e)]))
            case (let c?, nil):
                separator = (c, ":")
            case (nil, let e?):
                separator = (e, "=")
            default:
                separator = nil
            }
            guard let separator else { continue }
            let key = String(trimmed[..<separator.index]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(trimmed[trimmed.index(after: separator.index)...]).trimmingCharacters(in: .whitespaces)
            if values[key] == nil { values[key] = value }
        }

        let mcKeys = ["versionvanillaname", "versionoriginal", "version", "gameversion", "minecraftversion"]
        for key in mcKeys where next.minecraftVersion.isEmpty {
            if let value = values[key], !value.isEmpty {
                next.minecraftVersion = value
            }
        }
        if next.loader == nil {
            for (key, kind) in [("versionfabric", LoaderKind.fabric), ("versionquilt", LoaderKind.quilt)] {
                if let value = values[key], !value.isEmpty {
                    next.loader = kind
                    next.loaderVersion = value
                    next.rawLoader = kind.rawValue
                    break
                }
            }
        }
        if next.loader == nil, let loaderName = values["loader"] ?? values["loadertype"] {
            next.rawLoader = loaderName
            next.loader = loaderKind(from: loaderName)
            if next.loaderVersion == nil, let version = values["loaderversion"] ?? values["loader-version"], !version.isEmpty {
                next.loaderVersion = version
            }
        }
        if next.minecraftVersion.isEmpty, let mc = Self.firstMatch(in: text, pattern: "1\\.\\d+(\\.\\d+)?") {
            next.minecraftVersion = mc
        }
        return next
    }

    private static func parseInstanceCfg(_ data: Data, partial: PartialPlan) -> PartialPlan {
        var next = partial
        let text = String(decoding: data, as: UTF8.self)
        for line in text.lines where line.hasPrefix("name=") {
            next.packName = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            break
        }
        return next
    }

    private static func loaderKind(from raw: String) -> LoaderKind? {
        let lowered = raw.lowercased()
        if lowered.contains("fabric") { return .fabric }
        if lowered.contains("quilt") { return .quilt }
        return nil
    }

    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.range
        guard let range, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    // MARK: 解压条目规划

    /// 按格式决定哪些 zip 条目解压到 game/，以及剥前缀后的相对路径。
    /// overrides 先解、client-overrides 后解（后者覆盖前者），与 Windows 端顺序一致。
    private static func buildExtractItems(stripped: [(entry: ZIPEntry, relative: String)],
                                          format: ModpackFormat) -> [ModpackExtractItem] {
        var overrides: [ModpackExtractItem] = []
        var clientOverrides: [ModpackExtractItem] = []
        var plain: [ModpackExtractItem] = []
        let onlyOverrides = format == .modrinth || format == .curseforge

        for (entry, relative) in stripped {
            guard !relative.isEmpty else { continue }
            // 剥 .minecraft/ 前缀。
            var path = relative
            if path.hasPrefix(".minecraft/") {
                path = String(path.dropFirst(".minecraft/".count))
            }
            guard !path.isEmpty else { continue }

            if path.hasPrefix("server-overrides/") || path == "server-overrides" {
                continue
            }

            let isMetadata = metadataFileNames.contains { path == $0 || path.hasSuffix("/" + $0) }

            if path.hasPrefix("overrides/") {
                guard !isMetadata else { continue }
                overrides.append(ModpackExtractItem(entry: entry, relativePath: String(path.dropFirst("overrides/".count))))
                continue
            }
            if path.hasPrefix("client-overrides/") {
                guard !isMetadata else { continue }
                clientOverrides.append(ModpackExtractItem(entry: entry, relativePath: String(path.dropFirst("client-overrides/".count))))
                continue
            }
            if onlyOverrides {
                // mrpack / CF 包：元数据之外只认 overrides，其余（如果打包者乱塞）跳过。
                continue
            }

            // 顶层噪音目录（运行产物 / 共享库），接收方按版本 JSON 重新生成。
            let topLevel = path.split(separator: "/").first.map(String.init) ?? path
            if noiseDirectories.contains(topLevel) {
                continue
            }
            // yzl 自家导出的 zip：根上的版本 JSON / 客户端 jar 是基础版本的产物，
            // 基础版本会从 Mojang 重新安装，这里不落进 game 目录。
            if format == .yzl, !path.contains("/"),
               path.hasSuffix(".json") || path.hasSuffix(".jar") {
                continue
            }
            guard !isMetadata else { continue }
            plain.append(ModpackExtractItem(entry: entry, relativePath: path))
        }

        let validOverrides = overrides.filter { !$0.relativePath.isEmpty }
        let validClient = clientOverrides.filter { !$0.relativePath.isEmpty }
        return validOverrides + validClient + plain
    }

    // MARK: 版本 ID

    /// `name-version` → 非法字符换 `-`、空格换 `-`、去首尾 `-.`、截断 56 字符；
    /// 重名时：同包（版本 JSON 里 yzlModpackName 相同）复用，否则加 `-MMddHHmm` 后缀。
    static func buildPackID(name: String, version: String, date: Date = Date(),
                            fileManager: FileManager = .default) -> String {
        let forbidden = "\\/:*?\"<>|"
        var base = ((name.isEmpty ? "整合包" : name) + "-" + (version.isEmpty ? "1.0" : version))
            .map { character -> Character in
                if forbidden.contains(character) || character == " " { return "-" }
                return character
            }
            .reduce("") { $0 + String($1) }

        func trim(_ text: String) -> String {
            var result = text
            while let first = result.first, first == "-" || first == "." { result.removeFirst() }
            while let last = result.last, last == "-" || last == "." { result.removeLast() }
            return String(result.prefix(56))
        }
        base = trim(base)
        if base.isEmpty { base = "modpack" }

        if fileManager.fileExists(atPath: InstallLayout.forVersion(base).root.path) {
            // 同包重装：读取旧版本 JSON 的 yzlModpackName 判断。
            let layout = InstallLayout.forVersion(base)
            if let data = try? Data(contentsOf: layout.versionJSON),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let existingName = object["yzlModpackName"] as? String,
               existingName == name {
                return base
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMddHHmm"
            let suffixed = trim(base + "-" + formatter.string(from: date))
            return suffixed.isEmpty ? base + "-1" : suffixed
        }
        return base
    }

    // MARK: 安装准备

    /// 落盘整合包版本目录 + 生成全部下载 spec（基础版本文件 + 在线文件）。
    /// 下载队列由调用方启动：`queue.start(receipt.specs, batchID: receipt.packID) { ... }`。
    /// 刻意不标 @MainActor：几百 MB 的解压不能占主线程。
    static func prepare(plan: ModpackPlan, zipURL: URL, date: Date = Date()) async throws -> ModpackInstallReceipt {
        let packID = buildPackID(name: plan.packName, version: plan.packVersion, date: date)
        let layout = InstallLayout.forVersion(packID)
        let manifestService = VersionManifestService()
        let detailService = VersionDetailService()
        let assetIndexService = AssetIndexService()

        // 1. 基础版本 detail：加载器走 Meta profile，原版走 Mojang 清单。
        var baseDetail: VersionDetail
        var baseVersion: MinecraftVersion
        if let loader = plan.loader {
            var loaderVersion = plan.loaderVersion ?? ""
            if loaderVersion.isEmpty {
                let entries = try await LoaderService().fetchLoaders(kind: loader, gameVersion: plan.minecraftVersion, limit: 1)
                loaderVersion = entries.first?.loader.version ?? ""
            }
            guard !loaderVersion.isEmpty else {
                throw ModpackError.baseVersionUnavailable("\(loader.rawValue) for \(plan.minecraftVersion)")
            }
            let profileURL = loader.profileURL(gameVersion: plan.minecraftVersion, loaderVersion: loaderVersion)
            baseDetail = try await detailService.fetch(detailURL: profileURL)
            baseVersion = MinecraftVersion(
                id: baseDetail.id,
                type: "release",
                url: profileURL,
                time: baseDetail.time ?? "",
                releaseTime: baseDetail.releaseTime ?? ""
            )
        } else {
            guard let detailURL = try await manifestService.detailURL(for: plan.minecraftVersion) else {
                throw ModpackError.baseVersionUnavailable(plan.minecraftVersion)
            }
            baseDetail = try await detailService.fetch(detailURL: detailURL)
            baseVersion = MinecraftVersion(
                id: baseDetail.id,
                type: baseDetail.type,
                url: detailURL,
                time: baseDetail.time ?? "",
                releaseTime: baseDetail.releaseTime ?? ""
            )
        }

        // 2. 拍平继承链并落盘祖先（与 VersionDetailViewModel.resolveInheritance 同一套）。
        if baseDetail.inheritsFrom != nil {
            baseDetail = try await resolveInheritance(baseDetail, manifestService: manifestService, detailService: detailService)
        }

        // 3. 基础版本文件 spec。已下载过的文件在队列里按 SHA-1 秒过，直接全量加入即可断点续装。
        let baseLayout = InstallLayout.forVersion(baseDetail.id)
        let basePlan = InstallPlanner.plan(detail: baseDetail, layout: baseLayout)
        var specs = basePlan.specs
        if let index = baseDetail.assetIndex {
            let document = try await assetIndexService.fetch(
                indexURL: index.url,
                cacheURL: baseLayout.assetIndexURL(id: index.id),
                expectedSHA1: index.sha1
            )
            specs.append(contentsOf: InstallPlanner.assetObjectPlan(document: document, layout: baseLayout, versionID: baseDetail.id).specs)
        }
        let baseFileCount = specs.count
        let baseBytes = specs.reduce(Int64(0)) { $0 + ($1.expectedSize ?? 0) }

        // 4. 解压本地内容到 game/（overrides 顺序已在计划里排好）。
        try FileManager.default.createDirectory(at: layout.gameDirectory, withIntermediateDirectories: true)
        for item in plan.extractItems {
            try ZIPReader.extract(item.entry, from: zipURL, to: layout.gameDirectory)
        }

        // 5. 在线文件 spec。
        var savedWorldZips: [(zipURL: URL, targetDirectory: URL)] = []
        switch plan.onlineSource {
        case .direct(let files):
            for file in files.sorted(by: { ($0.size ?? 0) > ($1.size ?? 0) }) {
                let destination = layout.gameDirectory.appendingPathComponent(file.relativePath)
                specs.append(makeModpackSpec(
                    packID: packID,
                    relativePath: file.relativePath,
                    urls: file.urls,
                    sha1: file.sha1,
                    size: file.size,
                    destination: destination
                ))
            }
        case .curseForge(let refs):
            for ref in refs.sorted(by: { $0.fileID < $1.fileID }) {
                let info = try await curseForgeFileInfo(ref)
                let directory = try await curseForgeDirectory(projectID: ref.projectID, fileName: info.fileName)
                let destination = layout.gameDirectory
                    .appendingPathComponent(directory, isDirectory: true)
                    .appendingPathComponent(info.fileName)
                let candidates = forgeCDNCandidates(fileID: ref.fileID, fileName: info.fileName, downloadURL: info.downloadURL)
                specs.append(makeModpackSpec(
                    packID: packID,
                    relativePath: directory + "/" + info.fileName,
                    urls: candidates,
                    sha1: nil,
                    size: info.length,
                    destination: destination
                ))
                if directory == "saves", info.fileName.lowercased().hasSuffix(".zip") {
                    let worldName = (info.fileName as NSString).deletingPathExtension
                    savedWorldZips.append((
                        zipURL: destination,
                        targetDirectory: layout.gameDirectory.appendingPathComponent("saves", isDirectory: true)
                            .appendingPathComponent(worldName, isDirectory: true)
                    ))
                }
            }
        }

        // 6. 写整合包版本 JSON（inheritsFrom 指向基础版本；启动时 VersionMerger 拍平）。
        let modpackDetail = try writeModpackVersionJSON(
            packID: packID,
            baseVersionID: baseDetail.id,
            packName: plan.packName,
            packVersion: plan.packVersion,
            layout: layout
        )
        let modpackVersion = MinecraftVersion(
            id: packID,
            type: "release",
            url: baseVersion.url,
            time: modpackDetail.time ?? "",
            releaseTime: modpackDetail.releaseTime ?? ""
        )

        let modpackFileCount = specs.count - baseFileCount
        let modpackBytes = specs.dropFirst(baseFileCount).reduce(Int64(0)) { $0 + ($1.expectedSize ?? 0) }
        return ModpackInstallReceipt(
            packID: packID,
            baseVersionID: baseDetail.id,
            specs: specs,
            baseDetail: baseDetail,
            baseVersion: baseVersion,
            baseFileCount: baseFileCount,
            baseBytes: baseBytes,
            modpackDetail: modpackDetail,
            modpackVersion: modpackVersion,
            modpackFileCount: modpackFileCount,
            modpackBytes: modpackBytes,
            savedWorldZips: savedWorldZips
        )
    }

    /// 下载队列全部完成后的收尾：解压 CurseForge 世界 ZIP。
    static func extractSavedWorlds(_ receipt: ModpackInstallReceipt) {
        for world in receipt.savedWorldZips {
            guard FileManager.default.fileExists(atPath: world.zipURL.path) else { continue }
            let entries = (try? ZIPReader.entries(at: world.zipURL)) ?? []
            for entry in entries {
                try? ZIPReader.extract(entry, from: world.zipURL, to: world.targetDirectory)
            }
            // 世界包解压完删除源 zip（与 Windows 端一致）。
            try? FileManager.default.removeItem(at: world.zipURL)
        }
    }

    /// 照 VersionDetailViewModel.resolveInheritance：本地优先取父版本，否则按清单取回，
    /// 逐层落盘后拍平存盘。
    private static func resolveInheritance(_ child: VersionDetail,
                                           manifestService: VersionManifestService,
                                           detailService: VersionDetailService) async throws -> VersionDetail {
        let chain = try await VersionInheritanceResolver.chain(root: child) { parentID in
            let parentLayout = InstallLayout.forVersion(parentID)
            if let data = try? Data(contentsOf: parentLayout.versionJSON),
               let local = try? JSONDecoder().decode(VersionDetail.self, from: data) {
                return local
            }
            guard let url = try await manifestService.detailURL(for: parentID) else {
                return nil
            }
            return try await detailService.fetch(detailURL: url)
        }
        for ancestor in chain.dropLast() {
            try? FileManager.default.createDirectory(at: InstallLayout.forVersion(ancestor.id).root, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(ancestor) {
                try? data.write(to: InstallLayout.forVersion(ancestor.id).versionJSON, options: .atomic)
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: chain.map { ($0.id, $0) })
        return VersionMerger.merge(root: child) { byID[$0] }
    }

    // MARK: 在线文件 spec

    /// 整合包文件的 spec：主源 = 第 1 条 URL，备用源 = 第 2 条；
    /// 只有一条 URL 时按 host 补 MCIM 镜像兜底（cdn.modrinth.com / forgecdn 系）。
    private static func makeModpackSpec(packID: String, relativePath: String, urls: [URL],
                                        sha1: String?, size: Int64?, destination: URL) -> DownloadSpec {
        var candidates = urls
        if let first = candidates.first, candidates.count < 2,
           let mirrored = mcimCandidate(of: first), !candidates.contains(mirrored) {
            candidates.append(mirrored)
        }
        let primary = candidates[0]
        let fallback = candidates.count > 1 ? candidates[1] : nil
        let bytes = size ?? 0
        return DownloadSpec(
            id: "modpack-\(DownloadPaths.sanitize(packID))-\(DownloadPaths.sanitize(relativePath))",
            url: primary,
            fallbackURL: fallback,
            destination: destination,
            expectedSHA1: sha1,
            expectedSize: size,
            segmentSize: bytes > 16_777_216 ? 2_097_152 : 1_048_576,
            maxConnections: bytes > InstallPlanner.smallFileThreshold ? 8 : 1
        )
    }

    /// Modrinth / CurseForge CDN 的 MCIM 代理（Windows 端同款兜底）。
    static func mcimCandidate(of url: URL) -> URL? {
        let host = url.host?.lowercased() ?? ""
        let mirrored = ["cdn.modrinth.com", "cdn-raw.modrinth.com",
                        "edge.forgecdn.net", "mediafilez.forgecdn.net"]
        guard mirrored.contains(host) else { return nil }
        return URL(string: "https://mod.mcimirror.top" + url.path)
    }

    // MARK: CurseForge 文件信息（全部走 MCIM，免 API key）

    private static func curseForgeFileInfo(_ ref: CurseForgeFileRef) async throws
        -> (fileName: String, downloadURL: URL?, length: Int64?) {
        let endpoint = "https://mod.mcimirror.top/curseforge/v1/mods/\(ref.projectID)/files/\(ref.fileID)"
        guard let url = URL(string: endpoint) else {
            throw ModpackError.curseForgeUnavailable("URL 无效")
        }

        var lastError = ""
        for attempt in 1...3 {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                request.setValue("YZLLauncher/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw ModpackError.curseForgeUnavailable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["data"] as? [String: Any],
                      let fileName = payload["fileName"] as? String, !fileName.isEmpty else {
                    throw ModpackError.curseForgeUnavailable("响应缺少 data.fileName")
                }
                let downloadURL = (payload["downloadUrl"] as? String).flatMap(URL.init(string:))
                let length = (payload["fileLength"] as? NSNumber)?.int64Value
                return (fileName, downloadURL, length)
            } catch {
                lastError = error.localizedDescription
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 800_000_000)
                }
            }
        }
        throw ModpackError.curseForgeUnavailable(lastError)
    }

    /// classId → 目录映射；查不到按扩展名兜底（.jar/.litemod → mods，否则 resourcepacks）。
    private static func curseForgeDirectory(projectID: Int, fileName: String) async throws -> String {
        let lowered = fileName.lowercased()
        func byExtension() -> String {
            lowered.hasSuffix(".jar") || lowered.hasSuffix(".litemod") ? "mods" : "resourcepacks"
        }

        guard let url = URL(string: "https://mod.mcimirror.top/curseforge/v1/mods/\(projectID)") else {
            return byExtension()
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("YZLLauncher/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["data"] as? [String: Any],
                  let classID = (payload["classId"] as? NSNumber)?.int64Value else {
                return byExtension()
            }
            switch classID {
            case 6: return "mods"
            case 12: return "resourcepacks"
            case 6552: return "shaderpacks"
            case 17: return "saves"
            case 6945: return "datapacks"
            default: return byExtension()
            }
        } catch {
            return byExtension()
        }
    }

    /// CF 文件候选链：downloadUrl（可能为 null）→ edge.forgecdn 规则地址，
    /// 再按 Windows 端顺序补 mediafilez / edge / MCIM 同路径。取前两条进主源 + 备源。
    static func forgeCDNCandidates(fileID: Int, fileName: String, downloadURL: URL?) -> [URL] {
        let escaped = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        func ruleURL(_ host: String) -> URL? {
            URL(string: "https://\(host)/files/\(fileID / 1000)/\(fileID % 1000)/\(escaped)")
        }

        var candidates: [URL] = []
        let primary = downloadURL ?? ruleURL("edge.forgecdn.net")
        if let primary { candidates.append(primary) }

        let path = primary?.path ?? "/files/\(fileID / 1000)/\(fileID % 1000)/\(escaped)"
        for host in ["mediafilez.forgecdn.net", "edge.forgecdn.net"] {
            if let candidate = URL(string: "https://" + host + path), !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }
        if let mcim = URL(string: "https://mod.mcimirror.top" + path), !candidates.contains(mcim) {
            candidates.append(mcim)
        }
        return candidates
    }

    // MARK: 版本 JSON 落盘

    /// 写整合包版本 JSON（字段与 Windows 端一致：yzlModpack 标记 + inheritsFrom 基础版本），
    /// 并解析回 VersionDetail 供安装记录使用。
    private static func writeModpackVersionJSON(packID: String, baseVersionID: String,
                                                packName: String, packVersion: String,
                                                layout: InstallLayout) throws -> VersionDetail {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let now = formatter.string(from: Date())

        var object: [String: Any] = [
            "id": packID,
            "inheritsFrom": baseVersionID,
            "type": "release",
            "time": now,
            "releaseTime": now,
            "yzlModpack": true,
            "yzlModpackName": packName
        ]
        if !packVersion.isEmpty {
            object["yzlModpackVersion"] = packVersion
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            throw ModpackError.metadataCorrupt("整合包版本 JSON 序列化失败")
        }
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try data.write(to: layout.versionJSON, options: .atomic)

        guard let detail = try? JSONDecoder().decode(VersionDetail.self, from: data) else {
            throw ModpackError.metadataCorrupt("整合包版本 JSON 回读失败")
        }
        return detail
    }
}
