import Cocoa

/// An independent native workspace, not a modal sheet or a tab of the editor.
/// Floating panels keep the timeline and other tools reachable while editing.
final class VideoToolPanel: NSPanel {
    init(contentSize: NSSize, title: String, controller: NSViewController) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.title = title
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = true
        // This is an activating panel: numeric fields and sliders use normal
        // keyboard focus. It must never merge into a window tab group.
        becomesKeyOnlyIfNeeded = false
        tabbingMode = .disallowed
        collectionBehavior.insert(.fullScreenAuxiliary)
        contentMinSize = NSSize(width: 820, height: 620)
        contentViewController = controller
    }
}

/// Pure frame geometry shared by open, focus and explicit Arrange actions.
/// Inputs and outputs use complete window frames, including the title bar.
enum VideoToolWindowLayout {
    private static let margin: CGFloat = 16
    private static let gap: CGFloat = 16
    private static let cascade: CGFloat = 32

    /// Keep the existing position whenever it is already on this monitor.
    /// If a monitor is smaller than the window minimum, screen bounds win;
    /// AppKit/the caller can handle the resulting minimum-size restriction.
    static func clamp(frame: NSRect, visibleFrame: NSRect) -> NSRect {
        let available = usableFrame(visibleFrame)
        let size = fittedSize(frame.size, in: available)
        let x = finite(frame.origin.x, fallback: available.midX - size.width / 2)
        let y = finite(frame.origin.y, fallback: available.midY - size.height / 2)
        return NSRect(
            x: min(max(x, available.minX), available.maxX - size.width),
            y: min(max(y, available.minY), available.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    /// Cascade only a newly created panel. Reopening/focusing existing panels
    /// should use clamp instead, so user positioning is never discarded.
    static func initialFrame(size: NSSize, visibleFrame: NSRect, existingFrames: [NSRect]) -> NSRect {
        let available = usableFrame(visibleFrame)
        let fitted = fittedSize(size, in: available)
        let centered = NSRect(x: available.midX - fitted.width / 2, y: available.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        guard let previous = existingFrames.last else { return centered }

        let alignedY = previous.maxY - fitted.height
        let origins = [
            NSPoint(x: previous.minX + cascade, y: alignedY - cascade),
            NSPoint(x: previous.minX - cascade, y: alignedY - cascade),
            NSPoint(x: previous.minX + cascade, y: alignedY + cascade),
            NSPoint(x: previous.minX - cascade, y: alignedY + cascade),
            NSPoint(x: available.minX, y: available.maxY - fitted.height),
            NSPoint(x: available.maxX - fitted.width, y: available.maxY - fitted.height),
            NSPoint(x: available.minX, y: available.minY),
            NSPoint(x: available.maxX - fitted.width, y: available.minY),
            centered.origin
        ]
        for origin in origins {
            let candidate = clamp(frame: NSRect(origin: origin, size: fitted), visibleFrame: visibleFrame)
            // A visible title-bar offset matters more than whether the two
            // panels have different dimensions but exactly the same origin.
            if existingFrames.allSatisfy({ distance(NSPoint(x: candidate.minX, y: candidate.maxY), NSPoint(x: $0.minX, y: $0.maxY)) >= 8 }) {
                return candidate
            }
        }
        // If every available corner is occupied, a modest offset still gives
        // the best achievable cascade. A full-screen-sized panel has no room
        // to move at all; do not push it offscreen merely to force an offset.
        return clamp(frame: NSRect(origin: origins[0], size: fitted), visibleFrame: visibleFrame)
    }

    /// Arrange side by side only if all minimum FRAME widths and heights fit.
    /// Otherwise cascade within the screen, without forcing unusable columns.
    static func arrangedFrames(currentFrames: [NSRect], minimumSizes: [NSSize], visibleFrame: NSRect) -> [NSRect] {
        guard !currentFrames.isEmpty else { return [] }
        let available = usableFrame(visibleFrame)
        let minimums = currentFrames.indices.map { index -> NSSize in
            let requested = minimumSizes.indices.contains(index) ? minimumSizes[index] : NSSize(width: 1, height: 1)
            return NSSize(width: positive(requested.width), height: positive(requested.height))
        }
        let gutters = CGFloat(currentFrames.count - 1) * gap
        let minimumWidth = minimums.reduce(CGFloat.zero) { $0 + $1.width }
        let minimumHeight = minimums.map(\.height).max() ?? 1
        guard minimumWidth + gutters <= available.width, minimumHeight <= available.height else {
            var result: [NSRect] = []
            for (index, frame) in currentFrames.enumerated() {
                let size = NSSize(width: max(positive(frame.width), minimums[index].width), height: max(positive(frame.height), minimums[index].height))
                result.append(initialFrame(size: size, visibleFrame: visibleFrame, existingFrames: result))
            }
            return result
        }

        let desiredWidths = currentFrames.indices.map { max(positive(currentFrames[$0].width), minimums[$0].width) }
        let desiredTotal = desiredWidths.reduce(0, +)
        let totalWidth = min(desiredTotal, available.width - gutters)
        let extraWidth = totalWidth - minimumWidth
        let desiredExtra = max(0, desiredTotal - minimumWidth)
        let widths = currentFrames.indices.map { index -> CGFloat in
            guard desiredExtra > 0 else { return minimums[index].width }
            return minimums[index].width + extraWidth * (desiredWidths[index] - minimums[index].width) / desiredExtra
        }
        let desiredHeight = currentFrames.map { positive($0.height) }.max() ?? minimumHeight
        let height = min(available.height, max(minimumHeight, desiredHeight))
        var x = available.midX - (totalWidth + gutters) / 2
        return widths.map { width in
            let frame = NSRect(x: x, y: available.maxY - height, width: width, height: height)
            x += width + gap
            return frame
        }
    }

    private static func usableFrame(_ frame: NSRect) -> NSRect {
        let width = positive(frame.width), height = positive(frame.height)
        let normalized = NSRect(x: finite(frame.minX, fallback: 0), y: finite(frame.minY, fallback: 0), width: width, height: height)
        let horizontal = min(margin, max(0, (width - 1) / 2))
        let vertical = min(margin, max(0, (height - 1) / 2))
        return normalized.insetBy(dx: horizontal, dy: vertical)
    }
    private static func fittedSize(_ size: NSSize, in frame: NSRect) -> NSSize {
        NSSize(width: min(positive(size.width), frame.width), height: min(positive(size.height), frame.height))
    }
    private static func positive(_ value: CGFloat) -> CGFloat { value.isFinite ? max(1, value) : 1 }
    private static func finite(_ value: CGFloat, fallback: CGFloat) -> CGFloat { value.isFinite ? value : fallback }
    private static func distance(_ first: NSPoint, _ second: NSPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }
}
