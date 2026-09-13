import AppKit

/// Sizes the editable preview from its wrapped text, within the current display.
@MainActor
enum PreviewPanelSizing {
    private static let minimumWidth: CGFloat = 360
    private static let maximumWidth: CGFloat = 600
    private static let minimumHeight: CGFloat = 132
    private static let maximumHeight: CGFloat = 480
    private static let chromeHeight: CGFloat = 63
    private static let horizontalInsets: CGFloat = 38
    private static let font = NSFont.systemFont(ofSize: 14)

    static func preferredSize(text: String, visibleFrame: NSRect) -> NSSize {
        let availableWidth = max(1, visibleFrame.width - 24)
        let widthLimit = min(maximumWidth, max(320, visibleFrame.width * 0.7), availableWidth)
        let widths = [minimumWidth, 440, 520, maximumWidth]
            .map { min($0, widthLimit) }
            .reduce(into: [CGFloat]()) { result, width in
                if result.last != width { result.append(width) }
            }

        let lineHeight = font.ascender - font.descender + font.leading
        let targetTextHeight = lineHeight * 6
        let measurements = widths.map { width in
            (width: width, height: textHeight(text, width: width))
        }
        let chosen = measurements.first { $0.height <= targetTextHeight }
            ?? measurements.dropFirst().reduce(measurements[0]) { best, candidate in
                candidate.height < best.height - 1 ? candidate : best
            }

        let heightLimit = max(1, min(maximumHeight, visibleFrame.height * 0.52, visibleFrame.height - 24))
        let height = min(heightLimit, max(min(minimumHeight, heightLimit), chosen.height + chromeHeight))
        return NSSize(width: chosen.width, height: height)
    }

    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let body = text.isEmpty ? " " : text
        let bounds = (body as NSString).boundingRect(
            with: NSSize(width: max(1, width - horizontalInsets), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(font.ascender - font.descender + font.leading, ceil(bounds.height))
    }
}
