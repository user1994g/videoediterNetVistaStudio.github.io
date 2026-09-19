import Cocoa
import SceneKit
import simd

/// Joint positions are stored in the imported model's normalized, editable space.
/// The original model file is never rewritten when a rig is created or bound.
public struct SceneRigJoint: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var parentID: String?
    public var position: SceneVector3
}

public struct SceneRigMeshBinding: Codable, Equatable {
    public var meshPath: String
    public var vertexCount: Int
    public var jointIndices: [UInt16]
    public var weights: [Float]
}

public struct SceneAuthoredRig: Codable, Equatable {
    public var id = UUID()
    public var joints: [SceneRigJoint]
    public var bindings: [SceneRigMeshBinding] = []
    public var isBound: Bool { !bindings.isEmpty }
}

enum SceneRigError: LocalizedError {
    case invalidSkeleton, noMesh, tooLarge, invalidGeometry, changedMesh
    var errorDescription: String? {
        switch self {
        case .invalidSkeleton: return "The rig has an invalid joint hierarchy or joint position."
        case .noMesh: return "This model has no readable mesh to bind."
        case .tooLarge: return "This model has more than one million vertices. Import a lower-detail copy before binding."
        case .invalidGeometry: return "The model contains an unsupported vertex format. Export an OBJ or DAE mesh and try again."
        case .changedMesh: return "The model geometry changed after this rig was bound. Fit the joints and bind the mesh again."
        }
    }
}

/// Shared by the live scene and movie renderer. This is linear blend skinning,
/// with four automatic segment-distance influences per vertex, not IK or a
/// substitute for an artist's skin weights on complex characters.
enum SceneRigging {
    static let rootName = "__netVistaAuthoredRig"
    static let meshesName = "__netVistaSkinnedMeshes"
    static let overlayName = "__netVistaRigOverlay"
    static let jointPrefix = "__netVistaJoint_"

    static func humanoid(in root: SCNNode) throws -> SceneAuthoredRig {
        let meshes = try meshRecords(in: root)
        let points = meshes.flatMap(\.vertices)
        guard let first = points.first else { throw SceneRigError.noMesh }
        var low = first, high = first
        for point in points { low = simd_min(low, point); high = simd_max(high, point) }
        let height = max(0.01, high.y - low.y)
        let centerX = (low.x + high.x) / 2
        let centerZ = (low.z + high.z) / 2
        let halfWidth = max(height * 0.14, (high.x - low.x) / 2)
        func joint(_ id: String, _ name: String, _ parent: String?, _ x: Float, _ y: Float, _ z: Float = 0) -> SceneRigJoint {
            SceneRigJoint(id: id, name: name, parentID: parent,
                          position: vector(SIMD3(centerX + x * halfWidth, low.y + y * height, centerZ + z * height)))
        }
        // A front-facing T-pose starting point. Users fit these joints to their mesh.
        return SceneAuthoredRig(joints: [
            joint("hips", "Hips", nil, 0, 0.51),
            joint("spine", "Spine", "hips", 0, 0.63),
            joint("chest", "Chest", "spine", 0, 0.75),
            joint("neck", "Neck", "chest", 0, 0.84),
            joint("head", "Head", "neck", 0, 0.91),
            joint("leftUpperArm", "Left upper arm", "chest", 0.27, 0.77),
            joint("leftForearm", "Left forearm", "leftUpperArm", 0.58, 0.77),
            joint("leftHand", "Left hand", "leftForearm", 0.88, 0.77),
            joint("rightUpperArm", "Right upper arm", "chest", -0.27, 0.77),
            joint("rightForearm", "Right forearm", "rightUpperArm", -0.58, 0.77),
            joint("rightHand", "Right hand", "rightForearm", -0.88, 0.77),
            joint("leftThigh", "Left thigh", "hips", 0.16, 0.49),
            joint("leftShin", "Left shin", "leftThigh", 0.16, 0.27),
            joint("leftFoot", "Left foot", "leftShin", 0.16, 0.06, 0.035),
            joint("rightThigh", "Right thigh", "hips", -0.16, 0.49),
            joint("rightShin", "Right shin", "rightThigh", -0.16, 0.27),
            joint("rightFoot", "Right foot", "rightShin", -0.16, 0.06, 0.035)
        ])
    }

    static func validate(_ rig: SceneAuthoredRig) throws {
        guard !rig.joints.isEmpty, rig.joints.count < Int(UInt16.max) else { throw SceneRigError.invalidSkeleton }
        var visited = Set<String>()
        for joint in rig.joints {
            let p = joint.position
            guard !joint.id.isEmpty, !visited.contains(joint.id),
                  p.x.isFinite, p.y.isFinite, p.z.isFinite,
                  joint.parentID.map({ visited.contains($0) }) ?? true else { throw SceneRigError.invalidSkeleton }
            visited.insert(joint.id)
        }
    }

    static func bind(_ rig: SceneAuthoredRig, to source: SCNNode) throws -> SceneAuthoredRig {
        try validate(rig)
        let meshes = try meshRecords(in: source)
        guard !meshes.isEmpty else { throw SceneRigError.noMesh }
        guard meshes.reduce(0, { $0 + $1.vertices.count }) <= 1_000_000 else { throw SceneRigError.tooLarge }
        var result = rig
        result.bindings = meshes.map { mesh in
            var indices = [UInt16](), weights = [Float]()
            indices.reserveCapacity(mesh.vertices.count * 4)
            weights.reserveCapacity(mesh.vertices.count * 4)
            for point in mesh.vertices {
                let influences = influences(for: point, joints: rig.joints)
                indices.append(contentsOf: influences.indices)
                weights.append(contentsOf: influences.weights)
            }
            return SceneRigMeshBinding(meshPath: mesh.path, vertexCount: mesh.vertices.count, jointIndices: indices, weights: weights)
        }
        return result
    }

    static func influences(for point: SIMD3<Float>, joints: [SceneRigJoint]) -> (indices: [UInt16], weights: [Float]) {
        // A joint owns the segment towards its child. Thus rotating an elbow
        // deforms the forearm, rather than incorrectly owning the upper arm.
        let distances: [(Int, Float)] = joints.enumerated().map { index, joint in
            let start = simdVector(joint.position)
            let children = joints.filter { $0.parentID == joint.id }
            let distance = children.map { distanceSquared(point, start, simdVector($0.position)) }.min()
                ?? simd_length_squared(point - start)
            return (index, distance)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        let chosen = Array(distances.prefix(4))
        var indices = chosen.map { UInt16($0.0) }
        var weights = chosen.map { Float(1) / pow(max(0.000_01, $0.1), 2) }
        let total = max(Float.leastNonzeroMagnitude, weights.reduce(0, +))
        weights = weights.map { $0 / total }
        while indices.count < 4 { indices.append(0); weights.append(0) }
        return (indices, weights)
    }

    static func distanceSquared(_ point: SIMD3<Float>, _ start: SIMD3<Float>, _ end: SIMD3<Float>) -> Float {
        let segment = end - start
        let t = max(0, min(1, simd_dot(point - start, segment) / max(0.000_000_1, simd_length_squared(segment))))
        return simd_length_squared(point - (start + t * segment))
    }

    /// Creates real deforming mesh nodes. Positions/normals are transformed into
    /// model space first, so imported mesh transforms and normalization cannot
    /// give different bind spaces to the skeleton and the vertices.
    static func install(_ rig: SceneAuthoredRig, in root: SCNNode) throws {
        try validate(rig)
        let meshes = try meshRecords(in: root)
        var resolved: [(MeshRecord, SceneRigMeshBinding)] = []
        for binding in rig.bindings {
            guard let mesh = meshes.first(where: { $0.path == binding.meshPath }),
                  mesh.vertices.count == binding.vertexCount,
                  binding.jointIndices.count == binding.vertexCount * 4,
                  binding.weights.count == binding.vertexCount * 4,
                  binding.jointIndices.allSatisfy({ Int($0) < rig.joints.count }),
                  binding.weights.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw SceneRigError.changedMesh }
            for vertex in 0..<binding.vertexCount {
                let offset = vertex * 4
                let sum = binding.weights[offset..<offset + 4].reduce(0, +)
                guard abs(sum - 1) < 0.001 else { throw SceneRigError.changedMesh }
            }
            resolved.append((mesh, binding))
        }
        let skeleton = SCNNode()
        skeleton.name = rootName
        root.addChildNode(skeleton)
        var boneNodes = [String: SCNNode]()
        for joint in rig.joints {
            let bone = SCNNode()
            bone.name = jointPrefix + joint.id
            bone.setValue(joint.name, forKey: "netVistaJointDisplayName")
            bone.setValue(joint.id, forKey: "netVistaJointID")
            let parentPosition = joint.parentID.flatMap { id in rig.joints.first(where: { $0.id == id })?.position } ?? SceneVector3()
            bone.simdPosition = simdVector(joint.position) - simdVector(parentPosition)
            (joint.parentID.flatMap { boneNodes[$0] } ?? skeleton).addChildNode(bone)
            boneNodes[joint.id] = bone
        }
        let bones = rig.joints.compactMap { boneNodes[$0.id] }
        let inverseBind = rig.joints.map { joint -> NSValue in
            let p = joint.position
            return NSValue(scnMatrix4: SCNMatrix4MakeTranslation(-CGFloat(p.x), -CGFloat(p.y), -CGFloat(p.z)))
        }
        let skinnedMeshes = SCNNode()
        skinnedMeshes.name = meshesName
        root.addChildNode(skinnedMeshes)
        for (mesh, binding) in resolved {
            var sources = mesh.geometry.sources.filter { $0.semantic != .vertex && $0.semantic != .normal && $0.semantic != .boneWeights && $0.semantic != .boneIndices }
            sources.append(SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)) }))
            if !mesh.normals.isEmpty {
                sources.append(SCNGeometrySource(normals: mesh.normals.map { SCNVector3(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)) }))
            }
            let geometry = SCNGeometry(sources: sources, elements: mesh.geometry.elements)
            geometry.materials = mesh.geometry.materials
            let weightData = binding.weights.withUnsafeBytes { Data($0) }
            let indexData = binding.jointIndices.withUnsafeBytes { Data($0) }
            let weights = SCNGeometrySource(data: weightData, semantic: .boneWeights, vectorCount: binding.vertexCount, usesFloatComponents: true,
                                           componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
            let indices = SCNGeometrySource(data: indexData, semantic: .boneIndices, vectorCount: binding.vertexCount, usesFloatComponents: false,
                                           componentsPerVector: 4, bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
            let node = SCNNode(geometry: geometry)
            node.name = mesh.node.name
            node.skinner = SCNSkinner(baseGeometry: geometry, bones: bones, boneInverseBindTransforms: inverseBind, boneWeights: weights, boneIndices: indices)
            node.skinner?.baseGeometryBindTransform = SCNMatrix4Identity
            node.skinner?.skeleton = skeleton
            skinnedMeshes.addChildNode(node)
            mesh.node.skinner = nil
            mesh.node.geometry = nil
        }
    }

    static func jointNode(id: String, in root: SCNNode) -> SCNNode? {
        root.childNode(withName: jointPrefix + id, recursively: true)
    }

    static func addOverlay(to root: SCNNode, selectedJointID: String?) {
        root.childNode(withName: overlayName, recursively: false)?.removeFromParentNode()
        guard let skeleton = root.childNode(withName: rootName, recursively: false) else { return }
        let overlay = SCNNode()
        overlay.name = overlayName
        root.addChildNode(overlay)
        skeleton.enumerateChildNodes { bone, _ in
            guard let id = bone.value(forKey: "netVistaJointID") as? String else { return }
            let sphere = SCNSphere(radius: id == selectedJointID ? 0.029 : 0.019)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = id == selectedJointID ? NSColor.systemOrange : NSColor(calibratedRed: 0.15, green: 0.85, blue: 0.95, alpha: 1)
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            sphere.firstMaterial = material
            let handle = SCNNode(geometry: sphere)
            handle.setValue(id, forKey: "netVistaJointID")
            handle.simdPosition = root.simdConvertPosition(.zero, from: bone)
            handle.renderingOrder = 1000
            overlay.addChildNode(handle)
            if let parent = bone.parent, parent !== skeleton {
                let start = root.simdConvertPosition(.zero, from: parent)
                let end = handle.simdPosition
                let length = simd_length(end - start)
                if length > 0.0001 {
                    let line = SCNNode(geometry: SCNCylinder(radius: 0.006, height: CGFloat(length)))
                    line.geometry?.firstMaterial = material
                    line.simdPosition = (start + end) / 2
                    line.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(end - start))
                    line.renderingOrder = 999
                    overlay.addChildNode(line)
                }
            }
        }
    }

    struct MeshRecord {
        let path: String
        let node: SCNNode
        let geometry: SCNGeometry
        let vertices: [SIMD3<Float>]
        let normals: [SIMD3<Float>]
    }

    static func meshRecords(in root: SCNNode) throws -> [MeshRecord] {
        var records = [MeshRecord]()
        func visit(_ node: SCNNode, _ path: String) throws {
            if [rootName, meshesName, overlayName].contains(node.name ?? "") { return }
            if let geometry = node.geometry, let vertices = geometry.sources(for: .vertex).first {
                let positions = try vectors(from: vertices).map { root.simdConvertPosition($0, from: node) }
                let transform = root.simdConvertTransform(matrix_identity_float4x4, from: node)
                let normalMatrix = simd_transpose(simd_inverse(simd_float3x3(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                                                                            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                                                                            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))))
                let normals = try geometry.sources(for: .normal).first.map { source in
                    try vectors(from: source).map { vector -> SIMD3<Float> in
                        let transformed = normalMatrix * vector
                        return simd_length_squared(transformed) > 0.0000001 ? simd_normalize(transformed) : SIMD3(0, 1, 0)
                    }
                } ?? []
                records.append(MeshRecord(path: path, node: node, geometry: geometry, vertices: positions, normals: normals))
            }
            for (index, child) in node.childNodes.enumerated() { try visit(child, path.isEmpty ? "\(index)" : path + "/\(index)") }
        }
        try visit(root, "")
        return records
    }

    static func vectors(from source: SCNGeometrySource) throws -> [SIMD3<Float>] {
        guard source.usesFloatComponents, [4, 8].contains(source.bytesPerComponent), source.componentsPerVector >= 3,
              source.vectorCount <= 1_000_000 else { throw SceneRigError.invalidGeometry }
        let componentSize = source.bytesPerComponent
        let stride = source.dataStride > 0 ? source.dataStride : source.componentsPerVector * componentSize
        guard source.vectorCount == 0 || source.dataOffset + (source.vectorCount - 1) * stride + 3 * componentSize <= source.data.count else {
            throw SceneRigError.invalidGeometry
        }
        return source.data.withUnsafeBytes { bytes in
            (0..<source.vectorCount).map { index in
                var value = SIMD3<Float>.zero
                for axis in 0..<3 {
                    let offset = source.dataOffset + index * stride + axis * componentSize
                    // Geometry buffers can have unaligned offsets.
                    if componentSize == 4 {
                        var scalar: Float = 0
                        withUnsafeMutableBytes(of: &scalar) { target in target.copyBytes(from: bytes[offset..<offset + 4]) }
                        value[axis] = scalar
                    } else {
                        var scalar: Double = 0
                        withUnsafeMutableBytes(of: &scalar) { target in target.copyBytes(from: bytes[offset..<offset + 8]) }
                        value[axis] = Float(scalar)
                    }
                }
                return value
            }
        }
    }

    static func simdVector(_ value: SceneVector3) -> SIMD3<Float> { SIMD3(Float(value.x), Float(value.y), Float(value.z)) }
    static func vector(_ value: SIMD3<Float>) -> SceneVector3 { SceneVector3(x: Double(value.x), y: Double(value.y), z: Double(value.z)) }
}
