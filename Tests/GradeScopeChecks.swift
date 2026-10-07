import Cocoa
import CoreImage

extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
}

@main struct GradeScopeChecks {
    static func pump(until condition: () -> Bool, timeout: Double = 5) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(condition(), "Async scopes timed out")
    }
    static func main() throws {
        _ = NSApplication.shared
        let context = CIContext(options: [.cacheIntermediates: false])
        let extent = CGRect(x: 53, y: -18, width: 640, height: 360)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: extent)
        let samples = GradeScopeSamples.render(red, context: context)!
        precondition(samples.width == 320 && samples.height == 180 && samples.rgba.count == 320 * 180 * 4)
        precondition(samples.rgba[0] > 250 && samples.rgba[1] == 0 && samples.rgba[2] == 0 && samples.rgba[3] == 255,
                     "Graphics context must be available and explicitly render RGBA, not all-zero pixels")
        precondition(samples.histogram().reduce(0, +) == 320 * 180)
        let portrait = GradeScopeSamples.render(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 3200)), context: context)!
        precondition(portrait.width == 90 && portrait.height == 180, "Preserve portrait aspect ratio within a bounded sample")
        precondition(GradeScopeSamples.render(CIImage(color: .white), context: context) == nil, "Refuse infinite image bounds")
        let split = GradeScopeSamples(width: 4, height: 2, rgba: [0,0,0,255, 0,0,0,255, 255,255,255,255, 255,255,255,255,
                                                               0,0,0,255, 0,0,0,255, 255,255,255,255, 255,255,255,255])
        let density = split.density(columns: 4, levels: 4)
        precondition(density[0] == 2 && density[1] == 2 && density[14] == 2 && density[15] == 2,
                     "Waveforms retain real horizontal image position")
        precondition(density.reduce(0, +) == 8 && split.histogram()[0] == 4 && split.histogram()[255] == 4)
        let channel = samples.density(columns: 4, levels: 4, channel: 0)
        precondition(channel.prefix(12).allSatisfy { $0 == 0 } && channel.suffix(4).allSatisfy { $0 > 0 })

        let loader = ColourScopeFrameLoader()
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock(); var jobs: [Int] = [], delivered: [Int] = []
        loader.request(makeImage: { lock.lock(); jobs.append(1); lock.unlock(); gate.wait(); return red }, completion: { _ in delivered.append(1) })
        loader.request(makeImage: { lock.lock(); jobs.append(2); lock.unlock(); return red }, completion: { _ in delivered.append(2) })
        loader.request(makeImage: { lock.lock(); jobs.append(3); lock.unlock(); return red }, completion: { _ in delivered.append(3) })
        gate.signal()
        pump(until: { delivered == [3] })
        lock.lock(); let ran = jobs; lock.unlock()
        precondition(ran == [1, 3], "Only one replaceable pending decode; never deliver stale work")
        let cancellationGate = DispatchSemaphore(value: 0)
        loader.request(makeImage: { cancellationGate.wait(); return red }, completion: { _ in delivered.append(4) })
        loader.invalidate(); cancellationGate.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        precondition(delivered == [3], "Closing/changing selection invalidates a pending callback")

        let view = GradeScopeView(frame: NSRect(x: 0, y: 0, width: 700, height: 430))
        view.image = red
        pump(until: { view.samples != nil })
        for mode in 0..<4 {
            view.mode = mode
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/netvista-scope-\(mode).png"))
            }
        }
        view.image = nil
        precondition(view.samples == nil)
        print("PASS: bounded RGBA/aspect/origin samples, histogram, horizontally correct waveform/parade, four native scope views, latest-only background sampling and stale decode cancellation")
    }
}
