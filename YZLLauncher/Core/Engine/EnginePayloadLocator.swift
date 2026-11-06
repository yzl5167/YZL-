import Foundation

/// M2-b 引擎件定位：扫描 App Bundle 里 Amethyst 引擎 payload 是否齐备。
///
/// 完整引擎 payload（随 fork 构建的 `.tipa` 进入 bundle）：
/// - `java_runtimes/`：JRE 8/17/21/25（构建期从 assets.angelauramc.dev 下载裁剪）
/// - `Frameworks/`：libpojavexec*、GL4ES/Mesa/MetalANGLE/MoltenVK/OpenAL 等 dylib
/// - `libs/`：JavaApp 产物（PojavLauncher.jar、patchjna_agent.jar 等）
/// - `libs_caciocavallo/`（Java 8）与 `libs_caciocavallo17/`（Java 9+）：AWT 桥 jar
///
/// 缺任何一件都如实报告，绝不假装引擎可用；启动面板按此给出逐件诊断。
enum EnginePayloadLocator {
    /// 单个引擎件的存在性。
    struct Component: Equatable {
        let kind: Kind
        let isPresent: Bool
        let detail: String

        enum Kind: String, CaseIterable {
            case javaRuntimes = "java_runtimes"
            case frameworks = "Frameworks"
            case libs = "libs"
            case caciocavallo8 = "libs_caciocavallo"
            case caciocavallo17 = "libs_caciocavallo17"
        }
    }

    struct Payload: Equatable {
        let components: [Component]

        /// 四件核心（JRE、图形 dylib、Java 桥 jar、cacio 17）齐备才算「引擎可启动」。
        /// caciocavallo8 只在 Java 8 版本需要，缺失只降级说明不算硬缺失。
        var isLaunchable: Bool {
            requiredComponents.allSatisfy(\.isPresent)
        }

        var requiredComponents: [Component] {
            components.filter { $0.kind != .caciocavallo8 }
        }

        var missingKinds: [Component.Kind] {
            requiredComponents.filter { !$0.isPresent }.map(\.kind)
        }

        /// 面板用的一句话摘要。
        var summary: String {
            if isLaunchable {
                let jreNames = javaRuntimeNames.joined(separator: " / ")
                return "引擎件齐备（\(jreNames) · \(frameworkCount) 个 dylib）"
            }
            let names = missingKinds.map(\.rawValue).joined(separator: ", ")
            return "缺引擎件：\(names)"
        }

        // 便捷读取
        private func component(_ kind: Component.Kind) -> Component? {
            components.first { $0.kind == kind }
        }

        var javaRuntimeNames: [String] {
            guard let runtimes = component(.javaRuntimes), runtimes.isPresent else { return [] }
            // String.split(separator:) 的字符串分隔符重载是 iOS 16+，用 Foundation 的 components
            return runtimes.detail
                .components(separatedBy: ", ")
                .filter { !$0.isEmpty }
        }

        var frameworkCount: Int {
            component(.frameworks)?.detail.isEmpty == false ? Int(component(.frameworks)!.detail) ?? 0 : 0
        }
    }

    /// 扫描 bundle（可注入 fileManager 与 bundleURL 便于单测）。
    static func scan(bundleURL: URL? = nil, fileManager: FileManager = .default) -> Payload {
        let bundle = bundleURL ?? Bundle.main.bundleURL
        var components: [Component] = []

        components.append(javaRuntimesComponent(bundle: bundle, fileManager: fileManager))
        components.append(directoryComponent(.frameworks, bundle: bundle, fileManager: fileManager) { entries in
            let dylibs = entries.filter { $0.hasSuffix(".dylib") }
            return dylibs.isEmpty ? Component(kind: .frameworks, isPresent: false, detail: "")
                                  : Component(kind: .frameworks, isPresent: true, detail: "\(dylibs.count)")
        })
        components.append(directoryComponent(.libs, bundle: bundle, fileManager: fileManager) { entries in
            let jars = entries.filter { $0.hasSuffix(".jar") }
            return jars.isEmpty ? Component(kind: .libs, isPresent: false, detail: "")
                                : Component(kind: .libs, isPresent: true, detail: "\(jars.count) 个 jar")
        })
        components.append(directoryComponent(.caciocavallo8, bundle: bundle, fileManager: fileManager) { entries in
            let jars = entries.filter { $0.hasSuffix(".jar") }
            return Component(kind: .caciocavallo8, isPresent: !jars.isEmpty, detail: "\(jars.count) 个 jar")
        })
        components.append(directoryComponent(.caciocavallo17, bundle: bundle, fileManager: fileManager) { entries in
            let jars = entries.filter { $0.hasSuffix(".jar") }
            return jars.isEmpty ? Component(kind: .caciocavallo17, isPresent: false, detail: "")
                                : Component(kind: .caciocavallo17, isPresent: true, detail: "\(jars.count) 个 jar")
        })

        return Payload(components: components)
    }

    private static func javaRuntimesComponent(bundle: URL, fileManager: FileManager) -> Component {
        let root = bundle.appendingPathComponent("java_runtimes", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return Component(kind: .javaRuntimes, isPresent: false, detail: "")
        }
        // 只算真实可用的 JRE（有 libjli 标记的），与 RuntimeLocator 的判定一致。
        let validJREs = entries
            .filter { RuntimeLocator.isValidJRE(root.appendingPathComponent($0)) }
            .sorted()
        guard !validJREs.isEmpty else {
            return Component(kind: .javaRuntimes, isPresent: false, detail: "")
        }
        return Component(kind: .javaRuntimes, isPresent: true, detail: validJREs.joined(separator: ", "))
    }

    private static func directoryComponent(_ kind: Component.Kind,
                                           bundle: URL,
                                           fileManager: FileManager,
                                           evaluate: ([String]) -> Component) -> Component {
        let path = bundle.appendingPathComponent(kind.rawValue, isDirectory: true)
        let entries = (try? fileManager.contentsOfDirectory(atPath: path.path)) ?? []
        return evaluate(entries)
    }
}
