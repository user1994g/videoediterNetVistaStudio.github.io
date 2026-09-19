import Cocoa
import CoreImage
import UniformTypeIdentifiers

#if PHOTO_EDITOR_CHECKS
extension PhotoEditorViewController {
    func showBrushesForChecks() { selectTool(.brush); brushSettingsChanged() }
    func checkBrushInputEvents() {
        view.layoutSubtreeIfNeeded()
        precondition(abs(brushBrowser.frame.width - (brushBrowser.enclosingScrollView?.contentSize.width ?? 0)) < 1,"Both brush columns must fit in the library viewport")
        let brushPoint = brushBrowser.convert(NSPoint(x:brushBrowser.bounds.width*0.75,y:30),to:nil)
        let choose = NSEvent.mouseEvent(with:.leftMouseDown,location:brushPoint,modifierFlags:[],timestamp:0,windowNumber:view.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        brushBrowser.mouseDown(with:choose)
        precondition(brushPopup.indexOfSelectedItem == 1 && brushHardness.doubleValue == 0,"Clicking Soft round should select that tip")
        let hardnessField = brushValueFields[1]; hardnessField.stringValue = "50%"; brushNumberChanged(hardnessField)
        precondition(brushHardness.doubleValue == 0.5)
        foreground.color = .red; brushOpacity.doubleValue = 100; brushFlow.doubleValue = 100; brushSize.doubleValue = 80; brushSettingsChanged()
        let point = canvasView.convert(NSPoint(x:canvasView.bounds.midX,y:canvasView.bounds.midY),to:nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent { NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:1,windowNumber:view.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)! }
        canvasView.mouseDown(with:mouse(.leftMouseDown)); canvasView.mouseUp(with:mouse(.leftMouseUp))
        var pixel = [UInt8](repeating:0,count:4)
        context.render(selectedLayer!.sourceImage,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:documentSize.width/2,y:documentSize.height/2,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        precondition(pixel[0] > 230 && pixel[1] < 20,"Native mouse events must paint at the pointer location")
        undoEdit()
        let key = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:2,windowNumber:view.window!.windowNumber,context:nil,characters:"e",charactersIgnoringModifiers:"e",isARepeat:false,keyCode:14)!
        canvasView.keyDown(with:key); precondition(selectedTool == .eraser)
        chooseBrush(); precondition(selectedTool == .eraser,"Choosing a tip must not turn Eraser back into Brush")
        selectTool(.brush); brushPopup.selectItem(at:0); chooseBrush()
        print("PASS: native brush hit-testing, soft tip selection, numeric hardness, pointer painting, undo, keyboard shortcuts, eraser persistence")
    }
    func runPhotoRegressionChecks(projectURL: URL) throws {
        offeredNewDocument = true
        loadView()
        createDocument(size: CGSize(width:64,height:64),dpi:300,background:nil)
        func pixel(_ image: CIImage, _ x: Int = 32, _ y: Int = 32) -> [UInt8] {
            var bytes = [UInt8](repeating:0,count:4)
            context.render(image,toBitmap:&bytes,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB()); return bytes
        }
        func rendered() -> CIImage { composite(renderStates(),documentSize:documentSize,maxSide:nil,bypassAdjustments:false,opaqueBackground:false)! }
        precondition(layers.count == 1 && layers[0].sourceURL == nil && pixel(rendered())[3] == 0)
        foreground.color = .red; brushSize.doubleValue = 20; brushFlow.doubleValue = 100; selectTool(.brush)
        paint(CGPoint(x:32,y:32),phase:0,flags:[]); paint(CGPoint(x:32,y:32),phase:2,flags:[])
        precondition(pixel(rendered())[0] > 230 && pixel(rendered())[3] == 255, "Controller brush must render on blank canvas")
        let opacityField = sliderValueLabels[ObjectIdentifier(layerOpacity)]!; opacityField.stringValue = "50%"; numericPropertyChanged(opacityField)
        precondition(selectedLayer!.opacity == 0.5, "Exact numeric property edits must update the layer")
        undoEdit(); precondition(selectedLayer!.opacity == 1)
        undoEdit(); precondition(pixel(rendered())[3] == 0); redoEdit(); precondition(pixel(rendered())[0] > 230)
        let original = selectedLayer!
        original.extras.maskPNG = try PhotoPixels.png(CIImage(color:.black).cropped(to:original.sourceImage.extent),context:context)
        precondition(pixel(rendered())[3] == 0,"Black mask must hide without deleting pixels")
        precondition(pixel(original.sourceImage)[0] > 230)
        original.extras.maskPNG = nil
        duplicateLayer(); precondition(layers.count == 2); deleteLayer(); precondition(layers.count == 1)
        addAdjustmentLayer(); selectedLayer!.adjustments.saturation = 0
        let gray = pixel(rendered()); precondition(abs(Int(gray[0])-Int(gray[1])) < 3, "Adjustment layer must affect pixels below")
        selectedLayer!.isVisible = false; precondition(pixel(rendered())[0] > 230)
        selectedLayer!.isVisible = true
        let folder = PhotoLayer(name:"Folder",sourceURL:nil,sourceImage:CIImage(color:.clear).cropped(to:CGRect(x:0,y:0,width:1,height:1)),thumbnail:nil)
        folder.extras.isGroup = true; original.extras.groupID = folder.id; layers.append(folder)
        folder.isVisible = false; precondition(pixel(rendered())[3] == 0,"Hidden folder hides its contents")
        folder.isVisible = true; folder.isLocked = true; precondition(!editable(original)); folder.isLocked = false
        original.extras.maskPNG = try PhotoPixels.png(CIImage(color:.white).cropped(to:original.sourceImage.extent),context:context)
        original.extras.skew = 0.1; original.extras.text = "Metadata test"; original.extras.fontName = "Helvetica"; original.extras.fontSize = 20
        let before = pixel(rendered()); writeProject(to:projectURL)
        let saved = try JSONDecoder().decode(PhotoProjectFile.self,from:Data(contentsOf:projectURL))
        precondition(saved.version == 2 && saved.layers.allSatisfy { $0.pixels != nil } && saved.dpi == 300)
        layers = []; openPhotoProject(projectURL)
        precondition(layers.count == 3 && documentDPI == 300 && pixel(rendered()) == before,"Layered project round trip")
        precondition(layers.contains { $0.extras.maskPNG != nil && $0.extras.text == "Metadata test" && $0.extras.groupID != nil })
        let selected = layers.first { !$0.extras.isGroup && !$0.extras.isAdjustment }!
        selectedLayerID = selected.id; selected.extras.text = nil; selected.extras.skew = 0
        canvasView.selectionMask = CIImage(color:.white).cropped(to:CGRect(x:25,y:25,width:14,height:14)).composited(over:CIImage(color:.black).cropped(to:CGRect(x:0,y:0,width:64,height:64)))
        let count = layers.count; liftSelection(); precondition(layers.count == count+1 && selectedLayer!.sourceImage.extent.width == 14 && selectedLayer!.sourceImage.extent.height == 14,"Lifted selections need their own transform bounds")
        undoEdit(); precondition(layers.count == count)
        let transform = layerTransform(size:CGSize(width:32,height:20),position:CGPoint(x:12,y:-5),scale:2,rotation:35,skew:0.3,document:CGSize(width:64,height:64))
        let p = CGPoint(x:3,y:8), roundTrip = p.applying(transform).applying(transform.inverted())
        precondition(hypot(roundTrip.x-p.x,roundTrip.y-p.y) < 0.00001)
        selectedLayerID = layers.first { !$0.extras.isGroup && !$0.extras.isAdjustment }!.id
        selectTool(.marquee); canvasView.clearSelection()
        createDocument(size:CGSize(width:1920,height:1080),dpi:72,background:.white)
        view.frame = NSRect(x:0,y:0,width:1320,height:820); view.layoutSubtreeIfNeeded()
        print("PASS: blank documents, controller painting, undo/redo, masks, duplicate/delete, adjustments, folder visibility/locking, embedded project round trip, inverse transform, native workspace layout")
    }
}
#endif

private final class PhotoFlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
    override func addArrangedSubview(_ view: NSView) {
        alignment = .leading
        super.addArrangedSubview(view)
        let width = view.widthAnchor.constraint(equalTo: widthAnchor, constant: -(edgeInsets.left+edgeInsets.right)); width.priority = .init(999); width.isActive = true
    }
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

private final class PhotoSwatchWell: NSColorWell {
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) { super.mouseDown(with:event) }
        else { sendAction(action, to:target) }
    }
}

private final class PhotoFlatButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            NSColor(hex:"454A52").setFill(); NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:3,yRadius:3).fill()
        }
        super.draw(dirtyRect)
    }
}

private final class PhotoToneCurveView: NSView {
    var values = [0.25,0.5,0.75] { didSet { needsDisplay = true } }
    var isEnabled = true
    var onBegin: (() -> Void)?
    var onChange: (([Double]) -> Void)?
    private var draggingIndex: Int?
    private var plot: CGRect { bounds.insetBy(dx:12,dy:12) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex:"111419").setFill(); bounds.fill()
        let grid = NSBezierPath(); grid.lineWidth = 1
        for i in 0...4 {
            let f = Double(i)/4
            grid.move(to:CGPoint(x:plot.minX+plot.width*f,y:plot.minY)); grid.line(to:CGPoint(x:plot.minX+plot.width*f,y:plot.maxY))
            grid.move(to:CGPoint(x:plot.minX,y:plot.minY+plot.height*f)); grid.line(to:CGPoint(x:plot.maxX,y:plot.minY+plot.height*f))
        }
        NSColor(hex:"30353D").setStroke(); grid.stroke()
        let ys = [0.0]+values+[1.0]
        let points = ys.enumerated().map { CGPoint(x:plot.minX+Double($0.offset)*plot.width/4,y:plot.minY+$0.element*plot.height) }
        let curve = NSBezierPath(); curve.move(to:points[0])
        for i in 0..<4 {
            let a = points[i], b = points[i+1], dx = (b.x-a.x)/3
            let slopeA = i == 0 ? (ys[1]-ys[0])*4 : (ys[i+1]-ys[i-1])*2
            let slopeB = i == 3 ? (ys[4]-ys[3])*4 : (ys[i+2]-ys[i])*2
            curve.curve(to:b,controlPoint1:CGPoint(x:a.x+dx,y:a.y+slopeA*plot.height/12),controlPoint2:CGPoint(x:b.x-dx,y:b.y-slopeB*plot.height/12))
        }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect:plot).addClip()
        NSColor.systemPink.setStroke(); curve.lineWidth = 2; curve.stroke(); NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setFill()
        for point in points.dropFirst().dropLast() { NSBezierPath(ovalIn:CGRect(x:point.x-4,y:point.y-4,width:8,height:8)).fill() }
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow,from:nil)
        draggingIndex = min(2,max(0,Int(((p.x-plot.minX)/plot.width*4).rounded())-1))
        onBegin?(); mouseDragged(with:event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let index = draggingIndex else { return }
        let p = convert(event.locationInWindow,from:nil)
        values[index] = min(1,max(0,(p.y-plot.minY)/plot.height)); onChange?(values)
    }
    override func mouseUp(with event: NSEvent) { draggingIndex = nil }
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

private struct PhotoLayerExtras: Codable {
    var groupID: UUID? = nil
    var isGroup = false
    var isAdjustment = false
    var maskPNG: Data? = nil
    var skew = 0.0
    var hue = 0.0
    var black = 0.0
    var white = 1.0
    var midtone = 0.5
    var curveShadows = 0.25
    var curveHighlights = 0.75
    var noise = 0.0
    var text: String? = nil
    var fontName: String? = nil
    var fontSize: Double? = nil
    var textColor: [Double]? = nil
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
    var sourceImage: CIImage
    var thumbnail: NSImage?
    var isVisible = true
    var isLocked = false
    var opacity = 1.0
    var blendMode = PhotoBlendMode.normal
    var position = CGPoint.zero
    var scale = 1.0
    var rotation = 0.0
    var adjustments = PhotoAdjustments()
    var extras = PhotoLayerExtras()
    var maskPreview: CIImage?

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
    var extras = PhotoLayerExtras()
    var maskPreview: CIImage? = nil
}

private struct PhotoDocumentSnapshot {
    let layers: [PhotoLayerSnapshot]
    let selectedLayerID: UUID?
    let documentSize: CGSize
    let documentName: String
    var dpi = 72.0
    var projectURL: URL? = nil
}

private enum PhotoTool: Int, CaseIterable {
    case move, marquee, lasso, wand, brush, eraser, bucket, clone, heal, text, rectangle, ellipse, line, polygon, eyedropper, hand, zoom

    var title: String {
        switch self {
        case .move: return "Move Tool"
        case .marquee: return "Rectangular Select"
        case .hand: return "Hand Tool"
        case .zoom: return "Zoom Tool"
        case .lasso: return "Lasso"
        case .wand: return "Magic Wand"
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .bucket: return "Paint Bucket"
        case .clone: return "Clone Stamp"
        case .heal: return "Healing Brush"
        case .text: return "Text"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .polygon: return "Custom Polygon"
        case .eyedropper: return "Eyedropper"
        }
    }

    var hint: String {
        switch self {
        case .move: return "Drag the selected unlocked layer on the canvas"
        case .marquee: return "Drag to create a non-destructive canvas selection"
        case .hand: return "Drag to navigate the canvas"
        case .zoom: return "Click to zoom in; hold Option to zoom out"
        case .clone, .heal: return "Option-click a source, then paint on the same layer"
        case .brush, .eraser: return "Paint on the selected layer or its mask • [ / ] changes size"
        case .lasso: return "Draw a closed selection; painting and fill stay inside it"
        case .wand: return "Click a connected colour region • set tolerance in Tools"
        case .bucket: return "Fill a connected colour region, respecting the selection"
        case .text: return "Click to create a text layer • Edit Text to change it"
        case .rectangle, .ellipse, .line: return "Drag to create a shape on its own layer"
        case .polygon: return "Draw a closed custom shape on its own layer"
        case .eyedropper: return "Click the canvas to sample the visible colour"
        }
    }

    var symbol: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .marquee: return "rectangle.dashed"
        case .hand: return "hand.draw"
        case .zoom: return "magnifyingglass"
        case .lasso: return "lasso"
        case .wand: return "wand.and.stars"
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .bucket: return "drop.fill"
        case .clone: return "seal"
        case .heal: return "bandage"
        case .text: return "textformat"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .polygon: return "pentagon"
        case .eyedropper: return "eyedropper"
        }
    }
}

// Virtualised tip grid: a large ABR pack does not create hundreds of native controls
// or generate full-resolution thumbnails just to scroll the library.
private final class PhotoBrushScrollView: NSScrollView {
    override func tile() {
        super.tile()
        if let documentView { documentView.setFrameSize(NSSize(width:contentSize.width,height:documentView.frame.height)) }
    }
}
private final class PhotoBrushBrowser: NSView {
    var brushes: [PhotoBrush] = [] { didSet { thumbnails.removeAll(); filter(query) } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    private var query = ""
    private var indices: [Int] = []
    private var thumbnails: [Int:NSImage] = [:]
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func filter(_ text: String) {
        query = text
        indices = brushes.indices.filter { text.isEmpty || brushes[$0].name.localizedCaseInsensitiveContains(text) }
        setFrameSize(NSSize(width:max(1,frame.width),height:max(66,CGFloat((indices.count+1)/2)*66)))
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex:"202329").setFill(); dirtyRect.fill()
        if indices.isEmpty { ("No matching brushes" as NSString).draw(at:NSPoint(x:10,y:18),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.secondaryLabelColor]); return }
        let width = bounds.width/2
        for row in max(0,Int(dirtyRect.minY/66))..<min((indices.count+1)/2,Int(dirtyRect.maxY/66)+1) {
            for column in 0..<2 {
                let item = row*2+column; guard indices.indices.contains(item) else { continue }
                let index = indices[item], brush = brushes[index]
                let rect = NSRect(x:CGFloat(column)*width+2,y:CGFloat(row)*66+2,width:width-4,height:62)
                (index == selected ? NSColor(hex:"354D67") : NSColor(hex:"292D33")).setFill(); NSBezierPath(roundedRect:rect,xRadius:4,yRadius:4).fill()
                if thumbnails[index] == nil, let cg = brush.tip(color:.white,hardness:brush.hardness,maxDimension:64) { thumbnails[index] = NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height)) }
                if let tip = thumbnails[index] {
                    let factor = 25/max(tip.size.width,tip.size.height), size = NSSize(width:tip.size.width*factor,height:tip.size.height*factor)
                    tip.draw(in:NSRect(x:rect.midX-size.width/2,y:rect.minY+5,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:0.85,respectFlipped:true,hints:nil)
                }
                let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
                (brush.name as NSString).draw(in:NSRect(x:rect.minX+5,y:rect.minY+36,width:rect.width-10,height:18),withAttributes:[.font:NSFont.systemFont(ofSize:10,weight:index == selected ? .semibold : .regular),.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph])
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        let item = Int(point.y/66)*2 + (point.x >= bounds.width/2 ? 1 : 0)
        guard indices.indices.contains(item) else { return }
        selected = indices[item]; onSelect?(selected)
    }
    func revealSelection() {
        guard let item = indices.firstIndex(of:selected) else { return }
        scrollToVisible(NSRect(x:0,y:CGFloat(item/2)*66,width:bounds.width,height:66))
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
        return urls.filter { PhotoEditorViewController.supportsImage($0) || ["abr","netvistabrush"].contains($0.pathExtension.lowercased()) }
    }
}

private final class PhotoCanvasView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var documentSize = CGSize.zero { didSet { publishZoom(); needsDisplay = true } }
    var selectedTool = PhotoTool.move { didSet { window?.invalidateCursorRects(for:self) } }
    var canMoveLayer = false
    var onMoveLayer: ((CGPoint, Bool) -> Void)?
    var onZoomChanged: ((Double) -> Void)?
    var onSelectionChanged: ((CGRect?) -> Void)?
    var onToolEvent: ((CGPoint, Int, NSEvent.ModifierFlags) -> Void)?
    var onBrushSize: ((Double) -> Void)?
    var onToolShortcut: ((String) -> Void)?
    var brushDiameter = 40.0 { didSet { needsDisplay = true } }
    private var pointer: CGPoint?
    private var pointerTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area); pointerTracking = area
    }
    override func mouseMoved(with event: NSEvent) { pointer = convert(event.locationInWindow,from:nil); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { pointer = nil; needsDisplay = true }
    var selectionMask: CIImage?
    var selectionOutline: CGPath? { didSet { needsDisplay = true } }
    var gestureOutline: CGPath? { didSet { needsDisplay = true } }
    var showsRulers = true { didSet { needsDisplay = true } }
    private var gestureStarted = false

    private var zoomMultiplier = 1.0
    private var panOffset = CGPoint.zero
    private var dragStart = CGPoint.zero
    private var lastDragPoint = CGPoint.zero
    private var selectionStart: CGPoint?
    private(set) var documentSelection: CGRect?
    private var lastPublishedZoom = -1.0

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {
        let cursor: NSCursor = selectedTool == .hand ? .openHand : selectedTool == .move ? .arrow : .crosshair
        addCursorRect(bounds,cursor:cursor)
    }
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
    func clearSelection() { documentSelection = nil; selectionMask = nil; selectionOutline = nil; onSelectionChanged?(nil); needsDisplay = true }
    var documentSelectionRect: CGRect? {
        guard let documentSelection, documentSize.width > 0, documentSize.height > 0 else { return nil }
        let clipped = documentSelection.intersection(CGRect(origin: .zero, size: documentSize)).integral
        return clipped.width > 1 && clipped.height > 1 ? clipped : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(hex: "25272C").setFill(); dirtyRect.fill()
        guard documentSize.width > 0, documentSize.height > 0 else { drawEmptyState(); return }
        let rect = imageRect
        drawCheckerboard(in: rect)
        image?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
        NSColor.black.withAlphaComponent(0.85).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)); border.lineWidth = 1; border.stroke()
        if let documentSelection {
            let selectionRect = viewRect(forDocumentRect: documentSelection)
            NSGraphicsContext.saveGraphicsState()
            let path = NSBezierPath(rect: selectionRect); path.setLineDash([5, 4], count: 2, phase: 0); path.lineWidth = 1; NSColor.white.setStroke(); path.stroke()
            let shadow = NSBezierPath(rect: selectionRect.insetBy(dx: 1, dy: 1)); shadow.setLineDash([5, 4], count: 2, phase: 5); NSColor.black.setStroke(); shadow.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        if let c = NSGraphicsContext.current?.cgContext {
            c.saveGState(); c.clip(to: imageRect); c.translateBy(x: imageRect.minX, y: imageRect.minY); c.scaleBy(x: effectiveScale, y: effectiveScale)
            if let mask = selectionMask, selectionOutline == nil, let cg = CIContext().createCGImage(mask, from: mask.extent) {
                c.setAlpha(0.22); c.draw(cg, in: CGRect(origin: .zero, size: documentSize)); c.setAlpha(1)
            }
            for path in [selectionOutline, gestureOutline].compactMap({ $0 }) {
                c.addPath(path); c.setStrokeColor(NSColor.white.cgColor); c.setLineWidth(1/effectiveScale); c.setLineDash(phase: 0, lengths: [5/effectiveScale, 4/effectiveScale]); c.strokePath()
            }
            c.restoreGState()
        }
        if showsRulers { drawRulers() }
        if [.brush,.eraser,.clone,.heal].contains(selectedTool), let pointer, imageRect.contains(pointer) {
            let diameter = max(3,brushDiameter*effectiveScale)
            let circle = NSBezierPath(ovalIn:NSRect(x:pointer.x-diameter/2,y:pointer.y-diameter/2,width:diameter,height:diameter))
            NSColor.black.withAlphaComponent(0.8).setStroke(); circle.lineWidth = 2; circle.stroke()
            NSColor.white.withAlphaComponent(0.95).setStroke(); circle.lineWidth = 1; circle.stroke()
        }
    }
    private func drawRulers() {
        let height = 28.0
        NSColor(hex:"272A2E").setFill(); CGRect(x:0,y:bounds.height-height,width:bounds.width,height:height).fill(); CGRect(x:0,y:0,width:height,height:bounds.height).fill()
        let step = pow(10,floor(log10(max(1,80/effectiveScale))))
        let unit = step * (step*effectiveScale < 35 ? 5 : 1)
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:8,weight:.regular),.foregroundColor:NSColor(hex:"949BA5")]
        let ticks = NSBezierPath(); ticks.lineWidth = 0.5
        let firstX = floor((height-imageRect.minX)/effectiveScale/unit)*unit
        var value = firstX
        while imageRect.minX+value*effectiveScale < bounds.width {
            let x = imageRect.minX+value*effectiveScale
            if x > height { ticks.move(to:CGPoint(x:x,y:bounds.height-height)); ticks.line(to:CGPoint(x:x,y:bounds.height-height+5)); String(Int(value)).draw(at:CGPoint(x:x+3,y:bounds.height-13),withAttributes:attributes) }
            value += unit
        }
        let firstY = floor(-imageRect.minY/effectiveScale/unit)*unit; value = firstY
        while imageRect.minY+value*effectiveScale < bounds.height-height {
            let y = imageRect.minY+value*effectiveScale
            if y > 0 {
                ticks.move(to:CGPoint(x:height-5,y:y)); ticks.line(to:CGPoint(x:height,y:y))
                String(Int(documentSize.height-value)).draw(at:CGPoint(x:1,y:y+2),withAttributes:attributes)
            }
            value += unit
        }
        NSColor(hex:"747B84").setStroke(); ticks.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point; lastDragPoint = point
        gestureStarted = imageRect.contains(point)
        if selectedTool == .zoom { zoom(by: event.modifierFlags.contains(.option) ? 0.8 : 1.25, around: point) }
        else if selectedTool == .marquee {
            selectionMask = nil; selectionOutline = nil
            let start = clampedDocumentPoint(from: point)
            selectionStart = start; documentSelection = CGRect(origin: start, size: .zero); needsDisplay = true
        }
        else if gestureStarted { onToolEvent?(clampedDocumentPoint(from: point), 0, event.modifierFlags) }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
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
        default: if gestureStarted { onToolEvent?(clampedDocumentPoint(from: point), 1, event.modifierFlags) }
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
        else if gestureStarted { onToolEvent?(clampedDocumentPoint(from: convert(event.locationInWindow, from: nil)), 2, event.modifierFlags) }
        gestureStarted = false
    }
    override func keyDown(with event: NSEvent) {
        if !event.modifierFlags.intersection([.command,.control,.option]).isEmpty { super.keyDown(with:event); return }
        if let key = event.charactersIgnoringModifiers?.lowercased(), ["b","e","v","h","z","i","m","l","g","s","j","t"].contains(key) { onToolShortcut?(key) }
        else if event.characters == "[" { onBrushSize?(0.8) }
        else if event.characters == "]" { onBrushSize?(1.25) }
        else { super.keyDown(with: event) }
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
        let visible = rect.intersection(bounds)
        var row = Int(floor((visible.minY-rect.minY)/cell)); var y = rect.minY + Double(row)*cell
        while y < visible.maxY {
            var column = Int(floor((visible.minX-rect.minX)/cell)); var x = rect.minX + Double(column)*cell
            while x < visible.maxX { if (row + column).isMultiple(of: 2) { CGRect(x: x, y: y, width: cell, height: cell).fill() }; x += cell; column += 1 }
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
    private let contextOptions = NSStackView()
    private let selectionLabel = NSTextField(labelWithString: "No active selection")
    private let blendPopup = NSPopUpButton()
    private let lockButton = NSButton(checkboxWithTitle: "Lock layer", target: nil, action: nil)
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let showOriginal = NSButton(checkboxWithTitle: "Bypass adjustments", target: nil, action: nil)

    private var layers: [PhotoLayer] = [] // Topmost layer is first.
    private var selectedLayerID: UUID?
    private var documentSize = CGSize.zero
    private var documentDPI = 72.0
    private var brushLibrary = PhotoBrush.defaults
    private let brushPopup = NSPopUpButton()
    private let brushBrowser = PhotoBrushBrowser()
    private let brushSearch = NSSearchField()
    private let brushLibraryLabel = NSTextField(labelWithString: "")
    private let brushImportQueue = DispatchQueue(label:"netvista.photos.brush-import",qos:.userInitiated)
    private var importingBrushes = false
    private var brushValueFields: [NSTextField] = []
    private let foreground = NSColorWell()
    private let brushSize = NSSlider(value: 40, minValue: 1, maxValue: 800, target: nil, action: nil)
    private let brushHardness = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let brushOpacity = NSSlider(value: 100, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let brushFlow = NSSlider(value: 50, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let tolerance = NSSlider(value: 24, minValue: 0, maxValue: 255, target: nil, action: nil)
    private let maskEditing = NSButton(checkboxWithTitle: "Paint layer mask (black hides, white reveals)", target: nil, action: nil)
    private let toolSettingsLabel = NSTextField(labelWithString: "")
    private let inspectorTabs = NSTabView()
    private var inspectorTabButtons: [NSButton] = []
    private let toneCurve = PhotoToneCurveView()
    private var activeStroke: PhotoRasterStroke?
    private var strokeLayerID: UUID?
    private var strokeMask = false
    private var lastStrokePreview = 0.0
    private var cloneSource: CGPoint?
    private var cloneLayerID: UUID?
    private var gesturePoints: [CGPoint] = []
    private var extrasSliders: [String: PhotoTrackedSlider] = [:]
    private var collapsedGroups = Set<UUID>()
    private var newDocumentFields: [NSTextField] = []
    private var offeredNewDocument = false
    private var selectedTool = PhotoTool.move
    private var toolButtons: [PhotoTool: NSButton] = [:]
    private var undoHistory: [PhotoDocumentSnapshot] = []
    private var redoHistory: [PhotoDocumentSnapshot] = []
    private var renderGeneration = 0
    private var pendingPreview: DispatchWorkItem?
    private var moveUndoSnapshot: PhotoDocumentSnapshot?
    private var projectURL: URL?
    private var activePhotoExports = 0
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
    override func viewDidAppear() {
        super.viewDidAppear()
        if !offeredNewDocument {
            offeredNewDocument = true
            DispatchQueue.main.async { [weak self] in
                // File-open routing may have imported a photo/project after the window appeared.
                guard let self, self.projectURL == nil, self.undoHistory.isEmpty, self.layers.count == 1, self.layers.first?.name == "Background" else { return }
                self.newDocument()
            }
        }
    }

    override func loadView() {
        let dropView = PhotoDropView()
        dropView.onDrop = { [weak self] urls in
            guard let self else { return }
            let tips = urls.filter { ["abr","netvistabrush"].contains($0.pathExtension.lowercased()) }
            if !tips.isEmpty { self.importBrushURLs(tips) }
            self.openImages(urls.filter { Self.supportsImage($0) })
        }
        dropView.wantsLayer = true; dropView.layer?.backgroundColor = NSColor(hex: "101216").cgColor
        view = dropView
        configureCanvas()
        foreground.color = .black
        if let data = UserDefaults.standard.data(forKey: "netvista.photos.brushLibrary"), data.count <= 96*1024*1024, let saved = try? JSONDecoder().decode([PhotoBrush].self, from: data) { brushLibrary += saved.prefix(1020).filter(\.isValid) }

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
        selectTool(.brush); rebuildLayersPanel(); syncInspector(); updateHistoryButtons()
        if documentSize == .zero { createDocument(size: CGSize(width: 1920, height: 1080), dpi: 72, background: .white) }
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
            guard PhotoPixels.validSize(loaded.extent.size) else { return nil }
            return (url, normalized(loaded), NSImage(contentsOf: url))
        }
        guard !decoded.isEmpty else { statusLabel.stringValue = "No supported images could be opened"; return }

        pushHistory()
        if documentSize == .zero, let first = decoded.first { documentSize = first.source.extent.size }
        for item in decoded {
            let layer = PhotoLayer(name: item.url.deletingPathExtension().lastPathComponent, sourceURL: item.url, sourceImage: item.source, thumbnail: item.thumbnail)
            layer.scale = min(1, min(documentSize.width / max(item.source.extent.width, 1), documentSize.height / max(item.source.extent.height, 1)))
            layer.extras.groupID = selectedLayer?.extras.isGroup == true ? selectedLayerID : selectedLayer?.extras.groupID
            var index = layers.firstIndex { $0.id == selectedLayerID } ?? 0
            if selectedLayer?.extras.isGroup == true { index += 1 }
            layers.insert(layer, at: index); selectedLayerID = layer.id
        }
        documentLabel.stringValue = decoded.count == 1 ? decoded[0].url.lastPathComponent : "Untitled Composite"
        statusLabel.stringValue = decoded.count == 1 ? "Imported 1 layer" : "Imported \(decoded.count) layers"
        refreshDocumentUI(renderImmediately: true)
    }

    private func configureCanvas() {
        canvasView.onToolEvent = { [weak self] point, phase, flags in self?.handleTool(point, phase: phase, flags: flags) }
        canvasView.onBrushSize = { [weak self] factor in guard let self else { return }; self.brushSize.doubleValue = min(800, max(1, self.brushSize.doubleValue * factor)); self.brushSettingsChanged() }
        canvasView.onToolShortcut = { [weak self] key in
            let tools: [String:PhotoTool] = ["b":.brush,"e":.eraser,"v":.move,"h":.hand,"z":.zoom,"i":.eyedropper,"m":.marquee,"l":.lasso,"g":.bucket,"s":.clone,"j":.heal,"t":.text]
            if let tool = tools[key] { self?.selectTool(tool) }
        }
        canvasView.onMoveLayer = { [weak self] delta, finished in
            guard let self, let layer = self.selectedLayer, self.editable(layer), !layer.extras.isAdjustment else { return }
            if finished {
                if let snapshot = self.moveUndoSnapshot {
                    self.undoHistory.append(snapshot); self.redoHistory.removeAll(); self.moveUndoSnapshot = nil; self.updateHistoryButtons()
                }
                return
            }
            guard delta != .zero else { return }
            if self.moveUndoSnapshot == nil { self.moveUndoSnapshot = self.snapshot() }
            let targets = layer.extras.isGroup ? self.layers.filter { $0.extras.groupID == layer.id && !$0.isLocked } : [layer]
            for target in targets { target.position.x += delta.x; target.position.y += delta.y }
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
        let bar = NSStackView(); bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 5
        bar.edgeInsets = NSEdgeInsets(top:0,left:8,bottom:0,right:10); bar.heightAnchor.constraint(equalToConstant:40).isActive = true
        bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor(hex:"24262A").cgColor
        let home = iconButton("house", "Studio Home", #selector(showStudioHome)); home.widthAnchor.constraint(equalToConstant:28).isActive = true
        let title = NSTextField(labelWithString:"Photos"); title.font = .systemFont(ofSize:13,weight:.semibold); title.textColor = NSColor(hex:"E3E5E8")
        bar.addArrangedSubview(home); bar.addArrangedSubview(title); bar.addArrangedSubview(separator(vertical:true))
        bar.addArrangedSubview(commandMenu("File", [
            ("New Document…",#selector(newDocument)),("Open Project…",#selector(openProjectPanel)),("Import Image Layers…",#selector(importPhotos)),("Save",#selector(saveProject)),("Save As…",#selector(saveProjectAs)),("Export PNG / JPEG…",#selector(exportPhoto))]))
        bar.addArrangedSubview(commandMenu("Edit",[("Undo",#selector(undoEdit)),("Redo",#selector(redoEdit)),("Reset Layer Properties",#selector(resetSelectedLayer))]))
        bar.addArrangedSubview(commandMenu("Layer",[("New Pixel Layer",#selector(addBlankLayer)),("New Adjustment Layer",#selector(addAdjustmentLayer)),("Duplicate Layer",#selector(duplicateLayer)),("Rename Layer…",#selector(renameLayer)),("Folders…",#selector(groupLayer)),("Layer Mask…",#selector(maskAction)),("Delete Layer",#selector(deleteLayer))]))
        bar.addArrangedSubview(commandMenu("Select",[("Deselect",#selector(clearSelection)),("Crop to Selection",#selector(cropToSelection)),("Lift Selection to Layer",#selector(liftSelection))]))
        bar.addArrangedSubview(commandMenu("View",[("Fit Canvas",#selector(fitCanvas)),("Actual Pixels",#selector(actualCanvas)),("Zoom In",#selector(zoomIn)),("Zoom Out",#selector(zoomOut)),("Show / Hide Rulers",#selector(toggleRulers)),("Bypass / Restore Adjustments",#selector(toggleBypass))]))
        bar.addArrangedSubview(NSView())
        documentLabel.font = .systemFont(ofSize:10); documentLabel.textColor = NSColor(hex:"969DA7"); documentLabel.lineBreakMode = .byTruncatingMiddle; documentLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        documentLabel.widthAnchor.constraint(lessThanOrEqualToConstant:180).isActive = true; bar.addArrangedSubview(documentLabel)
        let brand = NSTextField(labelWithString:"NETVISTA STUDIO"); brand.font = .systemFont(ofSize:9,weight:.medium); brand.textColor = NSColor(hex:"858B94"); bar.addArrangedSubview(brand)
        configureHistoryButton(undoButton, symbol: "arrow.uturn.backward", tooltip: "Undo", action: #selector(undoEdit), key: "z", modifiers: [.command])
        configureHistoryButton(redoButton, symbol: "arrow.uturn.forward", tooltip: "Redo", action: #selector(redoEdit), key: "Z", modifiers: [.command, .shift])
        bar.addArrangedSubview(undoButton); bar.addArrangedSubview(redoButton)
        bar.addArrangedSubview(makeButton("Save", #selector(saveProject)))
        bar.addArrangedSubview(makeButton("Export…",#selector(exportPhoto)))
        return bar
    }
    func commandMenu(_ title: String, _ commands: [(String,Selector)]) -> NSView {
        let menu = NSPopUpButton(frame:.zero,pullsDown:true); menu.addItem(withTitle:title); menu.isBordered = false; menu.font = .systemFont(ofSize:11)
        for (name,action) in commands { let item = NSMenuItem(title:name,action:action,keyEquivalent:""); item.target = self; menu.menu?.addItem(item) }
        return menu
    }
    @objc func toggleRulers() { canvasView.showsRulers.toggle() }
    @objc func toggleBypass() { showOriginal.state = showOriginal.state == .on ? .off : .on; toggleOriginal() }

    func makeToolOptionsBar() -> NSView {
        let bar = NSStackView(); bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12); bar.heightAnchor.constraint(equalToConstant: 38).isActive = true
        bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor(hex: "1D2025").cgColor
        toolTitleLabel.font = .systemFont(ofSize: 11, weight: .semibold); toolTitleLabel.textColor = NSColor(hex: "E1E4E9")
        toolHintLabel.font = .systemFont(ofSize: 10); toolHintLabel.textColor = NSColor(hex: "7F8793")
        selectionLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular); selectionLabel.textColor = NSColor(hex: "7F8793")
        toolHintLabel.lineBreakMode = .byTruncatingTail; toolHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contextOptions.orientation = .horizontal; contextOptions.alignment = .centerY; contextOptions.spacing = 5
        bar.addArrangedSubview(toolTitleLabel); bar.addArrangedSubview(separator(vertical: true)); bar.addArrangedSubview(contextOptions); bar.addArrangedSubview(toolHintLabel); bar.addArrangedSubview(NSView())
        bar.addArrangedSubview(selectionLabel)
        return bar
    }

    func makeToolRail() -> NSView {
        let panel = NSStackView(); panel.orientation = .vertical; panel.alignment = .centerX; panel.spacing = 8
        panel.edgeInsets = NSEdgeInsets(top: 8, left: 4, bottom: 8, right: 4); panel.widthAnchor.constraint(equalToConstant: 74).isActive = true; panel.spacing = 2
        panel.wantsLayer = true; panel.layer?.backgroundColor = NSColor(hex: "17191D").cgColor
        var toolRow: NSStackView?
        for (index, tool) in PhotoTool.allCases.enumerated() {
            if index % 2 == 0 { let row = NSStackView(); row.orientation = .horizontal; row.spacing = 2; panel.addArrangedSubview(row); toolRow = row }
            let button = iconButton(tool.symbol, tool.title, #selector(toolPressed(_:)))
            button.tag = tool.rawValue; button.setButtonType(.toggle); button.widthAnchor.constraint(equalToConstant: 30).isActive = true; button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            toolButtons[tool] = button; toolRow?.addArrangedSubview(button)
        }
        panel.addArrangedSubview(separator()); panel.addArrangedSubview(iconButton("arrow.counterclockwise", "Reset selected layer", #selector(resetSelectedLayer))); panel.addArrangedSubview(NSView())
        return panel
    }

    func makeCanvasWorkspace() -> NSView {
        let workspace = NSView()
        workspace.setContentHuggingPriority(.defaultLow, for: .horizontal); workspace.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspace.setContentHuggingPriority(.defaultLow, for: .vertical); workspace.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        canvasView.setContentHuggingPriority(.defaultLow, for: .horizontal); canvasView.setContentHuggingPriority(.defaultLow, for: .vertical)
        canvasView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); canvasView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        canvasView.widthAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true
        let zoomBar = NSStackView(); zoomBar.orientation = .horizontal; zoomBar.alignment = .centerY; zoomBar.spacing = 7; zoomBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10); zoomBar.heightAnchor.constraint(equalToConstant: 32).isActive = true
        zoomBar.wantsLayer = true; zoomBar.layer?.backgroundColor = NSColor(hex: "15171B").cgColor
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); zoomLabel.textColor = NSColor(hex: "AEB5C0"); zoomLabel.alignment = .center; zoomLabel.widthAnchor.constraint(equalToConstant: 54).isActive = true
        zoomBar.addArrangedSubview(makeButton("−", #selector(zoomOut))); zoomBar.addArrangedSubview(zoomLabel); zoomBar.addArrangedSubview(makeButton("+", #selector(zoomIn))); zoomBar.addArrangedSubview(makeButton("Fit", #selector(fitCanvas))); zoomBar.addArrangedSubview(makeButton("100%", #selector(actualCanvas))); zoomBar.addArrangedSubview(NSView())
        let hint = NSTextField(labelWithString: "⌘ scroll to zoom  •  Hand tool to pan"); hint.font = .systemFont(ofSize: 9); hint.textColor = NSColor(hex: "646C77"); zoomBar.addArrangedSubview(hint)
        for item in [canvasView,zoomBar] { item.translatesAutoresizingMaskIntoConstraints = false; workspace.addSubview(item) }
        zoomBar.layer?.zPosition = 10
        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo:workspace.topAnchor),canvasView.leadingAnchor.constraint(equalTo:workspace.leadingAnchor),canvasView.trailingAnchor.constraint(equalTo:workspace.trailingAnchor),canvasView.bottomAnchor.constraint(equalTo:zoomBar.topAnchor),
            zoomBar.bottomAnchor.constraint(equalTo:workspace.bottomAnchor),zoomBar.leadingAnchor.constraint(equalTo:workspace.leadingAnchor),zoomBar.trailingAnchor.constraint(equalTo:workspace.trailingAnchor)
        ])
        return workspace
    }

    func makeRightSidebar() -> NSView {
        let sidebar = NSStackView(); sidebar.orientation = .vertical; sidebar.spacing = 0; sidebar.widthAnchor.constraint(equalToConstant: 310).isActive = true
        sidebar.setContentHuggingPriority(.required, for: .horizontal)
        sidebar.wantsLayer = true; sidebar.layer?.backgroundColor = NSColor(hex: "1A1D22").cgColor
        let tabs = inspectorTabs; tabs.tabViewType = .noTabsNoBorder; tabs.font = .systemFont(ofSize: 11)
        for (title, content) in [("Tools & Brushes", makeBrushPanel()), ("Properties", makeInspectorPanel())] {
            let item = NSTabViewItem(identifier: title); item.label = title; item.view = content; tabs.addTabViewItem(item)
        }
        let tabBar = NSStackView(); tabBar.orientation = .horizontal; tabBar.spacing = 2; tabBar.edgeInsets = NSEdgeInsets(top:2,left:6,bottom:2,right:6); tabBar.heightAnchor.constraint(equalToConstant:30).isActive = true
        for (index,title) in ["Brushes","Properties"].enumerated() {
            let button = PhotoFlatButton(title:title,target:self,action:#selector(inspectorTabChanged(_:))); button.isBordered = false; button.setButtonType(.toggle); button.font = .systemFont(ofSize:11); button.tag = index; button.heightAnchor.constraint(equalToConstant:26).isActive = true; button.widthAnchor.constraint(equalToConstant:90).isActive = true; tabBar.addArrangedSubview(button); inspectorTabButtons.append(button)
        }
        sidebar.addArrangedSubview(tabBar); sidebar.addArrangedSubview(tabs); sidebar.addArrangedSubview(separator()); sidebar.addArrangedSubview(makeLayersPanel())
        for child in sidebar.arrangedSubviews { child.widthAnchor.constraint(equalTo:sidebar.widthAnchor).isActive = true }
        return sidebar
    }

    func makeInspectorPanel() -> NSView {
        let panel = NSStackView(); panel.orientation = .vertical; panel.alignment = .leading; panel.spacing = 0; panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let heading = panelHeading("Properties", trailing: selectedLayerLabel)
        selectedLayerLabel.lineBreakMode = .byTruncatingTail; selectedLayerLabel.alignment = .right; selectedLayerLabel.font = .systemFont(ofSize: 9); selectedLayerLabel.textColor = NSColor(hex: "747D89")
        panel.addArrangedSubview(heading); panel.addArrangedSubview(separator())

        let controls = PhotoFlippedStackView(); controls.orientation = .vertical; controls.alignment = .width; controls.spacing = 10; controls.edgeInsets = NSEdgeInsets(top: 12, left: 13, bottom: 18, right: 13); controls.translatesAutoresizingMaskIntoConstraints = false

        controls.addArrangedSubview(section("TRANSFORM"))
        addExtraSlider("skew", title: "Skew X", value: 0, min: -1.5, max: 1.5, to: controls)
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
        addExtraSlider("hue", title: "Hue shift (degrees)", value: 0, min: -180, max: 180, to: controls)
        configure(saturation, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Saturation", saturation, formatter: decimal(2)))
        configure(vibrance, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Vibrance", vibrance, formatter: signed(2)))
        configure(temperature, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Temperature", temperature, formatter: { String(format: "%.0f K", $0) }))
        configure(tint, action: #selector(adjustmentChanged(_:))); controls.addArrangedSubview(sliderRow("Tint", tint, formatter: signed(0)))

        controls.addArrangedSubview(section("DETAIL & EFFECTS"))
        addExtraSlider("noise", title: "Monochrome grain", value: 0, min: 0, max: 0.5, to: controls)
        controls.addArrangedSubview(section("LEVELS & TONE CURVE"))
        toneCurve.heightAnchor.constraint(equalToConstant:150).isActive = true; toneCurve.toolTip = "Drag the three tone points vertically: shadows, midtones and highlights."
        toneCurve.onBegin = { [weak self] in self?.pushHistory() }
        toneCurve.onChange = { [weak self] values in
            guard let self, let layer = self.selectedLayer, self.editable(layer) else { return }
            layer.extras.curveShadows = values[0]; layer.extras.midtone = values[1]; layer.extras.curveHighlights = values[2]
            self.syncExtras(layer.extras); self.updateSliderLabels(); self.schedulePreview()
        }
        controls.addArrangedSubview(toneCurve)
        addExtraSlider("black", title: "Input black", value: 0, min: 0, max: 0.49, to: controls)
        addExtraSlider("white", title: "Input white", value: 1, min: 0.51, max: 1, to: controls)
        addExtraSlider("curveShadows", title: "Curve · shadows (25%)", value: 0.25, min: 0, max: 1, to: controls)
        addExtraSlider("midtone", title: "Curve · midtones (50%)", value: 0.5, min: 0, max: 1, to: controls)
        addExtraSlider("curveHighlights", title: "Curve · highlights (75%)", value: 0.75, min: 0, max: 1, to: controls)
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
        for child in panel.arrangedSubviews { child.widthAnchor.constraint(equalTo:panel.widthAnchor).isActive = true }
        return panel
    }

    func makeLayersPanel() -> NSView {
        let panel = NSStackView(); panel.orientation = .vertical; panel.alignment = .width; panel.spacing = 0; panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let preferred = panel.heightAnchor.constraint(equalToConstant:290); preferred.priority = .defaultHigh; preferred.isActive = true
        panel.addArrangedSubview(panelHeading("Layers", trailing: nil)); panel.addArrangedSubview(separator())
        let settings = PhotoFlippedStackView(); settings.orientation = .vertical; settings.spacing = 6; settings.edgeInsets = NSEdgeInsets(top:6,left:10,bottom:8,right:10)
        settings.heightAnchor.constraint(equalToConstant:72).isActive = true
        let blendRow = NSStackView(); blendRow.orientation = .horizontal; blendRow.alignment = .centerY; blendRow.spacing = 8
        blendPopup.addItems(withTitles: PhotoBlendMode.allCases.map(\.rawValue)); blendPopup.target = self; blendPopup.action = #selector(blendChanged); blendPopup.font = .systemFont(ofSize:11)
        lockButton.title = "Lock"; lockButton.target = self; lockButton.action = #selector(lockChanged); lockButton.font = .systemFont(ofSize:10)
        blendRow.addArrangedSubview(blendPopup); blendRow.addArrangedSubview(NSView()); blendRow.addArrangedSubview(lockButton); settings.addArrangedSubview(blendRow)
        configure(layerOpacity, action: #selector(layerControlChanged(_:))); settings.addArrangedSubview(sliderRow("Opacity",layerOpacity,formatter:{ String(format:"%.0f%%",$0) }))
        panel.addArrangedSubview(settings); panel.addArrangedSubview(separator())
        layersStack.orientation = .vertical; layersStack.alignment = .width; layersStack.spacing = 2; layersStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6); layersStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.documentView = layersStack
        scroll.setContentHuggingPriority(.defaultLow,for:.vertical); scroll.setContentCompressionResistancePriority(.defaultLow,for:.vertical)
        NSLayoutConstraint.activate([layersStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), layersStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), layersStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), layersStack.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor), layersStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        panel.addArrangedSubview(scroll); panel.addArrangedSubview(separator())
        let actions = NSStackView(); actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 4; actions.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6); actions.heightAnchor.constraint(equalToConstant: 38).isActive = true
        actions.addArrangedSubview(iconButton("plus", "New transparent layer", #selector(addBlankLayer))); actions.addArrangedSubview(iconButton("folder.badge.plus", "Group / ungroup layer…", #selector(groupLayer))); actions.addArrangedSubview(iconButton("rectangle.inset.filled", "Layer mask…", #selector(maskAction))); actions.addArrangedSubview(iconButton("circle.lefthalf.filled", "New adjustment layer", #selector(addAdjustmentLayer))); actions.addArrangedSubview(iconButton("doc.on.doc", "Duplicate selected layer", #selector(duplicateLayer))); actions.addArrangedSubview(iconButton("pencil", "Rename selected layer", #selector(renameLayer))); actions.addArrangedSubview(NSView())
        actions.addArrangedSubview(iconButton("arrow.up", "Move layer up", #selector(moveLayerUp))); actions.addArrangedSubview(iconButton("arrow.down", "Move layer down", #selector(moveLayerDown))); actions.addArrangedSubview(iconButton("trash", "Delete selected layer", #selector(deleteLayer)))
        panel.addArrangedSubview(actions)
        for child in panel.arrangedSubviews { child.widthAnchor.constraint(equalTo:panel.widthAnchor).isActive = true }
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
            let empty = NSTextField(wrappingLabelWithString: "No layers\nPress + for a transparent paint layer")
            empty.alignment = .center; empty.font = .systemFont(ofSize: 11); empty.textColor = NSColor(hex: "747C88"); empty.heightAnchor.constraint(equalToConstant: 70).isActive = true
            layersStack.addArrangedSubview(empty); return
        }
        for (index, layer) in layers.enumerated() {
            if let group = layer.extras.groupID, collapsedGroups.contains(group) { continue }
            layersStack.addArrangedSubview(makeLayerRow(layer, index: index))
        }
    }

    func makeLayerRow(_ layer: PhotoLayer, index: Int) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 6; row.edgeInsets = NSEdgeInsets(top: 4, left: 5, bottom: 4, right: 5); row.heightAnchor.constraint(equalToConstant: 46).isActive = true
        row.wantsLayer = true; row.layer?.cornerRadius = 5; row.layer?.backgroundColor = (layer.id == selectedLayerID ? NSColor(hex: "29384A") : NSColor(hex: "202329")).cgColor
        let visibility = NSButton(image: NSImage(systemSymbolName: layer.isVisible ? "eye" : "eye.slash", accessibilityDescription: layer.isVisible ? "Hide layer" : "Show layer") ?? NSImage(), target: self, action: #selector(toggleLayerVisibility(_:)))
        visibility.tag = index; visibility.isBordered = false; visibility.contentTintColor = layer.isVisible ? NSColor(hex: "D3D8E0") : NSColor(hex: "68717E"); visibility.toolTip = layer.isVisible ? "Hide layer" : "Show layer"; visibility.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let thumb = NSImageView(); thumb.image = layer.thumbnail; thumb.imageScaling = .scaleProportionallyUpOrDown; thumb.wantsLayer = true; thumb.layer?.backgroundColor = NSColor(hex: "111318").cgColor; thumb.layer?.cornerRadius = 3
        if layer.extras.isGroup { thumb.image = NSImage(systemSymbolName:"folder",accessibilityDescription:"Layer folder"); thumb.contentTintColor = .secondaryLabelColor }
        thumb.widthAnchor.constraint(equalToConstant: 36).isActive = true; thumb.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let prefix = layer.extras.isGroup ? (collapsedGroups.contains(layer.id) ? "▸ " : "▾ ") : (layer.extras.groupID != nil ? "    " : "")
        let select = NSButton(title: prefix + layer.name, target: self, action: #selector(selectLayer(_:))); select.tag = index; select.isBordered = false; select.alignment = .left; select.font = .systemFont(ofSize: 11, weight: layer.id == selectedLayerID ? .semibold : .regular); select.contentTintColor = NSColor(hex: "D7DBE2"); select.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: "\(layer.blendMode.rawValue)  ·  \(Int(layer.opacity * 100))%")
        detail.font = .systemFont(ofSize: 8); detail.textColor = NSColor(hex: "7D8591")
        if layer.extras.maskPNG != nil { detail.stringValue += " · Mask" }
        if layer.extras.isAdjustment { detail.stringValue += " · Adjustment" }
        let labels = NSStackView(); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 1; labels.addArrangedSubview(select); labels.addArrangedSubview(detail)
        let lock = iconButton(layer.isLocked ? "lock.fill" : "lock.open", layer.isLocked ? "Unlock layer" : "Lock layer", #selector(toggleLayerLock(_:))); lock.tag = index; lock.widthAnchor.constraint(equalToConstant: 22).isActive = true
        row.addArrangedSubview(visibility); row.addArrangedSubview(thumb); row.addArrangedSubview(labels); row.addArrangedSubview(NSView()); row.addArrangedSubview(lock)
        return row
    }

    func refreshDocumentUI(renderImmediately: Bool = false) {
        canvasView.documentSize = documentSize
        canvasView.canMoveLayer = selectedLayer.map { editable($0) } ?? false
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
        syncExtras(layer.extras)
        setInspectorEnabled(editable(layer)); lockButton.isEnabled = true; updateSliderLabels()
        if layer.extras.isGroup || layer.extras.isAdjustment { [positionX,positionY,layerScale,layerRotation].forEach { $0.isEnabled = false }; extrasSliders["skew"]?.isEnabled = false }
        maskEditing.isEnabled = layer.extras.maskPNG != nil && editable(layer)
    }

    func setInspectorEnabled(_ enabled: Bool) {
        allSliders.forEach { $0.isEnabled = enabled }
        extrasSliders.values.forEach { $0.isEnabled = enabled }
        toneCurve.isEnabled = enabled
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
        refreshToolOptions()
        if [.brush,.eraser,.clone,.heal,.bucket,.wand,.text,.eyedropper].contains(tool) { inspectorTabs.selectTabViewItem(at:0) }
        else if tool == .move { inspectorTabs.selectTabViewItem(at:1) }
        updateInspectorTabs()
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
            if layer.extras.isAdjustment {
                if let data = layer.extras.maskPNG, let mask = CIImage(data:data) { layer.extras.maskPNG = try? PhotoPixels.png(normalized(mask.cropped(to:crop)),context:context) }
                layer.sourceImage = CIImage(color:.clear).cropped(to:CGRect(origin:.zero,size:crop.size))
                continue
            }
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
        let target = layers[sender.tag]
        if target.extras.isGroup && target.id == selectedLayerID {
            if collapsedGroups.contains(target.id) { collapsedGroups.remove(target.id) } else { collapsedGroups.insert(target.id) }
        }
        maskEditing.state = .off
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
        copy.isVisible = original.isVisible; copy.opacity = original.opacity; copy.blendMode = original.blendMode; copy.position = CGPoint(x: original.position.x + 20, y: original.position.y - 20); copy.scale = original.scale; copy.rotation = original.rotation; copy.adjustments = original.adjustments; copy.extras = original.extras
        if original.extras.isGroup {
            let children = layers.filter { $0.extras.groupID == original.id }.map { child -> PhotoLayer in
                let item = PhotoLayer(name: child.name, sourceURL: child.sourceURL, sourceImage: child.sourceImage, thumbnail: child.thumbnail)
                item.isVisible = child.isVisible; item.isLocked = child.isLocked; item.opacity = child.opacity; item.blendMode = child.blendMode; item.position = child.position; item.scale = child.scale; item.rotation = child.rotation; item.adjustments = child.adjustments; item.extras = child.extras; item.extras.groupID = copy.id; return item
            }
            layers.insert(contentsOf: children, at: index)
        }
        layers.insert(copy, at: index); selectedLayerID = copy.id; refreshDocumentUI(); statusLabel.stringValue = "Layer duplicated"
    }
    @objc func deleteLayer() {
        guard let index = selectedLayerID.flatMap({ id in layers.firstIndex { $0.id == id } }) else { NSSound.beep(); return }
        guard editable(layers[index]) else { NSSound.beep(); return }
        let deletedID = layers[index].id
        pushHistory(); let name = layers[index].name; layers.remove(at: index)
        selectedLayerID = layers.indices.contains(index) ? layers[index].id : layers.last?.id
        layers.removeAll { $0.extras.groupID == deletedID }
        if !layers.contains(where: { $0.id == selectedLayerID }) { selectedLayerID = layers.first?.id }
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
        let item = layers[from]; guard editable(item) else { return }
        let siblings = layers.filter { $0.extras.groupID == item.extras.groupID }
        guard let sibling = siblings.firstIndex(where: { $0.id == item.id }), siblings.indices.contains(sibling+offset) else { return }
        let neighbour = siblings[sibling+offset]
        pushHistory()
        let block = layers.filter { $0.id == item.id || $0.extras.groupID == item.id }
        layers.removeAll { $0.id == item.id || $0.extras.groupID == item.id }
        if let anchor = layers.firstIndex(where: { $0.id == neighbour.id }) {
            var insertion = anchor
            if offset > 0 { insertion = (layers.lastIndex(where: { $0.id == neighbour.id || $0.extras.groupID == neighbour.id }) ?? anchor)+1 }
            layers.insert(contentsOf: block, at: insertion)
        }
        refreshDocumentUI()
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
    var pixels: Data? = nil
    var extras: PhotoLayerExtras? = nil
}

private struct PhotoProjectFile: Codable {
    let format: String
    let version: Int
    let canvasWidth: Double
    let canvasHeight: Double
    let selectedLayerID: UUID?
    let layers: [PhotoProjectLayerData]
    var dpi: Double? = nil
}

extension PhotoEditorViewController {
    static func supportsPhotoProject(_ url: URL) -> Bool { url.pathExtension.lowercased() == "netvistaphoto" }

    @discardableResult
    func openPhotoProject(_ url: URL, recordRecent: Bool = true) -> Bool {
        do {
            let data = try Data(contentsOf: url)
            let project = try JSONDecoder().decode(PhotoProjectFile.self, from: data)
            guard project.format == "NetVista Photo Project", (1...2).contains(project.version), project.layers.count <= 1024, PhotoPixels.validSize(CGSize(width: project.canvasWidth, height: project.canvasHeight)) else {
                throw NSError(domain: "NetVistaPhoto", code: 2, userInfo: [NSLocalizedDescriptionKey: "This photo project was created by an unsupported version of NetVista Studio."])
            }
            var loadedLayers: [PhotoLayer] = []
            var missing: [String] = []
            for saved in project.layers {
                let sourceURL = URL(fileURLWithPath: saved.sourcePath)
                let embedded = saved.pixels.flatMap { CIImage(data: $0) }
                guard let image = embedded ?? (saved.sourcePath.isEmpty ? nil : CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true])), PhotoPixels.validSize(image.extent.size) else {
                    missing.append(saved.sourcePath); continue
                }
                let source = normalized(image)
                let layer = PhotoLayer(id: saved.id, name: saved.name, sourceURL: sourceURL, sourceImage: source, thumbnail: NSImage(contentsOf: sourceURL))
                layer.isVisible = saved.isVisible; layer.isLocked = saved.isLocked; layer.opacity = saved.opacity; layer.blendMode = PhotoBlendMode(rawValue: saved.blendMode) ?? .normal
                layer.position = CGPoint(x: saved.positionX, y: saved.positionY); layer.scale = saved.scale; layer.rotation = saved.rotation; layer.adjustments = saved.adjustments.adjustments
                guard abs(saved.positionX) <= 1_000_000, abs(saved.positionY) <= 1_000_000, saved.scale > 0, saved.scale <= 100, abs(saved.rotation) <= 360_000, (0...1).contains(saved.opacity) else { throw PhotoBrushError.invalid("Invalid layer transform in project.") }
                layer.extras = saved.extras ?? PhotoLayerExtras()
                let e = layer.extras
                guard abs(e.skew) <= 10, abs(e.hue) <= 360, (0...1).contains(e.black), (0...1).contains(e.white), (0...1).contains(e.midtone), (0...1).contains(e.curveShadows), (0...1).contains(e.curveHighlights), (0...1).contains(e.noise), e.fontSize == nil || (1...2000).contains(e.fontSize!), e.textColor == nil || (e.textColor!.count == 4 && e.textColor!.allSatisfy { (0...1).contains($0) }) else { throw PhotoBrushError.invalid("Invalid layer properties in project.") }
                if let mask = layer.extras.maskPNG, CIImage(data: mask) == nil { throw PhotoBrushError.invalid("A layer mask is damaged.") }
                loadedLayers.append(layer)
            }
            if !missing.isEmpty {
                let list = missing.prefix(5).joined(separator: "\n") + (missing.count > 5 ? "\n…and \(missing.count - 5) more" : "")
                throw NSError(domain: "NetVistaPhoto", code: 3, userInfo: [NSLocalizedDescriptionKey: "The project references image files that are missing:\n\n\(list)\n\nMove the source images back to their original locations and try again."])
            }
            let ids = Set(loadedLayers.map(\.id))
            guard ids.count == loadedLayers.count else { throw PhotoBrushError.invalid("Duplicate layer identifiers in project.") }
            for layer in loadedLayers {
                if let parent = layer.extras.groupID {
                    guard !layer.extras.isGroup, loadedLayers.contains(where: { $0.id == parent && $0.extras.isGroup && $0.extras.groupID == nil }) else { throw PhotoBrushError.invalid("Invalid layer folder reference.") }
                }
            }
            layers = loadedLayers; documentSize = CGSize(width: project.canvasWidth, height: project.canvasHeight); documentDPI = min(1200, max(1, project.dpi ?? 72))
            selectedLayerID = project.selectedLayerID.flatMap { id in loadedLayers.contains { $0.id == id } ? id : nil } ?? loadedLayers.first?.id
            projectURL = url; documentLabel.stringValue = url.lastPathComponent; undoHistory.removeAll(); redoHistory.removeAll(); showOriginal.state = .off
            refreshDocumentUI(renderImmediately: true); statusLabel.stringValue = "Opened \(url.lastPathComponent)"
            #if !PHOTO_EDITOR_CHECKS
            if recordRecent { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
            #endif
            return true
        } catch {
            let alert = NSAlert(error: error); alert.messageText = "Could not Open Photo Project"
            if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            statusLabel.stringValue = "Open failed"
            return false
        }
    }

    var updateRestartBlocker: String? {
        if activePhotoExports > 0 { return "Wait for your photo export to finish, then press Update again." }
        if activeStroke != nil || importingBrushes { return "Finish the current brush operation before updating." }
        return nil
    }
    func writeUpdateRecovery(to url: URL) throws -> (URL?,String)? {
        guard documentSize.width > 0 else { return nil }
        try encodedProject().write(to:url,options:.atomic)
        return (projectURL,documentLabel.stringValue)
    }
    func restoreUpdateRecovery(from url: URL, originalURL: URL?, name: String) throws {
        guard openPhotoProject(url,recordRecent:false) else { throw NSError(domain:"NetVistaPhoto",code:4,userInfo:[NSLocalizedDescriptionKey:"Your photo recovery copy could not be opened. It remains saved at \(url.path)."]) }
        projectURL = originalURL; documentLabel.stringValue = name; updateCanvasTab()
    }
}

private extension PhotoEditorViewController {
    @objc func openProjectPanel() {
        let panel = NSOpenPanel(); panel.title = "Open Photo Project"; panel.prompt = "Open"; panel.allowedFileTypes = ["netvistaphoto"]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in if response == .OK, let url = panel?.url { self?.openPhotoProject(url) } }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    @objc func saveProject() {
        guard documentSize.width > 0 else { return }
        if let projectURL { writeProject(to: projectURL) }
        else { saveProjectAs() }
    }

    @objc func saveProjectAs() {
        let panel = NSSavePanel(); panel.title = "Save Photo Project"; panel.prompt = "Save Project"; panel.nameFieldStringValue = "Untitled.netvistaphoto"; panel.allowedFileTypes = ["netvistaphoto"]
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in guard response == .OK, let url = panel?.url else { return }; self?.writeProject(to: url) }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    func writeProject(to url: URL) {
        do {
            try encodedProject().write(to:url,options:.atomic)
            projectURL = url; documentLabel.stringValue = url.lastPathComponent; updateCanvasTab(); statusLabel.stringValue = "Saved \(url.lastPathComponent)"
            #if !PHOTO_EDITOR_CHECKS
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            #endif
        } catch {
            let alert = NSAlert(error: error); alert.messageText = "Could not Save Photo Project"
            if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            statusLabel.stringValue = "Save failed"
        }
    }

    func encodedProject() throws -> Data {
        let savedLayers = try layers.map { layer -> PhotoProjectLayerData in
            PhotoProjectLayerData(id:layer.id,name:layer.name,sourcePath:layer.sourceURL?.path ?? "",isVisible:layer.isVisible,isLocked:layer.isLocked,opacity:layer.opacity,blendMode:layer.blendMode.rawValue,positionX:layer.position.x,positionY:layer.position.y,scale:layer.scale,rotation:layer.rotation,adjustments:PhotoProjectAdjustmentData(layer.adjustments),pixels:try PhotoPixels.png(layer.sourceImage,context:context),extras:layer.extras)
        }
        let project = PhotoProjectFile(format:"NetVista Photo Project",version:2,canvasWidth:documentSize.width,canvasHeight:documentSize.height,selectedLayerID:selectedLayerID,layers:savedLayers,dpi:documentDPI)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return try encoder.encode(project)
    }

    @objc func exportPhoto() {
        guard documentSize.width > 0, documentSize.height > 0 else { return }
        let panel = NSSavePanel(); panel.title = "Export Composite"; panel.prompt = "Export"; panel.nameFieldStringValue = "NetVista-photo.png"; panel.allowedContentTypes = [.png, .jpeg]
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let output = panel?.url, let self else { return }
            self.statusLabel.stringValue = "Rendering full-resolution export…"
            let states = self.renderStates(); let size = self.documentSize; let dpi = self.documentDPI
            self.activePhotoExports += 1
            self.renderQueue.async {
                defer { DispatchQueue.main.async { self.activePhotoExports -= 1 } }
                let jpeg = ["jpg", "jpeg"].contains(output.pathExtension.lowercased())
                guard let result = self.composite(states, documentSize: size, maxSide: nil, bypassAdjustments: false, opaqueBackground: jpeg), let cg = self.context.createCGImage(result, from: result.extent) else {
                    DispatchQueue.main.async { self.statusLabel.stringValue = "Export failed" }; return
                }
                let bitmap = NSBitmapImageRep(cgImage: cg)
                bitmap.size = NSSize(width: size.width*72/dpi, height: size.height*72/dpi)
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
        undoHistory.append(snapshot())
        // Avoid retaining tens of gigabytes when painting on large documents.
        let pixels = layers.reduce(0.0) { $0 + $1.sourceImage.extent.width*$1.sourceImage.extent.height }
        let limit = min(80, max(2, Int(512_000_000/max(1,pixels*4))))
        while undoHistory.count > limit { undoHistory.removeFirst() }
        redoHistory.removeAll(); updateHistoryButtons()
    }
    func snapshot() -> PhotoDocumentSnapshot {
        PhotoDocumentSnapshot(layers: layers.map { PhotoLayerSnapshot(id: $0.id, name: $0.name, sourceURL: $0.sourceURL, sourceImage: $0.sourceImage, thumbnail: $0.thumbnail, isVisible: $0.isVisible, isLocked: $0.isLocked, opacity: $0.opacity, blendMode: $0.blendMode, position: $0.position, scale: $0.scale, rotation: $0.rotation, adjustments: $0.adjustments, extras: $0.extras, maskPreview: $0.maskPreview) }, selectedLayerID: selectedLayerID, documentSize: documentSize, documentName: documentLabel.stringValue, dpi: documentDPI, projectURL: projectURL)
    }
    func restore(_ snapshot: PhotoDocumentSnapshot) {
        layers = snapshot.layers.map {
            let layer = PhotoLayer(id: $0.id, name: $0.name, sourceURL: $0.sourceURL, sourceImage: $0.sourceImage, thumbnail: $0.thumbnail)
            layer.isVisible = $0.isVisible; layer.isLocked = $0.isLocked; layer.opacity = $0.opacity; layer.blendMode = $0.blendMode; layer.position = $0.position; layer.scale = $0.scale; layer.rotation = $0.rotation; layer.adjustments = $0.adjustments
            layer.extras = $0.extras
            return layer
        }
        selectedLayerID = snapshot.selectedLayerID; documentSize = snapshot.documentSize; documentDPI = snapshot.dpi; projectURL = snapshot.projectURL; documentLabel.stringValue = snapshot.documentName; canvasView.clearSelection(); refreshDocumentUI(renderImmediately: true)
    }
    func updateHistoryButtons() { undoButton.isEnabled = !undoHistory.isEmpty; redoButton.isEnabled = !redoHistory.isEmpty; undoButton.toolTip = "Undo · \(undoHistory.count) steps"; redoButton.toolTip = "Redo · \(redoHistory.count) steps" }

    func schedulePreview(immediate: Bool = false) {
        pendingPreview?.cancel(); renderGeneration += 1; let generation = renderGeneration
        guard documentSize.width > 0, documentSize.height > 0 else { canvasView.image = nil; return }
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
        func level(_ parent: UUID?, depth: Int) -> CIImage {
            var result = CIImage(color: parent == nil && opaqueBackground ? CIColor.white : CIColor.clear).cropped(to: extent)
            guard depth < 3 else { return result }
            for state in states.reversed() where state.extras.groupID == parent && state.isVisible && state.opacity > 0 {
                let extra = state.extras
                var image: CIImage
                if extra.isGroup { image = level(state.id, depth: depth+1) }
                else if extra.isAdjustment { image = result }
                else { image = state.sourceImage }
                if !bypassAdjustments { image = applyExtras(extra, to: apply(state.adjustments, to: image)) }
                if !extra.isGroup && !extra.isAdjustment {
                    if let mask = state.maskPreview ?? extra.maskPNG.flatMap({ CIImage(data: $0) }) {
                        image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent), kCIInputMaskImageKey: mask])
                    }
                    let transform = layerTransform(size: state.sourceImage.extent.size, position: state.position, scale: state.scale, rotation: state.rotation, skew: extra.skew, document: documentSize)
                    image = image.transformed(by: transform).transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                }
                if extra.isAdjustment {
                    if state.blendMode != .normal { image = image.applyingFilter(state.blendMode.filterName,parameters:[kCIInputBackgroundImageKey:result]) }
                    var mask = (state.maskPreview ?? extra.maskPNG.flatMap { CIImage(data: $0) })?.transformed(by: CGAffineTransform(scaleX: factor, y: factor)) ?? CIImage(color: .white).cropped(to: extent)
                    mask = mask.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: state.opacity, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: state.opacity, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: state.opacity, w: 0)])
                    result = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask]).cropped(to: extent)
                } else {
                    image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: state.opacity)])
                    result = image.applyingFilter(state.blendMode.filterName, parameters: [kCIInputBackgroundImageKey: result]).cropped(to: extent)
                }
            }
            return result
        }
        return level(nil, depth: 0)
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
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 6
        let label = propertyLabel(title)
        label.widthAnchor.constraint(equalToConstant:92).isActive = true; label.lineBreakMode = .byTruncatingTail; label.toolTip = title
        let value = NSTextField(string: formatter(slider.doubleValue)); value.font = .monospacedDigitSystemFont(ofSize:10,weight:.regular); value.textColor = NSColor(hex:"CCD0D6"); value.backgroundColor = NSColor(hex:"24272C"); value.alignment = .right; value.widthAnchor.constraint(equalToConstant:54).isActive = true
        value.target = self; value.action = #selector(numericPropertyChanged(_:)); value.toolTip = "Enter an exact value for \(title)"
        sliderValueLabels[ObjectIdentifier(slider)] = value; sliderFormatters[ObjectIdentifier(slider)] = formatter
        slider.controlSize = .small
        row.addArrangedSubview(label); row.addArrangedSubview(slider); row.addArrangedSubview(value)
        return row
    }
    @objc func numericPropertyChanged(_ sender: NSTextField) {
        guard let slider = (allSliders + Array(extrasSliders.values)).first(where:{ sliderValueLabels[ObjectIdentifier($0)] === sender }), slider.isEnabled, let number = Double(sender.stringValue.filter { "0123456789.-".contains($0) }), number.isFinite else { updateSliderLabels(); return }
        slider.doubleValue = min(slider.maxValue,max(slider.minValue,number)); if let action = slider.action { NSApp.sendAction(action,to:slider.target,from:slider) }
    }

    func updateSliderLabels() {
        for slider in allSliders + Array(extrasSliders.values) {
            let key = ObjectIdentifier(slider)
            if let label = sliderValueLabels[key], let formatter = sliderFormatters[key] { label.stringValue = formatter(slider.doubleValue); label.isEnabled = slider.isEnabled }
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
        let label = NSTextField(labelWithString: title.capitalized); label.font = .systemFont(ofSize:11,weight:.semibold); label.textColor = NSColor(hex:"B9BEC6"); return label
    }
    func propertyLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 10, weight: .medium); label.textColor = NSColor(hex: "C8CDD5"); return label
    }
    func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 10, weight: .medium); return button
    }
    func iconButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let button: NSButton
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) { button = PhotoFlatButton(image: image, target: self, action: action); button.imagePosition = .imageOnly }
        else { button = PhotoFlatButton(title: String(tooltip.prefix(1)), target: self, action: action) }
        button.isBordered = false; button.toolTip = tooltip; button.contentTintColor = NSColor(hex: "C1C7D0"); button.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
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

// MARK: - Documents, painting and docked tool properties
private extension PhotoEditorViewController {
    func refreshToolOptions() {
        contextOptions.arrangedSubviews.forEach { contextOptions.removeArrangedSubview($0); $0.removeFromSuperview() }
        if [.brush,.eraser,.clone,.heal,.rectangle,.ellipse,.line,.polygon].contains(selectedTool) {
            contextOptions.addArrangedSubview(makeButton("Brushes",#selector(showBrushLibrary)))
            for (tag,name,slider) in [(0,"Size",brushSize),(1,"Opacity",brushOpacity),(2,"Flow",brushFlow)] {
                let label = NSTextField(labelWithString:name); label.font = .systemFont(ofSize:10); label.textColor = .secondaryLabelColor
                let field = NSTextField(string:String(Int(slider.doubleValue))); field.tag = tag; field.font = .monospacedDigitSystemFont(ofSize:10,weight:.regular); field.widthAnchor.constraint(equalToConstant:42).isActive = true; field.target = self; field.action = #selector(contextBrushValue(_:)); field.toolTip = name
                contextOptions.addArrangedSubview(label); contextOptions.addArrangedSubview(field)
            }
            let colour = NSColorWell(); colour.color = foreground.color; colour.target = self; colour.action = #selector(contextColourChanged(_:)); colour.widthAnchor.constraint(equalToConstant:32).isActive = true; colour.heightAnchor.constraint(equalToConstant:24).isActive = true; colour.toolTip = "Paint colour"; contextOptions.addArrangedSubview(colour)
            toolHintLabel.stringValue = "[ / ] size · B brush · E eraser"
        } else if [.marquee,.lasso,.wand].contains(selectedTool) {
            contextOptions.addArrangedSubview(makeButton("Deselect",#selector(clearSelection))); contextOptions.addArrangedSubview(makeButton("Crop",#selector(cropToSelection))); contextOptions.addArrangedSubview(makeButton("Lift to Layer",#selector(liftSelection)))
        } else if selectedTool == .move { contextOptions.addArrangedSubview(makeButton("Transform Properties",#selector(showPhotoProperties))) }
        else if selectedTool == .text { contextOptions.addArrangedSubview(makeButton("Edit Text…",#selector(editTextLayer))) }
    }
    @objc func contextBrushValue(_ sender: NSTextField) {
        let sliders = [brushSize,brushOpacity,brushFlow]
        guard sliders.indices.contains(sender.tag) else { return }; let slider = sliders[sender.tag]
        slider.doubleValue = min(slider.maxValue,max(slider.minValue,sender.doubleValue)); brushSettingsChanged(); refreshToolOptions()
    }
    @objc func showPhotoProperties() { inspectorTabs.selectTabViewItem(at:1); updateInspectorTabs() }
    @objc func showBrushLibrary() { inspectorTabs.selectTabViewItem(at:0); updateInspectorTabs() }
    @objc func contextColourChanged(_ sender: NSColorWell) { foreground.color = sender.color }
    func editable(_ layer: PhotoLayer) -> Bool {
        !layer.isLocked && !(layers.first { $0.id == layer.extras.groupID }?.isLocked ?? false)
    }
    func createDocument(size: CGSize, dpi: Double, background: NSColor?) {
        guard PhotoPixels.validSize(size) else { return }
        documentSize = size; documentDPI = dpi; projectURL = nil
        let color = background.flatMap { CIColor(color: $0) } ?? .clear
        let layer = PhotoLayer(name: background == nil ? "Layer 1" : "Background", sourceURL: nil, sourceImage: CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size)), thumbnail: nil)
        updateThumbnail(layer)
        layers = [layer]; selectedLayerID = layer.id; documentLabel.stringValue = "Untitled Photo"
        canvasView.clearSelection(); canvasView.fit(); refreshDocumentUI(renderImmediately: true)
        statusLabel.stringValue = "Blank document · \(Int(size.width)) × \(Int(size.height)) px · \(Int(dpi)) ppi"
    }
    @objc func newDocument() {
        let alert = NSAlert(); alert.messageText = "New Document"; alert.informativeText = "Start with a blank canvas. Dimensions are in pixels. The current document remains in Undo history; save it first if you want a separate file."
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        let preset = NSPopUpButton(); preset.addItems(withTitles: ["HD · 1920 × 1080", "Square · 1080 × 1080", "Portrait · 1080 × 1350", "Story · 1080 × 1920", "4K · 3840 × 2160", "A4 print · 2480 × 3508 / 300 ppi", "US Letter · 2550 × 3300 / 300 ppi", "Custom"])
        preset.target = self; preset.action = #selector(documentPresetChanged(_:))
        let width = NSTextField(string: "1920"), height = NSTextField(string: "1080"), dpi = NSTextField(string: "72")
        newDocumentFields = [width, height, dpi]
        let background = NSPopUpButton(); background.addItems(withTitles: ["White", "Transparent", "Custom colour"])
        let color = NSColorWell(); color.color = NSColor(calibratedWhite: 0.15, alpha: 1)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 10
        stack.addArrangedSubview(preset)
        for (name, field) in [("Width (px)", width), ("Height (px)", height), ("Resolution (ppi)", dpi)] {
            let row = NSStackView(); row.addArrangedSubview(NSTextField(labelWithString: name)); row.addArrangedSubview(field); stack.addArrangedSubview(row)
        }
        stack.addArrangedSubview(background); stack.addArrangedSubview(color); stack.frame = NSRect(x: 0, y: 0, width: 380, height: 230); alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let size = CGSize(width: floor(width.doubleValue), height: floor(height.doubleValue))
        guard PhotoPixels.validSize(size), dpi.doubleValue.isFinite, (1...1200).contains(dpi.doubleValue) else { showPhotoError("Choose positive dimensions, at most 16,000 px per side / 64 megapixels, and 1–1,200 ppi."); return }
        pushHistory(); createDocument(size: size, dpi: dpi.doubleValue, background: background.indexOfSelectedItem == 1 ? nil : background.indexOfSelectedItem == 2 ? color.color : .white)
    }
    @objc func documentPresetChanged(_ sender: NSPopUpButton) {
        let presets = [[1920,1080,72],[1080,1080,72],[1080,1350,72],[1080,1920,72],[3840,2160,72],[2480,3508,300],[2550,3300,300]]
        guard presets.indices.contains(sender.indexOfSelectedItem), newDocumentFields.count == 3 else { return }
        for index in 0..<3 { newDocumentFields[index].integerValue = presets[sender.indexOfSelectedItem][index] }
    }
    func showPhotoError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Photos · NetVista Studio"; alert.informativeText = message
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    func insertLayer(_ layer: PhotoLayer) {
        updateThumbnail(layer)
        let current = selectedLayer
        layer.extras.groupID = current?.extras.isGroup == true ? current?.id : current?.extras.groupID
        var index = layers.firstIndex { $0.id == selectedLayerID } ?? 0
        if current?.extras.isGroup == true { index += 1; collapsedGroups.remove(current!.id) }
        layers.insert(layer, at: index); selectedLayerID = layer.id; maskEditing.state = .off; refreshDocumentUI(renderImmediately: true)
    }
    @objc func addBlankLayer() {
        guard PhotoPixels.validSize(documentSize) else { newDocument(); return }
        pushHistory(); insertLayer(PhotoLayer(name: "Layer \(layers.count+1)", sourceURL: nil, sourceImage: CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: documentSize)), thumbnail: nil))
    }
    func updateThumbnail(_ layer: PhotoLayer) {
        let factor = min(1,72/max(layer.sourceImage.extent.width,layer.sourceImage.extent.height))
        let image = layer.sourceImage.transformed(by:CGAffineTransform(scaleX:factor,y:factor))
        if let cg = context.createCGImage(image,from:image.extent) { layer.thumbnail = NSImage(cgImage:cg,size:image.extent.size) }
    }
    @objc func addAdjustmentLayer() {
        pushHistory()
        let layer = PhotoLayer(name: "Adjustment", sourceURL: nil, sourceImage: CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: documentSize)), thumbnail: nil)
        layer.extras.isAdjustment = true
        if let selection = documentSelectionMask() { layer.extras.maskPNG = try? PhotoPixels.png(selection, context: context) }
        insertLayer(layer); showPhotoProperties(); statusLabel.stringValue = "Adjustment layer added. Properties affects all layers below it (inside its folder)."
    }
    @objc func groupLayer() {
        guard let selected = selectedLayer, editable(selected) else { return }
        let folders = layers.filter { $0.extras.isGroup && !$0.isLocked }
        let alert = NSAlert(); alert.messageText = "Layer Folders"; alert.informativeText = "Group the selected layer, move it to a folder, or ungroup it. Select a folder twice to collapse/expand it. Folders support visibility, locking, opacity and blending."
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28)); popup.addItems(withTitles: ["New folder around selected layer", "Move out of folder / dissolve selected folder"] + folders.map { "Move into: " + $0.name }); alert.accessoryView = popup
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if selected.extras.isGroup && popup.indexOfSelectedItem != 1 { showPhotoError("Nested folders are not supported yet. Select a layer to move it into a folder."); return }
        pushHistory()
        if popup.indexOfSelectedItem == 1 {
            if selected.extras.isGroup { for child in layers where child.extras.groupID == selected.id { child.extras.groupID = nil }; layers.removeAll { $0.id == selected.id }; selectedLayerID = layers.first?.id }
            else { selected.extras.groupID = nil; layers.removeAll { $0.id == selected.id }; layers.insert(selected, at: 0) }
        } else {
            let folder: PhotoLayer
            if popup.indexOfSelectedItem == 0 {
                folder = PhotoLayer(name: "Group \(folders.count+1)", sourceURL: nil, sourceImage: CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)), thumbnail: nil); folder.extras.isGroup = true
                layers.insert(folder, at: 0)
            } else { folder = folders[popup.indexOfSelectedItem-2] }
            selected.extras.groupID = folder.id; layers.removeAll { $0.id == selected.id }
            layers.insert(selected, at: (layers.firstIndex { $0.id == folder.id } ?? 0)+1); collapsedGroups.remove(folder.id)
        }
        refreshDocumentUI()
    }
    @objc func maskAction() {
        guard let layer = selectedLayer, editable(layer), !layer.extras.isGroup else { showPhotoError("Select an unlocked image or adjustment layer for a mask."); return }
        let alert = NSAlert(); alert.messageText = "Layer Mask"; alert.informativeText = "Masks preserve original pixels. Black conceals, white reveals. Paint a mask with the Brush tool."
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28)); popup.addItems(withTitles: ["Reveal all", "Reveal selection", "Hide selection", "Invert existing mask", "Remove mask"]); alert.accessoryView = popup
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let choice = popup.indexOfSelectedItem
        if (choice == 1 || choice == 2) && documentSelectionMask() == nil { showPhotoError("Make a selection first."); return }
        let extent = layer.sourceImage.extent
        var mask = CIImage(color: .white).cropped(to: extent)
        if choice == 1 || choice == 2, let selected = selectionForLayer(layer) { mask = selected.cropped(to: extent) }
        if choice == 3 { mask = layer.extras.maskPNG.flatMap { CIImage(data: $0) } ?? mask }
        if choice == 2 || choice == 3 { mask = mask.applyingFilter("CIColorInvert") }
        do {
            let data = choice == 4 ? nil : try PhotoPixels.png(mask, context: context)
            pushHistory(); layer.extras.maskPNG = data; maskEditing.state = data == nil ? .off : .on
            foreground.color = .black; selectTool(.brush); refreshDocumentUI()
        } catch { showPhotoError(error.localizedDescription) }
    }
    func makeBrushPanel() -> NSView {
        let stack = PhotoFlippedStackView(); stack.orientation = .vertical; stack.spacing = 6; stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 12, right: 10); stack.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(); header.addArrangedSubview(section("BRUSH LIBRARY")); header.addArrangedSubview(NSView()); header.addArrangedSubview(makeButton("Import ABR…",#selector(importBrushes))); stack.addArrangedSubview(header)
        brushPopup.addItems(withTitles: brushLibrary.map(\.name)); brushPopup.target = self; brushPopup.action = #selector(chooseBrush)
        brushLibraryLabel.stringValue = "\(brushLibrary.count) brushes · \(brushLibrary[0].name)"
        brushSearch.placeholderString = "Search brushes"; brushSearch.font = .systemFont(ofSize:11); brushSearch.target = self; brushSearch.action = #selector(filterBrushes); brushSearch.sendsSearchStringImmediately = true; stack.addArrangedSubview(brushSearch)
        let libraryScroll = PhotoBrushScrollView(); libraryScroll.hasVerticalScroller = true; libraryScroll.autohidesScrollers = false; libraryScroll.borderType = .lineBorder; libraryScroll.heightAnchor.constraint(equalToConstant:134).isActive = true
        brushBrowser.frame = NSRect(x:0,y:0,width:286,height:132); brushBrowser.autoresizingMask = []; brushBrowser.brushes = brushLibrary; libraryScroll.documentView = brushBrowser
        brushBrowser.onSelect = { [weak self] index in self?.brushPopup.selectItem(at:index); self?.chooseBrush() }; stack.addArrangedSubview(libraryScroll)
        brushLibraryLabel.font = .systemFont(ofSize:10); brushLibraryLabel.textColor = .secondaryLabelColor; brushLibraryLabel.lineBreakMode = .byTruncatingTail; stack.addArrangedSubview(brushLibraryLabel)
        for (index,item) in [("Size",brushSize),("Hardness",brushHardness),("Opacity",brushOpacity),("Flow",brushFlow),("Tolerance",tolerance)].enumerated() {
            let (title,slider) = item
            let row = NSStackView(); row.spacing = 6; row.heightAnchor.constraint(equalToConstant:24).isActive = true
            let label = propertyLabel(title); label.widthAnchor.constraint(equalToConstant:56).isActive = true; row.addArrangedSubview(label)
            slider.target = self; slider.action = #selector(brushSettingsChanged); slider.isContinuous = true; row.addArrangedSubview(slider)
            let field = NSTextField(string:""); field.tag = index; field.font = .monospacedDigitSystemFont(ofSize:10,weight:.regular); field.alignment = .right; field.widthAnchor.constraint(equalToConstant:45).isActive = true; field.target = self; field.action = #selector(brushNumberChanged(_:)); field.toolTip = title; row.addArrangedSubview(field); brushValueFields.append(field); stack.addArrangedSubview(row)
        }
        let paintHeader = NSStackView(); paintHeader.addArrangedSubview(section("PAINT COLOUR")); paintHeader.addArrangedSubview(NSView()); foreground.widthAnchor.constraint(equalToConstant:44).isActive = true; foreground.heightAnchor.constraint(equalToConstant:24).isActive = true; foreground.target = self; foreground.action = #selector(brushSettingsChanged); paintHeader.addArrangedSubview(foreground); stack.addArrangedSubview(paintHeader)
        let swatches = NSStackView(); swatches.spacing = 2
        let colors: [NSColor] = [.black,.white,.systemRed,.systemOrange,.systemYellow,.systemGreen,.systemBlue,.systemPurple]
        let saved = UserDefaults.standard.array(forKey: "netvista.photos.swatches") as? [[Double]]
        for (index, color) in colors.enumerated() {
            let well = PhotoSwatchWell(); well.color = saved.flatMap { $0.indices.contains(index) && $0[index].count == 3 ? NSColor(deviceRed: $0[index][0], green: $0[index][1], blue: $0[index][2], alpha: 1) : nil } ?? color
            well.tag = index; well.target = self; well.action = #selector(swatchChanged(_:)); well.widthAnchor.constraint(equalToConstant: 28).isActive = true; well.heightAnchor.constraint(equalToConstant: 26).isActive = true; well.toolTip = "Click to use this colour; Option-click to edit and save the swatch"; swatches.addArrangedSubview(well)
        }
        stack.addArrangedSubview(swatches)
        toolSettingsLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); stack.addArrangedSubview(toolSettingsLabel)
        maskEditing.font = .systemFont(ofSize: 10); stack.addArrangedSubview(maskEditing)
        stack.addArrangedSubview(makeButton("+ New Paint Layer",#selector(addBlankLayer)))
        let library = NSStackView(); library.addArrangedSubview(makeButton("Save Tip…", #selector(saveBrush))); library.addArrangedSubview(makeButton("Define from Layer", #selector(defineBrush))); stack.addArrangedSubview(library)
        stack.addArrangedSubview(makeButton("Edit Text Layer…", #selector(editTextLayer)))
        stack.addArrangedSubview(makeButton("Lift Selection to Transform Layer", #selector(liftSelection)))
        let note = NSTextField(wrappingLabelWithString: "Drop .abr files here to import Photoshop round and sampled tips. Advanced Adobe dynamics are not reproduced.\nClone / Heal: Option-click a source, then paint."); note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = stack
        NSLayoutConstraint.activate([stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)])
        brushSettingsChanged(); return scroll
    }
    @objc func swatchChanged(_ sender: NSColorWell) {
        foreground.color = sender.color
        brushSettingsChanged()
        if let row = sender.superview as? NSStackView {
            let colors = row.arrangedSubviews.compactMap { ($0 as? NSColorWell)?.color.usingColorSpace(.deviceRGB) }.map { [$0.redComponent,$0.greenComponent,$0.blueComponent] }
            UserDefaults.standard.set(colors, forKey: "netvista.photos.swatches")
        }
    }
    @objc func inspectorTabChanged(_ sender: NSButton) { inspectorTabs.selectTabViewItem(at:sender.tag); updateInspectorTabs() }
    func updateInspectorTabs() { for button in inspectorTabButtons { button.state = inspectorTabs.selectedTabViewItem === inspectorTabs.tabViewItem(at:button.tag) ? .on : .off; button.needsDisplay = true } }
    @objc func brushSettingsChanged() {
        canvasView.brushDiameter = brushSize.doubleValue
        toolSettingsLabel.stringValue = "\(Int(brushSize.doubleValue)) px · \(Int(brushHardness.doubleValue*100))% hard · \(Int(brushOpacity.doubleValue))% / \(Int(brushFlow.doubleValue))%"
        let values = [brushSize.doubleValue,brushHardness.doubleValue*100,brushOpacity.doubleValue,brushFlow.doubleValue,tolerance.doubleValue]
        for field in brushValueFields { field.integerValue = Int(values[field.tag]); field.isEnabled = field.tag != 1 || brushHardness.isEnabled }
        for well in contextOptions.arrangedSubviews.compactMap({ $0 as? NSColorWell }) { well.color = foreground.color }
        for field in contextOptions.arrangedSubviews.compactMap({ $0 as? NSTextField }) where field.isEditable {
            let values = [brushSize,brushOpacity,brushFlow]; if values.indices.contains(field.tag) { field.integerValue = Int(values[field.tag].doubleValue) }
        }
    }
    @objc func filterBrushes() { brushBrowser.filter(brushSearch.stringValue) }
    @objc func brushNumberChanged(_ sender: NSTextField) {
        let sliders = [brushSize,brushHardness,brushOpacity,brushFlow,tolerance]
        guard sliders.indices.contains(sender.tag), let value = Double(sender.stringValue.trimmingCharacters(in:CharacterSet(charactersIn:" %px"))), value.isFinite else { brushSettingsChanged(); return }
        let slider = sliders[sender.tag]; slider.doubleValue = min(slider.maxValue,max(slider.minValue,sender.tag == 1 ? value/100 : value)); brushSettingsChanged()
    }
    @objc func liftSelection() {
        guard let layer = selectedLayer, editable(layer), !layer.extras.isGroup, !layer.extras.isAdjustment, layer.extras.text == nil, let mask = selectionForLayer(layer) else { statusLabel.stringValue = "Select pixels on an unlocked image layer first."; return }
        let transparent = CIImage(color:.clear).cropped(to:layer.sourceImage.extent)
        let lifted = layer.sourceImage.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:transparent,kCIInputMaskImageKey:mask])
        let remaining = transparent.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:layer.sourceImage,kCIInputMaskImageKey:mask])
        pushHistory()
        let crop = PhotoPixels.maskBounds(mask,context:context) ?? layer.sourceImage.extent
        let copy = PhotoLayer(name:layer.name+" selection",sourceURL:nil,sourceImage:PhotoPixels.frozen(normalized(lifted.cropped(to:crop)),context:context),thumbnail:nil)
        let centre = CGPoint(x:crop.midX,y:crop.midY).applying(transform(layer))
        copy.position = CGPoint(x:centre.x-documentSize.width/2,y:centre.y-documentSize.height/2); copy.scale = layer.scale; copy.rotation = layer.rotation; copy.opacity = layer.opacity; copy.blendMode = layer.blendMode; copy.adjustments = layer.adjustments; copy.extras = layer.extras
        if let data = copy.extras.maskPNG, let mask = CIImage(data:data) { copy.extras.maskPNG = try? PhotoPixels.png(normalized(mask.cropped(to:crop)),context:context) }
        layer.sourceImage = PhotoPixels.frozen(remaining,context:context); insertLayer(copy); canvasView.clearSelection(); selectTool(.move)
        statusLabel.stringValue = "Selection lifted. Drag to move; Properties resizes, rotates and skews it. Undo restores the original."
    }
    @objc func chooseBrush() {
        guard brushLibrary.indices.contains(brushPopup.indexOfSelectedItem) else { return }
        let brush = brushLibrary[brushPopup.indexOfSelectedItem]
        brushHardness.doubleValue = brush.hardness; brushHardness.isEnabled = brush.samples == nil
        brushHardness.toolTip = brush.samples == nil ? "Softness of the round tip edge" : "This imported tip has its own baked-in edge; opacity and flow still work."
        if let size = brush.diameter { brushSize.doubleValue = min(800,max(1,size)) }
        brushBrowser.selected = brushPopup.indexOfSelectedItem; brushBrowser.revealSelection()
        brushLibraryLabel.stringValue = "\(brushLibrary.count) brushes · \(brush.name)"
        brushSettingsChanged()
        if ![.eraser,.clone,.heal].contains(selectedTool) { selectTool(.brush) }
        view.window?.makeFirstResponder(canvasView)
    }
    func storeBrushes(_ brushes: [PhotoBrush], encodedLibrary: Data? = nil) throws {
        guard !brushes.isEmpty, brushes.allSatisfy(\.isValid), brushLibrary.count + brushes.count <= 1024 else { throw PhotoBrushError.invalid("Invalid brushes or library limit reached (1,024 tips).") }
        let all = Array(brushLibrary.dropFirst(PhotoBrush.defaults.count)) + brushes
        let data = try encodedLibrary ?? JSONEncoder().encode(all)
        guard data.count <= 96*1024*1024 else { throw PhotoBrushError.invalid("This library would exceed 96 MB. Use smaller brush tips.") }
        UserDefaults.standard.set(data, forKey: "netvista.photos.brushLibrary")
        let firstImported = brushLibrary.count
        brushLibrary += brushes; brushPopup.removeAllItems(); brushPopup.addItems(withTitles: brushLibrary.map(\.name)); brushPopup.selectItem(at:firstImported)
        brushSearch.stringValue = ""; brushBrowser.brushes = brushLibrary; brushBrowser.filter(""); chooseBrush(); showBrushLibrary()
    }
    @objc func importBrushes() {
        guard !importingBrushes else { statusLabel.stringValue = "A brush import is already running…"; return }
        let panel = NSOpenPanel(); panel.title = "Import Photoshop Brushes or Image Tips"; panel.prompt = "Import Brushes"; panel.allowedFileTypes = ["abr","png","jpg","jpeg","netvistabrush"]; panel.allowsMultipleSelection = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in if response == .OK { self?.importBrushURLs(panel.urls) } }
        if let window = view.window { panel.beginSheetModal(for:window,completionHandler:completion) } else { completion(panel.runModal()) }
    }
    func importBrushURLs(_ urls: [URL]) {
        guard !importingBrushes else { statusLabel.stringValue = "A brush import is already running. Wait for it to finish."; return }
        importingBrushes = true; showBrushLibrary(); statusLabel.stringValue = "Reading brush pack… You can keep editing."
        let existing = Array(brushLibrary.dropFirst(PhotoBrush.defaults.count))
        brushImportQueue.async { [weak self] in
            guard let self else { return }
            var imported: [PhotoBrush] = [], notes: [String] = []
            for url in urls.prefix(32) {
                do {
                    let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    guard size <= 128*1024*1024 else { throw PhotoBrushError.invalid("Pack exceeds 128 MB.") }
                    let data = try Data(contentsOf:url), name = url.deletingPathExtension().lastPathComponent
                    var batch: [PhotoBrush] = []
                    if url.pathExtension.lowercased() == "abr" {
                        let report = try PhotoABR.readReport(data,name:name); batch = report.brushes; notes += report.warnings
                    } else if url.pathExtension.lowercased() == "netvistabrush" {
                        let brush = try JSONDecoder().decode(PhotoBrush.self,from:data)
                        guard brush.isValid else { throw PhotoBrushError.invalid("Invalid brush tip.") }; batch = [brush]
                    } else if let image = CIImage(data:data), PhotoPixels.validSize(image.extent.size) { batch = [self.customBrush(image,name:name)] }
                    else { throw PhotoBrushError.invalid("Unsupported or oversized tip image.") }
                    guard imported.count+batch.count <= 1020, (imported+batch).reduce(0,{ $0+($1.samples?.count ?? 0) }) <= 64*1024*1024 else { throw PhotoBrushError.invalid("Batch exceeds the 64 MB / 1,020 imported-tip limit.") }
                    imported += batch
                } catch { notes.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            let results = imported
            // JSON/base64 encoding a large pack also belongs off the event thread.
            let encoded = try? JSONEncoder().encode(existing + results)
            let warnings = Array(Set(notes)).sorted()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.importingBrushes = false
                do {
                    if !results.isEmpty {
                        guard let encoded else { throw PhotoBrushError.invalid("Could not save the brush library.") }
                        try self.storeBrushes(results,encodedLibrary:encoded)
                    }
                    self.statusLabel.stringValue = "Imported \(results.count) brushes. " + (warnings.isEmpty ? "Select a tip and paint." : "See import report for compatibility details.")
                    if !warnings.isEmpty {
                        let alert = NSAlert(); alert.messageText = results.isEmpty ? "No brushes imported" : "\(results.count) brushes ready"
                        alert.informativeText = warnings.prefix(8).joined(separator:"\n\n")
                        alert.addButton(withTitle:"OK")
                        if let window = self.view.window { alert.beginSheetModal(for:window) } else { alert.runModal() }
                    }
                } catch { self.showPhotoError(error.localizedDescription) }
            }
        }
    }
    func customBrush(_ source: CIImage, name: String) -> PhotoBrush {
        let factor = min(1, 512 / max(source.extent.width, source.extent.height))
        let image = normalized(source).transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let w = max(1, Int(image.extent.width)), h = max(1, Int(image.extent.height))
        var pixels = [UInt8](repeating: 0, count: w*h*4)
        context.render(image, toBitmap: &pixels, rowBytes: w*4, bounds: CGRect(x: 0,y: 0,width: w,height: h), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var coverage = [UInt8](repeating: 0, count: w*h)
        for i in 0..<w*h { coverage[i] = UInt8(max(0, Int(pixels[i*4+3]) - (Int(pixels[i*4])+Int(pixels[i*4+1])+Int(pixels[i*4+2]))/3)) }
        return PhotoBrush(name: name, kind: "sample", hardness: 1, width: w, height: h, samples: Data(coverage))
    }
    @objc func defineBrush() {
        guard !importingBrushes else { statusLabel.stringValue = "Wait for the brush import to finish before defining another tip."; return }
        guard let layer = selectedLayer, !layer.extras.isGroup, !layer.extras.isAdjustment else { return }
        var image = layer.sourceImage
        if let mask = selectionForLayer(layer) {
            image = image.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:CIImage(color:.clear).cropped(to:image.extent),kCIInputMaskImageKey:mask])
            if let bounds = PhotoPixels.maskBounds(mask,context:context) { image = normalized(image.cropped(to:bounds)) }
        }
        do { try storeBrushes([customBrush(image, name: layer.name + " tip")]); statusLabel.stringValue = "Saved brush tip. Dark pixels paint; white / transparent pixels do not." } catch { showPhotoError(error.localizedDescription) }
    }
    @objc func saveBrush() {
        guard brushLibrary.indices.contains(brushPopup.indexOfSelectedItem) else { return }
        var brush = brushLibrary[brushPopup.indexOfSelectedItem]; brush.hardness = brushHardness.doubleValue
        let panel = NSSavePanel(); panel.allowedFileTypes = ["netvistabrush"]; panel.nameFieldStringValue = brush.name + ".netvistabrush"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONEncoder().encode(brush).write(to: url, options: .atomic) } catch { showPhotoError(error.localizedDescription) }
    }
    func addExtraSlider(_ key: String, title: String, value: Double, min: Double, max: Double, to stack: NSStackView) {
        let slider = PhotoTrackedSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil); slider.identifier = NSUserInterfaceItemIdentifier(key); extrasSliders[key] = slider
        configure(slider, action: #selector(extraChanged(_:))); stack.addArrangedSubview(sliderRow(title, slider, formatter: decimal(2)))
    }
    func syncExtras(_ e: PhotoLayerExtras) {
        toneCurve.values = [e.curveShadows,e.midtone,e.curveHighlights]
        let values = ["skew":e.skew,"hue":e.hue,"noise":e.noise,"black":e.black,"white":e.white,"midtone":e.midtone,"curveShadows":e.curveShadows,"curveHighlights":e.curveHighlights]
        for (key,value) in values { extrasSliders[key]?.doubleValue = value }
    }
    @objc func extraChanged(_ sender: PhotoTrackedSlider) {
        guard !isSynchronizingControls, let layer = selectedLayer, editable(layer) else { return }
        if !sender.isMouseTracking { pushHistory() }
        switch sender.identifier?.rawValue {
        case "skew": layer.extras.skew = sender.doubleValue
        case "hue": layer.extras.hue = sender.doubleValue
        case "noise": layer.extras.noise = sender.doubleValue
        case "black": layer.extras.black = sender.doubleValue
        case "white": layer.extras.white = sender.doubleValue
        case "midtone": layer.extras.midtone = sender.doubleValue
        case "curveShadows": layer.extras.curveShadows = sender.doubleValue
        case "curveHighlights": layer.extras.curveHighlights = sender.doubleValue
        default: break
        }
        updateSliderLabels(); schedulePreview()
    }
    func applyExtras(_ e: PhotoLayerExtras, to source: CIImage) -> CIImage {
        var image = source
        if e.hue != 0 { image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey:e.hue * .pi/180]) }
        if e.black != 0 || e.white != 1 {
            let gain = 1/max(0.01,e.white-e.black), bias = -e.black*gain
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputRVector":CIVector(x:gain,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:gain,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:gain,w:0),"inputBiasVector":CIVector(x:bias,y:bias,z:bias,w:0)])
        }
        if e.curveShadows != 0.25 || e.midtone != 0.5 || e.curveHighlights != 0.75 {
            image = image.applyingFilter("CIToneCurve", parameters: ["inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:0.25,y:e.curveShadows),"inputPoint2":CIVector(x:0.5,y:e.midtone),"inputPoint3":CIVector(x:0.75,y:e.curveHighlights),"inputPoint4":CIVector(x:1,y:1)])
        }
        if e.noise > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let grain = noise.cropped(to: source.extent).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey:0]).applyingFilter("CIColorMatrix", parameters: ["inputAVector":CIVector(x:0,y:0,z:0,w:e.noise)])
            image = grain.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey:image])
        }
        return image.cropped(to: source.extent)
    }
    func layerTransform(size: CGSize, position: CGPoint, scale: Double, rotation: Double, skew: Double, document: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: -size.width/2, y: -size.height/2)
            .concatenating(CGAffineTransform(a: scale,b: 0,c: skew*scale,d: scale,tx: 0,ty: 0))
            .concatenating(CGAffineTransform(rotationAngle: rotation * .pi/180))
            .concatenating(CGAffineTransform(translationX: document.width/2+position.x,y: document.height/2+position.y))
    }
    func transform(_ layer: PhotoLayer) -> CGAffineTransform { layerTransform(size: layer.sourceImage.extent.size, position: layer.position, scale: layer.scale, rotation: layer.rotation, skew: layer.extras.skew, document: documentSize) }
    func documentSelectionMask() -> CIImage? {
        if let mask = canvasView.selectionMask { return mask }
        guard let rect = canvasView.documentSelectionRect else { return nil }
        return CIImage(color: .white).cropped(to: rect).composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero,size: documentSize)))
    }
    func selectionForLayer(_ layer: PhotoLayer) -> CIImage? {
        documentSelectionMask()?.transformed(by: transform(layer).inverted()).cropped(to: layer.sourceImage.extent)
    }
    func pathMask(_ path: CGPath) -> CIImage? {
        guard let cg = PhotoPixels.context(documentSize) else { return nil }
        cg.setFillColor(NSColor.black.cgColor); cg.fill(CGRect(origin:.zero,size:documentSize)); cg.addPath(path); cg.setFillColor(NSColor.white.cgColor); cg.fillPath()
        return cg.makeImage().map { CIImage(cgImage:$0) }
    }
    func handleTool(_ point: CGPoint, phase: Int, flags: NSEvent.ModifierFlags) {
        guard documentSize.width > 0 else { return }
        if [.brush,.eraser,.clone,.heal].contains(selectedTool) { paint(point, phase: phase, flags: flags); return }
        if phase == 0 {
            gesturePoints = [point]
            if selectedTool == .eyedropper, let image = composite(renderStates(), documentSize: documentSize, maxSide:nil,bypassAdjustments:false,opaqueBackground:false) { foreground.color = PhotoPixels.color(at:point,image:image,context:context) }
            if selectedTool == .text { editText(at: point, existing: nil) }
            if selectedTool == .wand || selectedTool == .bucket { flood(point, fill: selectedTool == .bucket) }
        }
        if [.lasso,.polygon,.rectangle,.ellipse,.line].contains(selectedTool) {
            if phase > 0 { gesturePoints.append(point) }
            let path = gesturePath(); canvasView.gestureOutline = path
            if phase == 2 {
                canvasView.gestureOutline = nil
                guard gesturePoints.count > 1 else { return }
                if selectedTool == .lasso { canvasView.clearSelection(); canvasView.selectionMask = pathMask(path); canvasView.selectionOutline = path; selectionLabel.stringValue = "Lasso selection" }
                else { createShape(path) }
            }
        }
    }
    func gesturePath() -> CGPath {
        let path = CGMutablePath(); guard let first = gesturePoints.first, let last = gesturePoints.last else { return path }
        let rect = CGRect(x:min(first.x,last.x),y:min(first.y,last.y),width:abs(first.x-last.x),height:abs(first.y-last.y))
        if selectedTool == .rectangle { path.addRect(rect) }
        else if selectedTool == .ellipse { path.addEllipse(in:rect) }
        else if selectedTool == .line { path.move(to:first); path.addLine(to:last) }
        else { path.addLines(between:gesturePoints); path.closeSubpath() }
        return path
    }
    func createShape(_ path: CGPath) {
        guard let cg = PhotoPixels.context(documentSize) else { return }
        cg.addPath(path); cg.setFillColor(foreground.color.cgColor); cg.setStrokeColor(foreground.color.cgColor); cg.setLineWidth(brushSize.doubleValue)
        if selectedTool == .line { cg.strokePath() } else { cg.fillPath() }
        guard let pixels = cg.makeImage() else { return }
        var image = CIImage(cgImage:pixels)
        if let selection = documentSelectionMask() { image = image.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:CIImage(color:.clear).cropped(to:image.extent),kCIInputMaskImageKey:selection]) }
        pushHistory(); insertLayer(PhotoLayer(name:selectedTool.title,sourceURL:nil,sourceImage:image,thumbnail:nil))
    }
    func paint(_ point: CGPoint, phase: Int, flags: NSEvent.ModifierFlags) {
        if phase == 0 { activeStroke = nil; strokeLayerID = nil }
        guard let layer = selectedLayer, editable(layer), !layer.extras.isGroup else { statusLabel.stringValue = "Choose an unlocked pixel layer, not a folder."; return }
        guard layer.isVisible, !(layers.first { $0.id == layer.extras.groupID }.map { !$0.isVisible } ?? false) else { statusLabel.stringValue = "This layer is hidden. Turn on its eye icon before painting."; return }
        let local = point.applying(transform(layer).inverted())
        if phase == 0 {
            activeStroke = nil
            if [.clone,.heal].contains(selectedTool) && flags.contains(.option) { cloneSource = local; cloneLayerID = layer.id; statusLabel.stringValue = "Sample source set. Paint to clone/heal."; return }
            strokeMask = maskEditing.state == .on && layer.extras.maskPNG != nil
            if layer.extras.isAdjustment && !strokeMask { statusLabel.stringValue = "Adjustment layers have no paint pixels. Add a mask or select an image layer."; return }
            if layer.extras.text != nil && !strokeMask { statusLabel.stringValue = "Text stays editable. Paint on a new transparent layer above it."; return }
            var clone: CGImage?, offset = CGPoint.zero
            if [.clone,.heal].contains(selectedTool) {
                guard let source = cloneSource, cloneLayerID == layer.id, !strokeMask else { statusLabel.stringValue = "Option-click a source on this layer first."; return }
                offset = CGPoint(x:source.x-local.x,y:source.y-local.y)
                var sampled = layer.sourceImage
                if selectedTool == .heal {
                    let average = sampled.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(1,brushSize.doubleValue/3)])
                    let a = PhotoPixels.color(at:source,image:average,context:context), b = PhotoPixels.color(at:local,image:average,context:context)
                    sampled = sampled.applyingFilter("CIColorMatrix",parameters:["inputBiasVector":CIVector(x:b.redComponent-a.redComponent,y:b.greenComponent-a.greenComponent,z:b.blueComponent-a.blueComponent,w:0)])
                }
                clone = context.createCGImage(sampled,from:sampled.extent)
            }
            let base = strokeMask ? (layer.extras.maskPNG.flatMap { CIImage(data:$0) } ?? layer.sourceImage) : layer.sourceImage
            let index = brushPopup.indexOfSelectedItem
            guard brushLibrary.indices.contains(index) else { statusLabel.stringValue = "Select a brush in the Brushes panel."; return }
            let brush = brushLibrary[index]
            let color: NSColor = strokeMask && selectedTool == .eraser ? .white : foreground.color
            guard let stroke = PhotoRasterStroke(base:base,brush:brush,size:brushSize.doubleValue / layer.scale,hardness:brushHardness.doubleValue,opacity:brushOpacity.doubleValue/100,flow:brushFlow.doubleValue/100,color:color,erase:selectedTool == .eraser && !strokeMask,selection:selectionForLayer(layer),clone:clone,cloneOffset:offset) else { statusLabel.stringValue = "Unable to allocate brush surface."; return }
            pushHistory(); activeStroke = stroke; strokeLayerID = layer.id; lastStrokePreview = 0
        }
        guard let stroke = activeStroke, strokeLayerID == layer.id else { return }
        stroke.append(local)
        let now = Date.timeIntervalSinceReferenceDate
        if phase == 2 || now-lastStrokePreview > 1/30 {
            let image = stroke.image()
            if strokeMask { layer.maskPreview = image } else { layer.sourceImage = image }
            schedulePreview(immediate:true); lastStrokePreview = now
        }
        if phase == 2 {
            if strokeMask {
                do { layer.extras.maskPNG = try PhotoPixels.png(stroke.image(),context:context) } catch { showPhotoError(error.localizedDescription) }
                layer.maskPreview = nil
            } else { layer.sourceImage = PhotoPixels.frozen(stroke.image(),context:context) }
            activeStroke = nil; strokeLayerID = nil; updateThumbnail(layer); rebuildLayersPanel(); schedulePreview(immediate:true)
        }
    }
    func flood(_ point: CGPoint, fill: Bool) {
        guard let layer = selectedLayer, !fill || (editable(layer) && !layer.extras.isGroup && !layer.extras.isAdjustment && layer.extras.text == nil) else { statusLabel.stringValue = "Choose an unlocked pixel layer to fill."; return }
        let source = fill ? layer.sourceImage : composite(renderStates(),documentSize:documentSize,maxSide:nil,bypassAdjustments:false,opaqueBackground:false)
        guard let source else { return }
        let sample = fill ? point.applying(transform(layer).inverted()) : point
        let generation = renderGeneration, id = layer.id, toleranceValue = Int(tolerance.doubleValue), selection = selectionForLayer(layer), color = CIColor(color:foreground.color) ?? .black
        statusLabel.stringValue = "Finding connected colour region…"
        renderQueue.async { [weak self] in
            guard let self, var region = PhotoPixels.region(at:sample,image:source,tolerance:toleranceValue,context:self.context) else { return }
            if fill, let selection { region = region.applyingFilter("CIMultiplyCompositing",parameters:[kCIInputBackgroundImageKey:selection]) }
            let mask = region
            DispatchQueue.main.async { [weak self] in
                guard let self, self.renderGeneration == generation, self.selectedLayerID == id else { return }
                if fill {
                    self.pushHistory()
                    let result = CIImage(color:color).cropped(to:source.extent).applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:source,kCIInputMaskImageKey:mask])
                    layer.sourceImage = PhotoPixels.frozen(result,context:self.context); self.refreshDocumentUI(renderImmediately:true); self.statusLabel.stringValue = "Region filled"
                } else { self.canvasView.clearSelection(); self.canvasView.selectionMask = mask; self.canvasView.needsDisplay = true; self.selectionLabel.stringValue = "Wand selection"; self.statusLabel.stringValue = "Connected colour selected; paint and fill respect this region." }
            }
        }
    }
    @objc func editTextLayer() { guard let layer = selectedLayer, layer.extras.text != nil, editable(layer) else { statusLabel.stringValue = "Select a text layer first."; return }; editText(at:.zero,existing:layer) }
    func editText(at point: CGPoint, existing: PhotoLayer?) {
        let alert = NSAlert(); alert.messageText = existing == nil ? "New Text Layer" : "Edit Text Layer"; alert.addButton(withTitle:"Apply"); alert.addButton(withTitle:"Cancel")
        let text = NSTextField(string:existing?.extras.text ?? "Your text"), fonts = NSPopUpButton(), size = NSTextField(string:String(Int(existing?.extras.fontSize ?? 64))), color = NSColorWell()
        fonts.addItems(withTitles:NSFontManager.shared.availableFontFamilies.sorted()); fonts.selectItem(withTitle:existing?.extras.fontName ?? "Helvetica")
        color.color = foreground.color
        if let c = existing?.extras.textColor, c.count == 4 { color.color = NSColor(deviceRed:c[0],green:c[1],blue:c[2],alpha:c[3]) }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 8
        for item in [text,fonts,NSTextField(labelWithString:"Size in pixels"),size,color] { stack.addArrangedSubview(item) }
        stack.frame = NSRect(x:0,y:0,width:400,height:180); alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn, !text.stringValue.isEmpty, (1...2000).contains(size.doubleValue), text.stringValue.count <= 10000 else { return }
        let fontName = fonts.titleOfSelectedItem ?? "Helvetica", font = NSFont(name:fontName,size:size.doubleValue) ?? .systemFont(ofSize:size.doubleValue)
        let attributes: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:color.color]
        let string = NSAttributedString(string:text.stringValue,attributes:attributes)
        let bounds = string.boundingRect(with:NSSize(width:16000,height:16000),options:[.usesLineFragmentOrigin,.usesFontLeading])
        let textSize = CGSize(width:ceil(bounds.width)+8,height:ceil(bounds.height)+8)
        guard let cg = PhotoPixels.context(textSize) else { showPhotoError("This text layer is too large."); return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:cg,flipped:false); string.draw(at:CGPoint(x:4,y:4)); NSGraphicsContext.restoreGraphicsState()
        guard let pixels = cg.makeImage() else { return }
        pushHistory()
        let layer = existing ?? PhotoLayer(name:"Text",sourceURL:nil,sourceImage:CIImage(cgImage:pixels),thumbnail:nil)
        layer.sourceImage = CIImage(cgImage:pixels); layer.name = String(text.stringValue.prefix(40)); layer.extras.text = text.stringValue; layer.extras.fontName = fontName; layer.extras.fontSize = size.doubleValue
        let c = color.color.usingColorSpace(.deviceRGB) ?? .black; layer.extras.textColor = [c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent]
        if existing == nil { layer.position = CGPoint(x:point.x-documentSize.width/2+textSize.width/2,y:point.y-documentSize.height/2+textSize.height/2); insertLayer(layer) } else { refreshDocumentUI(renderImmediately:true) }
    }
}
