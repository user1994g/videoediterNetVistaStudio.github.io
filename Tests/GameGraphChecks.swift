import Foundation

@main struct GameGraphChecks {
    static func main() throws {
        for dimension in [GameDimension.twoD,.threeD] {
            var game = GameProject.starter(dimension)
            var object = GameObject(name:"Character",kind:.sprite)
            let condition = GameAction(kind:.ifKey,value:1,text:"movement")
            let move = GameAction(kind:.keyboard,value:4)
            let yes = GameAction(kind:.score,value:2)
            let no = GameAction(kind:.score,value:-1)
            let disconnected = GameAction(kind:.score,value:1000)
            var rule = GameRule(actions:[disconnected,no,yes,condition,move])
            rule.graph = GameGraph(wires:[.init(from:rule.id,to:condition.id),.init(from:condition.id,port:.yes,to:move.id),.init(from:move.id,to:yes.id),.init(from:condition.id,port:.no,to:no.id)])
            object.rules = [rule]; object.spriteSheet = GameSpriteSheet(columns:4,rows:2,frames:8,fps:12); game.objects = [object]
            try game.validate()
            var runtime = GamePlayState(objects:game.objects,dimension:dimension)
            runtime.step(keys:["d"],seconds:0.05); precondition(runtime.score == 2 && runtime.objects[0].x > 0)
            runtime.step(keys:[],seconds:0.05); precondition(runtime.score == 1,"False branch must execute; disconnected nodes must not run")
            var loop = rule; loop.graph?.wires.append(.init(from:yes.id,to:condition.id))
            do { try loop.graph!.validate(rule:loop); preconditionFailure("Cycle accepted") } catch {}
            var missing = rule; missing.graph?.wires.append(.init(from:yes.id,to:UUID()))
            do { try missing.graph!.validate(rule:missing); preconditionFailure("Missing node accepted") } catch {}
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("graph-"+UUID().uuidString+".netvistagame")
            defer { try? FileManager.default.removeItem(at:path) }
            try game.save(to:path); let loaded = try GameProject.open(path); precondition(loaded == game)
            let export = FileManager.default.temporaryDirectory.appendingPathComponent("graph-export-"+UUID().uuidString)
            do { try GameExporter.export(game,to:export,target:.threeJS); preconditionFailure("Unsupported sprite animation export should explain limitation") } catch {}
            precondition(!FileManager.default.fileExists(atPath:export.path))
            print("PASS: \(dimension.rawValue) graph branching, wire order, disconnected nodes, invalid edges, save/load, export limitation")
        }
        let set = GameAction(kind:.setVariable,value:5,text:"health")
        let add = GameAction(kind:.addVariable,value:-1,text:"health")
        let test = GameAction(kind:.ifVariable,value:4,text:"health")
        let walk = GameAction(kind:.walk,value:1)
        let stop = GameAction(kind:.stopAnimation)
        var rule = GameRule(actions:[set,add,test,walk,stop])
        rule.graph = GameGraph(wires:[.init(from:rule.id,to:set.id),.init(from:set.id,to:add.id),.init(from:add.id,to:test.id),.init(from:test.id,port:.yes,to:walk.id),.init(from:test.id,port:.no,to:stop.id)])
        var actor = GameObject(name:"Actor",kind:.block); actor.rules = [rule,GameRule(event:.keyPressed,key:"space",actions:[GameAction(kind:.score,value:1)])]
        var runtime = GamePlayState(objects:[actor]); runtime.step(keys:["space"],seconds:0.05); runtime.step(keys:["space"],seconds:0.05)
        precondition(runtime.variables["health"] == 4 && runtime.animations[actor.id] == "walk" && runtime.score == 1)
        runtime.step(keys:[],seconds:0.05); runtime.step(keys:["space"],seconds:0.05); precondition(runtime.score == 2)
        try GameCharacterRig.humanoid().validate()
        var rig = GameCharacterRig.humanoid(); rig.joints[0].parent = 2
        do { try rig.validate(); preconditionFailure("Cyclic rig accepted") } catch {}
        // Cross-runtime fixture includes graph variables, key edges and animations without renderer dependencies.
        let folder = URL(fileURLWithPath:"/private/tmp/netvista-graph-parity",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var project = GameProject.starter(.twoD); project.objects = [actor]
        try JSONEncoder().encode(project).write(to:folder.appendingPathComponent("game.json"))
        print("PASS: variables, key-press edges, animation commands, rig validation")
    }
}
