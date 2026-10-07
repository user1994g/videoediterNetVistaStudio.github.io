import Cocoa
import UniformTypeIdentifiers

final class ModCreatorWindowController: NSWindowController {
    init(manager: ModManager, onCreated: @escaping (String) -> Void) {
        let editor = ModCreatorViewController(manager: manager)
        let window = NSWindow(contentViewController: editor)
        window.title = "NetVista Studio — Mod Creator"
        window.setContentSize(NSSize(width: 900, height: 720))
        window.contentMinSize = NSSize(width: 790, height: 570)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        editor.onCreated = onCreated
        editor.onClose = { [weak self] in self?.close() }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ModCreatorDocumentStack: NSStackView {
    override var isFlipped: Bool { true }

    override func addArrangedSubview(_ view: NSView) {
        super.addArrangedSubview(view)
        if orientation == .vertical {
            view.widthAnchor.constraint(equalTo: widthAnchor, constant: -(edgeInsets.left + edgeInsets.right)).isActive = true
        }
    }
}

final class ModCreatorViewController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    var onCreated: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let manager: ModManager
    private var draft = ModAuthoringDraft()
    private let nameField = NSTextField(string: "My Studio Theme")
    private let idField = NSTextField(string: "local.creator.my-studio-theme")
    private let creatorField = NSTextField(string: "Local Creator")
    private let versionField = NSTextField(string: "1.0.0")
    private let descriptionField = NSTextField(string: "A custom NetVista Studio theme.")
    private let pageTitleField = NSTextField(string: "My Studio Tools")
    private let pageBody = NSTextView()
    private let templatePicker = NSSegmentedControl(labels: ModAuthoringKind.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let shortcutPicker = NSPopUpButton()
    private let palettePicker = NSPopUpButton()
    private let colorFields = (0..<5).map { _ in NSTextField(string: "") }
    private let colorWells = (0..<5).map { _ in NSColorWell() }
    private let radius = NSSlider(value: 7, minValue: 0, maxValue: 16, target: nil, action: nil)
    private let radiusValue = NSTextField(labelWithString: "7")
    private let presetValues = [
        NSSlider(value: 0, minValue: -4, maxValue: 4, target: nil, action: nil),
        NSSlider(value: 1, minValue: 0, maxValue: 3, target: nil, action: nil),
        NSSlider(value: 1, minValue: 0, maxValue: 3, target: nil, action: nil)
    ]
    private let presetLabels = (0..<3).map { _ in NSTextField(labelWithString: "1.00") }
    private let templateDescription = NSTextField(wrappingLabelWithString: "")
    private let preview = ModCreatorPreviewView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let contentStack = ModCreatorDocumentStack()
    private var themeSection = NSView()
    private var pageSection = NSView()
    private var presetSection = NSView()
    private var exportButton = NSButton()
    private var testButton = NSButton()
    private var identifierWasEdited = false
    private var busy = false

    init(manager: ModManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
        StudioTheme.shared.register(view, as: .workspace)
        let root = stack(.vertical, spacing: 12)
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let title = label("Create a Studio mod", size: 21, weight: .semibold)
        root.addArrangedSubview(title)
        root.addArrangedSubview(label("Choose a template, customize it, then export. NetVista handles the manifest and file checks for you.", size: 11, secondary: true, wrapping: true))
        templatePicker.selectedSegment = 0
        templatePicker.target = self
        templatePicker.action = #selector(templateChanged)
        templatePicker.segmentDistribution = .fillEqually
        templatePicker.setAccessibilityLabel("Mod template")
        root.addArrangedSubview(templatePicker)
        templateDescription.font = .systemFont(ofSize: 11)
        templateDescription.maximumNumberOfLines = 3
        StudioTheme.shared.register(templateDescription, as: .secondaryText)
        root.addArrangedSubview(templateDescription)

        let body = stack(.horizontal, spacing: 18)
        body.alignment = .top
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 18, right: 8)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = contentStack
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            contentStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        let identity = section("PACKAGE DETAILS")
        identity.addArrangedSubview(fieldRow("Name", nameField))
        identity.addArrangedSubview(fieldRow("Mod ID", idField))
        identity.addArrangedSubview(label("Use a stable ID. The suggested local.creator ID is fine for your own mods; use your own namespace when publishing.", size: 10, secondary: true, wrapping: true))
        identity.addArrangedSubview(fieldRow("Creator", creatorField))
        identity.addArrangedSubview(fieldRow("Version", versionField))
        identity.addArrangedSubview(fieldRow("Description", descriptionField))
        contentStack.addArrangedSubview(identity)
        for (index, field) in [nameField, idField, creatorField, versionField, descriptionField, pageTitleField].enumerated() {
            field.tag = index
            field.delegate = self
            field.font = .systemFont(ofSize: 11)
            field.alignment = .left
            field.lineBreakMode = .byTruncatingTail
        }
        nameField.setAccessibilityLabel("Mod name")
        idField.setAccessibilityLabel("Mod identifier")
        themeSection = makeThemeSection()
        pageSection = makePageSection()
        presetSection = makePresetSection()
        contentStack.addArrangedSubview(themeSection)
        contentStack.addArrangedSubview(pageSection)
        contentStack.addArrangedSubview(presetSection)
        body.addArrangedSubview(scroll)
        let previewColumn = stack(.vertical, spacing: 10)
        previewColumn.addArrangedSubview(label("LOCAL PREVIEW", size: 10, weight: .semibold, secondary: true))
        previewColumn.addArrangedSubview(preview)
        preview.heightAnchor.constraint(equalToConstant: 250).isActive = true
        previewColumn.addArrangedSubview(label("Preview does not change your app theme or run page shortcuts.", size: 10, secondary: true, wrapping: true))
        previewColumn.addArrangedSubview(label("Test Install adds your package to Mods, disabled. Enable it there to try the theme or page. Already installed? Increase the version before changing its contents.", size: 11, secondary: true, wrapping: true))
        previewColumn.addArrangedSubview(label("Data only · No scripts · No network permissions", size: 10, weight: .medium, secondary: true, wrapping: true))
        body.addArrangedSubview(previewColumn)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: body.widthAnchor, multiplier: 0.56),
            scroll.heightAnchor.constraint(equalTo: body.heightAnchor),
            previewColumn.widthAnchor.constraint(equalTo: body.widthAnchor, multiplier: 0.44, constant: -18),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 270)
        ])
        root.addArrangedSubview(body)
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        let divider = NSBox(); divider.boxType = .separator
        root.addArrangedSubview(divider)
        status.font = .systemFont(ofSize: 11)
        status.maximumNumberOfLines = 2
        status.setAccessibilityLabel("Creator status")
        root.addArrangedSubview(status)
        let footer = stack(.horizontal, spacing: 9)
        footer.alignment = .centerY
        footer.addArrangedSubview(button("Close", #selector(closeCreator)))
        footer.addArrangedSubview(NSView())
        testButton = button("Test Install", #selector(testInstall))
        footer.addArrangedSubview(testButton)
        exportButton = button("Export .netvistamod…", #selector(exportPackage))
        StudioTheme.shared.register(exportButton, as: .accentControl)
        footer.addArrangedSubview(exportButton)
        root.addArrangedSubview(footer)
        refresh()
    }

    private func makeThemeSection() -> NSView {
        let group = section("THEME COLOURS")
        palettePicker.addItems(withTitles: ["Studio", "Midnight", "Ocean", "Forest"])
        palettePicker.target = self; palettePicker.action = #selector(paletteChanged)
        group.addArrangedSubview(fieldRow("Start with", palettePicker))
        for (index, title) in ["Accent", "Panel", "Workspace", "Text", "Secondary text"].enumerated() {
            let line = stack(.horizontal, spacing: 8)
            line.alignment = .centerY
            let caption = label(title, size: 11)
            caption.widthAnchor.constraint(equalToConstant: 90).isActive = true
            line.addArrangedSubview(caption)
            colorWells[index].tag = index
            colorWells[index].target = self; colorWells[index].action = #selector(colorChanged(_:))
            colorWells[index].widthAnchor.constraint(equalToConstant: 44).isActive = true
            colorWells[index].heightAnchor.constraint(equalToConstant: 24).isActive = true
            colorWells[index].setAccessibilityLabel("\(title) colour")
            line.addArrangedSubview(colorWells[index])
            colorFields[index].tag = 200 + index; colorFields[index].delegate = self
            colorFields[index].font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            colorFields[index].setContentHuggingPriority(.defaultLow, for: .horizontal)
            colorFields[index].setAccessibilityLabel("\(title) hexadecimal colour")
            line.addArrangedSubview(colorFields[index])
            group.addArrangedSubview(line)
        }
        radius.target = self; radius.action = #selector(valuesChanged)
        let line = stack(.horizontal, spacing: 7)
        line.addArrangedSubview(label("Corners", size: 11))
        line.addArrangedSubview(radius); line.addArrangedSubview(radiusValue)
        radiusValue.widthAnchor.constraint(equalToConstant: 26).isActive = true
        group.addArrangedSubview(line)
        return group
    }

    private func makePageSection() -> NSView {
        let group = section("NATIVE TOOL PAGE")
        group.addArrangedSubview(fieldRow("Page title", pageTitleField))
        group.addArrangedSubview(label("Page text", size: 11))
        pageBody.isRichText = false
        pageBody.font = .systemFont(ofSize: 12)
        pageBody.string = draft.pageBody
        pageBody.delegate = self
        pageBody.isVerticallyResizable = true
        pageBody.isHorizontallyResizable = false
        pageBody.autoresizingMask = [.width]
        pageBody.textContainer?.widthTracksTextView = true
        pageBody.textContainerInset = NSSize(width: 8, height: 8)
        pageBody.setAccessibilityLabel("Page body text")
        let textScroll = NSScrollView()
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.documentView = pageBody
        textScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        group.addArrangedSubview(textScroll)
        shortcutPicker.addItems(withTitles: ModAuthoringPageShortcut.allCases.map(\.title))
        shortcutPicker.selectItem(at: 2)
        shortcutPicker.target = self; shortcutPicker.action = #selector(valuesChanged)
        group.addArrangedSubview(fieldRow("Shortcut", shortcutPicker))
        group.addArrangedSubview(label("Shortcuts use built-in Studio actions. This template cannot embed websites or execute code.", size: 10, secondary: true, wrapping: true))
        return group
    }

    private func makePresetSection() -> NSView {
        let group = section("LOOK REFERENCE")
        group.addArrangedSubview(label("Catalog-only in Mods v1. These numbers are shared as a reference, not inserted into an effect stack.", size: 11, secondary: true, wrapping: true))
        for (index, title) in ["Exposure", "Contrast", "Saturation"].enumerated() {
            let line = stack(.horizontal, spacing: 7)
            let caption = label(title, size: 11)
            caption.widthAnchor.constraint(equalToConstant: 75).isActive = true
            line.addArrangedSubview(caption)
            presetValues[index].target = self; presetValues[index].action = #selector(valuesChanged)
            line.addArrangedSubview(presetValues[index])
            presetLabels[index].font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            presetLabels[index].widthAnchor.constraint(equalToConstant: 36).isActive = true
            line.addArrangedSubview(presetLabels[index])
            group.addArrangedSubview(line)
        }
        return group
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === idField { identifierWasEdited = true }
        if notification.object as? NSTextField === nameField, !identifierWasEdited {
            idField.stringValue = ModAuthoringDraft.suggestedIdentifier(for: nameField.stringValue)
        }
        refresh()
    }

    func textDidChange(_ notification: Notification) { refresh() }

    @objc private func templateChanged() { refresh() }
    @objc private func valuesChanged() { refresh() }

    @objc private func paletteChanged() {
        let palettes = [
            ["#F05B5E", "#20232A", "#181B21", "#F4F6FA", "#9DA6B5"],
            ["#B3A0FF", "#1D1C2B", "#11111B", "#F2EFFA", "#A6A0BB"],
            ["#52BDE3", "#182C38", "#0F1E29", "#EBF7FC", "#91ACBA"],
            ["#83C6A3", "#202B27", "#131E1A", "#EEF6F1", "#A0B5A9"]
        ]
        for (index, color) in palettes[max(0, palettePicker.indexOfSelectedItem)].enumerated() { colorFields[index].stringValue = color }
        refresh()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard colorFields.indices.contains(sender.tag), let color = sender.color.usingColorSpace(.deviceRGB) else { return }
        colorFields[sender.tag].stringValue = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        refresh()
    }

    private func readDraft() -> ModAuthoringDraft {
        var result = draft
        result.kind = ModAuthoringKind.allCases[max(0, templatePicker.selectedSegment)]
        result.name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.identifier = idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.publisher = creatorField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.version = versionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.description = descriptionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !colorFields[0].stringValue.isEmpty {
            result.accent = colorFields[0].stringValue
            result.panel = colorFields[1].stringValue
            result.workspace = colorFields[2].stringValue
            result.primaryText = colorFields[3].stringValue
            result.secondaryText = colorFields[4].stringValue
        }
        result.cornerRadius = radius.doubleValue.rounded()
        result.pageTitle = pageTitleField.stringValue
        result.pageBody = pageBody.string
        result.pageShortcut = ModAuthoringPageShortcut.allCases[max(0, shortcutPicker.indexOfSelectedItem)]
        result.exposure = presetValues[0].doubleValue; result.contrast = presetValues[1].doubleValue; result.saturation = presetValues[2].doubleValue
        return result
    }

    private func refresh() {
        draft = readDraft()
        themeSection.isHidden = draft.kind != .theme
        pageSection.isHidden = draft.kind != .page
        presetSection.isHidden = draft.kind != .effectPreset
        templateDescription.stringValue = draft.kind.detail
        radiusValue.stringValue = String(format: "%.0f", draft.cornerRadius)
        for (index, value) in [draft.exposure, draft.contrast, draft.saturation].enumerated() { presetLabels[index].stringValue = String(format: "%.2f", value) }
        for (index, value) in [draft.accent, draft.panel, draft.workspace, draft.primaryText, draft.secondaryText].enumerated() {
            if colorFields[index].stringValue.isEmpty { colorFields[index].stringValue = value }
            if let color = StudioTheme.color(value) { colorWells[index].color = color }
        }
        preview.draft = draft
        do {
            try draft.validate()
            if !busy { status.stringValue = "Ready to export. Every payload will be hashed and checked before the file is saved."; status.textColor = .secondaryLabelColor }
            exportButton.isEnabled = !busy; testButton.isEnabled = !busy
        } catch {
            if !busy { status.stringValue = error.localizedDescription; status.textColor = .systemOrange }
            exportButton.isEnabled = false; testButton.isEnabled = false
        }
    }

    @objc private func exportPackage() {
        let captured = readDraft()
        let panel = NSSavePanel()
        panel.title = "Export NetVista Mod"
        panel.allowedContentTypes = [UTType(filenameExtension: "netvistamod") ?? .zip]
        panel.nameFieldStringValue = captured.identifier + ".netvistamod"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        performWork("Building and checking your package…") { try ModPackageAuthor.export(captured, to: url); return "Exported \(url.lastPathComponent). Share this file, or install it from Mods." }
    }

    @objc private func testInstall() {
        let captured = readDraft()
        let manager = self.manager
        // Package generation is off the UI thread; actual manager mutation is
        // serialized on the main thread with the rest of the Mods controls.
        performWork("Building and checking your test package…") {
            let data = try ModPackageAuthor.packageData(for: captured)
            let package = FileManager.default.temporaryDirectory.appendingPathComponent("NetVistaModTest-\(UUID().uuidString).netvistamod")
            try data.write(to: package, options: [.withoutOverwriting])
            defer { try? FileManager.default.removeItem(at: package) }
            var installed: InstalledMod?
            var failure: Error?
            DispatchQueue.main.sync {
                do { installed = try manager.install(packageURL: package) } catch { failure = error }
            }
            if let failure { throw failure }
            return "Installed \(installed?.manifest.name ?? captured.name). Review it in Mods; new packages start disabled."
        }
    }

    private func performWork(_ message: String, operation: @escaping () throws -> String) {
        guard !busy else { return }
        busy = true; exportButton.isEnabled = false; testButton.isEnabled = false
        status.stringValue = message; status.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try operation() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.refresh()
                switch result {
                case .success(let text):
                    self.status.stringValue = text; self.status.textColor = .systemGreen
                    self.onCreated?(text)
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription; self.status.textColor = .systemOrange
                }
            }
        }
    }

    @objc private func closeCreator() { onClose?() }

    private func stack(_ orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat) -> NSStackView {
        let result = ModCreatorDocumentStack(); result.orientation = orientation
        result.alignment = orientation == .vertical ? .leading : .centerY; result.spacing = spacing
        return result
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false, wrapping: Bool = false) -> NSTextField {
        let result = wrapping ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        result.font = .systemFont(ofSize: size, weight: weight)
        result.alignment = .left
        StudioTheme.shared.register(result, as: secondary ? .secondaryText : .primaryText)
        return result
    }

    private func section(_ name: String) -> NSStackView {
        let result = stack(.vertical, spacing: 9)
        result.addArrangedSubview(label(name, size: 10, weight: .semibold, secondary: true))
        return result
    }

    private func fieldRow(_ title: String, _ control: NSView) -> NSView {
        let row = stack(.horizontal, spacing: 8)
        let caption = label(title, size: 11)
        caption.widthAnchor.constraint(equalToConstant: 90).isActive = true
        row.addArrangedSubview(caption); row.addArrangedSubview(control)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded; result.font = .systemFont(ofSize: 11, weight: .medium)
        return result
    }

    #if MOD_AUTHORING_CHECKS
    func testSetTemplate(_ kind: ModAuthoringKind) { templatePicker.selectedSegment = ModAuthoringKind.allCases.firstIndex(of: kind)!; refresh() }
    func testSetName(_ name: String) { nameField.stringValue = name; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nameField)) }
    func testSetIdentifier(_ identifier: String) { idField.stringValue = identifier; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: idField)) }
    var testDraft: ModAuthoringDraft { readDraft() }
    var testCanExport: Bool { exportButton.isEnabled }
    var testVisibleSections: [Bool] { [!themeSection.isHidden, !pageSection.isHidden, !presetSection.isHidden] }
    #endif
}

private final class ModCreatorPreviewView: NSView {
    var draft = ModAuthoringDraft() { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let palette = StudioTheme.shared.palette
        let workspace = draft.kind == .theme ? StudioTheme.color(draft.workspace) ?? palette.workspaceBackground : palette.workspaceBackground
        let panel = draft.kind == .theme ? StudioTheme.color(draft.panel) ?? palette.panelBackground : palette.panelBackground
        let accent = draft.kind == .theme ? StudioTheme.color(draft.accent) ?? palette.accent : palette.accent
        let primary = draft.kind == .theme ? StudioTheme.color(draft.primaryText) ?? palette.primaryText : palette.primaryText
        let secondary = draft.kind == .theme ? StudioTheme.color(draft.secondaryText) ?? palette.secondaryText : palette.secondaryText
        let radius = CGFloat(draft.cornerRadius.isFinite ? min(16, max(0, draft.cornerRadius)) : 7)
        panel.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius).fill()
        func text(_ value: String, _ rect: NSRect, size: CGFloat = 11, color: NSColor, bold: Bool = false) {
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color, .paragraphStyle: style])
        }
        let width = bounds.width
        text(draft.kind == .page ? draft.pageTitle : draft.name, NSRect(x: 16, y: 16, width: width - 32, height: 26), size: 15, color: primary, bold: true)
        switch draft.kind {
        case .theme:
            workspace.setFill(); NSBezierPath(roundedRect: NSRect(x: 16, y: 54, width: width - 32, height: 115), xRadius: radius, yRadius: radius).fill()
            text("YOUR WORKSPACE", NSRect(x: 30, y: 68, width: width - 60, height: 18), size: 9, color: secondary, bold: true)
            text("Panels. Tools. Your colours.", NSRect(x: 30, y: 103, width: width - 60, height: 36), size: 13, color: primary)
            accent.setFill(); NSBezierPath(roundedRect: NSRect(x: 16, y: 187, width: min(155, width - 32), height: 30), xRadius: radius, yRadius: radius).fill()
            text("Accent preview", NSRect(x: 28, y: 194, width: 130, height: 20), size: 11, color: .black, bold: true)
        case .page:
            text(draft.pageBody, NSRect(x: 16, y: 54, width: width - 32, height: 112), size: 12, color: secondary)
            if draft.pageShortcut != .none {
                accent.withAlphaComponent(0.18).setFill(); NSBezierPath(roundedRect: NSRect(x: 16, y: 187, width: width - 32, height: 30), xRadius: 6, yRadius: 6).fill()
                text(draft.pageShortcut.title + "  (preview)", NSRect(x: 26, y: 194, width: width - 52, height: 20), color: accent, bold: true)
            }
        case .effectPreset:
            text("CATALOG REFERENCE", NSRect(x: 16, y: 52, width: width - 32, height: 20), size: 9, color: accent, bold: true)
            for (index, item) in [("Exposure", draft.exposure), ("Contrast", draft.contrast), ("Saturation", draft.saturation)].enumerated() {
                text(item.0, NSRect(x: 16, y: CGFloat(88 + index * 32), width: width - 100, height: 20), color: secondary)
                text(String(format: "%.2f", item.1), NSRect(x: width - 70, y: CGFloat(88 + index * 32), width: 54, height: 20), color: primary, bold: true)
            }
        }
        palette.separator.setStroke(); let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius); border.lineWidth = 1; border.stroke()
    }
}
