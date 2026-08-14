import Foundation
import CryptoKit

extension Notification.Name {
    static let netVistaModsDidChange = Notification.Name("NetVistaStudioModsDidChange")
}

final class ModManager {
    static let shared = ModManager()

    let modsDirectory: URL
    private let stagingDirectory: URL
    private let stateURL: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var storedMods: [InstalledMod] = []
    private var state = ModStateFile()

    var installedMods: [InstalledMod] {
        lock.lock(); defer { lock.unlock() }
        return storedMods
    }

    private init() {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        modsDirectory = applicationSupport
            .appendingPathComponent("NetVista Studio", isDirectory: true)
            .appendingPathComponent("Mods", isDirectory: true)
        stagingDirectory = modsDirectory.appendingPathComponent(".staging", isDirectory: true)
        stateURL = modsDirectory.appendingPathComponent("ModState.json")
    }

    func prepare() throws {
        try fileManager.createDirectory(at: modsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        state = loadState()
        try removeAbandonedStagingDirectories()
        try rescan(postNotification: false)
        applyStoredTheme()
    }

    @discardableResult
    func install(packageURL: URL) throws -> InstalledMod {
        let source = packageURL.standardizedFileURL
        guard source.pathExtension.lowercased() == "netvistamod" else {
            throw ModSystemError.invalidPackage("the filename must end in .netvistamod")
        }
        let transaction = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedArchive = transaction.appendingPathComponent("package.netvistamod")
        let payload = transaction.appendingPathComponent("payload", isDirectory: true)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? fileManager.removeItem(at: transaction) } }

        // Inspect and extract the private copy. This prevents another process
        // from swapping the original package between preflight and extraction.
        try fileManager.copyItem(at: source, to: stagedArchive)
        let plan = try ModPackageValidator.inspectArchive(at: stagedArchive, policy: .mod)

        _ = try ModPackageValidator.runTool(
            "/usr/bin/ditto",
            arguments: ["-x", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", stagedArchive.path, payload.path],
            outputLimit: 4 * 1_024 * 1_024
        )
        let validated = try ModPackageValidator.validateExtractedDirectory(payload, expectedEntries: plan)
        let destinationParent = modsDirectory.appendingPathComponent(validated.manifest.id, isDirectory: true)
        let destination = destinationParent.appendingPathComponent(validated.manifest.version, isDirectory: true)
        try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destination.path) {
            let existing = try ModPackageValidator.validateExtractedDirectory(destination, expectedEntries: nil)
            guard existing.packageDigest == validated.packageDigest else {
                throw ModSystemError.invalidPackage("\(validated.manifest.id) \(validated.manifest.version) is already installed with different contents")
            }
            try fileManager.removeItem(at: transaction)
            committed = true
            try rescan(postNotification: true)
            return installedMods.first(where: { $0.manifest.id == existing.manifest.id && $0.manifest.version == existing.manifest.version }) ?? existing
        }

        try fileManager.moveItem(at: payload, to: destination)
        try? fileManager.removeItem(at: transaction)
        committed = true
        if state.mods[validated.manifest.id] == nil {
            // Installation is intentionally off by default. The creator is
            // unverified until the user explicitly enables the package.
            state.mods[validated.manifest.id] = ModVersionState(enabledVersion: nil)
            try saveState()
        }
        try rescan(postNotification: true)
        guard let installed = installedMods.first(where: {
            $0.manifest.id == validated.manifest.id && $0.manifest.version == validated.manifest.version
        }) else { throw ModSystemError.modNotFound }
        return installed
    }

    func isEnabled(_ mod: InstalledMod) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.mods[mod.manifest.id]?.enabledVersion == mod.manifest.version
    }

    func setEnabled(_ enabled: Bool, modID: String, version: String) throws {
        guard let mod = installedMods.first(where: { $0.manifest.id == modID && $0.manifest.version == version }) else {
            throw ModSystemError.modNotFound
        }
        if enabled {
            for dependency in mod.manifest.dependencies ?? [] {
                guard let required = installedMods.first(where: {
                    $0.manifest.id == dependency.id && self.isEnabled($0)
                }) else { throw ModSystemError.dependencyMissing(dependency.id) }
                if let minimum = dependency.minVersion,
                   let requiredVersion = ModSemanticVersion(required.manifest.version),
                   let minimumVersion = ModSemanticVersion(minimum),
                   requiredVersion < minimumVersion {
                    throw ModSystemError.dependencyMissing("\(dependency.id) \(minimum) or newer")
                }
            }
            state.mods[modID] = ModVersionState(enabledVersion: version)
        } else if state.mods[modID]?.enabledVersion == version {
            state.mods[modID] = ModVersionState(enabledVersion: nil)
            if state.activeTheme?.modID == modID {
                state.activeTheme = nil
                StudioTheme.shared.reset()
            }
        }
        try saveState()
        postChange()
    }

    func remove(modID: String, version: String) throws {
        guard let mod = installedMods.first(where: { $0.manifest.id == modID && $0.manifest.version == version }) else {
            throw ModSystemError.modNotFound
        }
        if state.mods[modID]?.enabledVersion == version {
            state.mods[modID] = ModVersionState(enabledVersion: nil)
        }
        if state.activeTheme?.modID == modID && state.activeTheme?.version == version {
            state.activeTheme = nil
            StudioTheme.shared.reset()
        }
        try fileManager.removeItem(at: mod.directoryURL)
        let parent = mod.directoryURL.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try? fileManager.removeItem(at: parent)
        }
        if !installedMods.contains(where: { $0.manifest.id == modID && $0.manifest.version != version }) {
            state.mods.removeValue(forKey: modID)
        }
        try saveState()
        try rescan(postNotification: true)
    }

    func resetTheme() throws {
        state.activeTheme = nil
        try saveState()
        StudioTheme.shared.reset()
        postChange()
    }

    func applyTheme(from mod: InstalledMod, path: String) throws {
        guard isEnabled(mod) else {
            throw ModSystemError.invalidPackage("enable \(mod.manifest.name) before applying its theme")
        }
        guard mod.manifest.content.themes.contains(path),
              let url = ModPackageValidator.safePayloadURL(base: mod.directoryURL, relativePath: path) else {
            throw ModSystemError.invalidPackage("the requested theme is not part of this mod")
        }
        let document = try JSONDecoder().decode(ModThemeDocument.self, from: Data(contentsOf: url))
        try StudioTheme.shared.apply(document)
        state.activeTheme = ModThemeSelection(modID: mod.manifest.id, version: mod.manifest.version, path: path)
        try saveState()
        postChange()
    }

    func themeDocuments(for mod: InstalledMod) -> [(path: String, document: ModThemeDocument)] {
        mod.manifest.content.themes.compactMap { path in
            guard let url = ModPackageValidator.safePayloadURL(base: mod.directoryURL, relativePath: path),
                  let data = try? Data(contentsOf: url),
                  let document = try? JSONDecoder().decode(ModThemeDocument.self, from: data) else { return nil }
            return (path, document)
        }
    }

    func pageDocuments(for mod: InstalledMod) -> [ModPageDocument] {
        guard isEnabled(mod) else { return [] }
        return mod.manifest.content.pages.compactMap { path in
            guard let url = ModPackageValidator.safePayloadURL(base: mod.directoryURL, relativePath: path),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ModPageDocument.self, from: data)
        }
    }

    func catalogDocuments(for mod: InstalledMod) -> [(capability: ModCapability, document: ModCatalogDocument)] {
        guard isEnabled(mod) else { return [] }
        let groups: [(ModCapability, [String])] = [
            (.sceneProp, mod.manifest.content.sceneProps),
            (.sceneMap, mod.manifest.content.sceneMaps),
            (.effectPreset, mod.manifest.content.effectPresets)
        ]
        return groups.flatMap { capability, paths in
            paths.compactMap { path in
                guard let url = ModPackageValidator.safePayloadURL(base: mod.directoryURL, relativePath: path),
                      let data = try? Data(contentsOf: url),
                      let document = try? JSONDecoder().decode(ModCatalogDocument.self, from: data) else { return nil }
                return (capability, document)
            }
        }
    }

    func rescan(postNotification: Bool = true) throws {
        var discovered: [InstalledMod] = []
        let idDirectories = (try? fileManager.contentsOfDirectory(
            at: modsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for idDirectory in idDirectories where idDirectory.lastPathComponent != stateURL.lastPathComponent {
            guard (try? idDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let versions = (try? fileManager.contentsOfDirectory(
                at: idDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for directory in versions {
                guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if let mod = try? ModPackageValidator.validateExtractedDirectory(directory, expectedEntries: nil),
                   mod.manifest.id == idDirectory.lastPathComponent,
                   mod.manifest.version == directory.lastPathComponent {
                    discovered.append(mod)
                }
            }
        }
        discovered.sort {
            if $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedSame {
                return (ModSemanticVersion($0.manifest.version) ?? ModSemanticVersion("0.0.0")!) >
                    (ModSemanticVersion($1.manifest.version) ?? ModSemanticVersion("0.0.0")!)
            }
            return $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
        }
        lock.lock(); storedMods = discovered; lock.unlock()
        if postNotification { postChange() }
    }

    private func loadState() -> ModStateFile {
        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder().decode(ModStateFile.self, from: data),
              decoded.schemaVersion == 1 else { return ModStateFile() }
        return decoded
    }

    private func saveState() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private func applyStoredTheme() {
        guard let selection = state.activeTheme,
              let mod = installedMods.first(where: {
                  $0.manifest.id == selection.modID && $0.manifest.version == selection.version && self.isEnabled($0)
              }) else {
            StudioTheme.shared.reset()
            return
        }
        do {
            try applyTheme(from: mod, path: selection.path)
        } catch {
            state.activeTheme = nil
            try? saveState()
            StudioTheme.shared.reset()
        }
    }

    private func removeAbandonedStagingDirectories() throws {
        let abandoned = try fileManager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for url in abandoned { try fileManager.removeItem(at: url) }
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .netVistaModsDidChange, object: self)
        }
    }
}

enum ModArchivePolicy {
    case mod
    case usdz
}

struct ModArchiveEntry {
    let path: String
    let isDirectory: Bool
    let uncompressedSize: Int64
    let compressedSize: Int64
}

private struct ValidatedModDirectory {
    let manifest: ModManifest
    let packageDigest: String
    let installedAt: Date
}

enum ModPackageValidator {
    private static let maximumArchiveBytes: Int64 = 1_073_741_824
    private static let maximumExpandedBytes: Int64 = 2_147_483_648
    private static let maximumFileBytes: Int64 = 536_870_912
    private static let maximumEntries = 20_000
    private static let maximumCompressionRatio: Int64 = 100
    private static let allowedPayloadExtensions: Set<String> = [
        "json", "png", "jpg", "jpeg", "heic", "tif", "tiff", "webp",
        "obj", "mtl", "abc", "ply", "stl", "usd", "usda", "usdc", "usdz", "dae", "scn",
        "cube", "mov", "mp4", "m4v", "wav", "aiff", "aif", "mp3", "m4a", "md", "txt"
    ]
    private static let usdzExtensions: Set<String> = [
        "usd", "usda", "usdc", "png", "jpg", "jpeg", "tif", "tiff", "exr", "hdr", "mtl", "obj"
    ]

    static func inspectArchive(at url: URL, policy: ModArchivePolicy) throws -> [ModArchiveEntry] {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ModSystemError.unsafeArchive("the package must be a regular file")
        }
        guard Int64(values.fileSize ?? 0) <= maximumArchiveBytes else {
            throw ModSystemError.unsafeArchive("the package is larger than 1 GiB")
        }
        let namesOutput = try runTool("/usr/bin/zipinfo", arguments: ["-1", url.path], outputLimit: 32 * 1_024 * 1_024)
        let names = namesOutput.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard !names.isEmpty, names.count <= maximumEntries else {
            throw ModSystemError.unsafeArchive("the package has no files or too many entries")
        }

        let longOutput = try runTool("/usr/bin/zipinfo", arguments: ["-l", url.path], outputLimit: 48 * 1_024 * 1_024)
        let rows = longOutput.split(whereSeparator: { $0.isNewline }).compactMap { raw -> (String, Int64, Int64)? in
            let line = String(raw)
            guard let first = line.first, "-dlcbps".contains(first) else { return nil }
            let fields = line.split(maxSplits: 9, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard fields.count == 10,
                  let uncompressed = Int64(fields[3]),
                  let compressed = Int64(fields[5]) else { return nil }
            return (String(fields[0]), uncompressed, compressed)
        }
        guard rows.count == names.count else {
            throw ModSystemError.unsafeArchive("archive metadata is inconsistent")
        }

        let verbose = try runTool("/usr/bin/zipinfo", arguments: ["-v", url.path], outputLimit: 64 * 1_024 * 1_024)
        let securityLines = verbose.split(whereSeparator: { $0.isNewline }).filter { $0.contains("file security status:") }
        guard securityLines.count == names.count,
              securityLines.allSatisfy({ $0.lowercased().contains("not encrypted") }) else {
            throw ModSystemError.unsafeArchive("encrypted entries are not allowed")
        }

        var canonicalPaths = Set<String>()
        var total: Int64 = 0
        var entries: [ModArchiveEntry] = []
        for index in names.indices {
            let name = names[index]
            let row = rows[index]
            let isDirectory = row.0.first == "d"
            guard row.0.first == "-" || isDirectory else {
                throw ModSystemError.unsafeArchive("links and special files are not allowed")
            }
            guard isDirectory || !row.0.contains("x") else {
                throw ModSystemError.unsafeArchive("executable file permissions are not allowed")
            }
            let canonical = try validateRelativePath(name, directory: isDirectory, policy: policy)
            guard canonicalPaths.insert(canonical).inserted else {
                throw ModSystemError.unsafeArchive("duplicate or case-colliding path: \(name)")
            }
            guard row.1 >= 0, row.2 >= 0, row.1 <= maximumFileBytes else {
                throw ModSystemError.unsafeArchive("an entry is too large: \(name)")
            }
            total = try addingWithoutOverflow(total, row.1)
            guard total <= maximumExpandedBytes else {
                throw ModSystemError.unsafeArchive("expanded contents exceed 2 GiB")
            }
            if row.1 > 1_024 {
                guard row.2 > 0, row.1 / max(1, row.2) <= maximumCompressionRatio else {
                    throw ModSystemError.unsafeArchive("suspicious compression ratio: \(name)")
                }
            }
            entries.append(ModArchiveEntry(path: name, isDirectory: isDirectory, uncompressedSize: row.1, compressedSize: row.2))
        }
        if policy == .mod {
            guard entries.contains(where: { $0.path == "mod.json" && !$0.isDirectory }) else {
                throw ModSystemError.invalidPackage("mod.json must be at the archive root")
            }
        }
        return entries
    }

    static func validateExtractedDirectory(_ directory: URL, expectedEntries: [ModArchiveEntry]?) throws -> InstalledMod {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let manifestURL = root.appendingPathComponent("mod.json")
        let manifestValues = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard manifestValues.isRegularFile == true,
              manifestValues.isSymbolicLink != true,
              (manifestValues.fileSize ?? 0) <= 262_144 else {
            throw ModSystemError.invalidPackage("mod.json is missing, linked, or too large")
        }
        let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        try validateManifestJSONShape(manifestData)
        let manifest = try JSONDecoder().decode(ModManifest.self, from: manifestData)
        try validateManifest(manifest)

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else { throw ModSystemError.invalidPackage("contents could not be read") }

        var payloadFiles = Set<String>()
        var canonicalPaths = Set<String>()
        var total: Int64 = 0
        var earliestDate = Date()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let normalizedURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard normalizedURL.path.hasPrefix(root.path + "/") else {
                throw ModSystemError.unsafeArchive("a path escapes the mod folder")
            }
            let relative = String(normalizedURL.path.dropFirst(root.path.count + 1))
            guard !relative.isEmpty else { continue }
            let canonical = try validateRelativePath(relative, directory: values.isDirectory == true, policy: .mod)
            guard canonicalPaths.insert(canonical).inserted else {
                throw ModSystemError.unsafeArchive("case-colliding installed path: \(relative)")
            }
            guard values.isSymbolicLink != true else {
                throw ModSystemError.unsafeArchive("symbolic links are not allowed: \(relative)")
            }
            let resolved = normalizedURL
            guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
                throw ModSystemError.unsafeArchive("a path escapes the mod folder: \(relative)")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw ModSystemError.unsafeArchive("special files are not allowed: \(relative)")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let permissions = attributes[.posixPermissions] as? NSNumber,
               permissions.intValue & 0o111 != 0 {
                throw ModSystemError.unsafeArchive("executable permissions are not allowed: \(relative)")
            }
            let size = Int64(values.fileSize ?? 0)
            guard size <= maximumFileBytes else { throw ModSystemError.unsafeArchive("file is too large: \(relative)") }
            total = try addingWithoutOverflow(total, size)
            guard total <= maximumExpandedBytes else { throw ModSystemError.unsafeArchive("installed contents exceed 2 GiB") }
            if relative != "mod.json" {
                payloadFiles.insert(relative)
                try rejectExecutableMagic(at: url, name: relative)
                if url.pathExtension.lowercased() == "usdz" {
                    _ = try inspectArchive(at: url, policy: .usdz)
                }
            }
            if let date = values.creationDate { earliestDate = min(earliestDate, date) }
        }

        if let expectedEntries {
            let expected = Set(expectedEntries.filter { !$0.isDirectory }.map { $0.path })
            let actual = payloadFiles.union(["mod.json"])
            guard expected == actual else {
                throw ModSystemError.unsafeArchive("extracted files do not match the archive index")
            }
        }

        let integrityPaths = Set(manifest.integrity.files.keys)
        guard integrityPaths == payloadFiles else {
            let missing = payloadFiles.subtracting(integrityPaths).first ?? integrityPaths.subtracting(payloadFiles).first ?? "unknown file"
            throw ModSystemError.integrityFailure("every payload file must be listed exactly once (\(missing))")
        }
        for (path, expectedDigest) in manifest.integrity.files {
            guard expectedDigest.count == 64, expectedDigest.allSatisfy({ $0.isHexDigit }),
                  let url = safePayloadURL(base: root, relativePath: path) else {
                throw ModSystemError.integrityFailure("invalid path or digest for \(path)")
            }
            let actual = try sha256(of: url)
            guard actual.caseInsensitiveCompare(expectedDigest) == .orderedSame else {
                throw ModSystemError.integrityFailure(path)
            }
        }
        try validateDeclaredContent(manifest, in: root)

        var packageHasher = SHA256()
        packageHasher.update(data: manifestData)
        for item in manifest.integrity.files.sorted(by: { $0.key < $1.key }) {
            packageHasher.update(data: Data(item.key.utf8))
            packageHasher.update(data: Data(item.value.lowercased().utf8))
        }
        let digest = packageHasher.finalize().map { String(format: "%02x", $0) }.joined()
        return InstalledMod(manifest: manifest, directoryURL: root, packageDigest: digest, installedAt: earliestDate)
    }

    static func safePayloadURL(base: URL, relativePath: String) -> URL? {
        guard (try? validateRelativePath(relativePath, directory: false, policy: .mod)) != nil else { return nil }
        let root = base.resolvingSymlinksInPath().standardizedFileURL
        let destination = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else { return nil }
        return destination
    }

    static func runTool(_ executable: String, arguments: [String], outputLimit: Int) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() }
        catch { throw ModSystemError.toolFailure(error.localizedDescription) }
        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.readData(ofLength: 65_536)
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > outputLimit {
                process.terminate()
                process.waitUntilExit()
                throw ModSystemError.unsafeArchive("archive index output is too large")
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data.suffix(2_048), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown tool error"
            throw ModSystemError.toolFailure(detail)
        }
        guard let output = String(data: data, encoding: .utf8) else {
            throw ModSystemError.unsafeArchive("archive names must be valid UTF-8")
        }
        return output
    }

    private static func validateRelativePath(_ raw: String, directory: Bool, policy: ModArchivePolicy) throws -> String {
        guard !raw.isEmpty, raw.utf8.count <= 1_024,
              !raw.hasPrefix("/"), !raw.hasPrefix("~"), !raw.contains("\\"), !raw.contains(":") else {
            throw ModSystemError.unsafeArchive("absolute or malformed path: \(raw)")
        }
        let trimmed = directory && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw ModSystemError.unsafeArchive("path traversal or empty component: \(raw)")
        }
        for component in components {
            guard !component.hasPrefix("."),
                  component.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw ModSystemError.unsafeArchive("hidden or control-character path: \(raw)")
            }
        }
        if policy == .mod, trimmed != "mod.json" {
            let allowedRoots: Set<String> = ["themes", "pages", "scene-props", "scene-maps", "effect-presets", "assets", "docs"]
            guard allowedRoots.contains(components[0]) else {
                throw ModSystemError.unsafeArchive("unsupported top-level folder: \(components[0])")
            }
        }
        if !directory {
            let ext = (trimmed as NSString).pathExtension.lowercased()
            switch policy {
            case .mod:
                if trimmed == "mod.json" { break }
                guard components.count >= 2 else {
                    throw ModSystemError.unsafeArchive("payload files must be inside an allowed folder: \(raw)")
                }
                let root = components[0]
                let JSONFolders = ["themes", "pages", "scene-props", "scene-maps", "effect-presets"]
                if JSONFolders.contains(root) {
                    guard ext == "json" else { throw ModSystemError.unsafeArchive("\(root) accepts JSON only: \(raw)") }
                } else if root == "assets" {
                    guard allowedPayloadExtensions.contains(ext) else { throw ModSystemError.unsafeArchive("unsupported asset type: \(raw)") }
                } else if root == "docs" {
                    guard ["md", "txt", "png", "jpg", "jpeg"].contains(ext) else { throw ModSystemError.unsafeArchive("unsupported documentation type: \(raw)") }
                } else {
                    throw ModSystemError.unsafeArchive("unsupported top-level folder: \(root)")
                }
            case .usdz:
                guard usdzExtensions.contains(ext) else { throw ModSystemError.unsafeArchive("unsupported file inside USDZ: \(raw)") }
            }
        }
        return trimmed.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func validateManifest(_ manifest: ModManifest) throws {
        guard manifest.schemaVersion == 1, manifest.modAPI == "1.0" else {
            throw ModSystemError.unsupportedManifest("only manifest schema 1 / mod API 1.0 is supported")
        }
        guard manifest.id.count <= 100,
              manifest.id.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)+$"#, options: .regularExpression) != nil else {
            throw ModSystemError.unsupportedManifest("id must be a lowercase reverse-DNS identifier")
        }
        try boundedText(manifest.name, field: "name", maximum: 80)
        try boundedText(manifest.description, field: "description", maximum: 500)
        try boundedText(manifest.publisher.name, field: "publisher name", maximum: 80)
        guard ModSemanticVersion(manifest.version) != nil,
              let minimum = ModSemanticVersion(manifest.minAppVersion) else {
            throw ModSystemError.unsupportedManifest("version and minAppVersion must use SemVer")
        }
        let appText = Bundle.main.object(forInfoDictionaryKey: "NetVistaReleaseTag") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
        if let app = ModSemanticVersion(appText), app < minimum {
            throw ModSystemError.incompatibleApp("requires \(manifest.minAppVersion) or newer")
        }
        if let maximumText = manifest.maxAppVersion {
            guard let maximum = ModSemanticVersion(maximumText) else {
                throw ModSystemError.unsupportedManifest("maxAppVersion must use SemVer")
            }
            if let app = ModSemanticVersion(appText), app > maximum {
                throw ModSystemError.incompatibleApp("supports up to \(maximumText)")
            }
        }
        guard manifest.integrity.algorithm.lowercased() == "sha256" else {
            throw ModSystemError.unsupportedManifest("only SHA-256 integrity is supported")
        }
        guard Set(manifest.capabilities).count == manifest.capabilities.count else {
            throw ModSystemError.unsupportedManifest("capabilities must not be duplicated")
        }
        if let website = manifest.publisher.website {
            guard let url = URL(string: website), url.scheme?.lowercased() == "https", url.host != nil else {
                throw ModSystemError.unsupportedManifest("publisher website must use HTTPS")
            }
        }
        var dependencyIDs = Set<String>()
        for dependency in manifest.dependencies ?? [] {
            guard dependency.id != manifest.id,
                  dependency.id.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)+$"#, options: .regularExpression) != nil,
                  dependencyIDs.insert(dependency.id).inserted else {
                throw ModSystemError.unsupportedManifest("dependencies must have unique valid IDs and cannot reference themselves")
            }
            if let minimum = dependency.minVersion, ModSemanticVersion(minimum) == nil {
                throw ModSystemError.unsupportedManifest("dependency versions must use SemVer")
            }
        }
        let declared: [(ModCapability, [String], String)] = [
            (.theme, manifest.content.themes, "themes/"),
            (.page, manifest.content.pages, "pages/"),
            (.sceneProp, manifest.content.sceneProps, "scene-props/"),
            (.sceneMap, manifest.content.sceneMaps, "scene-maps/"),
            (.effectPreset, manifest.content.effectPresets, "effect-presets/")
        ]
        var paths = Set<String>()
        for (capability, items, prefix) in declared {
            if !items.isEmpty, !manifest.capabilities.contains(capability) {
                throw ModSystemError.unsupportedManifest("content requires the \(capability.rawValue) capability")
            }
            for path in items {
                guard path.hasPrefix(prefix), path.hasSuffix(".json"),
                      paths.insert(path).inserted,
                      manifest.integrity.files[path] != nil else {
                    throw ModSystemError.unsupportedManifest("declared content paths must be unique, hashed, and inside \(prefix)")
                }
            }
        }
    }

    private static func validateDeclaredContent(_ manifest: ModManifest, in directory: URL) throws {
        for path in manifest.content.themes {
            let data = try payloadData(path, in: directory)
            try validateThemeJSONShape(data)
            let document = try JSONDecoder().decode(ModThemeDocument.self, from: data)
            guard document.id.count <= 100, !document.name.isEmpty, document.name.count <= 80 else {
                throw ModSystemError.unsupportedManifest("invalid theme metadata in \(path)")
            }
            let values = [
                document.tokens.windowBackground, document.tokens.topBarBackground,
                document.tokens.panelBackground, document.tokens.workspaceBackground,
                document.tokens.cardBackground, document.tokens.controlBackground,
                document.tokens.primaryText, document.tokens.secondaryText,
                document.tokens.accent, document.tokens.danger, document.tokens.separator
            ]
            guard values.compactMap({ $0 }).allSatisfy({ StudioTheme.color($0) != nil }) else {
                throw ModSystemError.unsupportedManifest("invalid color token in \(path)")
            }
            if let radius = document.tokens.cornerRadius, (!radius.isFinite || !(0...16).contains(radius)) {
                throw ModSystemError.unsupportedManifest("invalid corner radius in \(path)")
            }
        }
        for path in manifest.content.pages {
            let data = try payloadData(path, in: directory)
            try validatePageJSONShape(data)
            let page = try JSONDecoder().decode(ModPageDocument.self, from: data)
            guard page.schemaVersion == 1, !page.id.isEmpty, page.id.count <= 100,
                  !page.title.isEmpty, page.title.count <= 100, page.blocks.count <= 100 else {
                throw ModSystemError.unsupportedManifest("invalid page metadata in \(path)")
            }
            for block in page.blocks {
                guard ["heading", "text", "image", "divider", "button"].contains(block.kind) else {
                    throw ModSystemError.unsupportedManifest("unsupported page block \(block.kind)")
                }
                if let title = block.title { try boundedText(title, field: "page title", maximum: 160) }
                if let text = block.text { try boundedText(text, field: "page text", maximum: 4_000) }
                if let image = block.image {
                    guard manifest.integrity.files[image] != nil,
                          ["png", "jpg", "jpeg", "heic", "tif", "tiff", "webp"].contains((image as NSString).pathExtension.lowercased()) else {
                        throw ModSystemError.unsupportedManifest("page images must be hashed image assets")
                    }
                }
                if let action = block.action {
                    guard ModPageAction(rawValue: action) != nil else {
                        throw ModSystemError.unsupportedManifest("unsupported page action \(action)")
                    }
                    if action == ModPageAction.openURL.rawValue,
                       let target = block.arguments?["url"] {
                        guard let url = URL(string: target), url.scheme?.lowercased() == "https", url.host != nil else {
                            throw ModSystemError.unsupportedManifest("page URLs must use HTTPS")
                        }
                    }
                }
                guard (block.arguments ?? [:]).count <= 12,
                      (block.arguments ?? [:]).allSatisfy({ $0.key.count <= 50 && $0.value.count <= 500 }) else {
                    throw ModSystemError.unsupportedManifest("page arguments are too large")
                }
            }
        }
        let catalogPaths = manifest.content.sceneProps + manifest.content.sceneMaps + manifest.content.effectPresets
        for path in catalogPaths {
            let data = try payloadData(path, in: directory)
            try validateCatalogJSONShape(data)
            let item = try JSONDecoder().decode(ModCatalogDocument.self, from: data)
            guard item.schemaVersion == 1, !item.id.isEmpty, item.id.count <= 100,
                  !item.name.isEmpty, item.name.count <= 100 else {
                throw ModSystemError.unsupportedManifest("invalid catalog metadata in \(path)")
            }
            if let asset = item.asset, manifest.integrity.files[asset] == nil {
                throw ModSystemError.unsupportedManifest("catalog asset is not hashed: \(asset)")
            }
            if let parameters = item.parameters {
                guard parameters.count <= 100,
                      parameters.allSatisfy({ $0.key.count <= 80 && $0.value.isFinite && abs($0.value) <= 1_000_000 }) else {
                    throw ModSystemError.unsupportedManifest("catalog parameters are outside safe limits")
                }
            }
        }
    }

    private static func validateManifestJSONShape(_ data: Data) throws {
        let object = try jsonObject(data)
        try exactKeys(object, allowed: ["schemaVersion", "modAPI", "id", "name", "version", "publisher", "description", "minAppVersion", "maxAppVersion", "capabilities", "dependencies", "content", "integrity"], required: ["schemaVersion", "modAPI", "id", "name", "version", "publisher", "description", "minAppVersion", "capabilities", "content", "integrity"], context: "manifest")
        if let publisher = object["publisher"] as? [String: Any] {
            try exactKeys(publisher, allowed: ["name", "website"], required: ["name"], context: "publisher")
        } else { throw ModSystemError.unsupportedManifest("publisher must be an object") }
        if let content = object["content"] as? [String: Any] {
            try exactKeys(content, allowed: ["themes", "pages", "sceneProps", "sceneMaps", "effectPresets"], required: [], context: "content")
        } else { throw ModSystemError.unsupportedManifest("content must be an object") }
        if let integrity = object["integrity"] as? [String: Any] {
            try exactKeys(integrity, allowed: ["algorithm", "files"], required: ["algorithm", "files"], context: "integrity")
        } else { throw ModSystemError.unsupportedManifest("integrity must be an object") }
        if let dependencies = object["dependencies"] as? [[String: Any]] {
            for dependency in dependencies {
                try exactKeys(dependency, allowed: ["id", "minVersion"], required: ["id"], context: "dependency")
            }
        }
    }

    private static func validateThemeJSONShape(_ data: Data) throws {
        let object = try jsonObject(data)
        try exactKeys(object, allowed: ["schemaVersion", "id", "name", "tokens"], required: ["schemaVersion", "id", "name", "tokens"], context: "theme")
        guard let tokens = object["tokens"] as? [String: Any] else { throw ModSystemError.unsupportedManifest("theme tokens must be an object") }
        try exactKeys(tokens, allowed: ["windowBackground", "topBarBackground", "panelBackground", "workspaceBackground", "cardBackground", "controlBackground", "primaryText", "secondaryText", "accent", "danger", "separator", "cornerRadius"], required: [], context: "theme tokens")
    }

    private static func validatePageJSONShape(_ data: Data) throws {
        let object = try jsonObject(data)
        try exactKeys(object, allowed: ["schemaVersion", "id", "title", "summary", "blocks"], required: ["schemaVersion", "id", "title", "blocks"], context: "page")
        guard let blocks = object["blocks"] as? [[String: Any]] else { throw ModSystemError.unsupportedManifest("page blocks must be an array") }
        for block in blocks {
            try exactKeys(block, allowed: ["kind", "title", "text", "image", "action", "arguments"], required: ["kind"], context: "page block")
        }
    }

    private static func validateCatalogJSONShape(_ data: Data) throws {
        let object = try jsonObject(data)
        try exactKeys(object, allowed: ["schemaVersion", "id", "name", "summary", "asset", "parameters"], required: ["schemaVersion", "id", "name"], context: "catalog item")
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw ModSystemError.unsupportedManifest("JSON must be an object smaller than 1 MiB")
        }
        return object
    }

    private static func exactKeys(_ object: [String: Any], allowed: Set<String>, required: Set<String>, context: String) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys) else {
            throw ModSystemError.unsupportedManifest("\(context) is missing required fields")
        }
        let unknown = keys.subtracting(allowed)
        guard unknown.isEmpty else {
            throw ModSystemError.unsupportedManifest("unknown \(context) field: \(unknown.sorted().joined(separator: ", "))")
        }
    }

    private static func payloadData(_ path: String, in directory: URL) throws -> Data {
        guard let url = safePayloadURL(base: directory, relativePath: path) else {
            throw ModSystemError.unsupportedManifest("unsafe content path: \(path)")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_048_576 else {
            throw ModSystemError.unsupportedManifest("declarative JSON must be a regular file smaller than 1 MiB: \(path)")
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func boundedText(_ text: String, field: String, maximum: Int) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximum,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }) else {
            throw ModSystemError.unsupportedManifest("\(field) is empty, too long, or contains control characters")
        }
    }

    private static func rejectExecutableMagic(at url: URL, name: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = [UInt8](try handle.read(upToCount: 8) ?? Data())
        let prefixes: [[UInt8]] = [
            [0x7f, 0x45, 0x4c, 0x46], // ELF
            [0x4d, 0x5a],             // Windows PE/DOS
            [0x23, 0x21],             // script shebang
            [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe]
        ]
        if prefixes.contains(where: { bytes.starts(with: $0) }) {
            throw ModSystemError.unsafeArchive("executable content is not allowed, even when renamed: \(name)")
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func addingWithoutOverflow(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else { throw ModSystemError.unsafeArchive("expanded size overflow") }
        return result.partialValue
    }
}
