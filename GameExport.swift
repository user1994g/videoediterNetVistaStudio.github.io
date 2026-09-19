import Foundation

enum GameExportTarget: String { case threeJS = "Three.js (JavaScript)", python = "Python (Panda3D)" }

enum GameExporter {
    /// Export into a new directory only. Stage first so failed exports leave no partial game.
    static func export(_ project: GameProject, to destination: URL, target: GameExportTarget) throws {
        try project.validate()
        if project.objects.contains(where: { $0.rig != nil || $0.spriteSheet != nil || $0.rules.contains { $0.actions.contains { [.walk,.spriteAnimation].contains($0.kind) } } }) {
            throw GameProjectError.invalid("Character rigs and sprite-sheet animations currently play inside Game Maker. Source export does not yet support these animations. Save the full .netvistagame project to preserve them.")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw GameProjectError.invalid("Choose a new folder name. Export never replaces an existing game folder.") }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".netvista-export-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        var meshes: [String: Any] = [:]
        for id in Set(project.objects.compactMap(\.modelID)) {
            guard let asset = project.assets.first(where: { $0.id == id }) else { continue }
            meshes[id.uuidString] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GameMesh.read(asset)))
        }
        json["meshes"] = meshes
        json["assets"] = project.assets.map { ["id": $0.id.uuidString, "path": "assets/" + $0.path] }
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: stage.appendingPathComponent("game.json"))
        for asset in project.assets {
            let url = stage.appendingPathComponent("assets/" + asset.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try asset.data.write(to: url)
        }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("game-runtime")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("assets/game-runtime")
        let templates = bundled.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil } ?? source
        let files = target == .threeJS ? ["index.html","main.js","runtime.mjs","package.json","serve.mjs"] : ["game.py","engine.py","requirements.txt"]
        for name in files { try fm.copyItem(at: templates.appendingPathComponent(name), to: stage.appendingPathComponent(name)) }
        let instructions = target == .threeJS ? "Install Node.js, then in this folder run:\n\n    npm install\n    npm start\n\nOpen http://localhost:8080 in a WebGL2-capable browser. Do not double-click index.html. The server binds to this computer only. To publish, upload this folder including node_modules/three/build (no server code is needed on static hosting)." : "Install Python 3.10–3.13, then in this folder run:\n\n    python3 -m venv .venv\n    # macOS/Linux: source .venv/bin/activate\n    # Windows: .venv\\Scripts\\activate\n    python -m pip install -r requirements.txt\n    python game.py\n\nOn Windows, use `py` if `python3` is unavailable. This is editable source, not a packaged executable."
        let readme = """
        # \(project.name) — exported from NetVista Studio Game Maker

        \(instructions)

        The scene, imported asset bytes and event/action rules are included. No NetVista installation is required.
        Start, every-frame, held-key, key-press, timer and contact-entry events run in object/rule order. Connected nodes follow wire order; conditions take only their Yes or No branch. Disconnected nodes never run.
        Move/rotate rates use seconds. Opacity uses 0–1. In 3D, Y is height and WASD moves on X/Z.
        Sprite/model size is square/unit-normalized. Colliders are axis-aligned boxes, even when artwork is rotated.
        Camera: fixed at (0, 15, 17) looking at origin in 3D; 21 × 13 world-unit view in 2D.
        Variables and key/score/contact/variable branches are included. No automatic player, score logic, floor, gravity or multiplayer is added. Native character and sprite-sheet animation are not supported by this source exporter.
        Add the blocks you need in the editor. Stop/Play or restart the exported game to reset state.

        Third-party runtime: \(target == .threeJS ? "Three.js (MIT), https://threejs.org/" : "Panda3D (Modified BSD), https://www.panda3d.org/"). Dependencies download during installation.
        You are responsible for the rights to assets you import and distribute. Opening project files never runs imported scripts.
        """
        try Data(readme.utf8).write(to: stage.appendingPathComponent("README.md"))
        try fm.moveItem(at: stage, to: destination)
    }
}
