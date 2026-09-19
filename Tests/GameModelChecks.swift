import Cocoa
import SceneKit

@main struct GameModelChecks {
    static func main() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("netvista-model-check-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let obj = root.appendingPathComponent("character.obj")
        try Data("v -1 -1 0\nv 1 -1 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to:obj)
        var project = try GameModelImporter.importModels([obj],into:.starter(.threeD))
        let model = project.assets.first { $0.path.hasSuffix(".nvmesh") }!
        var object = GameObject(name:"Character",kind:.model); object.modelID = model.id; object.rig = .humanoid(); project.objects = [object]
        let save = root.appendingPathComponent("Character.netvistagame"); try project.save(to:save); try fm.removeItem(at:obj)
        let loaded = try GameProject.open(save), mesh = try GameMesh.read(loaded.assets.first { $0.id == model.id }!)
        precondition(mesh.positions.count == 9)
        let rig = GameRigRenderer(mesh:mesh,rig:object.rig!,material:SCNMaterial())
        var body: SCNNode?
        rig.root.enumerateChildNodes { node,_ in if node.skinner != nil { body = node } }
        precondition(body?.skinner?.bones.count == object.rig!.joints.count,"Rig must deform mesh through a real skinner")
        rig.pose(time:0.13,walking:true)
        precondition(rig.root.childNode(withName:"Left thigh",recursively:true)!.eulerAngles.x != 0)
        rig.pose(time:0.13,walking:false)
        precondition(rig.root.childNode(withName:"Left thigh",recursively:true)!.eulerAngles.x == 0)
        let stl = root.appendingPathComponent("triangle.stl")
        try Data("solid test\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid test\n".utf8).write(to:stl)
        let stlMesh = try GameModelImporter.load(stl); precondition(stlMesh.positions.count == 9)
        print("PASS: OBJ and STL imports, portable compiled geometry, rig save/load, skin binding, walking and rest pose")
    }
}
