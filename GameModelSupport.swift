import Cocoa
import SceneKit
import SceneKit.ModelIO
import ModelIO
import simd

/// Converts supported source meshes into portable normalized triangle data.
/// The original files stay embedded too; the game never depends on their source location.
enum GameModelImporter {
    static var extensions: [String] { ["obj","dae","stl","ply","usd","usda","usdc","usdz","scn"].filter { ["dae","scn","obj","stl"].contains($0) || MDLAsset.canImportFileExtension($0) } }
    static func importModels(_ urls: [URL], into project: GameProject) throws -> GameProject {
        var candidate = project
        for url in urls {
            let directory = try url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true
            let start = candidate.assets.count
            try candidate.importFiles([url])
            let originals = Array(candidate.assets.dropFirst(start))
            let base = url.standardizedFileURL.resolvingSymlinksInPath()
            for asset in originals where extensions.contains(URL(fileURLWithPath:asset.path).pathExtension.lowercased()) {
                let source: URL
                if directory {
                    let relative = asset.path.split(separator:"/").dropFirst(2).joined(separator:"/")
                    source = base.appendingPathComponent(relative)
                } else { source = base }
                let mesh = try load(source)
                let data = try JSONEncoder().encode(mesh)
                let meshAsset = GameAsset(path:asset.path + ".nvmesh",data:data)
                candidate.assets.append(meshAsset)
            }
        }
        try candidate.validate(); return candidate
    }
    static func load(_ url: URL) throws -> GameMesh {
        if url.pathExtension.lowercased() == "stl" { return try GameMesh.stl(Data(contentsOf:url)) }
        if url.pathExtension.lowercased() == "obj" { return try GameMesh.obj(Data(contentsOf:url)) }
        let root: SCNNode
        if ["dae","scn"].contains(url.pathExtension.lowercased()) {
            root = try SCNScene(url:url,options:[.animationImportPolicy:SCNSceneSource.AnimationImportPolicy.doNotPlay,.checkConsistency:true]).rootNode
        } else {
            let asset = MDLAsset(url:url); root = SCNScene(mdlAsset:asset).rootNode
        }
        var mesh = GameMesh(), failure: Error?
        let visit: (SCNNode) -> Void = { node in
            guard failure == nil, let geometry = node.geometry, let vertices = geometry.sources(for:.vertex).first else { return }
            let uv = geometry.sources(for:.texcoord).first
            func component(_ source:SCNGeometrySource,_ index:Int,_ axis:Int) throws -> Float {
                let offset = source.dataOffset + index*source.dataStride + axis*source.bytesPerComponent
                guard index >= 0, index < source.vectorCount, source.usesFloatComponents, [4,8].contains(source.bytesPerComponent), axis < source.componentsPerVector, offset >= 0, offset + source.bytesPerComponent <= source.data.count else { throw GameProjectError.invalid("Unsupported model vertex format.") }
                let bytes = source.data.subdata(in:offset..<offset+source.bytesPerComponent)
                let value: Float = bytes.withUnsafeBytes { b in source.bytesPerComponent == 4 ? b.loadUnaligned(as:Float.self) : Float(b.loadUnaligned(as:Double.self)) }
                guard value.isFinite else { throw GameProjectError.invalid("The model contains invalid coordinates.") }; return value
            }
            do {
                for element in geometry.elements {
                    guard [.triangles,.triangleStrip].contains(element.primitiveType) else { continue }
                    let count = element.primitiveType == .triangles ? element.primitiveCount*3 : element.primitiveCount+2
                    guard count <= 900000, [1,2,4].contains(element.bytesPerIndex), count*element.bytesPerIndex <= element.data.count else { throw GameProjectError.invalid("Model geometry exceeds the supported limits.") }
                    func index(_ n:Int) -> Int { let offset = n*element.bytesPerIndex; return (0..<element.bytesPerIndex).reduce(0) { $0 | Int(element.data[offset+$1]) << ($1*8) } }
                    for triangle in 0..<element.primitiveCount {
                        let indices = element.primitiveType == .triangles ? [triangle*3,triangle*3+1,triangle*3+2] : triangle % 2 == 0 ? [triangle,triangle+1,triangle+2] : [triangle+1,triangle,triangle+2]
                        for offset in indices {
                            let i = index(offset)
                            let p = try SCNVector3(component(vertices,i,0),component(vertices,i,1),component(vertices,i,2))
                            let world = root.convertPosition(p,from:node)
                            mesh.positions += [Float(world.x),Float(world.y),Float(world.z)]
                            mesh.uv += try uv.map { [try component($0,i,0),try component($0,i,1)] } ?? [0,0]
                        }
                        guard mesh.positions.count <= 900000 else { throw GameProjectError.invalid("Use a model with up to 100,000 triangles.") }
                    }
                }
            } catch { failure = error }
        }
        visit(root); root.enumerateChildNodes { node,_ in visit(node) }
        if let failure { throw failure }
        guard !mesh.positions.isEmpty else { throw GameProjectError.invalid("No supported triangle geometry was found. Export an OBJ, DAE or triangulated mesh and try again.") }
        var low = SIMD3<Float>(repeating:.greatestFiniteMagnitude), high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in stride(from:0,to:mesh.positions.count,by:3) { let p = SIMD3(mesh.positions[i],mesh.positions[i+1],mesh.positions[i+2]); low = simd_min(low,p); high = simd_max(high,p) }
        let span = max(0.00001,max(high.x-low.x,max(high.y-low.y,high.z-low.z)))
        for i in mesh.positions.indices { mesh.positions[i] = (mesh.positions[i] - (low[i%3]+high[i%3])/2)/span }
        return mesh
    }
}

/// Real weighted skeletal deformation. Each vertex blends its four nearest bone segments.
/// Fitted joints are saved; binding is deterministic and rebuilt from the portable mesh.
final class GameRigRenderer {
    let root = SCNNode()
    private var bones: [SCNNode] = []
    let rig: GameCharacterRig
    init(mesh: GameMesh, rig: GameCharacterRig, material: SCNMaterial) {
        self.rig = rig
        let skeleton = SCNNode(); root.addChildNode(skeleton)
        for joint in rig.joints {
            let node = SCNNode(); node.name = joint.name
            let parent = joint.parent.map { rig.joints[$0] }
            node.position = SCNVector3(joint.x-(parent?.x ?? 0),joint.y-(parent?.y ?? 0),joint.z-(parent?.z ?? 0))
            (joint.parent.map { bones[$0] } ?? skeleton).addChildNode(node); bones.append(node)
        }
        let vertices = stride(from:0,to:mesh.positions.count,by:3).map { SCNVector3(mesh.positions[$0],mesh.positions[$0+1],mesh.positions[$0+2]) }
        let uv = stride(from:0,to:mesh.uv.count,by:2).map { CGPoint(x:Double(mesh.uv[$0]),y:Double(mesh.uv[$0+1])) }
        let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(textureCoordinates:uv)],elements:[SCNGeometryElement(indices:Array(0..<Int32(vertices.count)),primitiveType:.triangles)])
        geometry.materials = [material]
        var weights: [Float] = [], indices: [UInt16] = []
        func point(_ j:GameRigJoint) -> SIMD3<Float> { SIMD3(Float(j.x),Float(j.y),Float(j.z)) }
        for vertex in vertices {
            let p = SIMD3(Float(vertex.x),Float(vertex.y),Float(vertex.z))
            var distances: [(Int,Float)] = []
            for (i,joint) in rig.joints.enumerated() {
                let a = point(joint)
                var distance = Float.greatestFiniteMagnitude
                for child in rig.joints where child.parent == i {
                    let vector = point(child)-a
                    let denominator: Float = max(0.000001,simd_length_squared(vector))
                    let t: Float = max(0,min(1,simd_dot(p-a,vector)/denominator))
                    distance = min(distance,simd_length_squared(p-(a+vector*t)))
                }
                if distance == Float.greatestFiniteMagnitude { distance = simd_length_squared(p-a) }
                distances.append((i,distance))
            }
            distances.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
            distances = Array(distances.prefix(4))
            let raw = distances.map { 1 / pow(max(0.00001,$0.1),2) }; let sum = raw.reduce(0,+)
            indices += distances.map { UInt16($0.0) }; weights += raw.map { $0/sum }
            for _ in distances.count..<4 { indices.append(0); weights.append(0) }
        }
        let weightSource = SCNGeometrySource(data:weights.withUnsafeBytes { Data($0) },semantic:.boneWeights,vectorCount:vertices.count,usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)
        let indexSource = SCNGeometrySource(data:indices.withUnsafeBytes { Data($0) },semantic:.boneIndices,vectorCount:vertices.count,usesFloatComponents:false,componentsPerVector:4,bytesPerComponent:2,dataOffset:0,dataStride:8)
        let inverses = rig.joints.map { NSValue(scnMatrix4:SCNMatrix4MakeTranslation(-$0.x,-$0.y,-$0.z)) }
        let body = SCNNode(geometry:geometry)
        body.skinner = SCNSkinner(baseGeometry:geometry,bones:bones,boneInverseBindTransforms:inverses,boneWeights:weightSource,boneIndices:indexSource)
        body.skinner?.skeleton = skeleton; body.skinner?.baseGeometryBindTransform = SCNMatrix4Identity; root.addChildNode(body)
    }
    func pose(time:Double, walking:Bool) {
        root.childNode(withName:"rig-guides",recursively:false)?.isHidden = walking
        let swing = walking ? sin(time * rig.speed * .pi * 2) * rig.stride * .pi / 180 : 0
        for (i,joint) in rig.joints.enumerated() {
            let sign = joint.name.hasPrefix("Left") ? 1.0 : -1.0
            let value = joint.name.contains("thigh") ? swing*sign : joint.name.contains("knee") ? max(0,-swing*sign)*0.7 : joint.name.contains("arm") ? -swing*sign : 0
            bones[i].eulerAngles.x = value
            bones[i].eulerAngles.z = walking && joint.name.contains("arm") ? -sign * .pi/2 : 0
        }
    }
    func guides(selected:Int?) {
        root.childNode(withName:"rig-guides",recursively:false)?.removeFromParentNode()
        let guides = SCNNode(); guides.name = "rig-guides"; root.addChildNode(guides)
        for (i,j) in rig.joints.enumerated() {
            if let parent = j.parent {
                let p = rig.joints[parent]
                let vector = SIMD3(Float(j.x-p.x),Float(j.y-p.y),Float(j.z-p.z))
                let length = simd_length(vector)
                if length > 0.00001 {
                    let line = SCNNode(geometry:SCNCylinder(radius:0.004,height:CGFloat(length)))
                    line.position = SCNVector3((j.x+p.x)/2,(j.y+p.y)/2,(j.z+p.z)/2)
                    line.simdOrientation = simd_quatf(from:SIMD3<Float>(0,1,0),to:simd_normalize(vector))
                    let material = SCNMaterial(); material.diffuse.contents = NSColor.systemTeal; material.lightingModel = .constant; material.readsFromDepthBuffer = false; material.writesToDepthBuffer = false
                    line.geometry?.materials = [material]; line.renderingOrder = 99; guides.addChildNode(line)
                }
            }
            let node = SCNNode(geometry:SCNSphere(radius:0.012)); node.position = SCNVector3(j.x,j.y,j.z)
            let material = SCNMaterial(); material.diffuse.contents = i == selected ? NSColor.systemOrange : NSColor.systemTeal; material.lightingModel = .constant; material.readsFromDepthBuffer = false; material.writesToDepthBuffer = false; node.geometry?.materials = [material]; node.renderingOrder = 100; guides.addChildNode(node)
        }
    }
}
