#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreImage

// The same layer engine checks can run in a native UIKit QA app. Neither the
// Mac controller nor an alternate mobile photo model is required to render.
#if !NETVISTA_SHARED_CORE_QA
@main
#endif
struct PhotoDocumentCoreChecks {
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    static let size = CGSize(width: 16, height: 16)
    static let extent = CGRect(origin: .zero, size: size)

    static func image(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue, alpha: alpha)).cropped(to: extent)
    }
    static func pixel(_ image: CIImage, x: Int = 8, y: Int = 8) -> [Float] {
        var value = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &value, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return value
    }
    static func near(_ actual: Float, _ expected: Float, _ message: String, tolerance: Float = 0.025) {
        precondition(actual.isFinite && abs(actual - expected) <= tolerance, "\(message): \(actual), expected \(expected)")
    }
    static func layer(_ source: CIImage, name: String = "Layer") -> PhotoLayer {
        PhotoLayer(name: name, sourceURL: nil, sourceImage: source, thumbnail: nil)
    }
    static func snapshot(_ layer: PhotoLayer) -> PhotoLayerSnapshot {
        PhotoLayerSnapshot(id: layer.id, name: layer.name, sourceURL: layer.sourceURL, sourceImage: layer.sourceImage,
                           thumbnail: layer.thumbnail, isVisible: layer.isVisible, isLocked: layer.isLocked,
                           opacity: layer.opacity, blendMode: layer.blendMode, position: layer.position,
                           scale: layer.scale, rotation: layer.rotation, adjustments: layer.adjustments,
                           extras: layer.extras, maskPreview: layer.maskPreview)
    }
    static func render(_ layers: [PhotoLayer], maxSide: CGFloat? = nil, bypass: Bool = false, opaque: Bool = false) -> CIImage {
        PhotoRenderEngine.composite(layers.map(snapshot), documentSize: size, maxSide: maxSide,
                                    bypassAdjustments: bypass, opaqueBackground: opaque)!
    }
    static func main() throws {
        precondition(pixel(image(1, 0, 0))[0] > 0.99, "Unavailable native graphics must not pass as black pixels")
        try layerPixels()
        try masksAndAdjustments()
        transformsAndFilters()
        try projectPreservation()
        print("PASS: shared full photo layers/order/blends/groups/visibility/opacity/masks/adjustment pixels, transforms/filters, immutable snapshots and unchanged v1/v2 embedded project fields")
    }

    static func layerPixels() throws {
        let red = layer(image(1, 0, 0)), blue = layer(image(0, 0, 1))
        near(pixel(render([red, blue]))[0], 1, "Topmost layer remains first")
        red.opacity = 0.5
        let faded = pixel(render([red, blue]))
        near(faded[0], 0.5, "Opacity blends foreground"); near(faded[2], 0.5, "Opacity reveals lower layer")
        red.isVisible = false
        near(pixel(render([red, blue]))[2], 1, "Hidden layer is omitted")
        red.isVisible = true; red.opacity = 0
        near(pixel(render([red, blue]))[2], 1, "Zero opacity is not clamped to visible")
        red.opacity = 1; red.isLocked = true
        near(pixel(render([red, blue]))[0], 1, "Locked layers still render")

        let gray = layer(image(0.25, 0.25, 0.25)), background = layer(image(0.5, 0.5, 0.5))
        for (mode, expected) in [(PhotoBlendMode.normal, Float(0.25)), (.multiply, 0.125), (.screen, 0.625), (.overlay, 0.25), (.darken, 0.25), (.lighten, 0.5)] {
            gray.blendMode = mode
            near(pixel(render([gray, background]))[0], expected, "Actual \(mode.rawValue) blend pixels")
        }
        for (mode, expected) in [(PhotoBlendMode.softLight, Float(0.375)), (.colorDodge, Float(2.0 / 3.0))] {
            gray.blendMode = mode
            let result = pixel(render([gray, background]))
            near(result[0], expected, "Actual \(mode.rawValue) blend pixels")
            near(result[3], 1, "\(mode.rawValue) retains opaque composite alpha")
        }

        let folder = layer(image(0, 0, 0, alpha: 0), name: "Folder")
        folder.extras.isGroup = true; folder.opacity = 0.5
        red.isLocked = false; red.extras.groupID = folder.id
        let grouped = pixel(render([folder, red, blue]))
        near(grouped[0], 0.5, "Folder opacity applies to children"); near(grouped[2], 0.5, "Folder result composites onto root")
        folder.isVisible = false
        near(pixel(render([folder, red, blue]))[2], 1, "Hidden folder hides its children")
        near(pixel(render([], opaque: true))[0], 1, "JPEG opaque background is white")
        near(pixel(render([]))[3], 0, "Empty transparent document stays transparent")
        let preview = render([blue], maxSide: 8)
        precondition(preview.extent.size == CGSize(width: 8, height: 8), "Bounded preview does not resize the authored document")
    }

    static func masksAndAdjustments() throws {
        let mask = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 16))
            .composited(over: CIImage(color: .black).cropped(to: extent))
        let red = layer(image(1, 0, 0)), blue = layer(image(0, 0, 1))
        let original = red.sourceImage
        red.extras.maskPNG = try PhotoPixels.png(mask, context: context)
        near(pixel(render([red, blue]), x: 3)[0], 1, "White mask reveals image")
        near(pixel(render([red, blue]), x: 12)[2], 1, "Black mask reveals lower layer")
        near(pixel(original, x: 12)[0], 1, "Masks never destroy source pixels")
        red.maskPreview = CIImage(color: .black).cropped(to: extent)
        near(pixel(render([red, blue]), x: 3)[2], 1, "Transient painted mask preview takes precedence")
        red.maskPreview = nil

        let adjustment = layer(image(0, 0, 0, alpha: 0)), base = layer(image(0.25, 0.25, 0.25))
        adjustment.extras.isAdjustment = true; adjustment.adjustments.brightness = 0.25
        adjustment.extras.maskPNG = try PhotoPixels.png(mask, context: context)
        near(pixel(render([adjustment, base]), x: 3)[0], 0.5, "Masked adjustment processes underlying layers")
        near(pixel(render([adjustment, base]), x: 12)[0], 0.25, "Adjustment mask preserves unselected area")
        adjustment.opacity = 0.5
        near(pixel(render([adjustment, base]), x: 3)[0], 0.375, "Adjustment opacity mixes original and processed result")
        near(pixel(render([adjustment, base], bypass: true), x: 3)[0], 0.25, "Bypass uses the same masks and layers without adjustments")

        let frozen = snapshot(red)
        red.sourceImage = image(0, 1, 0); red.opacity = 0; red.extras.maskPNG = nil
        near(pixel(frozen.sourceImage)[0], 1, "History image remains immutable")
        precondition(frozen.opacity == 1 && frozen.extras.maskPNG != nil, "History retains full layer values/mask data")
    }

    static func transformsAndFilters() {
        let red = layer(image(1, 0, 0)); red.scale = 0.5
        near(pixel(render([red]))[0], 1, "Scaled layer stays centered")
        near(pixel(render([red]), x: 1)[3], 0, "Scale exposes transparent border")
        red.position = CGPoint(x: 4, y: 0)
        near(pixel(render([red]), x: 5)[3], 0, "Position shifts a fitted layer")
        near(pixel(render([red]), x: 12)[0], 1, "Moved source remains visible")
        red.position = CGPoint(x: 0, y: 4)
        near(pixel(render([red]), x: 8, y: 12)[0], 1, "Positive document Y moves image upward")
        near(pixel(render([red]), x: 8, y: 5)[3], 0, "Upward position exposes lower canvas")
        red.position = .zero; red.extras.skew = 1
        near(pixel(render([red]), x: 5, y: 11)[3], 0, "Skew exposes the upper-left edge")
        near(pixel(render([red]), x: 12, y: 11)[0], 1, "Skew moves the upper surface right")
        let narrow = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 16))
        let turned = layer(narrow); turned.rotation = 90
        near(pixel(render([turned]), x: 2, y: 8)[0], 1, "Rotation turns a vertical source into a horizontal source")
        near(pixel(render([turned]), x: 8, y: 13)[3], 0, "Rotation leaves transparent canvas above the horizontal source")
        let transform = PhotoRenderEngine.layerTransform(size: size, position: CGPoint(x: 2, y: 3), scale: 2, rotation: 90, skew: 0.25, document: CGSize(width: 32, height: 32))
        let center = CGPoint(x: 8, y: 8).applying(transform)
        precondition(abs(center.x - 18) < 0.00001 && abs(center.y - 19) < 0.00001, "Skew/rotation transform preserves the requested center")
        let shifted = image(0.5, 0.5, 0.5).transformed(by: CGAffineTransform(translationX: 25, y: -11))
        precondition(PhotoRenderEngine.normalized(shifted).extent.origin == .zero)
        var adjustments = PhotoAdjustments(); adjustments.brightness = 0.25
        near(pixel(PhotoRenderEngine.apply(adjustments, to: image(0.25, 0.25, 0.25)))[0], 0.5, "Shared primary adjustment filter")
        var extras = PhotoLayerExtras(); extras.black = 0.25; extras.white = 0.75
        near(pixel(PhotoRenderEngine.applyExtras(extras, to: image(0.5, 0.5, 0.5)))[0], 0.5, "Existing levels transform is preserved")
        extras.black = 0; extras.white = 1; extras.midtone = 0.7
        let curved = pixel(PhotoRenderEngine.applyExtras(extras, to: image(0.5, 0.5, 0.5)))
        // CIToneCurve evaluates in its native perceptual space; a 0.5 linear
        // sample is not the curve's 0.5 control point. Compare against the
        // independent native filter rather than incorrectly assuming RGB 0.7.
        let curveReference = image(0.5, 0.5, 0.5).applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25),
            "inputPoint2": CIVector(x: 0.5, y: 0.7), "inputPoint3": CIVector(x: 0.75, y: 0.75), "inputPoint4": CIVector(x: 1, y: 1)])
        let reference = pixel(curveReference)
        for channel in 0..<3 { near(curved[channel], reference[channel], "Full tone curve matches actual native filter", tolerance: 0.002) }
        precondition(curved[0] > 0.51, "Tone curve must change pixels, not only survive as a saved property: \(curved)")
        let mirrored = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 16)).composited(over: image(0, 0, 1))
        adjustments = PhotoAdjustments(); adjustments.mirrored = true
        near(pixel(PhotoRenderEngine.apply(adjustments, to: mirrored), x: 3)[2], 1, "Mirror remains part of the full renderer")
    }

    static func projectPreservation() throws {
        let id = UUID(), folderID = UUID(), mask = try PhotoPixels.png(image(1, 1, 1), context: context)
        var adjustments = PhotoAdjustments()
        adjustments.exposure = 0.5; adjustments.brightness = 0.1; adjustments.contrast = 1.4; adjustments.saturation = 0.8
        adjustments.vibrance = 0.2; adjustments.highlights = 0.75; adjustments.shadows = 0.1; adjustments.temperature = 4800
        adjustments.tint = 13; adjustments.sharpen = 0.6; adjustments.blur = 2; adjustments.sepia = 0.2; adjustments.vignette = 0.3; adjustments.mirrored = true
        var extras = PhotoLayerExtras()
        extras.groupID = folderID; extras.isAdjustment = true; extras.maskPNG = mask; extras.skew = 0.2; extras.hue = 30
        extras.black = 0.1; extras.white = 0.9; extras.midtone = 0.55; extras.curveShadows = 0.3; extras.curveHighlights = 0.8; extras.noise = 0.2
        extras.text = "Editable text"; extras.fontName = "Helvetica"; extras.fontSize = 42; extras.textColor = [1, 0.2, 0.3, 0.75]
        let saved = PhotoProjectLayerData(id: id, name: "All layer fields", sourcePath: "/legacy/source.png", isVisible: false, isLocked: true,
                                         opacity: 0.6, blendMode: PhotoBlendMode.overlay.rawValue, positionX: 12, positionY: -4, scale: 1.5,
                                         rotation: 27, adjustments: PhotoProjectAdjustmentData(adjustments), pixels: mask, extras: extras)
        let file = PhotoProjectFile(format: "NetVista Photo Project", version: 2, canvasWidth: 16, canvasHeight: 16, selectedLayerID: id, layers: [saved], dpi: 300)
        let encoded = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(PhotoProjectFile.self, from: encoded)
        let reencoded = try JSONEncoder().encode(decoded)
        let originalJSON = try JSONSerialization.jsonObject(with: encoded) as! NSDictionary
        let restoredJSON = try JSONSerialization.jsonObject(with: reencoded) as! NSDictionary
        precondition(originalJSON == restoredJSON, "No persistent layer/adjustment/extras/schema field may be dropped")
        precondition(decoded.layers[0].pixels == mask && decoded.layers[0].extras?.maskPNG == mask && decoded.layers[0].extras?.text == "Editable text")
        near(pixel(CIImage(data: decoded.layers[0].pixels!)!)[0], 1, "Saved embedded v2 layer PNG decodes to actual pixels")
        near(pixel(CIImage(data: decoded.layers[0].extras!.maskPNG!)!)[0], 1, "Saved embedded v2 mask PNG decodes to actual pixels")
        precondition(decoded.layers[0].adjustments.adjustments.temperature == 4800 && decoded.layers[0].adjustments.adjustments.mirrored)
        precondition(decoded.selectedLayerID == id && decoded.dpi == 300 && decoded.layers[0].sourcePath == "/legacy/source.png")
        let serializedLayer = (originalJSON["layers"] as! [[String: Any]])[0]
        precondition(serializedLayer["thumbnail"] == nil && serializedLayer["maskPreview"] == nil, "Transient UI caches must not become project fields")

        var legacy = originalJSON as! [String: Any]; legacy["version"] = 1; legacy.removeValue(forKey: "dpi")
        var legacyLayer = serializedLayer; legacyLayer.removeValue(forKey: "pixels"); legacyLayer.removeValue(forKey: "extras")
        legacy["layers"] = [legacyLayer]
        let old = try JSONDecoder().decode(PhotoProjectFile.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(old.version == 1 && old.dpi == nil && old.layers[0].pixels == nil && old.layers[0].extras == nil)
        precondition(old.layers[0].sourcePath == "/legacy/source.png" && old.layers[0].isLocked && old.layers[0].blendMode == "Overlay")
        precondition(old.layers[0].adjustments.adjustments.exposure == 0.5 && old.layers[0].adjustments.adjustments.blur == 2, "Legacy linked-source projects retain complete saved settings")
    }
}
