import Foundation
import CoreImage
import CoreGraphics
#if canImport(AppKit)
import AppKit
typealias PhotoDocumentThumbnail = NSImage
#else
import UIKit
typealias PhotoDocumentThumbnail = UIImage
#endif

/// Full photo document state shared by the native Mac and mobile engines.
/// Thumbnails are a platform display cache only; the project codec never saves them.
struct PhotoAdjustments {
    var exposure = 0.0
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var vibrance = 0.0
    var highlights = 1.0
    var shadows = 0.0
    var temperature = 6500.0
    var tint = 0.0
    var sharpen = 0.0
    var blur = 0.0
    var sepia = 0.0
    var vignette = 0.0
    var mirrored = false
}

struct PhotoLayerExtras: Codable {
    var groupID: UUID? = nil
    var isGroup = false
    var isAdjustment = false
    var maskPNG: Data? = nil
    var skew = 0.0
    var hue = 0.0
    var black = 0.0
    var white = 1.0
    var midtone = 0.5
    var curveShadows = 0.25
    var curveHighlights = 0.75
    var noise = 0.0
    var text: String? = nil
    var fontName: String? = nil
    var fontSize: Double? = nil
    var textColor: [Double]? = nil
}

enum PhotoBlendMode: String, CaseIterable {
    case normal = "Normal"
    case multiply = "Multiply"
    case screen = "Screen"
    case overlay = "Overlay"
    case softLight = "Soft Light"
    case darken = "Darken"
    case lighten = "Lighten"
    case colorDodge = "Color Dodge"

    var filterName: String {
        switch self {
        case .normal: return "CISourceOverCompositing"
        case .multiply: return "CIMultiplyBlendMode"
        case .screen: return "CIScreenBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        case .darken: return "CIDarkenBlendMode"
        case .lighten: return "CILightenBlendMode"
        case .colorDodge: return "CIColorDodgeBlendMode"
        }
    }
}

final class PhotoLayer {
    let id: UUID
    var name: String
    let sourceURL: URL?
    var sourceImage: CIImage
    var thumbnail: PhotoDocumentThumbnail?
    var isVisible = true
    var isLocked = false
    var opacity = 1.0
    var blendMode = PhotoBlendMode.normal
    var position = CGPoint.zero
    var scale = 1.0
    var rotation = 0.0
    var adjustments = PhotoAdjustments()
    var extras = PhotoLayerExtras()
    var maskPreview: CIImage?

    init(id: UUID = UUID(), name: String, sourceURL: URL?, sourceImage: CIImage, thumbnail: PhotoDocumentThumbnail?) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.sourceImage = sourceImage
        self.thumbnail = thumbnail
    }
}

struct PhotoLayerSnapshot {
    let id: UUID
    let name: String
    let sourceURL: URL?
    let sourceImage: CIImage
    let thumbnail: PhotoDocumentThumbnail?
    let isVisible: Bool
    let isLocked: Bool
    let opacity: Double
    let blendMode: PhotoBlendMode
    let position: CGPoint
    let scale: Double
    let rotation: Double
    let adjustments: PhotoAdjustments
    var extras = PhotoLayerExtras()
    var maskPreview: CIImage? = nil
}

struct PhotoDocumentSnapshot {
    let layers: [PhotoLayerSnapshot]
    let selectedLayerID: UUID?
    let documentSize: CGSize
    let documentName: String
    var dpi = 72.0
    var projectURL: URL? = nil
}
