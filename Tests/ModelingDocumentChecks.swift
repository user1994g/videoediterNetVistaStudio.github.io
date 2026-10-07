import Foundation

@main struct ModelingDocumentChecks {
    static func main() throws {
        for name in ["Cube","Plane","Cylinder","Sphere"] {
            var mesh = ModelingMesh.primitive(name); try mesh.validate()
            precondition(mesh.faces.allSatisfy { face in let index = mesh.faces.firstIndex(of:face)!; return mesh.normal(of:index).length > 0.9 })
            let before = mesh.faces.count; try mesh.subdivide(); try mesh.validate(); precondition(mesh.faces.count == before*4)
        }
        var cube = ModelingMesh.primitive("Cube")
        precondition(cube.vertices.count == 8 && cube.faces.count == 6)
        precondition(cube.normal(of:5).y == 1)
        for direction in 0...1 {
            var cut = cube
            cut.sculptMask = cut.vertices.map { $0.x+0.5 }
            let preview = try cut.loopCutPreview(face:5,direction:direction,fraction:0.25)
            precondition(preview.faceCount == 4 && preview.result == .init(vertices:12,faces:10),"A cube loop splits four faces and shares four new edge points")
            let beforeCut = cut
            let splitFaces = try cut.loopCut(face:5,direction:direction,fraction:0.25)
            try cut.validate(); precondition(splitFaces.count == 8 && cut.faces.count == 10 && cut.vertices.count == 12)
            precondition(cut.sculptMask!.count == 12)
            for i in cut.vertices.indices { precondition(abs(cut.sculptMask![i]-(cut.vertices[i].x+0.5)) < 1e-8,"Loop-cut masks must interpolate at the actual cut point") }
            var cutEdges: [String:Int] = [:]
            for ring in cut.faces { for i in ring.indices { let a = ring[i], b = ring[(i+1)%ring.count]; cutEdges["\(min(a,b))/\(max(a,b))",default:0] += 1 } }
            precondition(cutEdges.values.allSatisfy { $0 == 2 },"Loop cut must stay watertight, with no duplicate points or T-junctions")
            for f in beforeCut.faces.indices where splitFaces.contains(f) { precondition(cut.normal(of:f).dot(beforeCut.normal(of:f)) > 0.99,"Cut faces retain their original winding") }
            let roundtrip = try ModelingMesh.readOBJ(Data((try ModelingDocument(objects:[ModelingObject(name:"Cut cube",mesh:cut)]).obj()).utf8))
            precondition(roundtrip == ModelingMesh(vertices:cut.vertices,faces:cut.faces))
        }
        var planeCut = ModelingMesh.primitive("Plane"); try planeCut.subdivide()
        let planarPreview = try planeCut.loopCutPreview(face:0,direction:0,fraction:0.5)
        precondition(planarPreview.faceCount == 2)
        try planeCut.loopCut(face:0,direction:0,fraction:0.5); try planeCut.validate()
        precondition(planeCut.faces.count == 6 && planeCut.vertices.count == 12,"An open quad strip shares the middle cut point and stops at mesh boundaries")
        var mixed = ModelingMesh(vertices:[.init(),.init(x:1),.init(x:1,y:1),.init(y:1),.init(x:0.5,y:-1)],faces:[[0,1,2,3],[1,0,4]])
        let mixedBefore = mixed
        do { try mixed.loopCut(face:0,direction:0); preconditionFailure("A cut into an unsplit triangle would create a T-junction") } catch {}
        precondition(mixed == mixedBefore)
        var badWinding = mixed; badWinding.faces[1] = [0,1,4]
        let badWindingBefore = badWinding
        do { try badWinding.loopCut(face:0); preconditionFailure("Inconsistent strip winding accepted") } catch {}
        precondition(badWinding == badWindingBefore)
        var branched = cube; branched.faces.append(cube.faces[5]); let branchedBefore = branched
        do { try branched.loopCut(face:5); preconditionFailure("Non-manifold loop edge accepted") } catch {}
        precondition(branched == branchedBefore)
        do { _ = try branched.adjustedFaceSelection([5],operation:"linked"); preconditionFailure("Non-manifold selection query accepted") } catch {}
        var collapsed = ModelingMesh(vertices:[.init(),.init(x:1),.init(x:2),.init(x:3)],faces:[[0,1,2,3]])
        let collapsedBefore = collapsed
        do { try collapsed.loopCut(face:0); preconditionFailure("Collapsed quad accepted") } catch {}
        precondition(collapsed == collapsedBefore)
        var exhausted = cube; exhausted.vertices += Array(repeating:.init(),count:ModelingLimits.meshVertices-cube.vertices.count)
        let exhaustedBefore = exhausted
        do { try exhausted.loopCut(face:5); preconditionFailure("Over-budget cut accepted") } catch {}
        precondition(exhausted == exhaustedBefore)
        for fraction in [Double.nan,0,1] {
            var invalidCut = cube
            do { try invalidCut.loopCut(face:5,fraction:fraction); preconditionFailure("Invalid cut position accepted") } catch {}
            precondition(invalidCut == cube)
        }
        var individual = cube; individual.sculptMask = Array(repeating:0.4,count:cube.vertices.count)
        try individual.extrudeIndividualFaces([0,5],distance:0.2)
        try individual.validate(); precondition(individual.vertices.count == 16 && individual.faces.count == 14)
        precondition(individual.sculptMask!.allSatisfy { $0 == 0.4 })
        precondition(individual.vertices[individual.faces[0][0]].z < -0.5 && individual.vertices[individual.faces[5][0]].y > 0.5,"Individual caps follow different face normals")
        let beforeIndividual = individual
        do { try individual.extrudeIndividualFaces([999],distance:0.2); preconditionFailure("Invalid face accepted") } catch {}
        precondition(individual == beforeIndividual)
        let grown = try cube.adjustedFaceSelection([5],operation:"grow")
        precondition(grown.count == 5 && !grown.contains(4))
        let shrunk = try cube.adjustedFaceSelection(grown,operation:"shrink")
        precondition(shrunk == [5])
        let linked = try cube.adjustedFaceSelection([5],operation:"linked")
        precondition(linked == Set(cube.faces.indices))
        let island = try ModelingMesh.joined([ModelingObject(name:"A",mesh:cube),ModelingObject(name:"B",mesh:cube)])
        let islandSelection = try island.adjustedFaceSelection([5],operation:"linked")
        precondition(islandSelection == Set(0..<6),"Linked selection must not jump to a separate coincident island")
        try cube.extrude(face:5,distance:1)
        precondition(cube.vertices.count == 12 && cube.faces.count == 10)
        precondition(cube.faces[5].allSatisfy { cube.vertices[$0].y == 1.5 })
        try cube.extrude(face:5,distance:0,inset:0.2)
        precondition(cube.vertices.count == 16 && cube.faces.count == 14)
        var edges: [String:Int] = [:]
        for face in cube.faces { for i in face.indices { let a = face[i], b = face[(i+1)%face.count]; edges["\(min(a,b))/\(max(a,b))",default:0] += 1 } }
        precondition(edges.values.allSatisfy { $0 == 2 },"Extrusion and inset must keep the cube watertight")
        var subdivided = ModelingMesh.primitive("Cube"); try subdivided.subdivide(); precondition(subdivided.vertices.count == 26,"Neighbours must share midpoint vertices")
        let flatEstimate = try ModelingMesh.primitive("Cube").subdivisionEstimate()
        precondition(flatEstimate == .init(vertices:26,faces:24) && flatEstimate.withinLimit)
        var rounded = ModelingMesh.primitive("Cube"); rounded.sculptMask = Array(repeating:0.5,count:8)
        let smoothEstimate = try rounded.subdivisionEstimate(smooth:true)
        try rounded.subdivide(smooth:true); try rounded.validate()
        precondition(rounded.vertices.count == smoothEstimate.vertices && rounded.faces.count == smoothEstimate.faces)
        precondition(rounded.vertices.prefix(8).allSatisfy { $0.length < sqrt(0.75) },"Smooth detail should round a cube; flat detail should not")
        precondition(rounded.sculptMask!.allSatisfy { $0 == 0.5 },"Smooth detail preserves and interpolates sculpt protection")
        var roundedEdges: [String:Int] = [:]
        for face in rounded.faces { for i in face.indices { let a = face[i], b = face[(i+1)%face.count]; roundedEdges["\(min(a,b))/\(max(a,b))",default:0] += 1 } }
        precondition(roundedEdges.values.allSatisfy { $0 == 2 },"Smooth subdivision must remain welded/watertight")
        var smoothPlane = ModelingMesh.primitive("Plane"); try smoothPlane.subdivide(smooth:true)
        precondition(smoothPlane.vertices.count == 9 && smoothPlane.faces.count == 4)
        precondition(smoothPlane.vertices.prefix(4).allSatisfy { $0.y == 0 && abs($0.x) == 0.75 && abs($0.z) == 0.75 },"Open boundary rule should be stable and planar")
        let triangle = ModelingMesh(vertices:[.init(),.init(x:1),.init(y:1)],faces:[[0,1,2]])
        var smoothTriangle = triangle; let triangleEstimate = try triangle.subdivisionEstimate(smooth:true)
        try smoothTriangle.subdivide(smooth:true)
        precondition(smoothTriangle.vertices.count == triangleEstimate.vertices && smoothTriangle.faces.count == 3 && smoothTriangle.faces.allSatisfy { $0.count == 4 })
        var nonmanifold = ModelingMesh(vertices:[.init(),.init(x:1),.init(y:1),.init(z:1),.init(y:-1)],faces:[[0,1,2],[1,0,3],[0,1,4]])
        let nonmanifoldOriginal = nonmanifold
        do { try nonmanifold.subdivide(smooth:true); preconditionFailure("Non-manifold smooth detail accepted") } catch {}
        precondition(nonmanifold == nonmanifoldOriginal,"Rejected detail must leave the original mesh intact")
        var denseCube = ModelingMesh.primitive("Cube")
        for _ in 0..<7 { try denseCube.subdivide() }
        precondition(denseCube.faces.count == 98_304 && denseCube.vertices.count > 50_000,"Detail should surpass the previous 50k budget")
        let denseBefore = denseCube, overEstimate = try denseCube.subdivisionEstimate()
        precondition(!overEstimate.withinLimit)
        do { try denseCube.subdivide(); preconditionFailure("Over-budget subdivision accepted") } catch {}
        precondition(denseCube == denseBefore,"Budget rejection must happen before modifying the mesh")
        var region = subdivided
        region.sculptMask = region.vertices.map { max(0,min(1,$0.y+0.5)) }
        let top = Set(20..<24), originalRegion = region, patch = try region.vertices(in:top)
        try region.moveRegion(top,distance:0.2)
        for i in originalRegion.vertices.indices {
            precondition((region.vertices[i] - originalRegion.vertices[i]).length < 1e-8 || patch.contains(i))
            if patch.contains(i) { precondition(abs(region.vertices[i].y - originalRegion.vertices[i].y - 0.2) < 1e-8,"Shared region points move once") }
        }
        region = originalRegion
        try region.extrudeRegion(top,distance:0.5)
        precondition(region.vertices.count == 35 && region.faces.count == 32,"Region extrusion needs nine shared cap vertices and eight boundary walls, not four isolated extrusions")
        var regionEdges: [String:Int] = [:]
        for face in region.faces { for i in face.indices {
            let a = face[i], b = face[(i+1)%face.count]; regionEdges["\(min(a,b))/\(max(a,b))",default:0] += 1
        } }
        precondition(regionEdges.values.allSatisfy { $0 == 2 },"Connected region extrusion stays watertight")
        precondition(region.sculptMask!.count == region.vertices.count && region.sculptMask!.suffix(9).allSatisfy { $0 == 1 })
        let extruded = region
        try region.scaleRegion(top,factor:0.5); try region.validate()
        precondition(region != extruded)
        region.deleteFaces(top); try region.validate()
        precondition(region.faces.count == 28 && region.sculptMask!.count == region.vertices.count)
        var masked = ModelingMesh.primitive("Cube"); masked.sculptMask = Array(repeating:0.5,count:8)
        try masked.subdivide(); precondition(masked.sculptMask!.count == 26 && masked.sculptMask!.allSatisfy { $0 == 0.5 })
        let beforeInvalidRegion = originalRegion
        region = beforeInvalidRegion
        for selected in [Set<Int>(),Set([99]),Set([16,20])] {
            do { try region.extrudeRegion(selected,distance:0.2); preconditionFailure("Invalid/opposing face patch accepted") } catch {}
            precondition(region == beforeInvalidRegion,"A failed region edit must be atomic")
        }
        var invalidMask = masked; invalidMask.sculptMask = [1]
        do { try invalidMask.validate(); preconditionFailure("Short mask accepted") } catch {}
        invalidMask.sculptMask = Array(repeating:.nan,count:26)
        do { try invalidMask.validate(); preconditionFailure("Non-finite mask accepted") } catch {}
        var doc = ModelingDocument(); var object = ModelingObject(name:"My model",mesh:cube)
        object.position = .init(x:2,y:-3,z:4); object.rotation = .init(x:25,y:65,z:-30); object.scale = .init(x:2,y:0.5,z:3)
        for point in cube.vertices { precondition((object.local(object.world(point))-point).length < 1e-8) }
        doc.objects = [object]
        var joinFirst = object; joinFirst.mesh.sculptMask = Array(repeating:0.75,count:object.mesh.vertices.count)
        var second = ModelingObject(name:"Other",mesh:masked); second.position.x = -2; second.mesh.sculptMask = nil
        let joined = try ModelingMesh.joined([joinFirst,second]); try joined.validate()
        precondition(joined.vertices.count == object.mesh.vertices.count+second.mesh.vertices.count)
        precondition(joined.faces.suffix(second.mesh.faces.count) == second.mesh.faces.map { $0.map { $0+object.mesh.vertices.count } })
        precondition(joined.sculptMask!.suffix(second.mesh.vertices.count).allSatisfy { $0 == 0 })
        for i in object.mesh.vertices.indices { precondition(joined.vertices[i] == object.world(object.mesh.vertices[i])) }
        let output = try doc.obj(); let restoredMesh = try ModelingMesh.readOBJ(Data(output.utf8))
        precondition(restoredMesh.faces == cube.faces)
        for i in cube.vertices.indices { precondition((restoredMesh.vertices[i]-object.world(cube.vertices[i])).length < 1e-8) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".netvistamodel")
        defer { try? FileManager.default.removeItem(at:file) }
        try doc.save(file); let loaded = try ModelingDocument.open(file); precondition(doc == loaded)
        for text in ["v 0 0 0\nf 1 2 3", "v nan 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3", "v 0 0 0\nf 1 1 1"] {
            do { _ = try ModelingMesh.readOBJ(Data(text.utf8)); preconditionFailure("Invalid OBJ accepted") } catch {}
        }
        let negative = try ModelingMesh.readOBJ(Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf -3/1 -2/2 -1/3".utf8)); precondition(negative.faces == [[0,1,2]])
        let before = cube
        do { try cube.extrude(face:999,distance:1); preconditionFailure() } catch {}
        precondition(cube == before)
        cube.deleteFace(0); try cube.validate(); precondition(cube.faces.count == before.faces.count-1)
        var invalid = doc; invalid.objects[0].scale.x = 0
        do { try invalid.save(file); preconditionFailure() } catch {}
        let preserved = try ModelingDocument.open(file); precondition(preserved == doc)
        var tooMany = ModelingMesh(vertices:Array(repeating:.init(),count:ModelingLimits.meshVertices+1))
        do { try tooMany.validate(); preconditionFailure("Over-budget mesh accepted") } catch {}
        tooMany = .primitive("Cube"); tooMany.faces = Array(repeating:tooMany.faces[0],count:ModelingLimits.meshFaces)
        var tooLargeProject = ModelingDocument()
        tooLargeProject.objects = (0..<3).map { ModelingObject(name:"Many faces \($0)",mesh:tooMany) }
        do { try tooLargeProject.validate(); preconditionFailure("Global face budget ignored") } catch {}
        var highDocument = ModelingDocument(); highDocument.objects = [ModelingObject(name:"High detail",mesh:denseCube)]
        try highDocument.save(file); let highRestored = try ModelingDocument.open(file)
        precondition(highRestored == highDocument,"Dense native meshes should round-trip")
        print("PASS: welded closed/open quad-loop cuts, mask interpolation, individual-face extrusion, selection queries, atomic triangle/winding/non-manifold/budget refusals, high-detail subdivision and native/OBJ round trips")
    }
}
