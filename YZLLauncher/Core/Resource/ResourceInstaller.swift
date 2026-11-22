import Foundation

/// 把资源市场选中的 Modrinth 版本安装到某个已安装游戏版本。
/// 对齐 Windows 端 `InstallResource` + `InstallRequiredDependenciesAsync`：
/// 下载主文件到 mods/shaderpacks/resourcepacks，并递归补 required 前置（depth ≤ 4、去重防环）。
enum ResourceInstaller {
    struct InstallResult {
        var specs: [DownloadSpec]
        var messages: [String]
        var warnings: [String]

        var summary: String {
            var lines = messages
            if !warnings.isEmpty { lines += warnings }
            return lines.joined(separator: "\n")
        }
    }

    private static let maxDepth = 4

    /// 为一个版本生成下载规格。整合包（modpack）不由这里处理，走 ModpackImporter。
    static func specs(
        for version: ModrinthVersion,
        category: ResourceCategory,
        gameVersion: String?,
        loader: String?,
        installedVersionID: String
    ) async -> InstallResult {
        let layout = InstallLayout.forVersion(installedVersionID)
        let gameDir = layout.gameDirectory
        var specs: [DownloadSpec] = []
        var messages: [String] = []
        var warnings: [String] = []

        guard category != .modpack else {
            warnings.append("整合包请用版本页的「导入整合包」，不要在这里安装。")
            return InstallResult(specs: specs, messages: messages, warnings: warnings)
        }
        guard let subdir = category.targetSubdirectory else {
            return InstallResult(specs: specs, messages: messages, warnings: warnings)
        }
        let targetDir = gameDir.appendingPathComponent(subdir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            warnings.append("无法创建 \(subdir) 目录：\(error.localizedDescription)")
            return InstallResult(specs: specs, messages: messages, warnings: warnings)
        }

        // 主文件（含重复安装防护）。
        var visited = Set<String>()
        if appendMainFile(version, category: category, targetDir: targetDir,
                          specs: &specs, messages: &messages, warnings: &warnings) {
            visited.insert(version.projectID)
        }

        // 递归补 required 前置：depth ≤ 4，visited 去重防环，按目标加载器筛版本。
        if !visited.isEmpty {
            await collectDependencies(
                of: version, depth: 1, loader: loader, targetDir: targetDir,
                visited: &visited, specs: &specs, addedNames: &messages
            )
        }

        return InstallResult(specs: specs, messages: messages, warnings: warnings)
    }

    /// 把一个版本的主文件加入下载规格。返回是否真的加入（去重时返回 false）。
    @discardableResult
    private static func appendMainFile(
        _ version: ModrinthVersion,
        category: ResourceCategory,
        targetDir: URL,
        specs: inout [DownloadSpec],
        messages: inout [String],
        warnings: inout [String]
    ) -> Bool {
        guard let file = version.primaryFile, let url = URL(string: file.url) else {
            warnings.append("\(version.name) 没有可下载的文件，已跳过。")
            return false
        }
        let dest = targetDir.appendingPathComponent(file.filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            messages.append("\(file.filename) 已存在，跳过重复安装")
            return false
        }
        specs.append(DownloadSpec(
            id: "res:\(version.projectID):\(version.id)",
            url: url,
            destination: dest,
            expectedSHA1: file.hashes?.sha1,
            expectedSize: file.size
        ))
        messages.append("\(version.name) → \(category.targetSubdirectory ?? "mods")/\(file.filename)")
        return true
    }

    /// 递归收集 required 依赖。
    private static func collectDependencies(
        of version: ModrinthVersion,
        depth: Int,
        loader: String?,
        targetDir: URL,
        visited: inout Set<String>,
        specs: inout [DownloadSpec],
        addedNames: inout [String]
    ) async {
        guard depth <= maxDepth else { return }
        let requiredIDs = version.dependencies
            .filter { $0.isRequired }
            .compactMap { $0.projectID }
        guard !requiredIDs.isEmpty else { return }

        for depID in requiredIDs.prefix(12) {
            guard !visited.contains(depID) else { continue }
            visited.insert(depID)
            guard let depVersions = try? await ModrinthService.versions(for: depID),
                  let best = ModrinthService.pickBest(depVersions, gameVersion: version.gameVersions.first, loader: loader),
                  let depFile = best.version.primaryFile,
                  let depURL = URL(string: depFile.url) else { continue }
            let dest = targetDir.appendingPathComponent(depFile.filename)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            specs.append(DownloadSpec(
                id: "res-dep:\(depID):\(best.version.id)",
                url: depURL,
                destination: dest,
                expectedSHA1: depFile.hashes?.sha1,
                expectedSize: depFile.size
            ))
            addedNames.append("前置：\(best.version.name)")
            // 继续下钻其子依赖。
            await collectDependencies(
                of: best.version, depth: depth + 1, loader: loader,
                targetDir: targetDir, visited: &visited,
                specs: &specs, addedNames: &addedNames
            )
        }
    }
}
