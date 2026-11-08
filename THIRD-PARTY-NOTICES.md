# 第三方组件与许可声明

> 本文只做事实登记与义务提示，**不是法律意见**。对外分发任何包含引擎的
> `.ipa` / `.tipa` 之前，请自行确认许可合规，必要时咨询专业律师。

## 1. 两套产物，义务范围不同

| 产物 | 是否含第三方引擎代码 | 说明 |
| --- | --- | --- |
| `YZLLauncher-unsigned.ipa`（约 1.1 MB，纯 SwiftUI 外壳预览） | 否 | 本仓库自写 Swift 代码，不含 Amethyst / Pojav 源码与二进制 |
| `YZL-engine.tipa`、`YZL-engine-sideload-unsigned.ipa`（约 110 MB） | **是** | 由 Amethyst-iOS 源码构建，内含其原生层、JavaApp jar、图形库、JRE 与 `YZLUI.framework` |

**只要分发引擎包，下面第 2 节的 GPLv3 义务即被触发**。仅编译、自用、在本仓库内部流转不触发向第三方分发的义务，但仓库当前为私有且没有 `LICENSE`，公开前仍需补做决定。

## 2. 引擎与运行时

| 组件 | 上游 | 许可 | 在本项目中的形态 |
| --- | --- | --- | --- |
| Amethyst-iOS | <https://github.com/AngelAuraMC/Amethyst-iOS> | **GPL-3.0** | fork-overlay 底座：主二进制、Natives、JavaApp、`launchJVM`、图形翻译层 |
| PojavLauncher_iOS（已归档） | <https://github.com/PojavLauncherTeam/PojavLauncher_iOS> | GPL-3.0 | Amethyst 的前身；**JRE 8 / 17 二进制从 v2.2 的 IPA 中提取** |
| OpenJDK / Java 运行时 | OpenJDK 社区发行版 | GPL-2.0 + Classpath Exception | 随包分发的 `java_runtimes/*`，具体版本以包内 `release` 文件为准 |
| LWJGL / GLFW 及其 iOS 适配 | <https://github.com/LWJGL/lwjgl3> | BSD-3-Clause 等 | JavaApp 内的桥接类 |
| gl4es / MobileGlues / ANGLE / MoltenVK | 各自上游仓库 | 各自许可（多为 MIT / BSD / Apache-2.0） | `Frameworks/` 下的图形翻译 dylib |
| Azul Zulu JDK 8 | <https://www.azul.com/> | 其自有许可 | **仅构建期**使用（`setup-java`），不随包分发 |
| FoldCraftLauncher (FCL) | <https://github.com/FCL-Team/FoldCraftLauncher> | GPL-3.0 | **仅作 UI / 交互设计参照**，未复制其代码 |

## 3. 分发引擎包时必须做的事

GPLv3 要求向二进制接收者提供「对应源码」（Corresponding Source）。实践上至少：

1. 提供构建该引擎包所使用的 **Amethyst fork 完整源码**（含本仓库 `engine/fork-patches/`
   的全部补丁、`YZLGameEntry.java`、`engine/build-engine.sh`、CI workflow），
   或按 GPLv3 第 6 条给出有效期不少于三年的**书面要约**。
2. 提供构建脚本与确切的上游提交 SHA（产物 `amethyst-commit.txt` 已随 artifact 输出）。
3. 随包附上 GPL-3.0 许可证全文与本文，并说明修改点。
4. 不得对接收者行使 GPLv3 授予的权利再施加额外限制（例如禁止再分发）。
5. 若附带 JRE，另需满足 OpenJDK 的 GPL-2.0 + Classpath Exception 要求。

> 本项目在 `docs/ARCHITECTURE.md` §9 与 README「合规」章节已确认路线为
> **「链接引擎的 iOS 端按 GPLv3 开源，不按闭源分发设计」**。仓库尚未公开、
> 尚无 `LICENSE` 文件，属于**未完成的合规义务**，不是已解决事项。

## 4. 与 Mojang / Microsoft 的关系

- 不内置任何 Minecraft 游戏文件；资源在用户运行时从 Mojang 官方（或用户配置的镜像）获取。
- 用户必须自行拥有 Minecraft 账号；微软登录使用用户自己的凭证。
- 本项目与 Mojang / Microsoft / Amethyst / PojavLauncher / FCL 团队均无隶属关系。
- 非官方启动器不受 Mojang 支持，账号风险由用户自行承担（关于页需说明）。
