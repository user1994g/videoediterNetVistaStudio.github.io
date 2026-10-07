import Cocoa
import CoreImage

/// Explicit, bounded RGBA samples. Never assume a CGImage provider's channel
/// order, row padding or pixel format, and never render full-resolution media
/// just to draw a small scope. Values describe an SDR, sRGB preview.
struct GradeScopeSamples {
    let width: Int
    let height: Int
    let rgba: [UInt8]
    static let maximumWidth = 320
    static let maximumHeight = 180

    static func render(_ image: CIImage, context: CIContext) -> GradeScopeSamples? {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull,
              [extent.minX, extent.minY, extent.width, extent.height].allSatisfy({ $0.isFinite }),
              extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, CGFloat(maximumWidth) / extent.width, CGFloat(maximumHeight) / extent.height)
        let width = max(1, Int((extent.width * scale).rounded(.down)))
        let height = max(1, Int((extent.height * scale).rounded(.down)))
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(normalized, toBitmap: &bytes, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return GradeScopeSamples(width: width, height: height, rgba: bytes)
    }

    func histogram() -> [Int] {
        var result = [Int](repeating: 0, count: 256)
        for pixel in 0..<(width * height) { result[value(at: pixel, channel: nil)] += 1 }
        return result
    }

    /// Horizontal position must come from the image's actual row width, not a
    /// modulo stride that mixes unrelated columns. Used by waveform/parade.
    func density(columns: Int, levels: Int, channel: Int? = nil) -> [Int] {
        guard columns > 0, levels > 0 else { return [] }
        var bins = [Int](repeating: 0, count: columns * levels)
        for y in 0..<height {
            for x in 0..<width {
                let column = min(columns - 1, x * columns / width)
                let level = min(levels - 1, value(at: y * width + x, channel: channel) * levels / 256)
                bins[level * columns + column] += 1
            }
        }
        return bins
    }

    func value(at pixel: Int, channel: Int?) -> Int {
        let offset = pixel * 4
        if let channel { return Int(rgba[offset + channel]) }
        return min(255, Int((0.2126 * Double(rgba[offset]) + 0.7152 * Double(rgba[offset + 1]) + 0.0722 * Double(rgba[offset + 2])).rounded()))
    }
}

final class GradeScopeView: NSView {
    var mode = 0 { didSet { needsDisplay = true } }
    var image: CIImage? {
        didSet { scheduleSamples() }
    }
    private(set) var samples: GradeScopeSamples?
    private let queue = DispatchQueue(label: "com.netvistastudio.colour.scopes", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var generation = 0
    private var sampling = false
    private var pendingImage: CIImage?
    private var hasPendingImage = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        StudioTheme.shared.register(self, as: .workspace)
        layer?.cornerRadius = StudioTheme.shared.palette.cornerRadius
        setAccessibilityLabel("SDR colour scopes")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func scheduleSamples() {
        precondition(Thread.isMainThread)
        generation += 1
        pendingImage = image; hasPendingImage = true
        if image == nil { samples = nil; needsDisplay = true }
        startPendingSamples()
    }
    private func startPendingSamples() {
        guard !sampling, hasPendingImage else { return }
        hasPendingImage = false
        let source = pendingImage; pendingImage = nil
        let token = generation, context = context
        guard let source else { return }
        sampling = true
        queue.async { [weak self] in
            let result = autoreleasepool { GradeScopeSamples.render(source, context: context) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sampling = false
                if self.generation == token { self.samples = result; self.needsDisplay = true }
                self.startPendingSamples()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = StudioTheme.shared.palette
        palette.workspaceBackground.setFill(); bounds.fill()
        let graph = bounds.insetBy(dx: 38, dy: 30)
        guard graph.width > 20, graph.height > 20 else { return }
        palette.separator.withAlphaComponent(0.6).setStroke()
        let grid = NSBezierPath(); grid.lineWidth = 0.5
        for index in 0...4 {
            let x = graph.minX + graph.width * CGFloat(index) / 4
            let y = graph.minY + graph.height * CGFloat(index) / 4
            grid.move(to: NSPoint(x: x, y: graph.minY)); grid.line(to: NSPoint(x: x, y: graph.maxY))
            grid.move(to: NSPoint(x: graph.minX, y: y)); grid.line(to: NSPoint(x: graph.maxX, y: y))
            if mode != 3 { text("\(index * 25)", at: NSPoint(x: 5, y: y - 5), colour: palette.secondaryText) }
        }
        grid.stroke()
        guard let samples else {
            text(image == nil ? "Select a clip to inspect its current frame" : "Sampling frame…", at: NSPoint(x: graph.minX + 14, y: graph.midY), colour: palette.secondaryText)
            return
        }
        switch mode {
        case 1:
            for channel in 0..<3 {
                let area = NSRect(x: graph.minX + graph.width * CGFloat(channel) / 3, y: graph.minY,
                                  width: graph.width / 3, height: graph.height)
                density(samples.density(columns: 80, levels: 128, channel: channel), columns: 80, levels: 128,
                        area: area, colour: [.systemRed, .systemGreen, .systemBlue][channel])
            }
        case 2:
            let bins = samples.histogram()
            let maximum = max(1, bins.max() ?? 1)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: graph.minX, y: graph.minY))
            for index in bins.indices {
                line.line(to: NSPoint(x: graph.minX + graph.width * CGFloat(index) / 255,
                                      y: graph.minY + graph.height * CGFloat(bins[index]) / CGFloat(maximum)))
            }
            line.line(to: NSPoint(x: graph.maxX, y: graph.minY)); line.close()
            NSColor.systemOrange.withAlphaComponent(0.5).setFill(); line.fill()
        case 3: vectorscope(samples, graph)
        default:
            density(samples.density(columns: 180, levels: 128), columns: 180, levels: 128,
                    area: graph, colour: .systemGreen)
        }
        text("SDR · sRGB · graded selected clip", at: NSPoint(x: graph.minX, y: 7), colour: palette.secondaryText)
    }

    private func density(_ bins: [Int], columns: Int, levels: Int, area: NSRect, colour: NSColor) {
        let maximum = max(1, bins.max() ?? 1)
        let denominator = log(1 + Double(maximum))
        for level in 0..<levels {
            for column in 0..<columns {
                let count = bins[level * columns + column]
                guard count > 0 else { continue }
                let alpha = 0.2 + 0.8 * log(1 + Double(count)) / denominator
                colour.withAlphaComponent(alpha).setFill()
                NSRect(x: area.minX + area.width * CGFloat(column) / CGFloat(columns),
                       y: area.minY + area.height * CGFloat(level) / CGFloat(levels),
                       width: max(1, area.width / CGFloat(columns)), height: max(1, area.height / CGFloat(levels))).fill()
            }
        }
    }
    private func vectorscope(_ samples: GradeScopeSamples, _ area: NSRect) {
        let centre = NSPoint(x: area.midX, y: area.midY), radius = min(area.width, area.height) * 0.43
        StudioTheme.shared.palette.separator.setStroke()
        NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)).stroke()
        for (label, r, g, b) in [("R", 1.0, 0.0, 0.0), ("Y", 1.0, 1.0, 0.0), ("G", 0.0, 1.0, 0.0), ("C", 0.0, 1.0, 1.0), ("B", 0.0, 0.0, 1.0), ("M", 1.0, 0.0, 1.0)] {
            let point = chroma(r, g, b, centre: centre, radius: radius)
            text(label, at: NSPoint(x: point.x - 3, y: point.y - 5), colour: .secondaryLabelColor)
        }
        // Step in *pixels*, never byte offsets: RGB/alpha cannot get swapped.
        let step = max(1, (samples.width * samples.height + 2499) / 2500)
        for pixel in stride(from: 0, to: samples.width * samples.height, by: step) {
            let index = pixel * 4
            let r = Double(samples.rgba[index]) / 255, g = Double(samples.rgba[index + 1]) / 255, b = Double(samples.rgba[index + 2]) / 255
            let point = chroma(r, g, b, centre: centre, radius: radius)
            NSColor(srgbRed: r, green: g, blue: b, alpha: 0.3).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)).fill()
        }
    }
    private func chroma(_ r: Double, _ g: Double, _ b: Double, centre: NSPoint, radius: CGFloat) -> NSPoint {
        let cb = -0.168736 * r - 0.331264 * g + 0.5 * b
        let cr = 0.5 * r - 0.418688 * g - 0.081312 * b
        return NSPoint(x: centre.x + CGFloat(cb) * radius * 1.6, y: centre.y + CGFloat(cr) * radius * 1.6)
    }
    private func text(_ value: String, at point: NSPoint, colour: NSColor) {
        (value as NSString).draw(at: point, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: colour])
    }
}

/// One active request and one replaceable pending request. Rapid scrubbing and
/// slider edits cannot queue hundreds of decodes or deliver old selection data.
final class ColourScopeFrameLoader {
    private let queue = DispatchQueue(label: "com.netvistastudio.colour.frame", qos: .userInitiated)
    private var running = false
    private var generation = 0
    private var pending: (() -> CIImage?)?
    private var completion: ((CIImage?) -> Void)?

    func request(makeImage: @escaping () -> CIImage?, completion: @escaping (CIImage?) -> Void) {
        precondition(Thread.isMainThread)
        generation += 1; pending = makeImage; self.completion = completion
        startNext()
    }
    func invalidate() {
        precondition(Thread.isMainThread)
        generation += 1; pending = nil; completion = nil
    }
    private func startNext() {
        guard !running, let work = pending else { return }
        pending = nil; running = true
        let token = generation
        queue.async { [weak self] in
            let image = autoreleasepool(invoking: work)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false
                if self.generation == token { self.completion?(image) }
                self.startNext()
            }
        }
    }
}
