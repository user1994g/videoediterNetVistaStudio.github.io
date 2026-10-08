import Foundation
import AVFoundation
import CoreGraphics

/// These are decoded-frame checks, not settings/transform bookkeeping checks.
/// The same assertions run against the composed preview and the encoded MP4.
@main struct EffectsPixelChecks {
    struct Pixel {
        let r: Int, g: Int, b: Int
        var black: Bool { max(r, g, b) < 24 }
        // AVFoundation's YUV conversion varies slightly with source colour tags.
        // Dominant-channel checks leave room for that conversion, not for a
        // wrong quadrant, invisible source, or unprocessed effect.
        var red: Bool { r > 180 && g < 85 && b < 85 }
        var green: Bool { g > 180 && r < 85 && b < 85 }
        var blue: Bool { b > 180 && r < 85 && g < 85 }
        var white: Bool { min(r, g, b) > 180 }
        var gray: Bool { max(r, g, b) - min(r, g, b) < 10 }
        var description: String { "RGB(\(r),\(g),\(b))" }
    }
    struct Frame {
        let image: CGImage
        func pixel(_ x: Int, _ y: Int) -> Pixel {
            let scale = CGFloat(image.width) / 640
            let region = CGRect(x: CGFloat(x - 3) * scale, y: CGFloat(y - 3) * scale, width: 7 * scale, height: 7 * scale)
            guard let crop = image.cropping(to: region) else { fatalError("Invalid sampling region") }
            var bytes = [UInt8](repeating: 0, count: 4)
            guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("No bitmap context") }
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Pixel(r: Int(bytes[0]), g: Int(bytes[1]), b: Int(bytes[2]))
        }
    }
    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
    static func progress(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
    static func frame(_ generator: AVAssetImageGenerator, at seconds: Double) throws -> Frame {
        let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        expect(image.width == 1280 && image.height == 720, "Frame is not fitted to the requested 1280×720 canvas")
        return Frame(image: image)
    }
    static func checkFrames(_ generator: AVAssetImageGenerator, label: String) throws {
        // The source has four entire quadrants: red, green / blue, white.
        let neutral = try frame(generator, at: 0.5)
        expect(neutral.pixel(160, 90).red && neutral.pixel(480, 90).green &&
               neutral.pixel(160, 270).blue && neutral.pixel(480, 270).white,
               "\(label): neutral source fitting/orientation changed: TL \(neutral.pixel(160, 90).description), TR \(neutral.pixel(480, 90).description), BL \(neutral.pixel(160, 270).description), BR \(neutral.pixel(480, 270).description)")
        let hidden = try frame(generator, at: 1.5)
        for (x, y) in [(160, 90), (480, 90), (160, 270), (480, 270)] {
            expect(hidden.pixel(x, y).black, "\(label): opacity 0 does not hide the source at \(x),\(y)")
        }
        let half = try frame(generator, at: 2.5).pixel(160, 90)
        // Match the existing native Mac Core Image renderer: filters and alpha
        // operate in linear light, then the output is encoded to sRGB.
        // Qt/Android currently use encoded-channel controls; that separate
        // renderer parity gap must not be concealed by this iOS test.
        expect((165...202).contains(half.r) && half.g < 45 && half.b < 24,
               "\(label): opacity 50 is not a real composite over black: \(half.description)")
        let scaled = try frame(generator, at: 3.5)
        expect(scaled.pixel(60, 60).black && scaled.pixel(240, 130).red && scaled.pixel(400, 230).white,
               "\(label): 50% scale does not shrink about canvas centre")
        let right = try frame(generator, at: 4.5)
        expect(right.pixel(240, 130).black && right.pixel(350, 130).red && right.pixel(550, 130).green,
               "\(label): X=0.5 must move right by one quarter of canvas width (half-canvas normalized position)")
        let up = try frame(generator, at: 5.5)
        expect(up.pixel(240, 40).red && up.pixel(400, 140).white && up.pixel(240, 240).black,
               "\(label): Y=0.5 must move up by one quarter of canvas height, not down")
        let rotated = try frame(generator, at: 6.5)
        expect(rotated.pixel(280, 100).green && rotated.pixel(360, 100).white &&
               rotated.pixel(280, 260).red && rotated.pixel(360, 260).blue,
               "\(label): +90° must rotate counterclockwise in visible canvas coordinates")
        let desaturated = try frame(generator, at: 7.5)
        for (x, y) in [(160, 90), (480, 90), (160, 270)] {
            let value = desaturated.pixel(x, y)
            expect(value.gray && !value.black, "\(label): saturation 0 did not create gray at \(x),\(y): \(value.description)")
        }
        let bright = try frame(generator, at: 8.5).pixel(160, 270)
        expect((110...145).contains(bright.r) && (110...145).contains(bright.g) && bright.b > 220,
               "\(label): brightness 0.2 did not affect the decoded video: \(bright.description)")
        let lowContrast = try frame(generator, at: 9.5)
        for (x, y) in [(160, 90), (480, 90), (160, 270), (480, 270)] {
            let value = lowContrast.pixel(x, y)
            expect(value.gray && (172...203).contains(value.r),
                   "\(label): contrast 0 did not make midgray: \(value.description)")
        }
        progress("PASS: \(label) decoded pixels — neutral fitting, opacity 0/50, centred scale, half-canvas X/Y, +Y up, CCW rotation, saturation, brightness and contrast")
    }
    static func checkProjectMigration(_ directory: URL) throws {
        let oldClips: [[String: Any]] = [
            ["id": UUID().uuidString, "name": "First", "file": "quadrants.mov", "duration": 1.0, "inPoint": 0.2, "outPoint": 0.8],
            ["id": UUID().uuidString, "name": "Second", "file": "quadrants.mov", "duration": 1.0, "inPoint": 0.1, "outPoint": 0.9]
        ]
        let legacy = try JSONSerialization.data(withJSONObject: ["format": "netvista-mobile-video", "version": 1,
            "name": "Legacy", "clips": oldClips])
        var project = try JSONDecoder().decode(MobileProject.self, from: legacy)
        expect(project.version == 3 && project.library.count == 1, "Schema 1 migration must deduplicate media library")
        expect(project.library[0].inPoint == 0 && project.library[0].outPoint == 1 &&
               project.library[0].effects == MobileClipEffects(), "Migrated media-pool source must retain full original duration")
        project.clips[0].effects = MobileClipEffects(scale: 0.5, positionX: 0.25, positionY: 0.4,
            rotation: 45, opacity: 0.5, brightness: 0.2, contrast: 1.4, saturation: 0.6)
        let history = MobileHistory(); history.record(project)
        try project.split(0, at: 0.3)
        expect(project.clips.count == 3 && project.clips[0].id != project.clips[1].id &&
               project.clips[0].effects == project.clips[1].effects && project.library.count == 1,
               "Split must preserve clip effects and shared original media without duplicate IDs")
        let previous = history.undo(project)!
        expect(previous.clips.count == 2 && previous.clips[0].effects == project.clips[0].effects,
               "Undo must restore effect-bearing clip state")
        expect(history.redo(previous) == project, "Redo must restore split and clip effects")
        let output = directory.appendingPathComponent("effects-roundtrip.netvistamobile")
        try project.write(output)
        expect(try MobileProject.read(output) == project, "Native project save/reopen lost source pool or clip effects")
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            var bad = project; bad.clips[0].effects.opacity = invalid
            do { try bad.validate(); fatalError("Invalid non-finite effect was accepted") } catch {}
        }
        progress("PASS: schema 1 migration, neutral defaults, deduplicated full source pool, effects-preserving split, undo/redo and native project round-trip")
    }
    static func checkAnimation(_ directory: URL) async throws {
        var animated = MobileClipEffects()
        try animated.upsertKeyframe(for: .opacity, at: 0, value: 0, interpolation: .hold)
        try animated.upsertKeyframe(for: .opacity, at: 0.25, value: 0)
        try animated.upsertKeyframe(for: .opacity, at: 0.75, value: 1, interpolation: .hold)
        var project = MobileProject()
        project.clips = [MobileClip(name: "Lead in", file: "quadrants.mov", duration: 1, outPoint: 1),
                         MobileClip(name: "Animated fade", file: "quadrants.mov", duration: 1, outPoint: 1, effects: animated)]
        try project.trim(1, start: 0.1, end: 1)
        try project.split(1, at: 0.3)
        let sequence = try await MobileVideoEngine.sequence(project, media: directory, height: 720)
        expect(sequence.instructions[2].containsTweening, "Animated instruction must advertise temporal changes")
        expect(sequence.instructions[1].sourceInPoint == 0.1 && sequence.instructions[2].sourceInPoint == 0.4,
               "Fixture must be a non-first trimmed and split source, not a zero-origin curve")
        expect(abs(sequence.instructions[2].effects(at: CMTime(seconds: 1.4, preferredTimescale: 600)).opacity - 0.5) < 0.0001,
               "Composition time must remap through nonzero instruction start and split source in-point")
        func generator(_ asset: AVAsset, composition: AVVideoComposition? = nil) -> AVAssetImageGenerator {
            let generator = AVAssetImageGenerator(asset: asset); generator.videoComposition = composition
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero; return generator
        }
        func check(_ generator: AVAssetImageGenerator, label: String) throws {
            expect(try frame(generator, at: 0.5).pixel(160, 90).red, "\(label): animation leaked into preceding source instance")
            expect(try frame(generator, at: 1.033333).pixel(160, 90).black, "\(label): hold opacity 0 did not produce black")
            let half = try frame(generator, at: 1.4).pixel(160, 90)
            expect((165...202).contains(half.r) && half.g < 45 && half.b < 24,
                   "\(label): fade midpoint after split must be actual linear-light opacity 50: \(half.description)")
            expect(try frame(generator, at: 1.8).pixel(160, 90).red, "\(label): fade did not return to opacity 100")
        }
        try check(generator(sequence.composition, composition: sequence.videoComposition), label: "animated composed preview")
        // Prove that a prepared instruction evaluates new keyframe snapshots,
        // rather than freezing the initially loaded scalar/curve values.
        var reversed = animated
        try reversed.upsertKeyframe(for: .opacity, at: 0, value: 1, interpolation: .hold)
        try reversed.upsertKeyframe(for: .opacity, at: 0.25, value: 1)
        try reversed.upsertKeyframe(for: .opacity, at: 0.75, value: 0, interpolation: .hold)
        for clip in project.clips.dropFirst() { sequence.updateEffects(id: clip.id, effects: reversed) }
        let updated = generator(sequence.composition, composition: sequence.videoComposition)
        expect(try frame(updated, at: 1.033333).pixel(160, 90).red, "Live updated opacity curve remained frozen at old zero")
        expect(try frame(updated, at: 1.8).pixel(160, 90).black, "Live updated opacity curve remained frozen at old one")
        let exportSequence = try await MobileVideoEngine.sequence(project, media: directory, height: 720)
        let output = directory.appendingPathComponent("animated-effects-out.mp4")
        let session = try MobileVideoEngine.exporter(exportSequence, output: output)
        await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
        guard session.status == .completed else { throw session.error ?? MobileProjectError.noVideo }
        try check(generator(AVURLAsset(url: output)), label: "animated encoded MP4")
        progress("PASS: real preview and encoded MP4 animation pixels, opacity 0 → 50 → 100, nonzero sequence offset, split source-time continuity and live curve snapshot updates")
    }
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try checkProjectMigration(directory)
        var project = MobileProject()
        let variants = [MobileClipEffects(), MobileClipEffects(opacity: 0), MobileClipEffects(opacity: 0.5),
            MobileClipEffects(scale: 0.5), MobileClipEffects(scale: 0.5, positionX: 0.5),
            MobileClipEffects(scale: 0.5, positionY: 0.5), MobileClipEffects(rotation: 90),
            MobileClipEffects(saturation: 0), MobileClipEffects(brightness: 0.2), MobileClipEffects(contrast: 0)]
        project.clips = variants.enumerated().map { index, effects in
            MobileClip(name: "Effect \(index)", file: "quadrants.mov", duration: 1, outPoint: 1, effects: effects)
        }
        let sequence = try await MobileVideoEngine.sequence(project, media: directory, height: 720)
        let preview = AVAssetImageGenerator(asset: sequence.composition)
        preview.videoComposition = sequence.videoComposition
        preview.requestedTimeToleranceBefore = .zero; preview.requestedTimeToleranceAfter = .zero
        progress("Checking actual composed preview frames...")
        try checkFrames(preview, label: "composed preview")
        let output = directory.appendingPathComponent("effects-out.mp4")
        progress("Encoding ten-variant MP4 export...")
        let exportSequence = try await MobileVideoEngine.sequence(project, media: directory, height: 720)
        let session = try MobileVideoEngine.exporter(exportSequence, output: output)
        await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
        guard session.status == .completed else { throw session.error ?? MobileProjectError.noVideo }
        let asset = AVURLAsset(url: output)
        let exported = AVAssetImageGenerator(asset: asset)
        exported.appliesPreferredTrackTransform = true
        exported.requestedTimeToleranceBefore = .zero; exported.requestedTimeToleranceAfter = .zero
        progress("Checking decoded MP4 frames...")
        try checkFrames(exported, label: "encoded MP4 export")
        let duration = try await asset.load(.duration)
        expect(abs(duration.seconds - 10) < 0.1, "Effect export sequence length changed")
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        expect(audioTracks.isEmpty, "Silent-only export must not retain an empty audio track")
        try await checkAnimation(directory)
        print("Verification media retained at \(directory.path)")
    }
}
