import Cocoa
import AVFoundation
import CoreImage

/// Small immutable render jobs keep decoding and SceneKit snapshots off the UI
/// thread. A serial queue bounds GPU/decoder work across collaborating devices.
final class SharePreviewRenderer {
    enum Source { case clip(TimelineClip), scene(NetVistaSceneDocument) }
    private let queue = DispatchQueue(label: "NetVista.Share.Preview", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])

    func render(_ source: Source, time: Double, completion: @escaping (Data?) -> Void) {
        queue.async { [self] in
            let result: Data? = autoreleasepool {
                switch source {
                case .clip(let clip):
                    let asset = AVURLAsset(url: clip.url)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 960, height: 540)
                    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
                    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
                    let duration = clip.outPoint > clip.inPoint ? clip.outPoint - clip.inPoint : asset.duration.seconds - clip.inPoint
                    let local = min(max(0, time), max(0, duration - 1 / 30.0))
                    guard let frame = try? generator.copyCGImage(at: CMTime(seconds: clip.inPoint + local, preferredTimescale: 600), actualTime: nil) else { return nil }
                    let graded = NativeTimelineVisualPipeline.applyGrade(to: CIImage(cgImage: frame), clip: clip, timelineTime: clip.timelineStart + local)
                    return context.jpegRepresentation(of: graded, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.72])
                case .scene(let document):
                    return SceneSharePreviewRenderer.jpeg(document: document, time: time)
                }
            }
            completion(result)
        }
    }
}
