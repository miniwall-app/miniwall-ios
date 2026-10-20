#if os(iOS)
import MiniwallCore
import SwiftUI

extension Rgba {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

/// A rounded rectangle with its own radius per corner (iOS 16 has no UnevenRoundedRectangle).
struct CornerShape: InsettableShape {
    var corners: Corners
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }
        let radii = corners.resolved(width: Double(rect.width), height: Double(rect.height)).map { max(0, CGFloat($0) - insetAmount) }
        let (tl, tr, br, bl) = (radii[0], radii[1], radii[2], radii[3])
        var p = Path()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> CornerShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// Image and video masks (as in the web renderer).
struct MaskShape: Shape {
    var mask: Mask

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        switch mask {
        case let .rect(corners): return CornerShape(corners: corners).path(in: rect)
        case .circle:
            let d = min(w, h)
            return Path(ellipseIn: CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d))
        case .concave:
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + w, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + w, y: rect.minY + h))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + h), control: CGPoint(x: rect.minX + w / 2, y: rect.minY + h - 54))
            p.closeSubpath()
            return p
        case .convex:
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + w, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + w, y: rect.minY + h - 27))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + h - 27), control: CGPoint(x: rect.minX + w / 2, y: rect.minY + h + 27))
            p.closeSubpath()
            return p
        }
    }
}

enum PaintStyle {
    /// CSS `linear-gradient(<deg>)` end points for a box: 0deg goes up, 90deg goes right; the
    /// gradient line is long enough that the corners get the first and last colors.
    static func linearPoints(degrees: Double, size: CGSize) -> (UnitPoint, UnitPoint) {
        let rad = degrees * .pi / 180
        let w = max(Double(size.width), 1), h = max(Double(size.height), 1)
        let length = abs(w * sin(rad)) + abs(h * cos(rad))
        let dx = sin(rad) * length / 2 / w
        let dy = -cos(rad) * length / 2 / h
        return (UnitPoint(x: 0.5 - dx, y: 0.5 - dy), UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }

    static func gradient(_ stops: [GradientStop]) -> Gradient {
        Gradient(stops: stops.map { Gradient.Stop(color: $0.color.color, location: CGFloat(min(max($0.percent / 100, 0), 1))) })
    }

    /// A ShapeStyle for color and gradient fills (images are drawn by ``FillView``).
    static func style(_ fill: Fill?, size: CGSize) -> AnyShapeStyle {
        switch fill {
        case let .solid(c)?: return AnyShapeStyle(c.color)
        case let .linear(degrees, stops)?:
            let (start, end) = linearPoints(degrees: degrees, size: size)
            return AnyShapeStyle(LinearGradient(gradient: gradient(stops), startPoint: start, endPoint: end))
        case let .radial(stops)?:
            let radius = sqrt(pow(size.width / 2, 2) + pow(size.height / 2, 2))
            return AnyShapeStyle(RadialGradient(gradient: gradient(stops), center: .center, startRadius: 0, endRadius: radius))
        case .image?, nil:
            return AnyShapeStyle(Color.clear)
        }
    }
}

/// Everything around a shape (for shadows drawn only outside the box).
struct OutsideShape<S: Shape>: Shape {
    let inner: S

    func path(in rect: CGRect) -> Path {
        var p = Path(rect.insetBy(dx: -400, dy: -400))
        p.addPath(inner.path(in: rect))
        return p
    }
}

/// Paints a fill (color, gradient or image with overlay) in a shape.
struct FillView<S: Shape>: View {
    let fill: Fill?
    let shape: S
    let size: CGSize

    var body: some View {
        switch fill {
        case let .image(url, cover, overlay)?:
            ZStack {
                RemoteImage(url: url) { image in
                    if cover {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
                    } else {
                        Image(uiImage: image).resizable().scaledToFit().frame(width: size.width, height: size.height, alignment: .top)
                    }
                }
                if let overlay { Rectangle().fill(PaintStyle.style(overlay, size: size)) }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
        case nil:
            EmptyView()
        default:
            shape.fill(PaintStyle.style(fill, size: size))
        }
    }
}

/// Background, border and shadow of a box (`Paint`).
struct BoxPaint: View {
    let paint: Paint
    let size: CGSize

    var body: some View {
        let shape = CornerShape(corners: paint.corners)
        ZStack {
            if let shadow = paint.shadow {
                // CSS box-shadow shows only outside the box; CSS blur radius is about twice SwiftUI's.
                shape.fill(shadow.color.color)
                    .shadow(color: shadow.color.color, radius: CGFloat(shadow.radius / 2), x: CGFloat(shadow.x), y: CGFloat(shadow.y))
                    .mask(OutsideShape(inner: shape).fill(style: FillStyle(eoFill: true)))
            }
            FillView(fill: paint.background, shape: shape, size: size)
            if paint.borderWidth > 0, let border = paint.borderFill {
                // CSS borders sit inside the border box.
                shape.strokeBorder(PaintStyle.style(border, size: size), lineWidth: CGFloat(paint.borderWidth))
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}
#endif
