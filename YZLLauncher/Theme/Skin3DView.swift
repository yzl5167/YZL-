import SwiftUI

/// 3D 皮肤预览视图：走路摆臂动画 + 拖动旋转（对照 Windows 端 SkinPreview3D /
/// Android 端 HomeAvatar 的 3D 模型）。皮肤解析与 AvatarView 同一条链：
/// 本地 `yzl-local-skin://` → 账号 skinURL → 程序化默认皮肤。
///
/// 走路动画用 TimelineView(.animation) 驱动（iOS 15 可用），渲染在 Canvas 里
/// 调 Skin3DModel.draw；模型只在贴图 / 模型类型变化时重建一次。
struct Skin3DView: View {
    let account: MicrosoftAccount?
    /// "steve" / "alex" / "custom"：alex 用纤细手臂，其余经典。
    var skinModel: String = "steve"
    var canvasSize: CGFloat = 300
    var animated: Bool = true
    @Binding var yawDeg: CGFloat
    @Binding var pitchDeg: CGFloat

    /// 皮肤贴图变化时重建模型的 id（沿用 AvatarView 的 .task(id:) 模式）。
    private var skinReference: String? { account?.skinURL }

    @State private var texture: UIImage?
    @State private var model: Skin3DModel?
    @State private var dragStartYaw: CGFloat = 0
    @State private var dragStartPitch: CGFloat = 0
    @State private var walkStart = Date()

    /// 默认视角（主页同款略侧身）。
    static let defaultYaw: CGFloat = -18
    static let defaultPitch: CGFloat = 4

    init(account: MicrosoftAccount?, skinModel: String = "steve", canvasSize: CGFloat = 300,
         animated: Bool = true, yawDeg: Binding<CGFloat> = .constant(Skin3DView.defaultYaw),
         pitchDeg: Binding<CGFloat> = .constant(Skin3DView.defaultPitch)) {
        self.account = account
        self.skinModel = skinModel
        self.canvasSize = canvasSize
        self.animated = animated
        _yawDeg = yawDeg
        _pitchDeg = pitchDeg
    }

    var body: some View {
        // 闭包类型显式标注：Canvas 渲染闭包里 mixed self 捕获 + 泛型推断在
        // 云端编译器上会报「generic parameter 'Content' could not be inferred」。
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { (timeline: TimelineViewDefaultContext) in
            Canvas { (context: inout GraphicsContext, size: CGSize) in
                guard let model = self.model else { return }
                // 与 Android 端 HomeAvatar 一致：walkPhase 每秒 +2.4 rad。
                let phase = self.animated
                    ? timeline.date.timeIntervalSince(self.walkStart) * 2.4
                    : 0
                model.draw(into: context.cgContext, size: size,
                           yawDeg: self.yawDeg, pitchDeg: self.pitchDeg, walkPhase: CGFloat(phase))
            }
        }
        .frame(width: canvasSize, height: canvasSize)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    yawDeg = Self.normalized(dragStartYaw + value.translation.width / 3)
                    pitchDeg = min(max(dragStartPitch - value.translation.height / 3, -60), 60)
                }
                .onEnded { _ in
                    dragStartYaw = yawDeg
                    dragStartPitch = pitchDeg
                }
        )
        .onAppear {
            dragStartYaw = yawDeg
            dragStartPitch = pitchDeg
        }
        .task(id: skinReference) {
            await reload()
        }
    }

    /// 账号或皮肤地址变化时重新取图并重建模型；先清空旧图避免闪现上一账号的皮肤。
    @MainActor
    private func reload() async {
        texture = nil
        model = nil
        defer { rebuildModel() }

        guard let raw = skinReference, let url = URL(string: raw) else { return }
        if url.scheme?.lowercased() == LocalSkinStore.scheme {
            // 自定义 scheme 一律只读本地文件，绝不对它发网络请求。
            texture = LocalSkinStore().load(from: url)
            return
        }
        texture = await SkinTexture.load(from: url)
    }

    @MainActor
    private func rebuildModel() {
        model = Skin3DModel(
            skin: texture ?? Skin3DModel.defaultSkin(),
            model: skinModel,
            headOnly: false
        )
    }

    /// 归一化到 (-180, 180]，拖多圈也不会数值爆炸。
    static func normalized(_ angle: CGFloat) -> CGFloat {
        var value = angle.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }
}
