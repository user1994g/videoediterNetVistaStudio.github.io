import Foundation

@main struct ModelingGeneratorsChecks {
    static func main() throws {
        var previousCount = 0
        for detail in ModelingDetail.allCases {
            let started = Date(), parts = try ModelingGenerators.dragon(detail:detail)
            var document = ModelingDocument(); document.name = "Original dragon"; document.objects = parts
            try document.validate()
            let count = parts.reduce(0) { $0+$1.mesh.vertices.count }
            precondition(count > previousCount && count <= ModelingLimits.projectVertices)
            previousCount = count
            precondition(parts.contains { $0.name.contains("tail") } && parts.contains { $0.name.contains("wing membrane") } && parts.contains { $0.name.contains("crown horn") })
            for part in parts {
                precondition(part.mesh.vertices.allSatisfy(\.finite))
                precondition(part.mesh.faces.indices.allSatisfy { part.mesh.normal(of:$0).length > 0.9 },"\(part.name) contains a degenerate face")
                var edges: [String:Int] = [:]
                for face in part.mesh.faces { for i in face.indices {
                    let a = face[i], b = face[(i+1)%face.count]; edges["\(min(a,b))/\(max(a,b))",default:0] += 1
                } }
                precondition(edges.values.allSatisfy { $0 == 2 },"\(part.name) should be a capped, welded part")
            }
            let data = try JSONEncoder().encode(document), restored = try JSONDecoder().decode(ModelingDocument.self,from:data)
            try restored.validate(); precondition(restored == document)
            var body = parts[0].mesh; let sample = body.vertices[0]
            body.sculpt(brush:.draw,center:sample,normal:sample.unit,radius:0.2,strength:0.4,topology:ModelingSculptTopology(body))
            precondition(body != parts[0].mesh,"Dragon starter parts must be directly sculptable")
            print("\(detail.rawValue) dragon: \(parts.count) editable parts, \(count) vertices, \(parts.reduce(0) { $0+$1.mesh.faces.count }) faces; generated and checked in \(Date().timeIntervalSince(started)) seconds")
        }
        let tube = try ModelingGenerators.sweptTube(path:[.init(),.init(y:1),.init(x:0.5,y:2)],radii:[0.2,0.1,0.005])
        precondition(tube.faces.count > 100)
        for invalidRadii in [[0.2],[-0.2,0.1,0.01],[.nan,0.1,0.01]] {
            do { _ = try ModelingGenerators.sweptTube(path:[.init(),.init(y:1),.init(y:2)],radii:invalidRadii); preconditionFailure("Invalid generator input accepted") } catch {}
        }
        do { _ = try ModelingGenerators.sweptTube(path:[.init(),.init()],radii:[0.1,0.1]); preconditionFailure("Degenerate sweep accepted") } catch {}
        print("PASS: original draft/balanced/high editable dragon starters, welded closed parts, finite geometry, real sculpting, native round trips and malformed generator inputs")
    }
}
