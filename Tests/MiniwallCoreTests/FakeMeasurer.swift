import Foundation
@testable import MiniwallCore

/// Fixed metrics: each character is 0.55 x the font size wide, lines are 1.5 x tall (same as the Kotlin FakeMeasurer).
struct FakeMeasurer: TextMeasurer {
    func measure(_ runs: [TextLogic.Run], font: FontSpec, maxWidth: Double?) -> (width: Double, height: Double) {
        let text = runs.map(\.text).joined()
        let charWidth = font.size * 0.55
        var lines = 0
        var widest = 0.0
        for paragraph in text.components(separatedBy: "\n") {
            let full = Double(paragraph.count) * charWidth
            if maxWidth == nil || full <= maxWidth! {
                lines += 1
                widest = max(widest, full)
                continue
            }
            var line = 0.0
            lines += 1
            for word in paragraph.components(separatedBy: " ") {
                let w = Double(word.count) * charWidth
                let add = line == 0 ? w : w + charWidth
                if line > 0 && line + add > maxWidth! {
                    widest = max(widest, line)
                    lines += 1
                    line = w
                } else {
                    line += add
                }
            }
            widest = max(widest, line)
        }
        return (widest, Double(lines) * font.lineHeight)
    }
}
