import Cocoa

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
    private var hitDiamonds: [(property: AnimatableProperty, id: UUID, rect: NSRect)] = []
    private var draggedKeyframe: (property: AnimatableProperty, id: UUID)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var preferredHeight: CGFloat { rulerHeight + CGFloat(max(1, properties.count)) * rowHeight + 2 }

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
        let majorStep = duration <= 10 ? 1.0 : (duration <= 60 ? 5.0 : 10.0)
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
                let hit = NSRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
                hitDiamonds.append((property, frame.id, hit))
                let diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: point.x, y: point.y - 5)); diamond.line(to: NSPoint(x: point.x + 5, y: point.y)); diamond.line(to: NSPoint(x: point.x, y: point.y + 5)); diamond.line(to: NSPoint(x: point.x - 5, y: point.y)); diamond.close()
                (property == selectedProperty ? NSColor.systemOrange : NSColor(hex: "D59A45")).setFill(); diamond.fill()
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
    private func formatTime(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

final class EffectsStudioViewController: NSViewController {
    var onPreview: ((EffectControlValues) -> Void)?
    var onApplyTransform: ((EffectControlValues) -> Void)?
    var onApplyEffects: ((EffectControlValues) -> Void)?
    var onApplyAll: ((EffectControlValues) -> Void)?
    var onKeyframe: ((EffectControlValues, AnimatableProperty, KeyframeInterpolation) -> Void)?
    var onRemoveKeyframe: ((EffectControlValues, AnimatableProperty) -> Void)?
    var onClearKeyframes: ((EffectControlValues, AnimatableProperty) -> Void)?
    var onMoveKeyframe: ((AnimatableProperty, UUID, Double) -> Void)?
    var onSeekLocalTime: ((Double) -> Void)?
    var onOverlayOptions: ((Bool, Bool, Bool) -> Void)?
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
    private let grid = EffectsKeyframeGridView()
    private var gridHeightConstraint: NSLayoutConstraint?
    private var sections: [(keywords: String, view: NSView)] = []
    private var loadedAnimation = ClipAnimation()
    private var localPlayhead = 0.0
    private var numericFields: [ObjectIdentifier: (field: NSTextField, slider: NSSlider, scale: Double, suffix: String)] = [:]
    private var fieldToSlider: [ObjectIdentifier: (slider: NSSlider, scale: Double)] = [:]

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
        view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = NSColor(hex: "171B22").cgColor
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .width; root.spacing = 10; root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14); root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor), root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor)])

        let header = NSStackView(); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 10
        let title = NSTextField(labelWithString: "EFFECT CONTROLS"); title.font = .systemFont(ofSize: 16, weight: .bold); title.textColor = .white
        selectionLabel.font = .systemFont(ofSize: 11, weight: .medium); selectionLabel.textColor = .secondaryLabelColor; selectionLabel.lineBreakMode = .byTruncatingMiddle
        searchField.placeholderString = "Search effects and properties"; searchField.target = self; searchField.action = #selector(filterChanged)
        header.addArrangedSubview(title); header.addArrangedSubview(selectionLabel); header.addArrangedSubview(NSView()); header.addArrangedSubview(searchField); searchField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        root.addArrangedSubview(header)

        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let controls = makeControlsPane(); controls.widthAnchor.constraint(greaterThanOrEqualToConstant: 410).isActive = true
        let keyframes = makeKeyframePane(); keyframes.widthAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true
        split.addArrangedSubview(controls); split.addArrangedSubview(keyframes); split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        root.addArrangedSubview(split)

        let actions = NSStackView(); actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 8
        let fitNote = NSTextField(labelWithString: "Fit to frame is the 100% starting size for every video and rendered 3D clip."); fitNote.font = .systemFont(ofSize: 10); fitNote.textColor = NSColor(hex: "8F99A9")
        actions.addArrangedSubview(fitNote); actions.addArrangedSubview(NSView())
        actions.addArrangedSubview(makeButton("Revert Preview", #selector(revertPreview)))
        actions.addArrangedSubview(makeButton("Reset Selected", #selector(reset)))
        let apply = makeButton("Apply Changes", #selector(applyAll)); apply.contentTintColor = .systemBlue; actions.addArrangedSubview(apply)
        root.addArrangedSubview(actions)
        showGrid.state = .on; showBounds.state = .on
        DispatchQueue.main.async { [weak self] in self?.overlaysChanged() }
    }

    override func viewDidDisappear() { super.viewDidDisappear(); onCancelPreview?() }

    private func makeControlsPane() -> NSView {
        let document = NSStackView(); document.orientation = .vertical; document.alignment = .width; document.spacing = 9; document.translatesAutoresizingMaskIntoConstraints = false
        let motion = effectCard("MOTION", subtitle: "Automatic Fit → user transform", controls: [
            parameterRow("Position X", positionX), parameterRow("Position Y", positionY), parameterRow("Scale", scale, scale: 100, suffix: "%"), parameterRow("Rotation", rotation, suffix: "°")
        ]); addSection("motion transform position scale rotation", motion, to: document)

        ClipBlendMode.allCases.forEach { blendMode.addItem(withTitle: $0.title) }
        blendMode.target = self; blendMode.action = #selector(controlChanged)
        let opacityCard = effectCard("OPACITY", subtitle: "Fixed effect • composited after Motion", controls: [parameterRow("Opacity", opacity, scale: 100, suffix: "%"), popupRow("Blend Mode", blendMode)])
        addSection("opacity blend composite", opacityCard, to: document)

        let crop = effectCard("CROP", subtitle: "Transparent edge crop", controls: [parameterRow("Left", cropLeft, scale: 100, suffix: "%"), parameterRow("Right", cropRight, scale: 100, suffix: "%"), parameterRow("Top", cropTop, scale: 100, suffix: "%"), parameterRow("Bottom", cropBottom, scale: 100, suffix: "%")])
        addSection("crop left right top bottom", crop, to: document)

        let ultraStack = NSStackView(); ultraStack.orientation = .vertical; ultraStack.alignment = .width; ultraStack.spacing = 7
        keyEnabled.target = self; keyEnabled.action = #selector(controlChanged); ultraStack.addArrangedSubview(keyEnabled)
        UltraKeyOutputMode.allCases.forEach { keyOutput.addItem(withTitle: $0.title) }; keyOutput.target = self; keyOutput.action = #selector(controlChanged); ultraStack.addArrangedSubview(popupRow("Output", keyOutput))
        keyColor.target = self; keyColor.action = #selector(controlChanged); ultraStack.addArrangedSubview(colorRow())
        let presets = NSStackView(); presets.orientation = .horizontal; presets.spacing = 6; presets.addArrangedSubview(makeButton("Green Screen", #selector(greenScreen))); presets.addArrangedSubview(makeButton("Blue Screen", #selector(blueScreen))); presets.addArrangedSubview(makeButton("Relaxed", #selector(relaxedKey))); presets.addArrangedSubview(makeButton("Aggressive", #selector(aggressiveKey))); ultraStack.addArrangedSubview(presets)
        addSubheading("MATTE GENERATION", to: ultraStack)
        [parameterRow("Transparency", transparency, scale: 100, suffix: "%"), parameterRow("Highlight", highlight, scale: 100, suffix: "%"), parameterRow("Shadow", shadow, scale: 100, suffix: "%"), parameterRow("Tolerance", tolerance, scale: 100, suffix: "%"), parameterRow("Pedestal", pedestal, scale: 100, suffix: "%")].forEach { ultraStack.addArrangedSubview($0) }
        addSubheading("MATTE CLEANUP", to: ultraStack)
        [parameterRow("Choke", choke, scale: 100, suffix: "%"), parameterRow("Soften", soften, scale: 100, suffix: "%"), parameterRow("Contrast", matteContrast, scale: 100, suffix: "%"), parameterRow("Mid Point", midpoint, scale: 100, suffix: "%")].forEach { ultraStack.addArrangedSubview($0) }
        addSubheading("SPILL SUPPRESSION", to: ultraStack)
        [parameterRow("Desaturate", desaturate, scale: 100, suffix: "%"), parameterRow("Range", spillRange, scale: 100, suffix: "%"), parameterRow("Spill", spill, scale: 100, suffix: "%"), parameterRow("Luma", luma, scale: 100, suffix: "%")].forEach { ultraStack.addArrangedSubview($0) }
        addSubheading("COLOR CORRECTION", to: ultraStack)
        [parameterRow("Saturation", keySaturation, scale: 100, suffix: "%"), parameterRow("Hue", keyHue, suffix: "°"), parameterRow("Luminance", keyLuminance, scale: 100, suffix: "%")].forEach { ultraStack.addArrangedSubview($0) }
        let ultra = effectCard("ULTRA KEY", subtitle: "Native chroma matte, cleanup and despill", controls: [ultraStack]); addSection("ultra key green blue chroma matte spill color", ultra, to: document)

        let looks = effectCard("VIDEO EFFECTS", subtitle: "GPU-backed Core Image effects", controls: [parameterRow("Gaussian Blur", blur), parameterRow("Sharpen", sharpen), parameterRow("Vignette", vignette), parameterRow("Monochrome", monochrome, scale: 100, suffix: "%"), parameterRow("Sepia", sepia, scale: 100, suffix: "%")])
        addSection("video effects blur sharpen vignette monochrome sepia", looks, to: document)

        return scrollingView(document)
    }

    private func makeKeyframePane() -> NSView {
        let pane = NSStackView(); pane.orientation = .vertical; pane.alignment = .width; pane.spacing = 8; pane.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10); pane.wantsLayer = true; pane.layer?.backgroundColor = NSColor(hex: "14181F").cgColor
        let heading = NSTextField(labelWithString: "CLIP KEYFRAME TIMELINE"); heading.font = .systemFont(ofSize: 11, weight: .bold); heading.textColor = NSColor(hex: "AAB4C4"); pane.addArrangedSubview(heading)
        let overlays = NSStackView(); overlays.orientation = .horizontal; overlays.spacing = 8
        [showGrid, showSafe, showBounds].forEach { $0.target = self; $0.action = #selector(overlaysChanged); overlays.addArrangedSubview($0) }
        overlays.addArrangedSubview(NSView()); pane.addArrangedSubview(overlays)

        let gridScroll = NSScrollView(); gridScroll.drawsBackground = false; gridScroll.hasVerticalScroller = true; gridScroll.autohidesScrollers = true; grid.translatesAutoresizingMaskIntoConstraints = false; gridScroll.documentView = grid
        NSLayoutConstraint.activate([grid.leadingAnchor.constraint(equalTo: gridScroll.contentView.leadingAnchor), grid.trailingAnchor.constraint(equalTo: gridScroll.contentView.trailingAnchor), grid.topAnchor.constraint(equalTo: gridScroll.contentView.topAnchor), grid.widthAnchor.constraint(equalTo: gridScroll.contentView.widthAnchor)])
        gridHeightConstraint = grid.heightAnchor.constraint(equalToConstant: grid.preferredHeight); gridHeightConstraint?.isActive = true
        pane.addArrangedSubview(gridScroll)

        properties.forEach { propertyPicker.addItem(withTitle: $0.title) }; propertyPicker.target = self; propertyPicker.action = #selector(propertyChanged)
        [KeyframeInterpolation.easeInOut, .linear, .hold].forEach { curvePicker.addItem(withTitle: $0 == .easeInOut ? "Ease In / Out" : $0.rawValue.capitalized) }
        let selectors = NSStackView(); selectors.orientation = .horizontal; selectors.spacing = 8; selectors.addArrangedSubview(propertyPicker); selectors.addArrangedSubview(curvePicker); pane.addArrangedSubview(selectors)
        let keyActions = NSStackView(); keyActions.orientation = .horizontal; keyActions.spacing = 6
        keyActions.addArrangedSubview(makeButton("◀ Previous", #selector(previousKeyframe)))
        let add = makeButton("◆ Add / Update", #selector(addKeyframe)); add.contentTintColor = .systemOrange; keyActions.addArrangedSubview(add)
        keyActions.addArrangedSubview(makeButton("Next ▶", #selector(nextKeyframe)))
        keyActions.addArrangedSubview(makeButton("Remove Here", #selector(removeKeyframe)))
        keyActions.addArrangedSubview(makeButton("Clear Property", #selector(clearKeyframes)))
        pane.addArrangedSubview(keyActions)
        keyframeLabel.font = .systemFont(ofSize: 10); keyframeLabel.textColor = .secondaryLabelColor; keyframeLabel.maximumNumberOfLines = 4; pane.addArrangedSubview(keyframeLabel)

        grid.onSeek = { [weak self] time in self?.localPlayhead = time; self?.onSeekLocalTime?(time) }
        grid.onSelectProperty = { [weak self] property in self?.select(property) }
        grid.onMoveKeyframe = { [weak self] property, id, time in self?.onMoveKeyframe?(property, id, time) }
        return pane
    }

    func load(_ values: EffectControlValues, selectionName: String, property: AnimatableProperty, interpolation: KeyframeInterpolation, keyframeText: String) {
        load(values, selectionName: selectionName, property: property, interpolation: interpolation, keyframeText: keyframeText, clip: nil, timelineTime: 0)
    }

    func load(_ values: EffectControlValues, selectionName: String, property: AnimatableProperty, interpolation: KeyframeInterpolation, keyframeText: String, clip: TimelineClip?, timelineTime: Double) {
        selectionLabel.stringValue = "Selected: \(selectionName)"; keyframeLabel.stringValue = keyframeText
        positionX.doubleValue = values.transform.positionX; positionY.doubleValue = values.transform.positionY; scale.doubleValue = values.transform.scale; rotation.doubleValue = values.transform.rotation; opacity.doubleValue = values.transform.opacity
        blur.doubleValue = values.effects.blurRadius; sharpen.doubleValue = values.effects.sharpenAmount; vignette.doubleValue = values.effects.vignetteIntensity; monochrome.doubleValue = values.effects.monochromeAmount; sepia.doubleValue = values.effects.sepiaAmount
        cropLeft.doubleValue = values.effects.crop.left; cropRight.doubleValue = values.effects.crop.right; cropTop.doubleValue = values.effects.crop.top; cropBottom.doubleValue = values.effects.crop.bottom
        blendMode.selectItem(at: ClipBlendMode.allCases.firstIndex(of: values.effects.blendMode) ?? 0)
        loadUltraKey(values.effects.ultraKey)
        propertyPicker.selectItem(at: properties.firstIndex(of: property) ?? 0)
        curvePicker.selectItem(at: [KeyframeInterpolation.easeInOut, .linear, .hold].firstIndex(of: interpolation) ?? 0)
        updateNumericFields()
        let local = clip.map { $0.localTime(at: timelineTime) } ?? 0
        let clipDuration = clip.map { max(1.0 / 30.0, $0.outPoint - $0.inPoint) } ?? 1
        loadedAnimation = clip?.animation ?? .init(); localPlayhead = local
        grid.load(properties: properties, animation: clip?.animation ?? .init(), duration: clipDuration, playhead: local, selectedProperty: selectedProperty)
        gridHeightConstraint?.constant = grid.preferredHeight
    }

    func updatePlayhead(localTime: Double) { localPlayhead = localTime; grid.update(playhead: localTime) }

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
        var key = UltraKeySettings(); key.enabled = keyEnabled.state == .on; key.output = UltraKeyOutputMode.allCases[safe: keyOutput.indexOfSelectedItem] ?? .composite
        if let color = keyColor.color.usingColorSpace(.deviceRGB) { key.keyRed = color.redComponent; key.keyGreen = color.greenComponent; key.keyBlue = color.blueComponent }
        key.transparency = transparency.doubleValue; key.highlight = highlight.doubleValue; key.shadow = shadow.doubleValue; key.tolerance = tolerance.doubleValue; key.pedestal = pedestal.doubleValue
        key.choke = choke.doubleValue; key.soften = soften.doubleValue; key.matteContrast = matteContrast.doubleValue; key.midpoint = midpoint.doubleValue
        key.desaturate = desaturate.doubleValue; key.spillRange = spillRange.doubleValue; key.spill = spill.doubleValue; key.luma = luma.doubleValue
        key.saturation = keySaturation.doubleValue; key.hueDegrees = keyHue.doubleValue; key.luminance = keyLuminance.doubleValue; value.effects.ultraKey = key
        return value
    }

    private var selectedProperty: AnimatableProperty { properties[safe: propertyPicker.indexOfSelectedItem] ?? .opacity }
    private var selectedCurve: KeyframeInterpolation { [KeyframeInterpolation.easeInOut, .linear, .hold][safe: curvePicker.indexOfSelectedItem] ?? .easeInOut }

    @objc private func controlChanged() { updateNumericFields(); onPreview?(values()) }
    @objc private func numericChanged(_ sender: NSTextField) {
        guard let mapping = fieldToSlider[ObjectIdentifier(sender)] else { return }
        mapping.slider.doubleValue = sender.doubleValue / mapping.scale; controlChanged()
    }
    @objc private func propertyChanged() { gridSelectionChanged() }
    @objc private func addKeyframe() { onKeyframe?(values(), selectedProperty, selectedCurve); keyframeLabel.stringValue = "Keyframe added or updated at the program playhead." }
    @objc private func removeKeyframe() { onRemoveKeyframe?(values(), selectedProperty); keyframeLabel.stringValue = "Removed the keyframe at the program playhead." }
    @objc private func clearKeyframes() { onClearKeyframes?(values(), selectedProperty); keyframeLabel.stringValue = "Cleared \(selectedProperty.title) keyframes." }
    @objc private func previousKeyframe() { seekAdjacent(forward: false) }
    @objc private func nextKeyframe() { seekAdjacent(forward: true) }
    @objc private func applyAll() { onApplyAll?(values()) }
    @objc private func revertPreview() { onCancelPreview?() }
    @objc private func reset() { let fresh = EffectControlValues(); load(fresh, selectionName: selectionLabel.stringValue.replacingOccurrences(of: "Selected: ", with: ""), property: selectedProperty, interpolation: selectedCurve, keyframeText: "Effects and transform reset."); onReset?() }
    @objc private func overlaysChanged() { onOverlayOptions?(showGrid.state == .on, showSafe.state == .on, showBounds.state == .on) }
    @objc private func greenScreen() { keyColor.color = .green; keyEnabled.state = .on; controlChanged() }
    @objc private func blueScreen() { keyColor.color = .blue; keyEnabled.state = .on; controlChanged() }
    @objc private func relaxedKey() { tolerance.doubleValue = 0.38; soften.doubleValue = 0.12; spill.doubleValue = 0.35; pedestal.doubleValue = 0.05; keyEnabled.state = .on; controlChanged() }
    @objc private func aggressiveKey() { tolerance.doubleValue = 0.65; soften.doubleValue = 0.06; choke.doubleValue = 0.15; spill.doubleValue = 0.72; keyEnabled.state = .on; controlChanged() }

    private func seekAdjacent(forward: Bool) {
        guard let channel = loadedAnimation.channels.first(where: { $0.property == selectedProperty }) else {
            keyframeLabel.stringValue = "No \(selectedProperty.title) keyframes yet."
            return
        }
        let times = channel.keyframes.map(\.time).sorted()
        let destination = forward ? times.first(where: { $0 > localPlayhead + 1.0 / 60.0 }) : times.last(where: { $0 < localPlayhead - 1.0 / 60.0 })
        guard let destination else { keyframeLabel.stringValue = forward ? "Already at the last keyframe." : "Already at the first keyframe."; return }
        localPlayhead = destination; grid.update(playhead: destination); onSeekLocalTime?(destination)
        keyframeLabel.stringValue = "\(selectedProperty.title) • \(String(format: "%.2f s", destination))"
    }
    private func select(_ property: AnimatableProperty) { propertyPicker.selectItem(at: properties.firstIndex(of: property) ?? 0); gridSelectionChanged() }
    private func gridSelectionChanged() { grid.selectProperty(selectedProperty) }

    @objc private func filterChanged() {
        let query = searchField.stringValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for section in sections { section.view.isHidden = !query.isEmpty && !section.keywords.contains(query) }
    }

    private func addSection(_ keywords: String, _ section: NSView, to document: NSStackView) { sections.append((keywords, section)); document.addArrangedSubview(section) }
    private func effectCard(_ title: String, subtitle: String, controls: [NSView]) -> NSStackView {
        let card = NSStackView(); card.orientation = .vertical; card.alignment = .width; card.spacing = 7; card.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 12, right: 12); card.wantsLayer = true; card.layer?.backgroundColor = NSColor(hex: "222832").cgColor; card.layer?.cornerRadius = 8
        let heading = NSTextField(labelWithString: "▾  \(title)"); heading.font = .systemFont(ofSize: 11, weight: .bold); heading.textColor = .white
        let detail = NSTextField(labelWithString: subtitle); detail.font = .systemFont(ofSize: 9); detail.textColor = NSColor(hex: "8893A4")
        card.addArrangedSubview(heading); card.addArrangedSubview(detail); controls.forEach { card.addArrangedSubview($0) }; return card
    }
    private func parameterRow(_ title: String, _ slider: NSSlider, scale displayScale: Double = 1, suffix: String = "") -> NSStackView {
        slider.target = self; slider.action = #selector(controlChanged); slider.isContinuous = true
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 7
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 10, weight: .medium); label.textColor = NSColor(hex: "CFD5DF"); label.widthAnchor.constraint(equalToConstant: 102).isActive = true
        let stopwatch = NSTextField(labelWithString: "◷"); stopwatch.font = .systemFont(ofSize: 12); stopwatch.textColor = NSColor(hex: "73809A"); stopwatch.widthAnchor.constraint(equalToConstant: 15).isActive = true
        let field = NSTextField(string: ""); field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); field.alignment = .right; field.target = self; field.action = #selector(numericChanged(_:)); field.widthAnchor.constraint(equalToConstant: 66).isActive = true
        row.addArrangedSubview(stopwatch); row.addArrangedSubview(label); row.addArrangedSubview(slider); row.addArrangedSubview(field)
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
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
