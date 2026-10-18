import SwiftUI

struct CusePointerMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let originX = rect.midX - 12 * scale
        let originY = rect.midY - 12 * scale

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: originX + x * scale,
                y: originY + y * scale
            )
        }

        var path = Path()
        path.move(to: point(4.037, 4.688))
        path.addCurve(
            to: point(4.688, 4.037),
            control1: point(3.90, 3.90),
            control2: point(3.90, 3.90)
        )
        path.addLine(to: point(20.688, 10.537))
        path.addCurve(
            to: point(20.625, 11.484),
            control1: point(21.42, 10.84),
            control2: point(21.42, 10.84)
        )
        path.addLine(to: point(14.501, 13.064))
        path.addCurve(
            to: point(13.063, 14.499),
            control1: point(13.43, 13.34),
            control2: point(13.43, 13.34)
        )
        path.addLine(to: point(11.484, 20.625))
        path.addCurve(
            to: point(10.537, 20.688),
            control1: point(11.17, 21.42),
            control2: point(11.17, 21.42)
        )
        path.closeSubpath()
        return path
    }
}

struct CusePointerIcon: View {
    var color: Color = DS.Colors.textSecondary
    var size: CGFloat = 18

    var body: some View {
        CusePointerMark()
            .fill(color)
            .frame(width: size, height: size)
    }
}
