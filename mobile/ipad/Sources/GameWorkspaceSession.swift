import Foundation

/// UIKit's commands operate on the desktop document and runtime directly. A
/// rejected edit cannot partially alter the project or consume an Undo step.
final class GameWorkspaceSession {
    private(set) var project: GameProject
    private(set) var selectedID: UUID?
    private var undoSteps: [GameProject] = [], redoSteps: [GameProject] = []
    private var transaction: GameProject?
    private(set) var revision: UInt64 = 0
    var undoCount: Int { undoSteps.count }
    var canUndo: Bool { !undoSteps.isEmpty }
    var canRedo: Bool { !redoSteps.isEmpty }
    var selectedObject: GameObject? { project.objects.first { $0.id == selectedID } }
    init(project: GameProject = .starter(.twoD)) throws { try project.validate(); self.project = project }
    func select(_ id: UUID?) { selectedID = project.objects.contains { $0.id == id } ? id : nil }
    func edit(_ update: (inout GameProject) throws -> Void) throws {
        var next = project; try update(&next); try next.validate()
        guard next != project else { return }
        if transaction == nil { undoSteps.append(project); redoSteps.removeAll() }
        project = next
        if transaction == nil { trimHistory() }
        revision &+= 1
        if !project.objects.contains(where: { $0.id == selectedID }) { selectedID = nil }
    }
    func beginTransaction() { if transaction == nil { transaction = project } }
    func endTransaction(cancel: Bool = false) {
        guard let original = transaction else { return }; transaction = nil
        if cancel { if original != project { project = original; revision &+= 1 }; return }
        if original != project { undoSteps.append(original); redoSteps.removeAll(); trimHistory() }
    }
    private func trimHistory() {
        // Array/Data snapshots share immutable buffers. Budget unique embedded
        // assets, not sixty copies of every texture, and also bound scene data.
        func retainedBytes() -> Int {
            var assets = Set<UUID>(), bytes = 0
            for document in [project] + undoSteps + redoSteps {
                bytes += document.objects.reduce(0) { $0 + 512 + $1.rules.reduce(0) { $0 + 256 + $1.actions.count * 256 } }
                for asset in document.assets where assets.insert(asset.id).inserted { bytes += asset.data.count }
            }; return bytes
        }
        while !undoSteps.isEmpty && (undoSteps.count > 60 || retainedBytes() > 256 * 1024 * 1024) { undoSteps.removeFirst() }
    }
    func undo() { endTransaction(); guard let previous = undoSteps.popLast() else { return }; redoSteps.append(project); project = previous; revision &+= 1; select(selectedID) }
    func redo() { endTransaction(); guard let next = redoSteps.popLast() else { return }; undoSteps.append(project); project = next; revision &+= 1; select(selectedID) }
    func load(_ project: GameProject) throws { try project.validate(); self.project = project; selectedID = nil; transaction = nil; undoSteps.removeAll(); redoSteps.removeAll(); revision &+= 1 }
    /// Starting a scene is an edit, not a file load. Keep the previous scene,
    /// assets and block graph recoverable with one Undo in this workspace.
    func newDocument(_ dimension: GameDimension) throws {
        endTransaction()
        try edit { $0 = .starter(dimension) }
        selectedID = nil
    }
    @discardableResult func add(_ object: GameObject) throws -> UUID { try edit { $0.objects.append(object) }; select(object.id); return object.id }
    func updateSelected(_ update: (inout GameObject) throws -> Void) throws {
        guard let id = selectedID else { throw GameProjectError.invalid("Select an object in the scene first.") }
        try edit { project in guard let i = project.objects.firstIndex(where: { $0.id == id }) else { return }; try update(&project.objects[i]) }
    }
    func duplicate() throws {
        guard var object = selectedObject else { return }
        let oldID = object.id; object.id = UUID(); object.name += " copy"; object.x += 1
        for i in object.rules.indices {
            var rule = object.rules[i], ids = [rule.id: UUID()]
            for action in rule.actions { ids[action.id] = UUID() }
            rule.id = ids[rule.id]!
            for j in rule.actions.indices { rule.actions[j].id = ids[rule.actions[j].id]!; if rule.actions[j].targetID == oldID { rule.actions[j].targetID = object.id } }
            if rule.otherID == oldID { rule.otherID = object.id }
            if var graph = rule.graph {
                graph.wires = graph.wires.map { GameWire(from: ids[$0.from]!, port: $0.port, to: ids[$0.to]!) }
                graph.positions = graph.positions.map { GameNodePosition(id: ids[$0.id]!, x: $0.x, y: $0.y) }; rule.graph = graph
            }
            object.rules[i] = rule
        }
        try add(object)
    }
    func deleteSelected() throws {
        guard let id = selectedID else { return }
        try edit { project in
            project.objects.removeAll { $0.id == id }
            for i in project.objects.indices {
                project.objects[i].rules.removeAll { $0.otherID == id }
                for j in project.objects[i].rules.indices {
                    var rule = project.objects[i].rules[j]
                    let removed = Set(rule.actions.filter { $0.targetID == id }.map(\.id))
                    rule.actions.removeAll { removed.contains($0.id) }
                    rule.graph?.wires.removeAll { removed.contains($0.from) || removed.contains($0.to) }
                    rule.graph?.positions.removeAll { removed.contains($0.id) }
                    project.objects[i].rules[j] = rule
                }
            }
        }
    }
    func reorder(_ delta: Int) throws {
        guard let i = project.objects.firstIndex(where: { $0.id == selectedID }) else { return }
        let target = max(0, min(project.objects.count - 1, i + delta)); guard target != i else { return }
        try edit { let object = $0.objects.remove(at: i); $0.objects.insert(object, at: target) }
    }
    func setRule(_ rule: GameRule, at index: Int) throws { try updateSelected { guard $0.rules.indices.contains(index) else { return }; $0.rules[index] = rule } }
    func addAction(_ kind: GameActionKind, rule index: Int) throws {
        try updateSelected { object in
            guard object.rules.indices.contains(index) else { return }
            var rule = object.rules[index]; let action = GameAction(kind: kind)
            var graph = rule.graph ?? .chain(rule)
            let previous = rule.actions.last?.id ?? rule.id
            rule.actions.append(action)
            graph.positions.append(GameNodePosition(id: action.id, x: 300 + Double((rule.actions.count - 1) % 4) * 250, y: 40 + Double((rule.actions.count - 1) / 4) * 150))
            _ = graph.insertAction(action.id, after: previous, in: rule)
            rule.graph = graph; object.rules[index] = rule
        }
    }
    func connect(rule index: Int, from: UUID, port: GamePort, to: UUID?) throws {
        try updateSelected { object in
            var rule = object.rules[index], graph = rule.graph ?? .chain(rule)
            graph.wires.removeAll { $0.from == from && $0.port == port }
            if let to { graph.wires.append(GameWire(from: from, port: port, to: to)) }
            rule.graph = graph; object.rules[index] = rule
        }
    }
}
