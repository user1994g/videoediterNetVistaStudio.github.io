import Foundation
import CryptoKit

enum ModAuthoringKind: String, CaseIterable {
    case theme, page, effectPreset

    var title: String {
        switch self {
        case .theme: return "Theme"
        case .page: return "Tool Page"
        case .effectPreset: return "Preset Catalog"
        }
    }

    var detail: String {
        switch self {
        case .theme: return "Customize Studio colours with a native theme."
        case .page: return "Create a native page with text and a Studio shortcut."
        case .effectPreset: return "Share look settings as a catalog reference. Catalog presets are not automatically applied to clips in Mods v1."
        }
    }
}

enum ModAuthoringPageShortcut: String, CaseIterable {
    case none, importMedia, open3DScene, openModsFolder

    var title: String {
        switch self {
        case .none: return "No shortcut"
        case .importMedia: return "Import media"
        case .open3DScene: return "Open 3D Scene"
        case .openModsFolder: return "Open Mods Folder"
        }
    }
}

/// A deliberately small native creator, not an executable plug-in SDK. All
/// payload paths and action names are supplied by NetVista, never free-form code.
struct ModAuthoringDraft {
    var kind: ModAuthoringKind = .theme
    var name = "My Studio Theme"
    var identifier = "local.creator.my-studio-theme"
    var publisher = "Local Creator"
    var version = "1.0.0"
    var description = "A custom NetVista Studio theme."
    var accent = "#F05B5E"
    var panel = "#20232A"
    var workspace = "#181B21"
    var primaryText = "#F4F6FA"
    var secondaryText = "#9DA6B5"
    var cornerRadius = 7.0
    var pageTitle = "My Studio Tools"
    var pageBody = "Welcome to my workspace. Use the shortcut below to get started."
    var pageShortcut: ModAuthoringPageShortcut = .open3DScene
    var exposure = 0.0
    var contrast = 1.0
    var saturation = 1.0

    static func suggestedIdentifier(for name: String) -> String {
        let slug = name.lowercased().unicodeScalars.map { scalar -> String in
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(scalar) ? String(scalar) : "-"
        }.joined().split(separator: "-").joined(separator: "-")
        return "local.creator." + String((slug.isEmpty ? "my-mod" : slug).prefix(70)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    func validate() throws {
        func text(_ value: String, _ label: String, maximum: Int) throws {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= maximum,
                  trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }) else {
                throw ModSystemError.invalidPackage("\(label) must contain 1–\(maximum) characters and no control characters")
            }
        }
        try text(name, "name", maximum: 80)
        try text(publisher, "creator name", maximum: 80)
        try text(description, "description", maximum: 500)
        guard identifier.count <= 100,
              identifier.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)+$"#, options: .regularExpression) != nil else {
            throw ModSystemError.invalidPackage("Mod ID must be lowercase, for example local.creator.my-theme")
        }
        guard ModSemanticVersion(version) != nil else {
            throw ModSystemError.invalidPackage("version must look like 1.0.0 or 1.0.0-beta.1")
        }
        switch kind {
        case .theme:
            guard [accent, panel, workspace, primaryText, secondaryText].allSatisfy({
                $0.range(of: #"^#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?$"#, options: .regularExpression) != nil
            }), cornerRadius.isFinite, (0...16).contains(cornerRadius) else {
                throw ModSystemError.invalidPackage("theme colours must be #RRGGBB or #RRGGBBAA, and corner radius must be 0–16")
            }
        case .page:
            try text(pageTitle, "page title", maximum: 100)
            try text(pageBody, "page text", maximum: 4_000)
        case .effectPreset:
            guard exposure.isFinite, (-4...4).contains(exposure),
                  contrast.isFinite, (0...3).contains(contrast),
                  saturation.isFinite, (0...3).contains(saturation) else {
                throw ModSystemError.invalidPackage("preset values must stay inside their displayed ranges")
            }
        }
    }
}

enum ModPackageAuthor {
    /// Tiny, data-only packages are built in a private temporary directory,
    /// validated with the same checks as installation, then returned to the
    /// explicit Save panel caller. No shell text or external downloads are used.
    static func packageData(for draft: ModAuthoringDraft) throws -> Data {
        try draft.validate()
        let fileManager = FileManager.default
        let transaction = fileManager.temporaryDirectory.appendingPathComponent("NetVistaModCreator-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: transaction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: transaction) }
        let payload = transaction.appendingPathComponent("payload", isDirectory: true)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let itemID = "creator-item"
        var content = ModContent()
        var files: [String: Data] = [:]
        var capability: ModCapability
        switch draft.kind {
        case .theme:
            capability = .theme
            let path = "themes/theme.json"
            content.themes = [path]
            let document = ModThemeDocument(schemaVersion: 1, id: itemID, name: draft.name, tokens: ModThemeTokens(
                windowBackground: draft.workspace, topBarBackground: draft.panel, panelBackground: draft.panel,
                workspaceBackground: draft.workspace, cardBackground: draft.panel, controlBackground: draft.panel,
                primaryText: draft.primaryText, secondaryText: draft.secondaryText, accent: draft.accent,
                danger: nil, separator: nil, cornerRadius: draft.cornerRadius))
            files[path] = try encoder.encode(document)
        case .page:
            capability = .page
            let path = "pages/page.json"
            content.pages = [path]
            var blocks = [ModPageBlock(kind: "text", title: nil, text: draft.pageBody, image: nil, action: nil, arguments: nil)]
            if draft.pageShortcut != .none {
                blocks.append(ModPageBlock(kind: "button", title: draft.pageShortcut.title, text: nil, image: nil,
                                           action: draft.pageShortcut.rawValue, arguments: nil))
            }
            files[path] = try encoder.encode(ModPageDocument(schemaVersion: 1, id: itemID, title: draft.pageTitle,
                                                             summary: draft.description, blocks: blocks))
        case .effectPreset:
            capability = .effectPreset
            let path = "effect-presets/preset.json"
            content.effectPresets = [path]
            files[path] = try encoder.encode(ModCatalogDocument(schemaVersion: 1, id: itemID, name: draft.name,
                                                                summary: draft.description, asset: nil,
                                                                parameters: ["exposure": draft.exposure, "contrast": draft.contrast, "saturation": draft.saturation]))
        }
        files["docs/readme.txt"] = Data("""
        NetVista Studio creator package
        \(draft.name) \(draft.version) by \(draft.publisher)
        \(draft.description)

        Install from the Mods page. Packages start disabled; review and enable the mod yourself.
        \(draft.kind == .effectPreset ? "Mods v1 preset entries are catalog references, not automatic clip effects." : "This package contains native declarative data only, not executable plug-in code.")
        To change the package, create a new version in Mod Creator. SHA-256 checks detect damaged files, not creator identity.
        """.utf8)
        var digests: [String: String] = [:]
        for (path, data) in files {
            let url = payload.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try data.write(to: url, options: [.withoutOverwriting])
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            digests[path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let currentRelease = Bundle.main.object(forInfoDictionaryKey: "NetVistaReleaseTag") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let minimumRelease = ModSemanticVersion(currentRelease) == nil ? "0.0.0" : currentRelease
        let manifest = ModManifest(schemaVersion: 1, modAPI: "1.0", id: draft.identifier, name: draft.name,
                                   version: draft.version, publisher: ModPublisher(name: draft.publisher, website: nil),
                                   description: draft.description, minAppVersion: minimumRelease, maxAppVersion: nil,
                                   capabilities: [capability], dependencies: [], content: content,
                                   integrity: ModIntegrity(algorithm: "sha256", files: digests))
        let manifestURL = payload.appendingPathComponent("mod.json")
        try encoder.encode(manifest).write(to: manifestURL, options: [.withoutOverwriting])
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)
        _ = try ModPackageValidator.validateExtractedDirectory(payload, expectedEntries: nil)
        let archive = transaction.appendingPathComponent("package.netvistamod")
        // Store tiny JSON without compression so repetitive descriptions cannot
        // trip the existing archive-bomb ratio checks.
        _ = try ModPackageValidator.runTool("/usr/bin/zip", arguments: ["-q", "-0", "-r", archive.path, "."], outputLimit: 65_536, currentDirectory: payload)
        let entries = try ModPackageValidator.inspectArchive(at: archive, policy: .mod)
        let verified = transaction.appendingPathComponent("verified", isDirectory: true)
        try fileManager.createDirectory(at: verified, withIntermediateDirectories: false)
        _ = try ModPackageValidator.runTool("/usr/bin/ditto", arguments: ["-x", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", archive.path, verified.path], outputLimit: 65_536)
        _ = try ModPackageValidator.validateExtractedDirectory(verified, expectedEntries: entries)
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw ModSystemError.invalidPackage("creator packages must remain smaller than 1 MiB") }
        return try Data(contentsOf: archive)
    }

    static func export(_ draft: ModAuthoringDraft, to destination: URL) throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "netvistamod" else {
            throw ModSystemError.invalidPackage("choose a .netvistamod file")
        }
        if let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
           values.isSymbolicLink == true || values.isDirectory == true {
            throw ModSystemError.invalidPackage("the destination cannot be a folder or symbolic link")
        }
        let data = try packageData(for: draft)
        try data.write(to: destination, options: .atomic)
    }

    static func testInstall(_ draft: ModAuthoringDraft, using manager: ModManager) throws -> InstalledMod {
        let data = try packageData(for: draft)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("NetVistaModTest-\(UUID().uuidString).netvistamod")
        try data.write(to: temporary, options: [.withoutOverwriting])
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try manager.install(packageURL: temporary)
    }
}
