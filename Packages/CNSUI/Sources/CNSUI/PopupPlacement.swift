import AppKit

public enum PopupPlacement {
    /// Positions a popup below the pointer on the display that contains it and
    /// clamps the complete panel to that display's visible work area.
    public static func origin(
        mouse: NSPoint,
        panelSize: NSSize,
        visibleFrames: [NSRect],
        verticalGap: CGFloat = 20
    ) -> NSPoint {
        guard let screen = selectedFrame(for: mouse, frames: visibleFrames) else {
            return NSPoint(x: mouse.x - panelSize.width / 2, y: mouse.y - panelSize.height - verticalGap)
        }
        let proposedX = mouse.x - panelSize.width / 2
        let proposedY = mouse.y - panelSize.height - verticalGap
        let maxX = max(screen.minX, screen.maxX - panelSize.width)
        let maxY = max(screen.minY, screen.maxY - panelSize.height)
        return NSPoint(
            x: min(max(proposedX, screen.minX), maxX),
            y: min(max(proposedY, screen.minY), maxY)
        )
    }

    private static func selectedFrame(for point: NSPoint, frames: [NSRect]) -> NSRect? {
        if let containing = frames.first(where: { $0.contains(point) }) { return containing }
        return frames.min { distanceSquared(from: point, to: $0) < distanceSquared(from: point, to: $1) }
    }

    private static func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        return pow(point.x - x, 2) + pow(point.y - y, 2)
    }
}
