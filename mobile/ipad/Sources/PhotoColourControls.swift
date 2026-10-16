import UIKit

/// Shares the desktop's RGB swatch preferences format. Tap selects a colour;
/// long-press edits that slot with the system colour picker.
@MainActor final class MobilePhotoPaletteView: UIView {
    var onSelect: ((UIColor) -> Void)?
    var onEdit: ((Int, UIColor) -> Void)?
    private let defaults: UserDefaults, key: String
    private(set) var colours: [UIColor]
    private var buttons: [UIButton] = []
    init(defaults: UserDefaults = .standard, key: String = "netvista.photos.swatches") {
        self.defaults = defaults; self.key = key
        let base: [UIColor] = [.black, .white, .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
        let saved = defaults.array(forKey: key) as? [[Double]]
        colours = base.enumerated().map { index, fallback in
            guard let saved, saved.indices.contains(index), saved[index].count == 3,
                  saved[index].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return fallback }
            return UIColor(red: saved[index][0], green: saved[index][1], blue: saved[index][2], alpha: 1)
        }
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 102).isActive = true
        for index in colours.indices {
            let button = UIButton(type: .system); button.tag = index
            button.accessibilityIdentifier = "photo.palette.swatch.\(index)"; button.accessibilityLabel = "Colour swatch \(index + 1)"
            button.accessibilityHint = "Tap to select. Long press to edit and save this colour."
            button.layer.borderWidth = 1; button.layer.borderColor = MobileTheme.line.cgColor; button.layer.cornerRadius = 5
            button.backgroundColor = colours[index]
            button.addAction(UIAction { [weak self] _ in guard let self else { return }; self.onSelect?(self.colours[index]) }, for: .touchUpInside)
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(editSwatch(_:))); button.addGestureRecognizer(hold)
            addSubview(button); buttons.append(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layoutSubviews() {
        super.layoutSubviews(); let width = max(44, (bounds.width - 18) / 4)
        for (index, button) in buttons.enumerated() { button.frame = CGRect(x: CGFloat(index % 4) * (width + 6), y: CGFloat(index / 4) * 50, width: width, height: 44) }
    }
    @objc private func editSwatch(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let index = recognizer.view?.tag, colours.indices.contains(index) else { return }
        onEdit?(index, colours[index])
    }
    func setColour(_ colour: UIColor, at index: Int) {
        guard colours.indices.contains(index) else { return }
        let rgb = PhotoPixels.components(colour)
        guard [rgb.red, rgb.green, rgb.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return }
        colours[index] = UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1); buttons[index].backgroundColor = colours[index]
        defaults.set(colours.map { let c = PhotoPixels.components($0); return [c.red, c.green, c.blue] }, forKey: key)
    }
}

/// The desktop's same three fixed input anchors and smooth curve. Touch samples
/// and hardware-pointer touches drive one transaction through these callbacks.
@MainActor final class MobilePhotoToneCurveView: UIView {
    var values = [0.25, 0.5, 0.75] { didSet { setNeedsDisplay() } }
    var isEnabled = true { didSet { isUserInteractionEnabled = isEnabled; alpha = isEnabled ? 1 : 0.5 } }
    var onBegin: (() -> Bool)?, onChange: (([Double]) -> Void)?, onEnd: ((Bool) -> Void)?
    private var dragging: Int?, before = [Double]()
    var plot: CGRect { CGRect(x: 12, y: 12, width: max(1, bounds.width - 24), height: max(1, bounds.height - 24)) }
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = MobileTheme.top; layer.cornerRadius = 5; clipsToBounds = true
        accessibilityIdentifier = "photo.curve"; accessibilityLabel = "Tone curve: shadows, midtones and highlights"
        heightAnchor.constraint(equalToConstant: 160).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func point(at index: Int, output: Double) -> CGPoint { CGPoint(x: plot.minX + CGFloat(index + 1) * plot.width / 4, y: plot.maxY - output * plot.height) }
    func input(_ point: CGPoint, phase: Int) {
        guard isEnabled else { return }
        if phase < 0 {
            guard dragging != nil else { return }
            dragging = nil; values = before; onEnd?(true); return
        }
        guard bounds.width > 24, bounds.height > 24, values.count == 3, values.allSatisfy(\.isFinite),
              point.x.isFinite, point.y.isFinite else { input(.zero, phase: -1); return }
        if phase == 0 {
            guard onBegin?() != false else { return }
            let fraction = max(0, min(1, (point.x - plot.minX) / plot.width))
            before = values; dragging = max(0, min(2, Int((fraction * 4).rounded()) - 1))
        }
        guard let index = dragging else { return }
        values[index] = max(0, min(1, Double((plot.maxY - point.y) / max(1, plot.height)))); onChange?(values)
        if phase == 2 { dragging = nil; onEnd?(false) }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { input(touch.location(in: self), phase: 0) } }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { input(touch.location(in: self), phase: 1) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { input(touch.location(in: self), phase: 2) } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { input(.zero, phase: -1) }
    override func draw(_ rect: CGRect) {
        guard bounds.width > 24, bounds.height > 24, values.count == 3, values.allSatisfy(\.isFinite), let context = UIGraphicsGetCurrentContext() else { return }
        let graph = plot; context.setLineWidth(1); context.setStrokeColor(MobileTheme.line.cgColor)
        for i in 0...4 { let f = CGFloat(i) / 4; context.move(to: CGPoint(x: graph.minX + graph.width * f, y: graph.minY)); context.addLine(to: CGPoint(x: graph.minX + graph.width * f, y: graph.maxY)); context.move(to: CGPoint(x: graph.minX, y: graph.minY + graph.height * f)); context.addLine(to: CGPoint(x: graph.maxX, y: graph.minY + graph.height * f)) }; context.strokePath()
        let ys = [0.0] + values + [1.0]
        let points = ys.enumerated().map { CGPoint(x: graph.minX + CGFloat($0.offset) * graph.width / 4, y: graph.maxY - $0.element * graph.height) }
        context.saveGState(); context.clip(to: graph); context.setStrokeColor(MobileTheme.accent.cgColor); context.setLineWidth(2); context.move(to: points[0])
        for i in 0..<4 {
            let a = points[i], b = points[i + 1], dx = (b.x - a.x) / 3
            let sa = i == 0 ? (ys[1] - ys[0]) * 4 : (ys[i + 1] - ys[i - 1]) * 2
            let sb = i == 3 ? (ys[4] - ys[3]) * 4 : (ys[i + 2] - ys[i]) * 2
            context.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y - sa * graph.height / 12), control2: CGPoint(x: b.x - dx, y: b.y + sb * graph.height / 12))
        }
        context.strokePath(); context.restoreGState(); context.setFillColor(UIColor.white.cgColor)
        for point in points.dropFirst().dropLast() { context.fillEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)) }
    }
}
