import Foundation

/// Editor-only helpers. Recipes use the existing portable instruction set, so
/// the same graphs run in the native player and both source export targets.
enum GameBehaviourRecipe: String, CaseIterable {
    case movement = "Player movement"
    case spin = "Continuous spin"
    case patrol = "Patrol left / right"
    case pickup = "Collect for score"
    case interact = "Hide when E is pressed"
    case reset = "Return to spawn on Space"

    func rules(for object: GameObject, contact: UUID? = nil) -> [GameRule] {
        func chain(_ rule: GameRule) -> GameRule {
            var result = rule; result.graph = .chain(rule); return result
        }
        switch self {
        case .movement: return [chain(GameRule(actions: [GameAction(kind: .keyboard, value: 4)]))]
        case .spin: return [chain(GameRule(actions: [GameAction(kind: .rotate, value: 60)]))]
        case .interact: return [chain(GameRule(event: .keyPressed, key: "e", actions: [GameAction(kind: .hide)]))]
        case .reset:
            return [chain(GameRule(event: .keyPressed, key: "space", actions: [GameAction(kind: .position, x: object.x, y: object.y, z: object.z)]))]
        case .pickup:
            guard let contact, contact != object.id else { return [] }
            return [chain(GameRule(event: .touch, otherID: contact, actions: [GameAction(kind: .score, value: 1), GameAction(kind: .destroy)]))]
        case .patrol:
            let variable = "patrol_" + object.id.uuidString
            func branch(event: GameEvent, yes: GameAction, no: GameAction) -> GameRule {
                let test = GameAction(kind: .ifVariable, value: 1, text: variable)
                var rule = GameRule(event: event, interval: 2, actions: [test, yes, no])
                rule.graph = GameGraph(wires: [GameWire(from: rule.id, to: test.id), GameWire(from: test.id, port: .yes, to: yes.id), GameWire(from: test.id, port: .no, to: no.id)], positions: [GameNodePosition(id: rule.id, x: 30, y: 100), GameNodePosition(id: test.id, x: 290, y: 100), GameNodePosition(id: yes.id, x: 550, y: 30), GameNodePosition(id: no.id, x: 550, y: 180)])
                return rule
            }
            return [branch(event: .update, yes: GameAction(kind: .move, x: -2), no: GameAction(kind: .move, x: 2)), branch(event: .timer, yes: GameAction(kind: .setVariable, value: 0, text: variable), no: GameAction(kind: .setVariable, value: 1, text: variable))]
        }
    }
}

enum GameEditorMath {
    static func position(_ value: Double, grid: Double) -> Double {
        guard value.isFinite else { return 0 }
        let snapped = grid > 0 && grid.isFinite ? (value / grid).rounded() * grid : value
        return max(-10000, min(10000, snapped))
    }

    /// Project a pointer's displacement onto a screen-space world axis. Near
    /// end-on axes cannot be dragged reliably; ignore them instead of jumping.
    static func axisDistance(dx: Double, dy: Double, axisX: Double, axisY: Double) -> Double {
        let lengthSquared = axisX * axisX + axisY * axisY
        guard lengthSquared >= 4 else { return 0 }
        return (dx * axisX + dy * axisY) / lengthSquared
    }
}
