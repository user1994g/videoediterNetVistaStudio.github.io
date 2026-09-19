import Foundation

enum GameDimension: String, Codable { case twoD = "2D", threeD = "3D" }
enum GameObjectKind: String, Codable, CaseIterable { case sprite, model, block, coin, player, empty }

enum GameEvent: String, Codable, CaseIterable {
    case start, update, keyHeld, timer, touch, keyPressed
    var title: String { switch self { case .start: return "When game starts"; case .update: return "Every frame"; case .keyHeld: return "While key is held"; case .keyPressed: return "When key is pressed"; case .timer: return "Every N seconds"; case .touch: return "When touching object" } }
}
enum GameActionKind: String, Codable, CaseIterable {
    case keyboard, move, position, rotate, scale, opacity, show, hide, destroy, score, ifKey, ifScore, ifTouch, setVariable, addVariable, ifVariable, walk, stopAnimation, spriteAnimation
    var isCondition: Bool { [.ifKey,.ifScore,.ifTouch,.ifVariable].contains(self) }
    var title: String { switch self { case .keyboard: return "WASD / arrow movement"; case .move: return "Move per second"; case .position: return "Set position"; case .rotate: return "Rotate per second"; case .scale: return "Set size"; case .opacity: return "Set opacity"; case .show: return "Show"; case .hide: return "Hide"; case .destroy: return "Destroy"; case .score: return "Add to score"; case .ifKey: return "If key is held"; case .ifScore: return "If score ≥ value"; case .ifTouch: return "If touching target"; case .setVariable: return "Set variable"; case .addVariable: return "Add to variable"; case .ifVariable: return "If variable ≥ value"; case .walk: return "Walk animation"; case .stopAnimation: return "Stop animation"; case .spriteAnimation: return "Animate sprite sheet" } }
}
struct GameAction: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: GameActionKind = .keyboard
    var targetID: UUID?
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0
    var value: Double = 4
    var text: String?
}
struct GameRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var event: GameEvent = .update
    var key = "space"
    var interval: Double = 1
    var otherID: UUID?
    var enabled = true
    var actions: [GameAction] = []
    var graph: GameGraph?
}

struct GameObject: Codable, Equatable {
    var id = UUID()
    var name: String
    var kind: GameObjectKind
    var x: Double
    var y: Double
    var size: Double = 1
    var imageID: UUID?
    var z: Double = 0
    var rotation: Double = 0
    var opacity: Double = 1
    var visible = true
    var solid = false
    var modelID: UUID?
    var rules: [GameRule] = []
    var rig: GameCharacterRig?
    var spriteSheet: GameSpriteSheet?

    enum CodingKeys: String, CodingKey { case id, name, kind, x, y, size, imageID, z, rotation, opacity, visible, solid, modelID, rules, rig, spriteSheet }
    init(name: String, kind: GameObjectKind, x: Double = 0, y: Double = 0, size: Double = 1, imageID: UUID? = nil) {
        self.name = name; self.kind = kind; self.x = x; self.y = y; self.size = size; self.imageID = imageID
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(GameObjectKind.self, forKey: .kind)
        x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        size = try c.decode(Double.self, forKey: .size); imageID = try c.decodeIfPresent(UUID.self, forKey: .imageID)
        z = try c.decodeIfPresent(Double.self, forKey: .z) ?? 0
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        solid = try c.decodeIfPresent(Bool.self, forKey: .solid) ?? (kind == .block)
        modelID = try c.decodeIfPresent(UUID.self, forKey: .modelID)
        rules = try c.decodeIfPresent([GameRule].self, forKey: .rules) ?? []
        rig = try c.decodeIfPresent(GameCharacterRig.self, forKey: .rig)
        spriteSheet = try c.decodeIfPresent(GameSpriteSheet.self, forKey: .spriteSheet)
    }
}

struct GameAsset: Codable, Equatable {
    var id = UUID()
    var path: String
    var data: Data
}

enum GameProjectError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

/// Assets are embedded bytes, never references to files outside the project.
/// Paths preserve imported folder structure; opening a game executes no code.
struct GameProject: Codable, Equatable {
    var format = "netvista-game"
    var version = 3
    var name: String
    var dimension: GameDimension
    var objects: [GameObject]
    var assets: [GameAsset] = []
    static let assetLimit = 128 * 1024 * 1024

    static func starter(_ dimension: GameDimension) -> Self {
        Self(name: "Untitled \(dimension.rawValue) Game", dimension: dimension, objects: [])
    }

    func validate() throws {
        guard format == "netvista-game", version == 3 else { throw GameProjectError.invalid("This game format or version is not supported.") }
        guard objects.count <= 2000,
              Set(objects.map(\.id)).count == objects.count,
              Set(assets.map(\.id)).count == assets.count, Set(assets.map(\.path)).count == assets.count,
              assets.count <= 5000 else { throw GameProjectError.invalid("Use up to 2,000 objects and 5,000 assets with unique IDs and paths.") }
        var bytes = 0
        for asset in assets {
            bytes += asset.data.count
            let parts = asset.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !asset.path.contains("\\"), !asset.path.contains("\0"), bytes <= Self.assetLimit else {
                throw GameProjectError.invalid("Game files have an invalid path or exceed the 128 MB embedded asset limit.")
            }
        }
        var totalActions = 0
        for object in objects {
            guard [object.x, object.y, object.z, object.size, object.rotation, object.opacity].allSatisfy(\.isFinite),
                  abs(object.x) <= 10000, abs(object.y) <= 10000, abs(object.z) <= 10000,
                  (0.01...1000).contains(object.size), (0...1).contains(object.opacity), abs(object.rotation) <= 360000,
                  object.imageID == nil || assets.contains(where: { $0.id == object.imageID }),
                  object.modelID == nil || assets.contains(where: { $0.id == object.modelID }),
                  object.kind != .model || (object.modelID != nil && dimension == .threeD) else {
                throw GameProjectError.invalid("An object has an invalid position, size, or missing image.")
            }
            if let rig = object.rig { try rig.validate(); guard object.modelID != nil else { throw GameProjectError.invalid("A character rig needs a model.") } }
            try object.spriteSheet?.validate()
            guard object.rules.count <= 64, Set(object.rules.map(\.id)).count == object.rules.count else { throw GameProjectError.invalid("Use up to 64 unique behaviour rules per object.") }
            for rule in object.rules {
                try rule.graph?.validate(rule: rule)
                totalActions += rule.actions.count
                guard totalActions <= 10000 else { throw GameProjectError.invalid("Use up to 10,000 action blocks in one game project.") }
                guard rule.interval.isFinite, (0.02...3600).contains(rule.interval),
                      ["w","a","s","d","up","down","left","right","space","e"].contains(rule.key),
                      rule.otherID == nil || objects.contains(where: { $0.id == rule.otherID }),
                      rule.actions.count <= 64, Set(rule.actions.map(\.id)).count == rule.actions.count else { throw GameProjectError.invalid("A behaviour has invalid timing, key, target or actions.") }
                for action in rule.actions {
                    guard (action.text?.count ?? 0) <= 128, [action.x,action.y,action.z,action.value].allSatisfy({ $0.isFinite && abs($0) <= 10000 }),
                          action.targetID == nil || objects.contains(where: { $0.id == action.targetID }) else { throw GameProjectError.invalid("A block contains an invalid value or target.") }
                }
            }
        }
    }

    func save(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func open(_ url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 190 * 1024 * 1024 else { throw GameProjectError.invalid("This game exceeds the starter editor's file size limit.") }
        var project = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        if project.version == 1 {
            // Make the old demo's implicit rules explicit, without seeding new projects.
            let player = project.objects.first(where: { $0.kind == .player })?.id
            for index in project.objects.indices {
                if project.dimension == .threeD { project.objects[index].z = -project.objects[index].y; project.objects[index].y = project.objects[index].size / 2 }
                if project.objects[index].kind == .player { project.objects[index].rules = [GameRule(actions: [GameAction(kind: .keyboard)])] }
                if project.objects[index].kind == .coin, let player {
                    project.objects[index].rules = [GameRule(event: .touch, otherID: player, actions: [GameAction(kind: .score, value: 1),GameAction(kind: .destroy)])]
                }
            }
            project.version = 2
        }
        if project.version == 2 { project.version = 3 }
        try project.validate(); return project
    }

    /// Build the complete import first so a missing/unreadable file cannot leave a partial import.
    mutating func importFiles(_ urls: [URL]) throws {
        let fm = FileManager.default
        var additions: [GameAsset] = []
        var bytes = assets.reduce(0) { $0 + $1.data.count }
        for requestedURL in urls {
            // Directory enumeration may canonicalize /var to /private/var on macOS.
            // Use one canonical base for both enumeration and relative-path slicing.
            let original = try requestedURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard original.isSymbolicLink != true else { throw GameProjectError.invalid("Import the original file instead of a symbolic link.") }
            let url = requestedURL.standardizedFileURL.resolvingSymlinksInPath()
            let prefix = UUID().uuidString + "/"
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw GameProjectError.invalid("Import the original file instead of a symbolic link: \(url.lastPathComponent)") }
            var files = [url]
            if values.isDirectory == true {
                var enumerationError: Error?
                guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw GameProjectError.invalid("Could not read the selected folder.") }
                files = []
                for case let child as URL in enumerator {
                    let info = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard info.isSymbolicLink != true else { throw GameProjectError.invalid("The folder contains a symbolic link: \(child.lastPathComponent). Import its original files instead.") }
                    if info.isRegularFile == true { files.append(child) }
                }
                if let error = enumerationError { throw error }
            }
            for file in files.sorted(by: { $0.path < $1.path }) {
                let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard info.isRegularFile == true, bytes + (info.fileSize ?? 0) <= Self.assetLimit,
                      additions.count + assets.count < 5000 else { throw GameProjectError.invalid("Import regular files up to a total of 128 MB and 5,000 files.") }
                let data = try Data(contentsOf: file)
                bytes += data.count
                guard bytes <= Self.assetLimit else { throw GameProjectError.invalid("Game assets exceed 128 MB.") }
                let canonicalFile = file.standardizedFileURL.resolvingSymlinksInPath().path
                let base = url.deletingLastPathComponent().path + "/"
                guard values.isDirectory != true || canonicalFile.hasPrefix(base) else { throw GameProjectError.invalid("An imported file is outside the selected folder.") }
                let relative = values.isDirectory == true ? String(canonicalFile.dropFirst(base.count)) : file.lastPathComponent
                additions.append(GameAsset(path: prefix + relative, data: data))
            }
        }
        var candidate = self; candidate.assets += additions; try candidate.validate(); self = candidate
    }
}
