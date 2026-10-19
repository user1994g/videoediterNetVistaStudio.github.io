// Simulator-only native QA. Production build_ipa.sh does not compile Tests.
import UIKit
import SceneKit
import CoreImage

@MainActor enum GameWorkspaceChecks {
    static func run(controller:GameWorkspaceViewController,documents:URL) async throws {
        func require(_ condition:@autoclosure()->Bool,_ message:String) throws { if !condition() { throw GameProjectError.invalid("Game workspace: "+message) } }
        func views(_ view:UIView)->[UIView] { [view]+view.subviews.flatMap(views) }
        func button(_ view:UIView,_ id:String) throws -> UIButton { guard let value = views(view).first(where: { $0.accessibilityIdentifier == "game."+id }) as? UIButton else { throw GameProjectError.invalid("Missing native Game button "+id) }; return value }
        controller.permitsEditing = { true }; controller.loadViewIfNeeded()
        defer { controller.stopPlay() }
        controller.view.frame = CGRect(x:0,y:0,width:390,height:844)
        try controller.session.load(.starter(.twoD)); controller.refreshAccess(); controller.view.layoutIfNeeded()
        try require(controller.session.project.objects.isEmpty,"New scenes contain no forced demo objects")
        controller.addObject(.player); let actorID = controller.session.selectedID!
        try controller.session.updateSelected { $0.name = "Actor"; $0.colour = "#ff3344"; $0.rules = GameBehaviourRecipe.movement.rules(for:$0) }
        controller.refreshAccess()
        let history = controller.session.undoCount
        controller.move(actorID,x:0,y:0,z:0,phase:0)
        controller.move(actorID,x:1.3,y:1.2,z:0,phase:1)
        controller.move(actorID,x:2.3,y:1.2,z:0,phase:2)
        try require(controller.session.selectedObject?.x == 2.5 && controller.session.selectedObject?.y == 1,"Native drag uses snapped world coordinates")
        try require(controller.session.undoCount == history+1,"One drag creates exactly one Undo")
        try button(controller.view,"undo").sendActions(for:.touchUpInside)
        try require(controller.session.selectedObject?.x == 0,"Native Undo restores movement")
        controller.move(actorID,x:0,y:0,z:0,phase:0); controller.move(actorID,x:4,y:4,z:0,phase:1); controller.move(actorID,x:4,y:4,z:0,phase:-1)
        try require(controller.session.selectedObject?.x == 0 && controller.session.canRedo,"Cancelled drag preserves project and redo branch")
        try button(controller.view,"redo").sendActions(for:.touchUpInside)
        try require(controller.session.selectedObject?.x == 2.5,"Native Redo still works after cancelled drag")
        controller.undo()
        let beforeInvalid = controller.session.project, historyBeforeInvalid = controller.session.undoCount
        do { try controller.session.updateSelected { $0.opacity = -1 }; throw GameProjectError.invalid("Invalid game edit was accepted") }
        catch GameProjectError.invalid(let reason) where reason != "Invalid game edit was accepted" {}
        try require(controller.session.project == beforeInvalid && controller.session.undoCount == historyBeforeInvalid,"Failed validation is atomic and does not consume Undo")

        var wall = GameObject(name:"Wall",kind:.block,x:1.7); wall.solid = true
        try controller.session.add(wall); controller.select(actorID)
        let texture = UIGraphicsImageRenderer(size:CGSize(width:8,height:8)).image { c in UIColor.systemGreen.setFill(); c.fill(CGRect(x:0,y:0,width:8,height:8)) }.pngData()!
        let asset = GameAsset(path:"textures/leaf.png",data:texture)
        try controller.session.edit { $0.assets.append(asset) }
        let gameFile = documents.appendingPathComponent("native-game-roundtrip.netvistagame")
        try controller.session.project.save(to:gameFile)
        let reopened = try GameProject.open(gameFile)
        try require(reopened == controller.session.project && reopened.assets.first?.data == texture,"Desktop-native v4 project preserves rules and embedded image bytes")
        let beforeNew = controller.session.project, historyBeforeNew = controller.session.undoCount
        controller.newDocument(.threeD)
        try require(controller.session.project.dimension == .threeD && controller.session.project.objects.isEmpty && controller.session.project.assets.isEmpty,"New creates a genuinely blank chosen-dimension scene")
        try require(controller.session.undoCount == historyBeforeNew+1,"New keeps the previous document as one Undo step")
        try button(controller.view,"undo").sendActions(for:.touchUpInside)
        try require(controller.session.project == beforeNew && controller.session.project.assets.first?.data == texture && !controller.session.project.objects[0].rules.isEmpty,"Undo New restores exact objects, blocks and embedded image bytes")
        try button(controller.view,"redo").sendActions(for:.touchUpInside)
        try require(controller.session.project.dimension == .threeD && controller.session.project.objects.isEmpty,"Redo New restores blank scene")
        try button(controller.view,"undo").sendActions(for:.touchUpInside)
        try button(controller.view,"open").sendActions(for:.touchUpInside)
        try await Task.sleep(nanoseconds:350_000_000)
        guard let warning = controller.presentedViewController as? UIAlertController else { throw GameProjectError.invalid("Files Open silently replaced the workspace without its save warning") }
        try require(warning.title == "Open another game?" && warning.actions.contains { $0.title == "Cancel" } && warning.actions.contains { $0.title == "Save current copy first…" },"Files Open offers Cancel and save-current-first before replacing work")
        try require(controller.session.project == beforeNew,"Showing Open warning does not change the document")
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in warning.dismiss(animated:false) { continuation.resume() } }
        try controller.openProject(url:gameFile); controller.select(actorID)
        controller.togglePlay(); controller.togglePause()
        for _ in 0..<90 { controller.advance(seconds:1/60,keys:["right"]) }
        guard let actor = controller.playState?.objects.first(where: { $0.id == actorID }) else { throw GameProjectError.invalid("Native player did not start") }
        try require(actor.x > 0.5 && actor.x <= 0.71,"Actual shared runtime moves the actor and stops at its solid collider")
        try require(controller.session.project == reopened,"Play never mutates the saved editing scene")
        controller.restartPlay(); try require(controller.playState?.objects.first(where: { $0.id == actorID })?.x == 0,"Restart restores original runtime state")
        controller.stopPlay(); try require(!controller.isPlaying && controller.viewport.displayedObjects == controller.session.project.objects,"Stop restores document viewport")

        var condition = GameAction(kind:.ifVariable,value:5,text:"health"), yes = GameAction(kind:.score,value:3), no = GameAction(kind:.score,value:90)
        condition.targetID = actorID; yes.targetID = actorID; no.targetID = actorID
        let set = GameAction(kind:.setVariable,value:8,text:"health"), disconnected = GameAction(kind:.score,value:1000)
        var rule = GameRule(event:.start,actions:[set,condition,yes,no,disconnected])
        rule.graph = GameGraph(wires:[GameWire(from:rule.id,to:set.id),GameWire(from:set.id,to:condition.id),GameWire(from:condition.id,port:.yes,to:yes.id),GameWire(from:condition.id,port:.no,to:no.id)])
        try controller.session.updateSelected { $0.rules = [rule] }; controller.refreshAccess()
        controller.togglePlay(); controller.togglePause()
        try require(controller.playState?.score == 3 && controller.playState?.variables["health"] == 8,"Connected native Yes/No blocks execute, disconnected blocks do not")
        controller.stopPlay()
        let graphView = controller.graph; graphView.rule = rule
        try require(graphView.nodeRect(condition.id) != nil,"Every actual action has a visible block hit rectangle")
        let originalGraph = controller.session.selectedObject!.rules[0]
        do { try controller.session.connect(rule:0,from:yes.id,port:.next,to:condition.id); throw GameProjectError.invalid("Loop was accepted") }
        catch GameProjectError.invalid(let reason) where reason != "Loop was accepted" {}
        try require(controller.session.selectedObject!.rules[0] == originalGraph,"Invalid cyclic wire is rejected atomically")
        try controller.session.duplicate(); let copyID = controller.session.selectedID!
        try require(copyID != actorID && controller.session.selectedObject?.rules[0].id != rule.id,"Duplicate rewrites object, event and block UUIDs")
        try controller.session.project.validate()
        try controller.session.deleteSelected(); try require(!controller.session.project.objects.contains { $0.id == copyID },"Delete removes selected object")
        controller.undo(); try require(controller.session.project.objects.contains { $0.id == copyID },"Object deletion is undoable")
        controller.redo(); controller.select(actorID)

        guard let panelTabs = views(controller.view).compactMap({ $0 as? UISegmentedControl }).first else { throw GameProjectError.invalid("Missing native game panel tabs") }
        panelTabs.selectedSegmentIndex = 0; panelTabs.sendActions(for:.valueChanged); controller.view.layoutIfNeeded()
        let wallSelection = try button(controller.view,"object.select."+wall.id.uuidString)
        try require(wallSelection.bounds.width >= 44 && wallSelection.bounds.height >= 44,"Object selection accessory has a real44-point hit target")
        wallSelection.sendActions(for:.touchUpInside)
        try require(controller.session.selectedID == wall.id && panelTabs.selectedSegmentIndex == 2,"Object accessory actually selects its object and opens its properties")
        controller.select(actorID)

        for size in [CGSize(width:390,height:844),CGSize(width:844,height:390),CGSize(width:1024,height:768)] {
            controller.view.frame.size = size; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); controller.viewport.fit()
            try require(controller.viewport.bounds.width > 150 && controller.viewport.bounds.height >= 110,"Usable game scene at \(size)")
            for control in views(controller.view).filter({ $0 is UIButton || $0 is UISegmentedControl }) where !control.isHidden {
                try require(control.bounds.height >= 43.9,"Native touch target is at least44points at \(size): \(control.accessibilityIdentifier ?? String(describing:type(of:control)))")
            }
            let point = CGPoint(x:0.2,y:0.2), roundTrip = controller.viewport.worldPoint(controller.viewport.viewPoint(point))
            try require(abs(point.x-roundTrip.x) < 0.001 && abs(point.y-roundTrip.y) < 0.001,"Touch world transform is invertible")
            let hit = controller.viewport.hit(controller.viewport.viewPoint(.zero))
            try require(hit == actorID,"Touch selection hits the actual object at every device size")
            let image = UIGraphicsImageRenderer(size:size).image { _ in controller.view.drawHierarchy(in:controller.view.bounds,afterScreenUpdates:true) }
            try image.pngData()?.write(to:documents.appendingPathComponent("game-\(Int(size.width))x\(Int(size.height)).png"))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let canvasImage = UIGraphicsImageRenderer(size:controller.viewport.bounds.size,format:format).image { _ in controller.viewport.drawHierarchy(in:controller.viewport.bounds,afterScreenUpdates:true) }
            guard let pixels = CIImage(image:canvasImage) else { throw GameProjectError.invalid("Missing displayed native game pixels") }
            let p = controller.viewport.viewPoint(.zero); var rgb = [UInt8](repeating:0,count:4)
            CIContext().render(pixels,toBitmap:&rgb,rowBytes:4,bounds:CGRect(x:floor(p.x),y:floor(controller.viewport.bounds.height-p.y),width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
            try require(rgb[0] > 180 && rgb[1] < 120 && rgb[2] < 130,"Actual displayed scene contains the red actor, not a blank viewport at \(size)")
        }
        let deniedState = controller.session.project; controller.permitsEditing = { false }; controller.refreshAccess(); controller.addObject(.coin)
        try require(controller.session.project == deniedState && !controller.viewport.canEdit,"Account gate blocks edits without a bypass")
        controller.permitsEditing = { true }; controller.refreshAccess()

        let exportRoot = documents.appendingPathComponent("native-game-export-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:exportRoot,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:exportRoot) }
        for (name,target) in [("javascript",GameExportTarget.threeJS),("python",GameExportTarget.python)] {
            let destination = exportRoot.appendingPathComponent(name)
            try GameExporter.export(controller.session.project,to:destination,target:target)
            let restoredJSON = try JSONSerialization.jsonObject(with:Data(contentsOf:destination.appendingPathComponent("game.json"))) as? [String:Any]
            try require((restoredJSON?["objects"] as? [Any])?.count == controller.session.project.objects.count,"Real \(name) export contains document objects")
            try require(FileManager.default.fileExists(atPath:destination.appendingPathComponent("assets/textures/leaf.png").path),"Real \(name) export includes imported pixels")
        }

        var threeD = GameProject.starter(.threeD)
        let mesh = try GameMesh.obj(Data("v -1 -1 0\nv 1 -1 0\nv 0 1 0\nf 1 2 3\n".utf8))
        let model = GameAsset(path:"models/triangle.nvmesh",data:try JSONEncoder().encode(mesh)); threeD.assets = [model]
        var character = GameObject(name:"Character",kind:.model,size:4); character.modelID = model.id; character.rig = .humanoid(); character.rules = [GameRule(event:.start,actions:[GameAction(kind:.walk,value:1)])]; threeD.objects = [character]
        try controller.session.load(threeD); controller.select(character.id); controller.viewport.fit()
        controller.togglePlay(); controller.togglePause(); for _ in 0..<8 { controller.advance(seconds:1/60) }
        let limb = controller.viewport.sceneView.scene?.rootNode.childNode(withName:"Left thigh",recursively:true)
        try require(limb != nil && abs(limb!.eulerAngles.x) > 0.01,"Actual shared weighted character rig animates in the native 3D viewport")
        controller.stopPlay()
        do { try GameExporter.export(threeD,to:exportRoot.appendingPathComponent("unsupported-animation"),target:.threeJS); throw GameProjectError.invalid("Unsupported animation export was accepted") }
        catch GameProjectError.invalid(let reason) where reason != "Unsupported animation export was accepted" {}
        try require(!FileManager.default.fileExists(atPath:exportRoot.appendingPathComponent("unsupported-animation").path),"Unsupported source animation export fails without a partial game")
        try Data("PASS · native empty2D/3D, editing/history/atomic validation, connected rule branches, actual collisions, embedded asset save/load, JS/Python exports, weighted rig playback, phone/tablet layout, account gate\n".utf8).write(to:documents.appendingPathComponent("game-workspace-result.txt"))
    }
}
