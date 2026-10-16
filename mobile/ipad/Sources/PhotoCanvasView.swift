import UIKit
import CoreImage

enum MobilePhotoTool: String, CaseIterable {
    case move = "Move", brush = "Brush", eraser = "Eraser", marquee = "Select", lasso = "Lasso", wand = "Wand"
    case bucket = "Fill", clone = "Clone", heal = "Heal", text = "Text", rectangle = "Rectangle"
    case ellipse = "Ellipse", line = "Line", polygon = "Polygon", eyedropper = "Eyedropper", hand = "Hand"
    var symbol: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .marquee: return "rectangle.dashed"
        case .lasso: return "lasso"
        case .wand: return "wand.and.stars"
        case .bucket: return "drop.fill"
        case .clone: return "seal"
        case .heal: return "bandage"
        case .text: return "textformat"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .polygon: return "pentagon"
        case .eyedropper: return "eyedropper"
        case .hand: return "hand.draw"
        }
    }
}

/// The viewport is UIKit, but all editing coordinates are the same positive-Y-up
/// document pixels used by the desktop renderer and brush engine.
final class PhotoCanvasView: UIView, UIGestureRecognizerDelegate {
    var documentSize = CGSize(width: 1920, height: 1080) { didSet { setNeedsDisplay() } }
    var image: UIImage? { didSet { setNeedsDisplay() } }
    var outline: CGPath? { didSet { setNeedsDisplay() } }
    var showsRulers = true { didSet { setNeedsDisplay() } }
    var tool = MobilePhotoTool.brush { didSet { pan.minimumNumberOfTouches = tool == .hand ? 1 : 2 } }
    var onInput: ((CGPoint, Int) -> Void)?
    var onZoom: ((Double) -> Void)?
    private(set) var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var drawing = false
    private var lastPoint = CGPoint.zero
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = MobileTheme.workspace; clipsToBounds = true; isMultipleTouchEnabled = true
        accessibilityIdentifier = "photo.canvas"
        accessibilityLabel = "Photo canvas. Pinch to zoom; use two fingers or the Hand tool to pan."
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self; pan.delegate = self; pan.minimumNumberOfTouches = 2
        addGestureRecognizer(pinch); addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    var canvasRect: CGRect {
        let fit = min(max(1, bounds.width - 48) / documentSize.width, max(1, bounds.height - 48) / documentSize.height)
        let size = CGSize(width: documentSize.width * fit * zoom, height: documentSize.height * fit * zoom)
        return CGRect(x: bounds.midX - size.width / 2 + offset.x, y: bounds.midY - size.height / 2 + offset.y, width: size.width, height: size.height)
    }
    func documentPoint(_ point: CGPoint) -> CGPoint {
        let rect = canvasRect
        return CGPoint(x: (point.x - rect.minX) / rect.width * documentSize.width,
                       y: (rect.maxY - point.y) / rect.height * documentSize.height)
    }
    func viewPoint(_ point: CGPoint) -> CGPoint {
        let rect = canvasRect
        return CGPoint(x: rect.minX + point.x / documentSize.width * rect.width,
                       y: rect.maxY - point.y / documentSize.height * rect.height)
    }
    func fit() { cancelInput(); zoom = 1; offset = .zero; publishZoom() }
    func zoomBy(_ factor: CGFloat) { cancelInput(); zoom = min(32, max(0.05, zoom * factor)); publishZoom() }
    private func publishZoom() { setNeedsDisplay(); onZoom?(Double(canvasRect.width / documentSize.width * 100)) }
    override func layoutSubviews() { super.layoutSubviews(); publishZoom() }
    func cancelInput() { if drawing { drawing = false; onInput?(lastPoint, -1) } }
    @objc private func panned(_ sender: UIPanGestureRecognizer) {
        if sender.state == .began { cancelInput() }
        let delta = sender.translation(in: self); offset.x += delta.x; offset.y += delta.y
        sender.setTranslation(.zero, in: self); setNeedsDisplay()
    }
    @objc private func pinched(_ sender: UIPinchGestureRecognizer) {
        if sender.state == .began { cancelInput() }
        let anchor = sender.location(in: self), before = documentPoint(anchor)
        zoom = min(32, max(0.05, zoom * sender.scale)); sender.scale = 1
        let after = viewPoint(before); offset.x += anchor.x - after.x; offset.y += anchor.y - after.y
        publishZoom()
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tool != .hand, event?.allTouches?.count == 1, let touch = touches.first else { cancelInput(); return }
        let point = touch.location(in: self)
        guard canvasRect.contains(point), !showsRulers || (point.x >= 24 && point.y >= 24) else { return }
        drawing = true; lastPoint = documentPoint(point); onInput?(lastPoint, 0)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard drawing, let touch = touches.first else { return }
        if (event?.allTouches?.count ?? 1) > 1 { cancelInput(); return }
        for item in event?.coalescedTouches(for: touch) ?? [touch] {
            lastPoint = documentPoint(item.location(in: self)); onInput?(lastPoint, 1)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard drawing, let touch = touches.first else { return }
        drawing = false; lastPoint = documentPoint(touch.location(in: self)); onInput?(lastPoint, 2)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelInput() }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let paper = canvasRect
        context.saveGState(); context.clip(to: paper)
        context.setFillColor(UIColor(white: 0.72, alpha: 1).cgColor); context.fill(paper)
        let tile: CGFloat = 12
        let clipped = paper.intersection(bounds)
        if !clipped.isNull {
            context.setFillColor(UIColor(white: 0.56, alpha: 1).cgColor)
            let left = Int(floor((clipped.minX - paper.minX) / tile)), top = Int(floor((clipped.minY - paper.minY) / tile))
            let right = Int(ceil((clipped.maxX - paper.minX) / tile)), bottom = Int(ceil((clipped.maxY - paper.minY) / tile))
            for y in top..<bottom { for x in left..<right where (x + y) % 2 == 0 {
                context.fill(CGRect(x: paper.minX + CGFloat(x) * tile, y: paper.minY + CGFloat(y) * tile, width: tile, height: tile))
            } }
        }
        image?.draw(in: paper)
        context.restoreGState()
        context.setStrokeColor(UIColor(white: 0.38, alpha: 1).cgColor); context.setLineWidth(1); context.stroke(paper)
        if let outline {
            context.saveGState()
            context.translateBy(x: paper.minX, y: paper.maxY)
            let scale = paper.width / documentSize.width
            context.scaleBy(x: scale, y: -scale); context.addPath(outline)
            context.setLineWidth(2 / scale); context.setStrokeColor(UIColor.black.cgColor); context.strokePath()
            context.addPath(outline); context.setLineWidth(1 / scale)
            context.setLineDash(phase: 0, lengths: [5 / scale, 5 / scale]); context.setStrokeColor(UIColor.white.cgColor); context.strokePath()
            context.restoreGState()
        }
        if showsRulers { drawRulers(context) }
    }
    /// Same desktop ruler spacing, adapted to UIKit's downward view coordinates.
    /// Only on-screen ticks are generated, even at the maximum document size/zoom.
    func rulerTicks(horizontal: Bool) -> [(value: Double, position: CGFloat)] {
        let paper = canvasRect, scale = paper.width / documentSize.width
        guard scale.isFinite, scale > 0 else { return [] }
        let step = pow(10, floor(log10(max(1, 80 / scale))))
        let unit = step * (step * scale < 35 ? 5 : 1)
        let length = horizontal ? bounds.width : bounds.height
        let start = horizontal ? (24 - paper.minX) / scale : (paper.maxY - length) / scale
        var value = floor(start / unit) * unit, ticks: [(Double, CGFloat)] = []
        // At least 35 view pixels between ticks; the cap is a defensive bound,
        // not a truncation of any realistically sized native screen.
        for _ in 0..<256 {
            let position = horizontal ? paper.minX + value * scale : paper.maxY - value * scale
            if horizontal ? position > length : position < 24 { break }
            if position >= 24 && position <= length { ticks.append((Double(value), position)) }
            value += unit
        }
        return ticks
    }
    private func drawRulers(_ context: CGContext) {
        let height: CGFloat = 24
        context.saveGState(); defer { context.restoreGState() }
        context.setFillColor(MobileTheme.panel.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: bounds.width, height: height))
        context.fill(CGRect(x: 0, y: 0, width: height, height: bounds.height))
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular), .foregroundColor: MobileTheme.secondary]
        context.setStrokeColor(MobileTheme.secondary.cgColor); context.setLineWidth(0.5)
        for tick in rulerTicks(horizontal: true) {
            context.move(to: CGPoint(x: tick.position, y: height - 5)); context.addLine(to: CGPoint(x: tick.position, y: height))
            String(Int(tick.value)).draw(at: CGPoint(x: tick.position + 3, y: 3), withAttributes: attributes)
        }
        for tick in rulerTicks(horizontal: false) {
            context.move(to: CGPoint(x: height - 5, y: tick.position)); context.addLine(to: CGPoint(x: height, y: tick.position))
            String(Int(tick.value)).draw(at: CGPoint(x: 1, y: tick.position + 2), withAttributes: attributes)
        }
        context.strokePath()
    }
}
