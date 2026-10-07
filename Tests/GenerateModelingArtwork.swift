import Cocoa
import SceneKit

// Original procedural artwork for the launcher, rendered with SceneKit.
// Run this utility explicitly; builds copy the saved PNG without regenerating it.
@main struct GenerateModelingArtwork {
    static func main() throws {
        _ = NSApplication.shared
        let scene = SCNScene(); scene.background.contents = NSColor(calibratedRed:0.12,green:0.17,blue:0.2,alpha:1)
        func node(_ geometry:SCNGeometry,_ position:SCNVector3,_ colour:NSColor) -> SCNNode {
            let material = SCNMaterial(); material.diffuse.contents = colour; material.lightingModel = .physicallyBased; material.roughness.contents = 0.45
            geometry.materials = [material]; let n = SCNNode(geometry:geometry); n.position = position; scene.rootNode.addChildNode(n); return n
        }
        _ = node(SCNBox(width:200,height:0.2,length:200,chamferRadius:0),SCNVector3(0,-1.25,0),NSColor(calibratedRed:0.18,green:0.23,blue:0.25,alpha:1))
        _ = node(SCNCylinder(radius:2.15,height:0.2),SCNVector3(0,-1.05,0),NSColor(calibratedRed:0.29,green:0.36,blue:0.38,alpha:1))
        let gold = NSColor(calibratedRed:0.93,green:0.59,blue:0.29,alpha:1)
        for x in [-0.8,0.8] { _ = node(SCNBox(width:0.45,height:2.1,length:0.7,chamferRadius:0.045),SCNVector3(x,0,0),gold) }
        _ = node(SCNBox(width:2.05,height:0.45,length:0.7,chamferRadius:0.045),SCNVector3(0,1.05,0),gold)
        let sphere = SCNSphere(radius:0.66); sphere.segmentCount = 12
        let orb = node(sphere,SCNVector3(0,-0.25,0.25),NSColor(calibratedRed:0.31,green:0.71,blue:0.7,alpha:1))
        let wire = SCNNode(geometry:sphere.copy() as? SCNGeometry); let lineMaterial = SCNMaterial(); lineMaterial.fillMode = .lines; lineMaterial.diffuse.contents = NSColor(calibratedRed:0.64,green:0.96,blue:0.92,alpha:1); lineMaterial.lightingModel = .constant
        wire.geometry?.materials = [lineMaterial]; wire.scale = SCNVector3(1.003,1.003,1.003); orb.addChildNode(wire)
        let cube = node(SCNBox(width:0.65,height:0.65,length:0.65,chamferRadius:0.02),SCNVector3(1.4,-0.57,1.2),gold); cube.eulerAngles.y = 0.3
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.usesOrthographicProjection = true; camera.camera?.orthographicScale = 3.1; camera.camera?.wantsHDR = true; camera.camera?.exposureOffset = -0.7; camera.position = SCNVector3(4.5,3.1,6); camera.look(at:SCNVector3(0,0.05,0)); scene.rootNode.addChildNode(camera)
        let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni; light.light?.intensity = 650; light.light?.castsShadow = true; light.light?.shadowRadius = 12; light.position = SCNVector3(-3,6,4); scene.rootNode.addChildNode(light)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 200; scene.rootNode.addChildNode(ambient)
        let renderer = SCNRenderer(device:nil,options:nil); renderer.scene = scene; renderer.pointOfView = camera
        let image = renderer.snapshot(atTime:0,with:CGSize(width:1200,height:760),antialiasingMode:.multisampling4X)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let png = bitmap.representation(using:.png,properties:[:]) else { fatalError("Artwork rendering failed") }
        try png.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        print("Rendered original 3D Editor artwork")
    }
}
