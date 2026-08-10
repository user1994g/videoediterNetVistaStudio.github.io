import Foundation
import CoreImage
import CoreGraphics

enum UltraKeyOutputMode: String, Codable, CaseIterable {
    case composite
    case alpha
    case color

    var title: String {
        switch self {
        case .composite: return "Composite"
        case .alpha: return "Alpha Channel"
        case .color: return "Color Channel"
        }
    }
}

/// A portable, native chroma-key model arranged like a professional Ultra Key
/// workflow. Values are normalized to 0...1 unless their names say otherwise.
/// The renderer deliberately lives outside the UI so preview and export use
/// exactly the same matte.
struct UltraKeySettings: Codable, Equatable {
    var enabled = false
    var output: UltraKeyOutputMode = .composite
    var keyRed = 0.0
    var keyGreen = 1.0
    var keyBlue = 0.0

    // Matte Generation
    var transparency = 0.45
    var highlight = 0.10
    var shadow = 0.50
    var tolerance = 0.50
    var pedestal = 0.10

    // Matte Cleanup
    var choke = 0.0
    var soften = 0.0
    var matteContrast = 0.0
    var midpoint = 0.50

    // Spill Suppression
    var desaturate = 0.25
    var spillRange = 0.50
    var spill = 0.50
    var luma = 0.50

    // Foreground Color Correction
    var saturation = 1.0
    var hueDegrees = 0.0
    var luminance = 1.0

    private enum CodingKeys: String, CodingKey {
        case enabled, output, keyRed, keyGreen, keyBlue
        case transparency, highlight, shadow, tolerance, pedestal
        case choke, soften, matteContrast, midpoint
        case desaturate, spillRange, spill, luma
        case saturation, hueDegrees, luminance
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        output = try c.decodeIfPresent(UltraKeyOutputMode.self, forKey: .output) ?? .composite
        keyRed = try c.decodeIfPresent(Double.self, forKey: .keyRed) ?? 0
        keyGreen = try c.decodeIfPresent(Double.self, forKey: .keyGreen) ?? 1
        keyBlue = try c.decodeIfPresent(Double.self, forKey: .keyBlue) ?? 0
        transparency = try c.decodeIfPresent(Double.self, forKey: .transparency) ?? 0.45
        highlight = try c.decodeIfPresent(Double.self, forKey: .highlight) ?? 0.10
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? 0.50
        tolerance = try c.decodeIfPresent(Double.self, forKey: .tolerance) ?? 0.50
        pedestal = try c.decodeIfPresent(Double.self, forKey: .pedestal) ?? 0.10
        choke = try c.decodeIfPresent(Double.self, forKey: .choke) ?? 0
        soften = try c.decodeIfPresent(Double.self, forKey: .soften) ?? 0
        matteContrast = try c.decodeIfPresent(Double.self, forKey: .matteContrast) ?? 0
        midpoint = try c.decodeIfPresent(Double.self, forKey: .midpoint) ?? 0.50
        desaturate = try c.decodeIfPresent(Double.self, forKey: .desaturate) ?? 0.25
        spillRange = try c.decodeIfPresent(Double.self, forKey: .spillRange) ?? 0.50
        spill = try c.decodeIfPresent(Double.self, forKey: .spill) ?? 0.50
        luma = try c.decodeIfPresent(Double.self, forKey: .luma) ?? 0.50
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        hueDegrees = try c.decodeIfPresent(Double.self, forKey: .hueDegrees) ?? 0
        luminance = try c.decodeIfPresent(Double.self, forKey: .luminance) ?? 1
    }
}

/// Core Image implementation of NetVista's Ultra Key workflow. A cached 3D
/// color cube creates a luminance-independent chroma matte and despills the key
/// channel. This keeps paused-frame interaction responsive and is supported by
/// the same GPU-backed Core Image path used by timeline export.
enum UltraKeyRuntime {
    private static let cubeDimension = 32
    private static let cache = NSCache<NSString, NSData>()
    private static let cacheLock = NSLock()

    static func apply(to source: CIImage, settings: UltraKeySettings) -> CIImage {
        guard settings.enabled else { return source }
        let data = cubeData(for: settings)
        var image = source.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": cubeDimension,
            "inputCubeData": data
        ])
        guard settings.output == .composite else { return image.cropped(to: source.extent) }

        if abs(settings.saturation - 1) > 0.0001 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: clamp(settings.saturation, 0, 2)
            ])
        }
        if abs(settings.hueDegrees) > 0.0001 {
            image = image.applyingFilter("CIHueAdjust", parameters: [
                "inputAngle": clamp(settings.hueDegrees, -180, 180) * .pi / 180
            ])
        }
        if abs(settings.luminance - 1) > 0.0001 {
            let gain = clamp(settings.luminance, 0, 2)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }
        return image.cropped(to: source.extent)
    }

    /// Deterministic scalar form used by tests and by the color-cube builder.
    /// Keeping this public to the module makes the matte testable even on Macs
    /// where a headless Core Image context cannot allocate a render device.
    static func diagnosticSample(red: Double, green: Double, blue: Double, settings: UltraKeySettings) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        Evaluator(settings: settings).sample(red: red, green: green, blue: blue)
    }

    private static func cubeData(for settings: UltraKeySettings) -> Data {
        let key = cacheKey(settings) as NSString
        cacheLock.lock()
        if let cached = cache.object(forKey: key) {
            cacheLock.unlock()
            return cached as Data
        }
        cacheLock.unlock()

        let dimension = cubeDimension
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        let evaluator = Evaluator(settings: settings)

        for blueIndex in 0..<dimension {
            let blue = Double(blueIndex) / Double(dimension - 1)
            for greenIndex in 0..<dimension {
                let green = Double(greenIndex) / Double(dimension - 1)
                for redIndex in 0..<dimension {
                    let red = Double(redIndex) / Double(dimension - 1)
                    let sample = evaluator.sample(red: red, green: green, blue: blue)
                    values += [Float(sample.red), Float(sample.green), Float(sample.blue), Float(sample.alpha)]
                }
            }
        }
        let result = values.withUnsafeBufferPointer { Data(buffer: $0) }
        cacheLock.lock()
        cache.countLimit = 32
        cache.setObject(result as NSData, forKey: key, cost: result.count)
        cache.totalCostLimit = 32 * 1024 * 1024
        cacheLock.unlock()
        return result
    }

    private static func cacheKey(_ s: UltraKeySettings) -> String {
        let values: [Double] = [s.keyRed, s.keyGreen, s.keyBlue, s.transparency, s.highlight, s.shadow, s.tolerance, s.pedestal, s.choke, s.soften, s.matteContrast, s.midpoint, s.desaturate, s.spillRange, s.spill, s.luma]
        return ([s.output.rawValue] + values.map { String(format: "%.4f", $0) }).joined(separator: "|")
    }

    private struct Evaluator {
        let settings: UltraKeySettings
        let keyRGB: [Double]
        let keyChroma: [Double]
        let dominantKeyChannel: Int
        let threshold: Double
        let feather: Double
        let matteScale: Double
        let midpoint: Double

        init(settings: UltraKeySettings) {
            self.settings = settings
            keyRGB = [clamp(settings.keyRed), clamp(settings.keyGreen), clamp(settings.keyBlue)]
            let keyTotal = max(0.0001, keyRGB.reduce(0, +))
            keyChroma = keyRGB.map { $0 / keyTotal }
            dominantKeyChannel = keyRGB.enumerated().max(by: { $0.element < $1.element })?.offset ?? 1
            threshold = 0.025 + clamp(settings.tolerance) * 0.42 + clamp(settings.transparency) * 0.10 + clamp(settings.pedestal) * 0.10 + clamp(settings.choke) * 0.08
            feather = 0.008 + clamp(settings.soften) * 0.30
            matteScale = 1 + clamp(settings.matteContrast) * 4
            midpoint = clamp(settings.midpoint)
        }

        func sample(red: Double, green: Double, blue: Double) -> (red: Double, green: Double, blue: Double, alpha: Double) {
            var rgb = [red, green, blue]
            let total = max(0.0001, red + green + blue)
            let chroma = rgb.map { $0 / total }
            let distance = sqrt(zip(chroma, keyChroma).reduce(0) { $0 + pow($1.0 - $1.1, 2) })
            var alpha = smoothstep(threshold, threshold + feather, distance)
            let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
            let edge = alpha * (1 - alpha)
            alpha += edge * (max(0, luminance - 0.5) * clamp(settings.highlight) + max(0, 0.5 - luminance) * clamp(settings.shadow))
            alpha = clamp((alpha - midpoint) * matteScale + midpoint)

            let otherMaximum = rgb.enumerated().filter { $0.offset != dominantKeyChannel }.map(\.element).max() ?? 0
            let dominance = max(0, rgb[dominantKeyChannel] - otherMaximum)
            let spillWeight = clamp((1 - alpha) * clamp(settings.spill) * (0.35 + clamp(settings.spillRange)))
            let originalLuma = luminance
            rgb[dominantKeyChannel] = max(0, rgb[dominantKeyChannel] - dominance * spillWeight)
            let correctedLuma = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
            let restoredLuma = correctedLuma + (originalLuma - correctedLuma) * clamp(settings.luma)
            let desaturation = clamp(settings.desaturate) * spillWeight
            rgb = rgb.map { clamp(($0 + (restoredLuma - correctedLuma)) * (1 - desaturation) + restoredLuma * desaturation) }

            switch settings.output {
            case .composite: return (rgb[0], rgb[1], rgb[2], alpha)
            case .alpha: return (alpha, alpha, alpha, 1)
            case .color:
                let removed = 1 - alpha
                return (keyRGB[0] * removed, keyRGB[1] * removed, keyRGB[2] * removed, 1)
            }
        }
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = clamp((value - edge0) / max(0.0001, edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    private static func clamp(_ value: Double, _ minimum: Double = 0, _ maximum: Double = 1) -> Double {
        min(maximum, max(minimum, value))
    }
}
