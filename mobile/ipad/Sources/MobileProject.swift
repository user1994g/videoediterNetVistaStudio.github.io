import Foundation

struct MobileClip: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var file: String
    var duration: Double
    var inPoint: Double = 0
    var outPoint: Double
    var length: Double { outPoint - inPoint }

    func validate() throws {
        guard !name.isEmpty, file == URL(fileURLWithPath: file).lastPathComponent,
              !file.isEmpty, file != ".", file != "..",
              duration.isFinite, duration > 0, inPoint.isFinite, outPoint.isFinite,
              inPoint >= 0, outPoint <= duration + 0.001, outPoint - inPoint >= 0.04 else {
            throw MobileProjectError.invalidClip
        }
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
    var version = 1
    var name = "Untitled movie"
    var clips: [MobileClip] = []
    var totalDuration: Double { clips.reduce(0) { $0 + $1.length } }

    func validate() throws {
        guard format == "netvista-mobile-video", version == 1, !name.isEmpty,
              clips.count <= 10_000, Set(clips.map(\.id)).count == clips.count else {
            throw MobileProjectError.invalidProject
        }
        try clips.forEach { try $0.validate() }
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
