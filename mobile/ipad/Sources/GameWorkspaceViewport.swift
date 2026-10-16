import UIKit
import SceneKit

/// The 2D canvas uses world coordinates (positive Y up), while the 3D view
/// shares the desktop mesh/rig renderer. Neither screen-space drag nor camera
/// changes mutate a running game or the underlying document accidentally.
final class GameWorkspaceViewport: UIView, UIGestureRecognizerDelegate {
    var onSelect: ((UUID?) -> Void)?
    var onMove: ((UUID, Double, Double, Double, Int) -> Void)?
    var canEdit = false
    var selectedID: UUID? { didSet { setNeedsDisplay(); highlight() } }
    var movementAxis = "XZ"
    private(set) var project = GameProject.starter(.twoD)
    private(set) var displayedObjects: [GameObject] = []
    private(set) var sceneView = SCNView()
    private var camera = SCNNode(), nodes: [UUID: SCNNode] = [:], rigs: [UUID: GameRigRenderer] = [:]
    private var images: [UUID: UIImage] = [:], meshes: [UUID: GameMesh] = [:]
    private var assetIDs: [UUID] = []
    private var zoom: CGFloat = 38, worldCenter = CGPoint.zero, dragID: UUID?, dragObject: GameObject?, dragCenter = CGPoint.zero
    private var dragPoint = CGPoint.zero, projectedDepth: Float = 0
    private var dragWorld = SCNVector3Zero, pinchZoom: CGFloat = 1
    private var elapsed: Double = 0
    private var animationNames: [UUID: String] = [:], animationSpeeds: [UUID: Double] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = MobileTheme.workspace
        sceneView.backgroundColor = MobileTheme.workspace; sceneView.autoenablesDefaultLighting = true
        sceneView.allowsCameraControl = true; sceneView.preferredFramesPerSecond = 60; sceneView.isPlaying = false
        addSubview(sceneView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:))); addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:))); pan.maximumNumberOfTouches = 1; pan.delegate = self; addGestureRecognizer(pan)
        let cameraPan = UIPanGestureRecognizer(target: self, action: #selector(cameraPanned(_:))); cameraPan.minimumNumberOfTouches = 2; cameraPan.delegate = self; addGestureRecognizer(cameraPan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))); pinch.delegate = self; addGestureRecognizer(pinch)
        accessibilityIdentifier = "game.viewport"; accessibilityLabel = "Game scene viewport"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layoutSubviews() { super.layoutSubviews(); sceneView.frame = bounds; setNeedsDisplay() }
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if project.dimension == .threeD, recognizer is UIPinchGestureRecognizer { return false }
        if project.dimension == .threeD, let pan = recognizer as? UIPanGestureRecognizer {
            return pan.minimumNumberOfTouches == 1 && canEdit && hit(pan.location(in: self)) != nil
        }
        return true
    }
    func setProject(_ project: GameProject) {
        let assetsChanged = self.project.assets != project.assets
        let rebuild = assetsChanged || self.project.dimension != project.dimension || self.project.objects.count != project.objects.count || zip(self.project.objects,project.objects).contains { a,b in
            a.id != b.id || a.kind != b.kind || a.imageID != b.imageID || a.modelID != b.modelID || a.colour != b.colour || a.rig != b.rig
        }
        self.project = project; displayedObjects = project.objects; elapsed = 0; animationNames = [:]
        if assetsChanged {
            assetIDs = project.assets.map(\.id); images.removeAll(); meshes.removeAll()
            for asset in project.assets {
                if let image = UIImage(data: asset.data) { images[asset.id] = image }
                if ["obj", "nvmesh"].contains(URL(fileURLWithPath: asset.path).pathExtension.lowercased()), let mesh = try? GameMesh.read(asset) { meshes[asset.id] = mesh }
            }
        }
        sceneView.isHidden = project.dimension == .twoD
        if project.dimension == .threeD { if rebuild || sceneView.scene == nil { rebuild3D() } else { update3D() } }
        else { setNeedsDisplay() }
    }
    func display(_ play: GamePlayState) {
        displayedObjects = play.objects.filter { !play.destroyed.contains($0.id) }; elapsed = play.elapsed
        animationNames = play.animations; animationSpeeds = play.animationSpeeds
        if project.dimension == .twoD { setNeedsDisplay() } else { update3D() }
    }
    func fit() {
        if project.dimension == .twoD {
            let list = displayedObjects
            let lowX = list.map { $0.x - $0.size*$0.scaleX/2 }.min() ?? -8
            let highX = list.map { $0.x + $0.size*$0.scaleX/2 }.max() ?? 8
            let lowY = list.map { $0.y - $0.size*$0.scaleY/2 }.min() ?? -5
            let highY = list.map { $0.y + $0.size*$0.scaleY/2 }.max() ?? 5
            worldCenter = CGPoint(x: (lowX+highX)/2, y: (lowY+highY)/2)
            zoom = min(300, max(2, min(bounds.width/CGFloat(max(4,highX-lowX+2)), bounds.height/CGFloat(max(4,highY-lowY+2)))))
            setNeedsDisplay()
        } else {
            let radius = max(5, displayedObjects.map { max(abs($0.x), max(abs($0.y),abs($0.z))) + $0.size }.max() ?? 8)
            camera.position = SCNVector3(0, radius*1.2, radius*1.5); camera.look(at: SCNVector3Zero); sceneView.pointOfView = camera
        }
    }
    func zoomBy(_ amount: CGFloat) { zoom = max(2,min(600,zoom*amount)); setNeedsDisplay() }
    func viewPoint(_ world: CGPoint) -> CGPoint { CGPoint(x: bounds.midX+(world.x-worldCenter.x)*zoom, y: bounds.midY-(world.y-worldCenter.y)*zoom) }
    func worldPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: worldCenter.x+(point.x-bounds.midX)/zoom, y: worldCenter.y-(point.y-bounds.midY)/zoom) }
    func hit(_ point: CGPoint) -> UUID? {
        if project.dimension == .threeD {
            for result in sceneView.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]) {
                var node: SCNNode? = result.node
                while let current = node { if let name = current.name, let id = UUID(uuidString: name) { return id }; node = current.parent }
            }; return nil
        }
        let p = worldPoint(point)
        for object in displayedObjects.reversed() where object.visible && object.opacity > 0 {
            let angle = -object.rotation * .pi / 180, x = Double(p.x)-object.x, y = Double(p.y)-object.y
            let a = x*cos(angle)-y*sin(angle), b = x*sin(angle)+y*cos(angle)
            if abs(a) <= object.size*object.scaleX/2 && abs(b) <= object.size*object.scaleY/2 { return object.id }
        }; return nil
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) { if canEdit { onSelect?(hit(gesture.location(in: self))) } }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        if gesture.state == .began {
            dragID = canEdit ? hit(point) : nil; dragObject = displayedObjects.first { $0.id == dragID }
            dragPoint = point; dragCenter = worldCenter
            if let object = dragObject {
                onSelect?(object.id); onMove?(object.id,object.x,object.y,object.z,0)
                projectedDepth = sceneView.projectPoint(SCNVector3(object.x,object.y,object.z)).z
                dragWorld = sceneView.unprojectPoint(SCNVector3(Float(point.x),Float(point.y),projectedDepth))
            }
        }
        if let object = dragObject, canEdit {
            var x = object.x, y = object.y, z = object.z
            if project.dimension == .twoD { x += Double(point.x-dragPoint.x)/Double(zoom); y -= Double(point.y-dragPoint.y)/Double(zoom) }
            else {
                let world = sceneView.unprojectPoint(SCNVector3(Float(point.x),Float(point.y),projectedDepth))
                if movementAxis.contains("X") { x += Double(world.x-dragWorld.x) }
                if movementAxis.contains("Y") { y += Double(world.y-dragWorld.y) }
                if movementAxis.contains("Z") { z += Double(world.z-dragWorld.z) }
            }
            let phase = gesture.state == .cancelled ? -1 : gesture.state == .ended ? 2 : 1
            onMove?(object.id,x,y,z,phase)
        } else if project.dimension == .twoD {
            worldCenter = CGPoint(x: dragCenter.x-(point.x-dragPoint.x)/zoom,y: dragCenter.y+(point.y-dragPoint.y)/zoom); setNeedsDisplay()
        }
        if [.ended,.cancelled,.failed].contains(gesture.state) { dragID = nil; dragObject = nil }
    }
    @objc private func cameraPanned(_ gesture: UIPanGestureRecognizer) {
        guard project.dimension == .twoD else { return }
        if gesture.state == .began { dragCenter = worldCenter }
        let p = gesture.translation(in: self); worldCenter = CGPoint(x: dragCenter.x-p.x/zoom,y: dragCenter.y+p.y/zoom); setNeedsDisplay()
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) { if gesture.state == .began { pinchZoom = zoom }; zoom = max(2,min(600,pinchZoom*gesture.scale)); setNeedsDisplay() }
    private func colour(_ object: GameObject) -> UIColor {
        MobileTheme.color(UInt32((object.colour ?? (object.imageID != nil ? "#ffffff" : object.kind == .coin ? "#f5c45c" : "#589fd8")).dropFirst(),radix:16) ?? 0x589fd8)
    }
    override func draw(_ rect: CGRect) {
        guard project.dimension == .twoD, let c = UIGraphicsGetCurrentContext() else { return }
        c.setStrokeColor(MobileTheme.line.withAlphaComponent(0.4).cgColor); c.setLineWidth(0.5)
        let step = max(1, pow(10,floor(log10(30/Double(zoom)))))
        let a = worldPoint(.zero), b = worldPoint(CGPoint(x: bounds.maxX,y: bounds.maxY))
        for x in stride(from: floor(Double(a.x)/step)*step, through: Double(b.x), by: step) { let p = viewPoint(CGPoint(x:x,y:0)); c.move(to:CGPoint(x:p.x,y:0)); c.addLine(to:CGPoint(x:p.x,y:bounds.height)) }
        for y in stride(from: floor(Double(b.y)/step)*step, through: Double(a.y), by: step) { let p = viewPoint(CGPoint(x:0,y:y)); c.move(to:CGPoint(x:0,y:p.y)); c.addLine(to:CGPoint(x:bounds.width,y:p.y)) }; c.strokePath()
        for object in displayedObjects where object.visible {
            let p = viewPoint(CGPoint(x:object.x,y:object.y)), w = CGFloat(object.size*object.scaleX)*zoom, h = CGFloat(object.size*object.scaleY)*zoom
            c.saveGState(); c.translateBy(x:p.x,y:p.y); c.rotate(by:-CGFloat(object.rotation) * .pi/180); c.setAlpha(object.opacity)
            let box = CGRect(x:-w/2,y:-h/2,width:w,height:h)
            if let image = object.imageID.flatMap({ images[$0] }) {
                if let sheet = object.spriteSheet, animationNames[object.id] == "sprite", let cg = image.cgImage {
                    let frame = Int(elapsed*sheet.fps*(animationSpeeds[object.id] ?? 1)) % sheet.frames
                    let crop = CGRect(x:frame%sheet.columns*cg.width/sheet.columns,y:frame/sheet.columns*cg.height/sheet.rows,width:cg.width/sheet.columns,height:cg.height/sheet.rows)
                    if let tile = cg.cropping(to:crop) { UIImage(cgImage:tile).draw(in:box) }
                } else { image.draw(in:box) }
            } else { c.setFillColor(colour(object).cgColor); if object.kind == .coin { c.fillEllipse(in:box) } else { c.fill(box) } }
            if object.id == selectedID { c.setAlpha(1); c.setLineWidth(2); c.setStrokeColor(UIColor.systemTeal.cgColor); c.stroke(box.insetBy(dx:-2,dy:-2)) }
            c.restoreGState()
        }
        if displayedObjects.isEmpty { let label = "Empty scene · Add an object or import your own assets" as NSString; label.draw(in:bounds.insetBy(dx:24,dy:max(12,bounds.midY-20)),withAttributes:[.font:UIFont.systemFont(ofSize:13),.foregroundColor:MobileTheme.secondary]) }
    }
    private func rebuild3D() {
        let oldCamera = sceneView.pointOfView?.transform
        let scene = SCNScene(); sceneView.scene = scene; nodes.removeAll(); rigs.removeAll()
        camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.zFar = 100000; scene.rootNode.addChildNode(camera)
        if let oldCamera { camera.transform = oldCamera } else { camera.position = SCNVector3(0,12,17); camera.look(at:SCNVector3Zero) }; sceneView.pointOfView = camera
        let grid = SCNNode()
        for i in -10...10 { for axis in 0...1 { let line = SCNNode(geometry:SCNBox(width:axis == 0 ? 20 : 0.012,height:0.008,length:axis == 0 ? 0.012 : 20,chamferRadius:0)); line.position = SCNVector3(axis == 0 ? 0 : Float(i),-0.005,axis == 0 ? Float(i) : 0); line.geometry?.firstMaterial?.diffuse.contents = MobileTheme.line; grid.addChildNode(line) } }; scene.rootNode.addChildNode(grid)
        for object in project.objects {
            let material = SCNMaterial(); material.diffuse.contents = object.imageID.flatMap { images[$0] } ?? colour(object); material.isDoubleSided = true
            let node: SCNNode
            if let id = object.modelID, let mesh = meshes[id] {
                if let rig = object.rig { let renderer = GameRigRenderer(mesh:mesh,rig:rig,material:material); rigs[object.id] = renderer; node = renderer.root }
                else {
                    let vertices = stride(from:0,to:mesh.positions.count,by:3).map { SCNVector3(mesh.positions[$0],mesh.positions[$0+1],mesh.positions[$0+2]) }
                    let uv = stride(from:0,to:mesh.uv.count,by:2).map { CGPoint(x:Double(mesh.uv[$0]),y:Double(mesh.uv[$0+1])) }
                    let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(textureCoordinates:uv)],elements:[SCNGeometryElement(indices:Array(0..<Int32(vertices.count)),primitiveType:.triangles)]); geometry.materials = [material]; node = SCNNode(geometry:geometry)
                }
            } else { node = SCNNode(geometry:object.kind == .coin ? SCNSphere(radius:0.5) : object.kind == .sprite ? SCNPlane(width:1,height:1) : SCNBox(width:1,height:1,length:1,chamferRadius:0)); node.geometry?.materials = [material] }
            node.name = object.id.uuidString; nodes[object.id] = node; scene.rootNode.addChildNode(node)
        }
        update3D()
    }
    private func update3D() {
        let ids = Set(displayedObjects.map(\.id)); for (id,node) in nodes { node.isHidden = !ids.contains(id) }
        for object in displayedObjects {
            guard let node = nodes[object.id] else { continue }
            node.position = SCNVector3(object.x,object.y,object.z); node.scale = SCNVector3(object.size*object.scaleX,object.size*object.scaleY,object.size*object.scaleZ)
            node.eulerAngles.y = Float(object.rotation * .pi / 180); node.opacity = object.opacity; node.isHidden = !object.visible
            rigs[object.id]?.pose(time:elapsed*(animationSpeeds[object.id] ?? 1),walking:animationNames[object.id] == "walk")
            if canEdit,object.id == selectedID { rigs[object.id]?.guides(selected:nil) }
            if let sheet = object.spriteSheet, animationNames[object.id] == "sprite" {
                let frame = Int(elapsed*sheet.fps*(animationSpeeds[object.id] ?? 1)) % sheet.frames
                node.geometry?.firstMaterial?.diffuse.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(1/Float(sheet.columns),1/Float(sheet.rows),1),SCNMatrix4MakeTranslation(Float(frame%sheet.columns)/Float(sheet.columns),1-Float(frame/sheet.columns+1)/Float(sheet.rows),0))
            }
        }; highlight()
    }
    private func highlight() { for (id,node) in nodes { node.geometry?.firstMaterial?.emission.contents = id == selectedID ? UIColor.systemTeal.withAlphaComponent(0.22) : UIColor.black } }
}
