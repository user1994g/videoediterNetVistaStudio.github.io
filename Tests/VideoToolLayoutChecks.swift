import Cocoa

@main struct VideoToolLayoutChecks {
    static func main() {
        let wide = NSRect(x: -2560, y: 180, width: 2560, height: 1400)
        let narrow = NSRect(x: 200, y: -900, width: 1100, height: 850)
        let frames = [NSRect(x: 0, y: 0, width: 1120, height: 880), NSRect(x: 0, y: 0, width: 1240, height: 860)]
        let minimums = [NSSize(width: 820, height: 648), NSSize(width: 820, height: 648)]

        let arranged = VideoToolWindowLayout.arrangedFrames(currentFrames: frames, minimumSizes: minimums, visibleFrame: wide)
        check(arranged.count == 2, "Arrange returns one frame for each tool")
        check(!arranged[0].intersects(arranged[1]), "Wide monitor arranges tools side by side")
        for index in arranged.indices {
            check(wide.contains(arranged[index]), "Arranged frame respects negative monitor origin")
            check(arranged[index].width >= minimums[index].width, "Side by side preserves minimum frame width")
            check(arranged[index].height >= minimums[index].height, "Side by side preserves minimum frame height")
        }

        let identical = [NSRect(x: 0, y: 0, width: 900, height: 680), NSRect(x: 0, y: 0, width: 900, height: 680)]
        let cascaded = VideoToolWindowLayout.arrangedFrames(currentFrames: identical, minimumSizes: minimums, visibleFrame: narrow)
        check(cascaded.count == 2 && cascaded[0].origin != cascaded[1].origin, "Narrow monitor exposes separate title bars")
        cascaded.forEach { check(narrow.contains($0), "Cascaded frames fit nonzero monitor bounds") }
        check(cascaded[0].intersects(cascaded[1]), "Narrow layout cascades instead of forcing undersized columns")
        check(cascaded.allSatisfy { $0.width >= 820 && $0.height >= 648 }, "Cascade retains usable panel dimensions")

        let first = VideoToolWindowLayout.initialFrame(size: frames[0].size, visibleFrame: wide, existingFrames: [])
        let second = VideoToolWindowLayout.initialFrame(size: frames[0].size, visibleFrame: wide, existingFrames: [first])
        check(first.origin != second.origin, "A new tool must not exactly cover the previous tool")
        check(wide.contains(first) && wide.contains(second), "Initial cascade fits this monitor")
        let taller = VideoToolWindowLayout.initialFrame(size: NSSize(width: first.width, height: first.height + 150), visibleFrame: wide, existingFrames: [first])
        check(abs(taller.maxY - first.maxY) >= 28, "Different-sized tools still expose the previous title bar")
        let moved = NSRect(x: -2470, y: 320, width: 950, height: 750)
        check(VideoToolWindowLayout.clamp(frame: moved, visibleFrame: wide) == moved, "Focusing an on-screen tool preserves user position and size")

        let edge = NSRect(x: 1200, y: 4000, width: 5000, height: 5000)
        let clamped = VideoToolWindowLayout.clamp(frame: edge, visibleFrame: narrow)
        check(narrow.contains(clamped), "Offscreen and oversized frames clamp into the chosen monitor")
        let atEdge = NSRect(x: narrow.maxX - 916, y: narrow.minY + 16, width: 900, height: 680)
        let nextAtEdge = VideoToolWindowLayout.initialFrame(size: atEdge.size, visibleFrame: narrow, existingFrames: [atEdge])
        check(nextAtEdge.origin != atEdge.origin && narrow.contains(nextAtEdge), "Cascade finds a visible offset near the screen edge")

        let triple = VideoToolWindowLayout.arrangedFrames(currentFrames: Array(repeating: identical[0], count: 3), minimumSizes: Array(repeating: NSSize(width: 600, height: 600), count: 3), visibleFrame: wide)
        check(triple.count == 3 && zip(triple, triple.dropFirst()).allSatisfy { !$0.0.intersects($0.1) }, "Arrange supports more than two native tools")
        check(VideoToolWindowLayout.arrangedFrames(currentFrames: [], minimumSizes: [], visibleFrame: wide).isEmpty, "Empty arrangement is safe")
        let one = VideoToolWindowLayout.arrangedFrames(currentFrames: [frames[0]], minimumSizes: [], visibleFrame: narrow)
        check(one.count == 1 && narrow.contains(one[0]), "Missing minimum metadata is handled safely")
        let tiny = NSRect(x: -20, y: -20, width: 24, height: 24)
        check(tiny.contains(VideoToolWindowLayout.clamp(frame: edge, visibleFrame: tiny)), "Tiny bounds never produce a negative frame")
        let invalid = VideoToolWindowLayout.clamp(frame: NSRect(x: CGFloat.nan, y: CGFloat.infinity, width: CGFloat.infinity, height: CGFloat.nan), visibleFrame: narrow)
        check(invalid.origin.x.isFinite && invalid.origin.y.isFinite && invalid.width > 0 && invalid.height > 0, "Invalid geometry cannot escape as NaN or infinity")

        if CommandLine.arguments.contains("--native") { checkNativePanel() }
        print("PASS: independent video-tool panel geometry, wide/narrow arrangements, cascade and monitor-origin bounds")
    }

    private static func checkNativePanel() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let panel = VideoToolPanel(contentSize: NSSize(width: 900, height: 700), title: "Panel Test", controller: controller)
        check(panel.isFloatingPanel && panel.level == .floating, "Tool remains above the video editor")
        check(panel.tabbingMode == .disallowed, "Tool cannot merge into a window tab group")
        check(!panel.styleMask.contains(.nonactivatingPanel) && !panel.becomesKeyOnlyIfNeeded, "Native inputs receive normal keyboard focus")
        check(panel.contentMinSize == NSSize(width: 820, height: 620), "Tool preserves usable minimum content size")
        check(!panel.isReleasedWhenClosed && panel.contentViewController === controller, "Retained tool keeps its controller when closed")
        check(panel.hidesOnDeactivate && panel.collectionBehavior.contains(.fullScreenAuxiliary), "Tool follows normal native utility-window behavior")
        panel.close()
        print("PASS: native floating panel flags, controller ownership and keyboard behavior")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
