import Cocoa
import UniformTypeIdentifiers

final class ModsDropView: NSView {
    var onPackagesDropped: (([URL]) -> Void)?
    private let titleLabel = NSTextField(labelWithString: "Drop .netvistamod packages here")
    private let detailLabel = NSTextField(wrappingLabelWithString: "Packages are checked before installation. Mods cannot run scripts or native plug-in code.")
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 108),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            detailLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        (hovering ? StudioTheme.shared.palette.accent.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.025)).setFill()
        path.fill()
        (hovering ? StudioTheme.shared.palette.accent : NSColor.separatorColor).setStroke()
        path.lineWidth = hovering ? 2.5 : 1
        let dash: [CGFloat] = [7, 5]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !packages(from: sender.draggingPasteboard).isEmpty else { return [] }
        hovering = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hovering = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = packages(from: sender.draggingPasteboard)
        hovering = false
        guard !urls.isEmpty else { return false }
        onPackagesDropped?(urls)
        return true
    }

    private func packages(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "netvistamod" }
    }
}

final class ModsStudioViewController: NSViewController {
    var onAction: ((ModStudioAction) -> Void)?
    var onStatus: ((String) -> Void)?

    private let manager: ModManager
    private let documentStack = NSStackView()
    private var selectedModID: String?
    private var observer: NSObjectProtocol?

    init(manager: ModManager = .shared) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        StudioTheme.shared.register(view, as: .workspace)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        let heading = NSTextField(labelWithString: "MODS")
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        StudioTheme.shared.register(heading, as: .primaryText)
        let warning = NSTextField(labelWithString: "DECLARATIVE · CREATOR UNVERIFIED")
        warning.font = .systemFont(ofSize: 9, weight: .bold)
        warning.textColor = .systemOrange
        header.addArrangedSubview(heading)
        header.addArrangedSubview(warning)
        header.addArrangedSubview(NSView())
        let install = button("Install…", #selector(choosePackage))
        StudioTheme.shared.register(install, as: .accentControl)
        header.addArrangedSubview(install)
        header.addArrangedSubview(button("Open Mods Folder", #selector(openFolder)))
        let rescan = button("Rescan", #selector(rescan))
        header.addArrangedSubview(rescan)
        root.addArrangedSubview(header)

        let drop = ModsDropView()
        drop.onPackagesDropped = { [weak self] in self?.installPackages($0) }
        root.addArrangedSubview(drop)

        let explanation = NSTextField(wrappingLabelWithString: "NetVista mods can add bounded themes, native information/tool pages, catalog entries, scene maps, props, and presets. They cannot contain scripts, native libraries, shaders, HTML, CSS, or executable code. Installed mods start disabled.")
        explanation.font = .systemFont(ofSize: 11)
        StudioTheme.shared.register(explanation, as: .secondaryText)
        root.addArrangedSubview(explanation)

        documentStack.orientation = .vertical
        documentStack.alignment = .width
        documentStack.spacing = 10
        documentStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = documentStack
        NSLayoutConstraint.activate([
            documentStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentStack.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),
            documentStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        root.addArrangedSubview(scroll)

        observer = NotificationCenter.default.addObserver(forName: .netVistaModsDidChange, object: manager, queue: .main) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    func installPackages(_ urls: [URL]) {
        var installed: [String] = []
        var failures: [String] = []
        for url in urls {
            do {
                let mod = try manager.install(packageURL: url)
                installed.append("\(mod.manifest.name) \(mod.manifest.version)")
                selectedModID = mod.id
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reload()
        if !installed.isEmpty {
            onStatus?("Installed \(installed.joined(separator: ", ")) disabled. Review it in Mods before enabling.")
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = failures.count == 1 ? "Mod installation blocked" : "Some mods were blocked"
            alert.informativeText = failures.joined(separator: "\n\n")
            alert.addButton(withTitle: "Done")
            alert.runModal()
        }
    }

    private func reload() {
        guard isViewLoaded else { return }
        documentStack.arrangedSubviews.forEach {
            documentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let mods = manager.installedMods
        if mods.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "No mods installed yet. Drop a .netvistamod package above. You can also put packages in this app's Mods folder, but packages become installed only after opening them here so the safety checks can run.")
            empty.alignment = .center
            StudioTheme.shared.register(empty, as: .secondaryText)
            documentStack.addArrangedSubview(empty)
            return
        }
        for mod in mods { documentStack.addArrangedSubview(modCard(mod)) }
    }

    private func modCard(_ mod: InstalledMod) -> NSView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .width
        card.spacing = 9
        card.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        StudioTheme.shared.register(card, as: .card)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        let title = NSTextField(labelWithString: "\(mod.manifest.name)  \(mod.manifest.version)")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        StudioTheme.shared.register(title, as: .primaryText)
        let badge = NSTextField(labelWithString: manager.isEnabled(mod) ? "ENABLED" : "DISABLED")
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = manager.isEnabled(mod) ? .systemGreen : .secondaryLabelColor
        row.addArrangedSubview(title)
        row.addArrangedSubview(badge)
        row.addArrangedSubview(NSView())
        let toggle = button(manager.isEnabled(mod) ? "Disable" : "Enable", #selector(toggleMod(_:)))
        toggle.identifier = NSUserInterfaceItemIdentifier(mod.id)
        row.addArrangedSubview(toggle)
        let remove = button("Remove…", #selector(removeMod(_:)))
        remove.identifier = NSUserInterfaceItemIdentifier(mod.id)
        StudioTheme.shared.register(remove, as: .dangerControl)
        row.addArrangedSubview(remove)
        card.addArrangedSubview(row)

        let byline = NSTextField(labelWithString: "Creator: \(mod.manifest.publisher.name) · Unverified · ID: \(mod.manifest.id)")
        byline.font = .systemFont(ofSize: 10)
        byline.textColor = .systemOrange
        card.addArrangedSubview(byline)
        let detail = NSTextField(wrappingLabelWithString: mod.manifest.description)
        detail.font = .systemFont(ofSize: 11)
        StudioTheme.shared.register(detail, as: .secondaryText)
        card.addArrangedSubview(detail)

        let capabilityText = mod.manifest.capabilities.map { $0.rawValue }.joined(separator: " · ")
        let capabilities = NSTextField(labelWithString: capabilityText.isEmpty ? "No content capabilities" : capabilityText)
        capabilities.font = .systemFont(ofSize: 9, weight: .medium)
        StudioTheme.shared.register(capabilities, as: .secondaryText)
        card.addArrangedSubview(capabilities)

        if manager.isEnabled(mod) {
            let themes = manager.themeDocuments(for: mod)
            if !themes.isEmpty {
                let themeRow = NSStackView()
                themeRow.orientation = .horizontal
                themeRow.alignment = .centerY
                themeRow.addArrangedSubview(caption("THEMES"))
                for theme in themes {
                    let button = self.button("Apply \(theme.document.name)", #selector(applyTheme(_:)))
                    button.identifier = NSUserInterfaceItemIdentifier("\(mod.id)|\(theme.path)")
                    themeRow.addArrangedSubview(button)
                }
                let reset = button("Default Theme", #selector(resetTheme))
                themeRow.addArrangedSubview(reset)
                themeRow.addArrangedSubview(NSView())
                card.addArrangedSubview(themeRow)
            }

            let pages = manager.pageDocuments(for: mod)
            if !pages.isEmpty {
                card.addArrangedSubview(caption("NATIVE MOD PAGES"))
                for page in pages { card.addArrangedSubview(pageView(page, mod: mod)) }
            }

            let catalog = manager.catalogDocuments(for: mod)
            if !catalog.isEmpty {
                card.addArrangedSubview(caption("CATALOG"))
                for item in catalog {
                    let line = NSStackView()
                    line.orientation = .horizontal
                    line.alignment = .centerY
                    let label = NSTextField(labelWithString: "\(item.capability.rawValue): \(item.document.name)")
                    label.font = .systemFont(ofSize: 11, weight: .medium)
                    StudioTheme.shared.register(label, as: .primaryText)
                    line.addArrangedSubview(label)
                    if let summary = item.document.summary {
                        let text = NSTextField(labelWithString: summary)
                        text.lineBreakMode = .byTruncatingTail
                        StudioTheme.shared.register(text, as: .secondaryText)
                        line.addArrangedSubview(text)
                    }
                    line.addArrangedSubview(NSView())
                    let inspect = button("Details", #selector(showCatalog(_:)))
                    inspect.identifier = NSUserInterfaceItemIdentifier("\(item.capability.rawValue)|\(item.document.name)|\(item.document.summary ?? "No description")")
                    line.addArrangedSubview(inspect)
                    card.addArrangedSubview(line)
                }
            }
        }
        return card
    }

    private func pageView(_ page: ModPageDocument, mod: InstalledMod) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 7
        let title = NSTextField(labelWithString: page.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        StudioTheme.shared.register(title, as: .primaryText)
        stack.addArrangedSubview(title)
        if let summary = page.summary {
            let label = NSTextField(wrappingLabelWithString: summary)
            StudioTheme.shared.register(label, as: .secondaryText)
            stack.addArrangedSubview(label)
        }
        for (index, block) in page.blocks.enumerated() {
            switch block.kind {
            case "heading":
                let label = NSTextField(labelWithString: block.title ?? "")
                label.font = .systemFont(ofSize: 12, weight: .semibold)
                StudioTheme.shared.register(label, as: .accentText)
                stack.addArrangedSubview(label)
            case "text":
                let label = NSTextField(wrappingLabelWithString: block.text ?? "")
                StudioTheme.shared.register(label, as: .secondaryText)
                stack.addArrangedSubview(label)
            case "divider":
                let divider = NSBox(); divider.boxType = .separator
                stack.addArrangedSubview(divider)
            case "image":
                guard let path = block.image,
                      let url = ModPackageValidator.safePayloadURL(base: mod.directoryURL, relativePath: path),
                      let image = NSImage(contentsOf: url) else { continue }
                let imageView = NSImageView(image: image)
                imageView.imageScaling = .scaleProportionallyDown
                imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
                stack.addArrangedSubview(imageView)
            case "button":
                let button = self.button(block.title ?? "Open", #selector(runPageAction(_:)))
                button.identifier = NSUserInterfaceItemIdentifier("\(mod.id)#\(page.id)#\(index)")
                stack.addArrangedSubview(button)
            default: break
            }
        }
        return stack
    }

    @objc private func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = "Install NetVista Mods"
        panel.message = "Installed mods start disabled and cannot run code."
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "netvistamod") ?? .zip]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK else { return }
        installPackages(panel.urls)
    }

    @objc private func openFolder() { onAction?(.openModsFolder) }

    @objc private func rescan() {
        do { try manager.rescan(); onStatus?("Mods folder rescanned.") }
        catch { show(error) }
    }

    @objc private func toggleMod(_ sender: NSButton) {
        guard let mod = mod(for: sender) else { return }
        do {
            try manager.setEnabled(!manager.isEnabled(mod), modID: mod.manifest.id, version: mod.manifest.version)
            onStatus?("\(mod.manifest.name) is now \(manager.isEnabled(mod) ? "enabled" : "disabled").")
        } catch { show(error) }
    }

    @objc private func removeMod(_ sender: NSButton) {
        guard let mod = mod(for: sender) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(mod.manifest.name) \(mod.manifest.version)?"
        alert.informativeText = "This removes only the installed mod package. NetVista Studio projects and original creator downloads are not deleted."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try manager.remove(modID: mod.manifest.id, version: mod.manifest.version)
            onStatus?("Removed \(mod.manifest.name) \(mod.manifest.version).")
        } catch { show(error) }
    }

    @objc private func applyTheme(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let separator = raw.lastIndex(of: "|"),
              let mod = manager.installedMods.first(where: { $0.id == String(raw[..<separator]) }) else { return }
        let path = String(raw[raw.index(after: separator)...])
        do {
            try manager.applyTheme(from: mod, path: path)
            onStatus?("Applied \(StudioTheme.shared.activeThemeName).")
        } catch { show(error) }
    }

    @objc private func resetTheme() {
        do { try manager.resetTheme(); onStatus?("Restored the NetVista default theme.") }
        catch { show(error) }
    }

    @objc private func showCatalog(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        onAction?(.showCatalog(raw.replacingOccurrences(of: "|", with: "\n")))
    }

    @objc private func runPageAction(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let parts = raw.split(separator: "#", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              let index = Int(parts[2]),
              let mod = manager.installedMods.first(where: { $0.id == parts[0] }),
              let page = manager.pageDocuments(for: mod).first(where: { $0.id == parts[1] }),
              page.blocks.indices.contains(index),
              let actionName = page.blocks[index].action,
              let action = ModPageAction(rawValue: actionName) else { return }
        let arguments = page.blocks[index].arguments ?? [:]
        switch action {
        case .importMedia: onAction?(.importMedia)
        case .open3DScene: onAction?(.open3DScene)
        case .openModsFolder: onAction?(.openModsFolder)
        case .showCatalog: onAction?(.showCatalog(arguments["id"] ?? page.title))
        case .openURL:
            guard let target = arguments["url"], let url = URL(string: target),
                  url.scheme?.lowercased() == "https", url.host != nil else { return }
            let alert = NSAlert()
            alert.messageText = "Open this website?"
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { onAction?(.openURL(url)) }
        }
    }

    private func mod(for sender: NSButton) -> InstalledMod? {
        guard let identifier = sender.identifier?.rawValue else { return nil }
        return manager.installedMods.first(where: { $0.id == identifier })
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11, weight: .medium)
        return button
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9, weight: .bold)
        StudioTheme.shared.register(label, as: .accentText)
        return label
    }

    private func show(_ error: Error) {
        onStatus?(error.localizedDescription)
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
