# 内置 JIT 方案：已放弃（2026-11-17）

**结论：不做内置 JIT，JIT 继续走外部助手（StikDebug / StikJIT）路线。**

2026-11-15 曾评估过「把 JIT 收进启动器自己」的方案（helper appex + StikJIT.framework）。
经过便利性与可行性复核后决定放弃，本文件保留仅为记录决策依据，不再作为实施方案。

## 为什么放弃

1. **省不掉核心前置**：内置方案本质是把 StikJIT 框架塞进启动器，helper 仍要走
   RSD 隧道连 `10.7.0.1`、挂 DDI、附调试器。VPN、DDI、开发者模式这些底层依赖一个都省不掉，
   真正省掉的只是「第二个 App」和「来回跳转」这一步。
2. **硬门槛卡住目标设备**：参考实现（Husk）把 helper 的 deployment target 钉在 iOS 26，
   26 以下回落 StikDebug；本机测试机是 iOS 18.7.8，内置方案覆盖不到。
3. **配对文件也省不掉**：iOS 26 仍要导入配对文件；只有 iOS 27 的本机自配对能免电脑，
   但那是系统能力，不是内置 JIT 带来的。
4. **代码从未落地**：候选表（`JITLauncher.swift`）始终是三段
   （stikdebug / stikjit / apple-magnifier），没有内置 helper 分支；
   `engine/builtin-jit/` helper 源码目录也从未创建。放弃无需回滚代码。
5. **收益不抵成本**：要新建 appex、拉 StikJIT.xcframework、按嵌套顺序签名、
   真机验证扩展点——工作量大，而用户核心诉求「装了就能玩」在 iOS 非越狱 W^X 下本就到不了。

## 现行 JIT 路线（唯一支持）

External 助手：`JITLauncher` 候选表按 stikdebug → stikjit → TrollStore(apple-magnifier)
依次尝试，界面统一叫「性能模式」。操作方式与前置见 `docs/开JIT-傻瓜步骤.md`
与 `docs/拿不到LocalDevVPN.md`。
