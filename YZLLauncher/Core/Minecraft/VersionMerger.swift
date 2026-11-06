import Foundation

/// 把可能 `inheritsFrom` 的版本 JSON 递归拍平成一个自包含的完整 `VersionDetail`。
///
/// 例如 Forge 1.20.1 只描述差异、继承官方 1.20.1：合并后父版本的全部库、客户端 jar、
/// 资源索引与参数都会带下来。注意 Mojang 的继承语义是「数组追加、标量覆盖」——
/// 加载器 profile 的 `arguments.game: []` 表示追加零条，不是清空父版本参数。
/// 拍平结果可直接存盘，启动时离线读取，无需再次联网解析继承链。
enum VersionMerger {
    /// 最长继承链，防止本地 JSON 互相 `inheritsFrom` 造成无限递归。
    private static let maxDepth = 32

    /// - Parameters:
    ///   - root: 最具体的版本（最终要启动的那个）。
    ///   - localLookup: 按 id 在本地已安装版本里找父版本 JSON；找不到返回 `nil`。
    static func merge(root: VersionDetail, localLookup: (String) -> VersionDetail?) -> VersionDetail {
        var seen = Set<String>()
        return merge(root: root, localLookup: localLookup, seen: &seen)
    }

    private static func merge(root: VersionDetail,
                              localLookup: (String) -> VersionDetail?,
                              seen: inout Set<String>) -> VersionDetail {
        seen.insert(root.id)
        guard seen.count <= maxDepth,
              let parentID = root.inheritsFrom,
              !parentID.isEmpty,
              !seen.contains(parentID),
              let parent = localLookup(parentID) else {
            return root
        }
        let base = merge(root: parent, localLookup: localLookup, seen: &seen)
        return flatten(child: root, onto: base)
    }

    private static func flatten(child: VersionDetail, onto base: VersionDetail) -> VersionDetail {
        return VersionDetail(
            id: child.id,
            type: child.type,
            downloads: child.downloads ?? base.downloads,
            javaVersion: child.javaVersion ?? base.javaVersion,
            mainClass: child.mainClass ?? base.mainClass,
            libraries: mergedLibraries(base: base.libraries, child: child.libraries),
            assetIndex: child.assetIndex ?? base.assetIndex,
            assets: child.assets ?? base.assets,
            inheritsFrom: nil,
            minecraftArguments: child.minecraftArguments ?? base.minecraftArguments,
            arguments: mergedArguments(base: base.arguments, child: child.arguments)
        )
    }

    /// 同名库以子版本（加载器）为准：加载器常覆盖父版本的 ASM / Mixin 版本，
    /// 保留父版本那一个会把旧 jar 放进 classpath。
    private static func mergedLibraries(base: [VersionDetail.Library]?,
                                        child: [VersionDetail.Library]?) -> [VersionDetail.Library] {
        var result = base ?? []
        for library in child ?? [] {
            if let index = result.firstIndex(where: { $0.name == library.name }) {
                result[index] = library
            } else {
                result.append(library)
            }
        }
        return result
    }

    /// Mojang 继承：`arguments.game` / `arguments.jvm` 都是「父 + 子」拼接。
    /// 子版本 `game: []` 只表示不追加，绝不能把父版本的参数清空。
    private static func mergedArguments(base: VersionDetail.VersionArguments?,
                                        child: VersionDetail.VersionArguments?) -> VersionDetail.VersionArguments? {
        guard let child else { return base }
        guard let base else { return child }
        return VersionDetail.VersionArguments(
            jvm: (base.jvm ?? []) + (child.jvm ?? []),
            game: (base.game ?? []) + (child.game ?? [])
        )
    }
}
