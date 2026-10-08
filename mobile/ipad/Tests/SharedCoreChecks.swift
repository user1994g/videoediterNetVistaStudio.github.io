// Isolated simulator checks of the actual Mac engines compiled for UIKit.
// Not a product entry point or a claim that the missing workspaces are ported.
import UIKit
import CoreImage
import SceneKit

@MainActor final class SharedCoreCheckDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }
    func application(_ app: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Shared core checks", sessionRole: session.role)
        config.delegateClass = SharedCoreCheckScene.self; return config
    }
    func start(_ scene: UIWindowScene) {
        let window = UIWindow(windowScene: scene), host = UIViewController()
        host.view.backgroundColor = .black; window.rootViewController = host; window.makeKeyAndVisible(); self.window = window
        Task { @MainActor in
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let result = documents.appendingPathComponent("shared-core-result.txt")
            do {
                try PhotoRasterChecks.main()
                try Self.checkModelCommands(documents)
                try Self.checkGameCommands(documents)
                try Self.checkGradePixels(documents)
                try "PASS: original Mac brush/ABR/selection pixels on UIKit; shared model extrude, subdivide, side sculpt and native project/OBJ round trip; 2D/3D connected game rules and project persistence; real grading/LUT/keyed pixels. Shared engines only, not finished mobile workspaces.\n".write(to: result, atomically: true, encoding: .utf8)
            } catch {
                try? "FAIL: \(error)\n".write(to: result, atomically: true, encoding: .utf8)
                fatalError("Shared native engines failed: \(error)")
            }
        }
    }
    static func checkModelCommands(_ folder: URL) throws {
        var cube = ModelingMesh.primitive("Cube")
        let original = cube
        try cube.extrude(face: 5, distance: 0.25); try cube.subdivide(); try cube.validate()
        precondition(cube != original && cube.faces.count > original.faces.count)
        let sphere = try ModelingMesh.sculptSphere(detail: 1)
        var sculpt = sphere
        sculpt.sculpt(brush: .draw, center: .init(x: 0.5), normal: .init(x: 1), radius: 0.15, strength: 1,
                      topology: ModelingSculptTopology(sphere))
        try sculpt.validate()
        precondition(sculpt != sphere && sculpt.faces == sphere.faces && sculpt.vertices.contains { $0.x > 0.5 })
        var model = ModelingDocument(); model.objects = [ModelingObject(name: "Side sculpt", mesh: sculpt)]
        let url = folder.appendingPathComponent("shared-model.netvistamodel")
        try model.save(url); let read = try ModelingDocument.open(url); precondition(read == model)
        let obj = try read.obj(), imported = try ModelingMesh.readOBJ(Data(obj.utf8))
        precondition(imported == sculpt)
    }
    static func checkGameCommands(_ folder: URL) throws {
        for dimension in [GameDimension.twoD, .threeD] {
            var game = GameProject.starter(dimension)
            var actor = GameObject(name: "Character", kind: .block)
            actor.rules = GameBehaviourRecipe.movement.rules(for: actor) + GameBehaviourRecipe.reset.rules(for: actor)
            game.objects = [actor]; try game.validate()
            var state = GamePlayState(objects: game.objects, dimension: dimension)
            state.step(keys: ["d"], seconds: 0.05)
            precondition(state.objects[0].x > 0 && game.objects[0].x == 0, "Play must not mutate the authored scene")
            state.step(keys: ["space"], seconds: 0.05); precondition(state.objects[0].x == 0)
            let url = folder.appendingPathComponent("shared-\(dimension.rawValue).netvistagame")
            try game.save(to: url); let restored = try GameProject.open(url); precondition(restored == game)
            var invalid = actor.rules[0]
            invalid.graph?.wires.append(GameWire(from: invalid.actions[0].id, to: invalid.actions[0].id))
            do { try invalid.graph?.validate(rule: invalid); preconditionFailure("Cyclic game graph accepted") } catch {}
        }
    }
    static func checkGradePixels(_ folder: URL) throws {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let extent = CGRect(x: 0, y: 0, width: 32, height: 32)
        func solid(_ r: Double, _ g: Double, _ b: Double) -> CIImage { CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: extent) }
        func pixel(_ image: CIImage) -> [Float] {
            var value = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &value, rowBytes: 16, bounds: CGRect(x: 12, y: 12, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return value
        }
        let baseline = solid(1, 0, 0)
        precondition(pixel(baseline)[0] > 0.99, "Unavailable graphics must not pass as black pixels")
        var node = GradeNode(); node.saturation = 0
        let gray = pixel(AdvancedGradeRuntime.apply([node], to: baseline))
        precondition(gray[0] > 0.1 && abs(gray[0] - gray[1]) < 0.02 && abs(gray[0] - gray[2]) < 0.02)
        let cubeURL = folder.appendingPathComponent("shared-grade.cube")
        try AdvancedGradeRuntime.exportCube(to: cubeURL, dimension: 17, nodes: [node])
        let source = try String(contentsOf: cubeURL, encoding: .utf8), cube = try CubeLUT.parse(source)
        let reloaded = pixel(try cube.applying(to: baseline, colorSpace: nil))
        precondition(abs(reloaded[0] - gray[0]) < 0.025 && abs(reloaded[1] - gray[1]) < 0.025 && abs(reloaded[2] - gray[2]) < 0.025)
        var key = UltraKeySettings(); key.enabled = true
        let green = pixel(UltraKeyRuntime.apply(to: solid(0, 1, 0), settings: key))
        precondition(green.allSatisfy { abs($0) < 0.01 }, "The shared keyer must remove actual green pixels")
        let red = pixel(UltraKeyRuntime.apply(to: baseline, settings: key))
        precondition(red[0] > 0.99 && red[3] > 0.99, "Keyer must preserve foreground")
    }
}

@MainActor final class SharedCoreCheckScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene, let delegate = UIApplication.shared.delegate as? SharedCoreCheckDelegate else { return }
        delegate.start(scene); window = delegate.window
    }
}
@main struct SharedCoreCheckEntry {
    @MainActor static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(SharedCoreCheckDelegate.self)) }
}
