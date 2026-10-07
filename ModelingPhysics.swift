import Foundation
import SceneKit
import simd

enum ModelingPhysicsMode: String, Codable, CaseIterable {
    case off, `static`, dynamic
    var title: String {
        switch self { case .off: return "Off"; case .static: return "Static collider"; case .dynamic: return "Dynamic body" }
    }
}

/// Lightweight rigid-body preview settings, stored with a modelling object.
/// Detailed sculpt geometry is deliberately not used as a collision mesh.
struct ModelingPhysicsSettings: Codable, Equatable {
    var mode: ModelingPhysicsMode = .off
    var mass: Double = 1
    var friction: Double = 0.6
    var restitution: Double = 0.15
    var affectedByGravity: Bool = true
    var damping: Double = 0.1
    var angularDamping: Double = 0.1

    func validate() throws {
        guard mass.isFinite, (0.001...10000).contains(mass),
              [friction,restitution,damping,angularDamping].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw ModelingPhysicsError.invalid("Physics needs a mass of 0.001–10,000 and finite friction, bounce and damping values from 0 to 1.")
        }
    }
}

enum ModelingPhysicsError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

struct ModelingPhysicsParticipant {
    let id: UUID
    let node: SCNNode
    let settings: ModelingPhysicsSettings
    init(id: UUID, node: SCNNode, settings: ModelingPhysicsSettings = .init()) {
        self.id = id; self.node = node; self.settings = settings
    }
}

/// A separate physics scene owns the simulation. The visible editor remains
/// editable geometry, and its mesh/document is never changed by playback.
/// A single fixed-step clock makes Pause, Step and Reset independent of the
/// viewport's render rate. Call this object on the main thread.
final class ModelingPhysicsPreview {
    enum State: Equatable { case stopped, playing, paused }
    private(set) var state: State = .stopped
    private(set) var time: TimeInterval = 0
    var onUpdate: (() -> Void)?
    static let colliderDescription = "Box colliders · rigid bodies only"
    private var simulation = SCNScene()
    private var renderer = SCNRenderer(device:nil,options:nil)
    private var timer: Timer?
    private var clock: TimeInterval = ProcessInfo.processInfo.systemUptime
    private let interval: TimeInterval = 1.0 / 60.0
    private struct Entry {
        let display: SCNNode
        let body: SCNNode
        let originalWorld: simd_float4x4
        let originalBodyWorld: simd_float4x4
        let inverseOriginalBodyWorld: simd_float4x4
        let originalDisplayTransform: SCNMatrix4
        let settings: ModelingPhysicsSettings
    }
    private var entries: [UUID:Entry] = [:]
    private var floorHeight: Double = 0
    private var floor: SCNNode?
    private var configured = false

    init() {
        prepareSimulation()
    }
    private func prepareSimulation() {
        simulation = SCNScene()
        renderer = SCNRenderer(device:nil,options:nil)
        renderer.scene = simulation
        renderer.isPlaying = true
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.position = SCNVector3(0,5,10)
        simulation.rootNode.addChildNode(camera); renderer.pointOfView = camera
        simulation.physicsWorld.gravity = SCNVector3(0,-9.81,0)
        simulation.physicsWorld.timeStep = interval
        clock = ProcessInfo.processInfo.systemUptime
    }
    deinit { timer?.invalidate() }

    var dynamicBodyCount: Int { entries.values.filter { $0.settings.mode == .dynamic }.count }
    var bodyCount: Int { entries.count }

    /// Reconfiguration discards preview motion, never authored transforms.
    /// Floor height uses the editor's ground plane (Y = 0 by default).
    func configure(participants: [ModelingPhysicsParticipant], floorHeight: Double = 0) throws {
        guard Thread.isMainThread else { throw ModelingPhysicsError.invalid("Configure physics on the main thread.") }
        guard renderer.device != nil else { throw ModelingPhysicsError.invalid("The native graphics device is unavailable. Physics preview needs access to this Mac's graphics runtime.") }
        guard floorHeight.isFinite, abs(floorHeight) <= 100000,
              participants.count <= 256, Set(participants.map(\.id)).count == participants.count else {
            throw ModelingPhysicsError.invalid("Use a finite floor height and up to 256 unique physics objects.")
        }
        for p in participants { try p.settings.validate() }
        // Validate all bounds before resetting an existing preview.
        for p in participants where p.settings.mode != .off {
            let bounds = p.node.boundingBox
            let values = [bounds.min.x,bounds.min.y,bounds.min.z,bounds.max.x,bounds.max.y,bounds.max.z]
            guard values.allSatisfy({ $0.isFinite && abs($0) <= 200000 }) else {
                throw ModelingPhysicsError.invalid("This object has invalid bounds and cannot be simulated.")
            }
        }
        end(); prepareSimulation(); self.floorHeight = floorHeight
        for p in participants where p.settings.mode != .off {
            let bounds = p.node.boundingBox
            let center = SIMD3<Float>(Float((bounds.min.x+bounds.max.x)/2),Float((bounds.min.y+bounds.max.y)/2),Float((bounds.min.z+bounds.max.z)/2))
            // A minimum thickness keeps planes and very thin faces stable.
            let width = max(0.01,CGFloat(bounds.max.x-bounds.min.x))
            let height = max(0.01,CGFloat(bounds.max.y-bounds.min.y))
            let length = max(0.01,CGFloat(bounds.max.z-bounds.min.z))
            let box = SCNBox(width:width,height:height,length:length,chamferRadius:0)
            let node = SCNNode(geometry:box)
            var centered = matrix_identity_float4x4
            centered.columns.3 = SIMD4<Float>(center.x,center.y,center.z,1)
            let original = p.node.simdWorldTransform
            node.simdTransform = original * centered
            simulation.rootNode.addChildNode(node)
            let shape = SCNPhysicsShape(geometry:box,options:[.type:SCNPhysicsShape.ShapeType.boundingBox, .scale:NSValue(scnVector3:node.scale)])
            let body = SCNPhysicsBody(type:p.settings.mode == .dynamic ? .dynamic : .static,shape:shape)
            // Static colliders must retain zero inverse mass. Assigning a
            // positive mass to a SceneKit static body makes contact impulses
            // move it even when the reported type remains `.static`.
            body.mass = p.settings.mode == .dynamic ? CGFloat(p.settings.mass) : 0
            body.friction = CGFloat(p.settings.friction)
            body.restitution = CGFloat(p.settings.restitution)
            body.damping = CGFloat(p.settings.damping)
            body.angularDamping = CGFloat(p.settings.angularDamping)
            body.isAffectedByGravity = p.settings.affectedByGravity
            body.continuousCollisionDetectionThreshold = max(0.005,min(width,height,length)*0.25)
            node.physicsBody = body
            body.resetTransform()
            entries[p.id] = Entry(display:p.node,body:node,originalWorld:original,
                                  originalBodyWorld:node.simdWorldTransform,
                                  inverseOriginalBodyWorld:simd_inverse(node.simdWorldTransform),
                                  originalDisplayTransform:p.node.transform,settings:p.settings)
        }
        let floor = SCNNode(geometry:SCNBox(width:400000,height:0.1,length:400000,chamferRadius:0))
        floor.position = SCNVector3(0,floorHeight-0.05,0)
        floor.physicsBody = .static(); floor.physicsBody?.friction = 0.6; floor.physicsBody?.restitution = 0.1
        simulation.rootNode.addChildNode(floor); self.floor = floor
        clock += interval
        renderer.update(atTime:clock)
        SCNTransaction.flush()
        configured = true; state = .stopped; time = 0
        onUpdate?()
    }

    func play() {
        guard configured, dynamicBodyCount > 0, state != .playing else { return }
        state = .playing
        let timer = Timer(timeInterval:1.0/30.0,repeats:true) { [weak self] _ in
            guard let self, self.state == .playing else { return }
            self.advance(steps:2)
        }
        self.timer = timer
        RunLoop.main.add(timer,forMode:.common)
        onUpdate?()
    }
    func pause() {
        timer?.invalidate(); timer = nil
        if configured { state = .paused }
        onUpdate?()
    }
    /// One frame (or a bounded number of frames) while paused. No wall-clock wait.
    func step(frames: Int = 1) {
        guard configured, dynamicBodyCount > 0 else { return }
        pause(); advance(steps:max(1,min(120,frames)))
    }
    private func advance(steps: Int) {
        for _ in 0..<steps { clock += interval; renderer.update(atTime:clock); SCNTransaction.flush(); time += interval }
        mirrorPresentation(); onUpdate?()
    }
    private func mirrorPresentation() {
        SCNTransaction.begin(); SCNTransaction.disableActions = true
        for entry in entries.values {
            let delta = entry.body.presentation.simdWorldTransform * entry.inverseOriginalBodyWorld
            entry.display.simdWorldTransform = delta * entry.originalWorld
        }
        SCNTransaction.commit()
    }
    /// A rigid world-space motion applied to the object's original world vertices.
    /// Use only when the user explicitly chooses Bake; meshes stay untouched here.
    func deltaTransform(for id: UUID) -> simd_float4x4? {
        guard let entry = entries[id] else { return nil }
        return entry.body.presentation.simdWorldTransform * entry.inverseOriginalBodyWorld
    }
    func transformedPoint(for id: UUID, x: Double, y: Double, z: Double) -> (x:Double,y:Double,z:Double)? {
        guard let delta = deltaTransform(for:id), [x,y,z].allSatisfy(\.isFinite) else { return nil }
        let p = delta * SIMD4<Float>(Float(x),Float(y),Float(z),1)
        guard [p.x,p.y,p.z,p.w].allSatisfy(\.isFinite), abs(p.w) > 1e-8 else { return nil }
        return (Double(p.x/p.w),Double(p.y/p.w),Double(p.z/p.w))
    }
    func reset() {
        pause()
        SCNTransaction.begin(); SCNTransaction.disableActions = true
        for entry in entries.values {
            entry.body.simdWorldTransform = entry.originalBodyWorld
            entry.body.physicsBody?.clearAllForces()
            entry.body.physicsBody?.velocity = SCNVector3Zero
            entry.body.physicsBody?.angularVelocity = SCNVector4Zero
            entry.body.physicsBody?.resetTransform()
            entry.display.transform = entry.originalDisplayTransform
        }
        SCNTransaction.commit()
        // Flush teleportation without advancing gravity during the reset itself.
        simulation.physicsWorld.speed = 0
        clock += interval; renderer.update(atTime:clock); SCNTransaction.flush()
        simulation.physicsWorld.speed = 1
        time = 0; state = .stopped; onUpdate?()
    }
    /// Call before editing, rebuilding visible nodes, or closing the editor.
    func end() {
        timer?.invalidate(); timer = nil
        SCNTransaction.begin(); SCNTransaction.disableActions = true
        for entry in entries.values { entry.display.transform = entry.originalDisplayTransform; entry.body.removeFromParentNode() }
        SCNTransaction.commit()
        entries.removeAll(); floor?.removeFromParentNode(); floor = nil
        configured = false; time = 0; state = .stopped
    }
}
