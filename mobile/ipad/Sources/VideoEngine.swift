import AVFoundation
import CoreGraphics

struct MobileSequence {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
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

    static func sequence(_ project: MobileProject, media: URL, height: Int = 1080, fps: Int = 30) async throws -> MobileSequence {
        try project.validate()
        guard !project.clips.isEmpty else { throw MobileProjectError.noVideo }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MobileProjectError.noVideo
        }
        let size = CGSize(width: CGFloat(height) * 16 / 9, height: CGFloat(height))
        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for clip in project.clips {
            let url = media.appendingPathComponent(clip.file)
            guard FileManager.default.fileExists(atPath: url.path) else { throw MobileProjectError.missingMedia(clip.name) }
            let asset = AVURLAsset(url: url)
            let sources = try await asset.loadTracks(withMediaType: .video)
            guard let source = sources.first else { throw MobileProjectError.noVideo }
            let range = CMTimeRange(start: CMTime(seconds: clip.inPoint, preferredTimescale: 600),
                                    duration: CMTime(seconds: clip.length, preferredTimescale: 600))
            try video.insertTimeRange(range, of: source, at: cursor)
            if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                // Missing or shorter audio is not allowed to prevent an otherwise valid video export.
                let soundRange = try await sound.load(.timeRange)
                let intersection = CMTimeRangeGetIntersection(range, otherRange: soundRange)
                if intersection.duration.seconds > 0 {
                    let destination = CMTimeAdd(cursor, CMTimeSubtract(intersection.start, range.start))
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
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
            layer.setTransform(transform, at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = CMTimeAdd(cursor, range.duration)
        }
        let render = AVMutableVideoComposition()
        render.renderSize = size; render.frameDuration = CMTime(value: 1, timescale: Int32(fps))
        render.instructions = instructions
        return MobileSequence(composition: composition, videoComposition: render)
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
