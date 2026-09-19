import Foundation
import CoreGraphics
import ImageIO

@main struct GameProjectChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("netvista-game-check-" + UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        // Supply an output directory to retain exports for JS/Python integration checks.
        let keep = CommandLine.arguments.count > 1
        defer { if !keep { try? fm.removeItem(at:root) } }
        let folder = root.appendingPathComponent("Source/textures"); try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        let context = CGContext(data:nil,width:16,height:16,bitsPerComponent:8,bytesPerRow:64,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:1,green:0.25,blue:0.1,alpha:1)); context.fill(CGRect(x:0,y:0,width:16,height:16))
        let png = NSMutableData(); let encoder = CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(encoder,context.makeImage()!,nil); precondition(CGImageDestinationFinalize(encoder)); let texture = png as Data
        try texture.write(to:folder.appendingPathComponent("sprite.png"))
        let obj = "v -1 -1 0\nv 1 -1 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0.5 1\nf -3/1 -2/2 -1/3\n"
        try Data(obj.utf8).write(to:root.appendingPathComponent("Source/model.obj"))
        try Data("data only".utf8).write(to:root.appendingPathComponent("Source/.hidden"))
        let mesh = try GameMesh.obj(Data(obj.utf8)); precondition(mesh.positions.count == 9 && mesh.uv.count == 6 && mesh.positions.max()! == 0.5)
        for malformed in ["v 0 0 0\nf 1 2 3", "v nan 0 0\nf 1 1 1", "v 0 0 0\nf 0 0 0"] {
            do { _ = try GameMesh.obj(Data(malformed.utf8)); preconditionFailure("Invalid OBJ accepted") } catch {}
        }
        for dimension in [GameDimension.twoD,.threeD] {
            var game = GameProject.starter(dimension); precondition(game.objects.isEmpty); try game.validate()
            let blank = root.appendingPathComponent("blank.netvistagame"); try game.save(to:blank); let restored = try GameProject.open(blank); precondition(restored.objects.isEmpty)
            try game.importFiles([root.appendingPathComponent("Source")]); precondition(game.assets.count == 3)
            precondition(game.assets.allSatisfy { $0.path.split(separator:"/")[1] == "Source" },"Canonical paths must preserve exactly the chosen folder name")
            var player = GameObject(name:"My sprite",kind:.sprite,x:-2,y:0,imageID:game.assets.first(where:{$0.path.hasSuffix("sprite.png")})!.id)
            var wall = GameObject(name:"Wall",kind:.block,x:0); wall.solid = true
            var pickup = GameObject(name:"Pickup",kind:.coin,x:-2,y:2)
            if dimension == .threeD { pickup.y = 0; pickup.z = -2 }
            player.rules = [GameRule(event:.start,actions:[GameAction(kind:.opacity,value:0.75)]),GameRule(actions:[GameAction(kind:.keyboard,value:4),GameAction(kind:.rotate,value:90)]),GameRule(event:.timer,interval:0.5,actions:[GameAction(kind:.score,value:2)])]
            pickup.rules = [GameRule(event:.touch,otherID:player.id,actions:[GameAction(kind:.score,value:10),GameAction(kind:.destroy)])]
            var probe = GameObject(name:"Animated block",kind:.block,x:-6,y:3)
            probe.rules = [GameRule(event:.start,actions:[GameAction(kind:.position,x:-6,y:3,z:1),GameAction(kind:.scale,value:1.5)]),GameRule(event:.keyHeld,key:"space",actions:[GameAction(kind:.hide)]),GameRule(event:.timer,interval:0.5,actions:[GameAction(kind:.show),GameAction(kind:.opacity,value:0.6)]),GameRule(actions:[GameAction(kind:.move,x:0.1,y:0.2,z:0.1)])]
            game.objects = [player,wall,pickup,probe]
            if dimension == .threeD { var model = GameObject(name:"Imported model",kind:.model,x:3); model.modelID = game.assets.first(where:{$0.path.hasSuffix("model.obj")})!.id; game.objects.append(model) }
            let file = root.appendingPathComponent("\(dimension.rawValue).netvistagame"); try game.save(to:file); let loaded = try GameProject.open(file); precondition(loaded == game)
            var malformed = game; malformed.version = 99
            do { try malformed.save(to:file); preconditionFailure("Future version accepted") } catch {}
            let preserved = try GameProject.open(file); precondition(preserved == game)
            malformed = game; malformed.assets[0].path = "../outside"
            do { try malformed.validate(); preconditionFailure("Unsafe path accepted") } catch {}
            malformed = game; malformed.objects[0].rules[0].actions[0].targetID = UUID()
            do { try malformed.validate(); preconditionFailure("Missing target accepted") } catch {}
            let before = game
            do { try game.importFiles([folder.appendingPathComponent("sprite.png"),root.appendingPathComponent("missing")]); preconditionFailure("Invalid import accepted") } catch {}
            precondition(game == before)
            var runtime = GamePlayState(objects:game.objects,dimension:dimension)
            for _ in 0..<120 { runtime.step(keys:["d"],seconds:1.0/60) }
            precondition(runtime.objects[0].x <= -1 && runtime.objects[0].opacity == 0.75)
            precondition(game == before,"Play must not modify authoring state")
            runtime.objects[0].x = -2
            for _ in 0..<30 { runtime.step(keys:["w"],seconds:1.0/60) }
            precondition(runtime.destroyed.contains(pickup.id))
            let destroyedCount = runtime.destroyed.count; runtime.step(keys:[],seconds:0.05); precondition(runtime.destroyed.count == destroyedCount)
            var parity = GamePlayState(objects:game.objects,dimension:dimension)
            let frames: [[String]] = (0..<180).map { $0 < 30 ? ["w"] : $0 < 90 ? ["d"] : $0 < 100 ? ["space"] : [] }
            for keys in frames { parity.step(keys:Set(keys),seconds:1.0/60) }
            let expected: [String:Any] = ["frames":frames,"score":parity.score,"destroyed":parity.destroyed.map(\.uuidString).sorted(),"objects":try JSONSerialization.jsonObject(with:JSONEncoder().encode(parity.objects))]
            for target in [GameExportTarget.threeJS,.python] {
                let destination = root.appendingPathComponent(dimension.rawValue + (target == .threeJS ? "-js" : "-python"))
                try GameExporter.export(game,to:destination,target:target)
                try JSONSerialization.data(withJSONObject:expected,options:[.sortedKeys]).write(to:destination.appendingPathComponent("expected.json"))
                do { try GameExporter.export(game,to:destination,target:target); preconditionFailure("Existing export overwritten") } catch {}
                precondition(fm.fileExists(atPath:destination.appendingPathComponent("README.md").path))
            }
            print("PASS: \(dimension.rawValue) empty scenes, embedded assets, OBJ, save/load, invalid files/targets, collision, blocks, exports")
        }
        // Legacy version-one projects retain demo behaviour through explicit migration.
        var legacy = GameProject.starter(.threeD); legacy.objects = [GameObject(name:"Player",kind:.player,x:0,y:2),GameObject(name:"Coin",kind:.coin)]
        var old = try JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy)) as! [String:Any]; old["version"] = 1
        var oldObjects = old["objects"] as! [[String:Any]]; for i in oldObjects.indices { ["rules","z","solid"].forEach { oldObjects[i].removeValue(forKey:$0) } }; old["objects"] = oldObjects
        let oldURL = root.appendingPathComponent("legacy.netvistagame"); try JSONSerialization.data(withJSONObject:old).write(to:oldURL)
        let migrated = try GameProject.open(oldURL); precondition(migrated.version == 3 && migrated.objects[0].z == -2 && !migrated.objects[0].rules.isEmpty)
        try fm.removeItem(at:root.appendingPathComponent("Source"))
        let portable = try GameProject.open(root.appendingPathComponent("3D.netvistagame")); precondition(portable.assets.contains { $0.data == texture })
        print("PASS: version-one migration and assets survive deletion of source folder")
        if keep { print("EXPORT_FIXTURES=\(root.path)") }
    }
}
