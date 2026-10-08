import Foundation

/// Curves use source seconds, not sequence time. Moving/duplicating a clip or
/// splitting/triming its source range therefore never restarts its animation.
enum MobileEffectProperty: String, Codable, CaseIterable {
    case scale, positionX, positionY, rotation, opacity, brightness, contrast, saturation
    var title: String {
        switch self {
        case .scale: return "Scale / Zoom"
        case .positionX: return "Position X"
        case .positionY: return "Position Y"
        case .rotation: return "Rotation"
        case .opacity: return "Opacity"
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .saturation: return "Saturation"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .scale: return 0.05...10
        case .positionX, .positionY: return -2...2
        case .rotation: return -360...360
        case .opacity: return 0...1
        case .brightness: return -1...1
        case .contrast, .saturation: return 0...4
        }
    }
}

enum MobileKeyframeInterpolation: String, Codable, CaseIterable {
    case linear, hold, easeIn, easeOut, easeInOut
    var title: String {
        switch self {
        case .linear: return "Linear"
        case .hold: return "Hold"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Ease In / Out"
        }
    }
}

struct MobileEffectKeyframe: Codable, Equatable {
    var sourceSeconds: Double
    var value: Double
    /// The interpolation leaving this keyframe, up to the next keyframe.
    var interpolation: MobileKeyframeInterpolation = .linear
}

struct MobileClipEffects: Codable, Equatable {
    var scale: Double = 1
    var positionX: Double = 0
    var positionY: Double = 0
    var rotation: Double = 0
    var opacity: Double = 1
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var keyframes: [String: [MobileEffectKeyframe]] = [:]

    private enum CodingKeys: String, CodingKey {
        case scale, positionX, positionY, rotation, opacity, brightness, contrast, saturation, keyframes
    }
    init(scale: Double = 1, positionX: Double = 0, positionY: Double = 0, rotation: Double = 0,
         opacity: Double = 1, brightness: Double = 0, contrast: Double = 1, saturation: Double = 1,
         keyframes: [String: [MobileEffectKeyframe]] = [:]) {
        self.scale = scale; self.positionX = positionX; self.positionY = positionY; self.rotation = rotation
        self.opacity = opacity; self.brightness = brightness; self.contrast = contrast; self.saturation = saturation
        self.keyframes = keyframes
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        scale = try value.decode(Double.self, forKey: .scale); positionX = try value.decode(Double.self, forKey: .positionX)
        positionY = try value.decode(Double.self, forKey: .positionY); rotation = try value.decode(Double.self, forKey: .rotation)
        opacity = try value.decode(Double.self, forKey: .opacity); brightness = try value.decode(Double.self, forKey: .brightness)
        contrast = try value.decode(Double.self, forKey: .contrast); saturation = try value.decode(Double.self, forKey: .saturation)
        keyframes = try value.decodeIfPresent([String: [MobileEffectKeyframe]].self, forKey: .keyframes) ?? [:]
    }

    func value(for property: MobileEffectProperty) -> Double {
        switch property {
        case .scale: return scale; case .positionX: return positionX; case .positionY: return positionY
        case .rotation: return rotation; case .opacity: return opacity; case .brightness: return brightness
        case .contrast: return contrast; case .saturation: return saturation
        }
    }
    mutating func setValue(_ number: Double, for property: MobileEffectProperty) {
        switch property {
        case .scale: scale = number; case .positionX: positionX = number; case .positionY: positionY = number
        case .rotation: rotation = number; case .opacity: opacity = number; case .brightness: brightness = number
        case .contrast: contrast = number; case .saturation: saturation = number
        }
    }
    func frames(for property: MobileEffectProperty) -> [MobileEffectKeyframe] { keyframes[property.rawValue] ?? [] }
    func keyframeIndex(for property: MobileEffectProperty, at seconds: Double) -> Int? {
        frames(for: property).firstIndex { abs($0.sourceSeconds - seconds) <= 1.0 / 600 }
    }
    /// Validated clips make the binary search bounded and sorted. Unknown/non-
    /// finite preview times fall back to static values without producing NaNs.
    func value(for property: MobileEffectProperty, at sourceSeconds: Double) -> Double {
        let frames = frames(for: property)
        guard sourceSeconds.isFinite, let first = frames.first, let last = frames.last else { return value(for: property) }
        if sourceSeconds <= first.sourceSeconds { return first.value }
        if sourceSeconds >= last.sourceSeconds { return last.value }
        var low = 0, high = frames.count - 1
        while high - low > 1 { let middle = (low + high) / 2; if frames[middle].sourceSeconds <= sourceSeconds { low = middle } else { high = middle } }
        let a = frames[low], b = frames[high]
        var fraction = (sourceSeconds - a.sourceSeconds) / (b.sourceSeconds - a.sourceSeconds)
        switch a.interpolation {
        case .hold: fraction = 0
        case .easeIn: fraction = fraction * fraction
        case .easeOut: fraction = 1 - (1 - fraction) * (1 - fraction)
        case .easeInOut: fraction = fraction * fraction * (3 - 2 * fraction)
        case .linear: break
        }
        return a.value + (b.value - a.value) * fraction
    }
    func evaluated(at sourceSeconds: Double) -> MobileClipEffects {
        var result = self
        for property in MobileEffectProperty.allCases { result.setValue(value(for: property, at: sourceSeconds), for: property) }
        result.keyframes = [:]
        return result
    }
    mutating func upsertKeyframe(for property: MobileEffectProperty, at seconds: Double, value: Double,
                                interpolation: MobileKeyframeInterpolation = .linear) throws {
        guard seconds.isFinite, (0...31_536_000).contains(seconds), value.isFinite, property.range.contains(value) else {
            throw MobileProjectError.invalidClip
        }
        var track = frames(for: property)
        let frame = MobileEffectKeyframe(sourceSeconds: seconds, value: value, interpolation: interpolation)
        if let index = keyframeIndex(for: property, at: seconds) { track[index] = frame }
        else { guard track.count < 2_000 else { throw MobileProjectError.invalidClip }; track.append(frame) }
        track.sort { $0.sourceSeconds < $1.sourceSeconds }
        var next = self; next.keyframes[property.rawValue] = track; try next.validate(); self = next
    }
    mutating func removeKeyframe(for property: MobileEffectProperty, at seconds: Double) {
        guard let index = keyframeIndex(for: property, at: seconds) else { return }
        var track = frames(for: property); track.remove(at: index)
        if track.isEmpty { keyframes.removeValue(forKey: property.rawValue) } else { keyframes[property.rawValue] = track }
    }

    func validate(duration: Double = 31_536_000) throws {
        guard scale.isFinite, (0.05...10).contains(scale), positionX.isFinite, (-2...2).contains(positionX),
              positionY.isFinite, (-2...2).contains(positionY), rotation.isFinite, (-360...360).contains(rotation),
              opacity.isFinite, (0...1).contains(opacity), brightness.isFinite, (-1...1).contains(brightness),
              contrast.isFinite, (0...4).contains(contrast), saturation.isFinite, (0...4).contains(saturation) else {
            throw MobileProjectError.invalidClip
        }
        guard keyframes.count <= MobileEffectProperty.allCases.count,
              keyframes.values.reduce(0, { $0 + $1.count }) <= 10_000 else { throw MobileProjectError.invalidClip }
        for (key, frames) in keyframes {
            guard let property = MobileEffectProperty(rawValue: key), !frames.isEmpty, frames.count <= 2_000 else { throw MobileProjectError.invalidClip }
            var previous: Double = -1
            for frame in frames {
                guard frame.sourceSeconds.isFinite, frame.sourceSeconds >= 0, frame.sourceSeconds <= duration + 0.001,
                      frame.sourceSeconds - previous > 1.0 / 600, frame.value.isFinite, property.range.contains(frame.value) else {
                    throw MobileProjectError.invalidClip
                }
                previous = frame.sourceSeconds
            }
        }
    }
}

struct MobileClip: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var file: String
    var duration: Double
    var inPoint: Double = 0
    var outPoint: Double
    var effects = MobileClipEffects()
    var length: Double { outPoint - inPoint }

    private enum CodingKeys: String, CodingKey { case id, name, file, duration, inPoint, outPoint, effects }
    init(id: UUID = UUID(), name: String, file: String, duration: Double, inPoint: Double = 0,
         outPoint: Double, effects: MobileClipEffects = MobileClipEffects()) {
        self.id = id; self.name = name; self.file = file; self.duration = duration
        self.inPoint = inPoint; self.outPoint = outPoint; self.effects = effects
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        id = try value.decode(UUID.self, forKey: .id); name = try value.decode(String.self, forKey: .name)
        file = try value.decode(String.self, forKey: .file); duration = try value.decode(Double.self, forKey: .duration)
        inPoint = try value.decodeIfPresent(Double.self, forKey: .inPoint) ?? 0
        outPoint = try value.decode(Double.self, forKey: .outPoint)
        effects = try value.decodeIfPresent(MobileClipEffects.self, forKey: .effects) ?? MobileClipEffects()
    }

    func validate() throws {
        guard !name.isEmpty, file == URL(fileURLWithPath: file).lastPathComponent,
              !file.isEmpty, file != ".", file != "..",
              duration.isFinite, duration > 0, duration <= 31_536_000, inPoint.isFinite, outPoint.isFinite,
              inPoint >= 0, outPoint <= duration + 0.001, outPoint - inPoint >= 0.04 else {
            throw MobileProjectError.invalidClip
        }
        try effects.validate(duration: duration)
    }
}

enum MobileProjectError: LocalizedError {
    case invalidClip, invalidProject, missingMedia(String), noVideo
    var errorDescription: String? {
        switch self {
        case .invalidClip: return "A clip has invalid trim settings or a media path."
        case .invalidProject: return "This is not a supported NetVista mobile project."
        case .missingMedia(let file): return "The project is missing media: \(file)"
        case .noVideo: return "This file does not contain a playable video track."
        }
    }
}

struct MobileProject: Codable, Equatable {
    var format = "netvista-mobile-video"
    var version = 3
    var name = "Untitled movie"
    var clips: [MobileClip] = []
    var library: [MobileClip] = []
    var totalDuration: Double { clips.reduce(0) { $0 + $1.length } }

    func validate() throws {
        guard format == "netvista-mobile-video", (1...3).contains(version), !name.isEmpty,
              clips.count <= 10_000, library.count <= 10_000, totalDuration.isFinite,
              totalDuration <= 31_536_000, Set(clips.map(\.id)).count == clips.count else {
            throw MobileProjectError.invalidProject
        }
        try clips.forEach { try $0.validate() }
        try library.forEach { try $0.validate() }
        guard (clips + library).reduce(0, { count, clip in count + clip.effects.keyframes.values.reduce(0, { $0 + $1.count }) }) <= 100_000 else {
            throw MobileProjectError.invalidProject
        }
    }

    init() {}
    private enum CodingKeys: String, CodingKey { case format, version, name, clips, library }
    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        format = try value.decode(String.self, forKey: .format); version = try value.decode(Int.self, forKey: .version)
        name = try value.decode(String.self, forKey: .name); clips = try value.decode([MobileClip].self, forKey: .clips)
        if let saved = try value.decodeIfPresent([MobileClip].self, forKey: .library) { library = saved }
        else {
            var files = Set<String>()
            library = clips.filter { files.insert($0.file).inserted }.map {
                var original = $0; original.inPoint = 0; original.outPoint = original.duration; original.effects = MobileClipEffects(); return original
            }
        }
        try validate(); version = 3
    }

    mutating func split(_ index: Int, at seconds: Double) throws {
        guard clips.indices.contains(index), seconds.isFinite, seconds >= 0.04,
              seconds <= clips[index].length - 0.04 else { throw MobileProjectError.invalidClip }
        var right = clips[index]; right.id = UUID(); right.inPoint += seconds
        clips[index].outPoint = right.inPoint; clips.insert(right, at: index + 1)
    }

    mutating func trim(_ index: Int, start: Double, end: Double) throws {
        guard clips.indices.contains(index) else { throw MobileProjectError.invalidClip }
        var clip = clips[index]; clip.inPoint = start; clip.outPoint = end
        try clip.validate(); clips[index] = clip
    }

    mutating func move(_ index: Int, to destination: Int) {
        guard clips.indices.contains(index), clips.indices.contains(destination), index != destination else { return }
        let clip = clips.remove(at: index); clips.insert(clip, at: destination)
    }

    static func read(_ url: URL) throws -> MobileProject {
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024 else { throw MobileProjectError.invalidProject }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }

    func write(_ url: URL) throws {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 8 * 1024 * 1024 else { throw MobileProjectError.invalidProject }
        try data.write(to: url, options: .atomic)
    }
}

final class MobileHistory {
    private(set) var undo: [MobileProject] = []
    private(set) var redo: [MobileProject] = []
    func record(_ current: MobileProject) {
        undo.append(current); if undo.count > 50 { undo.removeFirst() }; redo.removeAll()
    }
    func undo(_ current: MobileProject) -> MobileProject? {
        guard let previous = undo.popLast() else { return nil }; redo.append(current); return previous
    }
    func redo(_ current: MobileProject) -> MobileProject? {
        guard let next = redo.popLast() else { return nil }; undo.append(current); return next
    }
}
