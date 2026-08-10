import Cocoa
import UniformTypeIdentifiers

/// A small shared placement engine for both native pointer moves and imported
/// media. A track may contain any number of clips, but two clips never occupy
/// the same time range on that exact track.
struct TimelineLaneInterval {
    let kind: MediaKind
    let track: Int
    let start: Double
    let duration: Double
}

enum TimelineLanePlacement {
    static let frameRate = 30.0
    private static let epsilon = 0.000_001

    static func roundedFrame(_ time: Double) -> Double {
        max(0, (time * frameRate).rounded() / frameRate)
    }

    private static func floorFrame(_ time: Double) -> Double {
        floor(time * frameRate) / frameRate
    }

    private static func ceilFrame(_ time: Double) -> Double {
        ceil(time * frameRate) / frameRate
    }

    static func isAvailable(_ moving: [TimelineLaneInterval], among stationary: [TimelineLaneInterval], delta: Double) -> Bool {
        guard let earliest = moving.map(\.start).min(), delta >= -earliest - epsilon else { return false }
        for item in moving {
            let start = roundedFrame(item.start + delta)
            let end = start + max(1 / frameRate, item.duration)
            for obstacle in stationary where obstacle.kind == item.kind && obstacle.track == item.track {
                let obstacleEnd = obstacle.start + max(1 / frameRate, obstacle.duration)
                if start < obstacleEnd - epsilon && end > obstacle.start + epsilon { return false }
            }
        }
        return true
    }

    /// Returns the legal common time delta closest to the pointer request.
    /// Ties choose the later/right-hand position, matching normal insert flow.
    static func nearestDelta(
        moving: [TimelineLaneInterval],
        stationary: [TimelineLaneInterval],
        proposedDelta: Double
    ) -> Double {
        guard let earliest = moving.map(\.start).min() else { return 0 }
        let minimumDelta = -earliest
        let proposed = max(minimumDelta, proposedDelta)
        if isAvailable(moving, among: stationary, delta: proposed) { return proposed }

        var candidates = [minimumDelta]
        for item in moving {
            let duration = max(1 / frameRate, item.duration)
            for obstacle in stationary where obstacle.kind == item.kind && obstacle.track == item.track {
                let obstacleEnd = obstacle.start + max(1 / frameRate, obstacle.duration)
                candidates.append(floorFrame(obstacle.start - duration) - item.start)
                candidates.append(ceilFrame(obstacleEnd) - item.start)
            }
        }
        if let latestEnd = stationary.map({ $0.start + max(1 / frameRate, $0.duration) }).max() {
            candidates.append(ceilFrame(latestEnd) - earliest)
        }

        let legal = candidates.filter { isAvailable(moving, among: stationary, delta: $0) }
        return legal.min { left, right in
            let leftDistance = abs(left - proposed)
            let rightDistance = abs(right - proposed)
            if abs(leftDistance - rightDistance) > epsilon { return leftDistance < rightDistance }
            return left > right
        } ?? proposed
    }

    static func nearestStart(
        requested: Double,
        duration: Double,
        kind: MediaKind,
        track: Int,
        stationary: [TimelineLaneInterval]
    ) -> Double {
        let requestedStart = roundedFrame(max(0, requested))
        let moving = [TimelineLaneInterval(kind: kind, track: track, start: requestedStart, duration: duration)]
        let delta = nearestDelta(moving: moving, stationary: stationary, proposedDelta: 0)
        return roundedFrame(requestedStart + delta)
    }
}

/// A native, non-destructive editing timeline.  The ruler, track headers and
/// clip canvas are separate views so labels stay pinned while long projects use
/// AppKit's normal two-axis scrolling.
final class ProfessionalTimelineView: NSView {
    weak var controller: EditorController?

    var clips: [TimelineClip] = [] {
        didSet {
            guard clips != oldValue, !isApplyingSnapshot else { return }
            let previousVideoTrackCount = cachedVideoTrackCount
            let previousScrollOrigin = canvasScrollView.contentView.bounds.origin
            editOverrides.removeAll(keepingCapacity: true)
            refreshTimelineMetrics()
            selectedIDs.formIntersection(Set(clips.map(\.id)))
            updateCanvasWidth()
            // Higher-numbered video tracks are inserted above V1. Keep the
            // existing lanes under the pointer instead of making every clip
            // jump down when the automatic blank top lane appears after a drop.
            let insertedVideoRows = cachedVideoTrackCount - previousVideoTrackCount
            if insertedVideoRows > 0 {
                scrollCanvas(to: NSPoint(
                    x: previousScrollOrigin.x,
                    y: previousScrollOrigin.y + CGFloat(insertedVideoRows) * trackHeight
                ))
            }
            invalidateTimeline()
        }
    }
    var selectedIDs = Set<UUID>() {
        didSet {
            guard selectedIDs != oldValue, !isApplyingSnapshot else { return }
            canvasView.needsDisplay = true
            canvasView.window?.invalidateCursorRects(for: canvasView)
        }
    }
    /// The controller may populate this with either clip IDs or asset IDs.
    /// Supporting both makes trims safe for repeated instances of one source.
    var sourceDurations: [UUID: Double] = [:] {
        didSet {
            guard sourceDurations != oldValue, !isApplyingSnapshot else { return }
            refreshTimelineMetrics()
            updateCanvasWidth()
            invalidateTimeline()
        }
    }
    var bladeMode = false {
        didSet {
            canvasView.window?.invalidateCursorRects(for: canvasView)
            canvasView.needsDisplay = true
        }
    }
    var selectsLinkedPairs = true
    var snappingEnabled = true {
        didSet {
            if !snappingEnabled { snapGuideTime = nil }
            canvasView.needsDisplay = true
        }
    }

    var currentPlayheadTime: Double { playheadTime }
    var playheadX: CGFloat { xPosition(for: playheadTime) }
    var zoomScale: CGFloat { pixelsPerSecond }
    var isInteracting: Bool { moveState != nil || trimState != nil || marqueeState != nil }

    private let headerWidth: CGFloat = 148
    private let rulerHeight: CGFloat = 34
    private let sectionGap: CGFloat = 8
    private let trailingCanvasPadding: CGFloat = 180
    private let minimumPixelsPerSecond: CGFloat = 3
    private let maximumPixelsPerSecond: CGFloat = 1_600
    private let frameRate = 30.0
    private let snapDistance: CGFloat = 8

    private let cornerView = ProfessionalTimelineCornerView(frame: .zero)
    private let rulerScrollView = NSScrollView(frame: .zero)
    private let headerScrollView = NSScrollView(frame: .zero)
    private let canvasScrollView = NSScrollView(frame: .zero)
    private let rulerView = ProfessionalTimelineRulerView(frame: .zero)
    private let headerView = ProfessionalTimelineHeaderView(frame: .zero)
    private let canvasView = ProfessionalTimelineCanvasView(frame: .zero)

    private var pixelsPerSecond: CGFloat = 52
    private var trackHeight: CGFloat = 62
    private var playheadTime = 0.0
    private var snapGuideTime: Double?
    private var dropGuide: (time: Double, kind: MediaKind, track: Int)?
    private var externalFileDragURLs: [URL] = []
    private var observers: [NSObjectProtocol] = []
    private var fitRestoreZoom: CGFloat?
    private var isApplyingFit = false
    private var isApplyingSnapshot = false
    private var lockedTrackCounts: (video: Int, audio: Int)?
    private var cachedVideoTrackCount = 3
    private var cachedAudioTrackCount = 3
    private var cachedBaseTimelineDuration = 1.0
    /// During a gesture only the touched clips live here. The saved model array
    /// remains untouched until mouse-up, avoiding an O(n) property assignment,
    /// geometry rebuild and observer cascade for every pointer event.
    private var editOverrides: [UUID: TimelineClip] = [:]
    private var lastCanvasToolTipBounds = NSRect.zero
    private var lastRulerToolTipBounds = NSRect.zero
    private var lastHeaderToolTipBounds = NSRect.zero

    private enum TrimEdge { case leading, trailing }

    private struct MoveState {
        let origin: NSPoint
        let initial: [UUID: TimelineClip]
        let ids: Set<UUID>
        let anchorID: UUID
        let anchorKind: MediaKind
        let anchorTrack: Int
        let clickSelection: Set<UUID>?
        var changed = false
    }

    private struct TrimState {
        let origin: NSPoint
        let initial: [UUID: TimelineClip]
        let ids: Set<UUID>
        let primaryID: UUID
        let edge: TrimEdge
        var changed = false
    }

    private struct MarqueeState {
        let origin: NSPoint
        let originalSelection: Set<UUID>
        let additive: Bool
        let solo: Bool
        var dragged = false
    }

    private var moveState: MoveState?
    private var trimState: TrimState?
    private var marqueeState: MarqueeState?
    private var isSeeking = false
    private var lastDragLocationInWindow: NSPoint?
    private var autoScrollTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1).cgColor
        clipsToBounds = true

        rulerView.owner = self
        headerView.owner = self
        canvasView.owner = self

        configurePinnedScrollView(rulerScrollView, documentView: rulerView)
        configurePinnedScrollView(headerScrollView, documentView: headerView)

        canvasScrollView.drawsBackground = true
        canvasScrollView.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1)
        canvasScrollView.borderType = .noBorder
        canvasScrollView.hasHorizontalScroller = true
        canvasScrollView.hasVerticalScroller = true
        canvasScrollView.autohidesScrollers = true
        canvasScrollView.scrollerStyle = .overlay
        canvasScrollView.horizontalScrollElasticity = .automatic
        canvasScrollView.verticalScrollElasticity = .automatic
        canvasScrollView.documentView = canvasView

        addSubview(cornerView)
        addSubview(rulerScrollView)
        addSubview(headerScrollView)
        addSubview(canvasScrollView)

        canvasScrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: canvasScrollView.contentView,
            queue: .main
        ) { [weak self] _ in self?.synchronizePinnedRegions() })

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Professional video editing timeline")
        setAccessibilityHelp("Use V for Select, C for Blade, S for snapping, Space to play, and Option-scroll to zoom.")
        updateCanvasWidth()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        fatalError("ProfessionalTimelineView must be created in code")
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        autoScrollTimer?.invalidate()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 350) }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width)
        let height = max(0, bounds.height)
        let rail = min(headerWidth, max(0, width - 120))
        let top = min(rulerHeight, height)

        cornerView.frame = NSRect(x: 0, y: 0, width: rail, height: top)
        rulerScrollView.frame = NSRect(x: rail, y: 0, width: max(0, width - rail), height: top)
        headerScrollView.frame = NSRect(x: 0, y: top, width: rail, height: max(0, height - top))
        canvasScrollView.frame = NSRect(x: rail, y: top, width: max(0, width - rail), height: max(0, height - top))
        updateDocumentGeometry()
        synchronizePinnedRegions()
    }

    private func configurePinnedScrollView(_ scrollView: NSScrollView, documentView: NSView) {
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1)
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = documentView
    }

    // MARK: - Public timeline controls

    /// Installs one controller snapshot in a single layout pass. Selection
    /// changes used to assign clips, selection and durations separately, which
    /// could reflow and scroll the timeline three times while a drag began.
    func applySnapshot(
        clips snapshotClips: [TimelineClip],
        selectedIDs snapshotSelection: Set<UUID>,
        sourceDurations snapshotDurations: [UUID: Double],
        resetTrackStructure: Bool = false
    ) {
        let validIDs = Set(snapshotClips.map(\.id))
        let nextSelection = snapshotSelection.intersection(validIDs)
        let hasModelChange = clips != snapshotClips || selectedIDs != nextSelection || sourceDurations != snapshotDurations
        guard hasModelChange || !editOverrides.isEmpty || resetTrackStructure else { return }

        let previousVideoTrackCount = cachedVideoTrackCount
        let previousScrollOrigin = canvasScrollView.contentView.bounds.origin
        if resetTrackStructure {
            cachedVideoTrackCount = 3
            cachedAudioTrackCount = 3
        }

        isApplyingSnapshot = true
        clips = snapshotClips
        selectedIDs = nextSelection
        sourceDurations = snapshotDurations
        isApplyingSnapshot = false

        editOverrides.removeAll(keepingCapacity: true)
        refreshTimelineMetrics()
        updateCanvasWidth()

        let insertedVideoRows = cachedVideoTrackCount - previousVideoTrackCount
        if resetTrackStructure {
            scrollCanvas(to: .zero)
        } else if insertedVideoRows > 0 {
            scrollCanvas(to: NSPoint(
                x: previousScrollOrigin.x,
                y: previousScrollOrigin.y + CGFloat(insertedVideoRows) * trackHeight
            ))
        }
        invalidateTimeline()
    }

    func setZoom(_ requestedScale: CGFloat, anchorTime: Double? = nil) {
        applyZoom(requestedScale, anchorTime: anchorTime, minimumScale: minimumPixelsPerSecond)
    }

    private func applyZoom(_ requestedScale: CGFloat, anchorTime: Double?, minimumScale: CGFloat) {
        let requested = min(maximumPixelsPerSecond, max(minimumScale, requestedScale))
        guard abs(requested - pixelsPerSecond) > 0.0001 else { return }

        let visible = canvasScrollView.contentView.bounds
        let anchor = max(0, anchorTime ?? playheadTime)
        let oldAnchorX = xPosition(for: anchor)
        var viewportOffset = oldAnchorX - visible.minX
        if viewportOffset < 0 || viewportOffset > visible.width {
            viewportOffset = visible.width * 0.5
        }

        pixelsPerSecond = requested
        if !isApplyingFit { fitRestoreZoom = nil }
        updateDocumentGeometry()

        let maximumX = max(0, canvasView.frame.width - visible.width)
        let destinationX = min(maximumX, max(0, xPosition(for: anchor) - viewportOffset))
        canvasScrollView.contentView.scroll(to: NSPoint(x: destinationX, y: visible.minY))
        canvasScrollView.reflectScrolledClipView(canvasScrollView.contentView)
        synchronizePinnedRegions()
        invalidateTimeline()
    }

    func fittedZoom(for viewportWidth: CGFloat) -> CGFloat {
        // Fit is deliberately allowed below the 3 px/s manual-navigation
        // floor. Otherwise a long-form project can never be shown end to end.
        let usableWidth = max(1, viewportWidth - trailingCanvasPadding - 8)
        let duration = max(1.0, semanticTimelineDuration)
        return min(maximumPixelsPerSecond, max(0.000_1, usableWidth / CGFloat(duration)))
    }

    func toggleFit() {
        if let restore = fitRestoreZoom {
            fitRestoreZoom = nil
            setZoom(restore, anchorTime: playheadTime)
            return
        }
        let previous = pixelsPerSecond
        isApplyingFit = true
        applyZoom(
            fittedZoom(for: canvasScrollView.contentSize.width),
            anchorTime: 0,
            minimumScale: 0.000_1
        )
        isApplyingFit = false
        fitRestoreZoom = previous
        canvasScrollView.contentView.scroll(to: NSPoint(x: 0, y: canvasScrollView.contentView.bounds.minY))
        canvasScrollView.reflectScrolledClipView(canvasScrollView.contentView)
    }

    func revealClip(_ id: UUID) {
        guard let base = clips.first(where: { $0.id == id }) else { return }
        let clip = displayed(base)
        let rect = clipRect(clip).insetBy(dx: -24, dy: -10)
        let visible = canvasScrollView.contentView.bounds
        var x = visible.minX
        var y = visible.minY
        if rect.minX < visible.minX { x = rect.minX }
        else if rect.maxX > visible.maxX { x = rect.maxX - visible.width }
        if rect.minY < visible.minY { y = rect.minY }
        else if rect.maxY > visible.maxY { y = rect.maxY - visible.height }
        scrollCanvas(to: NSPoint(x: x, y: y))
    }

    func updateCanvasWidth() {
        needsLayout = true
        updateDocumentGeometry()
    }

    func updatePlaybackPlayhead(_ time: Double) {
        updatePlayhead(time, notifyController: false)
    }

    func keepPlayheadVisible() {
        // Playback may continue while arranging clips. Do not let the automatic
        // playhead follow scroll the canvas underneath a captured drag origin.
        guard !isInteracting else { return }
        let visible = canvasScrollView.contentView.bounds
        let x = xPosition(for: playheadTime)
        let margin = min(100, visible.width * 0.18)
        guard x < visible.minX + margin || x > visible.maxX - margin else { return }
        scrollCanvas(to: NSPoint(x: x - visible.width * 0.35, y: visible.minY))
    }

    func adjustTrackHeight(by delta: CGFloat) {
        let oldHeight = trackHeight
        let requested = min(120, max(38, oldHeight + delta))
        guard abs(requested - oldHeight) > 0.01 else { return }
        let visible = canvasScrollView.contentView.bounds
        let oldVideoHeight = CGFloat(videoTrackCount) * oldHeight
        let oldAudioOrigin = oldVideoHeight + sectionGap
        enum VerticalAnchor {
            case videoRow(CGFloat)
            case divider(CGFloat)
            case audioRow(CGFloat)
        }
        let anchor: VerticalAnchor
        if visible.midY < oldVideoHeight {
            anchor = .videoRow(visible.midY / oldHeight)
        } else if visible.midY < oldAudioOrigin {
            anchor = .divider((visible.midY - oldVideoHeight) / max(1, sectionGap))
        } else {
            anchor = .audioRow((visible.midY - oldAudioOrigin) / oldHeight)
        }
        trackHeight = requested
        updateDocumentGeometry()
        let newVideoHeight = CGFloat(videoTrackCount) * requested
        let newAnchorY: CGFloat
        switch anchor {
        case .videoRow(let row): newAnchorY = row * requested
        case .divider(let fraction): newAnchorY = newVideoHeight + fraction * sectionGap
        case .audioRow(let row): newAnchorY = newVideoHeight + sectionGap + row * requested
        }
        scrollCanvas(to: NSPoint(x: visible.minX, y: newAnchorY - visible.height * 0.5))
        invalidateTimeline()
    }

    // MARK: - Geometry

    fileprivate var videoTrackCount: Int { lockedTrackCounts?.video ?? cachedVideoTrackCount }
    fileprivate var audioTrackCount: Int { lockedTrackCounts?.audio ?? cachedAudioTrackCount }
    fileprivate var videoSectionHeight: CGFloat { CGFloat(videoTrackCount) * trackHeight }
    fileprivate var audioSectionOrigin: CGFloat { videoSectionHeight + sectionGap }
    fileprivate var canvasContentHeight: CGFloat { audioSectionOrigin + CGFloat(audioTrackCount) * trackHeight }

    private var semanticTimelineDuration: Double {
        let previewEnd = editOverrides.values.reduce(cachedBaseTimelineDuration) { result, clip in
            max(result, clip.timelineStart + clipDuration(clip))
        }
        return max(playheadTime, previewEnd, 1)
    }

    private func displayed(_ clip: TimelineClip) -> TimelineClip {
        editOverrides[clip.id] ?? clip
    }

    private func refreshTimelineMetrics() {
        var highestVideo = -1
        var highestAudio = -1
        var duration = 1.0
        for base in clips {
            let clip = displayed(base)
            if clip.kind == .video { highestVideo = max(highestVideo, clip.track) }
            else { highestAudio = max(highestAudio, clip.track) }
            duration = max(duration, clip.timelineStart + clipDuration(clip))
        }
        // Track rails are stable within a project. Moving the final V3 clip
        // down to V1 must not delete a row underneath the mouse and jump the
        // pinned headers. Explicit project loading resets these counts.
        cachedVideoTrackCount = max(cachedVideoTrackCount, max(3, highestVideo + 2))
        cachedAudioTrackCount = max(cachedAudioTrackCount, max(3, highestAudio + 2))
        cachedBaseTimelineDuration = duration
    }

    private func updateDocumentGeometry() {
        let viewportWidth = max(1, canvasScrollView.contentSize.width)
        let viewportHeight = max(1, canvasScrollView.contentSize.height)
        let semanticWidth = CGFloat(semanticTimelineDuration) * pixelsPerSecond
        let width = max(viewportWidth, semanticWidth + trailingCanvasPadding)
        let height = max(viewportHeight, canvasContentHeight)

        setFrame(canvasView, size: NSSize(width: width, height: height))
        setFrame(rulerView, size: NSSize(width: width, height: max(1, rulerScrollView.contentSize.height)))
        setFrame(headerView, size: NSSize(width: max(1, headerScrollView.contentSize.width), height: height))
        updateToolTips()
    }

    private func setFrame(_ view: NSView, size: NSSize) {
        guard abs(view.frame.width - size.width) > 0.25 || abs(view.frame.height - size.height) > 0.25 else { return }
        view.frame = NSRect(origin: .zero, size: size)
    }

    private func synchronizePinnedRegions() {
        let origin = canvasScrollView.contentView.bounds.origin
        rulerScrollView.contentView.scroll(to: NSPoint(x: origin.x, y: 0))
        headerScrollView.contentView.scroll(to: NSPoint(x: 0, y: origin.y))
        rulerScrollView.reflectScrolledClipView(rulerScrollView.contentView)
        headerScrollView.reflectScrolledClipView(headerScrollView.contentView)
    }

    private func scrollCanvas(to proposed: NSPoint) {
        let viewport = canvasScrollView.contentView.bounds.size
        let maximumX = max(0, canvasView.frame.width - viewport.width)
        let maximumY = max(0, canvasView.frame.height - viewport.height)
        let point = NSPoint(x: min(maximumX, max(0, proposed.x)), y: min(maximumY, max(0, proposed.y)))
        canvasScrollView.contentView.scroll(to: point)
        canvasScrollView.reflectScrolledClipView(canvasScrollView.contentView)
        synchronizePinnedRegions()
    }

    fileprivate func trackY(kind: MediaKind, track: Int) -> CGFloat {
        if kind == .video {
            let clamped = min(videoTrackCount - 1, max(0, track))
            // V1 sits nearest the audio tracks; higher video tracks stack above.
            return CGFloat(videoTrackCount - 1 - clamped) * trackHeight
        }
        return audioSectionOrigin + CGFloat(min(audioTrackCount - 1, max(0, track))) * trackHeight
    }

    fileprivate func trackTarget(at point: NSPoint) -> (kind: MediaKind, track: Int) {
        if point.y < videoSectionHeight {
            let row = min(videoTrackCount - 1, max(0, Int(point.y / trackHeight)))
            return (.video, videoTrackCount - 1 - row)
        }
        let audioY = max(0, point.y - audioSectionOrigin)
        let row = min(audioTrackCount - 1, max(0, Int(audioY / trackHeight)))
        return (.audio, row)
    }

    private func compatibleTrack(at point: NSPoint, kind: MediaKind) -> Int {
        switch kind {
        case .video:
            if point.y >= videoSectionHeight { return 0 }
            let row = min(videoTrackCount - 1, max(0, Int(max(0, point.y) / trackHeight)))
            return videoTrackCount - 1 - row
        case .audio:
            if point.y <= audioSectionOrigin { return 0 }
            return min(audioTrackCount - 1, max(0, Int((point.y - audioSectionOrigin) / trackHeight)))
        }
    }

    fileprivate func clipDuration(_ clip: TimelineClip) -> Double {
        if clip.outPoint > clip.inPoint { return clip.outPoint - clip.inPoint }
        let sourceDuration = sourceDurations[clip.id] ?? sourceDurations[clip.assetID] ?? 0
        return max(0, sourceDuration - clip.inPoint)
    }

    fileprivate func clipRect(_ clip: TimelineClip) -> NSRect {
        NSRect(
            x: xPosition(for: clip.timelineStart),
            y: trackY(kind: clip.kind, track: clip.track) + 5,
            width: CGFloat(clipDuration(clip)) * pixelsPerSecond,
            height: max(1, trackHeight - 10)
        )
    }

    private func hitRect(for clip: TimelineClip) -> NSRect {
        let semantic = clipRect(clip)
        let extra = max(0, (10 - semantic.width) * 0.5)
        return semantic.insetBy(dx: -extra, dy: 0)
    }

    fileprivate func xPosition(for time: Double) -> CGFloat { CGFloat(max(0, time)) * pixelsPerSecond }
    fileprivate func time(atX x: CGFloat) -> Double { max(0, Double(x / pixelsPerSecond)) }
    private func quantized(_ time: Double) -> Double {
        guard time.isFinite else { return 0 }
        return max(0, (time * frameRate).rounded() / frameRate)
    }

    private func clipHit(at point: NSPoint) -> (index: Int, clip: TimelineClip)? {
        for (index, base) in clips.enumerated().reversed() {
            let clip = displayed(base)
            if hitRect(for: clip).contains(point) { return (index, clip) }
        }
        return nil
    }

    private func trimEdge(at point: NSPoint, clip: TimelineClip) -> TrimEdge? {
        let rect = clipRect(clip)
        // At a very wide Fit view, a short clip still needs a usable body for
        // moving. Edge trim activates once there is room for two unambiguous
        // handles and a body region between them.
        guard rect.width >= 16 else { return nil }
        let hitWidth = min(8, max(3, rect.width * 0.18))
        guard point.y >= rect.minY, point.y <= rect.maxY else { return nil }
        if abs(point.x - rect.minX) <= hitWidth { return .leading }
        if abs(point.x - rect.maxX) <= hitWidth { return .trailing }
        return nil
    }

    // MARK: - Selection and snapping

    private func linkedComponent(containing clip: TimelineClip, solo: Bool) -> Set<UUID> {
        guard selectsLinkedPairs, !solo, let group = clip.groupID else { return [clip.id] }
        let linked = Set(clips.lazy.filter { $0.groupID == group }.map(\.id))
        return linked.isEmpty ? [clip.id] : linked
    }

    private func publishSelection(_ ids: Set<UUID>, primary: UUID?) {
        selectedIDs = ids
        controller?.selectTimelineClips(ids, primary: primary)
    }

    private func selectionForClick(_ clip: TimelineClip, event: NSEvent) -> Set<UUID> {
        let component = linkedComponent(containing: clip, solo: event.modifierFlags.contains(.option))
        if event.modifierFlags.contains(.command) {
            var next = selectedIDs
            if next.contains(clip.id) { next.subtract(component) }
            else { next.formUnion(component) }
            return next
        }
        // In linked mode, clicking one member of an existing multi-selection
        // keeps the selection together for a group drag. In Single mode a plain
        // click must collapse even an already-selected linked pair to the exact
        // picture or sound component the user clicked.
        if selectsLinkedPairs, selectedIDs.contains(clip.id), !event.modifierFlags.contains(.option) { return selectedIDs }
        return component
    }

    private func snapCandidates(excluding ids: Set<UUID>) -> [Double] {
        var values = [0.0, playheadTime]
        for clip in clips where !ids.contains(clip.id) {
            values.append(clip.timelineStart)
            values.append(clip.timelineStart + clipDuration(clip))
        }
        return values
    }

    private func snappedBoundary(_ proposed: Double, excluding ids: Set<UUID>) -> Double {
        let frameTime = quantized(proposed)
        guard snappingEnabled else { snapGuideTime = nil; return frameTime }
        let threshold = Double(snapDistance / pixelsPerSecond)
        let candidates = snapCandidates(excluding: ids)
        guard let nearest = candidates.min(by: { abs($0 - frameTime) < abs($1 - frameTime) }),
              abs(nearest - frameTime) <= threshold else {
            snapGuideTime = nil
            return frameTime
        }
        snapGuideTime = nearest
        return quantized(nearest)
    }

    private func snappedMoveDelta(
        initial: [UUID: TimelineClip],
        ids: Set<UUID>,
        anchorKind: MediaKind,
        trackDelta: Int,
        ignoring ignoredIDs: Set<UUID> = [],
        proposedDelta: Double
    ) -> Double {
        let activeInitial = initial.filter { !ignoredIDs.contains($0.key) }
        guard let earliest = initial.values.map(\.timelineStart).min(), !activeInitial.isEmpty else { return 0 }
        var delta = proposedDelta
        delta = max(delta, -earliest)
        delta = quantized(earliest + delta) - earliest
        guard snappingEnabled else { snapGuideTime = nil; return delta }

        let movingEdges = activeInitial.values.flatMap { [$0.timelineStart, $0.timelineStart + clipDuration($0)] }
        let threshold = Double(snapDistance / pixelsPerSecond)
        func bestSnap(in candidates: [Double]) -> (adjustment: Double, target: Double)? {
            var best: (adjustment: Double, target: Double)?
            for edge in movingEdges {
                for candidate in candidates {
                    let adjustment = candidate - (edge + delta)
                    guard abs(adjustment) <= threshold else { continue }
                    if best == nil || abs(adjustment) < abs(best!.adjustment) {
                        best = (adjustment, candidate)
                    }
                }
            }
            return best
        }

        // Prefer the edge of a clip on the actual destination lane. A nearby
        // clip on V2 must not pull a V1 join away from the clip being combined.
        var laneCandidates = [0.0, playheadTime]
        for stationary in clips where !ids.contains(stationary.id) {
            let sharesDestinationLane = activeInitial.values.contains { moving in
                let destinationTrack = moving.kind == anchorKind ? max(0, moving.track + trackDelta) : moving.track
                return moving.kind == stationary.kind && destinationTrack == stationary.track
            }
            if sharesDestinationLane {
                laneCandidates.append(stationary.timelineStart)
                laneCandidates.append(stationary.timelineStart + clipDuration(stationary))
            }
        }
        let best = bestSnap(in: laneCandidates) ?? bestSnap(in: snapCandidates(excluding: ids))
        if let best {
            snapGuideTime = best.target
            return max(-earliest, delta + best.adjustment)
        }
        snapGuideTime = nil
        return delta
    }

    /// Keeps the chosen destination lane and settles an occupied drop into the
    /// nearest legal gap. This lets V2 clips move onto V1 beside existing clips
    /// instead of silently cancelling the lane change.
    private func resolvedMoveDelta(
        initial: [UUID: TimelineClip],
        ids: Set<UUID>,
        anchorKind: MediaKind,
        trackDelta: Int,
        ignoring ignoredIDs: Set<UUID> = [],
        proposedDelta: Double
    ) -> Double {
        let moving = initial.filter { !ignoredIDs.contains($0.key) }.values.map { clip in
            TimelineLaneInterval(
                kind: clip.kind,
                track: clip.kind == anchorKind ? max(0, clip.track + trackDelta) : clip.track,
                start: clip.timelineStart,
                duration: clipDuration(clip)
            )
        }
        let stationary = clips.filter { !ids.contains($0.id) }.map { clip in
            TimelineLaneInterval(kind: clip.kind, track: clip.track, start: clip.timelineStart, duration: clipDuration(clip))
        }
        let resolved = TimelineLanePlacement.nearestDelta(
            moving: moving,
            stationary: stationary,
            proposedDelta: proposedDelta
        )

        if abs(resolved - proposedDelta) > 0.000_001 {
            for item in moving {
                let start = TimelineLanePlacement.roundedFrame(item.start + resolved)
                let end = start + max(1 / frameRate, item.duration)
                for obstacle in stationary where obstacle.kind == item.kind && obstacle.track == item.track {
                    let obstacleEnd = obstacle.start + max(1 / frameRate, obstacle.duration)
                    if abs(start - obstacleEnd) < 0.5 / frameRate {
                        snapGuideTime = obstacleEnd
                        return resolved
                    }
                    if abs(end - obstacle.start) < 0.5 / frameRate {
                        snapGuideTime = obstacle.start
                        return resolved
                    }
                }
            }
        }
        return resolved
    }

    /// When a linked video is deliberately moved to another video layer, its
    /// sound follows in time but may need A2/A3 so an occupied A1 does not pull
    /// the whole picture away from the requested overlay position.
    private func routedLinkedAudioTracks(
        initial: [UUID: TimelineClip],
        selectedIDs: Set<UUID>,
        routedIDs: Set<UUID>,
        timeDelta: Double
    ) -> [UUID: Int] {
        guard !routedIDs.isEmpty else { return [:] }
        var occupied = clips.filter { !selectedIDs.contains($0.id) }.map { clip in
            TimelineLaneInterval(kind: clip.kind, track: clip.track, start: clip.timelineStart, duration: clipDuration(clip))
        }
        for clip in initial.values where clip.kind == .audio && !routedIDs.contains(clip.id) {
            occupied.append(TimelineLaneInterval(
                kind: .audio,
                track: clip.track,
                start: TimelineLanePlacement.roundedFrame(clip.timelineStart + timeDelta),
                duration: clipDuration(clip)
            ))
        }

        let routed = initial.values.filter { routedIDs.contains($0.id) }.sorted {
            if abs($0.timelineStart - $1.timelineStart) > 0.000_001 { return $0.timelineStart < $1.timelineStart }
            return $0.id.uuidString < $1.id.uuidString
        }
        var result: [UUID: Int] = [:]
        for clip in routed {
            let start = TimelineLanePlacement.roundedFrame(clip.timelineStart + timeDelta)
            let highest = occupied.filter { $0.kind == .audio }.map(\.track).max() ?? -1
            var candidates = [clip.track]
            candidates.append(contentsOf: 0...max(0, highest + 1))
            var chosen = max(0, highest + 1)
            for track in candidates where track >= 0 {
                let item = TimelineLaneInterval(kind: .audio, track: track, start: start, duration: clipDuration(clip))
                if TimelineLanePlacement.isAvailable([item], among: occupied, delta: 0) {
                    chosen = track
                    break
                }
            }
            result[clip.id] = chosen
            occupied.append(TimelineLaneInterval(kind: .audio, track: chosen, start: start, duration: clipDuration(clip)))
        }
        return result
    }

    // MARK: - Pointer interaction

    fileprivate func canvasMouseDown(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = canvasView.convert(event.locationInWindow, from: nil)

        if let hit = clipHit(at: point) {
            if event.clickCount >= 2, let sceneID = hit.clip.sceneID {
                controller?.openSceneClip(sceneID: sceneID)
                return
            }
            if bladeMode {
                let cutTime = quantized(time(atX: point.x))
                updatePlayhead(cutTime, notifyController: true)
                _ = controller?.cutTimelineClips(
                    [hit.clip.id],
                    at: cutTime,
                    includeLinked: selectsLinkedPairs && !event.modifierFlags.contains(.option)
                )
                return
            }

            let solo = event.modifierFlags.contains(.option)
            let clickedComponent = linkedComponent(containing: hit.clip, solo: solo)
            let nextSelection = selectionForClick(hit.clip, event: event)
            publishSelection(nextSelection, primary: nextSelection.contains(hit.clip.id) ? hit.clip.id : nextSelection.first)
            guard nextSelection.contains(hit.clip.id) else { return }

            if let edge = trimEdge(at: point, clip: hit.clip) {
                let trimIDs = linkedComponent(containing: hit.clip, solo: solo)
                if trimIDs != selectedIDs { publishSelection(trimIDs, primary: hit.clip.id) }
                let initial = Dictionary(uniqueKeysWithValues: clips.filter { trimIDs.contains($0.id) }.map { ($0.id, $0) })
                trimState = TrimState(origin: point, initial: initial, ids: trimIDs, primaryID: hit.clip.id, edge: edge)
                lastDragLocationInWindow = event.locationInWindow
                return
            }

            let initial = Dictionary(uniqueKeysWithValues: clips.filter { nextSelection.contains($0.id) }.map { ($0.id, $0) })
            moveState = MoveState(
                origin: point,
                initial: initial,
                ids: nextSelection,
                anchorID: hit.clip.id,
                anchorKind: hit.clip.kind,
                anchorTrack: hit.clip.track,
                // Preserve a deliberate multi-selection if the pointer moves.
                // A normal click-release collapses it to the clicked linked
                // component, so an earlier Add All selection cannot trap the
                // user into moving every imported clip forever.
                clickSelection: !event.modifierFlags.contains(.command) && nextSelection != clickedComponent
                    ? clickedComponent
                    : nil
            )
            lockedTrackCounts = (cachedVideoTrackCount, cachedAudioTrackCount)
            lastDragLocationInWindow = event.locationInWindow
            return
        }

        // Empty track space belongs to selection, never seeking: a click clears
        // selection and a drag creates a marquee. Seeking is confined to the
        // pinned ruler so a selection attempt cannot unexpectedly pause video.
        marqueeState = MarqueeState(
            origin: point,
            originalSelection: selectedIDs,
            additive: event.modifierFlags.contains(.command),
            solo: event.modifierFlags.contains(.option)
        )
        lastDragLocationInWindow = event.locationInWindow
    }

    fileprivate func canvasMouseDragged(_ event: NSEvent) {
        lastDragLocationInWindow = event.locationInWindow
        let point = canvasView.convert(event.locationInWindow, from: nil)
        if moveState != nil {
            updateMove(to: point)
        } else if trimState != nil {
            updateTrim(to: point)
        } else if marqueeState != nil {
            updateMarquee(to: point)
        }
        if moveState != nil || trimState != nil || marqueeState != nil { beginAutoScrollIfNeeded() }
    }

    fileprivate func canvasMouseUp(_ event: NSEvent) {
        stopAutoScroll()
        let move = moveState
        let trim = trimState
        let marquee = marqueeState
        let finalLayout = (move?.changed == true || trim?.changed == true) ? mergedLayout() : nil

        if let state = move, state.changed, let finalLayout {
            // Keep the final live geometry installed until the controller's
            // committed snapshot arrives. Clearing it first draws one frame of
            // the old layout and makes an edge join visibly snap backwards.
            finishTransientInteraction(preservingOverrides: true)
            controller?.commitTimelineLayout(finalLayout, selected: state.ids, primary: state.anchorID)
            if controller == nil { finishTransientInteraction() }
            return
        }
        if let state = trim, state.changed, let finalLayout {
            finishTransientInteraction(preservingOverrides: true)
            controller?.commitTimelineEdit(finalLayout, selected: state.ids, primary: state.primaryID, action: "Trim Clip")
            if controller == nil { finishTransientInteraction() }
            return
        }
        finishTransientInteraction()
        if let state = move, let clickSelection = state.clickSelection {
            publishSelection(clickSelection, primary: state.anchorID)
            return
        }
        if let state = marquee {
            if state.dragged {
                let primary = clips.first(where: { selectedIDs.contains($0.id) })?.id
                controller?.selectTimelineClips(selectedIDs, primary: primary)
            } else if !state.additive {
                publishSelection([], primary: nil)
            }
        }
    }

    private func updateMove(to point: NSPoint) {
        guard var state = moveState,
              state.initial[state.anchorID] != nil else { return }
        let dx = point.x - state.origin.x
        let dy = point.y - state.origin.y
        guard state.changed || abs(dx) >= 2 || abs(dy) >= 2 else { return }
        state.changed = true

        let rawDelta = Double(dx / pixelsPerSecond)
        let destinationTrack = compatibleTrack(at: point, kind: state.anchorKind)
        let requestedTrackDelta = destinationTrack - state.anchorTrack
        let lowestTrack = state.initial.values.filter { $0.kind == state.anchorKind }.map(\.track).min() ?? 0
        let trackDelta = max(-lowestTrack, requestedTrackDelta)
        let movedVideoGroups = Set(state.initial.values.compactMap { clip in
            clip.kind == .video ? clip.groupID : nil
        })
        let routedAudioIDs: Set<UUID> = state.anchorKind == .video && trackDelta != 0
            ? Set(state.initial.values.filter { clip in
                clip.kind == .audio && clip.groupID.map(movedVideoGroups.contains) == true
            }.map(\.id))
            : []
        let snappedDelta = snappedMoveDelta(
            initial: state.initial,
            ids: state.ids,
            anchorKind: state.anchorKind,
            trackDelta: trackDelta,
            ignoring: routedAudioIDs,
            proposedDelta: rawDelta
        )
        let delta = resolvedMoveDelta(
            initial: state.initial,
            ids: state.ids,
            anchorKind: state.anchorKind,
            trackDelta: trackDelta,
            ignoring: routedAudioIDs,
            proposedDelta: snappedDelta
        )
        let routedAudioTracks = routedLinkedAudioTracks(
            initial: state.initial,
            selectedIDs: state.ids,
            routedIDs: routedAudioIDs,
            timeDelta: delta
        )

        var overrides = editOverrides
        for id in state.ids {
            guard var updated = state.initial[id] else { continue }
            let original = updated
            updated.timelineStart = max(0, quantized(original.timelineStart + delta))
            if let routedTrack = routedAudioTracks[id] {
                updated.track = routedTrack
            } else if original.kind == state.anchorKind {
                updated.track = max(0, original.track + trackDelta)
            }
            overrides[id] = updated
        }
        replaceEditOverrides(overrides)
        moveState = state
    }

    private func updateTrim(to point: NSPoint) {
        guard var state = trimState, let primary = state.initial[state.primaryID] else { return }
        let dx = Double((point.x - state.origin.x) / pixelsPerSecond)
        guard state.changed || abs(point.x - state.origin.x) >= 2 else { return }
        state.changed = true

        let frame = 1.0 / frameRate
        let primaryDuration = clipDuration(primary)
        let proposedBoundary: Double
        switch state.edge {
        case .leading: proposedBoundary = primary.timelineStart + dx
        case .trailing: proposedBoundary = primary.timelineStart + primaryDuration + dx
        }
        let boundary = snappedBoundary(proposedBoundary, excluding: state.ids)
        var commonDelta: Double
        switch state.edge {
        case .leading: commonDelta = boundary - primary.timelineStart
        case .trailing: commonDelta = boundary - (primary.timelineStart + primaryDuration)
        }

        for original in state.initial.values {
            switch state.edge {
            case .leading:
                commonDelta = max(commonDelta, -original.inPoint)
                // Every linked component must remain on or after sequence zero.
                // Applying max(0, ...) later would give different deltas to an
                // offset picture/sound pair and silently destroy their sync.
                commonDelta = max(commonDelta, -original.timelineStart)
                commonDelta = min(commonDelta, clipDuration(original) - frame)
            case .trailing:
                commonDelta = max(commonDelta, frame - clipDuration(original))
                let effectiveOut = original.outPoint > original.inPoint
                    ? original.outPoint
                    : original.inPoint + clipDuration(original)
                let sourceDuration = sourceDurations[original.id] ?? sourceDurations[original.assetID] ?? effectiveOut
                if sourceDuration > 0 { commonDelta = min(commonDelta, sourceDuration - effectiveOut) }
            }
        }

        // Extending a clip may touch its neighbour, but it must not grow over
        // that neighbour and hide it on the same lane.
        let stationary = clips.filter { !state.ids.contains($0.id) }
        if state.edge == .leading, commonDelta < 0 {
            for original in state.initial.values {
                for neighbour in stationary where neighbour.kind == original.kind && neighbour.track == original.track {
                    let neighbourEnd = neighbour.timelineStart + clipDuration(neighbour)
                    guard neighbourEnd <= original.timelineStart + 0.000_001 else { continue }
                    let earliestStart = ceil(neighbourEnd * frameRate) / frameRate
                    if original.timelineStart + commonDelta < earliestStart {
                        commonDelta = max(commonDelta, earliestStart - original.timelineStart)
                        snapGuideTime = neighbourEnd
                    }
                }
            }
        } else if state.edge == .trailing, commonDelta > 0 {
            for original in state.initial.values {
                let originalEnd = original.timelineStart + clipDuration(original)
                for neighbour in stationary where neighbour.kind == original.kind && neighbour.track == original.track {
                    guard neighbour.timelineStart >= originalEnd - 0.000_001 else { continue }
                    let latestEnd = floor(neighbour.timelineStart * frameRate) / frameRate
                    if originalEnd + commonDelta > latestEnd {
                        commonDelta = min(commonDelta, latestEnd - originalEnd)
                        snapGuideTime = neighbour.timelineStart
                    }
                }
            }
        }

        var overrides = editOverrides
        for id in state.ids {
            guard var updated = state.initial[id] else { continue }
            let original = updated
            switch state.edge {
            case .leading:
                let newStart = quantized(original.timelineStart + commonDelta)
                let applied = newStart - original.timelineStart
                updated.timelineStart = max(0, newStart)
                updated.inPoint = max(0, quantized(original.inPoint + applied))
                // Keyframes are clip-local. Rebase their local clock by the
                // exact trim delta so each keyframe stays at the same sequence
                // time and attached to the same source picture/sound. Frames
                // outside the visible trim remain stored for a later extension.
                updated.animation = original.animation
                for channelIndex in updated.animation.channels.indices {
                    for keyframeIndex in updated.animation.channels[channelIndex].keyframes.indices {
                        updated.animation.channels[channelIndex].keyframes[keyframeIndex].time -= applied
                    }
                }
            case .trailing:
                let effectiveOut = original.outPoint > original.inPoint
                    ? original.outPoint
                    : original.inPoint + clipDuration(original)
                updated.outPoint = max(original.inPoint + frame, quantized(effectiveOut + commonDelta))
            }
            overrides[id] = updated
        }
        replaceEditOverrides(overrides)
        trimState = state
    }

    private func replaceEditOverrides(_ next: [UUID: TimelineClip]) {
        editOverrides = next
        // Track counts are locked for a vertical move and trims never change a
        // track. Only the width can need to grow during the live gesture.
        updateDocumentGeometry()
        canvasView.needsDisplay = true
        canvasView.window?.invalidateCursorRects(for: canvasView)
    }

    private func mergedLayout() -> [TimelineClip] {
        clips.map { editOverrides[$0.id] ?? $0 }
    }

    private func finishTransientInteraction(preservingOverrides: Bool = false) {
        if !preservingOverrides { editOverrides.removeAll(keepingCapacity: true) }
        moveState = nil
        trimState = nil
        marqueeState = nil
        lockedTrackCounts = nil
        lastDragLocationInWindow = nil
        snapGuideTime = nil
        canvasView.marqueeRect = nil
        if !preservingOverrides {
            updateDocumentGeometry()
            invalidateTimeline()
        }
    }

    @discardableResult
    private func cancelActiveInteraction() -> Bool {
        guard moveState != nil || trimState != nil || marqueeState != nil else { return false }
        if let marqueeState { selectedIDs = marqueeState.originalSelection }
        stopAutoScroll()
        finishTransientInteraction()
        return true
    }

    private func updateMarquee(to point: NSPoint) {
        guard var state = marqueeState else { return }
        let rect = NSRect(
            x: min(state.origin.x, point.x),
            y: min(state.origin.y, point.y),
            width: abs(point.x - state.origin.x),
            height: abs(point.y - state.origin.y)
        )
        guard state.dragged || rect.width >= 3 || rect.height >= 3 else { return }
        state.dragged = true
        canvasView.marqueeRect = rect

        var hits = Set(clips.compactMap { base -> UUID? in
            let clip = displayed(base)
            return clipRect(clip).intersects(rect) ? clip.id : nil
        })
        if selectsLinkedPairs && !state.solo {
            let groups = Set(clips.filter { hits.contains($0.id) }.compactMap(\.groupID))
            hits.formUnion(clips.filter { $0.groupID.map(groups.contains) ?? false }.map(\.id))
        }
        selectedIDs = state.additive ? state.originalSelection.union(hits) : hits
        marqueeState = state
        canvasView.needsDisplay = true
    }

    // MARK: - Ruler seeking

    fileprivate func rulerMouseDown(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        isSeeking = true
        lastDragLocationInWindow = event.locationInWindow
        seekFromRuler(event)
    }

    fileprivate func rulerMouseDragged(_ event: NSEvent) {
        guard isSeeking else { return }
        lastDragLocationInWindow = event.locationInWindow
        seekFromRuler(event)
        beginAutoScrollIfNeeded()
    }

    fileprivate func rulerMouseUp(_ event: NSEvent) {
        guard isSeeking else { return }
        seekFromRuler(event)
        isSeeking = false
        lastDragLocationInWindow = nil
        stopAutoScroll()
    }

    private func seekFromRuler(_ event: NSEvent) {
        let point = rulerView.convert(event.locationInWindow, from: nil)
        updatePlayhead(quantized(time(atX: point.x)), notifyController: true)
    }

    private func updatePlayhead(_ requestedTime: Double, notifyController: Bool) {
        let oldX = xPosition(for: playheadTime)
        playheadTime = max(0, requestedTime)
        let newX = xPosition(for: playheadTime)
        canvasView.setNeedsDisplay(NSRect(x: oldX - 8, y: 0, width: 16, height: canvasView.bounds.height))
        canvasView.setNeedsDisplay(NSRect(x: newX - 8, y: 0, width: 16, height: canvasView.bounds.height))
        rulerView.setNeedsDisplay(NSRect(x: oldX - 8, y: 0, width: 16, height: rulerView.bounds.height))
        rulerView.setNeedsDisplay(NSRect(x: newX - 8, y: 0, width: 16, height: rulerView.bounds.height))
        if newX + trailingCanvasPadding > canvasView.frame.width { updateDocumentGeometry() }
        if notifyController { controller?.timelinePlayheadSelected(to: playheadTime) }
    }

    // MARK: - Zoom gestures and keyboard routing

    fileprivate func zoom(with event: NSEvent, in view: NSView, magnification: CGFloat? = nil) {
        let point = view.convert(event.locationInWindow, from: nil)
        let anchor = time(atX: point.x)
        let factor: CGFloat
        if let magnification {
            factor = max(0.2, 1 + magnification)
        } else {
            let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.035 : 0.12
            let exponent = min(5, max(-5, event.scrollingDeltaY * sensitivity))
            factor = pow(1.35, exponent)
        }
        setZoom(pixelsPerSecond * factor, anchorTime: anchor)
    }

    fileprivate func forwardScrollWheel(_ event: NSEvent, fromTrackHeaders: Bool = false) {
        if fromTrackHeaders, event.modifierFlags.contains(.option) {
            let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.035 : 0.12
            let exponent = min(5, max(-5, event.scrollingDeltaY * sensitivity))
            setZoom(pixelsPerSecond * pow(1.35, exponent), anchorTime: playheadTime)
            return
        }
        // Sending the original event to the real two-axis scroll view retains
        // AppKit's precise-delta, momentum and natural-direction behaviour.
        canvasScrollView.scrollWheel(with: event)
        synchronizePinnedRegions()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, cancelActiveInteraction() { return }
        if event.keyCode == 51 || event.keyCode == 117 {
            controller?.deleteSelectedTimelineClips()
            return
        }
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            super.keyDown(with: event)
            return
        }
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch character {
        case "v": controller?.timelineSelectToolRequested()
        case "c": controller?.timelineBladeToolRequested()
        case "s": controller?.timelineSnappingRequested()
        case " ": controller?.timelinePlaybackRequested()
        case "+", "=": setZoom(pixelsPerSecond * 1.3, anchorTime: playheadTime)
        case "-", "_": setZoom(pixelsPerSecond / 1.3, anchorTime: playheadTime)
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Drag and drop

    fileprivate func handleDraggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let board = sender.draggingPasteboard
        externalFileDragURLs.removeAll(keepingCapacity: true)
        if board.string(forType: .netVistaAsset) != nil { return .copy }
        externalFileDragURLs = draggedFileURLs(from: board)
        return externalFileDragURLs.isEmpty ? [] : .copy
    }

    fileprivate func handleDraggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        autoScroll(aroundWindowPoint: sender.draggingLocation)
        let point = canvasView.convert(sender.draggingLocation, from: nil)
        let target = resolvedDropTarget(pasteboard: sender.draggingPasteboard, at: point)
        let requested = snappedBoundary(time(atX: point.x), excluding: [])
        let previewStart: Double
        if let indexText = sender.draggingPasteboard.string(forType: .netVistaAsset), let index = Int(indexText) {
            previewStart = controller?.resolvedDropStart(forAssetAt: index, requested: requested, track: target.track) ?? requested
        } else {
            previewStart = requested
        }
        dropGuide = (previewStart, target.kind, target.track)
        canvasView.needsDisplay = true
        return .copy
    }

    fileprivate func handleDraggingExited() {
        externalFileDragURLs.removeAll(keepingCapacity: true)
        dropGuide = nil
        snapGuideTime = nil
        canvasView.needsDisplay = true
    }

    fileprivate func handlePerformDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        let point = canvasView.convert(sender.draggingLocation, from: nil)
        let start = snappedBoundary(time(atX: point.x), excluding: [])
        defer {
            externalFileDragURLs.removeAll(keepingCapacity: true)
            dropGuide = nil
            snapGuideTime = nil
            canvasView.needsDisplay = true
        }

        if let indexText = board.string(forType: .netVistaAsset), let index = Int(indexText) {
            let kind = controller?.mediaKind(at: index) ?? trackTarget(at: point).kind
            controller?.addAsset(at: index, at: start, track: compatibleTrack(at: point, kind: kind))
            return true
        }

        let urls = externalFileDragURLs.isEmpty ? draggedFileURLs(from: board) : externalFileDragURLs
        guard !urls.isEmpty else { return false }
        let target = resolvedDropTarget(pasteboard: board, at: point)
        controller?.addMedia(urls, addToTimeline: true, at: start, track: target.track, dropKind: target.kind)
        return true
    }

    private func resolvedDropTarget(pasteboard: NSPasteboard, at point: NSPoint) -> (kind: MediaKind, track: Int) {
        if let indexText = pasteboard.string(forType: .netVistaAsset),
           let index = Int(indexText), let kind = controller?.mediaKind(at: index) {
            return (kind, compatibleTrack(at: point, kind: kind))
        }
        if let url = (externalFileDragURLs.first ?? draggedFileURLs(from: pasteboard).first) {
            let audioExtensions: Set<String> = ["aac", "aif", "aiff", "caf", "flac", "m4a", "mp3", "ogg", "wav"]
            let kind: MediaKind = audioExtensions.contains(url.pathExtension.lowercased()) ? .audio : .video
            return (kind, compatibleTrack(at: point, kind: kind))
        }
        return trackTarget(at: point)
    }

    private func draggedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        let knownExtensions: Set<String> = [
            "3g2", "3gp", "aac", "aif", "aiff", "asf", "avi", "caf", "flac", "m2ts", "m4a", "m4v",
            "mkv", "mov", "mp3", "mp4", "mpeg", "mpg", "mts", "ogg", "ogv", "wav", "webm", "wmv"
        ]
        return urls.filter { url in
            guard url.isFileURL else { return false }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
            guard values?.isDirectory != true else { return false }
            if let type = values?.contentType,
               type.conforms(to: .movie) || type.conforms(to: .audio) || type.conforms(to: .audiovisualContent) {
                return true
            }
            return knownExtensions.contains(url.pathExtension.lowercased())
        }
    }

    // MARK: - Autoscroll

    private func beginAutoScrollIfNeeded() {
        guard autoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.autoScrollTick() }
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    private func autoScrollTick() {
        guard let point = lastDragLocationInWindow else { return }
        let didScroll = autoScroll(aroundWindowPoint: point)
        guard didScroll else { return }
        let canvasPoint = canvasView.convert(point, from: nil)
        if moveState != nil { updateMove(to: canvasPoint) }
        else if trimState != nil { updateTrim(to: canvasPoint) }
        else if marqueeState != nil { updateMarquee(to: canvasPoint) }
        else if isSeeking {
            let rulerPoint = rulerView.convert(point, from: nil)
            updatePlayhead(quantized(time(atX: rulerPoint.x)), notifyController: true)
        }
    }

    @discardableResult
    private func autoScroll(aroundWindowPoint windowPoint: NSPoint) -> Bool {
        let viewportPoint = canvasScrollView.contentView.convert(windowPoint, from: nil)
        let bounds = canvasScrollView.contentView.bounds
        let local = NSPoint(x: viewportPoint.x - bounds.minX, y: viewportPoint.y - bounds.minY)
        let edge: CGFloat = 34
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if local.x < edge { dx = -max(4, (edge - local.x) * 0.32) }
        else if local.x > bounds.width - edge { dx = max(4, (local.x - (bounds.width - edge)) * 0.32) }
        // A ruler drag only seeks in time. It must never shift the user's
        // vertical track position merely because the pointer is above canvas.
        if !isSeeking {
            if local.y < edge { dy = -max(3, (edge - local.y) * 0.24) }
            else if local.y > bounds.height - edge { dy = max(3, (local.y - (bounds.height - edge)) * 0.24) }
        }
        guard dx != 0 || dy != 0 else { return false }
        let old = bounds.origin
        scrollCanvas(to: NSPoint(x: old.x + dx, y: old.y + dy))
        return canvasScrollView.contentView.bounds.origin != old
    }

    // MARK: - Drawing support

    fileprivate struct TickSpacing {
        let major: Double
        let minor: Double
    }

    fileprivate func tickSpacing() -> TickSpacing {
        let candidates: [Double] = [
            1.0 / 30.0, 1.0 / 15.0, 0.1, 0.2, 0.5,
            1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1_200,
            3_600, 7_200, 18_000, 36_000, 86_400
        ]
        let desiredSeconds = 92.0 / Double(pixelsPerSecond)
        let major = candidates.first(where: { $0 >= desiredSeconds }) ?? candidates.last!
        let rawMinor = major / 5
        let minor = max(1.0 / frameRate, rawMinor)
        return TickSpacing(major: major, minor: minor)
    }

    fileprivate func timecode(_ time: Double, compact: Bool = false) -> String {
        let totalFrames = max(0, Int((time * frameRate).rounded()))
        let frames = totalFrames % Int(frameRate)
        let totalSeconds = totalFrames / Int(frameRate)
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3_600
        if compact && hours == 0 { return String(format: "%02d:%02d:%02d", minutes, seconds, frames) }
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }

    fileprivate func drawCanvas(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.085, alpha: 1).setFill()
        dirtyRect.fill()

        for row in 0..<videoTrackCount {
            let y = CGFloat(row) * trackHeight
            let rect = NSRect(x: dirtyRect.minX, y: y, width: dirtyRect.width, height: trackHeight)
            guard rect.intersects(dirtyRect) else { continue }
            (row.isMultiple(of: 2) ? NSColor(calibratedWhite: 0.105, alpha: 1) : NSColor(calibratedWhite: 0.095, alpha: 1)).setFill()
            rect.intersection(dirtyRect).fill()
        }
        NSColor(calibratedWhite: 0.045, alpha: 1).setFill()
        NSRect(x: dirtyRect.minX, y: videoSectionHeight, width: dirtyRect.width, height: sectionGap).intersection(dirtyRect).fill()
        for row in 0..<audioTrackCount {
            let y = audioSectionOrigin + CGFloat(row) * trackHeight
            let rect = NSRect(x: dirtyRect.minX, y: y, width: dirtyRect.width, height: trackHeight)
            guard rect.intersects(dirtyRect) else { continue }
            (row.isMultiple(of: 2) ? NSColor(calibratedRed: 0.075, green: 0.115, blue: 0.10, alpha: 1) : NSColor(calibratedRed: 0.07, green: 0.105, blue: 0.092, alpha: 1)).setFill()
            rect.intersection(dirtyRect).fill()
        }

        drawGrid(in: dirtyRect)
        for base in clips {
            let clip = displayed(base)
            let rect = clipRect(clip)
            guard rect.width > 0, rect.intersects(dirtyRect) else { continue }
            drawClip(clip, rect: rect, dirtyRect: dirtyRect)
        }
        if let guide = dropGuide { drawDropGuide(guide) }
        if let guide = snapGuideTime { drawSnapGuide(at: guide) }
        if let marquee = canvasView.marqueeRect { drawMarquee(marquee) }
        drawPlayhead(in: canvasView.bounds)
    }

    private func drawGrid(in dirtyRect: NSRect) {
        let spacing = tickSpacing()
        let startTime = floor(time(atX: dirtyRect.minX) / spacing.minor) * spacing.minor
        let endTime = time(atX: dirtyRect.maxX) + spacing.minor
        var time = startTime
        while time <= endTime {
            let majorIndex = (time / spacing.major).rounded()
            let isMajor = abs(time - majorIndex * spacing.major) < spacing.minor * 0.12
            let color = isMajor ? NSColor(white: 0.38, alpha: 0.20) : NSColor(white: 0.45, alpha: 0.07)
            color.setFill()
            NSRect(x: xPosition(for: time), y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
            time += spacing.minor
        }

        NSColor(white: 1, alpha: 0.055).setFill()
        for row in 0...videoTrackCount {
            let y = CGFloat(row) * trackHeight
            if y >= dirtyRect.minY, y <= dirtyRect.maxY { NSRect(x: dirtyRect.minX, y: y, width: dirtyRect.width, height: 1).fill() }
        }
        for row in 0...audioTrackCount {
            let y = audioSectionOrigin + CGFloat(row) * trackHeight
            if y >= dirtyRect.minY, y <= dirtyRect.maxY { NSRect(x: dirtyRect.minX, y: y, width: dirtyRect.width, height: 1).fill() }
        }
    }

    private func drawClip(_ clip: TimelineClip, rect: NSRect, dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: min(5, rect.width * 0.2), yRadius: 5).addClip()
        let base: NSColor
        if clip.kind == .audio {
            base = NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.36, alpha: 1)
        } else if clip.sceneID != nil {
            base = NSColor(calibratedRed: 0.43, green: 0.25, blue: 0.68, alpha: 1)
        } else {
            let brightness = CGFloat(min(0.2, max(-0.2, clip.brightness)))
            base = NSColor(calibratedRed: 0.16 + brightness, green: 0.35 + brightness, blue: 0.56 + brightness, alpha: 1)
        }
        base.setFill()
        rect.fill()

        if clip.kind == .audio {
            drawWaveform(for: clip, in: rect, dirtyRect: dirtyRect)
        } else {
            let band = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(7, rect.height))
            NSColor(white: 1, alpha: 0.14).setFill(); band.fill()
            let footer = NSRect(x: rect.minX, y: rect.maxY - min(8, rect.height), width: rect.width, height: min(8, rect.height))
            NSColor(white: 0, alpha: 0.13).setFill(); footer.fill()
        }

        if selectedIDs.contains(clip.id) {
            NSColor(white: 1, alpha: 0.16).setFill(); rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: min(5, rect.width * 0.2), yRadius: 5)
        outline.lineWidth = selectedIDs.contains(clip.id) ? 2 : 1
        (selectedIDs.contains(clip.id) ? NSColor.white : NSColor(white: 0, alpha: 0.58)).setStroke()
        outline.stroke()

        if selectedIDs.contains(clip.id), rect.width >= 8 {
            NSColor(white: 1, alpha: 0.82).setFill()
            NSRect(x: rect.minX + 2, y: rect.minY + 5, width: 2, height: max(1, rect.height - 10)).fill()
            NSRect(x: rect.maxX - 4, y: rect.minY + 5, width: 2, height: max(1, rect.height - 10)).fill()
        }

        guard rect.width >= 24 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect.insetBy(dx: 6, dy: 4)).addClip()
        let icon = clip.kind == .audio ? "♫" : (clip.sceneID == nil ? "▣" : "◇")
        let title = "\(icon)  \(clip.name)"
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.55); shadow.shadowBlurRadius = 1; shadow.shadowOffset = NSSize(width: 0, height: 1)
        title.draw(
            at: NSPoint(x: rect.minX + 7, y: rect.minY + 9),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
                .shadow: shadow
            ]
        )
        drawKeyframes(for: clip, rect: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawWaveform(for clip: TimelineClip, in rect: NSRect, dirtyRect: NSRect) {
        let visible = rect.intersection(dirtyRect)
        guard visible.width > 0, rect.height > 12 else { return }
        let seed = clip.name.utf8.reduce(17) { (($0 &* 31) &+ Int($1)) & 0x7fff }
        let centre = rect.midY + 4
        NSColor(white: 1, alpha: 0.46).setStroke()
        let path = NSBezierPath(); path.lineWidth = 1
        var x = floor(visible.minX / 3) * 3
        while x <= visible.maxX {
            let local = Int((x - rect.minX) / 3)
            let harmonic = abs(sin(Double(local + seed) * 0.57) * 0.62 + sin(Double(local + seed) * 0.13) * 0.38)
            let amplitude = CGFloat(harmonic) * max(2, rect.height * 0.32)
            path.move(to: NSPoint(x: x, y: centre - amplitude))
            path.line(to: NSPoint(x: x, y: centre + amplitude))
            x += 3
        }
        path.stroke()
    }

    private func drawKeyframes(for clip: TimelineClip, rect: NSRect) {
        guard clip.kind == .video, selectedIDs.contains(clip.id) else { return }
        let times = Set(clip.animation.channels.flatMap { $0.keyframes.map(\.time) })
        NSColor.systemOrange.setFill()
        for localTime in times where localTime >= 0 && localTime <= clipDuration(clip) {
            let x = xPosition(for: clip.timelineStart + localTime)
            let y = rect.maxY - 7
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: x, y: y - 4))
            diamond.line(to: NSPoint(x: x + 4, y: y))
            diamond.line(to: NSPoint(x: x, y: y + 4))
            diamond.line(to: NSPoint(x: x - 4, y: y))
            diamond.close(); diamond.fill()
        }
    }

    private func drawPlayhead(in rect: NSRect) {
        let x = xPosition(for: playheadTime)
        NSColor(calibratedRed: 1, green: 0.24, blue: 0.18, alpha: 0.96).setFill()
        NSRect(x: x - 1, y: rect.minY, width: 2, height: rect.height).fill()
    }

    private func drawSnapGuide(at time: Double) {
        let x = xPosition(for: time)
        NSColor.systemYellow.withAlphaComponent(0.92).setFill()
        NSRect(x: x - 0.5, y: 0, width: 1, height: canvasView.bounds.height).fill()
    }

    private func drawDropGuide(_ guide: (time: Double, kind: MediaKind, track: Int)) {
        let x = xPosition(for: guide.time)
        let y = trackY(kind: guide.kind, track: guide.track)
        let lane = NSRect(x: x, y: y + 5, width: max(90, pixelsPerSecond * 2), height: max(1, trackHeight - 10))
        NSColor.systemBlue.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: lane, xRadius: 5, yRadius: 5).fill()
        NSColor.systemBlue.setFill()
        NSRect(x: x - 1, y: y, width: 2, height: trackHeight).fill()
    }

    private func drawMarquee(_ rect: NSRect) {
        NSColor.systemBlue.withAlphaComponent(0.16).setFill(); rect.fill()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)); path.lineWidth = 1
        NSColor.systemBlue.withAlphaComponent(0.9).setStroke(); path.stroke()
    }

    fileprivate func drawRuler(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.075, alpha: 1).setFill(); dirtyRect.fill()
        let spacing = tickSpacing()
        let start = floor(time(atX: dirtyRect.minX) / spacing.minor) * spacing.minor
        let end = time(atX: dirtyRect.maxX) + spacing.minor
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.68, alpha: 1)]
        var time = start
        while time <= end {
            let majorIndex = (time / spacing.major).rounded()
            let isMajor = abs(time - majorIndex * spacing.major) < spacing.minor * 0.12
            let x = xPosition(for: time)
            let height: CGFloat = isMajor ? 13 : 6
            (isMajor ? NSColor(white: 0.72, alpha: 0.7) : NSColor(white: 0.65, alpha: 0.35)).setFill()
            NSRect(x: x, y: rulerView.bounds.height - height, width: 1, height: height).fill()
            if isMajor {
                timecode(time, compact: true).draw(at: NSPoint(x: x + 4, y: 6), withAttributes: attributes)
            }
            time += spacing.minor
        }
        NSColor(white: 1, alpha: 0.08).setFill()
        NSRect(x: dirtyRect.minX, y: rulerView.bounds.height - 1, width: dirtyRect.width, height: 1).fill()

        let x = xPosition(for: playheadTime)
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: x - 6, y: 0))
        marker.line(to: NSPoint(x: x + 6, y: 0))
        marker.line(to: NSPoint(x: x + 3, y: 9))
        marker.line(to: NSPoint(x: x, y: 12))
        marker.line(to: NSPoint(x: x - 3, y: 9))
        marker.close()
        NSColor(calibratedRed: 1, green: 0.24, blue: 0.18, alpha: 1).setFill(); marker.fill()
        NSRect(x: x - 1, y: 9, width: 2, height: rulerView.bounds.height - 9).fill()
    }

    fileprivate func drawHeaders(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill(); dirtyRect.fill()
        let shortAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.90, alpha: 1)
        ]
        let longAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1)
        ]

        for row in 0..<videoTrackCount {
            let track = videoTrackCount - 1 - row
            let y = CGFloat(row) * trackHeight
            let rect = NSRect(x: 0, y: y, width: headerView.bounds.width, height: trackHeight)
            guard rect.intersects(dirtyRect) else { continue }
            (row.isMultiple(of: 2) ? NSColor(calibratedWhite: 0.105, alpha: 1) : NSColor(calibratedWhite: 0.09, alpha: 1)).setFill(); rect.fill()
            "V\(track + 1)".draw(at: NSPoint(x: 13, y: y + trackHeight * 0.5 - 7), withAttributes: shortAttributes)
            "Video \(track + 1)".draw(at: NSPoint(x: 46, y: y + trackHeight * 0.5 - 6), withAttributes: longAttributes)
        }
        NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
        NSRect(x: 0, y: videoSectionHeight, width: headerView.bounds.width, height: sectionGap).fill()
        for row in 0..<audioTrackCount {
            let y = audioSectionOrigin + CGFloat(row) * trackHeight
            let rect = NSRect(x: 0, y: y, width: headerView.bounds.width, height: trackHeight)
            guard rect.intersects(dirtyRect) else { continue }
            (row.isMultiple(of: 2) ? NSColor(calibratedRed: 0.075, green: 0.115, blue: 0.10, alpha: 1) : NSColor(calibratedRed: 0.065, green: 0.098, blue: 0.087, alpha: 1)).setFill(); rect.fill()
            "A\(row + 1)".draw(at: NSPoint(x: 13, y: y + trackHeight * 0.5 - 7), withAttributes: shortAttributes)
            "Audio \(row + 1)".draw(at: NSPoint(x: 46, y: y + trackHeight * 0.5 - 6), withAttributes: longAttributes)
        }
        NSColor(white: 1, alpha: 0.07).setFill()
        for row in 0...videoTrackCount {
            NSRect(x: 0, y: CGFloat(row) * trackHeight, width: headerView.bounds.width, height: 1).fill()
        }
        for row in 0...audioTrackCount {
            NSRect(x: 0, y: audioSectionOrigin + CGFloat(row) * trackHeight, width: headerView.bounds.width, height: 1).fill()
        }
        NSColor(white: 1, alpha: 0.10).setFill()
        NSRect(x: headerView.bounds.width - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    fileprivate func resetCanvasCursorRects() {
        if bladeMode {
            canvasView.addCursorRect(canvasView.visibleRect, cursor: .crosshair)
            return
        }
        for base in clips {
            let clip = displayed(base)
            guard clipRect(clip).intersects(canvasView.visibleRect) else { continue }
            let rect = clipRect(clip)
            if rect.width >= 16 {
                let handleWidth = min(8, max(3, rect.width * 0.18))
                canvasView.addCursorRect(NSRect(x: rect.minX - 2, y: rect.minY, width: handleWidth + 2, height: rect.height), cursor: .resizeLeftRight)
                canvasView.addCursorRect(NSRect(x: rect.maxX - handleWidth, y: rect.minY, width: handleWidth + 2, height: rect.height), cursor: .resizeLeftRight)
                canvasView.addCursorRect(rect.insetBy(dx: handleWidth, dy: 0), cursor: .openHand)
            } else {
                canvasView.addCursorRect(hitRect(for: clip), cursor: .openHand)
            }
        }
    }

    private func invalidateTimeline() {
        canvasView.needsDisplay = true
        rulerView.needsDisplay = true
        headerView.needsDisplay = true
        canvasView.window?.invalidateCursorRects(for: canvasView)
    }

    private func updateToolTips() {
        guard canvasView.bounds != lastCanvasToolTipBounds ||
                rulerView.bounds != lastRulerToolTipBounds ||
                headerView.bounds != lastHeaderToolTipBounds else { return }
        lastCanvasToolTipBounds = canvasView.bounds
        lastRulerToolTipBounds = rulerView.bounds
        lastHeaderToolTipBounds = headerView.bounds
        canvasView.removeAllToolTips()
        rulerView.removeAllToolTips()
        headerView.removeAllToolTips()
        if !canvasView.bounds.isEmpty { canvasView.addToolTip(canvasView.bounds, owner: self, userData: nil) }
        if !rulerView.bounds.isEmpty { rulerView.addToolTip(rulerView.bounds, owner: self, userData: nil) }
        if !headerView.bounds.isEmpty { headerView.addToolTip(headerView.bounds, owner: self, userData: nil) }
    }
}

// MARK: - Tooltip content

extension ProfessionalTimelineView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        if view === rulerView { return "Click or drag to move the playhead. Pinch or Option-scroll to zoom around the pointer." }
        if view === headerView {
            let target = trackTarget(at: point)
            return target.kind == .video ? "Video \(target.track + 1)" : "Audio \(target.track + 1)"
        }
        if let hit = clipHit(at: point) {
            let start = timecode(hit.clip.timelineStart)
            let end = timecode(hit.clip.timelineStart + clipDuration(hit.clip))
            return "\(hit.clip.name)  •  \(start) – \(end)\nDrag the body to move. Drag an edge to trim. Option-click selects only this component."
        }
        return "Click empty space to clear selection, drag to marquee-select, or drop media here. Use the ruler to seek."
    }
}

// MARK: - Lightweight document views

private final class ProfessionalTimelineCanvasView: NSView {
    weak var owner: ProfessionalTimelineView?
    var marqueeRect: NSRect?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .netVistaAsset])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Timeline clips")
        setAccessibilityHelp("Drag clips to move them, drag their edges to trim, or drag empty space to select multiple clips.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) { owner?.drawCanvas(dirtyRect) }
    override func mouseDown(with event: NSEvent) { owner?.canvasMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { owner?.canvasMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { owner?.canvasMouseUp(event) }
    override func resetCursorRects() { owner?.resetCanvasCursorRects() }

    override func magnify(with event: NSEvent) { owner?.zoom(with: event, in: self, magnification: event.magnification) }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) { owner?.zoom(with: event, in: self) }
        else { super.scrollWheel(with: event) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { owner?.handleDraggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { owner?.handleDraggingUpdated(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { owner?.handleDraggingExited() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { owner?.handlePerformDragOperation(sender) ?? false }
}

private final class ProfessionalTimelineRulerView: NSView {
    weak var owner: ProfessionalTimelineView?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.ruler)
        setAccessibilityLabel("Timeline time ruler")
        setAccessibilityHelp("Click or drag to seek. Pinch or Option-scroll to zoom.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) { owner?.drawRuler(dirtyRect) }
    override func mouseDown(with event: NSEvent) { owner?.rulerMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { owner?.rulerMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { owner?.rulerMouseUp(event) }
    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .pointingHand) }
    override func magnify(with event: NSEvent) { owner?.zoom(with: event, in: self, magnification: event.magnification) }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) { owner?.zoom(with: event, in: self) }
        else { owner?.forwardScrollWheel(event) }
    }
}

private final class ProfessionalTimelineHeaderView: NSView {
    weak var owner: ProfessionalTimelineView?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Timeline track headers")
        setAccessibilityHelp("Track names remain visible while the timeline scrolls horizontally.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { owner?.drawHeaders(dirtyRect) }
    override func scrollWheel(with event: NSEvent) { owner?.forwardScrollWheel(event, fromTrackHeaders: true) }
}

private final class ProfessionalTimelineCornerView: NSView {
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Timeline 1")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.065, alpha: 1).setFill(); dirtyRect.fill()
        "TIMELINE 1".draw(
            at: NSPoint(x: 12, y: 10),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor(calibratedWhite: 0.73, alpha: 1),
                .kern: 0.6
            ]
        )
        NSColor(white: 1, alpha: 0.10).setFill()
        NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        NSRect(x: dirtyRect.minX, y: bounds.maxY - 1, width: dirtyRect.width, height: 1).fill()
    }
}
