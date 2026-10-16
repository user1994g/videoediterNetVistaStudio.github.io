import Foundation
import CoreImage
import CoreGraphics

/// Single-source layer rendering for both the AppKit and UIKit photo workspaces.
/// Algorithms and filter order are the existing Mac renderer, not a mobile subset.
enum PhotoRenderEngine {
    static func composite(_ states: [PhotoLayerSnapshot], documentSize: CGSize, maxSide: CGFloat?, bypassAdjustments: Bool, opaqueBackground: Bool) -> CIImage? {
        guard documentSize.width > 0, documentSize.height > 0 else { return nil }
        let factor: CGFloat = maxSide.map { min(1, $0 / max(documentSize.width, documentSize.height)) } ?? 1
        let extent = CGRect(x: 0, y: 0, width: documentSize.width * factor, height: documentSize.height * factor)
        func level(_ parent: UUID?, depth: Int) -> CIImage {
            var result = CIImage(color: parent == nil && opaqueBackground ? CIColor.white : CIColor.clear).cropped(to: extent)
            guard depth < 3 else { return result }
            for state in states.reversed() where state.extras.groupID == parent && state.isVisible && state.opacity > 0 {
                let extra = state.extras
                var image: CIImage
                if extra.isGroup { image = level(state.id, depth: depth+1) }
                else if extra.isAdjustment { image = result }
                else { image = state.sourceImage }
                if !bypassAdjustments { image = applyExtras(extra, to: apply(state.adjustments, to: image)) }
                if !extra.isGroup && !extra.isAdjustment {
                    if let mask = state.maskPreview ?? extra.maskPNG.flatMap({ CIImage(data: $0) }) {
                        image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent), kCIInputMaskImageKey: mask])
                    }
                    let transform = layerTransform(size: state.sourceImage.extent.size, position: state.position, scale: state.scale, rotation: state.rotation, skew: extra.skew, document: documentSize)
                    image = image.transformed(by: transform).transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                }
                if extra.isAdjustment {
                    if state.blendMode != .normal { image = image.applyingFilter(state.blendMode.filterName,parameters:[kCIInputBackgroundImageKey:result]) }
                    var mask = (state.maskPreview ?? extra.maskPNG.flatMap { CIImage(data: $0) })?.transformed(by: CGAffineTransform(scaleX: factor, y: factor)) ?? CIImage(color: .white).cropped(to: extent)
                    mask = mask.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: state.opacity, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: state.opacity, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: state.opacity, w: 0)])
                    result = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask]).cropped(to: extent)
                } else {
                    image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: state.opacity)])
                    result = image.applyingFilter(state.blendMode.filterName, parameters: [kCIInputBackgroundImageKey: result]).cropped(to: extent)
                }
            }
            return result
        }
        return level(nil, depth: 0)
    }

    static func apply(_ settings: PhotoAdjustments, to source: CIImage) -> CIImage {
        var image = source
        if settings.mirrored { image = normalized(image.transformed(by: CGAffineTransform(translationX: image.extent.width, y: 0).scaledBy(x: -1, y: 1))) }
        image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
        image = image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: settings.brightness, kCIInputContrastKey: settings.contrast, kCIInputSaturationKey: settings.saturation])
        image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": settings.vibrance])
        image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": settings.highlights, "inputShadowAmount": settings.shadows])
        image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: settings.temperature, y: settings.tint)])
        if settings.sharpen > 0 { image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: settings.sharpen]) }
        if settings.blur > 0 { let extent = image.extent; image = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: settings.blur]).cropped(to: extent) }
        if settings.sepia > 0 { image = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: settings.sepia]) }
        if settings.vignette > 0 { image = image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: settings.vignette, kCIInputRadiusKey: min(image.extent.width, image.extent.height) * 0.45]) }
        return normalized(image)
    }
    static func normalized(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.minX != 0 || extent.minY != 0 else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    static func applyExtras(_ e: PhotoLayerExtras, to source: CIImage) -> CIImage {
        var image = source
        if e.hue != 0 { image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey:e.hue * .pi/180]) }
        if e.black != 0 || e.white != 1 {
            let gain = 1/max(0.01,e.white-e.black), bias = -e.black*gain
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputRVector":CIVector(x:gain,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:gain,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:gain,w:0),"inputBiasVector":CIVector(x:bias,y:bias,z:bias,w:0)])
        }
        if e.curveShadows != 0.25 || e.midtone != 0.5 || e.curveHighlights != 0.75 {
            image = image.applyingFilter("CIToneCurve", parameters: ["inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:0.25,y:e.curveShadows),"inputPoint2":CIVector(x:0.5,y:e.midtone),"inputPoint3":CIVector(x:0.75,y:e.curveHighlights),"inputPoint4":CIVector(x:1,y:1)])
        }
        if e.noise > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let grain = noise.cropped(to: source.extent).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey:0]).applyingFilter("CIColorMatrix", parameters: ["inputAVector":CIVector(x:0,y:0,z:0,w:e.noise)])
            image = grain.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey:image])
        }
        return image.cropped(to: source.extent)
    }
    static func layerTransform(size: CGSize, position: CGPoint, scale: Double, rotation: Double, skew: Double, document: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: -size.width/2, y: -size.height/2)
            .concatenating(CGAffineTransform(a: scale,b: 0,c: skew*scale,d: scale,tx: 0,ty: 0))
            .concatenating(CGAffineTransform(rotationAngle: rotation * .pi/180))
            .concatenating(CGAffineTransform(translationX: document.width/2+position.x,y: document.height/2+position.y))
    }
    /// Image pixels are mirrored before the layer mask is applied. Authoring
    /// tools need this full mapping; masks use layerTransform without the flip.
    static func pixelTransform(size: CGSize, position: CGPoint, scale: Double, rotation: Double, skew: Double, mirrored: Bool, document: CGSize) -> CGAffineTransform {
        let placement = layerTransform(size: size, position: position, scale: scale, rotation: rotation, skew: skew, document: document)
        guard mirrored else { return placement }
        return CGAffineTransform(translationX: size.width, y: 0).scaledBy(x: -1, y: 1).concatenating(placement)
    }
}
