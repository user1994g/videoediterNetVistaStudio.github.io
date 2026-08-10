import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import VideoToolbox

// MARK: - Public-facing export choices

/// Frame sizes offered by NetVista Studio's native delivery engine.
enum TimelineExportResolution: String, CaseIterable, Codable {
    case hd1080
    case ultraHD4K
    case ultraHD8K

    var title: String {
        switch self {
        case .hd1080: return "1080p HD"
        case .ultraHD4K: return "4K Ultra HD"
        case .ultraHD8K: return "8K Ultra HD"
        }
    }

    var dimensions: CGSize {
        switch self {
        case .hd1080: return CGSize(width: 1920, height: 1080)
        case .ultraHD4K: return CGSize(width: 3840, height: 2160)
        case .ultraHD8K: return CGSize(width: 7680, height: 4320)
        }
    }

    var recommendedVideoBitRate: Int {
        switch self {
        case .hd1080: return 16_000_000
        case .ultraHD4K: return 55_000_000
        case .ultraHD8K: return 140_000_000
        }
    }
}

enum TimelineExportContainer: String, CaseIterable, Codable {
    case mp4
    case mov

    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
    var avFileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

enum TimelineExportCodec: String, CaseIterable, Codable {
    case automatic
    case h264
    case hevc

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        }
    }

    fileprivate var avCodec: AVVideoCodecType? {
        switch self {
        case .automatic: return nil
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }

    fileprivate var coreMediaCodec: CMVideoCodecType? {
        switch self {
        case .automatic: return nil
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }
}

struct TimelineExportOptions: Codable, Equatable {
    var resolution: TimelineExportResolution = .hd1080
    var container: TimelineExportContainer = .mp4
    var codec: TimelineExportCodec = .automatic
    var frameRate: Int32 = 30
    var videoBitRate: Int? = nil
    var audioBitRate: Int = 256_000
    var includeAudio = true
    var allowCodecFallback = true
    var optimizeForStreaming = true

    var renderSize: CGSize { resolution.dimensions }
    var resolvedVideoBitRate: Int { videoBitRate ?? resolution.recommendedVideoBitRate }
}

struct TimelineExportProgress: Equatable {
    let fractionCompleted: Double
    let renderedSeconds: Double
    let totalSeconds: Double

    var percent: Int { Int((fractionCompleted * 100).rounded()) }
}

/// Resolves a clip's requested asset-time trim against the actual media track.
/// Real camera files frequently have audio at zero while video begins a few
/// frames later (or ends earlier). Using the container duration for both tracks
/// creates empty edits or failed inserts that appear as a black second clip.
struct NativeTimelineResolvedMediaRange {
    let sourceRange: CMTimeRange
    let timelineStart: Double
    let duration: Double
}

enum NativeTimelineMediaRangeResolver {
    static func resolve(
        clip: TimelineClip,
        sourceTrack: AVAssetTrack,
        assetDuration: Double
    ) -> NativeTimelineResolvedMediaRange? {
        let trackRange = sourceTrack.timeRange
        let trackStart = trackRange.start.seconds
        let trackEnd = CMTimeRangeGetEnd(trackRange).seconds
        guard trackStart.isFinite, trackEnd.isFinite, trackEnd > trackStart else { return nil }

        let requestedStart = clip.inPoint.isFinite ? max(0, clip.inPoint) : 0
        let fallbackEnd = assetDuration.isFinite && assetDuration > requestedStart ? assetDuration : trackEnd
        let requestedEnd = clip.outPoint.isFinite && clip.outPoint > requestedStart ? clip.outPoint : fallbackEnd
        let sourceStart = max(requestedStart, trackStart)
        let sourceEnd = min(requestedEnd, trackEnd)
        let resolvedDuration = sourceEnd - sourceStart
        guard resolvedDuration > (1.0 / 600.0) else { return nil }

        let requestedTimelineStart = clip.timelineStart.isFinite ? max(0, clip.timelineStart) : 0
        // Preserve the asset's empty lead-in rather than pulling a late video
        // track earlier than its matching audio track.
        let resolvedTimelineStart = requestedTimelineStart + max(0, sourceStart - requestedStart)
        return NativeTimelineResolvedMediaRange(
            sourceRange: CMTimeRange(
                start: CMTime(seconds: sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: resolvedDuration, preferredTimescale: 600)
            ),
            timelineStart: resolvedTimelineStart,
            duration: resolvedDuration
        )
    }
}

enum NativeTimelineExportError: LocalizedError {
    case emptyTimeline
    case noVideoClips
    case sourceCannotBeRead(String)
    case invalidClipRange(String)
    case codecUnavailable(TimelineExportCodec, TimelineExportResolution)
    case readerCouldNotStart(String)
    case writerCouldNotStart(String)
    case encodingFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyTimeline:
            return "The timeline is empty."
        case .noVideoClips:
            return "The timeline does not contain a video clip."
        case .sourceCannotBeRead(let name):
            return "NetVista Studio could not read the media for \(name)."
        case .invalidClipRange(let name):
            return "The in and out points for \(name) are invalid."
        case .codecUnavailable(let codec, let resolution):
            return "\(codec.title) is not available for \(resolution.title) on this Mac."
        case .readerCouldNotStart(let reason):
            return "The timeline reader could not start: \(reason)"
        case .writerCouldNotStart(let reason):
            return "The video writer could not start: \(reason)"
        case .encodingFailed(let reason):
            return "Export failed: \(reason)"
        case .cancelled:
            return "Export cancelled."
        }
    }
}

/// A lightweight handle retained by the UI while an export is active.
/// Calling cancel is thread-safe and completion is still delivered exactly once.
final class TimelineExportJob {
    private let lock = NSLock()
    private var cancellationHandler: (() -> Void)?
    private var retainedSession: AnyObject?
    private var cancelled = false
    private var completionDelivered = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        let action: (() -> Void)?
        lock.lock()
        guard !completionDelivered else { lock.unlock(); return }
        cancelled = true
        action = cancellationHandler
        lock.unlock()
        action?()
    }

    fileprivate func installCancellationHandler(_ handler: @escaping () -> Void) {
        let shouldCancel: Bool
        lock.lock()
        cancellationHandler = handler
        shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { handler() }
    }

    fileprivate func retainSession(_ session: AnyObject?) {
        lock.lock()
        retainedSession = session
        lock.unlock()
    }

    fileprivate func claimCompletion() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !completionDelivered else { return false }
        completionDelivered = true
        return true
    }

    /// Establishes one atomic boundary between a last-moment cancellation and
    /// a successful delivery. Once this succeeds, later Cancel clicks are no-ops.
    fileprivate func claimSuccessfulCompletion() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !completionDelivered else { return false }
        completionDelivered = true
        return true
    }
}

// MARK: - Native timeline exporter

/// Native AVFoundation exporter used by NetVista Studio's Delivery page.
///
/// Progress and completion callbacks are always dispatched to the main queue,
/// which means AppKit controls may be updated directly by callers.
enum NativeTimelineExportEngine {
    typealias ProgressHandler = (TimelineExportProgress) -> Void
    typealias CompletionHandler = (Result<URL, Error>) -> Void

    private static let preparationQueue = DispatchQueue(label: "NetVistaStudio.NativeExport.Prepare", qos: .userInitiated)

    /// Starts a non-blocking export and immediately returns a cancellable job.
    @discardableResult
    static func export(
        clips: [TimelineClip],
        to outputURL: URL,
        options: TimelineExportOptions = TimelineExportOptions(),
        progress: @escaping ProgressHandler,
        completion: @escaping CompletionHandler
    ) -> TimelineExportJob {
        let job = TimelineExportJob()
        preparationQueue.async {
            let stagingURL = stagingURL(for: outputURL, container: options.container)
            do {
                guard !job.isCancelled else { throw NativeTimelineExportError.cancelled }
                guard !clips.isEmpty else { throw NativeTimelineExportError.emptyTimeline }
                guard clips.contains(where: { $0.kind == .video }) else { throw NativeTimelineExportError.noVideoClips }

                let codec = try resolveCodec(for: options)
                let plan = try buildPlan(from: clips, options: options)
                guard !job.isCancelled else { throw NativeTimelineExportError.cancelled }

                let session = try NativeWriterSession(
                    plan: plan,
                    stagingURL: stagingURL,
                    destinationURL: outputURL,
                    options: options,
                    codec: codec,
                    job: job,
                    progress: progress
                ) { result in
                    job.retainSession(nil)
                    // A successful writer session has already claimed success
                    // atomically with the final destination commit. Failures
                    // still claim here to suppress preparation/cancel races.
                    if case .failure = result, !job.claimCompletion() { return }
                    DispatchQueue.main.async { completion(result) }
                }
                job.retainSession(session)
                job.installCancellationHandler { [weak session] in session?.cancel() }
                try session.start()
            } catch {
                job.retainSession(nil)
                try? FileManager.default.removeItem(at: stagingURL)
                guard job.claimCompletion() else { return }
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
        return job
    }

    private static func stagingURL(for destination: URL, container: TimelineExportContainer) -> URL {
        let base = destination.deletingPathExtension().lastPathComponent
        return destination.deletingLastPathComponent()
            .appendingPathComponent(".\(base).netvista-studio-\(UUID().uuidString)")
            .appendingPathExtension(container.fileExtension)
    }

    /// Uses VideoToolbox's hardware capability report. Software encoding may
    /// still be available when this returns false.
    static func hasHardwareEncoder(for codec: TimelineExportCodec) -> Bool {
        var rawList: CFArray?
        guard VTCopyVideoEncoderList(nil, &rawList) == noErr,
              let encoders = rawList as? [[String: Any]] else { return false }
        let requested = codec.coreMediaCodec
        return encoders.contains { encoder in
            guard let codecNumber = encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber,
                  let hardware = encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool,
                  hardware else { return false }
            let availableCodec = CMVideoCodecType(codecNumber.uint32Value)
            return requested == nil || requested == availableCodec
        }
    }

    /// Checks whether AVAssetWriter accepts the requested codec, dimensions and
    /// container before the user commits to a lengthy high-resolution export.
    static func canExport(
        codec: TimelineExportCodec,
        resolution: TimelineExportResolution,
        container: TimelineExportContainer
    ) -> Bool {
        guard codec != .automatic, let avCodec = codec.avCodec else { return true }
        guard videoToolboxHasEncoder(for: codec) else { return false }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("netvista-studio-codec-check-\(UUID().uuidString)")
            .appendingPathExtension(container.fileExtension)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let writer = try? AVAssetWriter(outputURL: temporaryURL, fileType: container.avFileType) else { return false }
        return writer.canApply(
            outputSettings: videoSettings(codec: avCodec, options: TimelineExportOptions(resolution: resolution, container: container, codec: codec)),
            forMediaType: .video
        )
    }

    private static func videoToolboxHasEncoder(for codec: TimelineExportCodec) -> Bool {
        guard let requested = codec.coreMediaCodec else { return true }
        var rawList: CFArray?
        guard VTCopyVideoEncoderList(nil, &rawList) == noErr,
              let encoders = rawList as? [[String: Any]] else { return false }
        return encoders.contains { encoder in
            guard let codecNumber = encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber else { return false }
            return CMVideoCodecType(codecNumber.uint32Value) == requested
        }
    }

    private static func resolveCodec(for options: TimelineExportOptions) throws -> AVVideoCodecType {
        let preferred: [TimelineExportCodec]
        switch options.codec {
        case .automatic:
            preferred = options.resolution == .ultraHD8K ? [.hevc, .h264] : [.h264, .hevc]
        case .h264:
            preferred = options.allowCodecFallback ? [.h264, .hevc] : [.h264]
        case .hevc:
            preferred = options.allowCodecFallback ? [.hevc, .h264] : [.hevc]
        }
        for codec in preferred where canExport(codec: codec, resolution: options.resolution, container: options.container) {
            if let value = codec.avCodec { return value }
        }
        throw NativeTimelineExportError.codecUnavailable(options.codec, options.resolution)
    }

    fileprivate static func videoSettings(codec: AVVideoCodecType, options: TimelineExportOptions) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: options.resolvedVideoBitRate,
            AVVideoExpectedSourceFrameRateKey: options.frameRate,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int(options.frameRate * 2)),
            AVVideoAllowFrameReorderingKey: true
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        } else if codec == .hevc {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(options.renderSize.width),
            AVVideoHeightKey: Int(options.renderSize.height),
            AVVideoCompressionPropertiesKey: compression
        ]
    }

    private static func buildPlan(from clips: [TimelineClip], options: TimelineExportOptions) throws -> NativeExportPlan {
        let composition = AVMutableComposition()
        var videoSources: [NativeVideoSource] = []
        var audioSources: [NativeAudioSource] = []
        var timelineDuration = 0.0

        let ordered = clips.enumerated().sorted { left, right in
            if left.element.timelineStart == right.element.timelineStart { return left.offset < right.offset }
            return left.element.timelineStart < right.element.timelineStart
        }.map(\.element)

        for clip in ordered {
            let asset = AVURLAsset(url: clip.url)
            let mediaType: AVMediaType = clip.kind == .video ? .video : .audio
            guard let sourceTrack = asset.tracks(withMediaType: mediaType).first else {
                throw NativeTimelineExportError.sourceCannotBeRead(clip.name)
            }
            let sourceLength = asset.duration.seconds
            guard let resolved = NativeTimelineMediaRangeResolver.resolve(
                clip: clip,
                sourceTrack: sourceTrack,
                assetDuration: sourceLength
            ) else {
                throw NativeTimelineExportError.invalidClipRange(clip.name)
            }
            guard let outputTrack = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NativeTimelineExportError.encodingFailed("A composition track could not be created for \(clip.name).")
            }
            do {
                try outputTrack.insertTimeRange(
                    resolved.sourceRange,
                    of: sourceTrack,
                    at: CMTime(seconds: resolved.timelineStart, preferredTimescale: 600)
                )
            } catch {
                composition.removeTrack(outputTrack)
                throw NativeTimelineExportError.sourceCannotBeRead(clip.name)
            }
            timelineDuration = max(timelineDuration, resolved.timelineStart + resolved.duration)
            if clip.kind == .video {
                videoSources.append(NativeVideoSource(clip: clip, compositionTrack: outputTrack, sourceTrack: sourceTrack, timelineStart: resolved.timelineStart, duration: resolved.duration))
            } else if options.includeAudio {
                audioSources.append(NativeAudioSource(clip: clip, compositionTrack: outputTrack, timelineStart: resolved.timelineStart, duration: resolved.duration))
            }
        }

        guard !videoSources.isEmpty else { throw NativeTimelineExportError.noVideoClips }
        let videoComposition = makeVideoComposition(sources: videoSources, duration: timelineDuration, options: options)
        let audioMix = options.includeAudio ? makeAudioMix(sources: audioSources) : nil
        return NativeExportPlan(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            duration: timelineDuration,
            hasAudio: options.includeAudio && !audioSources.isEmpty
        )
    }

    private static func makeVideoComposition(
        sources: [NativeVideoSource],
        duration: Double,
        options: TimelineExportOptions
    ) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = options.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: max(1, options.frameRate))
        videoComposition.renderScale = 1
        videoComposition.customVideoCompositorClass = NativeTimelineVideoCompositor.self

        let timelineTimescale: CMTimeScale = 600
        var boundaryTicks = [Int64(0), Int64((duration * Double(timelineTimescale)).rounded())]
        for source in sources {
            boundaryTicks.append(Int64((source.timelineStart * Double(timelineTimescale)).rounded()))
            boundaryTicks.append(Int64(((source.timelineStart + source.duration) * Double(timelineTimescale)).rounded()))
        }
        let finalTick = Int64((duration * Double(timelineTimescale)).rounded())
        let points = Array(Set(boundaryTicks.map { max(0, min(finalTick, $0)) })).sorted()
        var instructions: [AVVideoCompositionInstructionProtocol] = []

        for index in 0..<(max(0, points.count - 1)) {
            let startTick = points[index]
            let endTick = points[index + 1]
            guard endTick > startTick else { continue }
            let startTime = CMTime(value: startTick, timescale: timelineTimescale)
            let endTime = CMTime(value: endTick, timescale: timelineTimescale)
            let range = CMTimeRange(start: startTime, duration: CMTimeSubtract(endTime, startTime))
            let start = startTime.seconds
            let end = endTime.seconds
            let active = sources.filter {
                $0.timelineStart < end - (1.0 / 1200.0) && $0.timelineStart + $0.duration > start + (1.0 / 1200.0)
            }
            let layers = active.sorted {
                if $0.clip.track != $1.clip.track { return $0.clip.track > $1.clip.track }
                if $0.clip.timelineStart != $1.clip.timelineStart { return $0.clip.timelineStart > $1.clip.timelineStart }
                return $0.clip.id.uuidString > $1.clip.id.uuidString
            }.map { source in
                NativeTimelineLayerPlan(
                    clip: source.clip,
                    trackID: source.compositionTrack.trackID,
                    naturalSize: source.sourceTrack.naturalSize,
                    preferredTransform: source.sourceTrack.preferredTransform
                )
            }
            instructions.append(NativeTimelineVideoInstruction(timeRange: range, layers: layers, renderSize: options.renderSize))
        }
        videoComposition.instructions = instructions
        return videoComposition
    }

    private static func makeAudioMix(sources: [NativeAudioSource]) -> AVMutableAudioMix? {
        guard !sources.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = sources.map { source in
            let parameters = AVMutableAudioMixInputParameters(track: source.compositionTrack)
            var boundaries = [source.timelineStart, source.timelineStart + source.duration]
            if let channel = source.clip.animation.channels.first(where: { $0.property == .volume }) {
                boundaries.append(contentsOf: channel.keyframes
                    .map { source.clip.timelineStart + $0.time }
                    .filter { $0 > source.timelineStart && $0 < source.timelineStart + source.duration })
            }
            let audioTimescale: CMTimeScale = 600
            let points = Array(Set(boundaries.map { Int64(($0 * Double(audioTimescale)).rounded()) })).sorted()
            for index in 0..<(max(0, points.count - 1)) {
                let startTick = points[index]
                let endTick = points[index + 1]
                guard endTick > startTick else { continue }
                let startTime = CMTime(value: startTick, timescale: audioTimescale)
                let endTime = CMTime(value: endTick, timescale: audioTimescale)
                let range = CMTimeRange(start: startTime, duration: CMTimeSubtract(endTime, startTime))
                let start = startTime.seconds
                let end = endTime.seconds
                parameters.setVolumeRamp(
                    fromStartVolume: Float(max(0, source.clip.value(for: .volume, at: start))),
                    toEndVolume: Float(max(0, source.clip.value(for: .volume, at: end))),
                    timeRange: range
                )
            }
            return parameters
        }
        return mix
    }
}

// MARK: - Composition plan

private struct NativeVideoSource {
    let clip: TimelineClip
    let compositionTrack: AVMutableCompositionTrack
    let sourceTrack: AVAssetTrack
    let timelineStart: Double
    let duration: Double
}

private struct NativeAudioSource {
    let clip: TimelineClip
    let compositionTrack: AVMutableCompositionTrack
    let timelineStart: Double
    let duration: Double
}

private struct NativeExportPlan {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix?
    let duration: Double
    let hasAudio: Bool
}

/// Immutable source-layer data carried by every custom composition instruction.
/// Layers are stored foreground-first, matching AVFoundation's standard layer
/// instruction ordering.
struct NativeTimelineLayerPlan {
    let clip: TimelineClip
    let trackID: CMPersistentTrackID
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
}

/// Preview-only clip snapshots used while the Effects window is being scrubbed.
/// Export instructions never consult this store, so un-applied controls cannot
/// leak into a final render.
final class TimelineLiveEffectStore: @unchecked Sendable {
    static let shared = TimelineLiveEffectStore()
    private let lock = NSLock()
    private var clips: [UUID: TimelineClip] = [:]

    func replace(with updated: [TimelineClip]) {
        lock.lock(); clips = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) }); lock.unlock()
    }
    func clear() { lock.lock(); clips.removeAll(); lock.unlock() }
    func resolved(_ saved: TimelineClip) -> TimelineClip {
        lock.lock(); defer { lock.unlock() }; return clips[saved.id] ?? saved
    }
}

final class NativeTimelineVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [NativeTimelineLayerPlan]
    let renderSize: CGSize
    let usesLivePreviewOverrides: Bool

    init(timeRange: CMTimeRange, layers: [NativeTimelineLayerPlan], renderSize: CGSize, usesLivePreviewOverrides: Bool = false) {
        self.timeRange = timeRange
        self.layers = layers
        self.renderSize = renderSize
        self.usesLivePreviewOverrides = usesLivePreviewOverrides
        // An empty array tells AVFoundation that this instruction needs no
        // decoder at all. After a long intentional gap it can then fail to
        // restart the camera track when the first real clip begins, while the
        // custom compositor keeps returning a perfectly valid black canvas.
        // `nil` means all composition sources remain eligible for preroll; the
        // empty `layers` array still makes this instruction render true black.
        self.requiredSourceTrackIDs = layers.isEmpty
            ? nil
            : layers.map { NSNumber(value: $0.trackID) }
        super.init()
    }
}

/// Core Image compositor that grades every source clip independently and only
/// then applies its transform, opacity and timeline layer order. This is vital
/// when two graded clips overlap: neither grade can leak into the other layer.
final class NativeTimelineVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [Int(kCVPixelFormatType_32BGRA)],
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
    ]

    private let renderQueue = DispatchQueue(label: "NetVistaStudio.NativeExport.Compositor", qos: .userInitiated)
    private let stateLock = NSLock()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var renderContext: AVVideoCompositionRenderContext?
    private var cancellationGeneration = 0

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        stateLock.lock()
        renderContext = newRenderContext
        stateLock.unlock()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        stateLock.lock()
        let generation = cancellationGeneration
        stateLock.unlock()
        renderQueue.async { [weak self] in
            guard let self else {
                request.finishCancelledRequest()
                return
            }
            guard !self.wasCancelled(generation) else {
                request.finishCancelledRequest()
                return
            }
            guard let instruction = request.videoCompositionInstruction as? NativeTimelineVideoInstruction else {
                request.finish(with: NSError(
                    domain: "NetVistaStudio.NativeTimelineVideoCompositor",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The timeline supplied an unsupported video instruction."]
                ))
                return
            }
            guard let destination = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(
                    domain: "NetVistaStudio.NativeTimelineVideoCompositor",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "A destination video frame could not be allocated."]
                ))
                return
            }

            let canvas = CGRect(origin: .zero, size: instruction.renderSize)
            var composite = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: canvas)
            let timelineTime = request.compositionTime.seconds

            // The instruction stores foreground first. Compositing from the
            // bottom upward preserves the same V1/V2 ordering as the editor.
            for layer in instruction.layers.reversed() {
                guard let sourceBuffer = request.sourceFrame(byTrackID: layer.trackID) else {
                    // AVPlayer can transiently omit a decoder frame exactly at
                    // a cut or immediately after a seek. Failing the request
                    // poisons the entire player item and leaves the monitor
                    // black. Preview instead finishes the frame with any other
                    // available layers (or the black canvas) and recovers on
                    // the next frame; final export remains strict.
                    if instruction.usesLivePreviewOverrides { continue }
                    request.finish(with: NSError(
                        domain: "NetVistaStudio.NativeTimelineVideoCompositor",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey:
                            "A required source frame for ‘\(layer.clip.name)’ (track \(layer.trackID)) was missing at \(String(format: "%.3f", timelineTime)) seconds."
                        ]
                    ))
                    return
                }
                let renderedClip = instruction.usesLivePreviewOverrides ? TimelineLiveEffectStore.shared.resolved(layer.clip) : layer.clip
                let rawImage = CIImage(cvPixelBuffer: sourceBuffer)
                var image = NativeTimelineVisualPipeline.applyGrade(
                    to: rawImage,
                    clip: renderedClip,
                    timelineTime: timelineTime
                )
                let transform = NativeTimelineVisualPipeline.renderTransform(
                    clip: renderedClip,
                    naturalSize: layer.naturalSize,
                    preferredTransform: layer.preferredTransform,
                    timelineTime: timelineTime,
                    renderSize: instruction.renderSize
                )
                image = image.transformed(by: transform).cropped(to: canvas)
                let opacity = min(1, max(0, renderedClip.value(for: .opacity, at: timelineTime)))
                if opacity < 0.9999 {
                    image = image.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                    ])
                }
                let blendFilter: String?
                switch renderedClip.effects.blendMode {
                case .normal: blendFilter = nil
                case .multiply: blendFilter = "CIMultiplyBlendMode"
                case .screen: blendFilter = "CIScreenBlendMode"
                case .overlay: blendFilter = "CIOverlayBlendMode"
                case .softLight: blendFilter = "CISoftLightBlendMode"
                case .add: blendFilter = "CIAdditionCompositing"
                }
                if let blendFilter {
                    composite = image.applyingFilter(blendFilter, parameters: [kCIInputBackgroundImageKey: composite]).cropped(to: canvas)
                } else {
                    composite = image.composited(over: composite)
                }
            }

            guard !self.wasCancelled(generation) else {
                request.finishCancelledRequest()
                return
            }
            self.ciContext.render(
                composite.cropped(to: canvas),
                to: destination,
                bounds: canvas,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            if self.wasCancelled(generation) { request.finishCancelledRequest() }
            else { request.finish(withComposedVideoFrame: destination) }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        stateLock.lock()
        cancellationGeneration += 1
        stateLock.unlock()
        // The protocol requires this call to return only after outstanding
        // requests have either completed or acknowledged cancellation.
        renderQueue.sync {}
    }

    private func wasCancelled(_ generation: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return generation != cancellationGeneration
    }
}

enum NativeTimelineVisualPipeline {
    static func applyGrade(to source: CIImage, clip: TimelineClip, timelineTime: Double) -> CIImage {
        let sourceExtent = source.extent
        var keySettings = clip.effects.ultraKey
        keySettings.tolerance = clip.value(for: .ultraKeyTolerance, at: timelineTime)
        keySettings.soften = clip.value(for: .ultraKeySoftness, at: timelineTime)
        keySettings.choke = clip.value(for: .ultraKeyChoke, at: timelineTime)
        keySettings.spill = clip.value(for: .ultraKeySpill, at: timelineTime)
        var image = UltraKeyRuntime.apply(to: source, settings: keySettings)
        if keySettings.enabled && keySettings.output != .composite {
            return applyCrop(to: image, clip: clip, timelineTime: timelineTime, sourceExtent: sourceExtent)
        }
        image = image.applyingFilter("CIExposureAdjust", parameters: [
            "inputEV": clip.value(for: .exposure, at: timelineTime)
        ])
        image = image.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: clip.value(for: .brightness, at: timelineTime),
            kCIInputContrastKey: clip.value(for: .contrast, at: timelineTime),
            kCIInputSaturationKey: clip.value(for: .saturation, at: timelineTime)
        ])
        image = image.applyingFilter("CIVibrance", parameters: [
            "inputAmount": clip.value(for: .vibrance, at: timelineTime)
        ])
        image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputHighlightAmount": 1 - clip.value(for: .highlights, at: timelineTime),
            "inputShadowAmount": clip.value(for: .shadows, at: timelineTime)
        ])
        image = image.applyingFilter("CIGammaAdjust", parameters: [
            "inputPower": clip.value(for: .gamma, at: timelineTime)
        ])
        image = image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(
                x: clip.value(for: .temperature, at: timelineTime),
                y: clip.value(for: .tint, at: timelineTime)
            )
        ])
        image = image.applyingFilter("CIHueAdjust", parameters: [
            "inputAngle": clip.value(for: .hue, at: timelineTime) * .pi / 180
        ])
        image = applyingThreeWayColorWheels(to: image, extras: clip.colorExtras)
        image = CubeLUTRuntime.applyOrPassThrough(clip.colorExtras.cubeLUT, to: image)

        let monochrome = min(1, max(0, clip.value(for: .monochromeAmount, at: timelineTime)))
        if monochrome > 0.0001 {
            image = image.applyingFilter("CIColorMonochrome", parameters: [
                "inputColor": CIColor.white,
                "inputIntensity": monochrome
            ])
        }
        let sepia = min(1, max(0, clip.value(for: .sepiaAmount, at: timelineTime)))
        if sepia > 0.0001 {
            image = image.applyingFilter("CISepiaTone", parameters: ["inputIntensity": sepia])
        }
        let blur = max(0, clip.value(for: .blurRadius, at: timelineTime))
        if blur > 0.0001 {
            image = image.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blur]).cropped(to: sourceExtent)
        }
        let sharpen = max(0, clip.value(for: .sharpenAmount, at: timelineTime))
        if sharpen > 0.0001 {
            image = image.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": sharpen])
        }
        let vignette = max(0, clip.value(for: .vignetteIntensity, at: timelineTime))
        if vignette > 0.0001 {
            image = image.applyingFilter("CIVignette", parameters: ["inputIntensity": vignette, "inputRadius": 2])
        }
        return applyCrop(to: image, clip: clip, timelineTime: timelineTime, sourceExtent: sourceExtent)
    }

    private static func applyCrop(to image: CIImage, clip: TimelineClip, timelineTime: Double, sourceExtent: CGRect) -> CIImage {
        let left = min(0.49, max(0, clip.value(for: .cropLeft, at: timelineTime)))
        let right = min(0.49, max(0, clip.value(for: .cropRight, at: timelineTime)))
        let top = min(0.49, max(0, clip.value(for: .cropTop, at: timelineTime)))
        let bottom = min(0.49, max(0, clip.value(for: .cropBottom, at: timelineTime)))
        let cropRect = CGRect(
            x: sourceExtent.minX + sourceExtent.width * left,
            y: sourceExtent.minY + sourceExtent.height * bottom,
            width: sourceExtent.width * max(0.02, 1 - left - right),
            height: sourceExtent.height * max(0.02, 1 - top - bottom)
        )
        return image.cropped(to: cropRect)
    }

    static func renderTransform(
        clip: TimelineClip,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        timelineTime: Double,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let sourceBounds = CGRect(origin: .zero, size: naturalSize)
        let orientedBounds = sourceBounds.applying(preferredTransform)
        let orientedWidth = abs(orientedBounds.width)
        let orientedHeight = abs(orientedBounds.height)
        guard orientedWidth > 0, orientedHeight > 0 else { return preferredTransform }

        let fitScale = min(renderSize.width / orientedWidth, renderSize.height / orientedHeight)
        let fit = CGAffineTransform(scaleX: fitScale, y: fitScale)
        let scaledBounds = orientedBounds.applying(fit)
        let centre = CGAffineTransform(
            translationX: (renderSize.width - scaledBounds.width) / 2 - scaledBounds.minX,
            y: (renderSize.height - scaledBounds.height) / 2 - scaledBounds.minY
        )
        let fittedSource = preferredTransform.concatenating(fit).concatenating(centre)

        let centreX = renderSize.width / 2
        let centreY = renderSize.height / 2
        let positionX = CGFloat(clip.value(for: .positionX, at: timelineTime)) * centreX
        let positionY = CGFloat(clip.value(for: .positionY, at: timelineTime)) * centreY
        let scale = CGFloat(max(0.01, clip.value(for: .scale, at: timelineTime)))
        let rotation = CGFloat(clip.value(for: .rotation, at: timelineTime) * .pi / 180)
        let userTransform = CGAffineTransform(translationX: centreX + positionX, y: centreY + positionY)
            .rotated(by: rotation)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -centreX, y: -centreY)
        return fittedSource.concatenating(userTransform)
    }
}

// MARK: - Reader/writer pump

private final class NativeWriterSession {
    private enum Stream { case video, audio }

    private let plan: NativeExportPlan
    private let stagingURL: URL
    private let destinationURL: URL
    private let job: TimelineExportJob
    private let progressHandler: NativeTimelineExportEngine.ProgressHandler
    private let completionHandler: (Result<URL, Error>) -> Void
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderAudioMixOutput?
    private let audioInput: AVAssetWriterInput?
    private let videoQueue = DispatchQueue(label: "NetVistaStudio.NativeExport.Video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "NetVistaStudio.NativeExport.Audio", qos: .userInitiated)
    private static let backupCleanupQueue = DispatchQueue(label: "NetVistaStudio.NativeExport.BackupCleanup", qos: .utility)
    private let lock = NSLock()
    private var videoFinished = false
    private var audioFinished: Bool
    private var terminalClaimed = false
    private var completionResolved = false
    private var cancellationRequested = false
    private var lastProgressUpdate = 0.0

    init(
        plan: NativeExportPlan,
        stagingURL: URL,
        destinationURL: URL,
        options: TimelineExportOptions,
        codec: AVVideoCodecType,
        job: TimelineExportJob,
        progress: @escaping NativeTimelineExportEngine.ProgressHandler,
        completion: @escaping (Result<URL, Error>) -> Void
    ) throws {
        self.plan = plan
        self.stagingURL = stagingURL
        self.destinationURL = destinationURL
        self.job = job
        self.progressHandler = progress
        self.completionHandler = completion
        self.audioFinished = !plan.hasAudio

        if FileManager.default.fileExists(atPath: stagingURL.path) {
            try FileManager.default.removeItem(at: stagingURL)
        }
        writer = try AVAssetWriter(outputURL: stagingURL, fileType: options.container.avFileType)
        writer.shouldOptimizeForNetworkUse = options.optimizeForStreaming
        let videoSettings = NativeTimelineExportEngine.videoSettings(codec: codec, options: options)
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw NativeTimelineExportError.codecUnavailable(options.codec, options.resolution)
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw NativeTimelineExportError.writerCouldNotStart("The selected video settings are not supported.")
        }
        writer.add(videoInput)

        reader = try AVAssetReader(asset: plan.composition)
        let pixelSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: plan.composition.tracks(withMediaType: .video),
            videoSettings: pixelSettings
        )
        videoOutput.videoComposition = plan.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw NativeTimelineExportError.readerCouldNotStart("The composited video stream could not be created.")
        }
        reader.add(videoOutput)

        if plan.hasAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: plan.composition.tracks(withMediaType: .audio),
                audioSettings: audioSettings
            )
            output.audioMix = plan.audioMix
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw NativeTimelineExportError.readerCouldNotStart("The mixed audio stream could not be created.")
            }
            reader.add(output)
            audioOutput = output

            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: max(96_000, options.audioBitRate)
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw NativeTimelineExportError.writerCouldNotStart("The AAC audio encoder is not available.")
            }
            writer.add(input)
            audioInput = input
        } else {
            audioOutput = nil
            audioInput = nil
        }
    }

    func start() throws {
        guard !job.isCancelled else { throw NativeTimelineExportError.cancelled }
        guard writer.startWriting() else {
            throw NativeTimelineExportError.writerCouldNotStart(writer.error?.localizedDescription ?? "Unknown writer error")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw NativeTimelineExportError.readerCouldNotStart(reader.error?.localizedDescription ?? "Unknown reader error")
        }
        writer.startSession(atSourceTime: .zero)
        DispatchQueue.main.async {
            self.progressHandler(TimelineExportProgress(fractionCompleted: 0, renderedSeconds: 0, totalSeconds: self.plan.duration))
        }

        videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in self?.pumpVideo() }
        if let audioInput {
            audioInput.requestMediaDataWhenReady(on: audioQueue) { [weak self] in self?.pumpAudio() }
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        lock.unlock()
        reader.cancelReading()
        writer.cancelWriting()
        completeFailure(NativeTimelineExportError.cancelled)
    }

    private func pumpVideo() {
        while videoInput.isReadyForMoreMediaData && !isTerminal {
            guard !job.isCancelled else { fail(NativeTimelineExportError.cancelled); return }
            guard let sample = videoOutput.copyNextSampleBuffer() else {
                videoInput.markAsFinished()
                streamFinished(.video)
                return
            }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            let seconds = presentationTime.seconds
            guard videoInput.append(sample) else {
                fail(NativeTimelineExportError.encodingFailed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "The video encoder stopped."))
                return
            }
            reportProgress(for: seconds)
        }
    }

    private func pumpAudio() {
        guard let audioInput, let audioOutput else { return }
        while audioInput.isReadyForMoreMediaData && !isTerminal {
            guard !job.isCancelled else { fail(NativeTimelineExportError.cancelled); return }
            guard let sample = audioOutput.copyNextSampleBuffer() else {
                audioInput.markAsFinished()
                streamFinished(.audio)
                return
            }
            guard audioInput.append(sample) else {
                fail(NativeTimelineExportError.encodingFailed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "The audio encoder stopped."))
                return
            }
        }
    }

    private var isTerminal: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminalClaimed
    }

    private func streamFinished(_ stream: Stream) {
        let shouldFinish: Bool
        lock.lock()
        guard !terminalClaimed else { lock.unlock(); return }
        switch stream {
        case .video: videoFinished = true
        case .audio: audioFinished = true
        }
        shouldFinish = videoFinished && audioFinished
        if shouldFinish { terminalClaimed = true }
        lock.unlock()
        guard shouldFinish else { return }

        if reader.status == .failed {
            completeFailure(NativeTimelineExportError.encodingFailed(reader.error?.localizedDescription ?? "The media reader failed."))
            return
        }
        writer.finishWriting { [weak self] in
            self?.finishWritingCompleted()
        }
    }

    private enum DestinationCommit {
        case created
        case replaced(backupURL: URL)
    }

    /// Called by AVAssetWriter after its asynchronous finishing phase. The
    /// session lock is intentionally held across commit and the job performs
    /// the final atomic success claim. If Cancel was clicked at any point while
    /// finishWriting was running, the staged movie is discarded (or rolled
    /// back) and success is never reported.
    private func finishWritingCompleted() {
        lock.lock()
        guard !completionResolved else {
            lock.unlock()
            try? FileManager.default.removeItem(at: stagingURL)
            return
        }
        if cancellationRequested || job.isCancelled {
            completionResolved = true
            lock.unlock()
            try? FileManager.default.removeItem(at: stagingURL)
            completionHandler(.failure(NativeTimelineExportError.cancelled))
            return
        }
        guard writer.status == .completed else {
            completionResolved = true
            let error = NativeTimelineExportError.encodingFailed(writer.error?.localizedDescription ?? "The movie could not be finalized.")
            lock.unlock()
            try? FileManager.default.removeItem(at: stagingURL)
            completionHandler(.failure(error))
            return
        }

        do {
            let commit = try commitFinishedMovie()
            if job.claimSuccessfulCompletion() {
                completionResolved = true
                lock.unlock()
                finalize(commit)
                DispatchQueue.main.async {
                    self.progressHandler(TimelineExportProgress(fractionCompleted: 1, renderedSeconds: self.plan.duration, totalSeconds: self.plan.duration))
                }
                completionHandler(.success(destinationURL))
            } else {
                // Cancellation won the race after encoding but before delivery.
                try rollback(commit)
                cancellationRequested = true
                completionResolved = true
                lock.unlock()
                try? FileManager.default.removeItem(at: stagingURL)
                completionHandler(.failure(NativeTimelineExportError.cancelled))
            }
        } catch {
            completionResolved = true
            lock.unlock()
            try? FileManager.default.removeItem(at: stagingURL)
            completionHandler(.failure(NativeTimelineExportError.encodingFailed("The finished movie could not replace the destination: \(error.localizedDescription)")))
        }
    }

    private func commitFinishedMovie() throws -> DestinationCommit {
        let manager = FileManager.default
        if manager.fileExists(atPath: destinationURL.path) {
            let backupName = ".\(destinationURL.lastPathComponent).netvista-studio-backup-\(UUID().uuidString)"
            let backupURL = destinationURL.deletingLastPathComponent().appendingPathComponent(backupName)
            try? manager.removeItem(at: backupURL)
            _ = try manager.replaceItemAt(
                destinationURL,
                withItemAt: stagingURL,
                backupItemName: backupName,
                options: [.withoutDeletingBackupItem]
            )
            return .replaced(backupURL: backupURL)
        } else {
            try manager.moveItem(at: stagingURL, to: destinationURL)
            return .created
        }
    }

    private func rollback(_ commit: DestinationCommit) throws {
        let manager = FileManager.default
        switch commit {
        case .created:
            if manager.fileExists(atPath: destinationURL.path) { try manager.removeItem(at: destinationURL) }
        case .replaced(let backupURL):
            guard manager.fileExists(atPath: backupURL.path) else {
                throw NativeTimelineExportError.encodingFailed(
                    "Cancellation could not restore the previous export because its safety backup is missing."
                )
            }
            if manager.fileExists(atPath: destinationURL.path) {
                // FileManager performs this replacement atomically. Never
                // remove the current destination before the backup is ready.
                _ = try manager.replaceItemAt(destinationURL, withItemAt: backupURL)
            } else {
                try manager.moveItem(at: backupURL, to: destinationURL)
            }
        }
    }

    private func finalize(_ commit: DestinationCommit) {
        guard case .replaced(let backupURL) = commit,
              FileManager.default.fileExists(atPath: backupURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: backupURL)
        } catch {
            NSLog("NetVista Studio could not remove export backup on the first attempt: \(error.localizedDescription)")
            Self.retryBackupCleanup(at: backupURL, attempt: 1)
        }
    }

    private static func retryBackupCleanup(at backupURL: URL, attempt: Int) {
        let maximumAttempts = 3
        let delay = 0.4 * Double(attempt)
        backupCleanupQueue.asyncAfter(deadline: .now() + delay) {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { return }
            do {
                try FileManager.default.removeItem(at: backupURL)
            } catch {
                NSLog("NetVista Studio export backup cleanup retry \(attempt) failed: \(error.localizedDescription)")
                if attempt < maximumAttempts {
                    retryBackupCleanup(at: backupURL, attempt: attempt + 1)
                } else {
                    NSLog("NetVista Studio left the recoverable export backup at \(backupURL.path).")
                }
            }
        }
    }

    private func reportProgress(for seconds: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard now - lastProgressUpdate >= 0.08, !terminalClaimed else { lock.unlock(); return }
        lastProgressUpdate = now
        lock.unlock()
        let rendered = min(max(0, seconds), plan.duration)
        let fraction = plan.duration > 0 ? rendered / plan.duration : 0
        DispatchQueue.main.async {
            self.progressHandler(TimelineExportProgress(fractionCompleted: fraction, renderedSeconds: rendered, totalSeconds: self.plan.duration))
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        guard !completionResolved else { lock.unlock(); return }
        terminalClaimed = true
        completionResolved = true
        lock.unlock()
        reader.cancelReading()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: stagingURL)
        completionHandler(.failure(error))
    }

    private func completeFailure(_ error: Error) {
        lock.lock()
        guard !completionResolved else { lock.unlock(); return }
        terminalClaimed = true
        completionResolved = true
        lock.unlock()
        try? FileManager.default.removeItem(at: stagingURL)
        completionHandler(.failure(error))
    }
}
