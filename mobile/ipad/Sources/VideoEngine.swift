import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo

struct MobileSequence {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let instructions: [MobileCompositionInstruction]

    func updateEffects(id: UUID, effects: MobileClipEffects) {
        for instruction in instructions where instruction.clipID == id { instruction.update(effects) }
    }
}

final class MobileCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    var requiredSourceTrackIDs: [NSValue]? { [NSNumber(value: sourceTrackID)] }
    let sourceTrackID: CMPersistentTrackID
    let clipID: UUID
    let fitTransform: CGAffineTransform
    let sourceHeight: CGFloat
    let usesLivePreview: Bool
    private let lock = NSLock()
    private var value: MobileClipEffects
    var effects: MobileClipEffects { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ effects: MobileClipEffects) { lock.lock(); value = effects; lock.unlock() }
    init(range: CMTimeRange, track: CMPersistentTrackID, clip: MobileClip, transform: CGAffineTransform, sourceHeight: CGFloat,
         livePreview: Bool = false) {
        timeRange = range; sourceTrackID = track; clipID = clip.id; fitTransform = transform
        self.sourceHeight = sourceHeight; usesLivePreview = livePreview; value = clip.effects; super.init()
    }
}

/// Shared Core Image renderer: the player and exporter execute the same fitted
/// source transform, user motion, opacity and colour settings. No screenshot-only
/// transforms or filters are applied to the UIKit video surface.
final class MobileVideoCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [Int(kCVPixelFormatType_32BGRA)],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
         kCVPixelBufferMetalCompatibilityKey as String: true,
         kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    }
    // Use the same linear-light Core Image working space as the macOS renderer.
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let renderQueue = DispatchQueue(label: "NetVista.Mobile.Compositor", qos: .userInitiated)
    private let stateLock = NSLock()
    private var cancellationGeneration = 0
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        stateLock.lock(); let ticket = cancellationGeneration; stateLock.unlock()
        renderQueue.async { [weak self] in
            guard let self, !self.cancelled(ticket) else { request.finishCancelledRequest(); return }
            self.render(request, ticket: ticket)
        }
    }
    private func render(_ request: AVAsynchronousVideoCompositionRequest, ticket: Int) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? MobileCompositionInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: MobileProjectError.noVideo); return
            }
            let rect = CGRect(origin: .zero, size: request.renderContext.size)
            guard let source = request.sourceFrame(byTrackID: instruction.sourceTrackID) else {
                // AVPlayer can temporarily omit the decoder buffer on a seek or
                // exact cut. Like the Mac renderer, preview recovers next frame;
                // final export still fails strictly rather than hiding lost video.
                if instruction.usesLivePreview {
                    context.render(CIImage(color: .black).cropped(to: rect), to: output, bounds: rect,
                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                    if cancelled(ticket) { request.finishCancelledRequest() } else { request.finish(withComposedVideoFrame: output) }
                } else { request.finish(with: MobileProjectError.noVideo) }
                return
            }
            let effects = instruction.effects
            let centre = CGAffineTransform(translationX: -rect.width / 2, y: -rect.height / 2)
                .concatenating(CGAffineTransform(scaleX: effects.scale, y: effects.scale))
                // Match the desktop/Android contract: one position unit is half
                // the canvas, positive Y is up, and positive rotation is CCW.
                // This intermediate transform is in AVFoundation's top-left
                // coordinates, so Y and rotation are inverted before the flip.
                .concatenating(CGAffineTransform(rotationAngle: -effects.rotation * .pi / 180))
                .concatenating(CGAffineTransform(translationX: rect.width / 2 * (1 + effects.positionX),
                                               y: rect.height / 2 * (1 - effects.positionY)))
            // Core Image is bottom-left based; AVFoundation/user coordinates are top-left based.
            let sourceFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: instruction.sourceHeight)
            let canvasFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.height)
            let transform = sourceFlip.concatenating(instruction.fitTransform).concatenating(centre).concatenating(canvasFlip)
            var image = CIImage(cvPixelBuffer: source)
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: effects.brightness,
                    kCIInputContrastKey: effects.contrast, kCIInputSaturationKey: effects.saturation])
                .transformed(by: transform)
            if effects.opacity != 1 {
                image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: effects.opacity)])
            }
            let background = CIImage(color: .black).cropped(to: rect)
            image = image.composited(over: background).cropped(to: rect)
            context.render(image, to: output, bounds: rect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            if cancelled(ticket) { request.finishCancelledRequest() } else { request.finish(withComposedVideoFrame: output) }
        }
    }
    func cancelAllPendingVideoCompositionRequests() {
        stateLock.lock(); cancellationGeneration += 1; stateLock.unlock()
        renderQueue.sync { }
    }
    private func cancelled(_ ticket: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return cancellationGeneration != ticket
    }
}

enum MobileVideoEngine {
    static func inspect(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty, duration.seconds.isFinite, duration.seconds >= 0.04 else {
            throw MobileProjectError.noVideo
        }
        return duration.seconds
    }

    static func sequence(_ project: MobileProject, media: URL, height: Int = 1080, fps: Int = 30,
                         livePreview: Bool = false) async throws -> MobileSequence {
        try project.validate()
        guard !project.clips.isEmpty else { throw MobileProjectError.noVideo }
        let composition = AVMutableComposition()
        // A completely empty audio track makes AVAssetExportSession reject some
        // otherwise valid silent movies. Create A1 only on the first real range.
        var audio: AVMutableCompositionTrack?
        let size = CGSize(width: CGFloat(height) * 16 / 9, height: CGFloat(height))
        var cursor = CMTime.zero
        var instructions: [MobileCompositionInstruction] = []
        for clip in project.clips {
            let url = media.appendingPathComponent(clip.file)
            guard FileManager.default.fileExists(atPath: url.path) else { throw MobileProjectError.missingMedia(clip.name) }
            let asset = AVURLAsset(url: url)
            let sources = try await asset.loadTracks(withMediaType: .video)
            guard let source = sources.first else { throw MobileProjectError.noVideo }
            // Match the Mac composition graph: each source owns its decoder
            // track. Inserting heterogeneous codecs/geometries into one track
            // can make AVPlayer reject a graph that an offline exporter accepts.
            guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MobileProjectError.noVideo
            }
            let range = CMTimeRange(start: CMTime(seconds: clip.inPoint, preferredTimescale: 600),
                                    duration: CMTime(seconds: clip.length, preferredTimescale: 600))
            try video.insertTimeRange(range, of: source, at: cursor)
            if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                // Missing or shorter audio is not allowed to prevent an otherwise valid video export.
                let soundRange = try await sound.load(.timeRange)
                let intersection = CMTimeRangeGetIntersection(range, otherRange: soundRange)
                if intersection.duration.seconds > 0 {
                    let destination = CMTimeAdd(cursor, CMTimeSubtract(intersection.start, range.start))
                    if audio == nil { audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                    guard let audio else { throw MobileProjectError.noVideo }
                    try audio.insertTimeRange(intersection, of: sound, at: destination)
                }
            }
            let natural = try await source.load(.naturalSize)
            let preferred = try await source.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: natural).applying(preferred)
            guard bounds.width > 0, bounds.height > 0 else { throw MobileProjectError.noVideo }
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            let transform = preferred
                .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (size.width - bounds.width * scale) / 2,
                                               y: (size.height - bounds.height * scale) / 2))
            let instruction = MobileCompositionInstruction(range: CMTimeRange(start: cursor, duration: range.duration),
                track: video.trackID, clip: clip, transform: transform, sourceHeight: natural.height, livePreview: livePreview)
            instructions.append(instruction)
            cursor = CMTimeAdd(cursor, range.duration)
        }
        let render = AVMutableVideoComposition()
        render.renderSize = size; render.frameDuration = CMTime(value: 1, timescale: Int32(fps))
        render.instructions = instructions
        render.customVideoCompositorClass = MobileVideoCompositor.self
        return MobileSequence(composition: composition, videoComposition: render, instructions: instructions)
    }

    static func exporter(_ sequence: MobileSequence, output: URL) throws -> AVAssetExportSession {
        guard let session = AVAssetExportSession(asset: sequence.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw MobileProjectError.noVideo
        }
        session.videoComposition = sequence.videoComposition
        session.outputURL = output; session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        return session
    }
}
