# 拿不到 LocalDevVPN 怎么开 JIT

> **2026-11-15 实测回填（重要）**：真机装完后首页直接显示红色 `error`。
> 上游维护者在同类 issue（#35「sideloading decrypted ipa 权限」）里明确回复：
> **「You can't use the vpn entitlement for apps sideloaded with a free account.
> Just get it from the App Store.」**
>
> 也就是说 `com.apple.developer.networking.vpn.api` / `packet-tunnel-provider`
> 这两个权限，**免费 Apple ID 签的包用不了**，与签得对不对、装得好不好无关。
> 真正的门槛是**签名证书本身带 Network Extension 能力**：付费开发者账号（在
> App ID 上勾 Network Extensions 后重签）或权限齐全的企业证书才行。
> 同一个 issue 里另一条结论：StosVPN 已被 LocalDevVPN 取代，且 LocalDevVPN
> **只在中国区之外上架**。
>
> 下面保留原始步骤，供**有付费证书**的人使用；免费证书用户请直接看第五节。

StikDebug 要连 `10.7.0.1`（手机自己的回环地址），这个地址只有「本机 VPN」能建出来。
市面上这类 App 只有两个实现：

| App | 来源 | 地区限制 |
|---|---|---|
| LocalDevVPN | App Store（Coxson Engineering） | 只在部分区上架 |
| **StosVPN** | SideStore 团队开源（MIT），只出源码 | 无，任何区都能签 |

所以改不了地区不是死路：**用 StosVPN，它不走商店。**

---

## 一、装 StosVPN

1. 拿到 `StosVPN-unsigned.ipa`（本仓库 CI 的 `StosVPN build` 工作流产出的 artifact：
   `StosVPN-unsigned`，5.1 MB，sha256 `5905c06b28e4a75bd9c2bb4c120559d90fd258f9c9268b3347eba3f6785b6a11`）。
2. 用你**现在签 YZL 的那套工具**签名。两条硬要求：
   - **保留原有 entitlements，不要「清空权限」**。需要的是这两项：
     ```xml
     <key>com.apple.developer.networking.vpn.api</key>
     <array><string>allow-vpn</string></array>
     <key>com.apple.developer.networking.networkextension</key>
     <array><string>packet-tunnel-provider</string></array>
     ```
   - **不要改 bundle id**（`com.stossy11.StosVPN`，扩展是 `com.stossy11.StosVPN.TunnelProv`）。
     改了之后主 App 找不到自己的扩展，Connect 会直接失败。
3. 装完打开 StosVPN → 点 **Connect** → 系统弹「StosVPN 想添加 VPN 配置」→ **允许** → 面容/密码确认。

**签名工具怎么选**（影响成败，不只是能不能装上）：

| 工具 | 默认是否保留原权限 | 备注 |
|---|---|---|
| Feather | 保留，可在 Entitlements 页看到并编辑 | 最省事，扩展会一起签 |
| SideStore | 保留 | 走它自己的刷新通道，适合长期用 |
| 轻松签 / ESign | 多数版本保留，但要在签名设置里勾「保留权限 / 自定义权限」 | 关掉就必失败 |
| Sideloadly | 不保留（只留描述文件里的） | 用它签 VPN 大概率建不了隧道，建议只用来装 YZL |

## 二、回到 StikDebug
1. 确认 VPN 状态栏有 `VPN` 图标（StosVPN 建的是本机隧道，不耗流量、不出网）。
2. StikDebug → **Enable JIT** → 选 YZL。
3. 成功后回 YZL 点「开始游戏」。

---

## 三、失败对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| 点 Connect 没有任何反应/秒退 | 签名把 `packet-tunnel-provider` 丢了 | 用签名工具的「导入 entitlements」把上面两段加回去，重签 |
| 「无法添加 VPN 配置」 | 同上，或描述文件策略禁止 | 设置 → 通用 → VPN 与设备管理，删掉旧的 VPN 配置再试 |
| 装上了但图标空白 / 打不开 | 扩展没被一起签 | 重签工具要勾「同时签名 PlugIns/扩展」 |
| StikDebug 一直 Not Connected | VPN 没连上，或同时开了别的 VPN | 只留 StosVPN，关掉加速器/DNS 类 App |
| Enable JIT 成功但 YZL 黑屏 | 不是 VPN 问题 | 取 `Documents/YZL-UI.log` 看注入结果 |

---

## 四、不想签这个包的两条替代

1. **注册一个新的外区 Apple ID**（不是「改地区」，是另开一个号，只登 App Store）：
   设置头像 → 媒体与购买项目 → 退出登录 → App Store 登外区号 → 搜 LocalDevVPN → 获取 → 切回原号。
   已装的 App 不会被删。
2. **用电脑，不要 VPN**：Sideloadly 装包时勾 `Enable JIT`，或 AltServer 的 AltJIT（同一 Wi-Fi）。
   代价是每次启动前电脑要开着。

---

## 五、免费证书用户的实际出路

| 条件 | 能做 | 代价 |
|---|---|---|
| 有非中国区 Apple ID（新注册也行） | 商店装 LocalDevVPN，一次搞定 | 一个邮箱 + 外区地址，不动原账号 |
| 有付费开发者账号（$99/年） | App ID 勾 Network Extensions → 重签 StosVPN | 钱 + 每年续 |
| iOS ≤ 17.0 | TrollStore | 换设备 |
| 以上都没有 | 电脑开 JIT（Sideloadly / AltServer） | 每次启动前电脑开着 |

关键结论：**VPN 这条路只在签名证书带 VPN 权限时才通**，与系统版本无关。

**关于「内置 JIT 能不能免 VPN」**：内置 JIT 方案已于 2026-11-17 决定放弃（见
`docs/builtin-jit.md`），现行路线统一走外部助手 StikDebug / StikJIT。就核实过的事实而言：
Husk 这类实现里 grep 不到 `NEPacketTunnel` / `10.7.0.1`，是说它自己不*提供* VPN，
但仍然*要求*有 `10.7.0.1` 这条 RSD 隧道（`checkingReachability` →
「LocalDevVPN is reachable」）。换言之，即便做内置 JIT 也省不掉 VPN——这也是放弃它的
理由之一。`deviceAddress` 可改，但 RSD 只在该 utun 上监听，换成 Wi-Fi 局域网 IP 通常连不上。

## 附：这个包是怎么来的

- 上游 `SideStore/StosVPN`，commit `010bc14`，许可证 MIT（带署名要求）。
- CI 用 macOS runner 跑 `xcodebuild archive`（`CODE_SIGNING_ALLOWED=NO`），再 `ldid` 分别签
  `TunnelProv.appex` 与主二进制，权限取自仓库内的 `TunnelProv.entitlements` / `StosVPN.entitlements`。
- 产物是**假签名**，不能直接装，必须你自己重签 —— 和 `YZL-engine-sideload-unsigned.ipa` 同一套路。
