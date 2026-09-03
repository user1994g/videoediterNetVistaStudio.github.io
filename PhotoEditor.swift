import Cocoa
import CoreImage
import UniformTypeIdentifiers

private final class PhotoFlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class PhotoTrackedSlider: NSSlider {
    var onTrackingBegan: (() -> Void)?
    var onTrackingEnded: (() -> Void)?
    private(set) var isMouseTracking = false
    override func mouseDown(with event: NSEvent) {
        isMouseTracking = true
        onTrackingBegan?()
        super.mouseDown(with: event)
        isMouseTracking = false
        onTrackingEnded?()
    }
}

private struct PhotoAdjustments {
    var exposure = 0.0
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var vibrance = 0.0
    var highlights = 1.0
    var shadows = 0.0
    var temperature = 6500.0
    var tint = 0.0
    var sharpen = 0.0
    var blur = 0.0
    var sepia = 0.0
    var vignette = 0.0
    var mirrored = false
}

private enum PhotoBlendMode: String, CaseIterable {
    case normal = "Normal"
    case multiply = "Multiply"
    case screen = "Screen"
    case overlay = "Overlay"
    case softLight = "Soft Light"
    case darken = "Darken"
    case lighten = "Lighten"
    case colorDodge = "Color Dodge"

    var filterName: String {
        switch self {
        case .normal: return "CISourceOverCompositing"
        case .multiply: return "CIMultiplyBlendMode"
        case .screen: return "CIScreenBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        case .darken: return "CIDarkenBlendMode"
        case .lighten: return "CILightenBlendMode"
        case .colorDodge: return "CIColorDodgeBlendMode"
        }
    }
}

private final class PhotoLayer {
    let id: UUID
    var name: String
    let sourceURL: URL?
    let sourceImage: CIImage
    let thumbnail: NSImage?
    var isVisible = true
    var isLocked = false
    var opacity = 1.0
    var blendMode = PhotoBlendMode.normal
    var position = CGPoint.zero
    var scale = 1.0
    var rotation = 0.0
    var adjustments = PhotoAdjustments()

    init(id: UUID = UUID(), name: String, sourceURL: URL?, sourceImage: CIImage, thumbnail: NSImage?) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.sourceImage = sourceImage
        self.thumbnail = thumbnail
    }
}

private struct PhotoLayerSnapshot {
    let id: UUID
    let name: String
    let sourceURL: URL?
    let sourceImage: CIImage
    let thumbnail: NSImage?
    let isVisible: Bool
    let isLocked: Bool
    let opacity: Double
    let blendMode: PhotoBlendMode
    let position: CGPoint
    let scale: Double
    let rotation: Double
    let adjustments: PhotoAdjustments
}

private struct PhotoDocumentSnapshot {
    let layers: [PhotoLayerSnapshot]
    let selectedLayerID: UUID?
    let documentSize: CGSize
    let documentName: String
}

private enum PhotoTool: Int, CaseIterable {
    case move, marquee, hand, zoom

    var title: String {
        switch self {
        case .move: return "Move Tool"
        case .marquee: return "Rectangular Select"
        case .hand: return "Hand Tool"
        case .zoom: return "Zoom Tool"
        }
    }

    var hint: String {
        switch self {
        case .move: return "Drag the selected unlocked layer on the canvas"
        case .marquee: return "Drag to create a non-destructive canvas selection"
        case .hand: return "Drag to navigate the canvas"
        case .zoom: return "Click to zoom in; hold Option to zoom out"
        }
    }

    var symbol: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .marquee: return "rectangle.dashed"
        case .hand: return "hand.draw"
        case .zoom: return "magnifyingglass"
        }
    }
}

private final class PhotoDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { imageURLs(from: sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
    private func imageURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { PhotoEditorViewController.supportsImage($0) }
    }
}

private final class PhotoCanvasView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var documentSize = CGSize.zero { didSet { publishZoom(); needsDisplay = true } }
    var selectedTool = PhotoTool.move
    var canMoveLayer = false
    var onMoveLayer: ((CGPoint, Bool) -> Void)?
    var onZoomChanged: ((Double) -> Void)?
    var onSelectionChanged: ((CGRect?) -> Void)?

    private var zoomMultiplier = 1.0
    private var panOffset = CGPoint.zero
    private var dragStart = CGPoint.zero
    private var lastDragPoint = CGPoint.zero
    private var selectionStart: CGPoint?
    private(set) var documentSelection: CGRect?
    private var lastPublishedZoom = -1.0

    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: "25272C").cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        publishZoom()
    }

    func fit() { zoomMultiplier = 1; panOffset = .zero; publishZoom(); needsDisplay = true }
    func actualSize() {
        guard documentSize.width > 0, documentSize.height > 0 else { return }
        zoomMultiplier = 1 / max(fitScale, 0.0001)
        panOffset = .zero
        publishZoom(); needsDisplay = true
    }
    func zoom(by factor: Double, around point: CGPoint? = nil) {
        let old = zoomMultiplier
        zoomMultiplier = min(16, max(0.05, zoomMultiplier * factor))
        if let point, old > 0 {
            let ratio = zoomMultiplier / old
            let center = CGPoint(x: bounds.midX + panOffset.x, y: bounds.midY + panOffset.y)
            panOffset.x -= (point.x - center.x) * (ratio - 1)
            panOffset.y -= (point.y - center.y) * (ratio - 1)
        }
        publishZoom(); needsDisplay = true
    }
    func clearSelection() { documentSelection = nil; onSelectionChanged?(nil); needsDisplay = true }
    var documentSelectionRect: CGRect? {
        guard let documentSelection, documentSize.width > 0, documentSize.height > 0 else { return nil }
        let clipped = documentSelection.intersection(CGRect(origin: .zero, size: documentSize)).integral
        return clipped.width > 1 && clipped.height > 1 ? clipped : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(hex: "25272C").setFill(); dirtyRect.fill()
        guard let image, documentSize.width > 0, documentSize.height > 0 else { drawEmptyState(); return }
        let rect = imageRect
        drawCheckerboard(in: rect)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
        NSColor.black.withAlphaComponent(0.85).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)); border.lineWidth = 1; border.stroke()
        if let documentSelection {
            let selectionRect = viewRect(forDocumentRect: documentSelection)
            NSGraphicsContext.saveGraphicsState()
            let path = NSBezierPath(rect: selectionRect); path.setLineDash([5, 4], count: 2, phase: 0); path.lineWidth = 1; NSColor.white.setStroke(); path.stroke()
            let shadow = NSBezierPath(rect: selectionRect.insetBy(dx: 1, dy: 1)); shadow.setLineDash([5, 4], count: 2, phase: 5); NSColor.black.setStroke(); shadow.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point; lastDragPoint = point
        if selectedTool == .zoom { zoom(by: event.modifierFlags.contains(.option) ? 0.8 : 1.25, around: point) }
        else if selectedTool == .marquee {
            let start = clampedDocumentPoint(from: point)
            selectionStart = start; documentSelection = CGRect(origin: start, size: .zero); needsDisplay = true
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGPoint(x: point.x - lastDragPoint.x, y: point.y - lastDragPoint.y)
        switch selectedTool {
        case .hand: panOffset.x += delta.x; panOffset.y += delta.y
        case .move where canMoveLayer:
            let scale = max(effectiveScale, 0.0001)
            onMoveLayer?(CGPoint(x: delta.x / scale, y: delta.y / scale), false)
        case .marquee:
            if let start = selectionStart {
                let current = clampedDocumentPoint(from: point)
                documentSelection = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
            }
        default: break
        }
        lastDragPoint = point; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if selectedTool == .move, canMoveLayer { onMoveLayer?(.zero, true) }
        if selectedTool == .marquee {
            selectionStart = nil
            if let rect = documentSelection, rect.width < 2 || rect.height < 2 { documentSelection = nil }
            onSelectionChanged?(documentSelection)
        }
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            zoom(by: event.scrollingDeltaY > 0 ? 1.1 : 0.9, around: convert(event.locationInWindow, from: nil))
        } else {
            panOffset.x -= event.scrollingDeltaX; panOffset.y -= event.scrollingDeltaY; needsDisplay = true
        }
    }

    private var fitScale: Double {
        guard documentSize.width > 0, documentSize.height > 0 else { return 1 }
        return min(max(0.02, (bounds.width - 72) / documentSize.width), max(0.02, (bounds.height - 72) / documentSize.height))
    }
    private var effectiveScale: Double { fitScale * zoomMultiplier }
    private var imageRect: CGRect {
        let size = CGSize(width: documentSize.width * effectiveScale, height: documentSize.height * effectiveScale)
        return CGRect(x: bounds.midX - size.width / 2 + panOffset.x, y: bounds.midY - size.height / 2 + panOffset.y, width: size.width, height: size.height)
    }
    private func clampedDocumentPoint(from viewPoint: CGPoint) -> CGPoint {
        guard documentSize.width > 0, documentSize.height > 0 else { return .zero }
        let scale = max(effectiveScale, 0.0001)
        return CGPoint(
            x: min(documentSize.width, max(0, (viewPoint.x - imageRect.minX) / scale)),
            y: min(documentSize.height, max(0, (viewPoint.y - imageRect.minY) / scale))
        )
    }
    private func viewRect(forDocumentRect rect: CGRect) -> CGRect {
        let scale = max(effectiveScale, 0.0001)
        return CGRect(
            x: imageRect.minX + rect.minX * scale,
            y: imageRect.minY + rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }
    private func publishZoom() {
        let value = effectiveScale * 100
        guard abs(value - lastPublishedZoom) > 0.05 else { return }
        lastPublishedZoom = value
        onZoomChanged?(value)
    }
    private func drawEmptyState() {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor(hex: "D1D5DC"), .paragraphStyle: paragraph]
        let hintAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(hex: "717985"), .paragraphStyle: paragraph]
        "Create a photo document".draw(in: CGRect(x: bounds.midX - 180, y: bounds.midY + 8, width: 360, height: 26), withAttributes: titleAttributes)
        "Drop one or more images here, or choose Import Layers".draw(in: CGRect(x: bounds.midX - 220, y: bounds.midY - 22, width: 440, height: 20), withAttributes: hintAttributes)
    }
    private func drawCheckerboard(in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
        NSColor(hex: "D7D9DD").setFill(); rect.fill(); NSColor(hex: "BEC1C6").setFill()
        let cell = max(5, min(14, 9 * effectiveScale.squareRoot()))
        var row = 0; var y = rect.minY
        while y < rect.maxY {
            var column = 0; var x = rect.minX
            while x < rect.maxX { if (row + column).isMultiple(of: 2) { CGRect(x: x, y: y, width: cell, height: cell).fill() }; x += cell; column += 1 }
            y += cell; row += 1
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class PhotoEditorViewController: NSViewController {
    var onShowStudioHome: (() -> Void)?

    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let renderQueue = DispatchQueue(label: "local.netvista.photos.preview", qos: .userInitiated)
    private let canvasView = PhotoCanvasView()
    private let layersStack = PhotoFlippedStackView()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let documentLabel = NSTextField(labelWithString: "Untitled Photo")
    private let canvasTabLabel = NSTextField(labelWithString: "Untitled Photo")
    private let zoomLabel = NSTextField(labelWithString: "Fit")
    private let selectedLayerLabel = NSTextField(labelWithString: "No layer selected")
    private let inspectorScrollView = NSScrollView()
    private let toolTitleLabel = NSTextField(labelWithString: PhotoTool.move.title)
    private let toolHintLabel = NSTextField(labelWithString: PhotoTool.move.hint)
    private let selectionLabel = NSTextField(labelWithString: "No active selection")
    private let blendPopup = NSPopUpButton()
    private let lockButton = NSButton(checkboxWithTitle: "Lock layer", target: nil, action: nil)
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let showOriginal = NSButton(checkboxWithTitle: "Bypass adjustments", target: nil, action: nil)

    private var layers: [PhotoLayer] = [] // Topmost layer is first.
    private var selectedLayerID: UUID?
    private var documentSize = CGSize.zero
    private var selectedTool = PhotoTool.move
    private var toolButtons: [PhotoTool: NSButton] = [:]
    private var undoHistory: [PhotoDocumentSnapshot] = []
    private var redoHistory: [PhotoDocumentSnapshot] = []
    private var renderGeneration = 0
    private var pendingPreview: DispatchWorkItem?
    private var moveUndoSnapshot: PhotoDocumentSnapshot?
    private var projectURL: URL?
    private var isSynchronizingControls = false
    private var sliderValueLabels: [ObjectIdentifier: NSTextField] = [:]
    private var sliderFormatters: [ObjectIdentifier: (Double) -> String] = [:]

    private let layerOpacity = PhotoTrackedSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let positionX = PhotoTrackedSlider(value: 0, minValue: -4000, maxValue: 4000, target: nil, action: nil)
    private let positionY = PhotoTrackedSlider(value: 0, minValue: -4000, maxValue: 4000, target: nil, action: nil)
    private let layerScale = PhotoTrackedSlider(value: 100, minValue: 1, maxValue: 400, target: nil, action: nil)
    private let layerRotation = PhotoTrackedSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    private let exposure = PhotoTrackedSlider(value: 0, minValue: -4, maxValue: 4, target: nil, action: nil)
    private let brightness = PhotoTrackedSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let contrast = PhotoTrackedSlider(value: 1, minValue: 0.25, maxValue: 2.5, target: nil, action: nil)
    private let saturation = PhotoTrackedSlider(value: 1, minValue: 0, maxValue: 2.5, target: nil, action: nil)
    private let vibrance = PhotoTrackedSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let highlights = PhotoTrackedSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let shadows = PhotoTrackedSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let temperature = PhotoTrackedSlider(value: 6500, minValue: 2000, maxValue: 10000, target: nil, action: nil)
    private let tint = PhotoTrackedSlider(value: 0, minValue: -150, maxValue: 150, target: nil, action: nil)
    private let sharpen = PhotoTrackedSlider(value: 0, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let blur = PhotoTrackedSlider(value: 0, minValue: 0, maxValue: 20, target: nil, action: nil)
    private let sepia = PhotoTrackedSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let vignette = PhotoTrackedSlider(value: 0, minValue: 0, maxValue: 2, target: nil, action: nil)

    private var selectedLayer: PhotoLayer? { layers.first { $0.id == selectedLayerID } }
    private var allSliders: [PhotoTrackedSlider] { [layerOpacity, positionX, positionY, layerScale, layerRotation, exposure, brightness, contrast, saturation, vibrance, highlights, shadows, temperature, tint, sharpen, blur, sepia, vignette] }

    static func supportsImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    override func loadView() {
        let dropView = PhotoDropView()
        dropView.onDrop = { [weak self] urls in self?.openImages(urls) }
        dropView.wantsLayer = true; dropView.layer?.backgroundColor = NSColor(hex: "101216").cgColor
        view = dropView
        configureCanvas()

        // Use an explicit application shell here rather than nesting the major regions
        // in one root NSStackView. AppKit can collapse cross-axis stack children when a
        // window first opens at a large size, which previously hid the command bars and
        // tool rail even though the canvas and inspector remained visible.
        let applicationBar = makeApplicationBar()
        let applicationSeparator = separator()
        let optionsBar = makeToolOptionsBar()
        let optionsSeparator = separator()
        let body = NSView()
        let statusSeparator = separator()
        let statusBar = makeStatusBar()
        // Add the flexible body first, then the fixed chrome. This guarantees that
        // canvas subviews can never paint over the command bars during live resize.
        for region in [body, applicationBar, applicationSeparator, optionsBar, optionsSeparator, statusSeparator, statusBar] {
            region.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(region)
        }

        let toolRail = makeToolRail()
        let toolSeparator = separator(vertical: true)
        let canvasWorkspace = makeCanvasWorkspace()
        let inspectorSeparator = separator(vertical: true)
        let rightSidebar = makeRightSidebar()
        body.wantsLayer = true
        body.layer?.masksToBounds = true
        canvasWorkspace.wantsLayer = true
        canvasWorkspace.layer?.masksToBounds = true
        // Keep the working surface at the back; docked chrome always paints above it.
        for region in [canvasWorkspace, toolRail, toolSeparator, inspectorSeparator, rightSidebar] {
            region.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(region)
        }
        applicationBar.layer?.zPosition = 10
        optionsBar.layer?.zPosition = 10
        toolRail.layer?.zPosition = 10
        rightSidebar.layer?.zPosition = 10
        statusBar.layer?.zPosition = 10

        NSLayoutConstraint.activate([
            applicationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            applicationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            applicationBar.topAnchor.constraint(equalTo: view.topAnchor),
            applicationSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            applicationSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            applicationSeparator.topAnchor.constraint(equalTo: applicationBar.bottomAnchor),
            optionsBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            optionsBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            optionsBar.topAnchor.constraint(equalTo: applicationSeparator.bottomAnchor),
            optionsSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            optionsSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            optionsSeparator.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),

            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.topAnchor.constraint(equalTo: optionsSeparator.bottomAnchor),
            body.bottomAnchor.constraint(equalTo: statusSeparator.topAnchor),

            statusSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: statusSeparator.bottomAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            toolRail.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            toolRail.topAnchor.constraint(equalTo: body.topAnchor),
            toolRail.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            toolSeparator.leadingAnchor.constraint(equalTo: toolRail.trailingAnchor),
            toolSeparator.topAnchor.constraint(equalTo: body.topAnchor),
            toolSeparator.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            canvasWorkspace.leadingAnchor.constraint(equalTo: toolSeparator.trailingAnchor),
            canvasWorkspace.topAnchor.constraint(equalTo: body.topAnchor),
            canvasWorkspace.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            inspectorSeparator.leadingAnchor.constraint(equalTo: canvasWorkspace.trailingAnchor),
            inspectorSeparator.topAnchor.constraint(equalTo: body.topAnchor),
            inspectorSeparator.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            rightSidebar.leadingAnchor.constraint(equalTo: inspectorSeparator.trailingAnchor),
            rightSidebar.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            rightSidebar.topAnchor.constraint(equalTo: body.topAnchor),
            rightSidebar.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
        selectTool(.move); rebuildLayersPanel(); syncInspector(); updateHistoryButtons()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inspectorScrollView.contentView.scroll(to: .zero)
            self.inspectorScrollView.reflectScrolledClipView(self.inspectorScrollView.contentView)
        }
    }

    func openImages(_ urls: [URL]) {
        let valid = urls.filter(Self.supportsImage)
        guard !valid.isEmpty else { return }
        let decoded: [(url: URL, source: CIImage, thumbnail: NSImage?)] = valid.compactMap { url in
            guard let loaded = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
            return (url, normalized(loaded), NSImage(contentsOf: url))
        }
        guard !decoded.isEmpty else { statusLabel.stringValue = "No supported images could be opened"; return }

        pushHistory()
        if documentSize == .zero, let first = decoded.first { documentSize = first.source.extent.size }
        for item in decoded {
            let layer = PhotoLayer(name: item.url.deletingPathExtension().lastPathComponent, sourceURL: item.url, sourceImage: item.source, thumbnail: item.thumbnail)
            layer.scale = min(1, min(documentSize.width / max(item.source.extent.width, 1), documentSize.height / max(item.source.extent.height, 1)))
            layers.insert(layer, at: 0); selectedLayerID = layer.id
        }
        documentLabel.stringValue = decoded.count == 1 ? decoded[0].url.lastPathComponent : "Untitled Composite"
        statusLabel.stringValue = decoded.count == 1 ? "Imported 1 layer" : "Imported \(decoded.count) layers"
        refreshDocumentUI(renderImmediately: true)
    }

    private func configureCanvas() {
        canvasView.onMoveLayer = { [weak self] delta, finished in
            guard let self, let layer = self.selectedLayer, !layer.isLocked else { return }
            if finished {
                if let snapshot = self.moveUndoSnapshot {
                    self.undoHistory.append(snapshot); self.redoHistory.removeAll(); self.moveUndoSnapshot = nil; self.updateHistoryButtons()
                }
                return
            }
            guard delta != .zero else { return }
            if self.moveUndoSnapshot == nil { self.moveUndoSnapshot = self.snapshot() }
            layer.position.x += delta.x; layer.position.y += delta.y
            self.syncInspector(); self.schedulePreview()
        }
        canvasView.onZoomChanged = { [weak self] percent in
            guard let self else { return }
            self.zoomLabel.stringValue = String(format: "%.0f%%", percent)
            self.updateCanvasTab()
        }
        canvasView.onSelectionChanged = { [weak self] rect in
            self?.selectionLabel.stringValue = rect.map { "Selection  \(Int($0.width)) × \(Int($0.height)) px" } ?? "No active selection"
        }
    }
}

private extension PhotoEditorViewController {
    func makeApplicationBar() -> NSView {
        let bar = NSStackView(); bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 9
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12); bar.heightAnchor.constraint(equalToConstant: 50).isActive = true
        bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor(hex: "17191D").cgColor

        let home = iconButton("square.grid.2x2", "Studio Home", #selector(showStudioHome)); home.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Photo Editor") ?? NSImage())
        icon.contentTintColor = .systemPink; icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let title = NSTextField(labelWithString: "Photos"); title.font = .systemFont(ofSize: 15, weight: .semibold); title.textColor = .white
        let brand = NSTextField(labelWithString: "NETVISTA STUDIO"); brand.font = .systemFont(ofSize: 9, weight: .bold); brand.textColor = .systemPink
        documentLabel.font = .systemFont(ofSize: 11, weight: .medium); documentLabel.textColor = NSColor(hex: "AEB4BE"); documentLabel.alignment = .center; documentLabel.lineBreakMode = .byTruncatingMiddle
        documentLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        configureHistoryButton(undoButton, symbol: "arrow.uturn.backward", tooltip: "Undo", action: #selector(undoEdit), key: "z", modifiers: [.command])
        configureHistoryButton(redoButton, symbol: "arrow.uturn.forward", tooltip: "Redo", action: #selector(redoEdit), key: "Z", modifiers: [.command, .shift])

        bar.addArrangedSubview(home); bar.addArrangedSubview(separator(vertical: true)); bar.addArrangedSubview(icon); bar.addArrangedSubview(title); bar.addArrangedSubview(brand)
        bar.addArrangedSubview(NSView()); bar.addArrangedSubview(documentLabel); bar.addArrangedSubview(NSView())
        bar.addArrangedSubview(undoButton); bar.addArrangedSubview(redoButton)
        bar.addArrangedSubview(makeButton("Open…", #selector(openProjectPanel)))
        bar.addArrangedSubview(makeButton("Save", #selector(saveProject)))
        bar.addArrangedSubview(makeButton("Import Layers…", #selector(importPhotos)))
        let export = makeButton("Export…", #selector(exportPhoto)); export.contentTintColor = .systemBlue; bar.addArrangedSubview(export)
        return bar
    }

    func makeToolOptionsBar() -> NSView {
        let bar = NSStackView(); bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12); bar.heightAnchor.constraint(equalToConstant: 38).isActive = true
        bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor(hex: "1D2025").cgColor
        toolTitleLabel.font = .systemFont(ofSize: 11, weight: .semibold); toolTitleLabel.textColor = NSColor(hex: "E1E4E9")
        toolHintLabel.font = .systemFont(ofSize: 10); toolHintLabel.textColor = NSColor(hex: "7F8793")
        selectionLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular); selectionLabel.textColor = NSColor(hex: "7F8793")
        bar.addArrangedSubview(toolTitleLabel); bar.addArrangedSubview(separator(vertical: true)); bar.addArrangedSubview(toolHintLabel); bar.addArrangedSubview(NSView())
        bar.addArrangedSubview(selectionLabel)
        bar.addArrangedSubview(makeButton("Crop to Selection", #selector(cropToSelection)))
        bar.addArrangedSubview(makeButton("Clear Selection", #selector(clearSelection)))
        return bar
    }

    func makeToolRail() -> NSView {
        let panel = NSStackView(); panel.orientation = .vertical; panel.alignment = .centerX; panel.spacing = 8
        panel.edgeInsets = NSEdgeInsets(top: 10, left: 6, bottom: 10, right: 6); panel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        panel.wantsLayer = true; panel.layer?.backgroundColor = NSColor(hex: "17191D").cgColor
        for tool in PhotoTool.allCases {
            let button = iconButton(tool.symbol, tool.title, #selector(toolPressed(_:)))
            button.tag = tool.rawValue; button.setButtonType(.toggle); button.widthAnchor.constraint(equalToConstant: 34).isActive = true; button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            toolButtons[tool] = button; panel.addArrangedSubview(button)
        }
        panel.addArrangedSubview(separator()); panel.addArrangedSubview(iconButton("arrow.counterclockwise", "Reset selected layer", #selector(resetSelectedLayer))); panel.addArrangedSubview(NSView())
        return panel
    }

    func makeCanvasWorkspace() -> NSView {
        let workspace = NSStackView(); workspace.orientation = .vertical; workspace.spacing = 0
        workspace.setContentHuggingPriority(.defaultLow, for: .horizontal); workspace.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspace.setContentHuggingPriority(.defaultLow, for: .vertical); workspace.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let header = NSStackView(); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 8; header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12); header.heightAnchor.constraint(equalToConstant: 32).isActive = true
        header.wantsLayer = true; header.layer?.backgroundColor = NSColor(hex: "14161A").cgColor
        let tab = NSStackView(); tab.orientation = .horizontal; tab.alignment = .centerY; tab.spacing = 7; tab.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12); tab.wantsLayer = true; tab.layer?.backgroundColor = NSColor(hex: "292C32").cgColor; tab.layer?.cornerRadius = 4
        let tabIcon = NSImageView(image: NSImage(systemSymbolName: "photo", accessibilityDescription: "Photo document") ?? NSImage()); tabIcon.contentTintColor = .systemPink; tabIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        canvasTabLabel.font = .systemFont(ofSize: 10, weight: .medium); canvasTabLabel.textColor = NSColor(hex: "D6DAE1"); canvasTabLabel.lineBreakMode = .byTruncatingMiddle; canvasTabLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        tab.addArrangedSubview(tabIcon); tab.addArrangedSubview(canvasTabLabel)
        showOriginal.target = self; showOriginal.action = #selector(toggleOriginal)
        header.addArrangedSubview(tab); header.addArrangedSubview(NSView()); header.addArrangedSubview(showOriginal)
        workspace.addArrangedSubview(header); workspace.addArrangedSubview(separator())
        canvasView.setContentHuggingPriority(.defaultLow, for: .horizontal); canvasView.setContentHuggingPriority(.defaultLow, for: .vertical)
        canvasView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); canvasView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        canvasView.widthAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true
        workspace.addArrangedSubview(canvasView); workspace.addArrangedSubview(separator())
        let zoomBar = NSStackView(); zoomBar.orientation = .horizontal; zoomBar.alignment = .centerY; zoomBar.spacing = 7; zoomBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10); zoomBar.heightAnchor.constraint(equalToConstant: 32).isActive = true
        zoomBar.wantsLayer = true; zoomBar.layer?.backgroundColor = NSColor(hex: "15171B").cgColor
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); zoomLabel.textColor = NSColor(hex: "AEB5C0"); zoomLabel.alignment = .center; zoomLabel.widthAnchor.constraint(equalToConstant: 54).isActive = true
        zoomBar.addArrangedSubview(makeButton("−", #selector(zoomOut))); zoomBar.addArrangedSubview(zoomLabel); zoomBar.addArrangedSubview(makeButton("+", #selector(zoomIn))); zoomBar.addArrangedSubview(makeButton("Fit", #selector(fitCanvas))); zoomBar.addArrangedSubview(makeButton("100%", #selector(actualCanvas))); zoomBar.addArrangedSubview(NSView())
        let hint = NSTextField(labelWithString: "⌘ scroll to zoom  •  Hand tool to pan"); hint.font = .systemFont(ofSize: 9); hint.textColor = NSColor(hex: "646C77"); zoomBar.addArrangedSubview(hint)
        workspace.addArrangedSubview(zoomBar)
        return workspace
    }

    func makeRightSidebar() -> NSView {
        let sidebar = NSStackView(); sidebar.orientation = .vertical; sidebar.spacing = 0; sidebar.widthAnchor.constraint(equalToConstant: 310).isActive = true
        sidebar.setContentHuggingPriority(.required, for: .horizontal)
        sidebar.wantsLayer = true; sidebar.layer?.backgroundColor = NSColor(hex: "1A1D22").cgColor
        sidebar.addArrangedSubview(makeInspectorPanel()); sidebar.addArrangedSubview(separator()); sidebar.addArrangedSubview(makeLayersPanel())
        return sidebar
    }

    func makeInspectorPanel() -> NSView {
        let panel = NSStackView(); panel.orientation = .vertical; panel.alignment = .width; panel.spacing = 0; panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let heading = panelHeading("PROPERTIES & ADJUSTMENTS", trailing: selectedLayerLabel)
        selectedLayerLabel.lineBreakMode = .byTruncatingTail; selectedLayerLabel.alignment = .right; selectedLayerLabel.font = .systemFont(ofSize: 9); selectedLayerLabel.textColor = NSColor(hex: "747D89")
        panel.addArrangedSubview(heading); panel.addArrangedSubview(separator())

        let controls = PhotoFlippedStackView(); controls.orientation = .vertical; controls.alignment = .width; controls.spacing = 10; controls.edgeInsets = NSEdgeInsets(top: 12, left: 13, bottom: 18, right: 13); controls.translatesAutoresizingMaskIntoConstraints = false
        controls.addArrangedSubview(section("LAYER"))
        let blendRow = NSStackView(); blendRow.orientation = .horizontal; blendRow.alignment = .centerY; blendRow.spacing = 8
        let blendLabel = propertyLabel("Blend mode"); blendLabel.widthAnchor.constraint(equalToConstant: 82).isActive = true
        blendPopup.addItems(withTitles: PhotoBlendMode.allCases.map(\.rawValue)); blendPopup.target = self; blendPopup.action = #selector(blendChanged); blendPopup.font = .systemFont(ofSize: 10)
        blendRow.addArrangedSubview(blendLabel); blendRow.addArrangedSubview(blendPopup); controls.addArrangedSubview(blendRow)
        configure(layerOpacity, action: #selector(layerControlChanged(_:))); controls.addArrangedSubview(sliderRow("Opacity", layerOpacity, formatter: { String(format: "%.0f%%", $0) }))
        lockButton.target = self; lockButton.action = #selector(lockChanged); lockButton.font = .systemFont(ofSize: 10); controls.addArrangedSubview(lockButton)

        controls.addArrangedSubview(section("TRANSFORM"))
        configure(positionX, action: #selector(layerControlChanged(_:))); controls.addArrangedSubview(sliderRow("Position X", positionX, formatter: { String(format: "%.0f", $0) }))
        configure(positionY, action: #selector(layerControlChanged(_:))); controls.addArrangedSubview(sliderRow("Position Y", positionY, formatter: { String(format: "%.0f", $0) }))
        configure(layerScale, action: #selector(layerControlChanged(_:))); controls.addArrangedSubview(sliderRow("Scale", layerScale, formatter: { String(format: "%.0f%%", $0) }))
        configure(layerRotation, action: #selector(layerControlChanged(_:))); controls.addArrangedSubview(sliderRow("Rotation", layerRotation, formatter: { String(format: "%.1f°", $0) }))

        controls.addArrangedSubview(section("LIGHT"))
        configure(exposure, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Exposure", exposure, formatter: signed(2)))
        configure(brightness, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Brightness", brightness, formatter: signed(2)))
        configure(contrast, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Contrast", contrast, formatter: decimal(2)))
        configure(highlights, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Highlights", highlights, formatter: decimal(2)))
        configure(shadows, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Shadows", shadows, formatter: signed(2)))

        controls.addArrangedSubview(section("COLOUR"))
        configure(saturation, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Saturation", saturation, formatter: decimal(2)))
        configure(vibrance, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Vibrance", vibrance, formatter: signed(2)))
        configure(temperature, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Temperature", temperature, formatter: { String(format: "%.0f K", $0) }))
        configure(tint, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Tint", tint, formatter: signed(0)))

        controls.addArrangedSubview(section("DETAIL & EFFECTS"))
        configure(sharpen, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Sharpen", sharpen, formatter: decimal(2)))
        configure(blur, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Blur", blur, formatter: decimal(1)))
        configure(sepia, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Sepia", sepia, formatter: decimal(2)))
        configure(vignette, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Vignette", vignette, formatter: decimal(2)))
        controls.addArrangedSubview(makeButton("Reset selected layer", #selector(resetSelectedLayer)))

        inspectorScrollView.drawsBackground = false
        inspectorScrollView.hasVerticalScroller = true
        inspectorScrollView.documentView = controls
        NSLayoutConstraint.activate([controls.leadingAnchor.constraint(equalTo: inspectorScrollView.contentView.leadingAnchor), controls.trailingAnchor.constraint(equalTo: inspectorScrollView.contentView.trailingAnchor), controls.topAnchor.constraint(equalTo: inspectorScrollView.contentView.topAnchor), controls.bottomAnchor.constraint(greaterThanOrEqualTo: inspectorScrollView.contentView.bottomAnchor), controls.widthAnchor.constraint(equalTo: inspectorScrollView.contentView.widthAnchor)])
        panel.addArrangedSubview(inspectorScrollView)
        return panel
    }

    func makeLayersPanel() -> NSView {
        let panel = NSStackView(); panel.orientation = .vertical; panel.alignment = .width; panel.spacing = 0; panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        panel.addArrangedSubview(panelHeading("LAYERS", trailing: nil)); panel.addArrangedSubview(separator())
        layersStack.orientation = .vertical; layersStack.alignment = .width; layersStack.spacing = 2; layersStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6); layersStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.documentView = layersStack
        NSLayoutConstraint.activate([layersStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), layersStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), layersStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), layersStack.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor), layersStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        panel.addArrangedSubview(scroll); panel.addArrangedSubview(separator())
        let actions = NSStackView(); actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 4; actions.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6); actions.heightAnchor.constraint(equalToConstant: 38).isActive = true
        actions.addArrangedSubview(iconButton("plus", "Import a new layer", #selector(importPhotos))); actions.addArrangedSubview(iconButton("doc.on.doc", "Duplicate selected layer", #selector(duplicateLayer))); actions.addArrangedSubview(iconButton("pencil", "Rename selected layer", #selector(renameLayer))); actions.addArrangedSubview(NSView())
        actions.addArrangedSubview(iconButton("arrow.up", "Move layer up", #selector(moveLayerUp))); actions.addArrangedSubview(iconButton("arrow.down", "Move layer down", #selector(moveLayerDown))); actions.addArrangedSubview(iconButton("trash", "Delete selected layer", #selector(deleteLayer)))
        panel.addArrangedSubview(actions)
        return panel
    }

    func makeStatusBar() -> NSView {
        let bar = NSStackView(); bar.orientation = .horizontal; bar.alignment = .centerY; bar.heightAnchor.constraint(equalToConstant: 26).isActive = true; bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor(hex: "14161A").cgColor
        statusLabel.font = .systemFont(ofSize: 10); statusLabel.textColor = NSColor(hex: "89919D"); bar.addArrangedSubview(statusLabel); bar.addArrangedSubview(NSView())
        let hint = NSTextField(labelWithString: "Non-destructive layers • Drop images anywhere to import"); hint.font = .systemFont(ofSize: 9); hint.textColor = NSColor(hex: "646C77"); bar.addArrangedSubview(hint)
        return bar
    }
}

private extension PhotoEditorViewController {
    func rebuildLayersPanel() {
        layersStack.arrangedSubviews.forEach { layersStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        if layers.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "No layers yet\nImport or drop an image to begin")
            empty.alignment = .center; empty.font = .systemFont(ofSize: 11); empty.textColor = NSColor(hex: "747C88"); empty.heightAnchor.constraint(equalToConstant: 70).isActive = true
            layersStack.addArrangedSubview(empty); return
        }
        for (index, layer) in layers.enumerated() { layersStack.addArrangedSubview(makeLayerRow(layer, index: index)) }
    }

    func makeLayerRow(_ layer: PhotoLayer, index: Int) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 6; row.edgeInsets = NSEdgeInsets(top: 4, left: 5, bottom: 4, right: 5); row.heightAnchor.constraint(equalToConstant: 46).isActive = true
        row.wantsLayer = true; row.layer?.cornerRadius = 5; row.layer?.backgroundColor = (layer.id == selectedLayerID ? NSColor(hex: "29384A") : NSColor(hex: "202329")).cgColor
        let visibility = NSButton(image: NSImage(systemSymbolName: layer.isVisible ? "eye" : "eye.slash", accessibilityDescription: layer.isVisible ? "Hide layer" : "Show layer") ?? NSImage(), target: self, action: #selector(toggleLayerVisibility(_:)))
        visibility.tag = index; visibility.isBordered = false; visibility.contentTintColor = layer.isVisible ? NSColor(hex: "D3D8E0") : NSColor(hex: "68717E"); visibility.toolTip = layer.isVisible ? "Hide layer" : "Show layer"; visibility.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let thumb = NSImageView(); thumb.image = layer.thumbnail; thumb.imageScaling = .scaleProportionallyUpOrDown; thumb.wantsLayer = true; thumb.layer?.backgroundColor = NSColor(hex: "111318").cgColor; thumb.layer?.cornerRadius = 3
        thumb.widthAnchor.constraint(equalToConstant: 36).isActive = true; thumb.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let select = NSButton(title: layer.name, target: self, action: #selector(selectLayer(_:))); select.tag = index; select.isBordered = false; select.alignment = .left; select.font = .systemFont(ofSize: 11, weight: layer.id == selectedLayerID ? .semibold : .regular); select.contentTintColor = NSColor(hex: "D7DBE2"); select.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: "\(layer.blendMode.rawValue)  ·  \(Int(layer.opacity * 100))%")
        detail.font = .systemFont(ofSize: 8); detail.textColor = NSColor(hex: "7D8591")
        let labels = NSStackView(); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 1; labels.addArrangedSubview(select); labels.addArrangedSubview(detail)
        let lock = iconButton(layer.isLocked ? "lock.fill" : "lock.open", layer.isLocked ? "Unlock layer" : "Lock layer", #selector(toggleLayerLock(_:))); lock.tag = index; lock.widthAnchor.constraint(equalToConstant: 22).isActive = true
        row.addArrangedSubview(visibility); row.addArrangedSubview(thumb); row.addArrangedSubview(labels); row.addArrangedSubview(NSView()); row.addArrangedSubview(lock)
        return row
    }

    func refreshDocumentUI(renderImmediately: Bool = false) {
        canvasView.documentSize = documentSize
        canvasView.canMoveLayer = selectedLayer.map { !$0.isLocked } ?? false
        rebuildLayersPanel(); syncInspector(); updateHistoryButtons(); updateCanvasTab(); schedulePreview(immediate: renderImmediately)
    }

    func updateCanvasTab() {
        let name = documentLabel.stringValue.isEmpty ? "Untitled Photo" : documentLabel.stringValue
        canvasTabLabel.stringValue = "\(name)  @  \(zoomLabel.stringValue)  (RGB/8)"
    }

    func syncInspector() {
        isSynchronizingControls = true
        defer { isSynchronizingControls = false }
        guard let layer = selectedLayer else {
            selectedLayerLabel.stringValue = "No layer selected"; setInspectorEnabled(false); updateSliderLabels(); return
        }
        selectedLayerLabel.stringValue = layer.name
        blendPopup.selectItem(withTitle: layer.blendMode.rawValue); layerOpacity.doubleValue = layer.opacity * 100; lockButton.state = layer.isLocked ? .on : .off
        positionX.doubleValue = layer.position.x; positionY.doubleValue = layer.position.y; layerScale.doubleValue = layer.scale * 100; layerRotation.doubleValue = layer.rotation
        let a = layer.adjustments
        exposure.doubleValue = a.exposure; brightness.doubleValue = a.brightness; contrast.doubleValue = a.contrast; saturation.doubleValue = a.saturation; vibrance.doubleValue = a.vibrance
        highlights.doubleValue = a.highlights; shadows.doubleValue = a.shadows; temperature.doubleValue = a.temperature; tint.doubleValue = a.tint
        sharpen.doubleValue = a.sharpen; blur.doubleValue = a.blur; sepia.doubleValue = a.sepia; vignette.doubleValue = a.vignette
        setInspectorEnabled(!layer.isLocked); lockButton.isEnabled = true; updateSliderLabels()
    }

    func setInspectorEnabled(_ enabled: Bool) {
        allSliders.forEach { $0.isEnabled = enabled }
        blendPopup.isEnabled = enabled; lockButton.isEnabled = selectedLayer != nil
    }

    @objc func showStudioHome() { onShowStudioHome?() }
    @objc func importPhotos() {
        let panel = NSOpenPanel(); panel.title = "Import Image Layers"; panel.prompt = "Import Layers"; panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in if response == .OK { self?.openImages(panel?.urls ?? []) } }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: completion) } else { completion(panel.runModal()) }
    }

    @objc func toolPressed(_ sender: NSButton) { guard let tool = PhotoTool(rawValue: sender.tag) else { return }; selectTool(tool) }
    func selectTool(_ tool: PhotoTool) {
        selectedTool = tool; canvasView.selectedTool = tool; toolButtons.forEach { $0.value.state = $0.key == tool ? .on : .off }
        toolTitleLabel.stringValue = tool.title; toolHintLabel.stringValue = tool.hint
    }
    @objc func clearSelection() { canvasView.clearSelection(); statusLabel.stringValue = "Selection cleared" }
    @objc func cropToSelection() {
        guard let crop = canvasView.documentSelectionRect, crop.width >= 2, crop.height >= 2 else {
            NSSound.beep(); statusLabel.stringValue = "Use Rectangular Select before cropping"; return
        }
        pushHistory()
        let oldCentre = CGPoint(x: documentSize.width / 2, y: documentSize.height / 2)
        let newCentreInOldDocument = CGPoint(x: crop.midX, y: crop.midY)
        for layer in layers {
            layer.position.x += oldCentre.x - newCentreInOldDocument.x
            layer.position.y += oldCentre.y - newCentreInOldDocument.y
        }
        documentSize = crop.size
        canvasView.clearSelection(); canvasView.fit()
        refreshDocumentUI(renderImmediately: true)
        statusLabel.stringValue = "Canvas cropped to \(Int(crop.width)) × \(Int(crop.height)) px"
    }
    @objc func fitCanvas() { canvasView.fit() }
    @objc func actualCanvas() { canvasView.actualSize() }
    @objc func zoomIn() { canvasView.zoom(by: 1.25) }
    @objc func zoomOut() { canvasView.zoom(by: 0.8) }
    @objc func toggleOriginal() { schedulePreview(immediate: true) }

    @objc func selectLayer(_ sender: NSButton) {
        guard layers.indices.contains(sender.tag) else { return }
        selectedLayerID = layers[sender.tag].id; refreshDocumentUI(); statusLabel.stringValue = "Selected \(layers[sender.tag].name)"
    }
    @objc func toggleLayerVisibility(_ sender: NSButton) {
        guard layers.indices.contains(sender.tag) else { return }
        pushHistory(); layers[sender.tag].isVisible.toggle(); refreshDocumentUI()
    }
    @objc func toggleLayerLock(_ sender: NSButton) {
        guard layers.indices.contains(sender.tag) else { return }
        pushHistory(); layers[sender.tag].isLocked.toggle(); refreshDocumentUI()
    }
    @objc func lockChanged() {
        guard let layer = selectedLayer else { return }
        pushHistory(); layer.isLocked = lockButton.state == .on; refreshDocumentUI()
    }
    @objc func blendChanged() {
        guard !isSynchronizingControls, let layer = selectedLayer, !layer.isLocked, let title = blendPopup.selectedItem?.title, let mode = PhotoBlendMode(rawValue: title) else { return }
        pushHistory(); layer.blendMode = mode; refreshDocumentUI(); statusLabel.stringValue = "Blend mode: \(mode.rawValue)"
    }
    @objc func layerControlChanged(_ sender: PhotoTrackedSlider) {
        guard !isSynchronizingControls, let layer = selectedLayer, !layer.isLocked else { return }
        if !sender.isMouseTracking { pushHistory() }
        layer.opacity = layerOpacity.doubleValue / 100; layer.position = CGPoint(x: positionX.doubleValue, y: positionY.doubleValue); layer.scale = layerScale.doubleValue / 100; layer.rotation = layerRotation.doubleValue
        updateSliderLabels(); schedulePreview()
    }
    @objc func adjustmentChanged(_ sender: PhotoTrackedSlider) {
        guard !isSynchronizingControls, let layer = selectedLayer, !layer.isLocked else { return }
        if !sender.isMouseTracking { pushHistory() }
        layer.adjustments.exposure = exposure.doubleValue; layer.adjustments.brightness = brightness.doubleValue; layer.adjustments.contrast = contrast.doubleValue; layer.adjustments.saturation = saturation.doubleValue
        layer.adjustments.vibrance = vibrance.doubleValue; layer.adjustments.highlights = highlights.doubleValue; layer.adjustments.shadows = shadows.doubleValue
        layer.adjustments.temperature = temperature.doubleValue; layer.adjustments.tint = tint.doubleValue; layer.adjustments.sharpen = sharpen.doubleValue; layer.adjustments.blur = blur.doubleValue
        layer.adjustments.sepia = sepia.doubleValue; layer.adjustments.vignette = vignette.doubleValue
        updateSliderLabels(); schedulePreview()
    }

    @objc func duplicateLayer() {
        guard let index = selectedLayerID.flatMap({ id in layers.firstIndex { $0.id == id } }) else { NSSound.beep(); return }
        pushHistory(); let original = layers[index]
        let copy = PhotoLayer(name: original.name + " copy", sourceURL: original.sourceURL, sourceImage: original.sourceImage, thumbnail: original.thumbnail)
        copy.isVisible = original.isVisible; copy.opacity = original.opacity; copy.blendMode = original.blendMode; copy.position = CGPoint(x: original.position.x + 20, y: original.position.y - 20); copy.scale = original.scale; copy.rotation = original.rotation; copy.adjustments = original.adjustments
        layers.insert(copy, at: index); selectedLayerID = copy.id; refreshDocumentUI(); statusLabel.stringValue = "Layer duplicated"
    }
    @objc func deleteLayer() {
        guard let index = selectedLayerID.flatMap({ id in layers.firstIndex { $0.id == id } }) else { NSSound.beep(); return }
        pushHistory(); let name = layers[index].name; layers.remove(at: index)
        selectedLayerID = layers.indices.contains(index) ? layers[index].id : layers.last?.id
        if layers.isEmpty { documentSize = .zero; documentLabel.stringValue = "Untitled Photo" }
        refreshDocumentUI(); statusLabel.stringValue = "Deleted \(name)"
    }
    @objc func renameLayer() {
        guard let layer = selectedLayer else { NSSound.beep(); return }
        let alert = NSAlert(); alert.messageText = "Rename Layer"; alert.informativeText = "Enter a name for this layer."; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: layer.name); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24); field.selectText(nil); alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty, value != layer.name else { return }
        pushHistory(); layer.name = value; refreshDocumentUI(); statusLabel.stringValue = "Layer renamed"
    }
    @objc func moveLayerUp() { reorderSelectedLayer(by: -1) }
    @objc func moveLayerDown() { reorderSelectedLayer(by: 1) }
    func reorderSelectedLayer(by offset: Int) {
        guard let from = selectedLayerID.flatMap({ id in layers.firstIndex { $0.id == id } }) else { NSSound.beep(); return }
        let target = from + offset; guard layers.indices.contains(target) else { NSSound.beep(); return }
        pushHistory(); layers.swapAt(from, target); refreshDocumentUI(); statusLabel.stringValue = offset < 0 ? "Layer moved up" : "Layer moved down"
    }
    @objc func resetSelectedLayer() {
        guard let layer = selectedLayer, !layer.isLocked else { NSSound.beep(); return }
        pushHistory(); layer.opacity = 1; layer.blendMode = .normal; layer.position = .zero; layer.scale = min(1, min(documentSize.width / max(layer.sourceImage.extent.width, 1), documentSize.height / max(layer.sourceImage.extent.height, 1))); layer.rotation = 0; layer.adjustments = PhotoAdjustments()
        showOriginal.state = .off; refreshDocumentUI(renderImmediately: true); statusLabel.stringValue = "Selected layer reset"
    }
    @objc func undoEdit() {
        guard let previous = undoHistory.popLast() else { NSSound.beep(); return }
        redoHistory.append(snapshot()); restore(previous); statusLabel.stringValue = "Undo"
    }
    @objc func redoEdit() {
        guard let next = redoHistory.popLast() else { NSSound.beep(); return }
        undoHistory.append(snapshot()); restore(next); statusLabel.stringValue = "Redo"
    }
}

private struct PhotoProjectAdjustmentData: Codable {
    let exposure: Double
    let brightness: Double
    let contrast: Double
    let saturation: Double
    let vibrance: Double
    let highlights: Double
    let shadows: Double
    let temperature: Double
    let tint: Double
    let sharpen: Double
    let blur: Double
    let sepia: Double
    let vignette: Double
    let mirrored: Bool

    init(_ value: PhotoAdjustments) {
        exposure = value.exposure; brightness = value.brightness; contrast = value.contrast; saturation = value.saturation; vibrance = value.vibrance
        highlights = value.highlights; shadows = value.shadows; temperature = value.temperature; tint = value.tint; sharpen = value.sharpen
        blur = value.blur; sepia = value.sepia; vignette = value.vignette; mirrored = value.mirrored
    }

    var adjustments: PhotoAdjustments {
        var value = PhotoAdjustments()
        value.exposure = exposure; value.brightness = brightness; value.contrast = contrast; value.saturation = saturation; value.vibrance = vibrance
        value.highlights = highlights; value.shadows = shadows; value.temperature = temperature; value.tint = tint; value.sharpen = sharpen
        value.blur = blur; value.sepia = sepia; value.vignette = vignette; value.mirrored = mirrored
        return value
    }
}

private struct PhotoProjectLayerData: Codable {
    let id: UUID
    let name: String
    let sourcePath: String
    let isVisible: Bool
    let isLocked: Bool
    let opacity: Double
    let blendMode: String
    let positionX: Double
    let positionY: Double
    let scale: Double
    let rotation: Double
    let adjustments: PhotoProjectAdjustmentData
}

private struct PhotoProjectFile: Codable {
    let format: String
    let version: Int
    let canvasWidth: Double
    let canvasHeight: Double
    let selectedLayerID: UUID?
    let layers: [PhotoProjectLayerData]
}

extension PhotoEditorViewController {
    static func supportsPhotoProject(_ url: URL) -> Bool { url.pathExtension.lowercased() == "netvistaphoto" }

    func openPhotoProject(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let project = try JSONDecoder().decode(PhotoProjectFile.self, from: data)
            guard project.format == "NetVista Photo Project", project.version <= 1 else {
                throw NSError(domain: "NetVistaPhoto", code: 2, userInfo: [NSLocalizedDescriptionKey: "This photo project was created by an unsupported version of NetVista Studio."])
            }
            var loadedLayers: [PhotoLayer] = []
            var missing: [String] = []
            for saved in project.layers {
                let sourceURL = URL(fileURLWithPath: saved.sourcePath)
                guard FileManager.default.fileExists(atPath: sourceURL.path), let image = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]) else {
                    missing.append(saved.sourcePath); continue
                }
                let source = normalized(image)
                let layer = PhotoLayer(id: saved.id, name: saved.name, sourceURL: sourceURL, sourceImage: source, thumbnail: NSImage(contentsOf: sourceURL))
                layer.isVisible = saved.isVisible; layer.isLocked = saved.isLocked; layer.opacity = saved.opacity; layer.blendMode = PhotoBlendMode(rawValue: saved.blendMode) ?? .normal
                layer.position = CGPoint(x: saved.positionX, y: saved.positionY); layer.scale = saved.scale; layer.rotation = saved.rotation; layer.adjustments = saved.adjustments.adjustments
                loadedLayers.append(layer)
            }
            if !missing.isEmpty {
                let list = missing.prefix(5).joined(separator: "\n") + (missing.count > 5 ? "\n…and \(missing.count - 5) more" : "")
                throw NSError(domain: "NetVistaPhoto", code: 3, userInfo: [NSLocalizedDescriptionKey: "The project references image files that are missing:\n\n\(list)\n\nMove the source images back to their original locations and try again."])
            }
            layers = loadedLayers; documentSize = CGSize(width: project.canvasWidth, height: project.canvasHeight)
            selectedLayerID = project.selectedLayerID.flatMap { id in loadedLayers.contains { $0.id == id } ? id : nil } ?? loadedLayers.first?.id
            projectURL = url; documentLabel.stringValue = url.lastPathComponent; undoHistory.removeAll(); redoHistory.removeAll(); showOriginal.state = .off
            refreshDocumentUI(renderImmediately: true); statusLabel.stringValue = "Opened \(url.lastPathComponent)"
        } catch {
            let alert = NSAlert(error: error); alert.messageText = "Could not Open Photo Project"
            if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            statusLabel.stringValue = "Open failed"
        }
    }
}

private extension PhotoEditorViewController {
    @objc func openProjectPanel() {
        let panel = NSOpenPanel(); panel.title = "Open Photo Project"; panel.prompt = "Open"; panel.allowedFileTypes = ["netvistaphoto"]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in if response == .OK, let url = panel?.url { self?.openPhotoProject(url) } }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    @objc func saveProject() {
        guard !layers.isEmpty else { NSSound.beep(); statusLabel.stringValue = "Import an image before saving"; return }
        if let projectURL { writeProject(to: projectURL) }
        else { saveProjectAs() }
    }

    func saveProjectAs() {
        let panel = NSSavePanel(); panel.title = "Save Photo Project"; panel.prompt = "Save Project"; panel.nameFieldStringValue = "Untitled.netvistaphoto"; panel.allowedFileTypes = ["netvistaphoto"]
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in guard response == .OK, let url = panel?.url else { return }; self?.writeProject(to: url) }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    func writeProject(to url: URL) {
        let missingNames = layers.filter { layer in
            guard let sourceURL = layer.sourceURL else { return true }
            return !FileManager.default.fileExists(atPath: sourceURL.path)
        }.map(\.name)
        guard missingNames.isEmpty else {
            let alert = NSAlert(); alert.messageText = "Some Layers Cannot Be Saved"; alert.informativeText = "These layers no longer have a source file: \(missingNames.joined(separator: ", "))."; alert.runModal(); return
        }
        let savedLayers = layers.compactMap { layer -> PhotoProjectLayerData? in
            guard let path = layer.sourceURL?.path else { return nil }
            return PhotoProjectLayerData(id: layer.id, name: layer.name, sourcePath: path, isVisible: layer.isVisible, isLocked: layer.isLocked, opacity: layer.opacity, blendMode: layer.blendMode.rawValue, positionX: layer.position.x, positionY: layer.position.y, scale: layer.scale, rotation: layer.rotation, adjustments: PhotoProjectAdjustmentData(layer.adjustments))
        }
        let project = PhotoProjectFile(format: "NetVista Photo Project", version: 1, canvasWidth: documentSize.width, canvasHeight: documentSize.height, selectedLayerID: selectedLayerID, layers: savedLayers)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: url, options: .atomic)
            projectURL = url; documentLabel.stringValue = url.lastPathComponent; updateCanvasTab(); statusLabel.stringValue = "Saved \(url.lastPathComponent)"
        } catch {
            let alert = NSAlert(error: error); alert.messageText = "Could not Save Photo Project"
            if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            statusLabel.stringValue = "Save failed"
        }
    }

    @objc func exportPhoto() {
        guard !layers.isEmpty, documentSize.width > 0, documentSize.height > 0 else { NSSound.beep(); statusLabel.stringValue = "Import an image before exporting"; return }
        let panel = NSSavePanel(); panel.title = "Export Composite"; panel.prompt = "Export"; panel.nameFieldStringValue = "NetVista-photo.png"; panel.allowedContentTypes = [.png, .jpeg]
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let output = panel?.url, let self else { return }
            self.statusLabel.stringValue = "Rendering full-resolution export…"
            let states = self.renderStates(); let size = self.documentSize
            self.renderQueue.async {
                let jpeg = ["jpg", "jpeg"].contains(output.pathExtension.lowercased())
                guard let result = self.composite(states, documentSize: size, maxSide: nil, bypassAdjustments: false, opaqueBackground: jpeg), let cg = self.context.createCGImage(result, from: result.extent) else {
                    DispatchQueue.main.async { self.statusLabel.stringValue = "Export failed" }; return
                }
                let bitmap = NSBitmapImageRep(cgImage: cg)
                guard let data = bitmap.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.94] : [:]) else {
                    DispatchQueue.main.async { self.statusLabel.stringValue = "Export failed: image encoder returned no data" }
                    return
                }
                do { try data.write(to: output, options: .atomic); DispatchQueue.main.async { self.statusLabel.stringValue = "Exported \(output.lastPathComponent)" } }
                catch { DispatchQueue.main.async { self.statusLabel.stringValue = "Export failed: \(error.localizedDescription)" } }
            }
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    func pushHistory() {
        undoHistory.append(snapshot()); if undoHistory.count > 80 { undoHistory.removeFirst() }
        redoHistory.removeAll(); updateHistoryButtons()
    }
    func snapshot() -> PhotoDocumentSnapshot {
        PhotoDocumentSnapshot(layers: layers.map { PhotoLayerSnapshot(id: $0.id, name: $0.name, sourceURL: $0.sourceURL, sourceImage: $0.sourceImage, thumbnail: $0.thumbnail, isVisible: $0.isVisible, isLocked: $0.isLocked, opacity: $0.opacity, blendMode: $0.blendMode, position: $0.position, scale: $0.scale, rotation: $0.rotation, adjustments: $0.adjustments) }, selectedLayerID: selectedLayerID, documentSize: documentSize, documentName: documentLabel.stringValue)
    }
    func restore(_ snapshot: PhotoDocumentSnapshot) {
        layers = snapshot.layers.map {
            let layer = PhotoLayer(id: $0.id, name: $0.name, sourceURL: $0.sourceURL, sourceImage: $0.sourceImage, thumbnail: $0.thumbnail)
            layer.isVisible = $0.isVisible; layer.isLocked = $0.isLocked; layer.opacity = $0.opacity; layer.blendMode = $0.blendMode; layer.position = $0.position; layer.scale = $0.scale; layer.rotation = $0.rotation; layer.adjustments = $0.adjustments
            return layer
        }
        selectedLayerID = snapshot.selectedLayerID; documentSize = snapshot.documentSize; documentLabel.stringValue = snapshot.documentName; refreshDocumentUI(renderImmediately: true)
    }
    func updateHistoryButtons() { undoButton.isEnabled = !undoHistory.isEmpty; redoButton.isEnabled = !redoHistory.isEmpty }

    func schedulePreview(immediate: Bool = false) {
        pendingPreview?.cancel(); renderGeneration += 1; let generation = renderGeneration
        guard !layers.isEmpty, documentSize.width > 0, documentSize.height > 0 else { canvasView.image = nil; return }
        let states = renderStates(); let size = documentSize; let bypass = showOriginal.state == .on
        let work = DispatchWorkItem { [weak self] in
            guard let self, let result = self.composite(states, documentSize: size, maxSide: 1800, bypassAdjustments: bypass, opaqueBackground: false), let cg = self.context.createCGImage(result, from: result.extent) else { return }
            let image = NSImage(cgImage: cg, size: result.extent.size)
            DispatchQueue.main.async { [weak self] in guard let self, generation == self.renderGeneration else { return }; self.canvasView.image = image }
        }
        pendingPreview = work; renderQueue.asyncAfter(deadline: .now() + (immediate ? 0 : 0.035), execute: work)
    }
    func renderStates() -> [PhotoLayerSnapshot] { snapshot().layers }

    func composite(_ states: [PhotoLayerSnapshot], documentSize: CGSize, maxSide: CGFloat?, bypassAdjustments: Bool, opaqueBackground: Bool) -> CIImage? {
        guard documentSize.width > 0, documentSize.height > 0 else { return nil }
        let factor: CGFloat = maxSide.map { min(1, $0 / max(documentSize.width, documentSize.height)) } ?? 1
        let extent = CGRect(x: 0, y: 0, width: documentSize.width * factor, height: documentSize.height * factor)
        var result = CIImage(color: opaqueBackground ? CIColor.white : CIColor.clear).cropped(to: extent)
        for state in states.reversed() where state.isVisible && state.opacity > 0 {
            var image = apply(bypassAdjustments ? PhotoAdjustments() : state.adjustments, to: state.sourceImage)
            let center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            image = image.transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y))
            image = image.transformed(by: CGAffineTransform(scaleX: state.scale * factor, y: state.scale * factor))
            image = image.transformed(by: CGAffineTransform(rotationAngle: state.rotation * .pi / 180))
            image = image.transformed(by: CGAffineTransform(translationX: extent.midX + state.position.x * factor, y: extent.midY + state.position.y * factor))
            if state.opacity < 0.999 { image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: state.opacity)]) }
            image = image.applyingFilter(state.blendMode.filterName, parameters: [kCIInputBackgroundImageKey: result]); result = image.cropped(to: extent)
        }
        return result
    }

    func apply(_ settings: PhotoAdjustments, to source: CIImage) -> CIImage {
        var image = source
        if settings.mirrored { image = normalized(image.transformed(by: CGAffineTransform(translationX: image.extent.width, y: 0).scaledBy(x: -1, y: 1))) }
        image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
        image = image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: settings.brightness, kCIInputContrastKey: settings.contrast, kCIInputSaturationKey: settings.saturation])
        image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": settings.vibrance])
        image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": settings.highlights, "inputShadowAmount": settings.shadows])
        image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: settings.temperature, y: settings.tint)])
        if settings.sharpen > 0 { image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: settings.sharpen]) }
        if settings.blur > 0 { let extent = image.extent; image = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: settings.blur]).cropped(to: extent) }
        if settings.sepia > 0 { image = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: settings.sepia]) }
        if settings.vignette > 0 { image = image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: settings.vignette, kCIInputRadiusKey: min(image.extent.width, image.extent.height) * 0.45]) }
        return normalized(image)
    }
    func normalized(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.minX != 0 || extent.minY != 0 else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
}

private extension PhotoEditorViewController {
    func configure(_ slider: PhotoTrackedSlider, action: Selector) {
        slider.target = self; slider.action = action; slider.isContinuous = true
        slider.onTrackingBegan = { [weak self] in self?.pushHistory() }
        slider.onTrackingEnded = { [weak self, weak slider] in
            guard let self, let slider else { return }
            if slider === self.layerOpacity || slider === self.positionX || slider === self.positionY || slider === self.layerScale || slider === self.layerRotation {
                self.rebuildLayersPanel()
            }
        }
    }

    func sliderRow(_ title: String, _ slider: PhotoTrackedSlider, formatter: @escaping (Double) -> String) -> NSView {
        let row = NSStackView(); row.orientation = .vertical; row.alignment = .width; row.spacing = 4
        let header = NSStackView(); header.orientation = .horizontal; header.alignment = .centerY
        let label = propertyLabel(title)
        let value = NSTextField(labelWithString: formatter(slider.doubleValue)); value.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium); value.textColor = NSColor(hex: "99A3B0"); value.alignment = .right; value.widthAnchor.constraint(equalToConstant: 58).isActive = true
        sliderValueLabels[ObjectIdentifier(slider)] = value; sliderFormatters[ObjectIdentifier(slider)] = formatter
        header.addArrangedSubview(label); header.addArrangedSubview(NSView()); header.addArrangedSubview(value); row.addArrangedSubview(header); row.addArrangedSubview(slider)
        return row
    }

    func updateSliderLabels() {
        for slider in allSliders {
            let key = ObjectIdentifier(slider)
            if let label = sliderValueLabels[key], let formatter = sliderFormatters[key] { label.stringValue = formatter(slider.doubleValue) }
        }
    }
    func signed(_ places: Int) -> (Double) -> String { { String(format: "%+.*f", places, $0) } }
    func decimal(_ places: Int) -> (Double) -> String { { String(format: "%.*f", places, $0) } }

    func panelHeading(_ title: String, trailing: NSView?) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12); row.heightAnchor.constraint(equalToConstant: 35).isActive = true
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 9, weight: .bold); label.textColor = NSColor(hex: "949CA7")
        row.addArrangedSubview(label); row.addArrangedSubview(NSView()); if let trailing { row.addArrangedSubview(trailing) }
        return row
    }
    func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 9, weight: .bold); label.textColor = .systemPink; return label
    }
    func propertyLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 10, weight: .medium); label.textColor = NSColor(hex: "C8CDD5"); return label
    }
    func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 10, weight: .medium); return button
    }
    func iconButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let button: NSButton
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) { button = NSButton(image: image, target: self, action: action); button.imagePosition = .imageOnly }
        else { button = NSButton(title: "•", target: self, action: action) }
        button.bezelStyle = .texturedRounded; button.toolTip = tooltip; button.contentTintColor = NSColor(hex: "C1C7D0"); button.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return button
    }
    func configureHistoryButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip); button.imagePosition = .imageOnly; button.target = self; button.action = action; button.bezelStyle = .texturedRounded; button.toolTip = tooltip; button.keyEquivalent = key; button.keyEquivalentModifierMask = modifiers; button.widthAnchor.constraint(equalToConstant: 30).isActive = true
    }
    func separator(vertical: Bool = false) -> NSBox {
        let box = NSBox(); box.boxType = .separator
        if vertical { box.widthAnchor.constraint(equalToConstant: 1).isActive = true } else { box.heightAnchor.constraint(equalToConstant: 1).isActive = true }
        return box
    }
}
