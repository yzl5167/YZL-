# 微软 / Mojang 应用注册与“白名单”说明

日期：2026-11-05

## 先澄清一件事

Minecraft: Java Edition 的微软登录**没有公开的“启动器白名单申请表”**。第三方启动器正确做法是：

1. 在 Azure 门户注册自己的公共客户端（public client）；
2. 用设备代码流拿到微软令牌；
3. 再用 Xbox Live → XSTS → Minecraft Services 换取 Minecraft 令牌。

所谓“麻将（Mojang）白名单”通常指两件不同的事：

- **Minecraft 启动器客户端 ID**：`00000000402b5328` 是官方启动器使用的公共客户端 ID。它属于微软，不属于本项目；第三方启动器复用它随时可能被限流或封禁，也不受我们控制。
- **Mojang 服务端允许列表**：Minecraft Services 没有面向个人开发者的启动器白名单入口。能做的只有使用合规的 Azure 应用身份，并遵守 [Minecraft 使用条款](https://www.minecraft.net/zh-hans/terms) 与 [Microsoft 服务协议](https://www.microsoft.com/servicesagreement)。

因此本项目能做的是：**默认带上安卓同款公共客户端 ID 方便自用，同时允许在设置里替换成自己注册的 Azure 客户端 ID**。真正要长期稳定，建议注册自己的应用。

## 注册自己的 Azure 公共客户端（免费，约 5 分钟）

> 需要你自己的 Microsoft 账户登录 [Azure 门户](https://portal.azure.com/)。本机没有你的账户凭据，无法代你提交。

1. 打开 **Microsoft Entra ID → 应用注册 → 新注册**。
2. 名称填 `YZL Launcher`。
3. 受支持的账户类型选 **“仅个人 Microsoft 账户”**（Minecraft 玩家账号属于个人账户）。
4. 重定向 URI 选 **“公共客户端/本机(移动和桌面)”**，填：
   `https://login.live.com/oauth20_desktop.srf`
5. 注册后记下 **应用程序(客户端) ID**。
6. 进入 **身份验证 → 高级设置**，把 **“允许公共客户端流”** 设为 **是**。
7. 进入 **API 权限 → 添加权限 → 所我的组织使用的 API**，添加：
   - `XboxLive.signin`
   - `offline_access`
   - `openid`
   - `profile`
8. 不需要创建客户端密码。设备代码流使用的是公共客户端，**不要**把任何 secret 写进 App。
9. 把这个客户端 ID 填到「设置 → 账户 → 客户端 ID」，或替换 `MicrosoftAuth.defaultClientId`。

## 本项目当前的登录分支

`MicrosoftAuthService` 会自动判断：

| 客户端 ID | 授权端点 | Scope |
| --- | --- | --- |
| `00000000402b5328`（默认） | `login.live.com/oauth20_connect.srf` | `service::user.auth.xboxlive.com::MBI_SSL` |
| 自定义 Azure 客户端 | `login.microsoftonline.com/consumers/oauth2/v2.0/devicecode` | `XboxLive.signin offline_access` |

两条分支最终都走同一套 Xbox / XSTS / Minecraft 交换。自定义 ID 打 Azure v2.0；默认 ID 打 Live Connect，因为实测 Azure v2.0 会返回 `AADSTS700016`（应用不在该租户中）。

## 申请材料模板（如果微软要求说明用途）

> YZL Launcher 是一个非商业的 Minecraft: Java Edition 第三方启动器，仅用于在用户自己的 iOS 设备上登录其本人拥有的微软账户并启动游戏。应用使用 OAuth 2.0 设备代码流，不收集微软密码，不向第三方服务器转发令牌；访问令牌只保存在设备 Keychain。应用不内置游戏文件，所有游戏资源从 Mojang 官方接口下载。

## 验收清单

- [ ] Azure 应用类型为公共客户端，未创建 secret。
- [ ] 已允许公共客户端流。
- [ ] `XboxLive.signin` 与 `offline_access` 已添加并授予用户同意。
- [ ] 设备代码页能显示 `user_code` 与 `verification_uri`。
- [ ] 登录后能拉到 Minecraft 档案（UUID + 皮肤 URL）。
- [ ] 访问令牌过期后能用刷新令牌续期。
- [ ] 设置里换回默认 ID 仍能走 Live Connect 分支。
