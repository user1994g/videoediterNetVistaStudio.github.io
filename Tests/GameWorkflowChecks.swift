import Foundation

@main struct GameWorkflowChecks {
    static func main() throws {
        precondition(GameEditorMath.position(1.24,grid:0.5) == 1)
        precondition(GameEditorMath.position(-1.26,grid:0.5) == -1.5)
        precondition(GameEditorMath.position(1.24,grid:0) == 1.24)
        precondition(GameEditorMath.position(20000,grid:0.5) == 10000)
        precondition(GameEditorMath.axisDistance(dx:50,dy:20,axisX:25,axisY:10) == 2)
        precondition(GameEditorMath.axisDistance(dx:50,dy:20,axisX:0.1,axisY:0) == 0)
        let first = GameAction(kind:.move,x:1), next = GameAction(kind:.score,value:1), added = GameAction(kind:.rotate,value:90)
        var rule = GameRule(actions:[first,next]); var graph = GameGraph.chain(rule); rule.actions.append(added)
        precondition(graph.insertAction(added.id,after:first.id,in:rule))
        precondition(graph.wires.contains(GameWire(from:first.id,to:added.id)))
        precondition(graph.wires.contains(GameWire(from:added.id,to:next.id)))
        try graph.validate(rule:rule)
        precondition(!graph.insertAction(added.id,after:first.id,in:rule))
        let condition = GameAction(kind:.ifScore,value:1), orphan = GameAction(kind:.show)
        rule.actions += [condition,orphan]
        precondition(!graph.insertAction(orphan.id,after:condition.id,in:rule))
        print("PASS: signed grid snapping, bounded transforms, projected-axis drag, node insertion and branch safety")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("netvista-workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for dimension in [GameDimension.twoD,.threeD] {
            var player = GameObject(name:"Player",kind:.block)
            player.rules = GameBehaviourRecipe.movement.rules(for:player) + GameBehaviourRecipe.reset.rules(for:player)
            var spinner = GameObject(name:"Spinner",kind:.coin,x:8)
            spinner.rules = GameBehaviourRecipe.spin.rules(for:spinner) + GameBehaviourRecipe.interact.rules(for:spinner)
            var patrol = GameObject(name:"Patrol",kind:.block,x:-5,y:4)
            patrol.rules = GameBehaviourRecipe.patrol.rules(for:patrol)
            var pickup = GameObject(name:"Pickup",kind:.coin,x:0.5)
            pickup.rules = GameBehaviourRecipe.pickup.rules(for:pickup,contact:player.id)
            precondition(GameBehaviourRecipe.pickup.rules(for:pickup).isEmpty)
            var wall = GameObject(name:"Wide collider",kind:.block,x:3)
            wall.scaleX = 4; wall.scaleY = 2; wall.scaleZ = 4; wall.colour = "#00FF80"; wall.solid = true
            var game = GameProject.starter(dimension); game.objects = [player,spinner,patrol,pickup,wall]; try game.validate()
            let path = root.appendingPathComponent("\(dimension.rawValue).netvistagame")
            try game.save(to:path); let loaded = try GameProject.open(path); precondition(loaded == game)
            var old = try JSONSerialization.jsonObject(with:JSONEncoder().encode(game)) as! [String:Any]
            old["version"] = 3
            var oldObjects = old["objects"] as! [[String:Any]]
            for i in oldObjects.indices { for key in ["scaleX","scaleY","scaleZ","colour"] { oldObjects[i].removeValue(forKey:key) } }
            old["objects"] = oldObjects
            let oldPath = root.appendingPathComponent("legacy-\(dimension.rawValue).netvistagame")
            try JSONSerialization.data(withJSONObject:old).write(to:oldPath)
            let migrated = try GameProject.open(oldPath)
            precondition(migrated.version == 4 && migrated.objects.allSatisfy { $0.scaleX == 1 && $0.scaleY == 1 && $0.scaleZ == 1 && $0.colour == nil })
            var bad = game; bad.objects[0].scaleY = 0
            do { try bad.validate(); preconditionFailure("Zero dimension accepted") } catch {}
            bad = game; bad.objects[0].colour = "red;unexpected"
            do { try bad.validate(); preconditionFailure("Invalid colour accepted") } catch {}
            var collision = GamePlayState(objects:[player,wall],dimension:dimension)
            for _ in 0..<120 { collision.step(keys:["d"],seconds:1.0/60) }
            precondition(collision.objects[0].x <= 0.5 && collision.objects[0].x > 0.3,"Colliders must follow the stretched width")
            var state = GamePlayState(objects:game.objects,dimension:dimension)
            let frames: [[String]] = (0..<300).map { frame in frame < 20 ? ["d"] : frame == 40 ? ["e"] : frame == 80 ? ["space"] : [] }
            for keys in frames { state.step(keys:Set(keys),seconds:1.0/60) }
            precondition(state.score == 1 && state.destroyed.contains(pickup.id))
            precondition(state.objects[0].x == 0 && !state.objects[1].visible)
            precondition(state.objects[1].rotation > 290)
            precondition(state.variables["patrol_"+patrol.id.uuidString] == 0)
            precondition(abs(state.objects[2].x - (-3)) < 0.1, "Patrol must reverse every two seconds")
            let expected: [String:Any] = ["frames":frames,"score":state.score,"destroyed":state.destroyed.map(\.uuidString).sorted(),"objects":try JSONSerialization.jsonObject(with:JSONEncoder().encode(state.objects))]
            for target in [GameExportTarget.threeJS,.python] {
                let folder = root.appendingPathComponent(dimension.rawValue + (target == .threeJS ? "-js" : "-python"))
                try GameExporter.export(game,to:folder,target:target)
                try JSONSerialization.data(withJSONObject:expected).write(to:folder.appendingPathComponent("expected.json"))
            }
            print("PASS: \(dimension.rawValue) six connected recipes, gameplay, save/reopen and both source export targets")
        }
        print("EXPORT_FIXTURES=\(root.path)")
    }
}
