import Foundation

/// iOS 端更新日志（硬编码，与 Windows / Android 端同模式：最新版本在最前）。
/// 「关于」页直接展示；不做远程拉取（与另外两端一致）。
enum ReleaseNotes {
    struct Entry {
        let version: String
        let items: [String]
    }

    static let history: [Entry] = [
        Entry(version: "0.2.0", items: [
            "新增：整合包导入（Modrinth .mrpack / CurseForge / PCL / MMC / YZL 导出 ZIP），自动装基础版本并做移动端适配",
            "新增：微软账号皮肤上传、恢复默认与披风管理（Mojang 官方档案）",
            "新增：模组管理（开关、搜索、删除，兼容「极端兼容」的中转目录）",
            "新增：皮肤站账号游戏内皮肤注入（authlib-injector）",
        ]),
        Entry(version: "0.1.1", items: [
            "新增：皮肤站账号（LittleSkin 等所有 authlib-injector 标准皮肤站），启动参数带上 Yggdrasil 令牌",
            "新增：下载源健康检查与一键测速，坏掉的镜像自动排到最后",
            "新增：版本导出 ZIP（含 PCL 兼容标记，可与 PCL / 安卓端互通）与版本删除",
            "新增：3D 皮肤预览（走路动画、拖动旋转，照安卓端算法移植）",
        ]),
        Entry(version: "0.1.0", items: [
            "M0：FCL 式界面、Mojang 版本清单、分片断点续传下载、微软登录、启动自检",
            "M2-b：Amethyst 引擎包（JRE 8/17/21/25 + 图形 dylib + YZL UI 注入件），云构建直出 TrollStore 包",
        ]),
    ]

    static var currentVersion: String {
        DeviceInfo.appVersion
    }

    /// 全部历史：「v{版本}」标题行 + 「• 」条目，版本之间空行。
    static func homeText() -> String {
        history.map { entry in
            "v\(entry.version)\n" + entry.items.map { "• \($0)" }.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    /// 当前版本条目（版本号对不上时回退到最新一条，开发构建也能看到内容）。
    static var current: Entry {
        history.first { $0.version == currentVersion } ?? (history.first ?? Entry(version: currentVersion, items: []))
    }
}
