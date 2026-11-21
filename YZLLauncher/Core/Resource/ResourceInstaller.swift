import Foundation

/// 把资源市场选中的 Modrinth 版本安装到某个已安装游戏版本。
/// 对齐 Windows 端 `InstallResource`：下载主文件到 mods/shaderpacks/resourcepacks，
/// 并递归补装 required 前置依赖（只补一层，避免循环）。
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

    /// 为一个版本生成下载规格。整合包（modpack）不由这里处理，走 ModpackImporter。
    static func specs(
        for version: ModrinthVersion,
        category: ResourceCategory,
        gameVersion: String?,
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
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        if let file = version.primaryFile, let url = URL(string: file.url) {
            let sha1 = file.hashes?.sha1
            let dest = targetDir.appendingPathComponent(file.filename)
            specs.append(DownloadSpec(
                id: "res:\(version.projectID):\(version.id)",
                url: url,
                destination: dest,
                expectedSHA1: sha1,
                expectedSize: file.size
            ))
            messages.append("\(version.name) → \(subdir)/\(file.filename)")
        }

        // 前置依赖：只自动补 required，且只补一层（递归拉版本会放大请求且易循环）。
        let required = version.dependencies.filter { $0.isRequired }
        if !required.isEmpty {
            let depIDs = required.compactMap { $0.projectID }.prefix(8)
            var depAdded = 0
            for depID in depIDs {
                guard let depVersions = try? await ModrinthService.versions(for: depID),
                      let best = ModrinthService.pickBest(depVersions, gameVersion: gameVersion, loader: nil),
                      let depFile = best.version.primaryFile,
                      let depURL = URL(string: depFile.url) else { continue }
                let dest = targetDir.appendingPathComponent(depFile.filename)
                // 已装过同名文件就跳过。
                if FileManager.default.fileExists(atPath: dest.path) { continue }
                specs.append(DownloadSpec(
                    id: "res-dep:\(depID):\(best.version.id)",
                    url: depURL,
                    destination: dest,
                    expectedSHA1: depFile.hashes?.sha1,
                    expectedSize: depFile.size
                ))
                depAdded += 1
            }
            if depAdded > 0 {
                messages.append("另补 \(depAdded) 个必需前置模组")
            }
        }

        return InstallResult(specs: specs, messages: messages, warnings: warnings)
    }
}
