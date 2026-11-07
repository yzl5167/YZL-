import SwiftUI
import UIKit

/// 3D 皮肤预览视图：走路摆臂动画 + 拖动旋转（对照 Windows 端 SkinPreview3D /
/// Android 端 HomeAvatar 的 3D 模型）。皮肤解析与 AvatarView 同一条链：
/// 本地 `yzl-local-skin://` → 账号 skinURL → 程序化默认皮肤。
///
/// 渲染用 UIKit 的 `draw(_:)` + CADisplayLink（iOS 15 全兼容）：
/// SwiftUI Canvas 的 `GraphicsContext.cgContext` 要 iOS 16，部署目标 15 用不了。
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
        Skin3DCanvasRepresentable(
            model: model,
            animated: animated,
            yawDeg: $yawDeg,
            pitchDeg: $pitchDeg
        )
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

// MARK: - UIKit 宿主

private struct Skin3DCanvasRepresentable: UIViewRepresentable {
    let model: Skin3DModel?
    let animated: Bool
    @Binding var yawDeg: CGFloat
    @Binding var pitchDeg: CGFloat

    func makeUIView(context: Context) -> Skin3DCanvas {
        let view = Skin3DCanvas(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false
        return view
    }

    func updateUIView(_ uiView: Skin3DCanvas, context: Context) {
        uiView.model = model
        uiView.animated = animated
        uiView.yawDeg = yawDeg
        uiView.pitchDeg = pitchDeg
    }
}

/// 真正画 3D 模型的 UIView：CADisplayLink 30fps 驱动走路动画，
/// 每帧调 Skin3DModel.draw 重画（与 Android 端 HomeAvatar 同策略）。
final class Skin3DCanvas: UIView {
    var model: Skin3DModel? { didSet { setNeedsDisplay() } }
    var yawDeg: CGFloat = Skin3DView.defaultYaw { didSet { setNeedsDisplay() } }
    var pitchDeg: CGFloat = Skin3DView.defaultPitch { didSet { setNeedsDisplay() } }
    var animated: Bool = true { didSet { syncDisplayLink() } }

    /// 走路相位基准：从视图创建时刻起算（与 Android 端每秒 +2.4 rad 一致）。
    private let walkStart = Date()
    private var displayLink: CADisplayLink?
    private let displayProxy = DisplayProxy()

    override init(frame: CGRect) {
        super.init(frame: frame)
        syncDisplayLink()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        syncDisplayLink()
    }

    deinit {
        displayLink?.invalidate()
    }

    /// 离开窗口（切页 / 进游戏）自动停帧，回来自动恢复。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncDisplayLink()
    }

    private func syncDisplayLink() {
        let shouldRun = animated && window != nil
        if shouldRun, displayLink == nil {
            displayProxy.view = self
            let link = CADisplayLink(target: displayProxy, selector: #selector(DisplayProxy.tick(_:)))
            link.preferredFramesPerSecond = 30
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !shouldRun, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let model else { return }
        let phase = animated ? Date().timeIntervalSince(walkStart) * 2.4 : 0
        model.draw(into: context, size: bounds.size,
                   yawDeg: yawDeg, pitchDeg: pitchDeg, walkPhase: CGFloat(phase))
    }

    /// CADisplayLink 会强持有 target，直接传 self 会造成保留环；经弱代理转发。
    private final class DisplayProxy: NSObject {
        weak var view: Skin3DCanvas?

        @objc func tick(_ link: CADisplayLink) {
            view?.setNeedsDisplay()
        }
    }
}
