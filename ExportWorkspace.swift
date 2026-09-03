import Cocoa

/// Native delivery workspace used by the Export page.
/// It owns only presentation state; the editor supplies the timeline and output URL.
final class ExportWorkspaceViewController: NSViewController {
    var onStartExport: ((TimelineExportOptions) -> Void)?
    var onCancelExport: (() -> Void)?

    private let resolutionPopup = NSPopUpButton()
    private let containerPopup = NSPopUpButton()
    private let codecPopup = NSPopUpButton()
    private let frameRatePopup = NSPopUpButton()
    private let customWidthField = NSTextField(string: "1920")
    private let customHeightField = NSTextField(string: "1080")
    private lazy var customWidthRow = field("Custom width", customWidthField)
    private lazy var customHeightRow = field("Custom height", customHeightField)
    private let includeAudioButton = NSButton(checkboxWithTitle: "Include timeline audio", target: nil, action: nil)
    private let streamingButton = NSButton(checkboxWithTitle: "Fast-start playback", target: nil, action: nil)
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let capabilityLabel = NSTextField(wrappingLabelWithString: "")
    private let exportButton = NSButton(title: "Export Movie…", target: nil, action: nil)
    private lazy var progressWindowController: ExportProgressWindowController = {
        let controller = ExportProgressWindowController()
        controller.onCancel = { [weak self] in self?.onCancelExport?() }
        return controller
    }()

    private(set) var isExporting = false

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(hex: "171B22").cgColor

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let eyebrow = NSTextField(labelWithString: "DELIVER")
        eyebrow.font = .systemFont(ofSize: 10, weight: .bold)
        eyebrow.textColor = NSColor(hex: "77A7FF")
        let title = NSTextField(labelWithString: "Export your finished timeline")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = .white
        let intro = NSTextField(wrappingLabelWithString: "Create a standard MP4 or a high-quality MOV directly on this Mac. The save window opens in Downloads by default, and you can choose another folder whenever you want.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        root.addArrangedSubview(eyebrow)
        root.addArrangedSubview(title)
        root.addArrangedSubview(intro)

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 16
        columns.distribution = .fillEqually
        root.addArrangedSubview(columns)

        let settings = card()
        settings.addArrangedSubview(sectionTitle("EXPORT SETTINGS"))
        configurePopups()
        settings.addArrangedSubview(field("Resolution", resolutionPopup))
        settings.addArrangedSubview(customWidthRow)
        settings.addArrangedSubview(customHeightRow)
        settings.addArrangedSubview(field("Format", containerPopup))
        settings.addArrangedSubview(field("Video codec", codecPopup))
        settings.addArrangedSubview(field("Frame rate", frameRatePopup))
        includeAudioButton.state = .on
        streamingButton.state = .on
        settings.addArrangedSubview(includeAudioButton)
        settings.addArrangedSubview(streamingButton)
        columns.addArrangedSubview(settings)

        let details = card()
        details.addArrangedSubview(sectionTitle("OUTPUT SUMMARY"))
        summaryLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        summaryLabel.textColor = .white
        details.addArrangedSubview(summaryLabel)
        capabilityLabel.font = .systemFont(ofSize: 11)
        capabilityLabel.textColor = .secondaryLabelColor
        details.addArrangedSubview(capabilityLabel)
        details.addArrangedSubview(NSView())
        columns.addArrangedSubview(details)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.addArrangedSubview(NSView())
        exportButton.target = self
        exportButton.action = #selector(startExport)
        exportButton.bezelStyle = .rounded
        exportButton.contentTintColor = .systemBlue
        actions.addArrangedSubview(exportButton)
        root.addArrangedSubview(actions)

        updateSummary()
    }

    private func configurePopups() {
        resolutionPopup.addItems(withTitles: TimelineExportResolution.allCases.map(\.title))
        containerPopup.addItems(withTitles: TimelineExportContainer.allCases.map(\.title))
        codecPopup.addItems(withTitles: TimelineExportCodec.allCases.map(\.title))
        frameRatePopup.addItems(withTitles: ["24 fps", "25 fps", "30 fps", "60 fps"])
        frameRatePopup.selectItem(at: 2)
        for popup in [resolutionPopup, containerPopup, codecPopup, frameRatePopup] {
            popup.target = self
            popup.action = #selector(settingChanged(_:))
        }
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .none
        numberFormatter.minimum = 64
        numberFormatter.maximum = 15_360
        customWidthField.formatter = numberFormatter
        let heightFormatter = numberFormatter.copy() as! NumberFormatter
        heightFormatter.maximum = 8_640
        customHeightField.formatter = heightFormatter
        for field in [customWidthField, customHeightField] {
            field.target = self
            field.action = #selector(settingChanged(_:))
            field.alignment = .right
        }
        includeAudioButton.target = self
        includeAudioButton.action = #selector(settingChanged(_:))
        streamingButton.target = self
        streamingButton.action = #selector(settingChanged(_:))
    }

    private func card() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 11
        stack.edgeInsets = NSEdgeInsets(top: 15, left: 15, bottom: 15, right: 15)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor(hex: "222832").cgColor
        stack.layer?.cornerRadius = 9
        return stack
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = NSColor(hex: "9DA9BA")
        return label
    }

    private func field(_ title: String, _ control: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        return row
    }

    var selectedOptions: TimelineExportOptions {
        let resolutions = TimelineExportResolution.allCases
        let containers = TimelineExportContainer.allCases
        let codecs = TimelineExportCodec.allCases
        let rates: [Int32] = [24, 25, 30, 60]
        return TimelineExportOptions(
            resolution: resolutions[max(0, min(resolutions.count - 1, resolutionPopup.indexOfSelectedItem))],
            container: containers[max(0, min(containers.count - 1, containerPopup.indexOfSelectedItem))],
            codec: codecs[max(0, min(codecs.count - 1, codecPopup.indexOfSelectedItem))],
            customWidth: Int(customWidthField.integerValue),
            customHeight: Int(customHeightField.integerValue),
            frameRate: rates[max(0, min(rates.count - 1, frameRatePopup.indexOfSelectedItem))],
            includeAudio: includeAudioButton.state == .on,
            optimizeForStreaming: streamingButton.state == .on
        )
    }

    @objc private func settingChanged(_ sender: Any?) {
        applyResolutionCompatibility()
        updateSummary()
    }

    private func applyResolutionCompatibility() {
        let resolutions = TimelineExportResolution.allCases
        guard resolutions.indices.contains(resolutionPopup.indexOfSelectedItem) else { return }
        let is16K = resolutions[resolutionPopup.indexOfSelectedItem] == .ultraHD16K
        if is16K {
            containerPopup.selectItem(at: TimelineExportContainer.allCases.firstIndex(of: .mov) ?? 1)
            codecPopup.selectItem(at: TimelineExportCodec.allCases.firstIndex(of: .proRes422) ?? 0)
            streamingButton.state = .off
        }
        containerPopup.isEnabled = !is16K && !isExporting
        codecPopup.isEnabled = !is16K && !isExporting
        streamingButton.isEnabled = !is16K && !isExporting
    }

    private func updateSummary() {
        guard isViewLoaded else { return }
        applyResolutionCompatibility()
        let options = selectedOptions
        let custom = options.resolution == .custom
        customWidthRow.isHidden = !custom
        customHeightRow.isHidden = !custom
        let size = options.renderSize
        summaryLabel.stringValue = "\(Int(size.width)) × \(Int(size.height))\n\(options.frameRate) frames per second\n\(options.container.title) • \(options.codec.title)\n\(options.includeAudio ? "AAC stereo audio" : "Video only")"
        let is16K = size.width > 8_192 || size.height > 4_608
        let highResolution = size.width > 3840 || size.height > 2160
        let requestedCodec: TimelineExportCodec = options.codec == .automatic ? (is16K ? .proRes422 : (highResolution ? .hevc : .h264)) : options.codec
        let supported = NativeTimelineExportEngine.canExport(codec: requestedCodec, options: options)
        let hardware = NativeTimelineExportEngine.hasHardwareEncoder(for: requestedCodec)
        if is16K && supported {
            capabilityLabel.stringValue = "✓ 16K safety mode uses Apple ProRes 422 in a MOV container. Expect very large files and a slower render."
            capabilityLabel.textColor = .systemGreen
        } else if supported {
            capabilityLabel.stringValue = hardware ? "✓ Hardware encoding is available on this Mac." : "✓ Supported using the available system encoder. High resolutions may render slowly."
            capabilityLabel.textColor = .systemGreen
        } else {
            capabilityLabel.stringValue = "This exact codec and size are unavailable. Automatic fallback will choose a compatible encoder."
            capabilityLabel.textColor = .systemOrange
        }
    }

    @objc private func startExport() {
        requestExport()
    }

    /// Every export entry point comes through one complete settings window.
    /// Nothing important is hidden behind the confirmation, so users never
    /// need to cancel and start again after noticing the frame-rate control.
    func requestExport() {
        guard !isExporting else { return }
        let chooser = ExportSettingsChooserView(options: selectedOptions)
        let alert = NSAlert()
        alert.messageText = "Export movie"
        alert.informativeText = "Choose every delivery setting now. The next window only asks where to save the movie."
        alert.alertStyle = .informational
        alert.accessoryView = chooser
        alert.addButton(withTitle: "Continue to Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let options = chooser.options
        apply(options)
        updateSummary()
        onStartExport?(options)
    }

    private func apply(_ options: TimelineExportOptions) {
        resolutionPopup.selectItem(at: TimelineExportResolution.allCases.firstIndex(of: options.resolution) ?? 1)
        containerPopup.selectItem(at: TimelineExportContainer.allCases.firstIndex(of: options.container) ?? 0)
        codecPopup.selectItem(at: TimelineExportCodec.allCases.firstIndex(of: options.codec) ?? 0)
        let rates: [Int32] = [24, 25, 30, 60]
        frameRatePopup.selectItem(at: rates.firstIndex(of: options.frameRate) ?? 2)
        customWidthField.integerValue = options.customWidth
        customHeightField.integerValue = options.customHeight
        includeAudioButton.state = options.includeAudio ? .on : .off
        streamingButton.state = options.optimizeForStreaming ? .on : .off
        applyResolutionCompatibility()
    }

    func beginExport(options: TimelineExportOptions) {
        isExporting = true
        exportButton.isEnabled = false
        [resolutionPopup, containerPopup, codecPopup, frameRatePopup, customWidthField, customHeightField, includeAudioButton, streamingButton].forEach { $0.isEnabled = false }
        progressWindowController.show(options: options)
    }

    func update(progress: TimelineExportProgress) {
        progressWindowController.update(progress)
    }

    func finishExport(message: String, succeeded: Bool) {
        isExporting = false
        exportButton.isEnabled = true
        [resolutionPopup, containerPopup, codecPopup, frameRatePopup, customWidthField, customHeightField, includeAudioButton, streamingButton].forEach { $0.isEnabled = true }
        progressWindowController.finish(message: message, succeeded: succeeded)
        updateSummary()
    }
}

/// The single authoritative settings step shown before the save panel.
private final class ExportSettingsChooserView: NSView {
    private let resolutionPopup = NSPopUpButton()
    private let containerPopup = NSPopUpButton()
    private let codecPopup = NSPopUpButton()
    private let frameRatePopup = NSPopUpButton()
    private let widthField = NSTextField(string: "1920")
    private let heightField = NSTextField(string: "1080")
    private let includeAudioButton = NSButton(checkboxWithTitle: "Include timeline audio", target: nil, action: nil)
    private let streamingButton = NSButton(checkboxWithTitle: "Fast-start playback", target: nil, action: nil)
    private let summaryLabel = NSTextField(labelWithString: "")

    var options: TimelineExportOptions {
        let resolutions = TimelineExportResolution.allCases
        let containers = TimelineExportContainer.allCases
        let codecs = TimelineExportCodec.allCases
        let rates: [Int32] = [24, 25, 30, 60]
        return TimelineExportOptions(
            resolution: resolutions[max(0, min(resolutions.count - 1, resolutionPopup.indexOfSelectedItem))],
            container: containers[max(0, min(containers.count - 1, containerPopup.indexOfSelectedItem))],
            codec: codecs[max(0, min(codecs.count - 1, codecPopup.indexOfSelectedItem))],
            customWidth: min(15_360, max(64, Int(widthField.integerValue))),
            customHeight: min(8_640, max(64, Int(heightField.integerValue))),
            frameRate: rates[max(0, min(rates.count - 1, frameRatePopup.indexOfSelectedItem))],
            includeAudio: includeAudioButton.state == .on,
            optimizeForStreaming: streamingButton.state == .on
        )
    }

    init(options: TimelineExportOptions) {
        super.init(frame: NSRect(x: 0, y: 0, width: 430, height: 276))
        resolutionPopup.addItems(withTitles: TimelineExportResolution.allCases.map(\.title))
        containerPopup.addItems(withTitles: TimelineExportContainer.allCases.map(\.title))
        codecPopup.addItems(withTitles: TimelineExportCodec.allCases.map(\.title))
        frameRatePopup.addItems(withTitles: ["24 fps", "25 fps", "30 fps", "60 fps"])
        resolutionPopup.selectItem(at: TimelineExportResolution.allCases.firstIndex(of: options.resolution) ?? 1)
        containerPopup.selectItem(at: TimelineExportContainer.allCases.firstIndex(of: options.container) ?? 0)
        codecPopup.selectItem(at: TimelineExportCodec.allCases.firstIndex(of: options.codec) ?? 0)
        frameRatePopup.selectItem(at: [24, 25, 30, 60].firstIndex(of: options.frameRate) ?? 2)
        widthField.integerValue = options.customWidth
        heightField.integerValue = options.customHeight
        widthField.alignment = .right
        heightField.alignment = .right
        includeAudioButton.state = options.includeAudio ? .on : .off
        streamingButton.state = options.optimizeForStreaming ? .on : .off

        let widthFormatter = NumberFormatter()
        widthFormatter.numberStyle = .none
        widthFormatter.minimum = 64
        widthFormatter.maximum = 15_360
        widthField.formatter = widthFormatter
        let heightFormatter = widthFormatter.copy() as! NumberFormatter
        heightFormatter.maximum = 8_640
        heightField.formatter = heightFormatter

        for popup in [resolutionPopup, containerPopup, codecPopup, frameRatePopup] {
            popup.target = self
            popup.action = #selector(settingChanged(_:))
        }
        includeAudioButton.target = self
        includeAudioButton.action = #selector(settingChanged(_:))
        streamingButton.target = self
        streamingButton.action = #selector(settingChanged(_:))

        let form = NSGridView(views: [
            [label("Resolution"), resolutionPopup],
            [label("Custom width"), widthField],
            [label("Custom height"), heightField],
            [label("Frame rate"), frameRatePopup],
            [label("Format"), containerPopup],
            [label("Video codec"), codecPopup]
        ])
        form.rowSpacing = 8
        form.columnSpacing = 12
        form.translatesAutoresizingMaskIntoConstraints = false
        addSubview(form)
        includeAudioButton.translatesAutoresizingMaskIntoConstraints = false
        streamingButton.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(includeAudioButton)
        addSubview(streamingButton)
        addSubview(summaryLabel)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: leadingAnchor),
            form.trailingAnchor.constraint(equalTo: trailingAnchor),
            form.topAnchor.constraint(equalTo: topAnchor),
            resolutionPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 230),
            widthField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            heightField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            includeAudioButton.leadingAnchor.constraint(equalTo: form.leadingAnchor, constant: 116),
            includeAudioButton.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 9),
            streamingButton.leadingAnchor.constraint(equalTo: includeAudioButton.trailingAnchor, constant: 16),
            streamingButton.centerYAnchor.constraint(equalTo: includeAudioButton.centerYAnchor),
            summaryLabel.leadingAnchor.constraint(equalTo: includeAudioButton.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: includeAudioButton.bottomAnchor, constant: 9)
        ])
        settingChanged(nil)
    }

    required init?(coder: NSCoder) { nil }

    private func label(_ title: String) -> NSTextField {
        let value = NSTextField(labelWithString: title)
        value.alignment = .right
        return value
    }

    @objc private func settingChanged(_ sender: Any?) {
        let resolutions = TimelineExportResolution.allCases
        let selectedResolution = resolutions[max(0, min(resolutions.count - 1, resolutionPopup.indexOfSelectedItem))]
        let is16K = selectedResolution == .ultraHD16K
        if is16K {
            containerPopup.selectItem(at: TimelineExportContainer.allCases.firstIndex(of: .mov) ?? 1)
            codecPopup.selectItem(at: TimelineExportCodec.allCases.firstIndex(of: .proRes422) ?? 0)
            streamingButton.state = .off
        }
        containerPopup.isEnabled = !is16K
        codecPopup.isEnabled = !is16K
        streamingButton.isEnabled = !is16K
        let custom = selectedResolution == .custom
        widthField.isEnabled = custom
        heightField.isEnabled = custom
        if !custom {
            let dimensions = selectedResolution.dimensions
            widthField.integerValue = Int(dimensions.width)
            heightField.integerValue = Int(dimensions.height)
        }
        let selected = options
        let size = selected.renderSize
        summaryLabel.stringValue = "Output: \(Int(size.width)) × \(Int(size.height)) · \(selected.frameRate) fps · \(selected.container.title) · \(selected.codec.title)" + (is16K ? "\n16K safety mode uses ProRes for reliable rendering." : "")
    }
}

/// Modeless progress panel that stays visible regardless of the selected page.
private final class ExportProgressWindowController: NSWindowController {
    var onCancel: (() -> Void)?
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "Preparing timeline…")
    private let detailLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel Export", target: nil, action: nil)

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 190),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Exporting Movie"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(root)

        let title = NSTextField(labelWithString: "Rendering your finished movie")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        progressLabel.textColor = .secondaryLabelColor
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.addArrangedSubview(NSView())
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        actions.addArrangedSubview(cancelButton)
        [title, detailLabel, progressBar, progressLabel, actions].forEach(root.addArrangedSubview)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(options: TimelineExportOptions) {
        let size = options.renderSize
        detailLabel.stringValue = "\(Int(size.width)) × \(Int(size.height)) · \(options.frameRate) fps · \(options.container.title)"
        progressBar.doubleValue = 0
        progressLabel.stringValue = "Preparing timeline…"
        cancelButton.isEnabled = true
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(_ progress: TimelineExportProgress) {
        progressBar.doubleValue = progress.fractionCompleted
        progressLabel.stringValue = String(format: "%3d%%  •  %.1f of %.1f seconds", progress.percent, progress.renderedSeconds, progress.totalSeconds)
    }

    func finish(message: String, succeeded: Bool) {
        progressBar.doubleValue = succeeded ? 1 : progressBar.doubleValue
        progressLabel.stringValue = message
        window?.orderOut(nil)
    }

    @objc private func cancelPressed() {
        cancelButton.isEnabled = false
        progressLabel.stringValue = "Cancelling export…"
        onCancel?()
    }
}
