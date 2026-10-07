import Foundation
import CoreImage
import CoreGraphics

/// Standalone synthetic regression checks. No downloaded model or footage is
/// required. Run with graphics access; an all-zero headless render is rejected.
@main struct UltraKeyChecks {
    static let context = CIContext(options: [.useSoftwareRenderer: false, .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    static let extent = CGRect(x: 0, y: 0, width: 64, height: 32)

    static func pixel(_ image: CIImage, _ x: Int = 12, _ y: Int = 12) -> [Float] {
        var result = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &result, rowBytes: 16,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return result
    }
    static func solid(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: a)).cropped(to: extent)
    }
    static func approximately(_ a: Float, _ b: Float, tolerance: Float = 0.015) -> Bool { abs(a - b) < tolerance }
    static func main() throws {
        let legacy = try JSONDecoder().decode(UltraKeySettings.self, from: Data("{\"enabled\":true,\"tolerance\":0.5}".utf8))
        precondition(legacy.enabled && !legacy.aiAssistEnabled && legacy.aiAssistStrength == 0.8, "Old projects must not turn on AI")
        var settings = UltraKeySettings(); settings.enabled = true
        settings.aiAssistEnabled = true; settings.aiAssistStrength = 0.72
        settings.choke = 0.1; settings.soften = 0.15; settings.output = .color
        let roundTrip = try JSONDecoder().decode(UltraKeySettings.self, from: JSONEncoder().encode(settings))
        precondition(roundTrip == settings)
        settings = legacy

        for rgb in [(0.0, 1.0, 0.0), (0.01, 0.09, 0.01), (0.10, 0.85, 0.12)] {
            let keyed = UltraKeyRuntime.diagnosticSample(red: rgb.0, green: rgb.1, blue: rgb.2, settings: settings)
            precondition(keyed.alpha < 0.01, "Uneven/shadow green screen must key out: \(keyed.alpha)")
        }
        for rgb in [(0.75, 0.44, 0.29), (0.0, 0.0, 1.0), (0.9, 0.9, 0.9), (0.02, 0.02, 0.02), (0.0, 0.0, 0.0)] {
            let keyed = UltraKeyRuntime.diagnosticSample(red: rgb.0, green: rgb.1, blue: rgb.2, settings: settings)
            precondition(keyed.alpha > 0.99, "Skin, blue and neutrals must stay solid")
        }
        var blue = settings; blue.keyGreen = 0; blue.keyBlue = 1
        precondition(UltraKeyRuntime.diagnosticSample(red: 0.01, green: 0.01, blue: 0.15, settings: blue).alpha < 0.01)
        precondition(UltraKeyRuntime.diagnosticSample(red: 0.75, green: 0.44, blue: 0.29, settings: blue).alpha > 0.99)
        let fringe = UltraKeyRuntime.diagnosticSample(red: 0.12, green: 0.38, blue: 0.12, settings: settings)
        precondition(fringe.alpha > 0.99 && fringe.green < 0.35, "Opaque spill near the screen hue must also be cleaned")
        let skin = UltraKeyRuntime.diagnosticSample(red: 0.75, green: 0.44, blue: 0.29, settings: settings)
        precondition(abs(skin.red - 0.75) < 1e-9 && abs(skin.green - 0.44) < 1e-9, "Warm skin must not be desaturated")
        var bad = settings; bad.tolerance = .nan; bad.soften = .infinity; bad.spill = -.infinity
        let safe = UltraKeyRuntime.diagnosticSample(red: .nan, green: .infinity, blue: -12, settings: bad)
        precondition([safe.red, safe.green, safe.blue, safe.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) })

        precondition(pixel(solid(1, 0, 0))[0] > 0.95, "Graphics context unavailable: do not mistake zero pixels for a passing keyer test")
        let transparentGreen = UltraKeyRuntime.apply(to: solid(0, 1, 0), settings: settings)
        let greenPixel = pixel(transparentGreen)
        precondition(greenPixel.allSatisfy { abs($0) < 0.005 }, "Removed green must have no unassociated RGB/halo: \(greenPixel)")
        let mixedEdge = pixel(UltraKeyRuntime.apply(to: solid(0.096, 0.6, 0.096), settings: settings))
        precondition(mixedEdge[3] > 0.01 && mixedEdge[3] < 0.99,
                     "The chroma transition must keep a fractional matte: \(mixedEdge)")
        precondition(mixedEdge.prefix(3).allSatisfy { $0 >= 0 && $0 <= mixedEdge[3] + 0.001 },
                     "Fractional edges must stay correctly premultiplied, without bright/green fringes: \(mixedEdge)")
        let halfSkin = UltraKeyRuntime.apply(to: solid(0.8, 0.2, 0.1, 0.5), settings: settings)
        let halfPixel = pixel(halfSkin)
        precondition(approximately(halfPixel[3], 0.5) && approximately(halfPixel[0], 0.4), "Source opacity must be retained exactly once, with premultiplied RGB: \(halfPixel)")
        let clearInput = UltraKeyRuntime.apply(to: solid(1, 0, 0, 0), settings: settings)
        precondition(pixel(clearInput).allSatisfy { abs($0) < 0.005 }, "Already-transparent pixels must not come back")
        var disabled = settings; disabled.enabled = false
        let disabledPixel = pixel(UltraKeyRuntime.apply(to: solid(0, 1, 0, 0.5), settings: disabled))
        precondition(approximately(disabledPixel[1], 0.5) && approximately(disabledPixel[3], 0.5), "Disabled keying must pass through")
        var diagnostic = settings; diagnostic.output = .alpha
        let mattePixel = pixel(UltraKeyRuntime.apply(to: solid(0.8, 0.2, 0.1, 0.5), settings: diagnostic))
        precondition(approximately(mattePixel[0], 0.5) && approximately(mattePixel[3], 1), "Alpha view must show source opacity: \(mattePixel)")
        let matteGreen = pixel(UltraKeyRuntime.apply(to: solid(0, 1, 0), settings: diagnostic))
        precondition(matteGreen[0] < 0.01 && matteGreen[3] > 0.99)
        diagnostic.output = .color
        let color = pixel(UltraKeyRuntime.apply(to: solid(0, 1, 0), settings: diagnostic))
        precondition(color[1] > 0.99 && color[0] < 0.01 && color[3] > 0.99)

        let patch = solid(0.75, 0.44, 0.29).cropped(to: CGRect(x: 20, y: 6, width: 24, height: 20)).composited(over: solid(0, 1, 0))
        let ordinary = UltraKeyRuntime.apply(to: patch, settings: settings)
        var cleanup = settings; cleanup.choke = 1
        let choked = UltraKeyRuntime.apply(to: patch, settings: cleanup)
        precondition(pixel(ordinary, 20, 15)[3] > 0.99 && pixel(choked, 20, 15)[3] < 0.01, "Choke must contract the actual silhouette")
        precondition(pixel(choked, 30, 15)[3] > 0.99, "Choke must preserve the foreground interior")
        cleanup = settings; cleanup.soften = 0.5
        let softened = UltraKeyRuntime.apply(to: patch, settings: cleanup)
        precondition(pixel(softened, 19, 15)[3] > 0.03 && pixel(softened, 20, 15)[3] < 0.99, "Soften must give a real spatial transition")
        precondition(softened.extent == extent && choked.extent == extent, "Cleanup must not expand video extent")

        // Person mask contains a green-clothed subject on a non-green set.
        let personRect = CGRect(x: 18, y: 4, width: 28, height: 24)
        let personMask = solid(1, 1, 1).cropped(to: personRect).composited(over: solid(0, 0, 0))
        let clothed = solid(0, 1, 0).cropped(to: personRect).composited(over: solid(0, 0, 1))
        var assisted = settings; assisted.aiAssistEnabled = true; assisted.aiAssistStrength = 1
        let assistedImage = UltraKeyRuntime.apply(to: clothed, settings: assisted, foregroundMask: personMask)
        let shirt = pixel(assistedImage, 30, 15)
        precondition(shirt[1] > 0.95 && shirt[3] > 0.99, "AI-protected green clothing must retain opacity and color: \(shirt)")
        precondition(pixel(assistedImage, 3, 15)[3] < 0.01, "Full-strength person assist removes non-green background")
        assisted.aiAssistStrength = 0
        let zero = UltraKeyRuntime.apply(to: clothed, settings: assisted, foregroundMask: personMask)
        precondition(pixel(zero, 30, 15)[3] < 0.01 && pixel(zero, 3, 15)[3] > 0.99, "AI zero strength is ordinary chroma key")
        assisted.aiAssistStrength = 1
        let fallback = UltraKeyRuntime.apply(to: clothed, settings: assisted)
        precondition(pixel(fallback, 30, 15)[3] < 0.01 && pixel(fallback, 3, 15)[3] > 0.99, "Missing model/mask must fall back safely")
        let badMask = personMask.cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        precondition(pixel(UltraKeyRuntime.apply(to: clothed, settings: assisted, foregroundMask: badMask), 3, 15)[3] > 0.99, "Misaligned masks must not erase the frame")
        print("PASS: legacy settings/AI migration, shadow green/blue keys, skin/neutral protection, opaque-edge spill, finite inputs, premultiplied edges, source alpha, output modes, spatial choke/soften, person-interior protection, mask strength and safe fallback")
    }
}
