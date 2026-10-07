import Foundation

enum ModelingBrush: String, CaseIterable {
    case draw = "Draw", clay = "Clay", inflate = "Inflate", crease = "Crease"
    case smooth = "Smooth", flatten = "Flatten", scrape = "Scrape", pinch = "Pinch", grab = "Grab", mask = "Mask"
    var help: String {
        switch self {
        case .draw: return "Raise or carve the surface along the brush normal."
        case .clay: return "Build a soft clay plateau; Control carves a shallow plane."
        case .inflate: return "Expand the surface along each vertex's own normal."
        case .crease: return "Carve a groove and pinch its sides; Control raises a ridge."
        case .smooth: return "Relax bumps without changing the mesh topology."
        case .flatten: return "Flatten towards the brush's tangent plane."
        case .scrape: return "Shave high points below the brush; Control fills low points."
        case .pinch: return "Pull a line together; Control spreads it apart."
        case .grab: return "Drag a whole region with soft falloff from its original shape."
        case .mask: return "Paint protection over the mesh. Control erases the mask."
        }
    }
}

extension ModelPoint {
    func dot(_ p: Self) -> Double { x*p.x + y*p.y + z*p.z }
    var mirroredX: Self { .init(x:-x,y:y,z:z) }
    var bounded: Self { .init(x:max(-100000,min(100000,x)),y:max(-100000,min(100000,y)),z:max(-100000,min(100000,z))) }
    var finite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

/// Cached once per stroke. Topology does not change while a brush is active.
struct ModelingSculptTopology {
    let neighbours: [[Int]]
    let incidentFaces: [[Int]]
    private let faceCount: Int
    init(_ mesh: ModelingMesh) {
        var links = Array(repeating:Set<Int>(),count:mesh.vertices.count)
        var incident = Array(repeating:[Int](),count:mesh.vertices.count)
        for (f,face) in mesh.faces.enumerated() { for i in face.indices {
            let a = face[i], b = face[(i+1)%face.count]; links[a].insert(b); links[b].insert(a)
            incident[a].append(f)
        } }
        neighbours = links.map { $0.sorted() }
        incidentFaces = incident; faceCount = mesh.faces.count
    }
    func matches(_ mesh: ModelingMesh) -> Bool { neighbours.count == mesh.vertices.count && faceCount == mesh.faces.count }
    /// Re-evaluate only faces touching the current brush footprint. A dense
    /// mesh no longer recalculates every vertex normal for every mouse stamp.
    func normals(for indices: [Int], in mesh: ModelingMesh) -> [Int:ModelPoint] {
        guard matches(mesh) else { return [:] }
        var faceNormals: [Int:ModelPoint] = [:]
        for i in indices { for f in incidentFaces[i] where faceNormals[f] == nil {
            let face = mesh.faces[f], a = mesh.vertices[face[0]]
            var n = ModelPoint()
            for j in 1..<face.count-1 { n = n+(mesh.vertices[face[j]]-a).cross(mesh.vertices[face[j+1]]-a) }
            faceNormals[f] = n
        } }
        var result: [Int:ModelPoint] = [:]; result.reserveCapacity(indices.count)
        for i in indices { result[i] = incidentFaces[i].reduce(ModelPoint()) { $0+(faceNormals[$1] ?? .init()) }.unit }
        return result
    }
}

extension ModelingMesh {
    func vertexNormals() -> [ModelPoint] {
        var result = Array(repeating:ModelPoint(),count:vertices.count)
        for face in faces {
            guard face.count >= 3, face.allSatisfy(vertices.indices.contains) else { continue }
            let a = vertices[face[0]]
            var normal = ModelPoint()
            for j in 1..<face.count-1 {
                normal = normal+(vertices[face[j]]-a).cross(vertices[face[j+1]]-a)
            }
            // Add polygon area once per corner, not once per render triangle.
            // Otherwise a quad's diagonal receives twice the normal weight.
            for v in face { result[v] = result[v]+normal }
        }
        return result.map(\.unit)
    }
    static func sculptSphere(detail: Int = 2) throws -> Self {
        guard (0...4).contains(detail) else { throw ModelingError.invalid("Use a sculpt sphere detail from 0 to 4. Higher levels would exceed the editing budget.") }
        var mesh = primitive("Sphere")
        for _ in 0..<detail { try mesh.subdivide(); mesh.vertices = mesh.vertices.map { $0.unit*0.5 } }
        return mesh
    }
    /// Cheap squared-distance prefilter so normals/falloff are calculated only
    /// for nearby vertices. Coordinates are mesh-local, including side hits.
    func sculptAffectedVertices(center: ModelPoint, radius: Double, symmetry: Bool = false) -> [Int] {
        guard center.finite, radius.isFinite, radius > 0 else { return [] }
        let r2 = radius*radius
        return vertices.indices.filter { i in
            let d = vertices[i]-center
            if d.dot(d) < r2 { return true }
            if symmetry { let mirror = vertices[i]-center.mirroredX; return mirror.dot(mirror) < r2 }
            return false
        }
    }
    /// Smooth falloff, zero at the brush boundary and one at its centre.
    static func influence(distance: Double, radius: Double) -> Double {
        guard radius.isFinite, radius > 0, distance.isFinite else { return 0 }
        let t = max(0,min(1,1-distance/radius)); return t*t*(3-2*t)
    }
    /// Spatial brush in mesh-local units. Overlapping symmetry regions use the
    /// strongest contribution once; the mirror plane stays welded.
    mutating func sculpt(brush: ModelingBrush, center: ModelPoint, normal: ModelPoint,
                         radius: Double, strength: Double, invert: Bool = false,
                         symmetry: Bool = false, frontOnly: Bool = true,
                         delta: ModelPoint = .init(), topology: ModelingSculptTopology? = nil) {
        guard center.finite, normal.finite, normal.length > 1e-8, delta.finite, radius.isFinite, radius > 0,
              strength.isFinite, strength > 0 else { return }
        let amount = min(1,strength), sign = invert ? -1.0 : 1.0, before = vertices
        let affected = sculptAffectedVertices(center:center,radius:radius,symmetry:symmetry)
        guard !affected.isEmpty else { return }
        let cached = topology?.matches(self) == true ? topology! : ModelingSculptTopology(self)
        let normals = frontOnly || brush == .inflate ? cached.normals(for:affected,in:self) : [:]
        var paintedMask = brush == .mask ? (sculptMask ?? Array(repeating:0.0,count:vertices.count)) : []
        let links = brush == .smooth ? cached.neighbours : []
        let samples = symmetry ? [(center,normal.unit,delta),(center.mirroredX,normal.mirroredX.unit,delta.mirroredX)] : [(center,normal.unit,delta)]
        for i in affected {
            let p = before[i]; var best = 0.0, displacement = ModelPoint()
            let protected = sculptMask?.indices.contains(i) == true ? sculptMask![i] : 0
            let editable = 1-protected
            for (c,n,d) in samples {
                let weight = Self.influence(distance:(p-c).length,radius:radius)
                guard weight > best, !frontOnly || (normals[i] ?? .init()).dot(n) > 0 else { continue }
                best = weight
                switch brush {
                case .draw: displacement = n*(radius*0.12*amount*weight*sign*editable)
                case .clay:
                    let planeDistance = (c+n*(radius*0.1*sign)-p).dot(n)
                    displacement = n*((invert ? min(0,planeDistance) : max(0,planeDistance))*amount*weight*0.25*editable)
                case .inflate: displacement = (normals[i] ?? .init())*(radius*0.12*amount*weight*sign*editable)
                case .crease:
                    let toward = c-p, tangent = toward-n*toward.dot(n)
                    displacement = (tangent*(0.2*sign)-n*(radius*0.08*sign))*(amount*weight*editable)
                case .smooth:
                    guard links.indices.contains(i), !links[i].isEmpty else { continue }
                    let average = links[i].reduce(ModelPoint()) { $0+before[$1] }*(1/Double(links[i].count))
                    displacement = (average-p)*(amount*weight*0.6*editable)
                case .flatten: displacement = n*((c-p).dot(n)*amount*weight*0.5*editable)
                case .scrape:
                    let planeDistance = (c-n*(radius*0.06*sign)-p).dot(n)
                    displacement = n*((invert ? max(0,planeDistance) : min(0,planeDistance))*amount*weight*0.5*editable)
                case .pinch:
                    let toward = c-p, tangent = toward-n*toward.dot(n)
                    displacement = tangent*(amount*weight*0.15*sign*editable)
                case .grab: displacement = d*(amount*weight*editable)
                case .mask: break // Commit only the strongest mirrored stamp below.
                }
            }
            if brush == .mask {
                paintedMask[i] = max(0,min(1,paintedMask[i]+amount*best*0.45*sign)); continue
            }
            if symmetry && abs(p.x) < 1e-8 { displacement.x = 0 }
            if displacement.finite { vertices[i] = (p+displacement).bounded }
        }
        if brush == .mask { sculptMask = paintedMask.contains(where:{ $0 > 0 }) ? paintedMask : nil }
    }
    mutating func clearSculptMask() { sculptMask = nil }
    mutating func invertSculptMask() {
        sculptMask = (sculptMask ?? Array(repeating:0.0,count:vertices.count)).map { 1-$0 }
        if sculptMask!.allSatisfy({ $0 == 0 }) { sculptMask = nil }
    }
    /// Two-pass smoothing reduces Laplacian shrinkage. Boundary vertices and
    /// fully painted masks stay fixed; topology and object transforms survive.
    mutating func relax(iterations: Int = 1) throws {
        guard (1...5).contains(iterations) else { throw ModelingError.invalid("Use one to five smoothing passes at a time.") }
        try validate()
        let topology = ModelingSculptTopology(self)
        struct Edge: Hashable { let a: Int, b: Int; init(_ a: Int, _ b: Int) { self.a = min(a,b); self.b = max(a,b) } }
        var edgeCounts: [Edge:Int] = [:]
        for face in faces { for i in face.indices { edgeCounts[Edge(face[i],face[(i+1)%face.count]),default:0] += 1 } }
        var boundary = Set<Int>()
        for (edge,count) in edgeCounts where count != 2 { boundary.insert(edge.a); boundary.insert(edge.b) }
        var candidate = self
        for _ in 0..<iterations { for factor in [0.35,-0.36] {
            let before = candidate.vertices
            for i in before.indices where !boundary.contains(i) && !topology.neighbours[i].isEmpty {
                let editable = 1-(sculptMask?[i] ?? 0)
                guard editable > 0 else { continue }
                let adjacent = topology.neighbours[i]
                let mean = adjacent.reduce(ModelPoint()) { $0+before[$1] }*(1/Double(adjacent.count))
                candidate.vertices[i] = before[i]+(mean-before[i])*(factor*editable)
            }
        } }
        try candidate.validate(); self = candidate
    }
    mutating func moveFace(_ face: Int, distance: Double) throws {
        guard faces.indices.contains(face), distance.isFinite else { throw ModelingError.invalid("Select a face and enter a finite distance.") }
        var candidate = self; let offset = normal(of:face)*distance
        for v in faces[face] { candidate.vertices[v] = vertices[v]+offset }
        try candidate.validate(); self = candidate
    }
    mutating func scaleFace(_ face: Int, factor: Double) throws {
        guard faces.indices.contains(face), factor.isFinite, factor > 0 else { throw ModelingError.invalid("Select a face and use a positive scale.") }
        var candidate = self; let center = center(of:face)
        for v in faces[face] { candidate.vertices[v] = center+(vertices[v]-center)*factor }
        try candidate.validate(); self = candidate
    }
}
