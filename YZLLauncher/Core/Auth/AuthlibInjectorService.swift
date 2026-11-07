import Foundation
import CryptoKit

/// authlib-injector（Yggdrasil 注入器）工件。
struct AuthlibInjectorArtifact: Equatable {
    let version: String
    let downloadURL: URL
    /// 官方 latest.json 的 checksums.sha256（实测是字符串数组，取第一个；缺失时只做粗校验）。
    let sha256: String?
}

enum AuthlibInjectorError: LocalizedError {
    case badLatestJSON
    case downloadTooSmall
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .badLatestJSON:
            return "authlib-injector 版本信息解析失败。"
        case .downloadTooSmall:
            return "authlib-injector 下载内容异常（体积过小），已放弃。"
        case .checksumMismatch:
            return "authlib-injector 下载校验失败（SHA-256 不符），已放弃。"
        }
    }
}

/// authlib-injector 的获取与 JVM 参数组装，协议与 Windows 端 `SkinStationAuth.EnsureAuthlibInjectorAsync`
/// 一致：
/// - `GET https://authlib-injector.yushi.moe/artifact/latest.json`，字段为
///   **download_url / version / checksums.sha256**（snake_case，没有 sha1、没有驼峰）；
/// - 缓存复用：同版本 jar 已在本地直接用（Windows 端只查文件 > 100KB，这里按版本号缓存更稳）；
/// - JVM 参数只有两条：`-javaagent:<jar>=<apiRoot>` + `-Dauthlibinjector.side=client`。
///
/// 皮肤站皮肤想在**游戏里**显示就靠它：把 Yggdrasil 认证服务器挂进游戏的会话链。
/// jar 拿不到不挡启动（与 Windows 端同语义）——只是游戏内不显示皮肤站皮肤。
enum AuthlibInjector {
    static let latestURL = URL(string: "https://authlib-injector.yushi.moe/artifact/latest.json")!
    /// 官方 jar 恒在 200KB 上下；低于这个值视为下载被劫持/截断。
    static let minimumJarBytes = 100_000

    static func jarDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("YZLLauncher", isDirectory: true)
            .appendingPathComponent("authlib-injector", isDirectory: true)
    }

    /// 解析 latest.json。实测响应形如：
    /// `{"build_number": "56", "version": "1.2.8", "download_url": ".../56/authlib-injector-1.2.8.jar",
    ///   "checksums": {"sha256": ["..."]}}`
    static func parseLatest(_ data: Data) -> AuthlibInjectorArtifact? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String, !version.isEmpty,
              let urlString = object["download_url"] as? String,
              let url = URL(string: urlString) else {
            return nil
        }
        var sha256: String?
        if let checksums = object["checksums"] as? [String: Any] {
            if let hash = checksums["sha256"] as? String {
                sha256 = hash
            } else if let hashes = checksums["sha256"] as? [String] {
                sha256 = hashes.first
            }
        }
        return AuthlibInjectorArtifact(version: version, downloadURL: url, sha256: sha256)
    }

    /// 注入参数（纯函数）。`serverURL` 直接拼在 `=` 后面，就是完整 Yggdrasil API Root。
    static func jvmArguments(jarPath: String, serverURL: String) -> [String] {
        ["-javaagent:\(jarPath)=\(serverURL)", "-Dauthlibinjector.side=client"]
    }

    /// LaunchPlan 里属于注入的参数（fork 引擎的 jvm_processed 转发用）。
    static func isInjectorArgument(_ argument: String) -> Bool {
        argument.hasPrefix("-javaagent:") || argument.hasPrefix("-Dauthlibinjector")
    }
}

struct AuthlibInjectorService {
    /// 拉取最新版本信息。
    func latest(session: URLSession = .shared) async throws -> AuthlibInjectorArtifact {
        var request = URLRequest(url: AuthlibInjector.latestURL)
        request.timeoutInterval = 20
        request.setValue("YZLLauncher/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthlibInjectorError.badLatestJSON
        }
        guard let artifact = AuthlibInjector.parseLatest(data) else {
            throw AuthlibInjectorError.badLatestJSON
        }
        return artifact
    }

    /// 确保本地有最新版 jar：同版本已存在直接复用，否则下载并按需校验 sha256。
    /// 返回 jar 绝对路径（进 `-javaagent`）与版本号。
    func ensureJar(session: URLSession = .shared, fileManager: FileManager = .default) async throws
        -> (jarPath: String, version: String) {
        let artifact = try await latest(session: session)
        let directory = AuthlibInjector.jarDirectory()
        let jarURL = directory.appendingPathComponent("authlib-injector-\(artifact.version).jar")

        if fileManager.fileExists(atPath: jarURL.path) {
            let size = (try? fileManager.attributesOfItem(atPath: jarURL.path))?[.size] as? Int ?? 0
            if size >= AuthlibInjector.minimumJarBytes {
                return (jarURL.path, artifact.version)
            }
            // 半截文件（上次下载中断）：删掉重下。
            try? fileManager.removeItem(at: jarURL)
        }

        var request = URLRequest(url: artifact.downloadURL)
        request.timeoutInterval = 60
        request.setValue("YZLLauncher/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthlibInjectorError.badLatestJSON
        }
        guard data.count >= AuthlibInjector.minimumJarBytes else {
            throw AuthlibInjectorError.downloadTooSmall
        }
        if let expected = artifact.sha256?.lowercased(), !expected.isEmpty {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expected.lowercased() else {
                throw AuthlibInjectorError.checksumMismatch
            }
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("jar.tmp")
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: jarURL.path) {
            try fileManager.removeItem(at: jarURL)
        }
        try fileManager.moveItem(at: temporary, to: jarURL)
        return (jarURL.path, artifact.version)
    }
}
