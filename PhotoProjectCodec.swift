import Foundation

/// Exact existing NetVista Photo Project v1/v2 schema. Keep field names and
/// optional embedded pixels/extras for backwards-compatible desktop/mobile reuse.
struct PhotoProjectAdjustmentData: Codable {
    let exposure: Double
    let brightness: Double
    let contrast: Double
    let saturation: Double
    let vibrance: Double
    let highlights: Double
    let shadows: Double
    let temperature: Double
    let tint: Double
    let sharpen: Double
    let blur: Double
    let sepia: Double
    let vignette: Double
    let mirrored: Bool

    init(_ value: PhotoAdjustments) {
        exposure = value.exposure; brightness = value.brightness; contrast = value.contrast; saturation = value.saturation; vibrance = value.vibrance
        highlights = value.highlights; shadows = value.shadows; temperature = value.temperature; tint = value.tint; sharpen = value.sharpen
        blur = value.blur; sepia = value.sepia; vignette = value.vignette; mirrored = value.mirrored
    }

    var adjustments: PhotoAdjustments {
        var value = PhotoAdjustments()
        value.exposure = exposure; value.brightness = brightness; value.contrast = contrast; value.saturation = saturation; value.vibrance = vibrance
        value.highlights = highlights; value.shadows = shadows; value.temperature = temperature; value.tint = tint; value.sharpen = sharpen
        value.blur = blur; value.sepia = sepia; value.vignette = vignette; value.mirrored = mirrored
        return value
    }
}

struct PhotoProjectLayerData: Codable {
    let id: UUID
    let name: String
    let sourcePath: String
    let isVisible: Bool
    let isLocked: Bool
    let opacity: Double
    let blendMode: String
    let positionX: Double
    let positionY: Double
    let scale: Double
    let rotation: Double
    let adjustments: PhotoProjectAdjustmentData
    var pixels: Data? = nil
    var extras: PhotoLayerExtras? = nil
}

struct PhotoProjectFile: Codable {
    let format: String
    let version: Int
    let canvasWidth: Double
    let canvasHeight: Double
    let selectedLayerID: UUID?
    let layers: [PhotoProjectLayerData]
    var dpi: Double? = nil
}
