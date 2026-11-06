import Foundation

/// Maven 坐标（`group:artifact:version[:classifier]`）。
///
/// Fabric / Forge 等加载器 profile 的依赖库只有 `name` + `url`（仓库根），
/// 不带 Mojang 的 `downloads.artifact` 结构。jar 的真实地址要按 Maven 布局推导：
/// `group:artifact:version` → `<repo>/group/path/version/artifact-version.jar`。
struct MavenCoordinates: Equatable {
    let group: String
    let artifact: String
    let version: String
    let classifier: String?

    /// 解析失败返回 nil（坐标必须至少有 3 段）。
    init?(_ name: String) {
        let segments = name.split(separator: ":", omittingEmptySubsequences: false)
        guard (3...4).contains(segments.count) else { return nil }
        let fields = segments.map(String.init)
        guard fields.allSatisfy({ !$0.isEmpty }) else { return nil }
        group = fields[0]
        artifact = fields[1]
        version = fields[2]
        classifier = segments.count == 4 ? fields[3] : nil
    }

    init(group: String, artifact: String, version: String, classifier: String? = nil) {
        self.group = group
        self.artifact = artifact
        self.version = version
        self.classifier = classifier
    }

    /// 相对仓库根的 jar 路径，例如
    /// `net/fabricmc/sponge-mixin/0.15.5+mixin.0.8.7/sponge-mixin-0.15.5+mixin.0.8.7.jar`。
    var artifactPath: String {
        let groupPath = group.replacingOccurrences(of: ".", with: "/")
        let base = "\(artifact)-\(version)"
        let file = classifier.map { "\(base)-\($0)" } ?? base
        return "\(groupPath)/\(artifact)/\(version)/\(file).jar"
    }

    /// 仓库根 + 推导路径。仓库根缺失或不是合法 URL 时返回 nil。
    func fileURL(repoBase: String?) -> URL? {
        guard let repoBase, !repoBase.isEmpty else { return nil }
        // 仓库根统一以 / 结尾，避免拼接出 "net/xxxhttps://" 这类坏地址。
        let base = repoBase.hasSuffix("/") ? repoBase : repoBase + "/"
        return URL(string: base + artifactPath)
    }
}
