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
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "Ready to export")
    private let exportButton = NSButton(title: "Choose File and Export", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

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

        let progressCard = card()
        progressCard.addArrangedSubview(sectionTitle("RENDER PROGRESS"))
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressCard.addArrangedSubview(progressBar)
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        progressLabel.textColor = .secondaryLabelColor
        progressCard.addArrangedSubview(progressLabel)
        root.addArrangedSubview(progressCard)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.addArrangedSubview(NSView())
        cancelButton.target = self
        cancelButton.action = #selector(cancelExport)
        cancelButton.isHidden = true
        actions.addArrangedSubview(cancelButton)
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
            popup.action = #selector(settingChanged)
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
            field.action = #selector(settingChanged)
            field.alignment = .right
        }
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

    @objc private func settingChanged() { updateSummary() }

    private func updateSummary() {
        guard isViewLoaded else { return }
        let options = selectedOptions
        let custom = options.resolution == .custom
        customWidthRow.isHidden = !custom
        customHeightRow.isHidden = !custom
        let size = options.renderSize
        summaryLabel.stringValue = "\(Int(size.width)) × \(Int(size.height))\n\(options.frameRate) frames per second\n\(options.container.title) • \(options.codec.title)\n\(options.includeAudio ? "AAC stereo audio" : "Video only")"
        let highResolution = size.width > 3840 || size.height > 2160
        let requestedCodec: TimelineExportCodec = options.codec == .automatic ? (highResolution ? .hevc : .h264) : options.codec
        let supported = NativeTimelineExportEngine.canExport(codec: requestedCodec, options: options)
        let hardware = NativeTimelineExportEngine.hasHardwareEncoder(for: requestedCodec)
        if supported {
            capabilityLabel.stringValue = hardware ? "✓ Hardware encoding is available on this Mac." : "✓ Supported using the available system encoder. High resolutions may render slowly."
            capabilityLabel.textColor = .systemGreen
        } else {
            capabilityLabel.stringValue = "This exact codec and size are unavailable. Automatic fallback will choose a compatible encoder."
            capabilityLabel.textColor = .systemOrange
        }
    }

    @objc private func startExport() {
        guard !isExporting else { return }
        onStartExport?(selectedOptions)
    }

    @objc private func cancelExport() { onCancelExport?() }

    func beginExport() {
        isExporting = true
        exportButton.isEnabled = false
        [resolutionPopup, containerPopup, codecPopup, frameRatePopup, customWidthField, customHeightField, includeAudioButton, streamingButton].forEach { $0.isEnabled = false }
        cancelButton.isHidden = false
        progressBar.doubleValue = 0
        progressLabel.stringValue = "Preparing timeline…"
    }

    func update(progress: TimelineExportProgress) {
        progressBar.doubleValue = progress.fractionCompleted
        progressLabel.stringValue = String(format: "%3d%%  •  %.1f of %.1f seconds", progress.percent, progress.renderedSeconds, progress.totalSeconds)
    }

    func finishExport(message: String, succeeded: Bool) {
        isExporting = false
        exportButton.isEnabled = true
        [resolutionPopup, containerPopup, codecPopup, frameRatePopup, customWidthField, customHeightField, includeAudioButton, streamingButton].forEach { $0.isEnabled = true }
        cancelButton.isHidden = true
        progressLabel.stringValue = message
        progressLabel.textColor = succeeded ? .systemGreen : .systemOrange
        if succeeded { progressBar.doubleValue = 1 }
        updateSummary()
    }
}
