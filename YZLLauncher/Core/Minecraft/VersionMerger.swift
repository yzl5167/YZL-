import Foundation

/// 把可能 `inheritsFrom` 的版本 JSON 递归拍平成一个自包含的完整 `VersionDetail`。
///
/// 例如 Forge 1.20.1 只描述差异、继承官方 1.20.1：合并后父版本的全部库、客户端 jar、
/// 资源索引与参数都会带下来，主类 / 参数以子版本（loader）为准。拍平结果可直接存盘，
/// 启动时离线读取，无需再次联网解析继承链。
enum VersionMerger {
    /// - Parameters:
    ///   - root: 最具体的版本（最终要启动的那个）。
    ///   - localLookup: 按 id 在本地已安装版本里找父版本 JSON；找不到返回 `nil`。
    static func merge(root: VersionDetail, localLookup: (String) -> VersionDetail?) -> VersionDetail {
        guard let parentID = root.inheritsFrom, let parent = localLookup(parentID) else {
            return root
        }
        let base = merge(root: parent, localLookup: localLookup)
        return flatten(child: root, onto: base)
    }

    private static func flatten(child: VersionDetail, onto base: VersionDetail) -> VersionDetail {
        var libraries = base.libraries ?? []
        for library in child.libraries ?? [] where !libraries.contains(where: { $0.name == library.name }) {
            libraries.append(library)
        }
        return VersionDetail(
            id: child.id,
            type: child.type,
            downloads: child.downloads ?? base.downloads,
            javaVersion: child.javaVersion ?? base.javaVersion,
            mainClass: child.mainClass ?? base.mainClass,
            libraries: libraries,
            assetIndex: child.assetIndex ?? base.assetIndex,
            assets: child.assets ?? base.assets,
            inheritsFrom: nil,
            minecraftArguments: child.minecraftArguments ?? base.minecraftArguments,
            arguments: child.arguments ?? base.arguments
        )
    }
}
