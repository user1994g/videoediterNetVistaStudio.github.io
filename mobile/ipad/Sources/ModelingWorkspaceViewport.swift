import UIKit
import SceneKit
import simd

extension ModelPoint {
    var mobileSCN: SCNVector3 { SCNVector3(Float(x), Float(y), Float(z)) }
    init(mobile vector: SCNVector3) { self.init(x: Double(vector.x), y: Double(vector.y), z: Double(vector.z)) }
}

/// Native viewport adapter. Picking is mesh-only: neither the ground nor the
/// selection overlay can intercept a stroke on the side of an actual model.
@MainActor final class ModelingWorkspaceViewport: SCNView, UIGestureRecognizerDelegate {
    var onPick: ((CGPoint) -> Void)?
    var onStroke: ((CGPoint, Int) -> Void)? // began / moved / ended / cancelled
    var editsSurface = false
    var navigationEnabled = true
    let cameraNode = SCNNode(), overlay = ModelingWorkspaceCursor()
    private(set) var target = ModelPoint()
    private(set) var distance = 4.0
    private var yaw = 0.75, pitch = 0.45
    private var strokeActive = false
    private var orbitStart = CGPoint.zero, lastPan = CGPoint.zero

    override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        backgroundColor = MobileTheme.workspace; antialiasingMode = .multisampling2X
        preferredFramesPerSecond = 60; rendersContinuously = false
        let world = SCNScene(); scene = world
        cameraNode.camera = SCNCamera(); cameraNode.camera?.zNear = 0.005; cameraNode.camera?.zFar = 100_000
        cameraNode.camera?.fieldOfView = 48; world.rootNode.addChildNode(cameraNode); pointOfView = cameraNode
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .omni; key.light?.intensity = 950
        key.position = SCNVector3(4, 7, 5); world.rootNode.addChildNode(key)
        let fill = SCNNode(); fill.light = SCNLight(); fill.light?.type = .ambient; fill.light?.intensity = 450
        world.rootNode.addChildNode(fill)
        var lines: [SCNVector3] = []
        for step in -20...20 {
            lines += [SCNVector3(-20, -0.003, Float(step)), SCNVector3(20, -0.003, Float(step)),
                      SCNVector3(Float(step), -0.003, -20), SCNVector3(Float(step), -0.003, 20)]
        }
        let gridGeometry = SCNGeometry(sources: [SCNGeometrySource(vertices: lines)], elements: [SCNGeometryElement(indices: Array(0..<Int32(lines.count)), primitiveType: .line)])
        let gridMaterial = SCNMaterial(); gridMaterial.lightingModel = .constant; gridMaterial.diffuse.contents = MobileTheme.line
        gridGeometry.materials = [gridMaterial]
        let grid = SCNNode(geometry: gridGeometry); grid.categoryBitMask = 2; world.rootNode.addChildNode(grid)
        overlay.isUserInteractionEnabled = false; overlay.backgroundColor = .clear; addSubview(overlay)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:))); addGestureRecognizer(tap)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.minimumNumberOfTouches = 1; drag.maximumNumberOfTouches = 1; addGestureRecognizer(drag)
        let orbit = UIPanGestureRecognizer(target: self, action: #selector(orbited(_:)))
        orbit.minimumNumberOfTouches = 2; orbit.maximumNumberOfTouches = 2; orbit.delegate = self; addGestureRecognizer(orbit)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 3; pan.maximumNumberOfTouches = 3; addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))); pinch.delegate = self; addGestureRecognizer(pinch)
        accessibilityIdentifier = "model.viewport"; accessibilityLabel = "3D modeling viewport"
        updateCamera()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layoutSubviews() { super.layoutSubviews(); overlay.frame = bounds }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) { if navigationEnabled { onPick?(gesture.location(in: self)) } }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard navigationEnabled else { return }
        let point = gesture.location(in: self)
        if gesture.state == .began { strokeActive = editsSurface; orbitStart = gesture.translation(in: self) }
        if strokeActive {
            switch gesture.state { case .began: onStroke?(point, 0); case .changed: onStroke?(point, 1)
            case .ended: onStroke?(point, 2); case .cancelled, .failed: onStroke?(point, 3); default: break }
        } else { orbit(gesture) }
        if [.ended, .cancelled, .failed].contains(gesture.state) { strokeActive = false }
    }
    @objc private func orbited(_ gesture: UIPanGestureRecognizer) { if navigationEnabled { orbit(gesture) } }
    private func orbit(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { orbitStart = gesture.translation(in: self) }
        let delta = gesture.translation(in: self)
        yaw -= Double(delta.x - orbitStart.x) * 0.008; pitch += Double(delta.y - orbitStart.y) * 0.008
        pitch = max(-1.5, min(1.5, pitch)); orbitStart = delta; updateCamera()
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard navigationEnabled else { return }
        if gesture.state == .began { lastPan = gesture.translation(in: self) }
        let p = gesture.translation(in: self), factor = distance / Double(max(100, bounds.height))
        let right = ModelPoint(x: cos(yaw), z: -sin(yaw)), up = ModelPoint(x: -sin(yaw) * sin(pitch), y: cos(pitch), z: -cos(yaw) * sin(pitch))
        target = target + right * (-Double(p.x - lastPan.x) * factor) + up * (Double(p.y - lastPan.y) * factor)
        lastPan = p; updateCamera()
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard navigationEnabled else { return }; zoom(Double(gesture.scale)); gesture.scale = 1
    }
    func zoom(_ multiplier: Double) { guard multiplier.isFinite, multiplier > 0 else { return }; distance = max(0.025, min(500_000, distance / multiplier)); updateCamera() }
    func frame(objects: [ModelingObject]) {
        let points = objects.filter(\.visible).flatMap { object in object.mesh.vertices.map { object.world($0) } }
        guard let first = points.first else { target = .init(); distance = 4; updateCamera(); return }
        var low = first, high = first
        for p in points { low = .init(x: min(low.x,p.x), y: min(low.y,p.y), z: min(low.z,p.z)); high = .init(x: max(high.x,p.x), y: max(high.y,p.y), z: max(high.z,p.z)) }
        target = (low + high) * 0.5; distance = max(0.5, (high - low).length * 1.65); updateCamera()
    }
    func setDirection(_ direction: String) {
        switch direction { case "Front": yaw = 0; pitch = 0; case "Back": yaw = .pi; pitch = 0
        case "Right": yaw = .pi / 2; pitch = 0; case "Left": yaw = -.pi / 2; pitch = 0
        case "Top": yaw = 0; pitch = 1.5; case "Bottom": yaw = 0; pitch = -1.5
        default: yaw = 0.75; pitch = 0.45 }; updateCamera()
    }
    private func updateCamera() {
        SCNTransaction.begin(); SCNTransaction.disableActions = true
        cameraNode.position = (target + ModelPoint(x: sin(yaw) * cos(pitch), y: sin(pitch), z: cos(yaw) * cos(pitch)) * distance).mobileSCN
        // look(at:) alone reuses the camera's previous world-up vector and
        // gradually banks level axis views after orbiting. Keep gravity upright.
        cameraNode.look(at: target.mobileSCN,up:SCNVector3(0,1,0),localFront:SCNVector3(0,0,-1))
        cameraNode.camera?.zNear = max(0.001, distance / 10_000)
        cameraNode.camera?.zFar = max(100, distance * 100); SCNTransaction.commit(); SCNTransaction.flush(); setNeedsDisplay()
        overlay.points = []
    }
    func surfaceHit(_ point: CGPoint) -> SCNHitTestResult? {
        // A ray exactly on a newly sculpted shared vertex can numerically miss
        // every near triangle and hit the rear instead. Use a subpixel pick
        // footprint and choose the nearest real mesh intersection. This stays
        // below one display pixel on Retina screens, preserves the actual face
        // and normal, and needs no synchronous rendered-image readback.
        guard bounds.width > 0, bounds.height > 0, point.x.isFinite, point.y.isFinite,
              let root = scene?.rootNode else {return nil}
        let near = unprojectPoint(SCNVector3(Float(point.x),Float(point.y),0))
        let origin = ModelPoint(mobile:near)
        func distanceSquared(_ hit: SCNHitTestResult) -> Double {
            let delta = ModelPoint(mobile:hit.worldCoordinates)-origin; return delta.dot(delta)
        }
        let offsets = [CGPoint.zero,CGPoint(x:0.25,y:0),CGPoint(x:-0.25,y:0),CGPoint(x:0,y:0.25),CGPoint(x:0,y:-0.25)]
        return offsets.flatMap { offset -> [SCNHitTestResult] in
            let x = Float(point.x+offset.x), y = Float(point.y+offset.y)
            return root.hitTestWithSegment(from:unprojectPoint(SCNVector3(x,y,0)),to:unprojectPoint(SCNVector3(x,y,1)),options:[SCNHitTestOption.categoryBitMask.rawValue: 1, SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue, SCNHitTestOption.backFaceCulling.rawValue: false])
        }
            .filter { UUID(uuidString: $0.node.name ?? "") != nil && distanceSquared($0).isFinite }
            .min { distanceSquared($0) < distanceSquared($1) }
    }
    func cursor(object: ModelingObject, center: ModelPoint, normal: ModelPoint, radius: Double) {
        let tangent = normal.cross(abs(normal.y) < 0.9 ? ModelPoint(y: 1) : ModelPoint(x: 1)).unit
        let bitangent = normal.cross(tangent).unit
        overlay.points = (0..<48).map { i in
            let angle = Double(i) * 2 * .pi / 48
            let p = projectPoint(object.world(center + (tangent * cos(angle) + bitangent * sin(angle)) * radius).mobileSCN)
            return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        }
    }
}

@MainActor final class ModelingWorkspaceCursor: UIView {
    var points: [CGPoint] = [] { didSet { setNeedsDisplay() } }
    override func draw(_ rect: CGRect) {
        guard let first = points.first else { return }; let line = UIBezierPath(); line.move(to: first)
        points.dropFirst().forEach { line.addLine(to: $0) }; line.close()
        UIColor.black.withAlphaComponent(0.7).setStroke(); line.lineWidth = 3; line.stroke()
        UIColor.systemOrange.setStroke(); line.lineWidth = 1.3; line.stroke()
    }
}
