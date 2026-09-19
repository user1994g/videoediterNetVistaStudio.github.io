import Foundation
import CoreImage
import CoreGraphics

/// A point in a normalised (0...1) grading curve.  Curves are deliberately
/// data-only so they can be saved in a project, copied between clips, and
/// exported to a LUT without depending on AppKit controls.
struct GradeCurvePoint: Codable, Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

struct GradeCurve: Codable, Equatable {
    var points: [GradeCurvePoint]

    init(points: [GradeCurvePoint] = GradeCurve.identityPoints) {
        self.points = GradeCurve.sanitized(points)
    }

    static let identityPoints = [GradeCurvePoint(x: 0, y: 0), GradeCurvePoint(x: 1, y: 1)]
    static let identity = GradeCurve(points: identityPoints)

    static func sanitized(_ points: [GradeCurvePoint]) -> [GradeCurvePoint] {
        var valid: [GradeCurvePoint] = []
        valid.reserveCapacity(points.count)
        for point in points where point.x.isFinite && point.y.isFinite {
            valid.append(GradeCurvePoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y))))
        }
        valid.sort { left, right in
            if left.x == right.x { return left.y < right.y }
            return left.x < right.x
        }
        var result: [GradeCurvePoint] = []
        for point in valid {
            if let index = result.firstIndex(where: { abs($0.x - point.x) < 0.000001 }) {
                result[index] = point
            } else {
                result.append(point)
            }
        }
        if result.count < 2 { return identityPoints }
        if result.first!.x > 0 { result.insert(GradeCurvePoint(x: 0, y: result.first!.y), at: 0) }
        if result.last!.x < 1 { result.append(GradeCurvePoint(x: 1, y: result.last!.y)) }
        return result
    }

    func value(at x: Double) -> Double {
        let input = min(1, max(0, x))
        let values = GradeCurve.sanitized(points)
        guard let first = values.first, let last = values.last else { return input }
        if input <= first.x { return first.y }
        if input >= last.x { return last.y }
        for index in 1..<values.count where input <= values[index].x {
            let a = values[index - 1], b = values[index]
            let span = max(0.000001, b.x - a.x)
            let t = (input - a.x) / span
            // A smoothstep gives hand-placed points a pleasant, film-editor
            // style curve while remaining deterministic for export.
            let smooth = t * t * (3 - 2 * t)
            return a.y + (b.y - a.y) * smooth
        }
        return input
    }
}

struct GradeCurves: Codable, Equatable {
    var master: GradeCurve = .identity
    var red: GradeCurve = .identity
    var green: GradeCurve = .identity
    var blue: GradeCurve = .identity
    var hueVsHue: GradeCurve = .identity
    var hueVsSat: GradeCurve = .identity
    var hueVsLum: GradeCurve = .identity
    var lumaVsSat: GradeCurve = .identity

    init() {}
}

/// Secondary isolation controls. Hue is expressed as degrees and wraps at
/// 360; the remaining ranges are normalised fractions.
struct HSLQualifier: Codable, Equatable {
    var enabled = false
    var inverted = false
    var hueCenter = 60.0
    var hueWidth = 60.0
    var saturationMin = 0.0
    var saturationMax = 1.0
    var luminanceMin = 0.0
    var luminanceMax = 1.0
    var softness = 0.18

    func normalised() -> HSLQualifier {
        var copy = self
        copy.hueCenter = hueCenter.isFinite ? hueCenter.truncatingRemainder(dividingBy: 360) : 60
        if copy.hueCenter < 0 { copy.hueCenter += 360 }
        copy.hueWidth = min(180, max(0.5, hueWidth.isFinite ? hueWidth : 60))
        copy.saturationMin = min(1, max(0, saturationMin.isFinite ? saturationMin : 0))
        copy.saturationMax = min(1, max(copy.saturationMin, saturationMax.isFinite ? saturationMax : 1))
        copy.luminanceMin = min(1, max(0, luminanceMin.isFinite ? luminanceMin : 0))
        copy.luminanceMax = min(1, max(copy.luminanceMin, luminanceMax.isFinite ? luminanceMax : 1))
        copy.softness = min(1, max(0, softness.isFinite ? softness : 0.18))
        return copy
    }
}

/// One non-destructive grade node. Nodes are evaluated in list order and the
/// node list is independent from the legacy one-click controls for backwards
/// compatibility with existing Beta projects.
struct GradeNode: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Grade 1"
    var enabled = true
    var mix = 1.0
    var exposure = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var hueShift = 0.0
    var lift = ColorWheelAdjustment()
    var gamma = ColorWheelAdjustment()
    var gain = ColorWheelAdjustment()
    var curves = GradeCurves()
    var qualifier = HSLQualifier()

    init(id: UUID = UUID(), name: String = "Grade 1") {
        self.id = id
        self.name = name
    }

    func normalised() -> GradeNode {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Grade" : name
        copy.mix = min(1, max(0, mix.isFinite ? mix : 1))
        copy.exposure = min(8, max(-8, exposure.isFinite ? exposure : 0))
        copy.contrast = min(4, max(0, contrast.isFinite ? contrast : 1))
        copy.saturation = min(4, max(0, saturation.isFinite ? saturation : 1))
        copy.hueShift = hueShift.isFinite ? hueShift : 0
        copy.qualifier = qualifier.normalised()
        return copy
    }
}

enum GradeCreativeLook: String, CaseIterable {
    case bleach, neon, tealOrange, monochrome, sunset

    var title: String {
        switch self {
        case .bleach: return "Bleach bypass"
        case .neon: return "Neon night"
        case .tealOrange: return "Teal & orange"
        case .monochrome: return "Silver monochrome"
        case .sunset: return "Warm sunset"
        }
    }

    func node() -> GradeNode {
        var result = GradeNode(name: title)
        switch self {
        case .bleach:
            result.contrast = 1.35; result.saturation = 0.58; result.exposure = 0.12
            result.lift = ColorWheelAdjustment(red: 0.015, green: 0.02, blue: 0.03)
        case .neon:
            result.contrast = 1.18; result.saturation = 1.55; result.hueShift = 8
            result.gain = ColorWheelAdjustment(red: 0.035, green: -0.01, blue: 0.05)
        case .tealOrange:
            result.saturation = 1.18
            result.lift = ColorWheelAdjustment(red: -0.02, green: 0.02, blue: 0.06)
            result.gain = ColorWheelAdjustment(red: 0.06, green: 0.025, blue: -0.025)
        case .monochrome:
            result.saturation = 0; result.contrast = 1.12
            result.gamma = ColorWheelAdjustment(red: 0.01, green: 0.01, blue: 0.01)
        case .sunset:
            result.exposure = 0.15; result.saturation = 1.12; result.hueShift = -4
            result.gain = ColorWheelAdjustment(red: 0.08, green: 0.025, blue: -0.035)
        }
        return result
    }
}

/// CPU-generated colour cubes keep the live preview and native export in the
/// same colour space. The cube is cached per node stack, so scrubbing a clip
/// does not rebuild it unless a control actually changed.
enum AdvancedGradeRuntime {
    private static let cacheLock = NSLock()
    private static var cubeCache: [String: Data] = [:]
    private static let cubeDimension = 17

    static func apply(_ nodes: [GradeNode], to image: CIImage) -> CIImage {
        let active = nodes.map { $0.normalised() }.filter { $0.enabled && $0.mix > 0.0001 }
        guard !active.isEmpty else { return image }
        let key = cacheKey(active)
        let data: Data
        cacheLock.lock()
        if let cached = cubeCache[key] {
            data = cached
            cacheLock.unlock()
        } else {
            cacheLock.unlock()
            let generated = makeCubeData(active, dimension: cubeDimension)
            cacheLock.lock(); cubeCache[key] = generated; cacheLock.unlock()
            data = generated
        }
        guard let filter = CIFilter(name: "CIColorCube") else { return image }
        filter.setValue(cubeDimension, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }

    static func exportCube(to url: URL, dimension requestedDimension: Int = 33, title: String = "NetVista Studio Grade", nodes: [GradeNode]) throws {
        let dimension = [17, 33, 65].min(by: { abs($0 - requestedDimension) < abs($1 - requestedDimension) }) ?? 33
        let active = nodes.map { $0.normalised() }.filter { $0.enabled && $0.mix > 0.0001 }
        let safeTitle = title.replacingOccurrences(of: "\"", with: "'")
        var text = "TITLE \"\(safeTitle)\"\nLUT_3D_SIZE \(dimension)\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n"
        text.reserveCapacity(dimension * dimension * dimension * 24)
        // .cube files conventionally vary blue slowest and red fastest.
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let rgb = SIMD3<Double>(Double(red) / Double(dimension - 1), Double(green) / Double(dimension - 1), Double(blue) / Double(dimension - 1))
                    let output = evaluate(rgb, nodes: active)
                    text += String(format: "%.6f %.6f %.6f\n", output.x, output.y, output.z)
                }
            }
        }
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func evaluate(_ input: SIMD3<Double>, node: GradeNode) -> SIMD3<Double> {
        let original = SIMD3<Double>(clamp(input.x), clamp(input.y), clamp(input.z))
        let n = node.normalised()
        guard qualifierWeight(original, qualifier: n.qualifier) > 0.0001 else { return original }
        var rgb = original
        let exposure = pow(2, n.exposure)
        rgb *= exposure
        rgb = SIMD3(repeating: 0.5) + (rgb - SIMD3(repeating: 0.5)) * n.contrast
        let hslBefore = rgbToHSL(rgb)
        var hsl = hslBefore
        hsl.s = clamp(hsl.s * n.saturation)
        hsl.h = wrapUnit(hsl.h + n.hueShift / 360)
        let hueOffset = n.curves.hueVsHue.value(at: hslBefore.h) - hslBefore.h
        hsl.h = wrapUnit(hsl.h + hueOffset)
        let hueSatScale = 1 + (n.curves.hueVsSat.value(at: hslBefore.h) - hslBefore.h) * 2
        hsl.s = clamp(hsl.s * hueSatScale)
        let hueLumOffset = (n.curves.hueVsLum.value(at: hslBefore.h) - hslBefore.h) * 0.35
        hsl.l = clamp(hsl.l + hueLumOffset)
        let lumaSatScale = 1 + (n.curves.lumaVsSat.value(at: hslBefore.l) - hslBefore.l) * 2
        hsl.s = clamp(hsl.s * lumaSatScale)
        rgb = hslToRGB(hsl)

        func wheel(_ value: Double, _ wheel: KeyPath<ColorWheelAdjustment, Double>) -> Double {
            n.lift[keyPath: wheel] * pow(1 - value, 2) + n.gamma[keyPath: wheel] * (4 * value * (1 - value)) + n.gain[keyPath: wheel] * value * value
        }
        rgb.x += wheel(rgb.x, \.red) + n.lift.master * pow(1 - rgb.x, 2) + n.gamma.master * (4 * rgb.x * (1 - rgb.x)) + n.gain.master * rgb.x * rgb.x
        rgb.y += wheel(rgb.y, \.green) + n.lift.master * pow(1 - rgb.y, 2) + n.gamma.master * (4 * rgb.y * (1 - rgb.y)) + n.gain.master * rgb.y * rgb.y
        rgb.z += wheel(rgb.z, \.blue) + n.lift.master * pow(1 - rgb.z, 2) + n.gamma.master * (4 * rgb.z * (1 - rgb.z)) + n.gain.master * rgb.z * rgb.z
        rgb.x = n.curves.red.value(at: clamp(rgb.x)); rgb.y = n.curves.green.value(at: clamp(rgb.y)); rgb.z = n.curves.blue.value(at: clamp(rgb.z))
        rgb.x = n.curves.master.value(at: clamp(rgb.x)); rgb.y = n.curves.master.value(at: clamp(rgb.y)); rgb.z = n.curves.master.value(at: clamp(rgb.z))
        rgb = SIMD3(clamp(rgb.x), clamp(rgb.y), clamp(rgb.z))
        let weight = qualifierWeight(original, qualifier: n.qualifier) * n.mix
        return original + (rgb - original) * weight
    }

    static func qualifierMatte(_ input: SIMD3<Double>, qualifier: HSLQualifier) -> Double {
        qualifierWeight(input, qualifier: qualifier.normalised())
    }

    private static func evaluate(_ input: SIMD3<Double>, nodes: [GradeNode]) -> SIMD3<Double> {
        nodes.reduce(input) { current, node in evaluate(current, node: node) }
    }

    private static func makeCubeData(_ nodes: [GradeNode], dimension: Int) -> Data {
        var data = Data(capacity: dimension * dimension * dimension * 4 * MemoryLayout<Float>.size)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let input = SIMD3<Double>(Double(red) / Double(dimension - 1), Double(green) / Double(dimension - 1), Double(blue) / Double(dimension - 1))
                    let value = evaluate(input, nodes: nodes)
                    var rgba: [Float] = [Float(value.x), Float(value.y), Float(value.z), 1]
                    rgba.withUnsafeBytes { data.append(contentsOf: $0) }
                }
            }
        }
        return data
    }

    private static func cacheKey(_ nodes: [GradeNode]) -> String {
        guard let data = try? JSONEncoder().encode(nodes) else { return UUID().uuidString }
        return data.base64EncodedString()
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value.isFinite ? value : 0)) }
    private static func wrapUnit(_ value: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: 1)
        return result < 0 ? result + 1 : result
    }

    private static func qualifierWeight(_ rgb: SIMD3<Double>, qualifier: HSLQualifier) -> Double {
        guard qualifier.enabled else { return 1 }
        let hsl = rgbToHSL(rgb)
        let hue = hsl.h * 360
        let difference = abs(((hue - qualifier.hueCenter + 540).truncatingRemainder(dividingBy: 360)) - 180)
        let hueEdge = max(0, qualifier.hueWidth * 0.5)
        let softness = max(0.001, qualifier.softness * max(1, hueEdge))
        let hueWeight = smoothRange(difference, inside: hueEdge, softness: softness)
        let satWeight = smoothRange(hsl.s, inside: qualifier.saturationMin...qualifier.saturationMax, softness: qualifier.softness)
        let lumWeight = smoothRange(hsl.l, inside: qualifier.luminanceMin...qualifier.luminanceMax, softness: qualifier.softness)
        let result = hueWeight * satWeight * lumWeight
        return qualifier.inverted ? 1 - result : result
    }

    private static func smoothRange(_ value: Double, inside range: ClosedRange<Double>, softness: Double) -> Double {
        if range.contains(value) { return 1 }
        let distance = value < range.lowerBound ? range.lowerBound - value : value - range.upperBound
        return clamp(1 - distance / max(0.001, softness))
    }

    private static func smoothRange(_ value: Double, inside centre: Double, softness: Double) -> Double {
        if value <= centre { return 1 }
        return clamp(1 - (value - centre) / max(0.001, softness))
    }

    private struct HSL { var h: Double; var s: Double; var l: Double }
    private static func rgbToHSL(_ rgb: SIMD3<Double>) -> HSL {
        let r = clamp(rgb.x), g = clamp(rgb.y), b = clamp(rgb.z)
        let maxValue = max(r, max(g, b)), minValue = min(r, min(g, b)), delta = maxValue - minValue
        let l = (maxValue + minValue) / 2
        guard delta > 0.000001 else { return HSL(h: 0, s: 0, l: l) }
        let s = delta / max(0.000001, 1 - abs(2 * l - 1))
        var h: Double
        if maxValue == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxValue == g { h = (b - r) / delta + 2 }
        else { h = (r - g) / delta + 4 }
        h /= 6
        if h < 0 { h += 1 }
        return HSL(h: h, s: clamp(s), l: l)
    }

    private static func hslToRGB(_ hsl: HSL) -> SIMD3<Double> {
        let h = wrapUnit(hsl.h), s = clamp(hsl.s), l = clamp(hsl.l)
        guard s > 0.000001 else { return SIMD3(repeating: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t: Double) -> Double {
            var value = wrapUnit(t)
            if value < 1 / 6 { return p + (q - p) * 6 * value }
            if value < 1 / 2 { return q }
            if value < 2 / 3 { return p + (q - p) * (2 / 3 - value) * 6 }
            return p
        }
        return SIMD3(clamp(hue(h + 1 / 3)), clamp(hue(h)), clamp(hue(h - 1 / 3)))
    }
}
