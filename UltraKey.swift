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

    // Optional downloaded person segmentation. Off by default; ordinary
    // green/blue-screen projects do not require a model or network access.
    var aiAssistEnabled = false
    var aiAssistStrength = 0.8

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
        case enabled, output, keyRed, keyGreen, keyBlue, aiAssistEnabled, aiAssistStrength
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
        aiAssistEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiAssistEnabled) ?? false
        aiAssistStrength = try c.decodeIfPresent(Double.self, forKey: .aiAssistStrength) ?? 0.8
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
/// color cube creates a luminance-independent chroma matte; a separate cube
/// despills the foreground. Keeping the matte separate avoids interpolating
/// unassociated RGB into transparent pixels (the source of green edge halos).
/// Preview and export share this same GPU-backed path.
enum UltraKeyRuntime {
    private static let cubeDimension = 32
    private static let cache = NSCache<NSString, NSData>()
    private static let cacheLock = NSLock()

    /// `foregroundMask` is an optional, aligned grayscale person silhouette:
    /// white is person, black is background. A semantic silhouette is not a
    /// hair-accurate alpha matte. It protects the eroded person interior (e.g.
    /// green clothes), while the chroma key still resolves the fine edge.
    /// Non-person footage should leave AI assist off. Missing masks fall back
    /// to the ordinary keyer, so a model download never blocks rendering.
    static func apply(to source: CIImage, settings: UltraKeySettings, foregroundMask: CIImage? = nil) -> CIImage {
        guard settings.enabled else { return source }
        guard source.extent.isFinite, !source.extent.isEmpty else { return source }
        let extent = source.extent
        let pixelScale = max(0.5, min(4, min(extent.width, extent.height) / 1080))
        // The cubes are opaque by design. Core Image retains the input alpha,
        // and the final blend multiplies it by the cleaned matte exactly once.
        // This also preserves semitransparent imported images and overlays.
        var foreground = source.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": cubeDimension,
            "inputCubeData": cubeData(for: settings, purpose: .foreground)
        ])
        var matte = source.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": cubeDimension,
            "inputCubeData": cubeData(for: settings, purpose: .matte)
        ]).applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).cropped(to: extent)

        if settings.aiAssistEnabled, let person = foregroundMask,
           person.extent.isFinite, !person.extent.isEmpty,
           person.extent.intersection(extent).width >= extent.width * 0.99,
           person.extent.intersection(extent).height >= extent.height * 0.99 {
            let strength = clamp(settings.aiAssistStrength)
            if strength > 0 {
                let silhouette = person.cropped(to: extent).applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
                ])
                let interior = silhouette.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": 2 * pixelScale]).cropped(to: extent)
                let boundary = silhouette.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 4 * pixelScale])
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2 * pixelScale]).cropped(to: extent)
                let protected = matte.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: interior])
                    .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: boundary]).cropped(to: extent)
                let mix = CIImage(color: CIColor(red: strength, green: strength, blue: strength)).cropped(to: extent)
                matte = protected.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: matte, kCIInputMaskImageKey: mix]).cropped(to: extent)
                // If AI protects green clothing in the person interior, do
                // not also treat that clothing as unwanted reflected spill.
                let protectedColor = interior.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0)
                ])
                foreground = source.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: foreground, kCIInputMaskImageKey: protectedColor]).cropped(to: extent)
            }
        }

        // Choke is a real spatial edge contraction, not a color-distance
        // threshold. Both radii are bounded and scale modestly with footage.
        let chokeRadius = clamp(settings.choke) * 6 * pixelScale
        if chokeRadius > 0.001 {
            matte = matte.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": chokeRadius]).cropped(to: extent)
        }
        let softenRadius = clamp(settings.soften) * 4 * pixelScale
        if softenRadius > 0.001 {
            matte = matte.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: softenRadius]).cropped(to: extent)
        }
        let clear = CIImage(color: .clear).cropped(to: extent)
        var image = foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: matte
        ]).cropped(to: extent)

        if settings.output != .composite {
            let alpha = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            guard settings.output == .color else { return alpha.cropped(to: extent) }
            return alpha.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -clamp(settings.keyRed), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: -clamp(settings.keyGreen), y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: -clamp(settings.keyBlue), y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: clamp(settings.keyRed), y: clamp(settings.keyGreen), z: clamp(settings.keyBlue), w: 0)
            ]).cropped(to: extent)
        }

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
    static func diagnosticSample(red: Double, green: Double, blue: Double, inputAlpha: Double = 1, settings: UltraKeySettings) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let sample = Evaluator(settings: settings).sample(red: red, green: green, blue: blue)
        let alpha = sample.alpha * clamp(inputAlpha)
        switch settings.output {
        case .composite: return (sample.red, sample.green, sample.blue, alpha)
        case .alpha: return (alpha, alpha, alpha, 1)
        case .color: return (clamp(settings.keyRed) * (1 - alpha), clamp(settings.keyGreen) * (1 - alpha), clamp(settings.keyBlue) * (1 - alpha), 1)
        }
    }

    private enum CubePurpose: String { case matte, foreground }

    private static func cubeData(for settings: UltraKeySettings, purpose: CubePurpose) -> Data {
        let key = (purpose.rawValue + "|" + cacheKey(settings)) as NSString
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
                    switch purpose {
                    case .matte: values += [Float(sample.alpha), Float(sample.alpha), Float(sample.alpha), 1]
                    case .foreground: values += [Float(sample.red), Float(sample.green), Float(sample.blue), 1]
                    }
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
        // Spatial cleanup, AI blending, diagnostic mode and correction run
        // after the cube; changing those does not rebuild 32³ lookup tables.
        let values: [Double] = [s.keyRed, s.keyGreen, s.keyBlue, s.transparency, s.highlight, s.shadow, s.tolerance, s.pedestal, s.soften, s.matteContrast, s.midpoint, s.desaturate, s.spillRange, s.spill, s.luma]
        return values.map { String(format: "%.4f", clamp($0)) }.joined(separator: "|")
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
            threshold = 0.025 + clamp(settings.tolerance) * 0.42 + clamp(settings.transparency) * 0.10 + clamp(settings.pedestal) * 0.10
            // A small intrinsic transition prevents a binary, aliased matte.
            // Soften adds a bounded chroma transition as well as spatial blur.
            feather = 0.018 + clamp(settings.soften) * 0.14
            matteScale = 1 + clamp(settings.matteContrast) * 4
            midpoint = clamp(settings.midpoint)
        }

        func sample(red: Double, green: Double, blue: Double) -> (red: Double, green: Double, blue: Double, alpha: Double) {
            var rgb = [clamp(red), clamp(green), clamp(blue)]
            let total = max(0.0001, rgb.reduce(0, +))
            let chroma = rgb.map { $0 / total }
            let distance = sqrt(zip(chroma, keyChroma).reduce(0) { $0 + pow($1.0 - $1.1, 2) })
            var alpha = smoothstep(threshold, threshold + feather, distance)
            let luminance = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
            let edge = alpha * (1 - alpha)
            alpha += edge * (max(0, luminance - 0.5) * clamp(settings.highlight) + max(0, 0.5 - luminance) * clamp(settings.shadow))
            alpha = clamp((alpha - midpoint) * matteScale + midpoint)

            let otherMaximum = rgb.enumerated().filter { $0.offset != dominantKeyChannel }.map(\.element).max() ?? 0
            let dominance = max(0, rgb[dominantKeyChannel] - otherMaximum)
            // Unlike the previous (1-alpha)-only suppression, this also
            // reaches fully opaque green-tinted hair/edges near the key hue.
            // Warm skin and neutral pixels have no key-channel dominance.
            let affinity = 1 - smoothstep(threshold + feather, threshold + feather + 0.12 + clamp(settings.spillRange) * 0.48, distance)
            let spillWeight = clamp(max(1 - alpha, affinity * 0.85) * clamp(settings.spill) * (0.7 + clamp(settings.spillRange)))
            let originalLuma = luminance
            rgb[dominantKeyChannel] = max(0, rgb[dominantKeyChannel] - dominance * spillWeight)
            let correctedLuma = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
            let restoredLuma = correctedLuma + (originalLuma - correctedLuma) * clamp(settings.luma)
            let desaturation = clamp(settings.desaturate) * spillWeight
            rgb = rgb.map { clamp(($0 + (restoredLuma - correctedLuma)) * (1 - desaturation) + restoredLuma * desaturation) }

            return (rgb[0], rgb[1], rgb[2], alpha)
        }
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = clamp((value - edge0) / max(0.0001, edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    private static func clamp(_ value: Double, _ minimum: Double = 0, _ maximum: Double = 1) -> Double {
        value.isFinite ? min(maximum, max(minimum, value)) : minimum
    }
}

private extension CGRect {
    var isFinite: Bool { origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite }
}
