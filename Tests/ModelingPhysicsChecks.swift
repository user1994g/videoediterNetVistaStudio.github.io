import Foundation
import SceneKit

@main struct ModelingPhysicsChecks {
    static func main() throws {
        var settings = ModelingPhysicsSettings(); settings.mode = .dynamic
        try settings.validate()
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(ModelingPhysicsSettings.self,from:data)
        precondition(restored == settings)
        var document = ModelingDocument()
        var object = ModelingObject(name:"Physics cube",mesh:.primitive("Cube"))
        object.position.y = 3; object.physics = settings; document.objects = [object]
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".netvistamodel")
        defer { try? FileManager.default.removeItem(at:saved) }
        try document.save(saved)
        let reopened = try ModelingDocument.open(saved)
        precondition(reopened == document && reopened.objects[0].physics == settings,"Physics settings must persist with the native project")
        var legacy = object; legacy.physics = nil
        let legacyData = try JSONEncoder().encode(legacy)
        let migrated = try JSONDecoder().decode(ModelingObject.self,from:legacyData)
        precondition(migrated.physics == nil,"Older models without physics must open without enabling simulation")
        for invalid in [Double.nan,-1,10001] {
            var bad = settings; bad.mass = invalid
            do { try bad.validate(); preconditionFailure("Invalid mass accepted") } catch {}
        }
        var bad = settings; bad.restitution = .infinity
        do { try bad.validate(); preconditionFailure("Non-finite bounce accepted") } catch {}
        let scene = SCNScene()
        let cube = SCNNode(geometry:SCNBox(width:1,height:1,length:1,chamferRadius:0))
        cube.position = SCNVector3(0,3,0); scene.rootNode.addChildNode(cube)
        let original = cube.transform
        let id = UUID(), preview = ModelingPhysicsPreview()
        try preview.configure(participants:[.init(id:id,node:cube,settings:settings)])
        precondition(preview.dynamicBodyCount == 1 && preview.state == .stopped)
        preview.step(frames:30)
        precondition(cube.position.y < 2.5 && cube.position.y > 0.4,"Dynamic body must fall under real gravity")
        preview.step(frames:120)
        precondition((0.45...0.8).contains(Double(cube.position.y)),"Cube must collide with and rest above the ground")
        let paused = cube.transform, pausedTime = preview.time
        RunLoop.current.run(until:Date().addingTimeInterval(0.08))
        precondition(SCNMatrix4EqualToMatrix4(cube.transform,paused) && preview.time == pausedTime,"Paused preview must stay frozen")
        precondition(preview.transformedPoint(for:id,x:0,y:3,z:0)!.y < 0.8,"Bake delta must include simulated translation")
        preview.reset()
        precondition(SCNMatrix4EqualToMatrix4(cube.transform,original) && preview.time == 0 && preview.state == .stopped)
        precondition(abs(preview.transformedPoint(for:id,x:0,y:3,z:0)!.y-3) < 1e-6,"Reset must restore the Bake delta without a hidden gravity step")
        preview.play(); RunLoop.current.run(until:Date().addingTimeInterval(0.15)); preview.pause()
        precondition(preview.time > 0 && cube.position.y < 3,"Play must advance the preview")
        preview.end()
        precondition(SCNMatrix4EqualToMatrix4(cube.transform,original) && preview.bodyCount == 0)
        settings.affectedByGravity = false
        try preview.configure(participants:[.init(id:id,node:cube,settings:settings)])
        preview.step(frames:60)
        precondition(abs(cube.position.y-3) < 0.0001,"Gravity-disabled body must remain still")
        preview.end(); settings.mode = .static
        try preview.configure(participants:[.init(id:id,node:cube,settings:settings)])
        preview.step(frames:60)
        precondition(SCNMatrix4EqualToMatrix4(cube.transform,original) && preview.dynamicBodyCount == 0)
        preview.end()
        // An authored static model must be a real collider, not just the floor.
        let platform = SCNNode(geometry:SCNBox(width:4,height:1,length:4,chamferRadius:0))
        platform.position = SCNVector3(0,1,0); scene.rootNode.addChildNode(platform)
        let platformID = UUID(), staticSettings = settings
        settings.mode = .dynamic; settings.affectedByGravity = true; cube.position.y = 4
        try preview.configure(participants:[.init(id:id,node:cube,settings:settings),.init(id:platformID,node:platform,settings:staticSettings)])
        preview.step(frames:120)
        precondition((1.95...2.15).contains(Double(cube.position.y)),"The falling body must collide with another model's static collider")
        precondition(abs(platform.position.y-1) < 1e-8,"Static model collider must not move")
        var invalidParticipant = settings; invalidParticipant.friction = 2
        let beforeInvalid = cube.transform
        do { try preview.configure(participants:[.init(id:id,node:cube,settings:invalidParticipant)]); preconditionFailure("Invalid settings accepted") } catch {}
        precondition(SCNMatrix4EqualToMatrix4(cube.transform,beforeInvalid),"Rejected reconfiguration must preserve the active preview")
        preview.end()
        precondition(document == reopened,"Running previews must not change authored meshes/settings")
        print("PASS: bounded settings/native persistence and old-file migration, real gravity/floor/model collision, deterministic stepping, pause/play/reset, gravity-off, static bodies, Bake delta and unmodified authored nodes")
    }
}
