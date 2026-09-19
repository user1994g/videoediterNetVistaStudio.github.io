import Foundation

enum GamePort: String, Codable { case next, yes, no }
struct GameWire: Codable, Equatable {
    var from: UUID
    var port: GamePort = .next
    var to: UUID
}
struct GameNodePosition: Codable, Equatable {
    var id: UUID
    var x: Double
    var y: Double
}
struct GameGraph: Codable, Equatable {
    var wires: [GameWire] = []
    var positions: [GameNodePosition] = []
    static func chain(_ rule: GameRule) -> Self {
        var graph = Self(), previous = rule.id
        graph.positions = [GameNodePosition(id: rule.id, x: 40, y: 50)]
        for (i, action) in rule.actions.enumerated() {
            graph.wires.append(GameWire(from: previous, to: action.id)); previous = action.id
            graph.positions.append(GameNodePosition(id: action.id, x: 320 + Double(i % 4)*260, y: 50 + Double(i / 4)*180))
        }
        return graph
    }
    func validate(rule: GameRule) throws {
        let ids = Set([rule.id] + rule.actions.map(\.id))
        guard ids.count == rule.actions.count + 1, wires.count <= 256, positions.count <= 65, Set(positions.map(\.id)).count == positions.count,
              positions.allSatisfy({ ids.contains($0.id) && $0.x.isFinite && $0.y.isFinite && (0...10000).contains($0.x) && (0...10000).contains($0.y) }) else { throw GameProjectError.invalid("Node positions or wire count are invalid.") }
        var unique = Set<String>()
        for wire in wires {
            let branch = rule.actions.first(where: { $0.id == wire.from })?.kind.isCondition == true
            guard ids.contains(wire.from), ids.contains(wire.to), wire.to != rule.id, wire.from != wire.to,
                  branch ? wire.port != .next : wire.port == .next,
                  unique.insert("\(wire.from)/\(wire.port)/\(wire.to)").inserted else { throw GameProjectError.invalid("Connect an output to an action input. Branches use Yes or No; duplicate wires are not allowed.") }
        }
        var visiting = Set<UUID>(), visited = Set<UUID>()
        func visit(_ id: UUID) throws {
            guard !visiting.contains(id) else { throw GameProjectError.invalid("That wire creates a loop. Use an Every frame or Timer event to repeat actions.") }
            if visited.contains(id) { return }; visiting.insert(id)
            for wire in wires where wire.from == id { try visit(wire.to) }
            visiting.remove(id); visited.insert(id)
        }
        for id in ids { try visit(id) }
    }
}

struct GameRigJoint: Codable, Equatable {
    var name: String
    var parent: Int?
    var x: Double
    var y: Double
    var z: Double
}
struct GameCharacterRig: Codable, Equatable {
    var joints: [GameRigJoint]
    var speed: Double = 1.8
    var stride: Double = 30
    func validate() throws {
        guard joints.count > 0, joints.count <= 64, speed.isFinite, (0.1...10).contains(speed), stride.isFinite, (0...90).contains(stride) else { throw GameProjectError.invalid("Invalid character rig settings.") }
        for (i,j) in joints.enumerated() {
            guard j.parent.map({ $0 >= 0 && $0 < i }) ?? true, [j.x,j.y,j.z].allSatisfy({ $0.isFinite && abs($0) <= 10 }), !j.name.isEmpty else { throw GameProjectError.invalid("Invalid joint hierarchy or position.") }
        }
    }
    static func humanoid() -> Self {
        // Normalized front-facing T-pose. Fit these joints before binding.
        Self(joints: [
            .init(name:"Hips",parent:nil,x:0,y:0,z:0),
            .init(name:"Spine",parent:0,x:0,y:0.13,z:0),
            .init(name:"Chest",parent:1,x:0,y:0.25,z:0),
            .init(name:"Head",parent:2,x:0,y:0.42,z:0),
            .init(name:"Left arm",parent:2,x:0.12,y:0.27,z:0),
            .init(name:"Left elbow",parent:4,x:0.28,y:0.27,z:0),
            .init(name:"Left hand",parent:5,x:0.43,y:0.27,z:0),
            .init(name:"Right arm",parent:2,x:-0.12,y:0.27,z:0),
            .init(name:"Right elbow",parent:7,x:-0.28,y:0.27,z:0),
            .init(name:"Right hand",parent:8,x:-0.43,y:0.27,z:0),
            .init(name:"Left thigh",parent:0,x:0.09,y:-0.02,z:0),
            .init(name:"Left knee",parent:10,x:0.09,y:-0.25,z:0),
            .init(name:"Left foot",parent:11,x:0.09,y:-0.47,z:0.04),
            .init(name:"Right thigh",parent:0,x:-0.09,y:-0.02,z:0),
            .init(name:"Right knee",parent:13,x:-0.09,y:-0.25,z:0),
            .init(name:"Right foot",parent:14,x:-0.09,y:-0.47,z:0.04)
        ])
    }
}
struct GameSpriteSheet: Codable, Equatable {
    var columns = 1
    var rows = 1
    var frames = 1
    var fps: Double = 10
    func validate() throws {
        guard (1...64).contains(columns), (1...64).contains(rows), (1...columns*rows).contains(frames), fps.isFinite, (0.1...60).contains(fps) else { throw GameProjectError.invalid("Invalid sprite-sheet rows, columns, frame count or speed.") }
    }
}
