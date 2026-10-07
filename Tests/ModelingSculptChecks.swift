import Foundation

@main struct ModelingSculptChecks {
    static func main() throws {
        let sphere = try ModelingMesh.sculptSphere()
        precondition(sphere.faces.count == ModelingMesh.primitive("Sphere").faces.count*16)
        precondition(sphere.vertices.allSatisfy { abs($0.length-0.5) < 1e-9 })
        let center = ModelPoint(y:0.5), normal = ModelPoint(y:1), topology = ModelingSculptTopology(sphere)
        let nearby = sphere.sculptAffectedVertices(center:center,radius:0.2)
        let partialNormals = topology.normals(for:nearby,in:sphere), fullNormals = sphere.vertexNormals()
        precondition(!nearby.isEmpty && nearby.count < sphere.vertices.count/5)
        for i in nearby { precondition((partialNormals[i]!-fullNormals[i]).length < 1e-8,"Local normals must match full-mesh normals") }
        var sideSculpt = sphere
        sideSculpt.sculpt(brush:.draw,center:.init(x:0.5),normal:.init(x:1),radius:0.15,strength:1,topology:topology)
        precondition(sideSculpt.vertices.contains { $0.x > 0.5 },"A brush placed on the model's side must actually deform its side")
        for i in sphere.vertices.indices where sphere.vertices[i].x <= 0 { precondition(sideSculpt.vertices[i] == sphere.vertices[i]) }
        for brush in ModelingBrush.allCases {
            var edited = sphere
            edited.sculpt(brush:brush,center:center,normal:normal,radius:0.3,strength:0.5,delta:ModelPoint(y:0.2),topology:topology)
            try edited.validate()
            precondition(edited != sphere,"\(brush) must change real vertices")
            precondition(edited.faces == sphere.faces && edited.vertices.count == sphere.vertices.count)
            for i in sphere.vertices.indices where sphere.vertices[i].y < 0 {
                precondition(edited.vertices[i] == sphere.vertices[i],"Brush must not touch the opposite side")
            }
        }
        var raised = sphere, carved = sphere
        raised.sculpt(brush:.draw,center:center,normal:normal,radius:0.3,strength:1)
        carved.sculpt(brush:.draw,center:center,normal:normal,radius:0.3,strength:1,invert:true)
        precondition(raised.vertices[0].y > 0.5 && carved.vertices[0].y < 0.5)
        precondition(abs(raised.vertices[0].y+carved.vertices[0].y-1) < 1e-9)
        var protected = sphere
        for _ in 0..<3 { protected.sculpt(brush:.mask,center:center,normal:normal,radius:0.3,strength:1) }
        precondition(protected.vertices == sphere.vertices && protected.sculptMask![0] == 1,"Mask painting is non-destructive")
        for brush in ModelingBrush.allCases where brush != .mask {
            var changed = protected
            changed.sculpt(brush:brush,center:center,normal:normal,radius:0.3,strength:1,delta:.init(y:0.2),topology:topology)
            precondition(changed.vertices[0] == sphere.vertices[0],"\(brush) must respect full protection")
        }
        let maskBeforeErase = protected.sculptMask![0]
        protected.sculpt(brush:.mask,center:center,normal:normal,radius:0.3,strength:1,invert:true)
        precondition(protected.sculptMask![0] < maskBeforeErase,"Control must erase a mask")
        let mask = protected.sculptMask!
        protected.invertSculptMask(); precondition(zip(protected.sculptMask!,mask).allSatisfy { abs($0+$1-1) < 1e-9 })
        protected.clearSculptMask(); precondition(protected.sculptMask == nil)
        var relaxed = raised; relaxed.sculptMask = Array(repeating:0,count:relaxed.vertices.count); relaxed.sculptMask![0] = 1
        try relaxed.relax(iterations:2); try relaxed.validate()
        precondition(relaxed.vertices[0] == raised.vertices[0] && relaxed.vertices != raised.vertices && relaxed.faces == raised.faces,"Whole-mesh relaxation must honor painted masks without replacing topology")
        var open = ModelingMesh.primitive("Plane"); try open.subdivide(); let boundaryBefore = open
        try open.relax(); precondition(open == boundaryBefore,"Planar open boundaries should not collapse")
        let relaxationBefore = relaxed
        do { try relaxed.relax(iterations:6); preconditionFailure("Unsafe smoothing count accepted") } catch {}
        precondition(relaxed == relaxationBefore)
        var partial = sphere; partial.sculptMask = Array(repeating:0.5,count:sphere.vertices.count)
        partial.sculpt(brush:.draw,center:center,normal:normal,radius:0.3,strength:1)
        precondition(abs((partial.vertices[0].y-0.5)*2 - (raised.vertices[0].y-0.5)) < 1e-9,"Mask opacity scales brush strength")
        let cubeNormals = ModelingMesh.primitive("Cube").vertexNormals()
        precondition(cubeNormals.allSatisfy { abs(abs($0.x)-abs($0.y)) < 1e-9 && abs(abs($0.x)-abs($0.z)) < 1e-9 },"Quad diagonals must not skew the smooth normals")
        var one = sphere, mirrored = sphere
        one.sculpt(brush:.draw,center:center,normal:normal,radius:0.4,strength:0.5)
        mirrored.sculpt(brush:.draw,center:center,normal:normal,radius:0.4,strength:0.5,symmetry:true)
        precondition(one == mirrored,"Overlapping symmetry must not double the displacement")
        var grabbed = sphere
        grabbed.sculpt(brush:.grab,center:ModelPoint(x:0.3,y:0.4),normal:ModelPoint(x:0.6,y:0.8),radius:0.25,strength:1,symmetry:true,delta:ModelPoint(x:0.1,y:0.2))
        for i in sphere.vertices.indices {
            let opposite = sphere.vertices[i].mirroredX
            if let j = sphere.vertices.firstIndex(where:{ ($0-opposite).length < 1e-8 }) {
                precondition((grabbed.vertices[i].mirroredX-grabbed.vertices[j]).length < 1e-7,"Mirrored grab must stay symmetric")
            }
        }
        var invalid = sphere
        invalid.sculpt(brush:.draw,center:center,normal:normal,radius:.nan,strength:1)
        invalid.sculpt(brush:.draw,center:center,normal:normal,radius:1,strength:.infinity)
        invalid.sculpt(brush:.draw,center:center,normal:.init(),radius:1,strength:1)
        precondition(invalid == sphere)
        // Front-facing protection works independently of radius/distance.
        var thin = ModelingMesh(vertices:[.init(x:-0.1,y:0,z:-0.1),.init(x:-0.1,y:0,z:0.1),.init(x:0.1,y:0,z:0.1),.init(x:0.1,y:0,z:-0.1),.init(x:-0.1,y:-0.01,z:-0.1),.init(x:-0.1,y:-0.01,z:0.1),.init(x:0.1,y:-0.01,z:0.1),.init(x:0.1,y:-0.01,z:-0.1)],faces:[[0,1,2,3],[7,6,5,4]])
        let initial = thin
        thin.sculpt(brush:.draw,center:.init(),normal:normal,radius:1,strength:1,frontOnly:true)
        precondition(thin.vertices[0].y > 0 && thin.vertices[4] == initial.vertices[4])
        var cube = ModelingMesh.primitive("Cube"); try cube.moveFace(5,distance:0.2)
        precondition(cube.faces[5].allSatisfy { abs(cube.vertices[$0].y-0.7) < 1e-8 })
        try cube.scaleFace(5,factor:0.5); precondition(cube.faces[5].allSatisfy { abs(cube.vertices[$0].x) == 0.25 })
        var doc = ModelingDocument(); var o = ModelingObject(name:"Sculpt",mesh:grabbed); o.mesh.sculptMask = mask; o.smoothShading = true; doc.objects = [o]
        let data = try JSONEncoder().encode(doc), restored = try JSONDecoder().decode(ModelingDocument.self,from:data)
        precondition(doc == restored)
        var legacy = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        var objects = legacy["objects"] as! [[String:Any]]; objects[0].removeValue(forKey:"smoothShading"); legacy["objects"] = objects
        var legacyMesh = objects[0]["mesh"] as! [String:Any]; legacyMesh.removeValue(forKey:"sculptMask"); objects[0]["mesh"] = legacyMesh; legacy["objects"] = objects
        let old = try JSONDecoder().decode(ModelingDocument.self,from:JSONSerialization.data(withJSONObject:legacy))
        try old.validate(); precondition(old.objects[0].smoothShading == nil && old.objects[0].mesh.sculptMask == nil)
        let imported = try ModelingMesh.readOBJ(Data(doc.obj().utf8)); precondition(imported == grabbed)
        var dense = try ModelingMesh.sculptSphere(detail:4); let denseTopology = ModelingSculptTopology(dense)
        precondition(dense.vertices.count > 50_000 && dense.faces.count == 73_728)
        let initialDense = dense, started = Date()
        for _ in 0..<10 { dense.sculpt(brush:.clay,center:center,normal:normal,radius:0.06,strength:0.3,topology:denseTopology) }
        try dense.validate(); precondition(dense != initialDense && dense.faces == initialDense.faces)
        // Informational timing, not a machine-dependent pass/fail threshold.
        print("Dense sculpt: 10 small stamps on \(dense.vertices.count) vertices in \(Date().timeIntervalSince(started)) seconds")
        do { _ = try ModelingMesh.sculptSphere(detail:5); preconditionFailure("Unsafe detail accepted") } catch {}
        print("PASS: direct side sculpting, dense local-normal strokes, ten brushes, masks, falloff, inversion, symmetry, front-face protection, malformed inputs and backwards-compatible persistence")
    }
}
