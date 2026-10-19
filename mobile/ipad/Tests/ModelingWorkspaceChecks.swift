import UIKit
import SceneKit
import CoreImage
import UniformTypeIdentifiers

/// Isolated QA-app checks. All picks use SceneKit's actual rendered mesh hit
/// test and all sculpt/vertex edits enter through the production touch adapter.
@MainActor enum ModelingWorkspaceChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {throw ModelingError.invalid("Native modeling UI check: "+message)}
    }
    static func descendants(_ view: UIView) -> [UIView] {[view]+view.subviews.flatMap(descendants)}
    static func button(_ controller: ModelingWorkspaceViewController, _ id: String) throws -> UIButton {
        guard let result = descendants(controller.view).first(where:{$0.accessibilityIdentifier == "model."+id}) as? UIButton else {throw ModelingError.invalid("Missing native modeling button "+id)}
        return result
    }
    static func pause() async {try? await Task.sleep(nanoseconds:350_000_000)}
    static func run(controller: ModelingWorkspaceViewController, documents: URL) async throws {
        controller.loadViewIfNeeded(); controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let viewport = controller.viewport
        try check(viewport.bounds.width > 100 && viewport.bounds.height > 100,"Real native viewport fits the window")
        var blank = ModelingDocument(); blank.name = "Native sculpture"
        try controller.loadDocument(blank)
        try controller.addPrimitive("Cube")
        try check(controller.document.objects.count == 1 && controller.selectedObject?.mesh.faces.count == 6,"Add creates an actual editable shared cube")
        let id = controller.selectedID!, cube = controller.document
        viewport.setDirection("Right"); await pause()
        func screen(_ p: ModelPoint) -> CGPoint {let value = viewport.projectPoint(p.mobileSCN); return CGPoint(x:CGFloat(value.x),y:CGFloat(value.y))}
        let side = screen(.init(x:0.5))
        guard let hit = viewport.surfaceHit(side) else {throw ModelingError.invalid("SceneKit cannot hit the visible right cube side at \(side)")}
        try check(hit.node.name == id.uuidString && abs(Double(hit.worldCoordinates.x)-0.5) < 0.01 && Double(hit.worldNormal.x) > 0.9,
                  "Picking returns the actual touched side and its geometric surface normal, not the ground")
        try check(controller.geometryNodes[id]?.geometry?.elements.first?.primitiveCount == 12,"SceneKit uploads twelve real cube triangles")

        controller.setMode(1); await pause(); controller.pickSurface(side)
        try check(controller.selectedFaces.count == 1,"Face mode maps a SceneKit triangle to its original editable quad")
        let beforeExtrude = controller.document, history = controller.undoSteps.count
        try button(controller,"topology.extrude").sendActions(for:.touchUpInside)
        try check(controller.selectedObject!.mesh.faces.count == 10 && controller.selectedObject!.mesh.vertices.count == 12,"Native Extrude adds connected walls and a new cap")
        try check(controller.undoSteps.count == history+1,"Topology operation is a single undo step")
        try button(controller,"undo").sendActions(for:.touchUpInside)
        try check(controller.document == beforeExtrude,"Native Undo restores the original topology exactly")
        try button(controller,"redo").sendActions(for:.touchUpInside)
        try check(controller.selectedObject!.mesh.faces.count == 10,"Native Redo restores topology")
        controller.undo(); await pause(); controller.pickSurface(side)
        let beforeCut = controller.document; controller.previewLoop()
        try check(controller.document == beforeCut,"Loop preview is non-destructive")
        try controller.topology("Loop cut")
        try check(controller.selectedObject!.mesh.faces.count > 6,"Shared connected loop cut applies from native face selection")
        controller.undo()

        controller.setMode(3); viewport.setDirection("Right"); await pause()
        let beforeSculpt = controller.document, beforeSculptHistory = controller.undoSteps.count
        controller.surfaceInput(side,phase:0)
        let afterFirstStamp = controller.document
        guard let nearAfterUpload = viewport.surfaceHit(side) else {throw ModelingError.invalid("Near surface disappeared after the first sculpt upload")}
        let alternate = viewport.hitTest(side,options:[.categoryBitMask:1,.searchMode:SCNHitTestSearchMode.closest.rawValue,.backFaceCulling:true])
        try check(Double(nearAfterUpload.worldCoordinates.x) > 0.49,"Successive brush hits use the visible near side after a geometry upload: hit=\(nearAfterUpload.worldCoordinates), normal=\(nearAfterUpload.worldNormal), camera=\(String(describing:viewport.pointOfView?.worldPosition)), ray=\(viewport.unprojectPoint(SCNVector3(Float(side.x),Float(side.y),0)))→\(viewport.unprojectPoint(SCNVector3(Float(side.x),Float(side.y),1))), culled=\(alternate.map { ($0.worldCoordinates,$0.worldNormal) })")
        controller.surfaceInput(CGPoint(x:side.x+4,y:side.y),phase:1); controller.surfaceInput(side,phase:2)
        let sculpted = controller.selectedObject!
        try check(sculpted.mesh.faces.count >= 512 && sculpted.mesh.vertices.contains(where:{$0.x > 0.501}),"Touching the middle of the right side adds working detail and raises actual mesh vertices outwards")
        let rear = sculpted.mesh.vertices.filter { $0.x < -0.49 }
        try check(rear.allSatisfy({abs($0.x+0.5)<0.001}),"Front-only sculpt does not pull the opposite side through the mesh; rear bounds=\(rear.map(\.x).min() ?? 0)…\(rear.map(\.x).max() ?? 0), unexpected=\(rear.filter {abs($0.x+0.5)>=0.001}.prefix(4)), source rear=\(beforeSculpt.objects[0].mesh.vertices.filter {$0.x < -0.49}), first stamp=\(afterFirstStamp.objects[0].mesh.vertices.filter {$0.x < -0.49 && abs($0.x+0.5)>=0.001}.prefix(4))")
        try check(controller.undoSteps.count == beforeSculptHistory+1,"Whole touch sculpt and automatic detail preparation are one Undo")
        controller.undo(); try check(controller.document == beforeSculpt,"Undo restores the coarse source mesh, not just its displayed image")
        await pause(); controller.surfaceInput(side,phase:0); controller.surfaceInput(CGPoint(x:side.x+12,y:side.y),phase:1); controller.surfaceInput(side,phase:3)
        try check(controller.document == beforeSculpt,"Cancelled touch restores the original authored mesh")

        controller.setMode(2); viewport.setDirection("Right"); await pause()
        let nearCorner = screen(.init(x:0.5,y:0.35,z:0.35)); controller.pickSurface(nearCorner)
        try check(controller.selectedVertex != nil,"Vertex mode selects a true source vertex on the touched face")
        let beforeVertex = controller.document, vertexHistory = controller.undoSteps.count
        controller.surfaceInput(nearCorner,phase:0); controller.surfaceInput(CGPoint(x:nearCorner.x+18,y:nearCorner.y-12),phase:2)
        let changed = zip(controller.document.objects[0].mesh.vertices,beforeVertex.objects[0].mesh.vertices).filter {$0 != $1}.count
        try check(changed == 1 && controller.undoSteps.count == vertexHistory+1,"Vertex drag unprojects the screen point and moves exactly one authored vertex in one Undo")
        controller.undo(); try check(controller.document == beforeVertex,"Undo restores a vertex drag exactly")

        controller.setMode(0)
        try button(controller,"duplicate").sendActions(for:.touchUpInside)
        try check(controller.document.objects.count == 2 && controller.selectedID != id,"Duplicate has an independent UUID")
        try controller.renameSelection("Wing · editable")
        try check(controller.selectedObject?.name == "Wing · editable","Rename affects the selected model")
        try controller.editSelected {$0.visible = false}
        try check(controller.geometryNodes[controller.selectedID!] == nil,"Hidden object is removed from the actual viewport and picking")
        try controller.deleteSelection(); try check(controller.document.objects.count == 1,"Delete removes a model")
        controller.undo(); try check(controller.document.objects.count == 2,"Deleted object is recoverable with Undo")
        try controller.loadDocument(cube)
        let projectURL = documents.appendingPathComponent("native-model-roundtrip.netvistamodel")
        try controller.document.save(projectURL); let loaded = try ModelingDocument.open(projectURL)
        try check(loaded == cube,"Native project round-trips the exact Mac modeling schema")
        let objectGeometry = try ModelingMesh.readOBJ(Data(controller.document.obj().utf8))
        try check(objectGeometry.faces.count == 6 && objectGeometry.vertices.count == 8,"OBJ export/import retains actual visible mesh topology")
        var invalid = cube; invalid.objects[0].scale.x = 0; let stable = controller.document
        do {try controller.loadDocument(invalid); throw ModelingError.invalid("Invalid model was accepted")} catch {try check(controller.document == stable,"Failed project open is atomic")}

        try controller.editSelected { $0.position.y = 3; $0.physics = ModelingPhysicsSettings(mode:.dynamic) }
        let authored = controller.document; try controller.playPhysics(); await pause(); await pause()
        try check(controller.isPhysicsPlaying && controller.document == authored,"Physics play uses a separate simulation without editing saved vertices or transforms")
        let previewNode = controller.geometryNodes[controller.selectedID!]!
        try check(abs(Double(previewNode.presentation.worldPosition.y)) > 0.01,"Native simulation actually moves the displayed mesh")
        controller.stopPhysics(); try check(controller.document == authored && abs(Double(previewNode.worldPosition.y)) < 0.001,"Reset restores the authored viewport pose")
        try controller.loadDocument(cube); controller.setMode(0)
        for _ in 0..<4 {viewport.setDirection("Perspective"); viewport.setDirection("Right"); viewport.frame(objects:controller.document.objects)}
        try check(viewport.cameraNode.worldUp.y > 0.999,"Repeated orbit/axis/frame changes keep the Right view upright instead of accumulating camera roll")

        for size in [CGSize(width:390,height:844),CGSize(width:844,height:390),CGSize(width:1024,height:768)] {
            controller.view.frame = CGRect(origin:.zero,size:size); controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); viewport.frame(objects:controller.document.objects); await pause()
            try check(viewport.bounds.width > 100 && viewport.bounds.height > 100,"Usable 3D viewport at \(size)")
            for control in descendants(controller.view) where control is UIButton || control is UITextField || control is UISegmentedControl {
                try check(control.bounds.height >= 43.5,"Native modeling controls keep44-point touch height at \(size), including \(control.accessibilityIdentifier ?? String(describing:type(of:control)))")
            }
            let image = viewport.snapshot()
            try check(image.size.width > 100 && image.size.height > 100,"SceneKit renders native 3D pixels")
            try image.pngData()?.write(to:documents.appendingPathComponent("model-viewport-\(Int(size.width))x\(Int(size.height)).png"))
            let full = UIGraphicsImageRenderer(size:size).image {_ in controller.view.drawHierarchy(in:controller.view.bounds,afterScreenUpdates:true)}
            try full.pngData()?.write(to:documents.appendingPathComponent("model-workspace-\(Int(size.width))x\(Int(size.height)).png"))
            let center = viewport.projectPoint(SCNVector3Zero)
            try check(viewport.surfaceHit(CGPoint(x:CGFloat(center.x),y:CGFloat(center.y))) != nil,"Visible model remains pickable at \(size)")
            if let cgImage = image.cgImage {
                // SceneKit's snapshot may report raw raster pixels as UIImage
                // points. Projected positions remain viewport points, so map
                // with the actual viewport-to-raster dimensions, not image.size.
                let context = CIContext(), raster = CIImage(cgImage:cgImage)
                let scaleX = CGFloat(cgImage.width)/viewport.bounds.width, scaleY = CGFloat(cgImage.height)/viewport.bounds.height
                func rgb(_ point:CGPoint) -> [UInt8] {
                    var pixel = [UInt8](repeating:0,count:4)
                    context.render(raster,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:floor(point.x*scaleX),y:floor(CGFloat(cgImage.height)-point.y*scaleY-1),width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
                    return Array(pixel.prefix(3))
                }
                let mesh = rgb(CGPoint(x:CGFloat(center.x),y:CGFloat(center.y))), background = rgb(CGPoint(x:5,y:5))
                try check(zip(mesh,background).reduce(0,{ $0+abs(Int($1.0)-Int($1.1)) }) > 35,"Displayed 3D mesh has actual rendered colour, not an empty or black surface at \(size): mesh=\(mesh), background=\(background), image=\(image.size)/\(cgImage.width)x\(cgImage.height), center=\(center), viewport=\(viewport.bounds)")
            } else {throw ModelingError.invalid("Native SceneKit snapshot has no raster pixels")}
        }
        // Completing background IO after Studio Home must not replace the
        // current session, open a detached system picker, or strand exports.
        func exportDirectories() -> Set<URL> {
            Set(((try? FileManager.default.contentsOfDirectory(at:FileManager.default.temporaryDirectory,includingPropertiesForKeys:nil)) ?? []).filter {$0.lastPathComponent.hasPrefix("NetVistaModelExport-")})
        }
        let oldHome = controller.onHome, directoriesBefore = exportDirectories(); var homeCalls = 0
        controller.onHome = {homeCalls += 1}
        try button(controller,"save").sendActions(for:.touchUpInside)
        try button(controller,"home").sendActions(for:.touchUpInside)
        await pause(); await pause()
        try check(homeCalls == 1 && controller.presentedViewController == nil && exportDirectories() == directoriesBefore,"Export then Home cancels late presentation and removes only its own temporary export")
        try controller.renameSelection("Unsaved sculpture must survive")
        let beforeStaleOpen = controller.document
        controller.documentPicker(UIDocumentPickerViewController(forOpeningContentTypes:[.data],asCopy:true),didPickDocumentsAt:[projectURL])
        try button(controller,"home").sendActions(for:.touchUpInside)
        await pause(); await pause()
        try check(controller.document == beforeStaleOpen,"A late project read after Home cannot replace the newer workspace session")
        controller.onHome = oldHome; controller.refreshAccess()
        let gateDocument = controller.document; controller.permitsEditing = {false}; controller.refreshAccess()
        do {try controller.addPrimitive("Sphere"); throw ModelingError.invalid("Signed-out mesh mutation accepted")} catch {try check(controller.document == gateDocument,"Account gate blocks native document mutation")}
        let addButton = try button(controller,"add")
        try check(!viewport.navigationEnabled && !addButton.isEnabled,"Signed-out tool controls are disabled")
        controller.permitsEditing = {true}; controller.refreshAccess()
        try "PASS: Native modeling actual side hits, connected topology, sculpt/vertex touch geometry, transactional history, outliner actions, Mac projects, OBJ, non-destructive physics and phone/tablet layouts.".write(to:documents.appendingPathComponent("model-workspace-result.txt"),atomically:true,encoding:.utf8)
    }
}
