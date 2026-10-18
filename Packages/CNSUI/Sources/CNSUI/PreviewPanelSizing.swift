import AppKit

/// Edges of the interactive preview panel that can be dragged to resize.
struct PreviewResizeEdges: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let left = PreviewResizeEdges(rawValue: 1 << 0)
    static let right = PreviewResizeEdges(rawValue: 1 << 1)
    static let top = PreviewResizeEdges(rawValue: 1 << 2)
    static let bottom = PreviewResizeEdges(rawValue: 1 << 3)
}

/// Sizes the editable preview from its wrapped text, within the current display.
@MainActor
enum PreviewPanelSizing {
    static let minimumInteractiveSize = NSSize(width: 320, height: 120)
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

    static func resizeEdges(
        at point: NSPoint,
        in size: NSSize,
        edgeThickness: CGFloat = 8,
        cornerSize: CGFloat = 14
    ) -> PreviewResizeEdges {
        let bounds = NSRect(origin: .zero, size: size)
        guard bounds.contains(point) else { return [] }

        let nearLeft = point.x <= edgeThickness
        let nearRight = point.x >= size.width - edgeThickness
        let nearBottom = point.y <= edgeThickness
        let nearTop = point.y >= size.height - edgeThickness

        let inCornerX = point.x <= cornerSize || point.x >= size.width - cornerSize
        let inCornerY = point.y <= cornerSize || point.y >= size.height - cornerSize
        let inCorner = inCornerX && inCornerY

        var edges: PreviewResizeEdges = []
        if nearLeft || (inCorner && point.x <= cornerSize) {
            edges.insert(.left)
        }
        if nearRight || (inCorner && point.x >= size.width - cornerSize) {
            edges.insert(.right)
        }
        if nearBottom || (inCorner && point.y <= cornerSize) {
            edges.insert(.bottom)
        }
        if nearTop || (inCorner && point.y >= size.height - cornerSize) {
            edges.insert(.top)
        }
        return edges
    }

    static func resizedFrame(
        initialFrame: NSRect,
        edges: PreviewResizeEdges,
        delta: NSPoint,
        minSize: NSSize = minimumInteractiveSize
    ) -> NSRect {
        var frame = initialFrame

        if edges.contains(.right) {
            frame.size.width = max(minSize.width, initialFrame.width + delta.x)
        } else if edges.contains(.left) {
            let newWidth = max(minSize.width, initialFrame.width - delta.x)
            frame.origin.x = initialFrame.maxX - newWidth
            frame.size.width = newWidth
        }

        if edges.contains(.top) {
            frame.size.height = max(minSize.height, initialFrame.height + delta.y)
        } else if edges.contains(.bottom) {
            let newHeight = max(minSize.height, initialFrame.height - delta.y)
            frame.origin.y = initialFrame.maxY - newHeight
            frame.size.height = newHeight
        }

        return frame
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
