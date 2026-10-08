import Foundation

struct MobileClipEffects: Codable, Equatable {
    var scale: Double = 1
    var positionX: Double = 0
    var positionY: Double = 0
    var rotation: Double = 0
    var opacity: Double = 1
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1

    func validate() throws {
        guard scale.isFinite, (0.05...10).contains(scale), positionX.isFinite, (-2...2).contains(positionX),
              positionY.isFinite, (-2...2).contains(positionY), rotation.isFinite, (-360...360).contains(rotation),
              opacity.isFinite, (0...1).contains(opacity), brightness.isFinite, (-1...1).contains(brightness),
              contrast.isFinite, (0...4).contains(contrast), saturation.isFinite, (0...4).contains(saturation) else {
            throw MobileProjectError.invalidClip
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
        try effects.validate()
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
    var version = 2
    var name = "Untitled movie"
    var clips: [MobileClip] = []
    var library: [MobileClip] = []
    var totalDuration: Double { clips.reduce(0) { $0 + $1.length } }

    func validate() throws {
        guard format == "netvista-mobile-video", (1...2).contains(version), !name.isEmpty,
              clips.count <= 10_000, library.count <= 10_000, totalDuration.isFinite,
              totalDuration <= 31_536_000, Set(clips.map(\.id)).count == clips.count else {
            throw MobileProjectError.invalidProject
        }
        try clips.forEach { try $0.validate() }
        try library.forEach { try $0.validate() }
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
        try validate(); version = 2
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
        try encoder.encode(self).write(to: url, options: .atomic)
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
