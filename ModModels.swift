import Foundation

enum ModCapability: String, Codable, CaseIterable {
    case theme
    case page
    case sceneProp
    case sceneMap
    case effectPreset
}

struct ModPublisher: Codable, Equatable {
    let name: String
    let website: String?
}

struct ModDependency: Codable, Equatable {
    let id: String
    let minVersion: String?
}

struct ModContent: Codable, Equatable {
    var themes: [String] = []
    var pages: [String] = []
    var sceneProps: [String] = []
    var sceneMaps: [String] = []
    var effectPresets: [String] = []

    private enum CodingKeys: String, CodingKey {
        case themes, pages, sceneProps, sceneMaps, effectPresets
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        themes = try container.decodeIfPresent([String].self, forKey: .themes) ?? []
        pages = try container.decodeIfPresent([String].self, forKey: .pages) ?? []
        sceneProps = try container.decodeIfPresent([String].self, forKey: .sceneProps) ?? []
        sceneMaps = try container.decodeIfPresent([String].self, forKey: .sceneMaps) ?? []
        effectPresets = try container.decodeIfPresent([String].self, forKey: .effectPresets) ?? []
    }
}

struct ModIntegrity: Codable, Equatable {
    let algorithm: String
    let files: [String: String]
}

struct ModManifest: Codable, Equatable {
    let schemaVersion: Int
    let modAPI: String
    let id: String
    let name: String
    let version: String
    let publisher: ModPublisher
    let description: String
    let minAppVersion: String
    let maxAppVersion: String?
    let capabilities: [ModCapability]
    let dependencies: [ModDependency]?
    let content: ModContent
    let integrity: ModIntegrity
}

struct InstalledMod: Equatable, Identifiable {
    var id: String { "\(manifest.id)@\(manifest.version)" }
    let manifest: ModManifest
    let directoryURL: URL
    let packageDigest: String
    let installedAt: Date
}

struct ModVersionState: Codable, Equatable {
    var enabledVersion: String?
}

struct ModThemeSelection: Codable, Equatable {
    let modID: String
    let version: String
    let path: String
}

struct ModStateFile: Codable, Equatable {
    var schemaVersion: Int = 1
    var mods: [String: ModVersionState] = [:]
    var activeTheme: ModThemeSelection?

    private enum CodingKeys: String, CodingKey { case schemaVersion, mods, activeTheme }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        mods = try container.decodeIfPresent([String: ModVersionState].self, forKey: .mods) ?? [:]
        activeTheme = try container.decodeIfPresent(ModThemeSelection.self, forKey: .activeTheme)
    }
}

struct ModPageDocument: Codable, Equatable {
    let schemaVersion: Int
    let id: String
    let title: String
    let summary: String?
    let blocks: [ModPageBlock]
}

struct ModPageBlock: Codable, Equatable {
    let kind: String
    let title: String?
    let text: String?
    let image: String?
    let action: String?
    let arguments: [String: String]?
}

struct ModCatalogDocument: Codable, Equatable {
    let schemaVersion: Int
    let id: String
    let name: String
    let summary: String?
    let asset: String?
    let parameters: [String: Double]?
}

enum ModPageAction: String, CaseIterable {
    case importMedia
    case open3DScene
    case openModsFolder
    case showCatalog
    case openURL
}

enum ModStudioAction {
    case importMedia
    case open3DScene
    case openModsFolder
    case showCatalog(String)
    case openURL(URL)
}

enum ModSystemError: LocalizedError {
    case cannotFindApplicationSupport
    case invalidPackage(String)
    case unsafeArchive(String)
    case unsupportedManifest(String)
    case incompatibleApp(String)
    case integrityFailure(String)
    case dependencyMissing(String)
    case toolFailure(String)
    case modNotFound

    var errorDescription: String? {
        switch self {
        case .cannotFindApplicationSupport:
            return "NetVista Studio could not find its Application Support folder."
        case .invalidPackage(let detail):
            return "This is not a valid NetVista mod: \(detail)"
        case .unsafeArchive(let detail):
            return "The mod was blocked because its archive is unsafe: \(detail)"
        case .unsupportedManifest(let detail):
            return "The mod manifest is not supported: \(detail)"
        case .incompatibleApp(let detail):
            return "This mod is not compatible with this version of NetVista Studio: \(detail)"
        case .integrityFailure(let detail):
            return "The mod failed its SHA-256 safety check: \(detail)"
        case .dependencyMissing(let detail):
            return "The mod cannot be enabled until this dependency is enabled: \(detail)"
        case .toolFailure(let detail):
            return "The mod package could not be inspected: \(detail)"
        case .modNotFound:
            return "That installed mod could not be found."
        }
    }
}

struct ModSemanticVersion: Comparable, Equatable {
    private let core: [Int]
    private let prerelease: [String]?

    init?(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = try? NSRegularExpression(pattern: #"^[vV]?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$"#)
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        guard let match = expression?.firstMatch(in: cleaned, range: range), match.range == range else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: cleaned) else { return nil }
            return String(cleaned[range])
        }
        guard let major = group(1).flatMap(Int.init),
              let minor = group(2).flatMap(Int.init),
              let patch = group(3).flatMap(Int.init) else { return nil }
        core = [major, minor, patch]
        prerelease = group(4)?.split(separator: ".").map(String.init)
    }

    static func < (lhs: ModSemanticVersion, rhs: ModSemanticVersion) -> Bool {
        for index in 0..<3 where lhs.core[index] != rhs.core[index] {
            return lhs.core[index] < rhs.core[index]
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case (.some(let left), .some(let right)):
            for index in 0..<max(left.count, right.count) {
                if index >= left.count { return true }
                if index >= right.count { return false }
                let l = left[index], r = right[index]
                if l == r { continue }
                if let li = Int(l), let ri = Int(r) { return li < ri }
                if Int(l) != nil { return true }
                if Int(r) != nil { return false }
                return l < r
            }
            return false
        }
    }
}
