import Foundation

/// Ordered event → action chains. No scripts from project files are executed.
/// The exporter implements this deliberately small instruction set verbatim.
struct GamePlayState {
    var objects: [GameObject]
    var dimension: GameDimension = .twoD
    var score: Double = 0
    var elapsed: Double = 0
    var destroyed = Set<UUID>()
    var variables: [String: Double] = [:]
    var animations: [UUID: String] = [:]
    var animationSpeeds: [UUID: Double] = [:]
    private var previousKeys = Set<String>()
    private var started = false
    private var contacts = Set<String>()
    init(objects: [GameObject], dimension: GameDimension = .twoD) { self.objects = objects; self.dimension = dimension }

    func overlaps(_ a: GameObject, _ b: GameObject) -> Bool {
        let radius = (a.size + b.size) / 2
        return abs(a.x-b.x) < radius && abs(a.y-b.y) < radius && (dimension == .twoD || abs(a.z-b.z) < radius)
    }
    mutating func step(keys: Set<String>, seconds: Double) {
        let dt = seconds.isFinite ? min(max(seconds, 0), 0.05) : 0
        let oldTime = elapsed; elapsed += dt
        var nextContacts = Set<String>()
        // Snapshot the rule owners, but evaluate each action against live game state.
        for owner in objects {
            guard !destroyed.contains(owner.id) else { continue }
            for rule in owner.rules where rule.enabled {
                guard !destroyed.contains(owner.id) else { break }
                let token = owner.id.uuidString + rule.id.uuidString
                let fire: Bool
                switch rule.event {
                case .start: fire = !started
                case .update: fire = true
                case .keyHeld: fire = keys.contains(rule.key)
                case .keyPressed: fire = keys.contains(rule.key) && !previousKeys.contains(rule.key)
                case .timer: fire = floor(elapsed / rule.interval) > floor(oldTime / rule.interval)
                case .touch:
                    let touching = objects.first(where: { $0.id == owner.id }).map { current in
                        objects.contains { other in other.id == rule.otherID && other.id != current.id && !destroyed.contains(other.id) && current.visible && other.visible && overlaps(current, other) }
                    } ?? false
                    if touching { nextContacts.insert(token) }; fire = touching && !contacts.contains(token)
                }
                guard fire else { continue }
                let graph = rule.graph
                var pending = graph.map { g in g.wires.filter { $0.from == rule.id }.map(\.to) } ?? rule.actions.map(\.id)
                var visited = Set<UUID>()
                while !pending.isEmpty {
                    let id = pending.removeFirst()
                    guard visited.insert(id).inserted, let action = rule.actions.first(where: { $0.id == id }) else { continue }
                    var branch: Bool?
                    guard let index = objects.firstIndex(where: { $0.id == (action.targetID ?? owner.id) }), !destroyed.contains(objects[index].id) else { continue }
                    switch action.kind {
                    case .keyboard:
                        let dx = (keys.contains("d") || keys.contains("right") ? 1.0 : 0) - (keys.contains("a") || keys.contains("left") ? 1.0 : 0)
                        let dy = (keys.contains("w") || keys.contains("up") ? 1.0 : 0) - (keys.contains("s") || keys.contains("down") ? 1.0 : 0)
                        let distance = action.value * dt / max(1, hypot(dx, dy))
                        move(index, x: dx*distance, y: dimension == .twoD ? dy*distance : 0, z: dimension == .threeD ? -dy*distance : 0)
                    case .move: move(index, x: action.x*dt, y: action.y*dt, z: action.z*dt)
                    case .position: objects[index].x = action.x; objects[index].y = action.y; objects[index].z = action.z
                    case .rotate: objects[index].rotation = (objects[index].rotation + action.value*dt).truncatingRemainder(dividingBy: 360)
                    case .scale: objects[index].size = max(0.01, min(1000, action.value))
                    case .opacity: objects[index].opacity = max(0, min(1, action.value))
                    case .show: objects[index].visible = true
                    case .hide: objects[index].visible = false
                    case .destroy: destroyed.insert(objects[index].id)
                    case .score: score += action.value
                    case .ifKey: branch = action.text == "movement" ? !keys.isDisjoint(with:["w","a","s","d","up","down","left","right"]) : keys.contains(action.text ?? "space")
                    case .ifScore: branch = score >= action.value
                    case .ifTouch:
                        branch = objects.first(where: { $0.id == owner.id }).map { overlaps($0,objects[index]) && $0.id != objects[index].id && $0.visible && objects[index].visible } ?? false
                    case .setVariable: variables[action.text ?? "health"] = action.value
                    case .addVariable: variables[action.text ?? "health",default:0] += action.value
                    case .ifVariable: branch = variables[action.text ?? "health",default:0] >= action.value
                    case .walk: animations[objects[index].id] = "walk"; animationSpeeds[objects[index].id] = max(0.01,min(10,action.value))
                    case .spriteAnimation: animations[objects[index].id] = "sprite"; animationSpeeds[objects[index].id] = max(0.01,min(10,action.value))
                    case .stopAnimation: animations.removeValue(forKey:objects[index].id); animationSpeeds.removeValue(forKey:objects[index].id)
                    }
                    if let graph {
                        let port: GamePort = branch.map { $0 ? .yes : .no } ?? .next
                        pending.insert(contentsOf:graph.wires.filter { $0.from == action.id && $0.port == port }.map(\.to),at:0)
                    }
                }
            }
        }
        contacts = nextContacts; started = true; previousKeys = keys
    }
    private mutating func move(_ index: Int, x: Double, y: Double, z: Double) {
        // Axis-separated box collisions; deliberately not a rigid-body physics engine.
        for (key, delta) in [(\GameObject.x,x),(\GameObject.y,y),(\GameObject.z,z)] {
            if key == \GameObject.z && dimension == .twoD { continue }
            var candidate = objects[index]; candidate[keyPath: key] = max(-10000,min(10000,candidate[keyPath: key]+delta))
            if !objects.contains(where: { $0.id != candidate.id && $0.solid && $0.visible && !destroyed.contains($0.id) && overlaps(candidate,$0) }) { objects[index] = candidate }
        }
    }
}

/// A bounded OBJ triangle reader shared by the native renderer and both exports.
/// Materials/rigs are not read; a sprite asset can be assigned as the model texture.
struct GameMesh: Codable {
    var positions: [Float] = []
    var uv: [Float] = []
    static func read(_ asset: GameAsset) throws -> Self {
        if asset.path.hasSuffix(".nvmesh") {
            let mesh = try JSONDecoder().decode(Self.self,from:asset.data)
            guard !mesh.positions.isEmpty, mesh.positions.count <= 900000, mesh.positions.count % 9 == 0,
                  mesh.uv.count == mesh.positions.count / 3 * 2,
                  mesh.positions.allSatisfy({ $0.isFinite && abs($0) <= 10 }), mesh.uv.allSatisfy({ $0.isFinite }) else { throw GameProjectError.invalid("Invalid compiled model geometry.") }
            return mesh
        }
        return try obj(asset.data)
    }
    static func stl(_ data: Data) throws -> Self {
        guard data.count <= 32*1024*1024 else { throw GameProjectError.invalid("Use an STL model under 32 MB.") }
        var mesh = Self()
        if data.count >= 84 {
            let count = Int(data.subdata(in:80..<84).withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(as:UInt32.self)) })
            if count > 0, count <= 100000, 84+count*50 == data.count {
                for triangle in 0..<count {
                    for vertex in 0..<3 {
                        let offset = 84+triangle*50+12+vertex*12
                        for axis in 0..<3 {
                            let bytes = data.subdata(in:offset+axis*4..<offset+axis*4+4)
                            mesh.positions.append(bytes.withUnsafeBytes { Float(bitPattern:UInt32(littleEndian:$0.loadUnaligned(as:UInt32.self))) })
                        }
                    }
                }
            }
        }
        if mesh.positions.isEmpty, let text = String(data:data,encoding:.utf8) {
            for line in text.split(whereSeparator:\.isNewline) {
                let fields = line.split(whereSeparator:\.isWhitespace)
                if fields.first?.lowercased() == "vertex" {
                    let coordinates = fields.dropFirst().compactMap { Float($0) }
                    guard coordinates.count == 3 else { throw GameProjectError.invalid("Invalid STL vertex.") }
                    mesh.positions += coordinates
                    guard mesh.positions.count <= 900000 else { throw GameProjectError.invalid("Use up to 100,000 triangles.") }
                }
            }
        }
        guard !mesh.positions.isEmpty, mesh.positions.count % 9 == 0, mesh.positions.allSatisfy({ $0.isFinite && abs($0) <= 1e9 }) else { throw GameProjectError.invalid("The STL contains no valid triangles.") }
        mesh.uv = [Float](repeating:0,count:mesh.positions.count/3*2)
        var low = [Float](repeating:.greatestFiniteMagnitude,count:3), high = [Float](repeating: -.greatestFiniteMagnitude,count:3)
        for i in mesh.positions.indices { low[i%3] = min(low[i%3],mesh.positions[i]); high[i%3] = max(high[i%3],mesh.positions[i]) }
        let span = max(0.00001,(0..<3).map { high[$0]-low[$0] }.max()!)
        for i in mesh.positions.indices { mesh.positions[i] = (mesh.positions[i]-(low[i%3]+high[i%3])/2)/span }
        return mesh
    }
    static func obj(_ data: Data) throws -> Self {
        guard data.count <= 32*1024*1024, let text = String(data: data, encoding: .utf8) else { throw GameProjectError.invalid("Use a UTF-8 OBJ model under 32 MB.") }
        var vertices: [[Float]] = [], textures: [[Float]] = [], mesh = Self()
        func index(_ text: Substring, count: Int) -> Int? {
            guard let n = Int(text), n != 0 else { return nil }; let value = n > 0 ? n-1 : count+n
            return (0..<count).contains(value) ? value : nil
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].split(whereSeparator: \.isWhitespace)
            guard let type = fields.first else { continue }
            if type == "v" || type == "vt" {
                let count = type == "v" ? 3 : 2
                let values = fields.dropFirst().prefix(count).compactMap { Float($0) }
                guard values.count == count, values.allSatisfy({ $0.isFinite && abs($0) <= 1e9 }), vertices.count + textures.count < 1000000 else { throw GameProjectError.invalid("The OBJ has invalid or too many vertices.") }
                if type == "v" { vertices.append(values) } else { textures.append(values) }
            } else if type == "f" {
                let face = Array(fields.dropFirst())
                guard (3...256).contains(face.count) else { throw GameProjectError.invalid("OBJ faces must have 3–256 vertices.") }
                for i in 1..<(face.count-1) {
                    for value in [face[0],face[i],face[i+1]] {
                        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
                        guard let vi = parts.first.flatMap({ index($0, count: vertices.count) }) else { throw GameProjectError.invalid("The OBJ references a missing vertex.") }
                        mesh.positions += vertices[vi]
                        if parts.count > 1, !parts[1].isEmpty {
                            guard let ti = index(parts[1], count: textures.count) else { throw GameProjectError.invalid("The OBJ references a missing texture coordinate.") }
                            mesh.uv += textures[ti]
                        } else { mesh.uv += [0,0] }
                    }
                    guard mesh.positions.count <= 900000 else { throw GameProjectError.invalid("Use models with no more than 100,000 triangles.") }
                }
            }
        }
        guard !mesh.positions.isEmpty else { throw GameProjectError.invalid("The OBJ has no polygon faces.") }
        var low = [Float](repeating: .greatestFiniteMagnitude,count: 3), high = [Float](repeating: -.greatestFiniteMagnitude,count: 3)
        for i in mesh.positions.indices { low[i%3] = min(low[i%3],mesh.positions[i]); high[i%3] = max(high[i%3],mesh.positions[i]) }
        let span = max(0.00001, (0..<3).map { high[$0]-low[$0] }.max()!)
        for i in mesh.positions.indices { let axis = i%3; mesh.positions[i] = (mesh.positions[i]-(low[axis]+high[axis])/2)/span }
        return mesh
    }
}
