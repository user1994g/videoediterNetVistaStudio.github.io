import Cocoa
import Foundation

@main
struct ModAuthoringChecks {
    static func main() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("NetVistaModAuthoringChecks-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        let manager = ModManager(modsDirectory: root.appendingPathComponent("installed", isDirectory: true))
        try manager.prepare()
        let initialTheme = StudioTheme.shared.activeThemeName
        for (index, kind) in ModAuthoringKind.allCases.enumerated() {
            var draft = ModAuthoringDraft()
            draft.kind = kind
            draft.identifier = "local.check.mod-\(index)"
            draft.name = "Checked \(kind.title)"
            let url = root.appendingPathComponent("\(kind.rawValue).netvistamod")
            try ModPackageAuthor.export(draft, to: url)
            let entries = try ModPackageValidator.inspectArchive(at: url, policy: .mod)
            require(entries.contains(where: { $0.path == "mod.json" }), "root manifest")
            require(!entries.contains(where: { $0.path.hasPrefix("payload/") }), "no wrapper folder")
            let installed = try manager.install(packageURL: url)
            require(!manager.isEnabled(installed), "new creator mod starts disabled")
            require(installed.manifest.capabilities.count == 1, "minimal capability")
            require(installed.manifest.integrity.files.count == 2, "document and readme hashed")
            require(installed.manifest.publisher.website == nil, "creator does not add external URLs")
            require(manager.pageDocuments(for: installed).isEmpty, "disabled mod pages not exposed")
            try manager.setEnabled(true, modID: draft.identifier, version: draft.version)
            if kind == .theme {
                require(manager.themeDocuments(for: installed).count == 1, "theme installed")
            } else if kind == .page {
                let page = manager.pageDocuments(for: installed).first!
                require(page.blocks.last?.action == "open3DScene", "allowlisted shortcut")
                require(page.blocks.allSatisfy { $0.action != "openURL" }, "no creator URL actions")
            } else {
                let preset = manager.catalogDocuments(for: installed).first!.document
                require(preset.parameters? ["contrast"] == 1, "preset reference values")
            }
        }
        require(StudioTheme.shared.activeThemeName == initialTheme, "creator/export never changes global theme")

        var page = ModAuthoringDraft()
        page.kind = .page; page.identifier = "local.check.shortcut"
        page.pageBody = String(repeating: "A", count: 4_000)
        for shortcut in ModAuthoringPageShortcut.allCases {
            page.pageShortcut = shortcut
            _ = try ModPackageAuthor.packageData(for: page)
        }
        page.pageBody += "A"
        try rejects("page size cap") { _ = try ModPackageAuthor.packageData(for: page) }

        var invalid = ModAuthoringDraft()
        invalid.identifier = "../escape"
        try rejects("path-looking ID") { _ = try ModPackageAuthor.packageData(for: invalid) }
        invalid = ModAuthoringDraft(); invalid.accent = "url(https://example.com)"
        try rejects("CSS colour injection") { _ = try ModPackageAuthor.packageData(for: invalid) }
        invalid = ModAuthoringDraft(); invalid.cornerRadius = .nan
        try rejects("nonfinite radius") { _ = try ModPackageAuthor.packageData(for: invalid) }
        invalid = ModAuthoringDraft(); invalid.description = String(repeating: "x", count: 501)
        try rejects("bounded description") { _ = try ModPackageAuthor.packageData(for: invalid) }
        invalid = ModAuthoringDraft(); invalid.name = "Bad\u{0000}Name"
        try rejects("control characters") { _ = try ModPackageAuthor.packageData(for: invalid) }
        invalid = ModAuthoringDraft(); invalid.kind = .effectPreset; invalid.saturation = .infinity
        try rejects("nonfinite preset") { _ = try ModPackageAuthor.packageData(for: invalid) }
        invalid = ModAuthoringDraft(); invalid.version = "latest"
        try rejects("invalid version") { _ = try ModPackageAuthor.packageData(for: invalid) }
        require(ModAuthoringDraft.suggestedIdentifier(for: " Ocean Theme! ") == "local.creator.ocean-theme", "friendly generated ID")
        require(ModAuthoringDraft.suggestedIdentifier(for: "🐉") == "local.creator.my-mod", "unicode name fallback")

        var draft = ModAuthoringDraft()
        draft.identifier = "local.check.revision"
        let first = try ModPackageAuthor.testInstall(draft, using: manager)
        require(!manager.isEnabled(first), "test install disabled")
        draft.accent = "#52BDE3"
        try rejects("same version altered content") { _ = try ModPackageAuthor.testInstall(draft, using: manager) }
        draft.version = "1.0.1"
        let updated = try ModPackageAuthor.testInstall(draft, using: manager)
        require(!manager.isEnabled(updated), "new version not silently enabled")

        let destination = root.appendingPathComponent("untouched.netvistamod")
        let original = Data("original file".utf8)
        try original.write(to: destination)
        draft.identifier = "invalid"
        try rejects("invalid export leaves destination intact") { try ModPackageAuthor.export(draft, to: destination) }
        try require(try Data(contentsOf: destination) == original, "existing file preserved on validation failure")
        let link = root.appendingPathComponent("linked.netvistamod")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: destination)
        try rejects("destination symlink refused") { try ModPackageAuthor.export(ModAuthoringDraft(), to: link) }
        try require(try Data(contentsOf: destination) == original, "linked target preserved")

        #if MOD_AUTHORING_CHECKS
        _ = NSApplication.shared
        let creator = ModCreatorViewController(manager: manager)
        creator.loadView()
        creator.view.frame = NSRect(x: 0, y: 0, width: 790, height: 570)
        creator.view.layoutSubtreeIfNeeded()
        require(creator.testCanExport, "valid creator starts ready")
        creator.testSetName("Moonlit Studio")
        require(creator.testDraft.identifier == "local.creator.moonlit-studio", "name autogenerates ID")
        creator.testSetIdentifier("com.artist.custom")
        creator.testSetName("Renamed Studio")
        require(creator.testDraft.identifier == "com.artist.custom", "manual ID remains stable")
        creator.testSetIdentifier("bad id")
        require(!creator.testCanExport, "invalid draft disables export")
        creator.testSetIdentifier("com.artist.custom")
        for kind in ModAuthoringKind.allCases {
            creator.testSetTemplate(kind)
            require(creator.testVisibleSections.filter { $0 }.count == 1, "one template section visible")
        }
        if CommandLine.arguments.contains("--screenshot") {
            creator.testSetTemplate(.theme)
            let window = NSWindow(contentViewController: creator)
            window.setContentSize(NSSize(width: 900, height: 720))
            window.appearance = NSAppearance(named: .darkAqua)
            window.makeKeyAndOrderFront(nil)
            creator.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            // Headless/sandbox WindowServer can clamp windows to a fictitious
            // 357-point screen. Inspect the requested content layout directly.
            creator.view.setFrameSize(NSSize(width: 900, height: 720))
            creator.view.layoutSubtreeIfNeeded()
            if let image = creator.view.bitmapImageRepForCachingDisplay(in: creator.view.bounds) {
                creator.view.cacheDisplay(in: creator.view.bounds, to: image)
                if let png = image.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: "/private/tmp/netvista-mod-creator-preview.png"))
                }
            }
            window.orderOut(nil)
        }
        #endif
        if CommandLine.arguments.contains("--export-fixture") {
            let fixture = URL(fileURLWithPath: "/private/tmp/netvista-mod-authoring-fixture.netvistamod")
            var portable = ModAuthoringDraft()
            portable.identifier = "local.check.portable"
            try ModPackageAuthor.export(portable, to: fixture)
        }
        print("PASS: mod templates, validated export/install, hashes, limits, disabled state, revisions, file preservation and creator controls")
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() { fatalError("FAIL: \(message)") }
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation(); fatalError("FAIL: \(message) was accepted") } catch { }
    }
}
