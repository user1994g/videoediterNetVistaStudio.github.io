import Cocoa

/// Shared native chrome for the video tool windows. Content and rendering stay
/// with each editor; navigation, spacing and theme tokens are common.
final class StudioWorkspaceStack: NSStackView {
    override var isFlipped: Bool { true }
}

enum StudioWorkspaceUI {
    static func panel(_ view: NSView, role: StudioThemeRole = .panel) {
        StudioTheme.shared.register(view, as: role)
        view.wantsLayer = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = StudioTheme.shared.palette.separator.cgColor
    }

    static func label(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .regular,
                      secondary: Bool = true, wrapping: Bool = false) -> NSTextField {
        let field = wrapping ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.alignment = .left
        field.lineBreakMode = wrapping ? .byWordWrapping : .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        StudioTheme.shared.register(field, as: secondary ? .secondaryText : .primaryText)
        return field
    }

    static func header(title: String, selection: NSTextField) -> NSStackView {
        let header = NSStackView(); header.orientation = .vertical; header.alignment = .width
        header.spacing = 6; header.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        panel(header)
        header.identifier = NSUserInterfaceItemIdentifier("studio-workspace-header")
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        row.addArrangedSubview(label(title, size: 18, weight: .semibold, secondary: false))
        row.addArrangedSubview(NSView())
        let live = label("● LIVE PREVIEW", size: 9, weight: .semibold)
        live.textColor = .systemGreen; row.addArrangedSubview(live)
        header.addArrangedSubview(row)
        selection.font = .systemFont(ofSize: 11, weight: .medium)
        selection.alignment = .left
        selection.lineBreakMode = .byTruncatingMiddle
        selection.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        StudioTheme.shared.register(selection, as: .secondaryText)
        header.addArrangedSubview(selection)
        return header
    }

    static func footer(note: String, buttons: [NSButton]) -> NSStackView {
        let footer = NSStackView(); footer.orientation = .vertical; footer.alignment = .width
        footer.spacing = 7; footer.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        panel(footer)
        footer.identifier = NSUserInterfaceItemIdentifier("studio-workspace-footer")
        footer.addArrangedSubview(label(note, size: 10, wrapping: true))
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        row.addArrangedSubview(NSView()); buttons.forEach { row.addArrangedSubview($0) }
        footer.addArrangedSubview(row)
        return footer
    }

    static func button(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 11, weight: .medium)
        return button
    }

    static func numericField(_ field: NSTextField, title: String) {
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        field.alignment = .right; field.toolTip = "Enter \(title) precisely, then press Return"
        field.setAccessibilityLabel("\(title) value")
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
    }

    /// A short horizontal strip may scroll on narrow displays, instead of
    /// increasing the minimum window width or pushing controls off-screen.
    static func toolbar(_ document: NSStackView) -> NSScrollView {
        document.translatesAutoresizingMaskIntoConstraints = false
        document.setContentHuggingPriority(.required, for: .horizontal)
        let scroll = NSScrollView(); scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document; scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(equalToConstant: 39).isActive = true
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }

    static func scroll(_ document: NSView) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }

    /// NSStackView's width alignment does not stretch every arranged child to
    /// its containing panel. Explicitly anchor width-aligned vertical stacks;
    /// preserve center-aligned fixed-size controls such as colour wheels.
    static func alignContent(_ root: NSView) {
        // AppKit rejects .width as an alignment attribute and normalizes it to
        // .notAnAttribute. Older panels used it widely; give those stacks a
        // valid leading alignment plus explicit fill-width constraints.
        if let stack = root as? NSStackView, stack.orientation == .vertical,
           stack.alignment == .width || stack.alignment == .notAnAttribute {
            stack.alignment = .leading
            let inset = stack.edgeInsets.left + stack.edgeInsets.right
            for child in stack.arrangedSubviews {
                child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
            }
        }
        if let label = root as? NSTextField, !label.isEditable, label.alignment == .natural { label.alignment = .left }
        root.subviews.forEach(alignContent)
    }
}
