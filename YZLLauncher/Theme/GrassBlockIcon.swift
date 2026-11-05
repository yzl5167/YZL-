import SwiftUI

/// 与安卓端 `GrassBlockIcon` 完全一致的等轴测草方块（三面体 + 草色顶边）。
/// 顶绿 `#79C24A`，左侧泥 `#8A6042`，右侧泥 `#6D4931`，侧面顶边草色 `#62AA39`/`#569832`。
struct GrassBlockIcon: View {
    var size: CGFloat = 34

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let px = { (x: CGFloat, y: CGFloat) -> CGPoint in CGPoint(x: w * x, y: h * y) }

            let top = px(0.50, 0.04)
            let rightP = px(0.94, 0.28)
            let center = px(0.50, 0.52)
            let leftP = px(0.06, 0.28)
            let bottomLeft = px(0.06, 0.79)
            let bottomCenter = px(0.50, 1.00)
            let bottomRight = px(0.94, 0.79)

            func face(_ pts: [CGPoint], _ color: Color) {
                var path = Path()
                path.move(to: pts[0])
                for pt in pts.dropFirst() { path.addLine(to: pt) }
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }

            face([top, rightP, center, leftP], Color(red: 0.475, green: 0.761, blue: 0.290))
            face([leftP, center, bottomCenter, bottomLeft], Color(red: 0.541, green: 0.376, blue: 0.259))
            face([center, rightP, bottomRight, bottomCenter], Color(red: 0.427, green: 0.286, blue: 0.192))
            face([leftP, center, px(0.50, 0.60), px(0.06, 0.36)], Color(red: 0.384, green: 0.667, blue: 0.224))
            face([center, rightP, px(0.94, 0.36), px(0.50, 0.60)], Color(red: 0.337, green: 0.596, blue: 0.196))
        }
        .frame(width: size, height: size)
    }
}

/// 与安卓端 `YzlLogo` 一致的品牌标记：蓝紫渐变圆角方块 + 白色 “Y”。
struct YzlLogoMark: View {
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(YZLTheme.brandGradient)
            Text("Y")
                .font(.system(size: size * 0.58, weight: .black))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
