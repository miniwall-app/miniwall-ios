/// Widest a presented screen gets on wide screens (iPad, landscape), in pt (mirrors `DisplayWidth.kt`). Same numbers as
/// the Web SDK's `WIDTHS` (sdks/web/src/present.ts). On a phone the screen is narrower than any of them, so nothing
/// changes there. `kind`: `modal`, `sheet` (the web's slide_in), `toast`, `fullscreen` or `banner`. `size`: `small`,
/// `medium`, `large`. An explicit `maxContentWidth` wins over `size`; no size and no width means no limit (nil).
public enum DisplayWidth {
    public static func cap(kind: String, size: String?, maxContentWidth: Double?) -> Double? {
        if let maxContentWidth, maxContentWidth > 0 { return maxContentWidth }
        let widths: [Double]
        switch kind {
        case "modal": widths = [360, 440, 560]
        case "sheet": widths = [320, 380, 440]
        case "toast": widths = [280, 360, 440]
        default: return nil
        }
        switch size {
        case "small": return widths[0]
        case "medium": return widths[1]
        case "large": return widths[2]
        default: return nil
        }
    }

    /// The size a presentation uses: the call's own `explicit` size wins, then the placement's `display.size`
    /// (web `layoutOf`: `options.size ?? source?.size`). Like the web, the placement's size is ignored when the call
    /// picked the format itself (`styleOverridden`). Unknown values and a missing size give nil (no limit).
    public static func resolveSize(explicit: String?, display: JSONValue?, styleOverridden: Bool) -> String? {
        if let explicit { return explicit }
        if styleOverridden { return nil }
        let size = display?.str("size")
        return (size == "small" || size == "medium" || size == "large") ? size : nil
    }
}
