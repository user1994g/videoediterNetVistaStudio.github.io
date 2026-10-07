import Foundation
import AVFoundation
import CoreGraphics

@main struct SequenceChecks {
    static func centerColor(_ asset: AVAsset, seconds: Double) throws -> (UInt8, UInt8, UInt8) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("No bitmap") }
        let crop = image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1))!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (bytes[0], bytes[1], bytes[2])
    }
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let red = try await MobileVideoEngine.inspect(directory.appendingPathComponent("red.mov"))
        let blue = try await MobileVideoEngine.inspect(directory.appendingPathComponent("blue.mov"))
        var project = MobileProject()
        project.clips = [MobileClip(name: "Silent red", file: "red.mov", duration: red, inPoint: 0.3, outPoint: 1.5),
                         MobileClip(name: "Rotated blue with sound", file: "blue.mov", duration: blue, inPoint: 0.4, outPoint: 2.0)]
        let sequence = try await MobileVideoEngine.sequence(project, media: directory, height: 720)
        precondition(abs(sequence.composition.duration.seconds - 2.8) < 0.01)
        precondition(sequence.videoComposition.instructions.count == 2)
        precondition(sequence.videoComposition.renderSize == CGSize(width: 1280, height: 720))
        let output = directory.appendingPathComponent("out.mp4")
        let exporter = try MobileVideoEngine.exporter(sequence, output: output)
        await withCheckedContinuation { continuation in exporter.exportAsynchronously { continuation.resume() } }
        guard exporter.status == .completed else { throw exporter.error ?? MobileProjectError.noVideo }
        let asset = AVURLAsset(url: output)
        let length = try await asset.load(.duration)
        precondition(abs(length.seconds - 2.8) < 0.1)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        precondition(audio.count == 1, "The sound from the second clip was lost")
        let size = try await asset.loadTracks(withMediaType: .video)[0].load(.naturalSize)
        precondition(size == CGSize(width: 1280, height: 720))
        let a = try centerColor(asset, seconds: 0.6); let b = try centerColor(asset, seconds: 2.0)
        precondition(a.0 > 180 && a.2 < 40, "First clip is not visible red")
        precondition(b.2 > 180 && b.0 < 40, "Second clip is not visible blue")
        let instructions = sequence.videoComposition.instructions
        precondition(abs(instructions[1].timeRange.start.seconds - 1.2) < 0.001)
        print("PASS: two source videos, trim offsets, sequence boundary, portrait/rotation fitting, visible nonblack frames, audio track and 720p MP4 export")
    }
}
