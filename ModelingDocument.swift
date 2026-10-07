import Foundation

struct ModelPoint: Codable, Equatable {
    var x: Double = 0, y: Double = 0, z: Double = 0
    static func + (a: Self, b: Self) -> Self { .init(x:a.x+b.x,y:a.y+b.y,z:a.z+b.z) }
    static func - (a: Self, b: Self) -> Self { .init(x:a.x-b.x,y:a.y-b.y,z:a.z-b.z) }
    static func * (a: Self, b: Double) -> Self { .init(x:a.x*b,y:a.y*b,z:a.z*b) }
    var length: Double { sqrt(x*x+y*y+z*z) }
    var unit: Self { length > 1e-10 ? self * (1/length) : .init() }
    func cross(_ b: Self) -> Self { .init(x:y*b.z-z*b.y,y:z*b.x-x*b.z,z:x*b.y-y*b.x) }
    func rotated(_ degrees: Self, inverse: Bool = false) -> Self {
        func axis(_ p: Self, _ n: Int, _ angle: Double) -> Self {
            let c = cos(angle), s = sin(angle)
            switch n {
            case 0: return .init(x:p.x,y:p.y*c-p.z*s,z:p.y*s+p.z*c)
            case 1: return .init(x:p.x*c+p.z*s,y:p.y,z: -p.x*s+p.z*c)
            default: return .init(x:p.x*c-p.y*s,y:p.x*s+p.y*c,z:p.z)
            }
        }
        let angles = [degrees.x,degrees.y,degrees.z]
        return (inverse ? [2,1,0] : [0,1,2]).reduce(self) { axis($0,$1,angles[$1] * .pi/180 * (inverse ? -1 : 1)) }
    }
}

enum ModelingError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

/// Explicit working limits keep high-detail subdivision from allocating an
/// unbounded mesh. These are editing limits, not claims about render quality.
enum ModelingLimits {
    static let meshVertices = 250_000
    static let meshFaces = 250_000
    static let projectVertices = 500_000
    static let projectFaces = 500_000
    static let projectBytes = 128 * 1024 * 1024
    static let objBytes = 64 * 1024 * 1024
}

struct ModelingMeshEstimate: Equatable {
    let vertices: Int
    let faces: Int
    var withinLimit: Bool { vertices <= ModelingLimits.meshVertices && faces <= ModelingLimits.meshFaces }
}

struct ModelingCutSegment: Equatable {
    let start: ModelPoint, end: ModelPoint
}

struct ModelingLoopCutPreview: Equatable {
    let segments: [ModelingCutSegment]
    let result: ModelingMeshEstimate
    var faceCount: Int { segments.count }
}

private struct ModelingEdge: Hashable {
    let a: Int, b: Int
    init(_ first: Int, _ second: Int) { a = min(first,second); b = max(first,second) }
}

struct ModelingMesh: Codable, Equatable {
    var vertices: [ModelPoint] = []
    var faces: [[Int]] = []
    /// Per-vertex protection: zero is editable, one is fully masked. Optional
    /// so version-1 projects written before sculpt masks remain readable.
    var sculptMask: [Double]? = nil
    func validate() throws {
        guard vertices.count <= ModelingLimits.meshVertices, faces.count <= ModelingLimits.meshFaces,
              vertices.allSatisfy({ [$0.x,$0.y,$0.z].allSatisfy { $0.isFinite && abs($0) <= 100000 } }),
              faces.allSatisfy({ (3...4).contains($0.count) && Set($0).count == $0.count && $0.allSatisfy(vertices.indices.contains) }) else {
            throw ModelingError.invalid("Use a mesh of up to 250,000 vertices and 250,000 triangular or quad faces, with valid vertex references.")
        }
        if let sculptMask {
            guard sculptMask.count == vertices.count,
                  sculptMask.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw ModelingError.invalid("The sculpt mask must contain one finite 0–1 value per vertex.")
            }
        }
    }
    func center(of face: Int) -> ModelPoint { faces[face].reduce(ModelPoint()) { $0 + vertices[$1] } * (1/Double(faces[face].count)) }
    func normal(of face: Int) -> ModelPoint {
        let indices = faces[face]
        var n = ModelPoint()
        for i in indices.indices {
            let a = vertices[indices[i]], b = vertices[indices[(i+1)%indices.count]]
            n.x += (a.y-b.y)*(a.z+b.z); n.y += (a.z-b.z)*(a.x+b.x); n.z += (a.x-b.x)*(a.y+b.y)
        }
        return n.unit
    }
    /// Keep the original boundary and replace the cap with a new connected ring.
    /// No duplicate internal cap is left behind.
    mutating func extrude(face: Int, distance: Double, inset: Double = 0) throws {
        guard faces.indices.contains(face), distance.isFinite, abs(distance) <= 1000, inset.isFinite, (0...0.95).contains(inset) else { throw ModelingError.invalid("Select a face and use a valid extrusion or inset amount.") }
        let ring = faces[face], n = normal(of:face), c = center(of:face)
        guard n.length > 0.5 else { throw ModelingError.invalid("This face has no usable surface normal. Move its vertices apart first.") }
        var candidate = self
        let start = candidate.vertices.count
        candidate.vertices += ring.map { c + (vertices[$0]-c)*(1-inset) + n*distance }
        if sculptMask != nil { candidate.sculptMask! += ring.map { sculptMask![$0] } }
        candidate.faces[face] = Array(start..<start+ring.count)
        for i in ring.indices { let j = (i+1)%ring.count; candidate.faces.append([ring[i],ring[j],start+j,start+i]) }
        try candidate.validate(); self = candidate
    }
    mutating func deleteFace(_ face: Int) {
        deleteFaces(Set([face]))
    }
    mutating func deleteFaces(_ selection: Set<Int>) {
        guard !selection.isEmpty, selection.allSatisfy(faces.indices.contains) else { return }
        faces = faces.enumerated().filter { !selection.contains($0.offset) }.map(\.element)
        let used = Set(faces.flatMap { $0 }).sorted(); let map = Dictionary(uniqueKeysWithValues:used.enumerated().map { ($0.element,$0.offset) })
        if let sculptMask { self.sculptMask = used.map { sculptMask[$0] } }
        vertices = used.map { vertices[$0] }; faces = faces.map { $0.map { map[$0]! } }
    }
    func vertices(in selection: Set<Int>) throws -> Set<Int> {
        guard !selection.isEmpty, selection.allSatisfy(faces.indices.contains) else {
            throw ModelingError.invalid("Select one or more valid faces first.")
        }
        return Set(selection.flatMap { faces[$0] })
    }
    func regionNormal(_ selection: Set<Int>) throws -> ModelPoint {
        _ = try vertices(in:selection)
        let normal = selection.reduce(ModelPoint()) { $0 + self.normal(of:$1) }.unit
        guard normal.length > 0.5 else { throw ModelingError.invalid("The selected faces point in opposing directions. Select a surface patch instead of the entire closed mesh.") }
        return normal
    }
    /// Region extrusion duplicates shared vertices only once and builds walls
    /// only on the patch boundary. Neighbouring caps stay connected.
    mutating func extrudeRegion(_ selection: Set<Int>, distance: Double) throws {
        guard distance.isFinite, abs(distance) <= 1000 else { throw ModelingError.invalid("Use a finite extrusion distance up to 1,000 units.") }
        let selectedVertices = try vertices(in:selection).sorted(), normal = try regionNormal(selection)
        var edges: [String:[(Int,Int)]] = [:]
        for f in selection { let ring = faces[f]; for j in ring.indices {
            let a = ring[j], b = ring[(j+1)%ring.count], key = "\(min(a,b))/\(max(a,b))"
            edges[key,default:[]].append((a,b))
        } }
        guard edges.values.allSatisfy({ $0.count <= 2 && ($0.count == 1 || ($0[0].0 == $0[1].1 && $0[0].1 == $0[1].0)) }) else {
            throw ModelingError.invalid("The selected patch contains inconsistent or non-manifold edges. Choose consistently wound neighbouring faces.")
        }
        let boundary = edges.keys.sorted().compactMap { edges[$0]!.count == 1 ? edges[$0]!.first : nil }
        guard !boundary.isEmpty else { throw ModelingError.invalid("This face selection has no boundary to extrude.") }
        var candidate = self
        let map = Dictionary(uniqueKeysWithValues:selectedVertices.enumerated().map { ($0.element,vertices.count+$0.offset) })
        candidate.vertices += selectedVertices.map { vertices[$0]+normal*distance }
        if sculptMask != nil { candidate.sculptMask! += selectedVertices.map { sculptMask![$0] } }
        for f in selection { candidate.faces[f] = faces[f].map { map[$0]! } }
        candidate.faces += boundary.map { [$0.0,$0.1,map[$0.1]!,map[$0.0]!] }
        try candidate.validate(); self = candidate
    }
    /// Each cap follows its own face normal. Shared outer vertices remain
    /// attached to the surrounding surface; neighbouring new caps are separate.
    /// Build once and validate once, rather than repeatedly copying a dense mesh.
    mutating func extrudeIndividualFaces(_ selection: Set<Int>, distance: Double, inset: Double = 0) throws {
        try validate(); _ = try vertices(in:selection)
        guard distance.isFinite, abs(distance) <= 1000, inset.isFinite, (0...0.95).contains(inset),
              abs(distance) > 1e-10 || inset > 0 else {
            throw ModelingError.invalid("Use a non-zero extrusion distance or inset fraction.")
        }
        let added = selection.reduce(0) { $0+faces[$1].count }
        guard vertices.count+added <= ModelingLimits.meshVertices, faces.count+added <= ModelingLimits.meshFaces else {
            throw ModelingError.invalid("This individual-face operation exceeds the per-mesh geometry limit. Select fewer faces.")
        }
        var candidate = self
        candidate.vertices.reserveCapacity(vertices.count+added); candidate.faces.reserveCapacity(faces.count+added)
        for f in selection.sorted() {
            let ring = faces[f], n = normal(of:f), c = center(of:f), start = candidate.vertices.count
            guard n.length > 0.5 else { throw ModelingError.invalid("One selected face has no usable normal. Repair its vertices before extruding.") }
            candidate.vertices += ring.map { c+(vertices[$0]-c)*(1-inset)+n*distance }
            if let sculptMask { candidate.sculptMask! += ring.map { sculptMask[$0] } }
            candidate.faces[f] = Array(start..<start+ring.count)
            for i in ring.indices { let j = (i+1)%ring.count; candidate.faces.append([ring[i],ring[j],start+j,start+i]) }
        }
        try candidate.validate(); self = candidate
    }

    /// Face selection is edge-connected: touching at only one vertex does not
    /// select another island. These queries never mutate geometry or history.
    func adjustedFaceSelection(_ selection: Set<Int>, operation: String) throws -> Set<Int> {
        try validate(); _ = try vertices(in:selection)
        var edgeFaces: [ModelingEdge:[Int]] = [:]
        for (f,ring) in faces.enumerated() { for i in ring.indices {
            edgeFaces[ModelingEdge(ring[i],ring[(i+1)%ring.count]),default:[]].append(f)
        } }
        guard edgeFaces.values.allSatisfy({ $0.count <= 2 }) else {
            throw ModelingError.invalid("Face-selection growth needs manifold edges. Repair edges shared by more than two faces first.")
        }
        var neighbours = Array(repeating:Set<Int>(),count:faces.count)
        var boundary = Set<Int>()
        for linked in edgeFaces.values {
            if linked.count == 1 { boundary.insert(linked[0]) }
            for f in linked { neighbours[f].formUnion(linked.filter { $0 != f }) }
        }
        switch operation {
        case "grow": return selection.reduce(selection) { $0.union(neighbours[$1]) }
        case "shrink": return selection.filter { !boundary.contains($0) && neighbours[$0].isSubset(of:selection) }
        case "linked":
            var result = selection, pending = selection.sorted(), cursor = 0
            while cursor < pending.count {
                let f = pending[cursor]; cursor += 1
                for next in neighbours[f].sorted() where result.insert(next).inserted { pending.append(next) }
            }
            return result
        default: throw ModelingError.invalid("Choose Grow, Shrink or Linked face selection.")
        }
    }

    private struct LoopCutPlan {
        var faceEdges: [Int:Int] = [:]
        var fractions: [ModelingEdge:Double] = [:]
    }
    /// Propagate across opposite edges of a quad strip. A triangle is rejected
    /// instead of silently leaving a T-junction in its unsplit shared edge.
    private func loopCutPlan(face: Int, direction: Int, fraction: Double) throws -> LoopCutPlan {
        try validate()
        guard faces.indices.contains(face), faces[face].count == 4, (0...1).contains(direction),
              fraction.isFinite, (0.01...0.99).contains(fraction) else {
            throw ModelingError.invalid("Select a quad face, a loop direction and a position between 1% and 99%.")
        }
        var edgeFaces: [ModelingEdge:[(face:Int,edge:Int)]] = [:]
        for (f,ring) in faces.enumerated() { for i in ring.indices {
            edgeFaces[ModelingEdge(ring[i],ring[(i+1)%ring.count]),default:[]].append((f,i))
        } }
        var plan = LoopCutPlan(), pending: [(Int,Int,Double)] = [(face,direction,fraction)], cursor = 0
        while cursor < pending.count {
            let (f,entry,ratio) = pending[cursor]; cursor += 1
            let ring = faces[f]
            guard ring.count == 4, normal(of:f).length > 0.5 else {
                throw ModelingError.invalid("Loop cuts need a continuous quad strip with usable faces. This loop reaches a triangle or collapsed face.")
            }
            if let prior = plan.faceEdges[f] {
                guard prior%2 == entry%2 else { throw ModelingError.invalid("This quad strip crosses itself. Try the other direction or repair the topology.") }
            } else { plan.faceEdges[f] = entry }
            for (e,t) in [(entry,ratio),((entry+2)%4,1-ratio)] {
                let a = ring[e], b = ring[(e+1)%4], key = ModelingEdge(a,b), canonical = a == key.a ? t : 1-t
                if let existing = plan.fractions[key] {
                    guard abs(existing-canonical) < 1e-8 else { throw ModelingError.invalid("This loop twists into itself. Use the centre position or repair the topology.") }
                    continue
                }
                plan.fractions[key] = canonical
                let linked = edgeFaces[key]!
                guard linked.count <= 2 else { throw ModelingError.invalid("Loop cuts cannot cross a non-manifold edge shared by more than two faces.") }
                if let next = linked.first(where: { $0.face != f }) {
                    let other = faces[next.face]
                    guard other[next.edge] == b && other[(next.edge+1)%other.count] == a else {
                        throw ModelingError.invalid("The quad strip has inconsistent face winding. Repair it before cutting.")
                    }
                    pending.append((next.face,next.edge,1-t))
                }
            }
        }
        guard vertices.count+plan.fractions.count <= ModelingLimits.meshVertices,
              faces.count+plan.faceEdges.count <= ModelingLimits.meshFaces else {
            throw ModelingError.invalid("This loop cut exceeds the per-mesh geometry limit. Use a less detailed mesh.")
        }
        return plan
    }
    func loopCutPreview(face: Int, direction: Int, fraction: Double) throws -> ModelingLoopCutPreview {
        let plan = try loopCutPlan(face:face,direction:direction,fraction:fraction)
        func point(_ edge: ModelingEdge) -> ModelPoint { vertices[edge.a]+(vertices[edge.b]-vertices[edge.a])*plan.fractions[edge]! }
        let segments = plan.faceEdges.keys.sorted().map { f -> ModelingCutSegment in
            let ring = faces[f], i = plan.faceEdges[f]!
            return .init(start:point(ModelingEdge(ring[i],ring[(i+1)%4])),end:point(ModelingEdge(ring[(i+2)%4],ring[(i+3)%4])))
        }
        return .init(segments:segments,result:.init(vertices:vertices.count+plan.fractions.count,faces:faces.count+plan.faceEdges.count))
    }
    /// Preview and Apply use the same plan. Split-edge points are shared once,
    /// original face winding is preserved, and masks interpolate at each cut.
    @discardableResult mutating func loopCut(face: Int, direction: Int = 0, fraction: Double = 0.5) throws -> Set<Int> {
        let plan = try loopCutPlan(face:face,direction:direction,fraction:fraction)
        var candidate = self, points: [ModelingEdge:Int] = [:], selection = Set(plan.faceEdges.keys)
        for edge in plan.fractions.keys.sorted(by: { $0.a == $1.a ? $0.b < $1.b : $0.a < $1.a }) {
            let t = plan.fractions[edge]!; points[edge] = candidate.vertices.count
            candidate.vertices.append(vertices[edge.a]+(vertices[edge.b]-vertices[edge.a])*t)
            if let sculptMask { candidate.sculptMask!.append(sculptMask[edge.a]+(sculptMask[edge.b]-sculptMask[edge.a])*t) }
        }
        for f in plan.faceEdges.keys.sorted() {
            let original = faces[f], e = plan.faceEdges[f]!, ring = (0..<4).map { original[(e+$0)%4] }
            let p = points[ModelingEdge(ring[0],ring[1])]!, q = points[ModelingEdge(ring[2],ring[3])]!
            candidate.faces[f] = [ring[0],p,q,ring[3]]
            selection.insert(candidate.faces.count); candidate.faces.append([p,ring[1],ring[2],q])
        }
        try candidate.validate(); self = candidate; return selection
    }
    mutating func moveRegion(_ selection: Set<Int>, distance: Double) throws {
        guard distance.isFinite, abs(distance) <= 1000 else { throw ModelingError.invalid("Use a finite move distance up to 1,000 units.") }
        let points = try vertices(in:selection), offset = try regionNormal(selection)*distance
        var candidate = self
        for v in points { candidate.vertices[v] = vertices[v]+offset }
        try candidate.validate(); self = candidate
    }
    mutating func scaleRegion(_ selection: Set<Int>, factor: Double) throws {
        guard factor.isFinite, factor > 0 else { throw ModelingError.invalid("Use a positive finite scale factor.") }
        let points = try vertices(in:selection), center = points.reduce(ModelPoint()) { $0+vertices[$1] }*(1/Double(points.count))
        var candidate = self
        for v in points { candidate.vertices[v] = center+(vertices[v]-center)*factor }
        try candidate.validate(); self = candidate
    }
    /// Counts the result before creating any new vertices. A smooth pass turns
    /// each triangle into three quads and each quad into four quads.
    func subdivisionEstimate(smooth: Bool = false) throws -> ModelingMeshEstimate {
        try validate()
        var edges = Set<ModelingEdge>()
        for face in faces { for i in face.indices { edges.insert(ModelingEdge(face[i],face[(i+1)%face.count])) } }
        return .init(vertices:vertices.count+edges.count+(smooth ? faces.count : faces.filter { $0.count == 4 }.count),
                     faces:smooth ? faces.reduce(0) { $0+$1.count } : faces.count*4)
    }
    /// Welded midpoint subdivision preserves the current surface. Smooth
    /// subdivision uses Catmull–Clark and keeps open boundary edges connected.
    mutating func subdivide(smooth: Bool = false) throws {
        let estimate = try subdivisionEstimate(smooth:smooth)
        guard estimate.withinLimit else { throw ModelingError.invalid("This subdivision needs \(estimate.vertices) vertices and \(estimate.faces) faces. The per-mesh limit is 250,000 of each. Use a lower detail level or separate parts.") }
        if smooth { try subdivideSmooth(estimate:estimate); return }
        var result = Self(vertices:vertices,sculptMask:sculptMask), edges: [ModelingEdge:Int] = [:]
        result.vertices.reserveCapacity(estimate.vertices); result.faces.reserveCapacity(estimate.faces)
        func midpoint(_ a: Int, _ b: Int) -> Int {
            let key = ModelingEdge(a,b)
            if let index = edges[key] { return index }
            let index = result.vertices.count; result.vertices.append((vertices[a]+vertices[b])*0.5)
            if let sculptMask { result.sculptMask!.append((sculptMask[a]+sculptMask[b])*0.5) }
            edges[key] = index; return index
        }
        for face in faces {
            if face.count == 3 {
                let a = midpoint(face[0],face[1]), b = midpoint(face[1],face[2]), c = midpoint(face[2],face[0])
                result.faces += [[face[0],a,c],[a,face[1],b],[c,b,face[2]],[a,b,c]]
            } else {
                let center = result.vertices.count; result.vertices.append(face.reduce(ModelPoint()) { $0+vertices[$1] }*0.25)
                if let sculptMask { result.sculptMask!.append(face.reduce(0) { $0+sculptMask[$1] }*0.25) }
                let mids = face.indices.map { midpoint(face[$0],face[($0+1)%4]) }
                for i in 0..<4 { result.faces.append([face[i],mids[i],center,mids[(i+3)%4]]) }
            }
        }
        try result.validate(); self = result
    }

    private mutating func subdivideSmooth(estimate: ModelingMeshEstimate) throws {
        var edgeFaces: [ModelingEdge:[Int]] = [:]
        var incidentFaces = Array(repeating:[Int](),count:vertices.count)
        var incidentEdges = Array(repeating:Set<ModelingEdge>(),count:vertices.count)
        for (f,face) in faces.enumerated() { for i in face.indices {
            let a = face[i], b = face[(i+1)%face.count], edge = ModelingEdge(a,b)
            edgeFaces[edge,default:[]].append(f); incidentFaces[a].append(f)
            incidentEdges[a].insert(edge); incidentEdges[b].insert(edge)
        } }
        guard edgeFaces.values.allSatisfy({ $0.count <= 2 }) else { throw ModelingError.invalid("Smooth subdivision needs a manifold surface: an edge cannot belong to more than two faces.") }
        let facePoints = faces.map { face in face.reduce(ModelPoint()) { $0+vertices[$1] }*(1/Double(face.count)) }
        var result = Self(vertices:vertices,sculptMask:sculptMask)
        result.vertices.reserveCapacity(estimate.vertices); result.faces.reserveCapacity(estimate.faces)
        for i in vertices.indices where !incidentFaces[i].isEmpty {
            let boundary = incidentEdges[i].filter { edgeFaces[$0]!.count == 1 }.map { $0.a == i ? $0.b : $0.a }
            if boundary.count == 2 {
                result.vertices[i] = vertices[i]*0.75+(vertices[boundary[0]]+vertices[boundary[1]])*0.125
            } else if !boundary.isEmpty {
                throw ModelingError.invalid("Smooth subdivision needs a continuous boundary. Repair branching or isolated edges first.")
            } else {
                let count = Double(incidentFaces[i].count)
                let f = incidentFaces[i].reduce(ModelPoint()) { $0+facePoints[$1] }*(1/count)
                let r = incidentEdges[i].reduce(ModelPoint()) { $0+(vertices[$1.a]+vertices[$1.b])*0.5 }*(1/Double(incidentEdges[i].count))
                result.vertices[i] = (f+r*2+vertices[i]*(count-3))*(1/count)
            }
        }
        var edgeIndex: [ModelingEdge:Int] = [:]
        // Sorted order makes the generated mesh deterministic for undo/tests.
        for edge in edgeFaces.keys.sorted(by:{ $0.a == $1.a ? $0.b < $1.b : $0.a < $1.a }) {
            let owners = edgeFaces[edge]!, index = result.vertices.count
            edgeIndex[edge] = index
            let point = owners.count == 2 ? (vertices[edge.a]+vertices[edge.b]+facePoints[owners[0]]+facePoints[owners[1]])*0.25 : (vertices[edge.a]+vertices[edge.b])*0.5
            result.vertices.append(point)
            // Protection is interpolated, never silently removed by a detail pass.
            if let sculptMask { result.sculptMask!.append((sculptMask[edge.a]+sculptMask[edge.b])*0.5) }
        }
        for (f,face) in faces.enumerated() {
            let center = result.vertices.count; result.vertices.append(facePoints[f])
            if let sculptMask { result.sculptMask!.append(face.reduce(0) { $0+sculptMask[$1] }/Double(face.count)) }
            for i in face.indices {
                let after = edgeIndex[ModelingEdge(face[i],face[(i+1)%face.count])]!
                let before = edgeIndex[ModelingEdge(face[(i+face.count-1)%face.count],face[i])]!
                result.faces.append([face[i],after,center,before])
            }
        }
        try result.validate(); self = result
    }

    /// Join parts into one editable mesh without pretending to perform a
    /// boolean union. Their transforms are baked; overlapping surfaces remain.
    static func joined(_ objects: [ModelingObject]) throws -> Self {
        var result = Self(), masks: [Double] = []
        let needsMask = objects.contains { $0.mesh.sculptMask != nil }
        guard objects.reduce(0,{ $0+$1.mesh.vertices.count }) <= ModelingLimits.meshVertices,
              objects.reduce(0,{ $0+$1.mesh.faces.count }) <= ModelingLimits.meshFaces else { throw ModelingError.invalid("Joining these parts would exceed 250,000 vertices or faces. Keep some parts separate.") }
        for object in objects {
            try object.mesh.validate()
            let offset = result.vertices.count
            result.vertices += object.mesh.vertices.map { object.world($0) }
            result.faces += object.mesh.faces.map { $0.map { $0+offset } }
            if needsMask { masks += object.mesh.sculptMask ?? Array(repeating:0,count:object.mesh.vertices.count) }
        }
        if needsMask { result.sculptMask = masks }
        try result.validate(); return result
    }
    static func primitive(_ kind: String) -> Self {
        if kind == "Cube" {
            let v = (0..<8).map { i in ModelPoint(x:i&1 == 0 ? -0.5 : 0.5,y:i&2 == 0 ? -0.5 : 0.5,z:i&4 == 0 ? -0.5 : 0.5) }
            return .init(vertices:v,faces:[[0,2,3,1],[4,5,7,6],[0,4,6,2],[1,3,7,5],[0,1,5,4],[2,6,7,3]])
        }
        if kind == "Plane" { return .init(vertices:[.init(x:-1,z:-1),.init(x:-1,z:1),.init(x:1,z:1),.init(x:1,z:-1)],faces:[[0,1,2,3]]) }
        var mesh = Self()
        let segments = 24
        if kind == "Cylinder" {
            for y in [-0.5,0.5] { for i in 0..<segments { let t = Double(i)*2 * .pi/Double(segments); mesh.vertices.append(.init(x:cos(t)*0.5,y:y,z:sin(t)*0.5)) } }
            mesh.vertices += [.init(y:-0.5),.init(y:0.5)]
            for i in 0..<segments { let j = (i+1)%segments; mesh.faces += [[i,i+segments,j+segments,j],[48,i,j],[49,j+segments,i+segments]] }
        } else { // UV sphere with welded poles and seam.
            mesh.vertices = [.init(y:0.5)]
            for row in 1..<12 { let p = Double(row) * .pi/12; for i in 0..<segments { let t = Double(i)*2 * .pi/Double(segments); mesh.vertices.append(.init(x:sin(p)*cos(t)*0.5,y:cos(p)*0.5,z:sin(p)*sin(t)*0.5)) } }
            let bottom = mesh.vertices.count; mesh.vertices.append(.init(y:-0.5))
            for i in 0..<segments {
                let j = (i+1)%segments; mesh.faces.append([0,1+j,1+i])
                for row in 0..<10 { let a = 1+row*segments; mesh.faces.append([a+i,a+j,a+segments+j,a+segments+i]) }
                mesh.faces.append([bottom,1+10*segments+i,1+10*segments+j])
            }
        }
        return mesh
    }
    static func readOBJ(_ data: Data) throws -> Self {
        guard data.count <= ModelingLimits.objBytes, let text = String(data:data,encoding:.utf8) else { throw ModelingError.invalid("Import a UTF-8 OBJ file smaller than 64 MB.") }
        var mesh = Self()
        for line in text.split(whereSeparator:\.isNewline) {
            let fields = line.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)[0].split(whereSeparator:\.isWhitespace)
            if fields.first == "v" {
                let v = fields.dropFirst().prefix(3).compactMap { Double($0) }
                guard v.count == 3, mesh.vertices.count < ModelingLimits.meshVertices else { throw ModelingError.invalid("Invalid OBJ vertex or more than 250,000 vertices.") }
                mesh.vertices.append(.init(x:v[0],y:v[1],z:v[2]))
            } else if fields.first == "f" {
                guard (4...5).contains(fields.count), mesh.faces.count < ModelingLimits.meshFaces else { throw ModelingError.invalid("Import up to 250,000 triangle or quad OBJ faces. Triangulate larger polygons before importing.") }
                let indices = try fields.dropFirst().map { field -> Int in
                    guard let first = field.split(separator:"/",omittingEmptySubsequences:false).first, let index = Int(first), index != 0 else { throw ModelingError.invalid("An OBJ face has an invalid vertex reference.") }
                    return index < 0 ? mesh.vertices.count+index : index-1
                }
                mesh.faces.append(indices)
            }
        }
        guard !mesh.faces.isEmpty else { throw ModelingError.invalid("The OBJ contains no faces.") }
        try mesh.validate(); return mesh
    }
}

struct ModelingObject: Codable, Equatable {
    var id = UUID()
    var name: String
    var mesh: ModelingMesh
    var position = ModelPoint()
    var rotation = ModelPoint()
    var scale = ModelPoint(x:1,y:1,z:1)
    var colour = "#92A9BE"
    var visible = true
    // Optional for backwards-compatible decoding of existing version-1 files.
    var smoothShading: Bool? = nil
    var physics: ModelingPhysicsSettings? = nil
    func world(_ point: ModelPoint) -> ModelPoint { ModelPoint(x:point.x*scale.x,y:point.y*scale.y,z:point.z*scale.z).rotated(rotation) + position }
    func local(_ point: ModelPoint) -> ModelPoint { let p = (point-position).rotated(rotation,inverse:true); return .init(x:p.x/scale.x,y:p.y/scale.y,z:p.z/scale.z) }
}

struct ModelingDocument: Codable, Equatable {
    var format = "netvista-model"
    var version = 1
    var name = "Untitled Model"
    var objects: [ModelingObject] = []
    func validate() throws {
        guard format == "netvista-model", version == 1, name.count <= 256, objects.count <= 256,
              Set(objects.map(\.id)).count == objects.count,
              objects.reduce(0,{ $0+$1.mesh.vertices.count }) <= ModelingLimits.projectVertices,
              objects.reduce(0,{ $0+$1.mesh.faces.count }) <= ModelingLimits.projectFaces else { throw ModelingError.invalid("Invalid modelling project, or too much geometry (256 objects, 500,000 total vertices and faces maximum).") }
        for o in objects {
            try o.mesh.validate()
            try o.physics?.validate()
            guard o.name.count <= 256, [o.position.x,o.position.y,o.position.z,o.rotation.x,o.rotation.y,o.rotation.z].allSatisfy({ $0.isFinite && abs($0) <= 100000 }),
                  [o.scale.x,o.scale.y,o.scale.z].allSatisfy({ $0.isFinite && (0.001...1000).contains($0) }),
                  o.colour.utf8.count == 7, o.colour.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil else { throw ModelingError.invalid("An object's transform or colour is invalid.") }
        }
    }
    func save(_ url: URL) throws {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= ModelingLimits.projectBytes else { throw ModelingError.invalid("Keep a modelling project under 128 MB. Save large parts separately.") }
        try data.write(to:url,options:.atomic)
    }
    static func open(_ url: URL) throws -> Self {
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= ModelingLimits.projectBytes else { throw ModelingError.invalid("Use a modelling project under 128 MB.") }
        let result = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url)); try result.validate(); return result
    }
    func obj() throws -> String {
        try validate(); var lines = ["# NetVista Studio 3D Editor — geometry only; transforms baked"], offset = 1
        for object in objects where object.visible && !object.mesh.faces.isEmpty {
            lines.append("o " + object.name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined())
            for vertex in object.mesh.vertices { let p = object.world(vertex); lines.append("v \(p.x) \(p.y) \(p.z)") }
            for face in object.mesh.faces { lines.append("f " + face.map { String($0+offset) }.joined(separator:" ")) }
            offset += object.mesh.vertices.count
        }
        guard offset > 1 else { throw ModelingError.invalid("Add a visible mesh before exporting.") }
        return lines.joined(separator:"\n") + "\n"
    }
}
