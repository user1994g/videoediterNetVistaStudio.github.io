import Foundation

enum ModelingDetail: String, CaseIterable {
    case draft = "Draft", balanced = "Balanced", high = "High"
    var sphereLevel: Int { switch self { case .draft: return 1; case .balanced: return 2; case .high: return 3 } }
    var radialSegments: Int { switch self { case .draft: return 10; case .balanced: return 16; case .high: return 24 } }
    var tubeSteps: Int { switch self { case .draft: return 5; case .balanced: return 8; case .high: return 12 } }
}

/// Original, procedural modelling starters. Parts are real editable meshes,
/// not images or imported third-party assets, and are deliberately kept
/// separate so horns, wings and limbs can be sculpted or repositioned.
enum ModelingGenerators {
    static func dragon(detail: ModelingDetail = .balanced) throws -> [ModelingObject] {
        var result: [ModelingObject] = []
        let level = detail.sphereLevel, radial = detail.radialSegments, steps = detail.tubeSteps
        func ellipsoid(_ name: String, _ center: ModelPoint, _ size: ModelPoint, _ colour: String = "#6F9285", _ detail: Int? = nil) throws {
            var mesh = try ModelingMesh.sculptSphere(detail:detail ?? level)
            mesh.vertices = mesh.vertices.map { .init(x:$0.x*size.x*2,y:$0.y*size.y*2,z:$0.z*size.z*2) }
            var object = ModelingObject(name:name,mesh:mesh); object.position = center; object.colour = colour; object.smoothShading = true
            result.append(object)
        }
        func tube(_ name: String, _ path: [ModelPoint], _ radii: [Double], _ colour: String = "#6F9285", radialOverride: Int? = nil) throws {
            let mesh = try sweptTube(path:path,radii:radii,radialSegments:radialOverride ?? radial,stepsPerSegment:steps)
            var object = ModelingObject(name:name,mesh:mesh); object.colour = colour; object.smoothShading = true
            result.append(object)
        }
        try ellipsoid("Dragon · body",.init(y:1.3),.init(x:0.62,y:0.58,z:1.04))
        try ellipsoid("Dragon · chest",.init(y:1.52,z:-0.63),.init(x:0.52,y:0.6,z:0.55))
        try tube("Dragon · neck",[.init(y:1.65,z:-0.72),.init(y:1.95,z:-1.18),.init(y:2.4,z:-1.42)],[0.37,0.3,0.25])
        try ellipsoid("Dragon · head",.init(y:2.46,z:-1.73),.init(x:0.4,y:0.32,z:0.48))
        try ellipsoid("Dragon · muzzle",.init(y:2.34,z:-2.17),.init(x:0.28,y:0.2,z:0.44))
        try ellipsoid("Dragon · lower jaw",.init(y:2.12,z:-2.13),.init(x:0.25,y:0.095,z:0.44),"#B4BE9B",max(0,level-1))
        try tube("Dragon · tail",[.init(y:1.3,z:0.78),.init(y:1.02,z:1.6),.init(x:0.24,y:0.68,z:2.5),.init(x:0.8,y:0.37,z:3.15),.init(x:1.24,y:0.55,z:3.66)],[0.37,0.27,0.18,0.09,0.009])
        for sign in [-1.0,1.0] {
            let side = sign < 0 ? "Left" : "Right"
            try tube("\(side) · front leg",[.init(x:sign*0.43,y:1.5,z:-0.58),.init(x:sign*0.73,y:0.84,z:-0.48),.init(x:sign*0.69,y:0.27,z:-0.91)],[0.22,0.16,0.12])
            try tube("\(side) · back leg",[.init(x:sign*0.4,y:1.26,z:0.66),.init(x:sign*0.76,y:0.67,z:0.95),.init(x:sign*0.69,y:0.23,z:0.45)],[0.31,0.21,0.15])
            for z in [-0.91,0.45] {
                let suffix = z < 0 ? "front" : "back"
                try ellipsoid("\(side) · \(suffix) foot",.init(x:sign*0.69,y:0.17,z:z-0.11),.init(x:0.2,y:0.12,z:0.32),"#577565",max(0,level-1))
                for toe in -1...1 {
                    let x = sign*0.69+Double(toe)*0.12
                    try tube("\(side) · \(suffix) claw \(toe+2)",[.init(x:x,y:0.18,z:z-0.32),.init(x:x,y:0.11,z:z-0.5),.init(x:x,y:0.08,z:z-0.58)],[0.045,0.024,0.005],"#DFD4B8",radialOverride:8)
                }
            }
            try tube("\(side) · crown horn",[.init(x:sign*0.24,y:2.66,z:-1.51),.init(x:sign*0.35,y:3.01,z:-1.24),.init(x:sign*0.41,y:3.16,z:-0.96)],[0.12,0.073,0.006],"#DFD4B8")
            try ellipsoid("\(side) · eye",.init(x:sign*0.355,y:2.51,z:-1.93),.init(x:0.065,y:0.072,z:0.1),"#E4A742",0)
            var wing = ModelingObject(name:"\(side) · wing membrane",mesh:try wingMesh(sign:sign,detail:detail)); wing.colour = "#7C5158"; wing.smoothShading = true
            result.append(wing)
            try tube("\(side) · wing leading edge",[.init(x:sign*0.47,y:1.71,z:-0.18),.init(x:sign*1.5,y:2.39,z:-0.58),.init(x:sign*3.1,y:2.12,z:-1.03)],[0.14,0.08,0.015],"#577565")
            for finger in 0..<3 {
                let r = Double(finger+1)/4, x = 0.65+2.45*r
                let y = 1.76+sin(r * .pi*0.85)*0.76
                let trailing = -0.18-0.85*r+0.05+1.45*sin(r * .pi*0.88)
                try tube("\(side) · wing finger \(finger+1)",[.init(x:sign*0.55,y:1.74,z:-0.12),.init(x:sign*x,y:y,z:-0.18-0.85*r),.init(x:sign*x,y:y-0.16,z:trailing)],[0.06,0.035,0.008],"#577565",radialOverride:8)
            }
        }
        for index in 0..<7 {
            let z = -0.65+Double(index)*0.38, y = z < 1 ? 1.89 : 1.69-(z-1)*0.24
            try tube("Back · crest \(index+1)",[.init(y:y,z:z),.init(y:y+0.29,z:z+0.02),.init(y:y+0.39,z:z+0.11)],[0.085,0.046,0.006],"#B5C1A4",radialOverride:8)
        }
        var document = ModelingDocument(); document.objects = result; try document.validate()
        return result
    }

    /// A capped, welded sweep with a parallel-transport frame. Catmull–Rom
    /// path sampling avoids faceted elbows and the frame avoids sudden twists.
    static func sweptTube(path: [ModelPoint], radii: [Double], radialSegments: Int = 16, stepsPerSegment: Int = 8) throws -> ModelingMesh {
        guard path.count >= 2, path.count <= 128, path.count == radii.count,
              path.allSatisfy(\.finite), radii.allSatisfy({ $0.isFinite && (0.001...1000).contains($0) }),
              (3...128).contains(radialSegments), (1...128).contains(stepsPerSegment) else { throw ModelingError.invalid("Use a valid finite tube path, positive radii and a bounded detail level.") }
        let count = (path.count-1)*stepsPerSegment+1
        guard count*radialSegments+2 <= ModelingLimits.meshVertices,
              (count-1)*radialSegments+radialSegments*2 <= ModelingLimits.meshFaces else { throw ModelingError.invalid("This swept part would exceed the mesh detail limit.") }
        func sample(_ segment: Int, _ t: Double) -> ModelPoint {
            let p0 = path[max(0,segment-1)], p1 = path[segment], p2 = path[segment+1], p3 = path[min(path.count-1,segment+2)]
            return (p1*2+(p2-p0)*t+(p0*2-p1*5+p2*4-p3)*(t*t)+(p1*3-p0-p2*3+p3)*(t*t*t))*0.5
        }
        var centers: [ModelPoint] = [], sizes: [Double] = []
        for segment in 0..<path.count-1 { for step in 0..<stepsPerSegment {
            let t = Double(step)/Double(stepsPerSegment)
            centers.append(sample(segment,t)); sizes.append(radii[segment]*(1-t)+radii[segment+1]*t)
        } }
        centers.append(path.last!); sizes.append(radii.last!)
        var mesh = ModelingMesh(), previous = ModelPoint(x:1)
        for i in centers.indices {
            let tangent = (centers[min(i+1,count-1)]-centers[max(0,i-1)]).unit
            guard tangent.length > 0.5 else { throw ModelingError.invalid("Remove repeated or reversing points from the swept path.") }
            var u = (previous-tangent*previous.dot(tangent)).unit
            if u.length < 0.5 { let reference = abs(tangent.y) < 0.9 ? ModelPoint(y:1) : ModelPoint(z:1); u = tangent.cross(reference).unit }
            let v = tangent.cross(u).unit; previous = u
            for j in 0..<radialSegments {
                let angle = Double(j)*2 * .pi/Double(radialSegments)
                mesh.vertices.append(centers[i]+(u*cos(angle)+v*sin(angle))*sizes[i])
            }
        }
        for i in 0..<count-1 { for j in 0..<radialSegments {
            let a = i*radialSegments+j, b = i*radialSegments+(j+1)%radialSegments
            mesh.faces.append([a,b,b+radialSegments,a+radialSegments])
        } }
        let first = mesh.vertices.count; mesh.vertices.append(centers[0])
        let last = mesh.vertices.count; mesh.vertices.append(centers.last!)
        let lastRing = (count-1)*radialSegments
        for j in 0..<radialSegments {
            let next = (j+1)%radialSegments
            mesh.faces.append([first,next,j]); mesh.faces.append([last,lastRing+j,lastRing+next])
        }
        try mesh.validate(); return mesh
    }

    private static func wingMesh(sign: Double, detail: ModelingDetail) throws -> ModelingMesh {
        let rows = detail == .draft ? 12 : (detail == .balanced ? 24 : 40)
        let columns = detail == .draft ? 8 : (detail == .balanced ? 14 : 24)
        var mesh = ModelingMesh()
        let surfaceSize = (rows+1)*(columns+1)
        for side in [-1.0,1.0] { for row in 0...rows { for col in 0...columns {
            let r = Double(row)/Double(rows), s = Double(col)/Double(columns)
            let x = sign*(0.65+2.45*r), y = 1.76+sin(r * .pi*0.85)*0.76-s*0.16+side*0.018
            let width = 0.05+1.45*sin(r * .pi*0.88)*(1-0.12*sin(r * .pi*6)*sin(r * .pi*6))
            mesh.vertices.append(.init(x:x,y:y,z:-0.18-0.85*r+width*s))
        } } }
        for side in 0..<2 { for row in 0..<rows { for col in 0..<columns {
            let a = side*surfaceSize+row*(columns+1)+col, b = a+columns+1
            let face = [a,b,b+1,a+1]
            mesh.faces.append(side == 0 ? face : Array(face.reversed()))
        } } }
        var boundary: [Int] = []
        boundary += (0...rows).map { $0*(columns+1) }
        boundary += (1...columns).map { rows*(columns+1)+$0 }
        boundary += stride(from:rows-1,through:0,by:-1).map { $0*(columns+1)+columns }
        if columns > 1 { boundary += stride(from:columns-1,through:1,by:-1) }
        for i in boundary.indices { let a = boundary[i], b = boundary[(i+1)%boundary.count]; mesh.faces.append([b,a,a+surfaceSize,b+surfaceSize]) }
        // Left/right mirroring reverses handedness; keep all normals outward.
        if sign < 0 { mesh.faces = mesh.faces.map { Array($0.reversed()) } }
        try mesh.validate(); return mesh
    }
}
