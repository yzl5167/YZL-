import Foundation

/// 解析 `inheritsFrom` 继承链，返回「从最顶层祖先到当前版本」的有序列表。
///
/// 例如 Fabric profile（`fabric-loader-0.16.14-1.20.1` → `1.20.1`）会得到
/// `[1.20.1, fabric-loader-0.16.14-1.20.1]`。安装流程用它把每一层祖先 JSON 取回
/// 并落盘，随后 `VersionMerger` 拍平成自包含版本；启动自检因此不再依赖网络。
enum VersionInheritanceResolver {
    enum ResolverError: LocalizedError, Equatable {
        /// 某层祖先在本地与 Mojang 清单里都找不到。
        case missingAncestor(String)
        /// 继承链出现环或超过深度上限。
        case cycleDetected(String)

        var errorDescription: String? {
            switch self {
            case .missingAncestor(let id):
                return "继承的父版本 \(id) 既不在本地也不在 Mojang 清单里，无法安装该版本。"
            case .cycleDetected(let id):
                return "版本 \(id) 的 inheritsFrom 链出现循环或超过最大深度。"
            }
        }
    }

    static let maxDepth = 10

    /// - Parameters:
    ///   - root: 已取到的子版本 JSON（继承链最具体的一层）。
    ///   - lookup: 按版本 id 取一层版本 JSON；本地已安装优先，否则走远端。找不到返回 nil。
    /// - Returns: `[最顶层祖先, …, 直接父版本, root]`，保证 root 在末尾。
    static func chain(root: VersionDetail,
                      lookup: (String) async throws -> VersionDetail?) async throws -> [VersionDetail] {
        var chain = [root]
        var seen = Set<String>([root.id])
        var current = root

        while let parentID = current.inheritsFrom {
            guard chain.count < maxDepth, !seen.contains(parentID) else {
                throw ResolverError.cycleDetected(parentID)
            }
            guard let parent = try await lookup(parentID) else {
                throw ResolverError.missingAncestor(parentID)
            }
            seen.insert(parentID)
            // 祖先插到链头，最终顺序就是 [顶层祖先, …, root]。
            chain.insert(parent, at: 0)
            current = parent
        }
        return chain
    }

    /// 便捷入口：直接对拍平结果负责——取回整条链后用 `VersionMerger` 合成自包含版本。
    static func flattened(root: VersionDetail,
                          lookup: (String) async throws -> VersionDetail?) async throws -> VersionDetail {
        let resolved = try await chain(root: root, lookup: lookup)
        let byID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
        return VersionMerger.merge(root: root) { byID[$0] }
    }
}
