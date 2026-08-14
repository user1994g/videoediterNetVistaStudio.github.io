import Cocoa

struct ModThemeDocument: Codable, Equatable {
    let schemaVersion: Int
    let id: String
    let name: String
    let tokens: ModThemeTokens
}

struct ModThemeTokens: Codable, Equatable {
    let windowBackground: String?
    let topBarBackground: String?
    let panelBackground: String?
    let workspaceBackground: String?
    let cardBackground: String?
    let controlBackground: String?
    let primaryText: String?
    let secondaryText: String?
    let accent: String?
    let danger: String?
    let separator: String?
    let cornerRadius: Double?
}

struct StudioThemePalette {
    var windowBackground = StudioTheme.color("17191E")!
    var topBarBackground = StudioTheme.color("111317")!
    var panelBackground = StudioTheme.color("20232A")!
    var workspaceBackground = StudioTheme.color("181B21")!
    var cardBackground = StudioTheme.color("202833")!
    var controlBackground = StudioTheme.color("242A33")!
    var primaryText = NSColor.white
    var secondaryText = StudioTheme.color("9DA6B5")!
    var accent = StudioTheme.color("F05B5E")!
    var danger = NSColor.systemRed
    var separator = StudioTheme.color("363B46")!
    var cornerRadius: CGFloat = 7
}

enum StudioThemeRole: Hashable {
    case window
    case topBar
    case panel
    case workspace
    case card
    case control
    case separator
    case primaryText
    case secondaryText
    case accentText
    case accentControl
    case dangerControl
}

extension Notification.Name {
    static let netVistaThemeDidChange = Notification.Name("NetVistaStudioThemeDidChange")
}

/// Applies only bounded visual tokens. Mod themes never provide CSS, HTML,
/// fonts, shaders, selectors, or executable callbacks.
final class StudioTheme {
    static let shared = StudioTheme()

    private(set) var palette = StudioThemePalette()
    private(set) var activeThemeName = "NetVista Default"
    private var registered: [StudioThemeRole: NSHashTable<NSView>] = [:]
    private let lock = NSLock()

    private init() {}

    func register(_ view: NSView, as role: StudioThemeRole) {
        lock.lock()
        let table = registered[role] ?? NSHashTable<NSView>.weakObjects()
        table.add(view)
        registered[role] = table
        lock.unlock()
        apply(role, to: view)
    }

    func apply(_ document: ModThemeDocument) throws {
        guard document.schemaVersion == 1 else {
            throw ModSystemError.unsupportedManifest("theme schema \(document.schemaVersion) is not supported")
        }
        var next = StudioThemePalette()
        let tokens = document.tokens
        next.windowBackground = try resolved(tokens.windowBackground, fallback: next.windowBackground, name: "windowBackground")
        next.topBarBackground = try resolved(tokens.topBarBackground, fallback: next.topBarBackground, name: "topBarBackground")
        next.panelBackground = try resolved(tokens.panelBackground, fallback: next.panelBackground, name: "panelBackground")
        next.workspaceBackground = try resolved(tokens.workspaceBackground, fallback: next.workspaceBackground, name: "workspaceBackground")
        next.cardBackground = try resolved(tokens.cardBackground, fallback: next.cardBackground, name: "cardBackground")
        next.controlBackground = try resolved(tokens.controlBackground, fallback: next.controlBackground, name: "controlBackground")
        next.primaryText = try resolved(tokens.primaryText, fallback: next.primaryText, name: "primaryText")
        next.secondaryText = try resolved(tokens.secondaryText, fallback: next.secondaryText, name: "secondaryText")
        next.accent = try resolved(tokens.accent, fallback: next.accent, name: "accent")
        next.danger = try resolved(tokens.danger, fallback: next.danger, name: "danger")
        next.separator = try resolved(tokens.separator, fallback: next.separator, name: "separator")
        if let radius = tokens.cornerRadius {
            guard radius.isFinite, (0...16).contains(radius) else {
                throw ModSystemError.unsupportedManifest("theme cornerRadius must be between 0 and 16")
            }
            next.cornerRadius = CGFloat(radius)
        }
        palette = next
        activeThemeName = document.name
        refresh()
    }

    func reset() {
        palette = StudioThemePalette()
        activeThemeName = "NetVista Default"
        refresh()
    }

    func refresh() {
        lock.lock()
        let snapshot = registered.mapValues { $0.allObjects }
        lock.unlock()
        let work = {
            for (role, views) in snapshot {
                for view in views { self.apply(role, to: view) }
            }
            NotificationCenter.default.post(name: .netVistaThemeDidChange, object: self)
        }
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    private func apply(_ role: StudioThemeRole, to view: NSView) {
        switch role {
        case .window:
            setBackground(palette.windowBackground, on: view)
        case .topBar:
            setBackground(palette.topBarBackground, on: view)
        case .panel:
            setBackground(palette.panelBackground, on: view)
        case .workspace:
            setBackground(palette.workspaceBackground, on: view)
        case .card:
            setBackground(palette.cardBackground, on: view, rounded: true)
        case .control:
            if let field = view as? NSTextField { field.backgroundColor = palette.controlBackground }
            setBackground(palette.controlBackground, on: view, rounded: true)
        case .separator:
            setBackground(palette.separator, on: view)
        case .primaryText:
            (view as? NSTextField)?.textColor = palette.primaryText
        case .secondaryText:
            (view as? NSTextField)?.textColor = palette.secondaryText
        case .accentText:
            (view as? NSTextField)?.textColor = palette.accent
        case .accentControl:
            (view as? NSButton)?.contentTintColor = palette.accent
        case .dangerControl:
            (view as? NSButton)?.contentTintColor = palette.danger
        }
    }

    private func setBackground(_ color: NSColor, on view: NSView, rounded: Bool = false) {
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        if rounded { view.layer?.cornerRadius = palette.cornerRadius }
    }

    private func resolved(_ raw: String?, fallback: NSColor, name: String) throws -> NSColor {
        guard let raw else { return fallback }
        guard let color = Self.color(raw) else {
            throw ModSystemError.unsupportedManifest("theme token \(name) must be #RRGGBB or #RRGGBBAA")
        }
        return color
    }

    static func color(_ raw: String) -> NSColor? {
        let value = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard value.count == 6 || value.count == 8,
              value.allSatisfy({ $0.isHexDigit }),
              let number = UInt64(value, radix: 16) else { return nil }
        if value.count == 6 {
            return NSColor(
                red: CGFloat((number >> 16) & 0xff) / 255,
                green: CGFloat((number >> 8) & 0xff) / 255,
                blue: CGFloat(number & 0xff) / 255,
                alpha: 1
            )
        }
        return NSColor(
            red: CGFloat((number >> 24) & 0xff) / 255,
            green: CGFloat((number >> 16) & 0xff) / 255,
            blue: CGFloat((number >> 8) & 0xff) / 255,
            alpha: CGFloat(number & 0xff) / 255
        )
    }
}
