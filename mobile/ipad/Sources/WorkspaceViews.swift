import UIKit

enum MobileTheme {
    static func color(_ rgb: UInt32) -> UIColor { UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1) }
    static let window = color(0x17191E), top = color(0x111317), panel = color(0x20232A), workspace = color(0x181B21)
    static let control = color(0x242A33), secondary = color(0x9DA6B5), accent = color(0xF05B5E), line = color(0x363B46)
    static let video = color(0x356F9F), audio = color(0x188B74)
    static func label(_ text: String, size: CGFloat = 12, weight: UIFont.Weight = .regular) -> UILabel {
        let value = UILabel(); value.text = text; value.font = .systemFont(ofSize: size, weight: weight)
        value.textColor = .white; value.numberOfLines = 1; value.lineBreakMode = .byTruncatingTail; return value
    }
    static func button(_ text: String, symbol: String? = nil, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(text, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        button.titleLabel?.numberOfLines = 1; button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.setTitleColor(.white, for: .normal); button.tintColor = .white
        if let symbol { button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15)), for: .normal) }
        button.backgroundColor = control; button.layer.cornerRadius = 5
        button.accessibilityLabel = text.isEmpty ? symbol : text
        button.addAction(UIAction { _ in action() }, for: .touchUpInside); return button
    }
}

final class MobileTimelineView: UIView, UIScrollViewDelegate {
    var project = MobileProject() {
        didSet {
            var cursor: Double = 0
            starts = project.clips.map { clip in defer { cursor += clip.length }; return cursor }
            canvas.setNeedsDisplay(); updateSize()
        }
    }
    var selected: Int? { didSet { canvas.setNeedsDisplay() } }
    var time: Double = 0 { didSet { canvas.setNeedsDisplay() } }
    var blade = false
    var canEdit = true
    var onSelect: ((Int, Double) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onSplit: ((Int, Double) -> Void)?
    var onTrim: ((Int, Double, Double) -> Void)?
    private let scroll = UIScrollView()
    fileprivate let canvas = MobileTimelineCanvas()
    fileprivate var pixels: CGFloat = 35
    fileprivate var starts: [Double] = []
    fileprivate var scrollOffset: CGFloat { scroll.contentOffset.x }
    private var virtualWidth: CGFloat = 0
    private var fitMode = true
    private let gutter: CGFloat = 68

    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = MobileTheme.workspace
        scroll.backgroundColor = MobileTheme.workspace; scroll.showsHorizontalScrollIndicator = true
        scroll.alwaysBounceHorizontal = true; scroll.delegate = self
        addSubview(scroll); scroll.addSubview(canvas); canvas.owner = self
        isAccessibilityElement = false; accessibilityLabel = "Video timeline"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layoutSubviews() { super.layoutSubviews(); scroll.frame = CGRect(x: gutter, y: 0, width: max(1, bounds.width - gutter), height: bounds.height); updateSize() }
    private func updateSize() {
        if fitMode { pixels = max(6, min(600, (scroll.bounds.width - 24) / CGFloat(max(8, project.totalDuration)))) }
        virtualWidth = max(scroll.bounds.width, CGFloat(max(8, project.totalDuration)) * pixels + 80)
        scroll.contentSize = CGSize(width: virtualWidth, height: max(150, bounds.height - 5))
        // The timeline coordinates are virtual; only one viewport-sized native
        // canvas is backed by pixels, even with hours of clips at high zoom.
        layoutCanvas(); setNeedsDisplay()
    }
    private func layoutCanvas() {
        canvas.frame = CGRect(x: scroll.contentOffset.x, y: 0, width: max(1, scroll.bounds.width), height: max(150, bounds.height - 5))
        canvas.setNeedsDisplay()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { layoutCanvas() }
    func zoom(_ multiplier: CGFloat) { fitMode = false; pixels = max(6, min(2000, pixels * multiplier)); updateSize(); revealPlayhead() }
    func fit() { fitMode = true; updateSize(); scroll.setContentOffset(.zero, animated: false) }
    func revealPlayhead() {
        let x = CGFloat(time) * pixels
        if x < scroll.contentOffset.x || x > scroll.contentOffset.x + scroll.bounds.width - 32 {
            scroll.setContentOffset(CGPoint(x: max(0, min(virtualWidth - scroll.bounds.width, x - scroll.bounds.width / 3)), y: 0), animated: false)
        }
    }
    fileprivate func clipRect(_ index: Int) -> CGRect {
        let start = starts.indices.contains(index) ? starts[index] : 0
        return CGRect(x: CGFloat(start) * pixels + 1, y: 39, width: max(4, CGFloat(project.clips[index].length) * pixels - 2), height: 49)
    }
    override func draw(_ rect: CGRect) {
        let context = UIGraphicsGetCurrentContext()!; context.setFillColor(MobileTheme.panel.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: gutter, height: bounds.height))
        for (text, y) in [("TIME", CGFloat(9)), ("V1", 49), ("Video", 66), ("A1", 105), ("Audio", 122)] {
            (text as NSString).draw(at: CGPoint(x: 12, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: text.count <= 4 ? 11 : 10, weight: .medium), .foregroundColor: text == "Video" || text == "Audio" ? MobileTheme.secondary : UIColor.white])
        }
        context.setStrokeColor(MobileTheme.line.cgColor); context.move(to: CGPoint(x: gutter - 0.5, y: 0)); context.addLine(to: CGPoint(x: gutter - 0.5, y: bounds.height)); context.strokePath()
    }
}

fileprivate final class MobileTimelineCanvas: UIView, UIGestureRecognizerDelegate {
    weak var owner: MobileTimelineView?
    private var dragging: Int?
    private var initial = CGPoint.zero
    private var draggedX: CGFloat = 0
    private var edge = 0
    private var original: MobileClip?
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = MobileTheme.workspace
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
        let press = UILongPressGestureRecognizer(target: self, action: #selector(drag(_:))); press.minimumPressDuration = 0.22
        addGestureRecognizer(press)
        let scrub = UIPanGestureRecognizer(target: self, action: #selector(scrub(_:))); scrub.delegate = self; addGestureRecognizer(scrub)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { gestureRecognizer.location(in: self).y < 34 }
    private func index(_ point: CGPoint) -> Int? { guard let owner else { return nil }; return owner.project.clips.indices.first { owner.clipRect($0).insetBy(dx: 0, dy: -2).contains(point) } }
    private func absolute(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + (owner?.scrollOffset ?? 0), y: point.y) }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        guard let owner else { return }; let point = absolute(gesture.location(in: self))
        let seconds = min(owner.project.totalDuration, max(0, Double(point.x / owner.pixels)))
        if let index = index(point) {
            owner.onSelect?(index, seconds)
            if owner.blade && owner.canEdit {
                let start = owner.project.clips.prefix(index).reduce(0) { $0 + $1.length }
                owner.onSplit?(index, seconds - start)
            }
        } else { owner.onSeek?(seconds) }
    }
    @objc private func scrub(_ gesture: UIPanGestureRecognizer) { guard let owner else { return }; owner.onSeek?(min(owner.project.totalDuration, max(0, Double(absolute(gesture.location(in: self)).x / owner.pixels)))) }
    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) { owner?.zoom(gesture.scale); gesture.scale = 1 }
    @objc private func drag(_ gesture: UILongPressGestureRecognizer) {
        guard let owner else { return }
        guard owner.canEdit else { dragging = nil; original = nil; setNeedsDisplay(); return }
        let point = absolute(gesture.location(in: self))
        switch gesture.state {
        case .began:
            guard let index = index(point) else { return }; dragging = index; original = owner.project.clips[index]; initial = point; draggedX = 0
            let box = owner.clipRect(index); edge = point.x - box.minX < 12 ? -1 : box.maxX - point.x < 12 ? 1 : 0
            owner.onSelect?(index, Double(box.minX / owner.pixels))
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed:
            draggedX = point.x - initial.x; setNeedsDisplay()
        case .ended:
            defer { dragging = nil; original = nil; setNeedsDisplay() }
            guard let index = dragging, let clip = original else { return }
            let delta = Double(draggedX / owner.pixels)
            if edge < 0 { owner.onTrim?(index, min(clip.outPoint - 0.04, max(0, clip.inPoint + delta)), clip.outPoint) }
            else if edge > 0 { owner.onTrim?(index, clip.inPoint, max(clip.inPoint + 0.04, min(clip.duration, clip.outPoint + delta))) }
            else {
                let middle = owner.clipRect(index).midX + draggedX
                let destination = owner.project.clips.indices.filter { $0 != index && owner.clipRect($0).midX < middle }.count
                owner.onMove?(index, min(owner.project.clips.count - 1, destination))
            }
        case .cancelled, .failed: dragging = nil; original = nil; setNeedsDisplay()
        default: break
        }
    }
    override func draw(_ dirtyRect: CGRect) {
        guard let owner, let context = UIGraphicsGetCurrentContext() else { return }
        let rect = dirtyRect.offsetBy(dx: owner.scrollOffset, dy: 0)
        context.translateBy(x: -owner.scrollOffset, y: 0)
        let font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let step: Double = owner.pixels > 150 ? 0.5 : owner.pixels > 70 ? 1 : owner.pixels > 25 ? 2 : owner.pixels > 12 ? 5 : 10
        var tick = floor(Double(rect.minX / owner.pixels) / step) * step
        while CGFloat(tick) * owner.pixels < rect.maxX {
            let x = CGFloat(tick) * owner.pixels
            context.setStrokeColor(MobileTheme.line.cgColor); context.setLineWidth(0.5)
            context.move(to: CGPoint(x: x, y: 23)); context.addLine(to: CGPoint(x: x, y: bounds.height)); context.strokePath()
            let text = tick < 60 ? String(format: "%02.0fs", tick) : String(format: "%02d:%02d", Int(tick) / 60, Int(tick) % 60)
            (text as NSString).draw(at: CGPoint(x: x + 4, y: 7), withAttributes: [.font: font, .foregroundColor: MobileTheme.secondary]); tick += step
        }
        for y in [CGFloat(33), 93, 143] { context.setStrokeColor(MobileTheme.line.cgColor); context.move(to: CGPoint(x: rect.minX, y: y)); context.addLine(to: CGPoint(x: rect.maxX, y: y)); context.strokePath() }
        if owner.project.clips.isEmpty { ("Import media, then add clips to the timeline" as NSString).draw(at: CGPoint(x: 18, y: 57), withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: MobileTheme.secondary]) }
        for index in owner.project.clips.indices {
            let clip = owner.project.clips[index]; let box = owner.clipRect(index)
            guard box.intersects(rect) else { continue }
            let path = UIBezierPath(roundedRect: box, cornerRadius: 4); MobileTheme.video.setFill(); path.fill()
            if owner.selected == index { UIColor.white.setStroke(); path.lineWidth = 1.5; path.stroke() }
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (clip.name as NSString).draw(in: box.insetBy(dx: 8, dy: 8), withAttributes: [.font: UIFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
            let audio = CGRect(x: box.minX, y: 100, width: box.width, height: 34)
            MobileTheme.audio.setFill(); UIBezierPath(roundedRect: audio, cornerRadius: 3).fill()
            ("Linked source audio" as NSString).draw(in: audio.insetBy(dx: 8, dy: 10), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
        }
        if let index = dragging {
            var box = owner.clipRect(index); if edge == 0 { box.origin.x += draggedX } else if edge < 0 { box.origin.x += draggedX; box.size.width -= draggedX } else { box.size.width += draggedX }
            MobileTheme.accent.withAlphaComponent(0.5).setFill(); UIBezierPath(roundedRect: box, cornerRadius: 4).fill()
        }
        let head = CGFloat(owner.time) * owner.pixels
        context.setStrokeColor(MobileTheme.accent.cgColor); context.setLineWidth(1.5); context.move(to: CGPoint(x: head, y: 0)); context.addLine(to: CGPoint(x: head, y: bounds.height)); context.strokePath()
        let pointer = UIBezierPath(); pointer.move(to: CGPoint(x: head - 5, y: 0)); pointer.addLine(to: CGPoint(x: head + 5, y: 0)); pointer.addLine(to: CGPoint(x: head, y: 8)); pointer.close(); MobileTheme.accent.setFill(); pointer.fill()
    }
}

final class MobilePropertyRow: UIView {
    let key: String
    let slider = UISlider()
    private let name: UILabel
    private let value = UIButton(type: .system)
    var onBegin: (() -> Void)?
    var onChange: ((String, Double, Bool) -> Void)?
    var onNumeric: ((String) -> Void)?
    let multiplier: Double
    init(key: String, title: String, range: ClosedRange<Double>, multiplier: Double = 1) {
        self.key = key; self.multiplier = multiplier; name = MobileTheme.label(title, size: 11)
        super.init(frame: .zero); addSubview(name); addSubview(slider); addSubview(value)
        slider.minimumValue = Float(range.lowerBound); slider.maximumValue = Float(range.upperBound); slider.tintColor = MobileTheme.accent
        slider.accessibilityLabel = title; value.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        value.tintColor = .white; value.backgroundColor = MobileTheme.top; value.layer.cornerRadius = 4
        slider.addTarget(self, action: #selector(begin), for: .touchDown)
        slider.addTarget(self, action: #selector(changed), for: .valueChanged)
        slider.addTarget(self, action: #selector(ended), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        value.addAction(UIAction { [weak self] _ in guard let self else { return }; self.onNumeric?(self.key) }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func set(_ number: Double, enabled: Bool) { slider.value = Float(number); slider.isEnabled = enabled; value.isEnabled = enabled; updateValue(); alpha = enabled ? 1 : 0.4 }
    private func updateValue() { value.setTitle(String(format: "%.1f", Double(slider.value) * multiplier), for: .normal) }
    @objc private func begin() { onBegin?() }
    @objc private func changed() { updateValue(); onChange?(key, Double(slider.value), false) }
    @objc private func ended() { updateValue(); onChange?(key, Double(slider.value), true) }
    override func layoutSubviews() { super.layoutSubviews(); name.frame = CGRect(x: 0, y: 0, width: 72, height: 44); value.frame = CGRect(x: bounds.width - 53, y: 5, width: 53, height: 34); slider.frame = CGRect(x: 75, y: 0, width: max(40, bounds.width - 133), height: 44) }
}
