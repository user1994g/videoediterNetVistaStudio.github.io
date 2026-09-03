import Cocoa

private final class EffectsFlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Non-rendering Program Monitor guides. They are presentation-only and never
/// enter the Core Image compositor or exported movie.
final class ProgramGuideOverlayView: NSView {
    var showsThirds = false { didSet { needsDisplay = true; isHidden = !showsThirds && !showsSafeMargins && !showsTransformBounds } }
    var showsSafeMargins = false { didSet { needsDisplay = true; isHidden = !showsThirds && !showsSafeMargins && !showsTransformBounds } }
    var showsTransformBounds = false { didSet { needsDisplay = true; isHidden = !showsThirds && !showsSafeMargins && !showsTransformBounds } }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor; isHidden = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let canvas = aspectFit(aspect: 16.0 / 9.0, in: bounds.insetBy(dx: 8, dy: 8))
        NSGraphicsContext.current?.saveGraphicsState()
        if showsThirds {
            let path = NSBezierPath(); path.lineWidth = 1
            for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                let x = canvas.minX + canvas.width * fraction; path.move(to: NSPoint(x: x, y: canvas.minY)); path.line(to: NSPoint(x: x, y: canvas.maxY))
                let y = canvas.minY + canvas.height * fraction; path.move(to: NSPoint(x: canvas.minX, y: y)); path.line(to: NSPoint(x: canvas.maxX, y: y))
            }
            NSColor.white.withAlphaComponent(0.36).setStroke(); path.stroke()
        }
        if showsSafeMargins {
            let action = canvas.insetBy(dx: canvas.width * 0.10, dy: canvas.height * 0.10)
            let title = canvas.insetBy(dx: canvas.width * 0.20, dy: canvas.height * 0.20)
            for (rect, alpha) in [(action, 0.55), (title, 0.34)] {
                let path = NSBezierPath(rect: rect); path.lineWidth = 1; path.setLineDash([6, 4], count: 2, phase: 0); NSColor.systemYellow.withAlphaComponent(alpha).setStroke(); path.stroke()
            }
        }
        if showsTransformBounds {
            let path = NSBezierPath(rect: canvas.insetBy(dx: 2, dy: 2)); path.lineWidth = 1.5; NSColor.systemBlue.withAlphaComponent(0.85).setStroke(); path.stroke()
            for point in [NSPoint(x: canvas.minX, y: canvas.minY), NSPoint(x: canvas.maxX, y: canvas.minY), NSPoint(x: canvas.minX, y: canvas.maxY), NSPoint(x: canvas.maxX, y: canvas.maxY)] {
                NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
            }
            let centre = NSPoint(x: canvas.midX, y: canvas.midY)
            let cross = NSBezierPath(); cross.move(to: NSPoint(x: centre.x - 8, y: centre.y)); cross.line(to: NSPoint(x: centre.x + 8, y: centre.y)); cross.move(to: NSPoint(x: centre.x, y: centre.y - 8)); cross.line(to: NSPoint(x: centre.x, y: centre.y + 8)); NSColor.systemBlue.setStroke(); cross.stroke()
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    private func aspectFit(aspect: CGFloat, in rect: CGRect) -> CGRect {
        if rect.width / max(1, rect.height) > aspect {
            let width = rect.height * aspect; return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        }
        let height = rect.width / aspect; return CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }
}

/// Premiere-style clip-local property grid. It shares the selected clip's time
/// range, displays every effect row at once, seeks on click, and lets a diamond
/// be dragged horizontally to retime that keyframe.
final class EffectsKeyframeGridView: NSView {
    var onSeek: ((Double) -> Void)?
    var onSelectProperty: ((AnimatableProperty) -> Void)?
    var onMoveKeyframe: ((AnimatableProperty, UUID, Double) -> Void)?

    private(set) var properties: [AnimatableProperty] = []
    private var animation = ClipAnimation()
    private var duration = 1.0
    private var playhead = 0.0
    private var selectedProperty: AnimatableProperty = .opacity
    private let rulerHeight: CGFloat = 30
    private let rowHeight: CGFloat = 34
    private let labelWidth: CGFloat = 164
    private var zoomScale: CGFloat = 1
    private var hitDiamonds: [(property: AnimatableProperty, id: UUID, rect: NSRect)] = []
    private var draggedKeyframe: (property: AnimatableProperty, id: UUID)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var preferredHeight: CGFloat { rulerHeight + CGFloat(max(1, properties.count)) * rowHeight + 2 }
    func preferredWidth(for viewportWidth: CGFloat) -> CGFloat { max(520, viewportWidth) * zoomScale }
    func setZoomScale(_ value: CGFloat) {
        zoomScale = min(12, max(1, value))
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func load(properties: [AnimatableProperty], animation: ClipAnimation, duration: Double, playhead: Double, selectedProperty: AnimatableProperty) {
        self.properties = properties
        self.animation = animation
        self.duration = max(1.0 / 30.0, duration)
        self.playhead = min(max(0, playhead), self.duration)
        self.selectedProperty = selectedProperty
        invalidateIntrinsicContentSize()
        frame.size.height = preferredHeight
        needsDisplay = true
    }

    func update(playhead: Double) {
        self.playhead = min(max(0, playhead), duration)
        needsDisplay = true
    }
    func selectProperty(_ property: AnimatableProperty) { selectedProperty = property; needsDisplay = true }

    override var intrinsicContentSize: NSSize { NSSize(width: 520, height: preferredHeight) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(hex: "11151B").setFill(); dirtyRect.fill()
        hitDiamonds.removeAll(keepingCapacity: true)
        let timelineWidth = max(40, bounds.width - labelWidth - 12)
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor(hex: "B8C0CE")]
        let mutedAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor(hex: "798394")]

        NSColor(hex: "191E26").setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: rulerHeight).fill()
        let secondsPerTargetTick = duration * 72 / Double(timelineWidth)
        let tickChoices = [1.0 / 30.0, 1.0 / 15.0, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let majorStep = tickChoices.first(where: { $0 >= secondsPerTargetTick }) ?? 600
        var time = 0.0
        while time <= duration + 0.0001 {
            let x = labelWidth + CGFloat(time / duration) * timelineWidth
            NSColor(hex: "343C49").setFill(); NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
            formatTime(time).draw(at: NSPoint(x: x + 4, y: 8), withAttributes: mutedAttributes)
            time += majorStep
        }

        for (rowIndex, property) in properties.enumerated() {
            let y = rulerHeight + CGFloat(rowIndex) * rowHeight
            if property == selectedProperty {
                NSColor(hex: "243044").setFill(); NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill()
            } else if rowIndex.isMultiple(of: 2) {
                NSColor(hex: "151A21").setFill(); NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill()
            }
            NSColor(hex: "2D3440").setFill(); NSRect(x: 0, y: y + rowHeight - 1, width: bounds.width, height: 1).fill()
            property.title.draw(in: NSRect(x: 12, y: y + 10, width: labelWidth - 20, height: 16), withAttributes: titleAttributes)

            guard let channel = animation.channels.first(where: { $0.property == property }) else { continue }
            let frames = channel.keyframes.sorted { $0.time < $1.time }
            if frames.count > 1 {
                let line = NSBezierPath(); line.lineWidth = 1.5
                for (index, frame) in frames.enumerated() {
                    let point = gridPoint(property: property, time: frame.time, value: frame.value, rowY: y, timelineWidth: timelineWidth)
                    index == 0 ? line.move(to: point) : line.line(to: point)
                }
                NSColor.systemOrange.withAlphaComponent(0.55).setStroke(); line.stroke()
            }
            for frame in frames {
                let point = gridPoint(property: property, time: frame.time, value: frame.value, rowY: y, timelineWidth: timelineWidth)
                let hit = NSRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)
                hitDiamonds.append((property, frame.id, hit))
                if abs(frame.time - playhead) < (1.0 / 60.0) {
                    NSColor.systemOrange.withAlphaComponent(0.22).setFill()
                    NSBezierPath(ovalIn: NSRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)).fill()
                }
                let diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: point.x, y: point.y - 6)); diamond.line(to: NSPoint(x: point.x + 6, y: point.y)); diamond.line(to: NSPoint(x: point.x, y: point.y + 6)); diamond.line(to: NSPoint(x: point.x - 6, y: point.y)); diamond.close()
                (property == selectedProperty ? NSColor.systemOrange : NSColor(hex: "D59A45")).setFill(); diamond.fill()
                NSColor.white.withAlphaComponent(0.72).setStroke(); diamond.lineWidth = 1; diamond.stroke()
            }
        }

        let playheadX = labelWidth + CGFloat(playhead / duration) * timelineWidth
        NSColor.systemRed.setFill(); NSRect(x: playheadX - 1, y: 0, width: 2, height: bounds.height).fill()
        let marker = NSBezierPath(); marker.move(to: NSPoint(x: playheadX - 6, y: 0)); marker.line(to: NSPoint(x: playheadX + 6, y: 0)); marker.line(to: NSPoint(x: playheadX, y: 8)); marker.close(); marker.fill()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let hit = hitDiamonds.last(where: { $0.rect.contains(point) }) {
            draggedKeyframe = (hit.property, hit.id)
            select(hit.property)
            if let frame = animation.channels.first(where: { $0.property == hit.property })?.keyframes.first(where: { $0.id == hit.id }) {
                playhead = frame.time; onSeek?(frame.time); needsDisplay = true
            }
            return
        }
        if point.y >= rulerHeight {
            let row = min(properties.count - 1, max(0, Int((point.y - rulerHeight) / rowHeight)))
            if properties.indices.contains(row) { select(properties[row]) }
        }
        playhead = time(at: point.x); onSeek?(playhead); needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let draggedKeyframe else { return }
        let point = convert(event.locationInWindow, from: nil)
        let newTime = (time(at: point.x) * 30).rounded() / 30
        if let channelIndex = animation.channels.firstIndex(where: { $0.property == draggedKeyframe.property }),
           let frameIndex = animation.channels[channelIndex].keyframes.firstIndex(where: { $0.id == draggedKeyframe.id }) {
            animation.channels[channelIndex].keyframes[frameIndex].time = newTime
            animation.channels[channelIndex].keyframes.sort { $0.time < $1.time }
        }
        playhead = newTime; needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let draggedKeyframe else { return }
        self.draggedKeyframe = nil
        onMoveKeyframe?(draggedKeyframe.property, draggedKeyframe.id, playhead)
        onSeek?(playhead)
    }

    private func select(_ property: AnimatableProperty) {
        selectedProperty = property; onSelectProperty?(property); needsDisplay = true
    }
    private func time(at x: CGFloat) -> Double {
        let width = max(40, bounds.width - labelWidth - 12)
        return min(duration, max(0, Double((x - labelWidth) / width) * duration))
    }
    private func gridPoint(property: AnimatableProperty, time: Double, value: Double, rowY: CGFloat, timelineWidth: CGFloat) -> NSPoint {
        let x = labelWidth + CGFloat(min(duration, max(0, time)) / duration) * timelineWidth
        let normalized = normalizedValue(value, for: property)
        let y = rowY + 6 + CGFloat(1 - normalized) * (rowHeight - 12)
        return NSPoint(x: x, y: y)
    }
    private func normalizedValue(_ value: Double, for property: AnimatableProperty) -> Double {
        let range: ClosedRange<Double>
        switch property {
        case .positionX, .positionY: range = -1...1
        case .scale: range = 0.1...4
        case .rotation: range = -180...180
        case .opacity, .cropLeft, .cropRight, .cropTop, .cropBottom, .ultraKeyTolerance, .ultraKeySoftness, .ultraKeyChoke, .ultraKeySpill, .monochromeAmount, .sepiaAmount: range = 0...1
        case .blurRadius: range = 0...20
        case .sharpenAmount: range = 0...4
        case .vignetteIntensity: range = 0...1.5
        default: range = 0...1
        }
        return min(1, max(0, (value - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound)))
    }
    private func formatTime(_ seconds: Double) -> String {
        if duration <= 10 || zoomScale >= 4 { return String(format: "%02d:%02d.%02d", Int(seconds) / 60, Int(seconds) % 60, Int((seconds.truncatingRemainder(dividingBy: 1) * 30).rounded())) }
        return String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

/// A UI-facing catalogue entry. Reorderable entries map one-to-one to the
/// persisted `VideoEffectKind`; the fixed stages are still shown in the same
/// applied stack so the user can understand the complete clip pipeline.
private enum EffectsPanelKind: String, CaseIterable {
    case motion, opacity, ultraKey, monochrome, sepia, blur, sharpen, vignette, crop

    var title: String {
        switch self {
        case .motion: return "Motion"
        case .opacity: return "Opacity & Blend"
        case .ultraKey: return "Ultra Key"
        case .monochrome: return "Monochrome"
        case .sepia: return "Sepia"
        case .blur: return "Gaussian Blur"
        case .sharpen: return "Sharpen"
        case .vignette: return "Vignette"
        case .crop: return "Crop"
        }
    }

    var summary: String {
        switch self {
        case .motion: return "Position, scale and rotation"
        case .opacity: return "Transparency and blend mode"
        case .ultraKey: return "Green/blue screen keyer"
        case .monochrome: return "Remove colour selectively"
        case .sepia: return "Warm vintage toning"
        case .blur: return "Soft Gaussian defocus"
        case .sharpen: return "Increase edge detail"
        case .vignette: return "Darken the image edges"
        case .crop: return "Trim transparent edges"
        }
    }

    var symbolName: String {
        switch self {
        case .motion: return "move.3d"
        case .opacity: return "circle.lefthalf.filled"
        case .ultraKey: return "person.crop.rectangle"
        case .monochrome: return "circle.righthalf.filled"
        case .sepia: return "camera.filters"
        case .blur: return "drop"
        case .sharpen: return "triangle"
        case .vignette: return "circle.dashed"
        case .crop: return "crop"
        }
    }

    var keywords: String { "\(rawValue) \(title) \(summary)".lowercased() }
    var isFixed: Bool { self == .motion || self == .opacity }
    var isReorderable: Bool { videoEffectKind != nil }

    var primaryProperty: AnimatableProperty {
        switch self {
        case .motion: return .scale
        case .opacity: return .opacity
        case .ultraKey: return .ultraKeyTolerance
        case .monochrome: return .monochromeAmount
        case .sepia: return .sepiaAmount
        case .blur: return .blurRadius
        case .sharpen: return .sharpenAmount
        case .vignette: return .vignetteIntensity
        case .crop: return .cropLeft
        }
    }

    var videoEffectKind: VideoEffectKind? {
        switch self {
        case .monochrome: return .monochrome
        case .sepia: return .sepia
        case .blur: return .blur
        case .sharpen: return .sharpen
        case .vignette: return .vignette
        default: return nil
        }
    }

    static func panel(for kind: VideoEffectKind) -> EffectsPanelKind {
        switch kind {
        case .monochrome: return .monochrome
        case .sepia: return .sepia
        case .blur: return .blur
        case .sharpen: return .sharpen
        case .vignette: return .vignette
        }
    }
}

final class EffectsStudioViewController: NSViewController {
    var onPreview: ((EffectControlValues) -> Void)?
    var onApplyTransform: ((EffectControlValues) -> Void)?
    var onApplyEffects: ((EffectControlValues) -> Void)?
    var onApplyAll: ((EffectControlValues, [AnimatableProperty]) -> Void)?
    var onKeyframe: ((EffectControlValues, AnimatableProperty, KeyframeInterpolation) -> Void)?
    var onRemoveKeyframe: ((EffectControlValues, AnimatableProperty) -> Void)?
    var onClearKeyframes: ((EffectControlValues, AnimatableProperty) -> Void)?
    var onMoveKeyframe: ((AnimatableProperty, UUID, Double) -> Void)?
    var onSeekLocalTime: ((Double) -> Void)?
    var onOverlayOptions: ((Bool, Bool, Bool) -> Void)?
    var onMonitorZoomOut: (() -> Void)?
    var onMonitorZoomIn: (() -> Void)?
    var onMonitorFit: (() -> Void)?
    var onCancelPreview: (() -> Void)?
    var onReset: (() -> Void)?

    private let properties: [AnimatableProperty] = [
        .positionX, .positionY, .scale, .rotation, .opacity,
        .cropLeft, .cropRight, .cropTop, .cropBottom,
        .ultraKeyTolerance, .ultraKeySoftness, .ultraKeyChoke, .ultraKeySpill,
        .blurRadius, .sharpenAmount, .vignetteIntensity, .monochromeAmount, .sepiaAmount
    ]
    private let selectionLabel = NSTextField(labelWithString: "No video clip selected")
    private let keyframeLabel = NSTextField(wrappingLabelWithString: "No keyframes on this clip yet.")
    private let searchField = NSSearchField()
    private let propertyPicker = NSPopUpButton()
    private let curvePicker = NSPopUpButton()
    private let autoKeyButton = NSButton(checkboxWithTitle: "Auto Keyframe", target: nil, action: nil)
    private let grid = EffectsKeyframeGridView()
    private var gridHeightConstraint: NSLayoutConstraint?
    private var gridWidthConstraint: NSLayoutConstraint?
    private weak var gridScrollView: NSScrollView?
    private let gridZoomLabel = NSTextField(labelWithString: "Fit")
    private let keyframeTimeLabel = NSTextField(labelWithString: "00:00:00")
    private let appliedCountLabel = NSTextField(labelWithString: "2 stages")
    private let settingsTitleLabel = NSTextField(labelWithString: "Motion")
    private let settingsSummaryLabel = NSTextField(labelWithString: "Position, scale and rotation")
    private let appliedEffectsStack = EffectsFlippedStackView()
    private let browserEffectsStack = EffectsFlippedStackView()
    private weak var controlsScrollView: NSScrollView?
    private var gridZoomScale: CGFloat = 1
    private var effectCards: [EffectsPanelKind: NSView] = [:]
    private var browserRows: [EffectsPanelKind: NSView] = [:]
    private var browserSelectionButtons: [ObjectIdentifier: EffectsPanelKind] = [:]
    private var browserAddButtons: [EffectsPanelKind: NSButton] = [:]
    private var appliedSelectionButtons: [ObjectIdentifier: EffectsPanelKind] = [:]
    private var appliedMoveUpButtons: [ObjectIdentifier: EffectsPanelKind] = [:]
    private var appliedMoveDownButtons: [ObjectIdentifier: EffectsPanelKind] = [:]
    private var appliedRemoveButtons: [ObjectIdentifier: EffectsPanelKind] = [:]
    private var workingEffectOrder = VideoEffectKind.defaultOrder
    private var selectedEffect: EffectsPanelKind = .motion
    private var displayedAppliedEffects: [EffectsPanelKind] = []
    private var pendingRemovedProperties = Set<AnimatableProperty>()
    private var hasClipSelection = false
    private var loadedAnimation = ClipAnimation()
    private var localPlayhead = 0.0
    private var loadedDuration = 1.0
    private var numericFields: [ObjectIdentifier: (field: NSTextField, slider: NSSlider, scale: Double, suffix: String)] = [:]
    private var fieldToSlider: [ObjectIdentifier: (slider: NSSlider, scale: Double)] = [:]
    private var keyframeButtonProperties: [ObjectIdentifier: AnimatableProperty] = [:]
    private var keyframeButtons: [(button: NSButton, property: AnimatableProperty)] = []
    private var sliderProperties: [ObjectIdentifier: AnimatableProperty] = [:]
    private var pendingAutoKeyframe: DispatchWorkItem?
    private var resumePlayheadControlUpdates: DispatchWorkItem?
    private var isEditingControl = false

    private let positionX = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let positionY = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let scale = NSSlider(value: 1, minValue: 0.1, maxValue: 4, target: nil, action: nil)
    private let rotation = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    private let opacity = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let cropLeft = NSSlider(value: 0, minValue: 0, maxValue: 0.49, target: nil, action: nil)
    private let cropRight = NSSlider(value: 0, minValue: 0, maxValue: 0.49, target: nil, action: nil)
    private let cropTop = NSSlider(value: 0, minValue: 0, maxValue: 0.49, target: nil, action: nil)
    private let cropBottom = NSSlider(value: 0, minValue: 0, maxValue: 0.49, target: nil, action: nil)
    private let blur = NSSlider(value: 0, minValue: 0, maxValue: 20, target: nil, action: nil)
    private let sharpen = NSSlider(value: 0, minValue: 0, maxValue: 4, target: nil, action: nil)
    private let vignette = NSSlider(value: 0, minValue: 0, maxValue: 1.5, target: nil, action: nil)
    private let monochrome = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let sepia = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let blendMode = NSPopUpButton()
    private let keyEnabled = NSButton(checkboxWithTitle: "Enable Ultra Key", target: nil, action: nil)
    private let keyOutput = NSPopUpButton()
    private let keyColor = NSColorWell()
    private var colorSampler: NSColorSampler?
    private let transparency = NSSlider(value: 0.45, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let highlight = NSSlider(value: 0.10, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let shadow = NSSlider(value: 0.50, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let tolerance = NSSlider(value: 0.50, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let pedestal = NSSlider(value: 0.10, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let choke = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let soften = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let matteContrast = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let midpoint = NSSlider(value: 0.50, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let desaturate = NSSlider(value: 0.25, minValue: 0, maxValue: 0.5, target: nil, action: nil)
    private let spillRange = NSSlider(value: 0.50, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let spill = NSSlider(value: 0.50, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let luma = NSSlider(value: 0.50, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let keySaturation = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let keyHue = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    private let keyLuminance = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let showGrid = NSButton(checkboxWithTitle: "Rule of thirds", target: nil, action: nil)
    private let showSafe = NSButton(checkboxWithTitle: "Safe margins", target: nil, action: nil)
    private let showBounds = NSButton(checkboxWithTitle: "Transform bounds", target: nil, action: nil)

    override func loadView() {
        view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = NSColor(hex: "0E1116").cgColor
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .width; root.spacing = 10; root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12); root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor), root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor)])

        let header = NSStackView(); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 12; header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14); header.wantsLayer = true; header.layer?.backgroundColor = NSColor(hex: "181D25").cgColor; header.layer?.cornerRadius = 10; header.layer?.borderColor = NSColor(hex: "2B3340").cgColor; header.layer?.borderWidth = 1
        let identity = NSStackView(); identity.orientation = .vertical; identity.alignment = .leading; identity.spacing = 2
        let eyebrow = NSTextField(labelWithString: "NETVISTA STUDIO  /  EFFECTS"); eyebrow.font = .monospacedSystemFont(ofSize: 9, weight: .bold); eyebrow.textColor = .systemPurple
        let title = NSTextField(labelWithString: "Effect Controls"); title.font = .systemFont(ofSize: 18, weight: .bold); title.textColor = .white
        identity.addArrangedSubview(eyebrow); identity.addArrangedSubview(title)
        selectionLabel.font = .systemFont(ofSize: 11, weight: .semibold); selectionLabel.textColor = NSColor(hex: "AEB8C8"); selectionLabel.lineBreakMode = .byTruncatingMiddle
        searchField.placeholderString = "Search effect browser"; searchField.target = self; searchField.action = #selector(filterChanged); searchField.sendsSearchStringImmediately = true
        let live = NSTextField(labelWithString: "●  LIVE PREVIEW"); live.font = .monospacedSystemFont(ofSize: 9, weight: .bold); live.textColor = .systemGreen
        header.addArrangedSubview(identity); header.addArrangedSubview(dividerView(height: 34)); header.addArrangedSubview(selectionLabel); header.addArrangedSubview(NSView()); header.addArrangedSubview(live); header.addArrangedSubview(searchField); searchField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        root.addArrangedSubview(header)

        let monitorTools = NSStackView(); monitorTools.orientation = .horizontal; monitorTools.alignment = .centerY; monitorTools.spacing = 7; monitorTools.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10); monitorTools.wantsLayer = true; monitorTools.layer?.backgroundColor = NSColor(hex: "141920").cgColor; monitorTools.layer?.cornerRadius = 8
        let monitorTitle = NSTextField(labelWithString: "PROGRAM VIEW"); monitorTitle.font = .systemFont(ofSize: 9, weight: .bold); monitorTitle.textColor = NSColor(hex: "8D99AB")
        monitorTools.addArrangedSubview(monitorTitle)
        monitorTools.addArrangedSubview(makeButton("−", #selector(monitorZoomOut)))
        monitorTools.addArrangedSubview(makeButton("Fit", #selector(monitorFit)))
        monitorTools.addArrangedSubview(makeButton("+", #selector(monitorZoomIn)))
        let safety = NSTextField(labelWithString: "Video surface is inspection-only — use the transport bar to play."); safety.font = .systemFont(ofSize: 10); safety.textColor = NSColor(hex: "7F8A9B")
        monitorTools.addArrangedSubview(safety); monitorTools.addArrangedSubview(NSView())
        [showGrid, showSafe, showBounds].forEach { $0.target = self; $0.action = #selector(overlaysChanged); monitorTools.addArrangedSubview($0) }
        root.addArrangedSubview(monitorTools)

        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let controls = makeControlsPane(); controls.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        let keyframes = makeKeyframePane(); keyframes.widthAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true
        split.addArrangedSubview(controls); split.addArrangedSubview(keyframes); split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        root.addArrangedSubview(split)

        let actions = NSStackView(); actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 8; actions.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10); actions.wantsLayer = true; actions.layer?.backgroundColor = NSColor(hex: "171C23").cgColor; actions.layer?.cornerRadius = 8
        let fitNote = NSTextField(labelWithString: "Changes preview at the current frame. Add diamonds to animate values over time."); fitNote.font = .systemFont(ofSize: 10); fitNote.textColor = NSColor(hex: "8F99A9")
        actions.addArrangedSubview(fitNote); actions.addArrangedSubview(NSView())
        actions.addArrangedSubview(makeButton("Revert Preview", #selector(revertPreview)))
        actions.addArrangedSubview(makeButton("Reset Selected", #selector(reset)))
        let apply = makeButton("Apply to Clip", #selector(applyAll)); apply.contentTintColor = .systemBlue; actions.addArrangedSubview(apply)
        root.addArrangedSubview(actions)
        showGrid.state = .off; showSafe.state = .off; showBounds.state = .off
        DispatchQueue.main.async { [weak self] in self?.overlaysChanged() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateGridWidth(revealPlayhead: false)
    }

    override func viewDidDisappear() { super.viewDidDisappear(); onCancelPreview?() }

    private func makeControlsPane() -> NSView {
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let sidebar = makeEffectSidebar()
        let settings = makeEffectSettingsPane()
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 184).isActive = true
        let sidebarMaximum = sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 260); sidebarMaximum.priority = .defaultHigh; sidebarMaximum.isActive = true
        settings.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(settings)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        DispatchQueue.main.async { [weak self] in
            self?.showEffect(.motion, revealKeyframes: false)
            self?.refreshAppliedEffects(force: true)
        }
        return split
    }

    private func makeEffectSidebar() -> NSView {
        let pane = NSStackView(); pane.orientation = .vertical; pane.alignment = .width; pane.spacing = 8; pane.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10); pane.wantsLayer = true; pane.layer?.backgroundColor = NSColor(hex: "11161D").cgColor; pane.layer?.cornerRadius = 9; pane.layer?.borderColor = NSColor(hex: "29313D").cgColor; pane.layer?.borderWidth = 1

        let appliedHeader = NSStackView(); appliedHeader.orientation = .horizontal; appliedHeader.alignment = .centerY
        let appliedTitle = sectionLabel("APPLIED EFFECTS")
        appliedCountLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold); appliedCountLabel.textColor = NSColor(hex: "7F8B9C")
        appliedHeader.addArrangedSubview(appliedTitle); appliedHeader.addArrangedSubview(NSView()); appliedHeader.addArrangedSubview(appliedCountLabel)
        pane.addArrangedSubview(appliedHeader)

        appliedEffectsStack.orientation = .vertical; appliedEffectsStack.alignment = .width; appliedEffectsStack.spacing = 5; appliedEffectsStack.translatesAutoresizingMaskIntoConstraints = false
        let appliedScroll = effectListScroll(appliedEffectsStack)
        let appliedHeight = appliedScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150); appliedHeight.priority = .defaultHigh; appliedHeight.isActive = true
        pane.addArrangedSubview(appliedScroll)

        let divider = NSView(); divider.wantsLayer = true; divider.layer?.backgroundColor = NSColor(hex: "2B323D").cgColor; divider.heightAnchor.constraint(equalToConstant: 1).isActive = true; pane.addArrangedSubview(divider)
        let browseTitle = sectionLabel("EFFECT BROWSER")
        pane.addArrangedSubview(browseTitle)
        let browseHelp = NSTextField(wrappingLabelWithString: "Add an effect once, then edit it directly. Search filters this list immediately.")
        browseHelp.font = .systemFont(ofSize: 9); browseHelp.textColor = NSColor(hex: "768294"); browseHelp.maximumNumberOfLines = 3; pane.addArrangedSubview(browseHelp)

        browserEffectsStack.orientation = .vertical; browserEffectsStack.alignment = .width; browserEffectsStack.spacing = 5; browserEffectsStack.translatesAutoresizingMaskIntoConstraints = false
        EffectsPanelKind.allCases.forEach { kind in
            let row = makeBrowserRow(kind)
            browserRows[kind] = row
            browserEffectsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: browserEffectsStack.widthAnchor).isActive = true
        }
        let browserScroll = effectListScroll(browserEffectsStack)
        browserScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        pane.addArrangedSubview(browserScroll)
        return pane
    }

    private func makeEffectSettingsPane() -> NSView {
        let pane = NSStackView(); pane.orientation = .vertical; pane.alignment = .width; pane.spacing = 8; pane.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10); pane.wantsLayer = true; pane.layer?.backgroundColor = NSColor(hex: "12171E").cgColor; pane.layer?.cornerRadius = 9; pane.layer?.borderColor = NSColor(hex: "29313D").cgColor; pane.layer?.borderWidth = 1

        let heading = NSStackView(); heading.orientation = .horizontal; heading.alignment = .centerY; heading.spacing = 8
        let identity = NSStackView(); identity.orientation = .vertical; identity.alignment = .leading; identity.spacing = 2
        settingsTitleLabel.font = .systemFont(ofSize: 14, weight: .bold); settingsTitleLabel.textColor = .white
        settingsSummaryLabel.font = .systemFont(ofSize: 9); settingsSummaryLabel.textColor = NSColor(hex: "8793A5")
        identity.addArrangedSubview(settingsTitleLabel); identity.addArrangedSubview(settingsSummaryLabel)
        heading.addArrangedSubview(identity); heading.addArrangedSubview(NSView())
        let resetButton = makeButton("Reset Effect", #selector(reset)); resetButton.toolTip = "Reset only the effect currently shown"; heading.addArrangedSubview(resetButton)
        pane.addArrangedSubview(heading)

        let document = EffectsFlippedStackView(); document.orientation = .vertical; document.alignment = .width; document.spacing = 9; document.translatesAutoresizingMaskIntoConstraints = false
        let motionKeys = quickActionRow([
            ("◆ Zoom 50%", #selector(keyframeZoom50)),
            ("◆ Fit 100%", #selector(keyframeZoom100)),
            ("◆ Zoom 200%", #selector(keyframeZoom200))
        ])
        let motion = effectCard("MOTION", subtitle: "Automatic Fit → user transform", controls: [
            parameterRow("Position X", positionX, property: .positionX), parameterRow("Position Y", positionY, property: .positionY), parameterRow("Scale / Zoom", scale, scale: 100, suffix: "%", property: .scale), parameterRow("Rotation", rotation, suffix: "°", property: .rotation), motionKeys
        ]); registerEffectCard(.motion, motion, in: document)

        ClipBlendMode.allCases.forEach { blendMode.addItem(withTitle: $0.title) }
        blendMode.target = self; blendMode.action = #selector(controlChanged)
        let opacityKeys = quickActionRow([
            ("◆ Hidden 0%", #selector(keyframeOpacity0)),
            ("◆ Visible 100%", #selector(keyframeOpacity100))
        ])
        let opacityCard = effectCard("OPACITY", subtitle: "Fixed effect • composited after Motion", controls: [parameterRow("Opacity", opacity, scale: 100, suffix: "%", property: .opacity), opacityKeys, popupRow("Blend Mode", blendMode)])
        registerEffectCard(.opacity, opacityCard, in: document)

        let crop = effectCard("CROP", subtitle: "Transparent edge crop", controls: [parameterRow("Left", cropLeft, scale: 100, suffix: "%", property: .cropLeft), parameterRow("Right", cropRight, scale: 100, suffix: "%", property: .cropRight), parameterRow("Top", cropTop, scale: 100, suffix: "%", property: .cropTop), parameterRow("Bottom", cropBottom, scale: 100, suffix: "%", property: .cropBottom)])
        registerEffectCard(.crop, crop, in: document)

        let ultraStack = NSStackView(); ultraStack.orientation = .vertical; ultraStack.alignment = .width; ultraStack.spacing = 7
        keyEnabled.target = self; keyEnabled.action = #selector(controlChanged); ultraStack.addArrangedSubview(keyEnabled)
        UltraKeyOutputMode.allCases.forEach { keyOutput.addItem(withTitle: $0.title) }; keyOutput.target = self; keyOutput.action = #selector(controlChanged); ultraStack.addArrangedSubview(popupRow("Output", keyOutput))
        keyColor.target = self; keyColor.action = #selector(controlChanged); ultraStack.addArrangedSubview(colorRow())
        let presets = NSStackView(); presets.orientation = .horizontal; presets.spacing = 6; presets.addArrangedSubview(makeButton("Green Screen", #selector(greenScreen))); presets.addArrangedSubview(makeButton("Blue Screen", #selector(blueScreen))); presets.addArrangedSubview(makeButton("Relaxed", #selector(relaxedKey))); presets.addArrangedSubview(makeButton("Aggressive", #selector(aggressiveKey))); ultraStack.addArrangedSubview(presets)
        addSubheading("MATTE GENERATION", to: ultraStack)
        [parameterRow("Transparency", transparency, scale: 100, suffix: "%"), parameterRow("Highlight", highlight, scale: 100, suffix: "%"), parameterRow("Shadow", shadow, scale: 100, suffix: "%"), parameterRow("Tolerance", tolerance, scale: 100, suffix: "%", property: .ultraKeyTolerance), parameterRow("Pedestal", pedestal, scale: 100, suffix: "%")].forEach { ultraStack.addArrangedSubview($0) }
        addSubheading("MATTE CLEANUP", to: ultraStack)
        [parameterRow("Choke", choke, scale: 100, suffix: "%", property: .ultraKeyChoke), parameterRow("Soften", soften, scale: 100, suffix: "%", property: .ultraKeySoftness), parameterRow("Contrast", matteContrast, scale: 100, suffix: "%"), parameterRow("Mid Point", midpoint, scale: 100, suffix: "%")].forEach { ultraStack.addArrangedSubview($0) }
        addSubheading("SPILL SUPPRESSION", to: ultraStack)
        [parameterRow("Desaturate", desaturate, scale: 100, suffix: "%"), parameterRow("Range", spillRange, scale: 100, suffix: "%"), parameterRow("Spill", spill, scale: 100, suffix: "%", property: .ultraKeySpill), parameterRow("Luma", luma, scale: 100, suffix: "%")].forEach { ultraStack.addArrangedSubview($0) }
        addSubheading("COLOR CORRECTION", to: ultraStack)
        [parameterRow("Saturation", keySaturation, scale: 100, suffix: "%"), parameterRow("Hue", keyHue, suffix: "°"), parameterRow("Luminance", keyLuminance, scale: 100, suffix: "%")].forEach { ultraStack.addArrangedSubview($0) }
        let ultra = effectCard("ULTRA KEY", subtitle: "Native chroma matte, cleanup and despill", controls: [ultraStack]); registerEffectCard(.ultraKey, ultra, in: document)

        registerEffectCard(.blur, effectCard("GAUSSIAN BLUR", subtitle: "Soft defocus with animated radius", controls: [parameterRow("Blur Radius", blur, property: .blurRadius)]), in: document)
        registerEffectCard(.sharpen, effectCard("SHARPEN", subtitle: "Luminance edge enhancement", controls: [parameterRow("Amount", sharpen, property: .sharpenAmount)]), in: document)
        registerEffectCard(.vignette, effectCard("VIGNETTE", subtitle: "Darken and focus the image edges", controls: [parameterRow("Intensity", vignette, property: .vignetteIntensity)]), in: document)
        registerEffectCard(.monochrome, effectCard("MONOCHROME", subtitle: "Blend from full colour to monochrome", controls: [parameterRow("Amount", monochrome, scale: 100, suffix: "%", property: .monochromeAmount)]), in: document)
        registerEffectCard(.sepia, effectCard("SEPIA", subtitle: "Warm vintage colour treatment", controls: [parameterRow("Amount", sepia, scale: 100, suffix: "%", property: .sepiaAmount)]), in: document)

        let scroll = scrollingView(document); controlsScrollView = scroll; pane.addArrangedSubview(scroll)
        return pane
    }

    private func registerEffectCard(_ kind: EffectsPanelKind, _ card: NSView, in document: NSStackView) {
        effectCards[kind] = card
        document.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: document.widthAnchor).isActive = true
        card.isHidden = kind != selectedEffect
    }

    private func effectListScroll(_ document: NSView) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 9, weight: .bold); label.textColor = NSColor(hex: "8996A9"); return label
    }

    private func makeBrowserRow(_ kind: EffectsPanelKind) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 6; row.edgeInsets = NSEdgeInsets(top: 6, left: 7, bottom: 6, right: 7); row.wantsLayer = true; row.layer?.backgroundColor = NSColor(hex: "191F28").cgColor; row.layer?.cornerRadius = 7; row.layer?.borderColor = NSColor(hex: "28313E").cgColor; row.layer?.borderWidth = 1
        let icon = NSImageView(); icon.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil); icon.contentTintColor = NSColor(hex: "91A0B6"); icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium); icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let choose = NSButton(title: kind.title, target: self, action: #selector(selectBrowserEffect(_:))); choose.isBordered = false; choose.alignment = .left; choose.font = .systemFont(ofSize: 10, weight: .semibold); choose.contentTintColor = NSColor(hex: "D5DCE7"); choose.toolTip = kind.summary; browserSelectionButtons[ObjectIdentifier(choose)] = kind
        let add = NSButton(title: kind.isFixed ? "Fixed" : "+ Add", target: self, action: #selector(addBrowserEffect(_:))); add.bezelStyle = .roundRect; add.font = .systemFont(ofSize: 9, weight: .semibold); add.isEnabled = !kind.isFixed; browserSelectionButtons[ObjectIdentifier(add)] = kind; browserAddButtons[kind] = add
        row.addArrangedSubview(icon); row.addArrangedSubview(choose); row.addArrangedSubview(NSView()); row.addArrangedSubview(add)
        return row
    }

    private func makeKeyframePane() -> NSView {
        let pane = NSStackView(); pane.orientation = .vertical; pane.alignment = .width; pane.spacing = 8; pane.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10); pane.wantsLayer = true; pane.layer?.backgroundColor = NSColor(hex: "12161C").cgColor; pane.layer?.cornerRadius = 9; pane.layer?.borderColor = NSColor(hex: "29313D").cgColor; pane.layer?.borderWidth = 1
        let timelineHeader = NSStackView(); timelineHeader.orientation = .horizontal; timelineHeader.alignment = .centerY; timelineHeader.spacing = 6
        let heading = NSTextField(labelWithString: "KEYFRAME EDITOR"); heading.font = .systemFont(ofSize: 11, weight: .bold); heading.textColor = NSColor(hex: "C7CFDC")
        let hint = NSTextField(labelWithString: "Move the playhead, then adjust a control to add a point"); hint.font = .systemFont(ofSize: 9); hint.textColor = NSColor(hex: "8995A7")
        gridZoomLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold); gridZoomLabel.textColor = NSColor(hex: "9AA6B8"); gridZoomLabel.alignment = .center; gridZoomLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        timelineHeader.addArrangedSubview(heading); timelineHeader.addArrangedSubview(hint); timelineHeader.addArrangedSubview(NSView())
        timelineHeader.addArrangedSubview(makeButton("−", #selector(zoomKeyframesOut))); timelineHeader.addArrangedSubview(gridZoomLabel); timelineHeader.addArrangedSubview(makeButton("+", #selector(zoomKeyframesIn))); timelineHeader.addArrangedSubview(makeButton("Fit", #selector(fitKeyframes)))
        pane.addArrangedSubview(timelineHeader)

        properties.forEach { propertyPicker.addItem(withTitle: $0.title) }; propertyPicker.target = self; propertyPicker.action = #selector(propertyChanged)
        KeyframeInterpolation.editorChoices.forEach { curvePicker.addItem(withTitle: $0.title) }
        let selectors = NSStackView(); selectors.orientation = .horizontal; selectors.alignment = .centerY; selectors.spacing = 8
        let propertyLabel = NSTextField(labelWithString: "PROPERTY"); propertyLabel.font = .systemFont(ofSize: 9, weight: .bold); propertyLabel.textColor = NSColor(hex: "748096")
        let curveLabel = NSTextField(labelWithString: "CURVE"); curveLabel.font = .systemFont(ofSize: 9, weight: .bold); curveLabel.textColor = NSColor(hex: "748096")
        keyframeTimeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold); keyframeTimeLabel.textColor = .systemRed
        autoKeyButton.target = self; autoKeyButton.action = #selector(autoKeyChanged); autoKeyButton.toolTip = "When enabled, changing an animatable slider writes a keyframe at the current playhead after you finish dragging."
        autoKeyButton.state = .on
        selectors.addArrangedSubview(propertyLabel); selectors.addArrangedSubview(propertyPicker); selectors.addArrangedSubview(curveLabel); selectors.addArrangedSubview(curvePicker); selectors.addArrangedSubview(NSView()); selectors.addArrangedSubview(autoKeyButton); selectors.addArrangedSubview(keyframeTimeLabel); pane.addArrangedSubview(selectors)
        let keyActions = NSStackView(); keyActions.orientation = .horizontal; keyActions.spacing = 6
        keyActions.addArrangedSubview(makeButton("◀ Previous", #selector(previousKeyframe)))
        let add = makeButton("◆ Add / Update", #selector(addKeyframe)); add.contentTintColor = .systemOrange; keyActions.addArrangedSubview(add)
        keyActions.addArrangedSubview(makeButton("Next ▶", #selector(nextKeyframe)))
        keyActions.addArrangedSubview(makeButton("Remove Here", #selector(removeKeyframe)))
        keyActions.addArrangedSubview(makeButton("Clear Property", #selector(clearKeyframes)))
        pane.addArrangedSubview(keyActions)

        let gridScroll = NSScrollView(); gridScroll.drawsBackground = true; gridScroll.backgroundColor = NSColor(hex: "0D1116"); gridScroll.hasVerticalScroller = true; gridScroll.hasHorizontalScroller = true; gridScroll.autohidesScrollers = true; gridScroll.borderType = .lineBorder; grid.translatesAutoresizingMaskIntoConstraints = false; gridScroll.documentView = grid; gridScrollView = gridScroll
        gridWidthConstraint = grid.widthAnchor.constraint(equalToConstant: 640); gridWidthConstraint?.isActive = true
        gridHeightConstraint = grid.heightAnchor.constraint(equalToConstant: grid.preferredHeight); gridHeightConstraint?.isActive = true
        NSLayoutConstraint.activate([grid.leadingAnchor.constraint(equalTo: gridScroll.contentView.leadingAnchor), grid.topAnchor.constraint(equalTo: gridScroll.contentView.topAnchor)])
        pane.addArrangedSubview(gridScroll)

        keyframeLabel.font = .systemFont(ofSize: 10); keyframeLabel.textColor = .secondaryLabelColor; keyframeLabel.maximumNumberOfLines = 4; pane.addArrangedSubview(keyframeLabel)

        grid.onSeek = { [weak self] time in self?.localPlayhead = time; self?.updateKeyframeTimeLabel(); self?.onSeekLocalTime?(time) }
        grid.onSelectProperty = { [weak self] property in self?.select(property) }
        grid.onMoveKeyframe = { [weak self] property, id, time in self?.onMoveKeyframe?(property, id, time) }
        return pane
    }

    func load(_ values: EffectControlValues, selectionName: String, property: AnimatableProperty, interpolation: KeyframeInterpolation, keyframeText: String) {
        load(values, selectionName: selectionName, property: property, interpolation: interpolation, keyframeText: keyframeText, clip: nil, timelineTime: 0)
    }

    func load(_ values: EffectControlValues, selectionName: String, property: AnimatableProperty, interpolation: KeyframeInterpolation, keyframeText: String, clip: TimelineClip?, timelineTime: Double) {
        hasClipSelection = clip != nil
        pendingRemovedProperties.removeAll()
        selectionLabel.stringValue = "Selected: \(selectionName)"; keyframeLabel.stringValue = keyframeText
        workingEffectOrder = ClipEffects.normalizedOrder(values.effects.effectOrder)
        positionX.doubleValue = values.transform.positionX; positionY.doubleValue = values.transform.positionY; scale.doubleValue = values.transform.scale; rotation.doubleValue = values.transform.rotation; opacity.doubleValue = values.transform.opacity
        blur.doubleValue = values.effects.blurRadius; sharpen.doubleValue = values.effects.sharpenAmount; vignette.doubleValue = values.effects.vignetteIntensity; monochrome.doubleValue = values.effects.monochromeAmount; sepia.doubleValue = values.effects.sepiaAmount
        cropLeft.doubleValue = values.effects.crop.left; cropRight.doubleValue = values.effects.crop.right; cropTop.doubleValue = values.effects.crop.top; cropBottom.doubleValue = values.effects.crop.bottom
        blendMode.selectItem(at: ClipBlendMode.allCases.firstIndex(of: values.effects.blendMode) ?? 0)
        loadUltraKey(values.effects.ultraKey)
        propertyPicker.selectItem(at: properties.firstIndex(of: property) ?? 0)
        curvePicker.selectItem(at: KeyframeInterpolation.editorChoices.firstIndex(of: interpolation) ?? 0)
        updateNumericFields()
        let local = clip.map { $0.localTime(at: timelineTime) } ?? 0
        let clipDuration = clip.map { max(1.0 / 30.0, $0.outPoint - $0.inPoint) } ?? 1
        loadedAnimation = clip?.animation ?? .init(); localPlayhead = local; loadedDuration = clipDuration
        grid.load(properties: properties, animation: clip?.animation ?? .init(), duration: clipDuration, playhead: local, selectedProperty: selectedProperty)
        gridHeightConstraint?.constant = grid.preferredHeight
        updateKeyframeTimeLabel()
        refreshKeyframeIndicators()
        setEditingEnabled(hasClipSelection)
        refreshAppliedEffects(force: true)
        DispatchQueue.main.async { [weak self] in
            self?.updateGridWidth(revealPlayhead: true)
            self?.revealSelectedProperty()
        }
    }

    func updatePlayhead(localTime: Double, evaluatedValues: EffectControlValues? = nil) {
        localPlayhead = localTime
        // A slider preview causes AVPlayer to seek the paused program monitor.
        // That seek reports the playhead again; do not let that callback write
        // the previous frame values over the thumb while the user is dragging.
        if let evaluatedValues, !isEditingControl {
            positionX.doubleValue = evaluatedValues.transform.positionX
            positionY.doubleValue = evaluatedValues.transform.positionY
            scale.doubleValue = evaluatedValues.transform.scale
            rotation.doubleValue = evaluatedValues.transform.rotation
            opacity.doubleValue = evaluatedValues.transform.opacity
            cropLeft.doubleValue = evaluatedValues.effects.crop.left
            cropRight.doubleValue = evaluatedValues.effects.crop.right
            cropTop.doubleValue = evaluatedValues.effects.crop.top
            cropBottom.doubleValue = evaluatedValues.effects.crop.bottom
            blur.doubleValue = evaluatedValues.effects.blurRadius
            sharpen.doubleValue = evaluatedValues.effects.sharpenAmount
            vignette.doubleValue = evaluatedValues.effects.vignetteIntensity
            monochrome.doubleValue = evaluatedValues.effects.monochromeAmount
            sepia.doubleValue = evaluatedValues.effects.sepiaAmount
            loadUltraKey(evaluatedValues.effects.ultraKey)
            updateNumericFields()
        }
        grid.update(playhead: localTime)
        updateKeyframeTimeLabel()
        refreshKeyframeIndicators()
    }

    private func loadUltraKey(_ key: UltraKeySettings) {
        keyEnabled.state = key.enabled ? .on : .off
        keyOutput.selectItem(at: UltraKeyOutputMode.allCases.firstIndex(of: key.output) ?? 0)
        keyColor.color = NSColor(calibratedRed: key.keyRed, green: key.keyGreen, blue: key.keyBlue, alpha: 1)
        transparency.doubleValue = key.transparency; highlight.doubleValue = key.highlight; shadow.doubleValue = key.shadow; tolerance.doubleValue = key.tolerance; pedestal.doubleValue = key.pedestal
        choke.doubleValue = key.choke; soften.doubleValue = key.soften; matteContrast.doubleValue = key.matteContrast; midpoint.doubleValue = key.midpoint
        desaturate.doubleValue = key.desaturate; spillRange.doubleValue = key.spillRange; spill.doubleValue = key.spill; luma.doubleValue = key.luma
        keySaturation.doubleValue = key.saturation; keyHue.doubleValue = key.hueDegrees; keyLuminance.doubleValue = key.luminance
    }

    private func values() -> EffectControlValues {
        var value = EffectControlValues()
        value.transform.positionX = positionX.doubleValue; value.transform.positionY = positionY.doubleValue; value.transform.scale = scale.doubleValue; value.transform.rotation = rotation.doubleValue; value.transform.opacity = opacity.doubleValue
        value.effects.blurRadius = blur.doubleValue; value.effects.sharpenAmount = sharpen.doubleValue; value.effects.vignetteIntensity = vignette.doubleValue; value.effects.monochromeAmount = monochrome.doubleValue; value.effects.sepiaAmount = sepia.doubleValue
        value.effects.crop = ClipCrop(left: cropLeft.doubleValue, right: cropRight.doubleValue, top: cropTop.doubleValue, bottom: cropBottom.doubleValue)
        value.effects.blendMode = ClipBlendMode.allCases[safe: blendMode.indexOfSelectedItem] ?? .normal
        value.effects.effectOrder = ClipEffects.normalizedOrder(workingEffectOrder)
        var key = UltraKeySettings(); key.enabled = keyEnabled.state == .on; key.output = UltraKeyOutputMode.allCases[safe: keyOutput.indexOfSelectedItem] ?? .composite
        if let color = keyColor.color.usingColorSpace(.deviceRGB) { key.keyRed = color.redComponent; key.keyGreen = color.greenComponent; key.keyBlue = color.blueComponent }
        key.transparency = transparency.doubleValue; key.highlight = highlight.doubleValue; key.shadow = shadow.doubleValue; key.tolerance = tolerance.doubleValue; key.pedestal = pedestal.doubleValue
        key.choke = choke.doubleValue; key.soften = soften.doubleValue; key.matteContrast = matteContrast.doubleValue; key.midpoint = midpoint.doubleValue
        key.desaturate = desaturate.doubleValue; key.spillRange = spillRange.doubleValue; key.spill = spill.doubleValue; key.luma = luma.doubleValue
        key.saturation = keySaturation.doubleValue; key.hueDegrees = keyHue.doubleValue; key.luminance = keyLuminance.doubleValue; value.effects.ultraKey = key
        return value
    }

    private var selectedProperty: AnimatableProperty { properties[safe: propertyPicker.indexOfSelectedItem] ?? .opacity }
    private var selectedCurve: KeyframeInterpolation { KeyframeInterpolation.editorChoices[safe: curvePicker.indexOfSelectedItem] ?? .easeInOut }

    @objc private func controlChanged() {
        holdPlayheadControlUpdates()
        updateNumericFields()
        refreshAppliedEffects()
        onPreview?(values())
    }
    @objc private func sliderChanged(_ sender: NSSlider) {
        controlChanged()
        guard let property = sliderProperties[ObjectIdentifier(sender)] else { return }
        scheduleAutoKeyframe(for: property)
    }
    @objc private func numericChanged(_ sender: NSTextField) {
        guard let mapping = fieldToSlider[ObjectIdentifier(sender)] else { return }
        mapping.slider.doubleValue = sender.doubleValue / mapping.scale
        controlChanged()
        if let property = sliderProperties[ObjectIdentifier(mapping.slider)] { scheduleAutoKeyframe(for: property) }
    }
    @objc private func propertyChanged() { gridSelectionChanged() }
    @objc private func addKeyframe() { onKeyframe?(values(), selectedProperty, selectedCurve); keyframeLabel.stringValue = "Keyframe added or updated at the program playhead." }
    @objc private func removeKeyframe() { onRemoveKeyframe?(values(), selectedProperty); keyframeLabel.stringValue = "Removed the keyframe at the program playhead." }
    @objc private func clearKeyframes() { onClearKeyframes?(values(), selectedProperty); keyframeLabel.stringValue = "Cleared \(selectedProperty.title) keyframes." }
    @objc private func previousKeyframe() { seekAdjacent(forward: false) }
    @objc private func nextKeyframe() { seekAdjacent(forward: true) }
    @objc private func applyAll() {
        onApplyAll?(values(), Array(pendingRemovedProperties))
        pendingRemovedProperties.removeAll()
    }
    @objc private func revertPreview() { onCancelPreview?() }
    @objc private func reset() {
        resetControls(for: selectedEffect)
        keyframeLabel.stringValue = "Reset \(selectedEffect.title) to its default settings."
        controlChanged()
    }
    @objc private func overlaysChanged() { onOverlayOptions?(showGrid.state == .on, showSafe.state == .on, showBounds.state == .on) }
    @objc private func monitorZoomOut() { onMonitorZoomOut?() }
    @objc private func monitorZoomIn() { onMonitorZoomIn?() }
    @objc private func monitorFit() { onMonitorFit?() }
    @objc private func zoomKeyframesOut() { setGridZoom(gridZoomScale / 1.5) }
    @objc private func zoomKeyframesIn() { setGridZoom(gridZoomScale * 1.5) }
    @objc private func fitKeyframes() { setGridZoom(1) }
    @objc private func autoKeyChanged() {
        pendingAutoKeyframe?.cancel()
        keyframeLabel.stringValue = autoKeyButton.state == .on
            ? "Auto Keyframe is on. Adjusting a diamond-enabled value writes a keyframe at the playhead."
            : "Auto Keyframe is off. Click a ◆ beside a property to write it manually."
    }
    @objc private func quickKeyframe(_ sender: NSButton) {
        guard let property = keyframeButtonProperties[ObjectIdentifier(sender)] else { return }
        select(property)
        addKeyframe()
    }
    @objc private func selectBrowserEffect(_ sender: NSButton) {
        guard let kind = browserSelectionButtons[ObjectIdentifier(sender)] else { return }
        showEffect(kind)
    }
    @objc private func addBrowserEffect(_ sender: NSButton) {
        guard let kind = browserSelectionButtons[ObjectIdentifier(sender)] else { return }
        if !isEffectActive(kind) { activateEffect(kind) }
        pendingRemovedProperties.subtract(animatableProperties(for: kind))
        showEffect(kind)
        controlChanged()
        keyframeLabel.stringValue = "Added \(kind.title). Its settings are ready to edit."
    }
    @objc private func selectAppliedEffect(_ sender: NSButton) {
        guard let kind = appliedSelectionButtons[ObjectIdentifier(sender)] else { return }
        showEffect(kind)
    }
    @objc private func moveAppliedEffectUp(_ sender: NSButton) {
        guard let kind = appliedMoveUpButtons[ObjectIdentifier(sender)] else { return }
        moveAppliedEffect(kind, offset: -1)
    }
    @objc private func moveAppliedEffectDown(_ sender: NSButton) {
        guard let kind = appliedMoveDownButtons[ObjectIdentifier(sender)] else { return }
        moveAppliedEffect(kind, offset: 1)
    }
    @objc private func removeAppliedEffect(_ sender: NSButton) {
        guard let kind = appliedRemoveButtons[ObjectIdentifier(sender)], !kind.isFixed else { return }
        resetControls(for: kind)
        let removedProperties = animatableProperties(for: kind)
        pendingRemovedProperties.formUnion(removedProperties)
        loadedAnimation.channels.removeAll { removedProperties.contains($0.property) }
        grid.load(properties: properties, animation: loadedAnimation, duration: loadedDuration, playhead: localPlayhead, selectedProperty: selectedProperty)
        gridHeightConstraint?.constant = grid.preferredHeight
        refreshKeyframeIndicators()
        refreshAppliedEffects(force: true)
        onPreview?(values())
        let next = displayedAppliedEffects.first(where: { $0 != kind }) ?? .motion
        showEffect(next)
        keyframeLabel.stringValue = "Removed \(kind.title) and its keyframes from the selected clip."
    }
    @objc private func greenScreen() { keyColor.color = .green; keyEnabled.state = .on; controlChanged() }
    @objc private func blueScreen() { keyColor.color = .blue; keyEnabled.state = .on; controlChanged() }
    @objc private func relaxedKey() { tolerance.doubleValue = 0.38; soften.doubleValue = 0.12; spill.doubleValue = 0.35; pedestal.doubleValue = 0.05; keyEnabled.state = .on; controlChanged() }
    @objc private func aggressiveKey() { tolerance.doubleValue = 0.65; soften.doubleValue = 0.06; choke.doubleValue = 0.15; spill.doubleValue = 0.72; keyEnabled.state = .on; controlChanged() }
    @objc private func keyframeZoom50() { commitQuickKeyframe(property: .scale, slider: scale, value: 0.5) }
    @objc private func keyframeZoom100() { commitQuickKeyframe(property: .scale, slider: scale, value: 1) }
    @objc private func keyframeZoom200() { commitQuickKeyframe(property: .scale, slider: scale, value: 2) }
    @objc private func keyframeOpacity0() { commitQuickKeyframe(property: .opacity, slider: opacity, value: 0) }
    @objc private func keyframeOpacity100() { commitQuickKeyframe(property: .opacity, slider: opacity, value: 1) }

    private func showEffect(_ kind: EffectsPanelKind, revealKeyframes: Bool = true) {
        selectedEffect = kind
        settingsTitleLabel.stringValue = kind.title
        settingsSummaryLabel.stringValue = hasClipSelection
            ? (isEffectActive(kind) || kind.isFixed ? kind.summary : "Not applied • \(kind.summary)")
            : "Select a timeline video clip to edit effects"
        for (cardKind, card) in effectCards { card.isHidden = cardKind != kind }
        for (rowKind, row) in browserRows {
            row.layer?.borderColor = (rowKind == kind ? NSColor.systemBlue.withAlphaComponent(0.9) : NSColor(hex: "28313E")).cgColor
            row.layer?.backgroundColor = (rowKind == kind ? NSColor(hex: "202C3C") : NSColor(hex: "191F28")).cgColor
        }
        refreshAppliedSelectionStyle()
        if let controlsScrollView {
            controlsScrollView.contentView.scroll(to: .zero)
            controlsScrollView.reflectScrolledClipView(controlsScrollView.contentView)
        }
        if revealKeyframes { select(kind.primaryProperty) }
    }

    private func activeEffectKinds() -> [EffectsPanelKind] {
        guard hasClipSelection else { return [] }
        var result: [EffectsPanelKind] = [.motion, .opacity]
        if isEffectActive(.ultraKey) { result.append(.ultraKey) }
        result += ClipEffects.normalizedOrder(workingEffectOrder).map(EffectsPanelKind.panel).filter(isEffectActive)
        if isEffectActive(.crop) { result.append(.crop) }
        return result
    }

    private func isEffectActive(_ kind: EffectsPanelKind) -> Bool {
        switch kind {
        case .motion, .opacity: return true
        case .ultraKey:
            return keyEnabled.state == .on || animatableProperties(for: kind).contains(where: hasKeyframes)
        case .crop:
            return cropLeft.doubleValue > 0.0001 || cropRight.doubleValue > 0.0001 || cropTop.doubleValue > 0.0001 || cropBottom.doubleValue > 0.0001 || animatableProperties(for: kind).contains(where: hasKeyframes)
        case .blur: return blur.doubleValue > 0.0001 || hasKeyframes(.blurRadius)
        case .sharpen: return sharpen.doubleValue > 0.0001 || hasKeyframes(.sharpenAmount)
        case .vignette: return vignette.doubleValue > 0.0001 || hasKeyframes(.vignetteIntensity)
        case .monochrome: return monochrome.doubleValue > 0.0001 || hasKeyframes(.monochromeAmount)
        case .sepia: return sepia.doubleValue > 0.0001 || hasKeyframes(.sepiaAmount)
        }
    }

    private func hasKeyframes(_ property: AnimatableProperty) -> Bool {
        loadedAnimation.channels.first(where: { $0.property == property })?.keyframes.isEmpty == false
    }

    private func activateEffect(_ kind: EffectsPanelKind) {
        switch kind {
        case .motion, .opacity: break
        case .ultraKey: keyEnabled.state = .on; keyColor.color = .green
        case .crop: cropLeft.doubleValue = 0.05; cropRight.doubleValue = 0.05
        case .blur: blur.doubleValue = 5
        case .sharpen: sharpen.doubleValue = 1
        case .vignette: vignette.doubleValue = 0.55
        case .monochrome: monochrome.doubleValue = 1
        case .sepia: sepia.doubleValue = 0.65
        }
        updateNumericFields()
    }

    private func resetControls(for kind: EffectsPanelKind) {
        switch kind {
        case .motion:
            positionX.doubleValue = 0; positionY.doubleValue = 0; scale.doubleValue = 1; rotation.doubleValue = 0
        case .opacity:
            opacity.doubleValue = 1; blendMode.selectItem(at: 0)
        case .ultraKey:
            loadUltraKey(UltraKeySettings())
        case .crop:
            cropLeft.doubleValue = 0; cropRight.doubleValue = 0; cropTop.doubleValue = 0; cropBottom.doubleValue = 0
        case .blur: blur.doubleValue = 0
        case .sharpen: sharpen.doubleValue = 0
        case .vignette: vignette.doubleValue = 0
        case .monochrome: monochrome.doubleValue = 0
        case .sepia: sepia.doubleValue = 0
        }
        updateNumericFields()
    }

    private func animatableProperties(for kind: EffectsPanelKind) -> [AnimatableProperty] {
        switch kind {
        case .motion: return [.positionX, .positionY, .scale, .rotation]
        case .opacity: return [.opacity]
        case .ultraKey: return [.ultraKeyTolerance, .ultraKeySoftness, .ultraKeyChoke, .ultraKeySpill]
        case .crop: return [.cropLeft, .cropRight, .cropTop, .cropBottom]
        default: return [kind.primaryProperty]
        }
    }

    private func moveAppliedEffect(_ kind: EffectsPanelKind, offset: Int) {
        guard kind.isReorderable else { return }
        let activeOrder = ClipEffects.normalizedOrder(workingEffectOrder).map(EffectsPanelKind.panel).filter(isEffectActive)
        guard let visibleIndex = activeOrder.firstIndex(of: kind) else { return }
        let destination = visibleIndex + offset
        guard activeOrder.indices.contains(destination),
              let sourceKind = kind.videoEffectKind,
              let targetKind = activeOrder[destination].videoEffectKind,
              let source = workingEffectOrder.firstIndex(of: sourceKind),
              let target = workingEffectOrder.firstIndex(of: targetKind) else { return }
        workingEffectOrder.swapAt(source, target)
        refreshAppliedEffects(force: true)
        showEffect(kind, revealKeyframes: false)
        onPreview?(values())
        keyframeLabel.stringValue = "Moved \(kind.title) \(offset < 0 ? "earlier" : "later") in the render stack."
    }

    private func refreshAppliedEffects(force: Bool = false) {
        let active = activeEffectKinds()
        for kind in EffectsPanelKind.allCases {
            let isActive = active.contains(kind)
            browserAddButtons[kind]?.title = kind.isFixed ? "Fixed" : (isActive ? "Added" : "+ Add")
            browserAddButtons[kind]?.isEnabled = hasClipSelection && !kind.isFixed && !isActive
        }
        settingsSummaryLabel.stringValue = hasClipSelection
            ? (isEffectActive(selectedEffect) || selectedEffect.isFixed ? selectedEffect.summary : "Not applied • \(selectedEffect.summary)")
            : "Select a timeline video clip to edit effects"
        guard force || active != displayedAppliedEffects else { return }
        displayedAppliedEffects = active
        appliedCountLabel.stringValue = hasClipSelection ? "\(max(0, active.count - 2)) effects • 2 fixed" : "No clip"
        appliedSelectionButtons.removeAll(); appliedMoveUpButtons.removeAll(); appliedMoveDownButtons.removeAll(); appliedRemoveButtons.removeAll()
        for child in appliedEffectsStack.arrangedSubviews { appliedEffectsStack.removeArrangedSubview(child); child.removeFromSuperview() }
        if !hasClipSelection {
            let empty = NSTextField(wrappingLabelWithString: "Select a video clip on the timeline. Its applied effects and controls will appear here.")
            empty.font = .systemFont(ofSize: 10); empty.textColor = NSColor(hex: "758195"); empty.alignment = .center; empty.maximumNumberOfLines = 4
            let holder = NSStackView(); holder.orientation = .vertical; holder.alignment = .width; holder.edgeInsets = NSEdgeInsets(top: 20, left: 12, bottom: 20, right: 12); holder.addArrangedSubview(empty)
            appliedEffectsStack.addArrangedSubview(holder); holder.widthAnchor.constraint(equalTo: appliedEffectsStack.widthAnchor).isActive = true
            return
        }
        let reorderableActive = active.filter(\.isReorderable)
        for kind in active {
            let row = makeAppliedRow(kind, reorderableIndex: reorderableActive.firstIndex(of: kind), reorderableCount: reorderableActive.count)
            appliedEffectsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: appliedEffectsStack.widthAnchor).isActive = true
        }
        refreshAppliedSelectionStyle()
    }

    private func setEditingEnabled(_ enabled: Bool) {
        func visit(_ node: NSView) {
            if let button = node as? NSButton { button.isEnabled = enabled }
            else if let slider = node as? NSSlider { slider.isEnabled = enabled }
            else if let popup = node as? NSPopUpButton { popup.isEnabled = enabled }
            else if let well = node as? NSColorWell { well.isEnabled = enabled }
            else if let field = node as? NSTextField, field.isEditable { field.isEnabled = enabled }
            node.subviews.forEach(visit)
        }
        visit(view)
    }

    private func makeAppliedRow(_ kind: EffectsPanelKind, reorderableIndex: Int?, reorderableCount: Int) -> NSView {
        let row = NSStackView(); row.identifier = NSUserInterfaceItemIdentifier("applied-\(kind.rawValue)"); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 3; row.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 5); row.wantsLayer = true; row.layer?.backgroundColor = NSColor(hex: "1B222C").cgColor; row.layer?.cornerRadius = 7; row.layer?.borderWidth = 1
        let handle = NSTextField(labelWithString: kind.isReorderable ? "≡" : "•"); handle.font = .systemFont(ofSize: 11, weight: .bold); handle.textColor = kind.isReorderable ? NSColor(hex: "79879A") : NSColor.systemGreen; handle.alignment = .center; handle.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let choose = NSButton(title: kind.title, target: self, action: #selector(selectAppliedEffect(_:))); choose.isBordered = false; choose.alignment = .left; choose.font = .systemFont(ofSize: 10, weight: .semibold); choose.contentTintColor = NSColor(hex: "D5DCE7"); appliedSelectionButtons[ObjectIdentifier(choose)] = kind
        row.addArrangedSubview(handle); row.addArrangedSubview(choose); row.addArrangedSubview(NSView())
        if let index = reorderableIndex {
            let up = compactButton("↑", #selector(moveAppliedEffectUp(_:))); up.isEnabled = index > 0; appliedMoveUpButtons[ObjectIdentifier(up)] = kind; row.addArrangedSubview(up)
            let down = compactButton("↓", #selector(moveAppliedEffectDown(_:))); down.isEnabled = index < reorderableCount - 1; appliedMoveDownButtons[ObjectIdentifier(down)] = kind; row.addArrangedSubview(down)
        } else if kind.isFixed {
            let badge = NSTextField(labelWithString: "FIXED"); badge.font = .monospacedSystemFont(ofSize: 7, weight: .bold); badge.textColor = NSColor(hex: "718096"); row.addArrangedSubview(badge)
        }
        if !kind.isFixed {
            let remove = compactButton("×", #selector(removeAppliedEffect(_:))); remove.toolTip = "Remove \(kind.title) and its keyframes"; remove.contentTintColor = NSColor.systemRed; appliedRemoveButtons[ObjectIdentifier(remove)] = kind; row.addArrangedSubview(remove)
        }
        return row
    }

    private func refreshAppliedSelectionStyle() {
        for row in appliedEffectsStack.arrangedSubviews {
            let isSelected = row.identifier?.rawValue == "applied-\(selectedEffect.rawValue)"
            row.layer?.borderColor = (isSelected ? NSColor.systemBlue.withAlphaComponent(0.9) : NSColor(hex: "29323E")).cgColor
            row.layer?.backgroundColor = (isSelected ? NSColor(hex: "213049") : NSColor(hex: "1B222C")).cgColor
        }
    }

    private func commitQuickKeyframe(property: AnimatableProperty, slider: NSSlider, value: Double) {
        pendingAutoKeyframe?.cancel()
        slider.doubleValue = value
        controlChanged()
        select(property)
        addKeyframe()
    }

    private func scheduleAutoKeyframe(for property: AnimatableProperty) {
        guard autoKeyButton.state == .on else { return }
        pendingAutoKeyframe?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.select(property)
            self.onKeyframe?(self.values(), property, self.selectedCurve)
            self.keyframeLabel.stringValue = "Auto keyframed \(property.title) at \(self.keyframeTimeLabel.stringValue)."
        }
        pendingAutoKeyframe = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func holdPlayheadControlUpdates() {
        isEditingControl = true
        resumePlayheadControlUpdates?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.isEditingControl = false }
        resumePlayheadControlUpdates = work
        // Continuous NSSlider actions arrive throughout the drag, so this
        // delay starts after the last movement rather than after mouse-down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func seekAdjacent(forward: Bool) {
        guard let channel = loadedAnimation.channels.first(where: { $0.property == selectedProperty }) else {
            keyframeLabel.stringValue = "No \(selectedProperty.title) keyframes yet."
            return
        }
        let times = channel.keyframes.map(\.time).sorted()
        let destination = forward ? times.first(where: { $0 > localPlayhead + 1.0 / 60.0 }) : times.last(where: { $0 < localPlayhead - 1.0 / 60.0 })
        guard let destination else { keyframeLabel.stringValue = forward ? "Already at the last keyframe." : "Already at the first keyframe."; return }
        localPlayhead = destination; grid.update(playhead: destination); onSeekLocalTime?(destination)
        updateKeyframeTimeLabel()
        keyframeLabel.stringValue = "\(selectedProperty.title) • \(String(format: "%.2f s", destination))"
    }
    private func select(_ property: AnimatableProperty) { propertyPicker.selectItem(at: properties.firstIndex(of: property) ?? 0); gridSelectionChanged() }
    private func gridSelectionChanged() {
        grid.selectProperty(selectedProperty)
        revealSelectedProperty()
    }

    private func revealSelectedProperty() {
        guard let scroll = gridScrollView,
              let row = properties.firstIndex(of: selectedProperty) else { return }
        let rowTop = CGFloat(30 + row * 34)
        let rowBottom = rowTop + 34
        let visible = scroll.contentView.bounds
        var destinationY = visible.origin.y
        if rowTop < visible.minY { destinationY = rowTop }
        else if rowBottom > visible.maxY { destinationY = rowBottom - visible.height }
        let maximumY = max(0, grid.bounds.height - visible.height)
        scroll.contentView.scroll(to: NSPoint(x: visible.origin.x, y: min(maximumY, max(0, destinationY))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func setGridZoom(_ zoom: CGFloat) {
        gridZoomScale = min(12, max(1, zoom))
        gridZoomLabel.stringValue = gridZoomScale <= 1.001 ? "Fit" : "\(Int((gridZoomScale * 100).rounded()))%"
        updateGridWidth(revealPlayhead: true)
    }
    private func updateGridWidth(revealPlayhead: Bool) {
        guard let scroll = gridScrollView else { return }
        let viewportWidth = max(520, scroll.contentSize.width)
        grid.setZoomScale(gridZoomScale)
        gridWidthConstraint?.constant = grid.preferredWidth(for: viewportWidth)
        view.layoutSubtreeIfNeeded()
        guard revealPlayhead else { return }
        if gridZoomScale <= 1.001 {
            scroll.contentView.scroll(to: .zero)
        } else {
            let width = gridWidthConstraint?.constant ?? viewportWidth
            let x = 164 + CGFloat(min(loadedDuration, max(0, localPlayhead)) / max(1.0 / 30.0, loadedDuration)) * max(40, width - 176)
            let maxX = max(0, width - scroll.contentSize.width)
            scroll.contentView.scroll(to: NSPoint(x: min(maxX, max(0, x - scroll.contentSize.width / 2)), y: scroll.contentView.bounds.origin.y))
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func updateKeyframeTimeLabel() {
        let frames = Int((max(0, localPlayhead) * 30).rounded())
        keyframeTimeLabel.stringValue = String(format: "%02d:%02d:%02d", frames / 1800, (frames / 30) % 60, frames % 30)
    }

    private func refreshKeyframeIndicators() {
        let tolerance = 1.0 / 60.0
        for item in keyframeButtons {
            let frames = loadedAnimation.channels.first(where: { $0.property == item.property })?.keyframes ?? []
            let isOnKeyframe = frames.contains { abs($0.time - localPlayhead) < tolerance }
            item.button.title = isOnKeyframe ? "◆" : "◇"
            item.button.contentTintColor = isOnKeyframe
                ? .systemOrange
                : (frames.isEmpty ? NSColor(hex: "697382") : NSColor(hex: "D59A45"))
            item.button.toolTip = isOnKeyframe
                ? "A \(item.property.title) keyframe exists at this playhead"
                : (frames.isEmpty
                    ? "Add a \(item.property.title) keyframe at the playhead"
                    : "\(frames.count) \(item.property.title) keyframe\(frames.count == 1 ? "" : "s"); add another at the playhead")
        }
    }

    @objc private func filterChanged() {
        let query = searchField.stringValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for (kind, row) in browserRows { row.isHidden = !query.isEmpty && !kind.keywords.contains(query) }
    }

    private func effectCard(_ title: String, subtitle: String, controls: [NSView]) -> NSStackView {
        let card = NSStackView(); card.orientation = .vertical; card.alignment = .width; card.spacing = 8; card.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 13, right: 12); card.wantsLayer = true; card.layer?.backgroundColor = NSColor(hex: "1B212A").cgColor; card.layer?.cornerRadius = 9; card.layer?.borderColor = NSColor(hex: "2C3542").cgColor; card.layer?.borderWidth = 1
        let heading = NSTextField(labelWithString: "▾  \(title)"); heading.font = .systemFont(ofSize: 11, weight: .bold); heading.textColor = .white
        let detail = NSTextField(labelWithString: subtitle); detail.font = .systemFont(ofSize: 9); detail.textColor = NSColor(hex: "8893A4")
        card.addArrangedSubview(heading); card.addArrangedSubview(detail); controls.forEach { card.addArrangedSubview($0) }; return card
    }
    private func parameterRow(_ title: String, _ slider: NSSlider, scale displayScale: Double = 1, suffix: String = "", property: AnimatableProperty? = nil) -> NSStackView {
        slider.target = self; slider.action = #selector(sliderChanged(_:)); slider.isContinuous = true
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 7
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 10, weight: .medium); label.textColor = NSColor(hex: "CFD5DF"); label.widthAnchor.constraint(equalToConstant: 102).isActive = true
        let keyframe = NSButton(title: property == nil ? "·" : "◇", target: self, action: #selector(quickKeyframe(_:))); keyframe.isBordered = false; keyframe.font = .systemFont(ofSize: 13, weight: .bold); keyframe.contentTintColor = property == nil ? NSColor(hex: "4C5666") : .systemOrange; keyframe.widthAnchor.constraint(equalToConstant: 18).isActive = true; keyframe.isEnabled = property != nil
        if let property {
            keyframeButtonProperties[ObjectIdentifier(keyframe)] = property
            keyframeButtons.append((keyframe, property))
            sliderProperties[ObjectIdentifier(slider)] = property
            keyframe.toolTip = "Add or update a \(property.title) keyframe at the playhead"
        }
        let field = NSTextField(string: ""); field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); field.alignment = .right; field.target = self; field.action = #selector(numericChanged(_:)); field.widthAnchor.constraint(equalToConstant: 66).isActive = true
        row.addArrangedSubview(keyframe); row.addArrangedSubview(label); row.addArrangedSubview(slider); row.addArrangedSubview(field)
        numericFields[ObjectIdentifier(slider)] = (field, slider, displayScale, suffix); fieldToSlider[ObjectIdentifier(field)] = (slider, displayScale)
        return row
    }
    private func popupRow(_ title: String, _ popup: NSPopUpButton) -> NSStackView { let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 10, weight: .medium); label.textColor = NSColor(hex: "CFD5DF"); label.widthAnchor.constraint(equalToConstant: 124).isActive = true; row.addArrangedSubview(label); row.addArrangedSubview(popup); return row }
    private func colorRow() -> NSStackView { let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; let label = NSTextField(labelWithString: "Key Color"); label.font = .systemFont(ofSize: 10, weight: .medium); label.textColor = NSColor(hex: "CFD5DF"); label.widthAnchor.constraint(equalToConstant: 124).isActive = true; row.addArrangedSubview(label); row.addArrangedSubview(keyColor); row.addArrangedSubview(makeButton("Eyedropper…", #selector(sampleKeyColor))); row.addArrangedSubview(NSView()); return row }
    @objc private func sampleKeyColor() {
        let sampler = NSColorSampler(); colorSampler = sampler
        sampler.show { [weak self] color in
            guard let self else { return }
            if let color { self.keyColor.color = color; self.keyEnabled.state = .on; self.controlChanged() }
            self.colorSampler = nil
        }
    }
    private func addSubheading(_ text: String, to stack: NSStackView) { let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 9, weight: .bold); label.textColor = NSColor(hex: "7FA9FF"); stack.addArrangedSubview(label) }
    private func updateNumericFields() { for entry in numericFields.values { entry.field.stringValue = String(format: "%.1f\(entry.suffix)", entry.slider.doubleValue * entry.scale) } }
    private func scrollingView(_ document: NSView) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), document.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }
    private func makeButton(_ title: String, _ action: Selector) -> NSButton { let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 10, weight: .medium); return button }
    private func compactButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .inline; button.font = .systemFont(ofSize: 10, weight: .bold); button.widthAnchor.constraint(equalToConstant: 22).isActive = true; button.heightAnchor.constraint(equalToConstant: 22).isActive = true; return button
    }
    private func quickActionRow(_ actions: [(String, Selector)]) -> NSStackView {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 6
        for (title, action) in actions {
            let button = makeButton(title, action); button.contentTintColor = .systemOrange; row.addArrangedSubview(button)
        }
        row.addArrangedSubview(NSView())
        return row
    }
    private func dividerView(height: CGFloat) -> NSView {
        let line = NSView(); line.wantsLayer = true; line.layer?.backgroundColor = NSColor(hex: "343C49").cgColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: height).isActive = true
        return line
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
