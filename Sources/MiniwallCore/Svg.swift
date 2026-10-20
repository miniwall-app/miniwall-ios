import Foundation

/// A path step in absolute coordinates; every SVG path command reduces to these four.
public enum PathOp: Equatable, Sendable {
    case move(Double, Double)
    case line(Double, Double)
    case cubic(Double, Double, Double, Double, Double, Double)
    case close
}

/// One drawable element of an icon: its path and how it is painted (always in the icon's one color).
public struct SvgShape: Equatable, Sendable {
    public let ops: [PathOp]
    public let fill: Bool
    public let stroke: Bool
    public let strokeWidth: Double
    public let roundCap: Bool
    public let roundJoin: Bool
    /// `fill-rule="evenodd"`: overlapping parts of the path are holes. Default is non-zero.
    public let evenOdd: Bool
}

/// `minX`/`minY`/`width`/`height` are the viewBox: shapes are drawn in these units and scaled to the icon's frame.
public struct SvgIcon: Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let width: Double
    public let height: Double
    public let shapes: [SvgShape]
}

/// The subset of SVG that icon sets use (what api.iconify.design serves for Lucide and Material
/// Design Icons): `path`, `circle`, `ellipse`, `rect`, `line`, `polyline`, `polygon`, inside `g`
/// and `svg`, with fill/stroke/stroke-width/linecap/linejoin inherited as in SVG. Colors are
/// ignored (an icon is tinted with one color), `none` is honored. Platforms only replay `PathOp`s.
///
public enum Svg {
    private struct Style {
        var fill: String?
        var stroke: String?
        var strokeWidth: Double?
        var cap: String?
        var join: String?
        var fillRule: String?
    }

    private static let tag = TextLogic.regex(#"<(/?)([a-zA-Z][\w:-]*)([^>]*?)(/?)>"#)
    private static let attribute = TextLogic.regex(#"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    private static let numberPattern = TextLogic.regex(#"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"#)
    private static let shapes: Set<String> = ["path", "circle", "ellipse", "rect", "line", "polyline", "polygon"]

    private static func groups(_ m: NSTextCheckingResult, in s: NSString) -> [String?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : s.substring(with: r)
        }
    }

    public static func parse(_ source: String) -> SvgIcon? {
        var box: [Double]?
        var styles: [Style] = [Style()]
        var open: [String] = []
        var found: [SvgShape] = []
        let ns = source as NSString
        for match in tag.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let g = groups(match, in: ns)
            let closing = g[1] == "/"
            let name = (g[2] ?? "").lowercased()
            let selfClosing = g[4] == "/"
            if closing {
                if let last = open.last, last == name {
                    open.removeLast()
                    if name == "g" || name == "svg" { styles.removeLast() }
                }
                continue
            }
            var attributes: [String: String] = [:]
            let attributeText = (g[3] ?? "") as NSString
            for a in attribute.matches(in: attributeText as String, range: NSRange(location: 0, length: attributeText.length)) {
                let ag = groups(a, in: attributeText)
                attributes[ag[1] ?? ""] = ag[2] ?? ag[3] ?? ""
            }
            let style = merge(styles[styles.count - 1], attributes)
            if name == "svg" {
                if box == nil, let v = attributes["viewBox"] {
                    let n = numbers(v)
                    if n.count == 4 && n[2] > 0 && n[3] > 0 { box = n }
                }
                if box == nil, let w = attributes["width"].flatMap(numbers)?.first, let h = attributes["height"].flatMap(numbers)?.first, w > 0, h > 0 {
                    box = [0, 0, w, h]
                }
                if !selfClosing { styles.append(style); open.append(name) }
            } else if name == "g" {
                if !selfClosing { styles.append(style); open.append(name) }
            } else if shapes.contains(name) {
                guard let d = pathData(name, attributes) else { continue }
                let ops = parsePath(d)
                if ops.isEmpty { continue }
                let fill = (style.fill ?? "black") != "none"
                let stroke = (style.stroke ?? "none") != "none"
                if !fill && !stroke { continue }
                found.append(SvgShape(ops: ops, fill: fill, stroke: stroke, strokeWidth: style.strokeWidth ?? 1, roundCap: style.cap == "round", roundJoin: style.join == "round", evenOdd: style.fillRule == "evenodd"))
            } else if !selfClosing {
                open.append(name)
            }
        }
        guard let b = box, !found.isEmpty else { return nil }
        return SvgIcon(minX: b[0], minY: b[1], width: b[2], height: b[3], shapes: found)
    }

    private static func merge(_ parent: Style, _ a: [String: String]) -> Style {
        Style(
            fill: a["fill"] ?? parent.fill,
            stroke: a["stroke"] ?? parent.stroke,
            strokeWidth: a["stroke-width"].flatMap(numbers)?.first ?? parent.strokeWidth,
            cap: a["stroke-linecap"] ?? parent.cap,
            join: a["stroke-linejoin"] ?? parent.join,
            fillRule: a["fill-rule"] ?? parent.fillRule
        )
    }

    private static func numbers(_ text: String) -> [Double] {
        let ns = text as NSString
        return numberPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { Double(ns.substring(with: $0.range)) }
    }

    private static func num(_ a: [String: String], _ key: String) -> Double { a[key].flatMap(numbers)?.first ?? 0 }

    /// The element as path data (circles, rectangles... become arcs and lines).
    private static func pathData(_ name: String, _ a: [String: String]) -> String? {
        switch name {
        case "path":
            return a["d"]
        case "circle":
            let r = num(a, "r")
            return r <= 0 ? nil : ellipse(num(a, "cx"), num(a, "cy"), r, r)
        case "ellipse":
            let rx = num(a, "rx"), ry = num(a, "ry")
            return rx <= 0 || ry <= 0 ? nil : ellipse(num(a, "cx"), num(a, "cy"), rx, ry)
        case "rect":
            let x = num(a, "x"), y = num(a, "y"), w = num(a, "width"), h = num(a, "height")
            var rx = a["rx"].flatMap(numbers)?.first
            var ry = a["ry"].flatMap(numbers)?.first
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            if w <= 0 || h <= 0 { return nil }
            guard let rxv = rx, let ryv = ry, rxv > 0, ryv > 0 else { return "M\(x) \(y) H\(x + w) V\(y + h) H\(x) Z" }
            let ax = min(rxv, w / 2), ay = min(ryv, h / 2)
            return "M\(x + ax) \(y) H\(x + w - ax) A\(ax) \(ay) 0 0 1 \(x + w) \(y + ay) V\(y + h - ay) A\(ax) \(ay) 0 0 1 \(x + w - ax) \(y + h) "
                + "H\(x + ax) A\(ax) \(ay) 0 0 1 \(x) \(y + h - ay) V\(y + ay) A\(ax) \(ay) 0 0 1 \(x + ax) \(y) Z"
        case "line":
            return "M\(num(a, "x1")) \(num(a, "y1")) L\(num(a, "x2")) \(num(a, "y2"))"
        case "polyline", "polygon":
            let points = numbers(a["points"] ?? "")
            if points.count < 4 { return nil }
            var out = ""
            for i in 0..<(points.count / 2) {
                out += (i == 0 ? "M" : "L") + "\(points[2 * i]) \(points[2 * i + 1]) "
            }
            if name == "polygon" { out += "Z" }
            return out
        default:
            return nil
        }
    }

    private static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> String {
        "M\(cx - rx) \(cy) A\(rx) \(ry) 0 1 0 \(cx + rx) \(cy) A\(rx) \(ry) 0 1 0 \(cx - rx) \(cy) Z"
    }

    /// Path data -> absolute `PathOp`s. Relative, horizontal/vertical, smooth, quadratic and arc
    /// commands are resolved here so platforms only draw moves, lines and cubics. Malformed data
    /// keeps what was read before the error, like browsers.
    public static func parsePath(_ d: String) -> [PathOp] {
        var ops: [PathOp] = []
        var s = PathScanner(Array(d))
        var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0
        var lastCubic: (Double, Double)?
        var lastQuad: (Double, Double)?
        var command: Character = " "
        var needMove = false

        func start() {
            if needMove { ops.append(.move(cx, cy)); needMove = false }
        }

        loop: while true {
            s.skipSeparators()
            if s.atEnd { break }
            let c = s.peek()
            if c.isLetter {
                command = c
                s.next()
            } else if command == " " || command == "Z" || command == "z" {
                break
            }
            let relative = command.isLowercase
            let ox = relative ? cx : 0
            let oy = relative ? cy : 0
            var cubic: (Double, Double)?
            var quad: (Double, Double)?
            switch Character(String(command.uppercased().prefix(1))) {
            case "M":
                guard let x = s.number(), let y = s.number() else { break loop }
                cx = ox + x; cy = oy + y; sx = cx; sy = cy
                ops.append(.move(cx, cy)); needMove = false
                command = relative ? "l" : "L"
            case "L":
                guard let x = s.number(), let y = s.number() else { break loop }
                start(); cx = ox + x; cy = oy + y; ops.append(.line(cx, cy))
            case "H":
                guard let x = s.number() else { break loop }
                start(); cx = ox + x; ops.append(.line(cx, cy))
            case "V":
                guard let y = s.number() else { break loop }
                start(); cy = oy + y; ops.append(.line(cx, cy))
            case "C":
                guard let x1 = s.number(), let y1 = s.number(), let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { break loop }
                start()
                ops.append(.cubic(ox + x1, oy + y1, ox + x2, oy + y2, ox + x, oy + y))
                cubic = (ox + x2, oy + y2); cx = ox + x; cy = oy + y
            case "S":
                guard let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { break loop }
                start()
                let x1 = lastCubic.map { 2 * cx - $0.0 } ?? cx
                let y1 = lastCubic.map { 2 * cy - $0.1 } ?? cy
                ops.append(.cubic(x1, y1, ox + x2, oy + y2, ox + x, oy + y))
                cubic = (ox + x2, oy + y2); cx = ox + x; cy = oy + y
            case "Q":
                guard let qx = s.number(), let qy = s.number(), let x = s.number(), let y = s.number() else { break loop }
                start()
                quadratic(&ops, cx, cy, ox + qx, oy + qy, ox + x, oy + y)
                quad = (ox + qx, oy + qy); cx = ox + x; cy = oy + y
            case "T":
                guard let x = s.number(), let y = s.number() else { break loop }
                start()
                let qx = lastQuad.map { 2 * cx - $0.0 } ?? cx
                let qy = lastQuad.map { 2 * cy - $0.1 } ?? cy
                quadratic(&ops, cx, cy, qx, qy, ox + x, oy + y)
                quad = (qx, qy); cx = ox + x; cy = oy + y
            case "A":
                guard let rx = s.number(), let ry = s.number(), let rotation = s.number(), let large = s.flag(), let sweep = s.flag(), let x = s.number(), let y = s.number() else { break loop }
                start()
                arc(&ops, cx, cy, rx, ry, rotation, large, sweep, ox + x, oy + y)
                cx = ox + x; cy = oy + y
            case "Z":
                ops.append(.close); cx = sx; cy = sy; needMove = true
            default:
                break loop
            }
            lastCubic = cubic
            lastQuad = quad
        }
        return ops
    }

    private static func quadratic(_ ops: inout [PathOp], _ x0: Double, _ y0: Double, _ qx: Double, _ qy: Double, _ x: Double, _ y: Double) {
        ops.append(.cubic(x0 + 2.0 / 3 * (qx - x0), y0 + 2.0 / 3 * (qy - y0), x + 2.0 / 3 * (qx - x), y + 2.0 / 3 * (qy - y), x, y))
    }

    /// SVG 1.1 implementation notes F.6.5/F.6.6: endpoint arc -> center arc -> cubic segments of at most 90 degrees.
    private static func arc(_ ops: inout [PathOp], _ x0: Double, _ y0: Double, _ rxIn: Double, _ ryIn: Double, _ rotation: Double, _ large: Bool, _ sweep: Bool, _ x: Double, _ y: Double) {
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if x0 == x && y0 == y { return }
        if rx == 0 || ry == 0 { ops.append(.line(x, y)); return }
        let phi = rotation * Double.pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (x0 - x) / 2
        let dy = (y0 - y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
        if lambda > 1 { let k = lambda.squareRoot(); rx *= k; ry *= k }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let sign = large == sweep ? -1.0 : 1.0
        let coefficient = denominator == 0 ? 0 : sign * max(0, numerator / denominator).squareRoot()
        let cxp = coefficient * (rx * y1p / ry)
        let cyp = coefficient * (-ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (x0 + x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (y0 + y) / 2
        let ux = (x1p - cxp) / rx
        let uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx
        let vy = (-y1p - cyp) / ry
        let theta = atan2(uy, ux)
        var delta = angle(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * Double.pi }
        if sweep && delta < 0 { delta += 2 * Double.pi }
        let rawSegments = (abs(delta) / (Double.pi / 2) - 1e-9).rounded(.up)
        let segments = rawSegments.isFinite ? max(1, Int(min(rawSegments, 64))) : 1 // NaN/inf from absurd radii must not trap
        let step = delta / Double(segments)
        let t = 4.0 / 3 * tan(step / 4)
        func point(_ unitX: Double, _ unitY: Double) -> (Double, Double) {
            (cx + rx * unitX * cosPhi - ry * unitY * sinPhi, cy + rx * unitX * sinPhi + ry * unitY * cosPhi)
        }
        for i in 0..<segments {
            let a = theta + Double(i) * step
            let b = a + step
            let p1 = point(cos(a) - t * sin(a), sin(a) + t * cos(a))
            let p2 = point(cos(b) + t * sin(b), sin(b) - t * cos(b))
            // The last segment ends exactly on the requested point, free of rounding drift.
            let end = i == segments - 1 ? (x, y) : point(cos(b), sin(b))
            ops.append(.cubic(p1.0, p1.1, p2.0, p2.1, end.0, end.1))
        }
    }

    private static func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        let dot = ux * vx + uy * vy
        let length = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
        let a = acos(min(1, max(-1, dot / length)))
        return ux * vy - uy * vx < 0 ? -a : a
    }

    private struct PathScanner {
        private let text: [Character]
        private var i = 0
        init(_ text: [Character]) { self.text = text }
        var atEnd: Bool { i >= text.count }
        func peek() -> Character { text[i] }
        mutating func next() { i += 1 }

        mutating func skipSeparators() {
            while i < text.count && (text[i].isWhitespace || text[i] == ",") { i += 1 }
        }

        private func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }

        /// Arc flags are single characters and may be written without a separator ("a1 1 0 011 1").
        mutating func flag() -> Bool? {
            skipSeparators()
            if i >= text.count { return nil }
            if text[i] == "0" { i += 1; return false }
            if text[i] == "1" { i += 1; return true }
            return nil
        }

        mutating func number() -> Double? {
            skipSeparators()
            let start = i
            if i < text.count && (text[i] == "-" || text[i] == "+") { i += 1 }
            var digits = 0
            while i < text.count && isDigit(text[i]) { i += 1; digits += 1 }
            if i < text.count && text[i] == "." {
                i += 1
                while i < text.count && isDigit(text[i]) { i += 1; digits += 1 }
            }
            if digits == 0 { i = start; return nil }
            if i < text.count && (text[i] == "e" || text[i] == "E") {
                let mark = i
                i += 1
                if i < text.count && (text[i] == "-" || text[i] == "+") { i += 1 }
                var exponent = 0
                while i < text.count && isDigit(text[i]) { i += 1; exponent += 1 }
                if exponent == 0 { i = mark }
            }
            return Double(String(text[start..<i]))
        }
    }
}
