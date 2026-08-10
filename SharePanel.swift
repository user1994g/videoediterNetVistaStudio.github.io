import Cocoa
import CoreImage

/// Native, modeless companion UI for `LocalShareServer`.
///
/// The server remains the source of truth for address, pairing expiry, and
/// trusted-device state. This controller only presents that state and sends
/// explicit user actions back to the server.
final class SharePanelViewController: NSViewController {
    var onStatus: ((String) -> Void)?

    private let server: LocalShareServer
    private var state = LocalShareServerState()
    private var countdownTimer: Timer?
    private var renderedQRURL: URL?
    private var lastReportedStatus: String?

    private let phaseDot = NSView(frame: .zero)
    private let phaseLabel = NSTextField(labelWithString: "Not sharing")
    private let statusDetailLabel = NSTextField(wrappingLabelWithString: "Press New Code to start sharing on your local network.")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    private let addressField = NSTextField(labelWithString: "Waiting for a local address…")
    private let alternateAddressField = NSTextField(labelWithString: "")
    private let qrImageView = NSImageView(frame: .zero)
    private let qrPlaceholder = NSTextField(labelWithString: "QR")

    private let codeLabel = NSTextField(labelWithString: "— — —")
    private let countdownLabel = NSTextField(labelWithString: "No active code")
    private let pairingHelpLabel = NSTextField(wrappingLabelWithString: "Create a temporary code for a new device.")
    private let pairedCountLabel = NSTextField(labelWithString: "0 paired devices")

    private let copyButton = NSButton(title: "Copy Address", target: nil, action: nil)
    private let openButton = NSButton(title: "Open on This Mac", target: nil, action: nil)
    private let newCodeButton = NSButton(title: "New Code", target: nil, action: nil)
    private let forgetButton = NSButton(title: "Forget Paired Devices", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop Sharing", target: nil, action: nil)

    init(server: LocalShareServer) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SharePanelViewController is created in code.")
    }

    deinit {
        countdownTimer?.invalidate()
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 690))
        view.wantsLayer = true
        view.layer?.backgroundColor = Palette.window.cgColor
        buildInterface()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installServerObserver()
        installCountdownTimer()
    }

    /// Called by the main Share button. Every invocation rotates the temporary
    /// challenge while preserving devices the user has already paired.
    func beginNewPairing() {
        server.startWithNewCode()
        reportStatus("Starting local sharing and creating a new pairing code…")
    }

    func refresh() {
        apply(server.currentState())
    }

    private func buildInterface() {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 580),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 520)
        ])

        root.addArrangedSubview(makeHeader())
        root.addArrangedSubview(makeDivider())

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 22, right: 22)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(makeErrorCard())
        content.addArrangedSubview(makeConnectionCard())
        content.addArrangedSubview(makePairingCard())
        content.addArrangedSubview(makeTrustCard())

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        root.addArrangedSubview(scroll)
        root.addArrangedSubview(makeDivider())
        root.addArrangedSubview(makeFooter())
    }

    private func makeHeader() -> NSView {
        let icon = NSImageView(frame: .zero)
        icon.image = NSImage(systemSymbolName: "rectangle.connected.to.line.below", accessibilityDescription: "Local sharing")
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: "Local sharing")
        icon.contentTintColor = Palette.accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34)
        ])

        let title = NSTextField(labelWithString: "Share on Your Local Network")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = .white
        let subtitle = NSTextField(labelWithString: "Open this NetVista Studio project on an iPad, phone, or another computer.")
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = Palette.secondaryText
        subtitle.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        phaseDot.wantsLayer = true
        phaseDot.layer?.cornerRadius = 4
        phaseDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            phaseDot.widthAnchor.constraint(equalToConstant: 8),
            phaseDot.heightAnchor.constraint(equalToConstant: 8)
        ])
        phaseLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        phaseLabel.textColor = .white
        let phasePill = NSStackView(views: [phaseDot, phaseLabel])
        phasePill.orientation = .horizontal
        phasePill.alignment = .centerY
        phasePill.spacing = 7
        phasePill.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        phasePill.wantsLayer = true
        phasePill.layer?.cornerRadius = 13
        phasePill.layer?.backgroundColor = Palette.pill.cgColor

        let header = NSStackView(views: [icon, labels, flexibleSpacer(), phasePill])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 11
        header.edgeInsets = NSEdgeInsets(top: 15, left: 22, bottom: 15, right: 22)
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        return header
    }

    private func makeErrorCard() -> NSView {
        errorLabel.font = .systemFont(ofSize: 12, weight: .medium)
        errorLabel.textColor = Palette.errorText
        errorLabel.maximumNumberOfLines = 3
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: "Sharing error") ?? NSImage())
        icon.contentTintColor = Palette.error
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let row = NSStackView(views: [icon, errorLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        let card = styledCard(row, background: Palette.errorBackground, border: Palette.errorBorder)
        card.isHidden = true
        card.identifier = NSUserInterfaceItemIdentifier("share-error-card")
        return card
    }

    private func makeConnectionCard() -> NSView {
        let eyebrow = sectionLabel("ADDRESS")
        let heading = NSTextField(labelWithString: "Open this address on your other device")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = .white

        addressField.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        addressField.textColor = Palette.address
        addressField.isSelectable = true
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.toolTip = "The local address to open on another device"
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        alternateAddressField.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        alternateAddressField.textColor = Palette.secondaryText
        alternateAddressField.isSelectable = true
        alternateAddressField.lineBreakMode = .byTruncatingMiddle
        alternateAddressField.isHidden = true

        configureButton(copyButton, action: #selector(copyAddress), tint: .systemBlue)
        configureButton(openButton, action: #selector(openLocally), tint: Palette.accent)
        let buttons = NSStackView(views: [copyButton, openButton, flexibleSpacer()])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        statusDetailLabel.font = .systemFont(ofSize: 11)
        statusDetailLabel.textColor = Palette.secondaryText
        statusDetailLabel.maximumNumberOfLines = 2

        let details = NSStackView(views: [eyebrow, heading, addressField, alternateAddressField, buttons, statusDetailLabel])
        details.orientation = .vertical
        details.alignment = .width
        details.spacing = 7
        details.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let qrSurface = NSView(frame: .zero)
        qrSurface.wantsLayer = true
        qrSurface.layer?.backgroundColor = NSColor.white.cgColor
        qrSurface.layer?.cornerRadius = 13
        qrSurface.layer?.cornerCurve = .continuous
        qrSurface.translatesAutoresizingMaskIntoConstraints = false
        qrSurface.widthAnchor.constraint(equalToConstant: 164).isActive = true
        qrSurface.heightAnchor.constraint(equalToConstant: 164).isActive = true

        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        qrImageView.wantsLayer = true
        qrImageView.layer?.magnificationFilter = .nearest
        qrImageView.toolTip = "Scan to open the shown address"
        qrSurface.addSubview(qrImageView)

        qrPlaceholder.font = .systemFont(ofSize: 18, weight: .bold)
        qrPlaceholder.textColor = NSColor(calibratedWhite: 0.68, alpha: 1)
        qrPlaceholder.alignment = .center
        qrPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        qrSurface.addSubview(qrPlaceholder)
        NSLayoutConstraint.activate([
            qrImageView.leadingAnchor.constraint(equalTo: qrSurface.leadingAnchor, constant: 10),
            qrImageView.trailingAnchor.constraint(equalTo: qrSurface.trailingAnchor, constant: -10),
            qrImageView.topAnchor.constraint(equalTo: qrSurface.topAnchor, constant: 10),
            qrImageView.bottomAnchor.constraint(equalTo: qrSurface.bottomAnchor, constant: -10),
            qrPlaceholder.centerXAnchor.constraint(equalTo: qrSurface.centerXAnchor),
            qrPlaceholder.centerYAnchor.constraint(equalTo: qrSurface.centerYAnchor)
        ])

        let row = NSStackView(views: [details, qrSurface])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        return styledCard(row)
    }

    private func makePairingCard() -> NSView {
        let heading = sectionLabel("PAIR A NEW DEVICE")
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 39, weight: .bold)
        codeLabel.textColor = .white
        codeLabel.isSelectable = true
        codeLabel.alignment = .center
        codeLabel.setAccessibilityLabel("Six-digit pairing code")
        codeLabel.wantsLayer = true
        codeLabel.layer?.backgroundColor = Palette.codeBackground.cgColor
        codeLabel.layer?.cornerRadius = 12
        codeLabel.layer?.cornerCurve = .continuous
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.heightAnchor.constraint(equalToConstant: 72).isActive = true

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        countdownLabel.textColor = Palette.secondaryText
        countdownLabel.alignment = .center
        pairingHelpLabel.font = .systemFont(ofSize: 11)
        pairingHelpLabel.textColor = Palette.secondaryText
        pairingHelpLabel.alignment = .center
        pairingHelpLabel.maximumNumberOfLines = 2

        let deviceIcon = NSImageView(image: NSImage(systemSymbolName: "ipad.and.iphone", accessibilityDescription: "Paired devices") ?? NSImage())
        deviceIcon.contentTintColor = Palette.accent
        deviceIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        pairedCountLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        pairedCountLabel.textColor = .white
        let pairedRow = NSStackView(views: [deviceIcon, pairedCountLabel])
        pairedRow.orientation = .horizontal
        pairedRow.alignment = .centerY
        pairedRow.spacing = 7
        pairedRow.distribution = .gravityAreas

        let stack = NSStackView(views: [heading, codeLabel, countdownLabel, pairingHelpLabel, pairedRow])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        return styledCard(stack)
    }

    private func makeTrustCard() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Trusted network warning") ?? NSImage())
        icon.contentTintColor = Palette.warning
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 23).isActive = true

        let title = NSTextField(labelWithString: "Use trusted private Wi-Fi only")
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = Palette.warningText
        let body = NSTextField(wrappingLabelWithString: "Anyone on this network can reach the pairing page. Share the temporary code only with a device you trust, and keep this Mac awake while sharing.")
        body.font = .systemFont(ofSize: 11)
        body.textColor = Palette.warningText.withAlphaComponent(0.82)
        body.maximumNumberOfLines = 3
        let labels = NSStackView(views: [title, body])
        labels.orientation = .vertical
        labels.alignment = .width
        labels.spacing = 3

        let row = NSStackView(views: [icon, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return styledCard(row, background: Palette.warningBackground, border: Palette.warningBorder)
    }

    private func makeFooter() -> NSView {
        configureButton(newCodeButton, action: #selector(createNewCode), tint: .systemBlue)
        configureButton(forgetButton, action: #selector(confirmForgetDevices), tint: Palette.secondaryText)
        configureButton(stopButton, action: #selector(stopSharing), tint: .systemRed)

        let footer = NSStackView(views: [newCodeButton, forgetButton, flexibleSpacer(), stopButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 9
        footer.edgeInsets = NSEdgeInsets(top: 12, left: 22, bottom: 12, right: 22)
        footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        return footer
    }

    private func installServerObserver() {
        server.onStateChange = { [weak self] state in
            guard let self else { return }
            if Thread.isMainThread { self.apply(state) }
            else { DispatchQueue.main.async { [weak self] in self?.apply(state) } }
        }
    }

    private func installCountdownTimer() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateCountdown()
        }
        countdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func apply(_ newState: LocalShareServerState) {
        precondition(Thread.isMainThread)
        let previous = state
        state = newState

        switch newState.phase {
        case .stopped:
            setPhase(title: "Not sharing", color: Palette.inactive)
            statusDetailLabel.stringValue = "Sharing is stopped. Create a new code when you are ready."
        case .starting:
            setPhase(title: "Starting…", color: Palette.warning)
            statusDetailLabel.stringValue = "Requesting local-network access and preparing the address…"
        case .ready:
            setPhase(title: "Sharing", color: Palette.success)
            statusDetailLabel.stringValue = "Keep NetVista Studio open while the other device is connected."
        case .failed:
            setPhase(title: "Couldn’t start", color: Palette.error)
            statusDetailLabel.stringValue = "Check local-network access and try creating a new code."
        }

        addressField.stringValue = newState.primaryURL?.absoluteString ?? "Waiting for a local address…"
        addressField.textColor = newState.primaryURL == nil ? Palette.secondaryText : Palette.address
        if let alternate = newState.alternateURL, alternate != newState.primaryURL {
            alternateAddressField.stringValue = "Alternate: \(alternate.absoluteString)"
            alternateAddressField.isHidden = false
        } else {
            alternateAddressField.stringValue = ""
            alternateAddressField.isHidden = true
        }

        copyButton.isEnabled = newState.primaryURL != nil && newState.phase == .ready
        openButton.isEnabled = copyButton.isEnabled
        stopButton.isEnabled = newState.isRunning
        forgetButton.isEnabled = newState.pairedDeviceCount > 0
        pairedCountLabel.stringValue = "\(newState.pairedDeviceCount) paired device\(newState.pairedDeviceCount == 1 ? "" : "s")"

        if let code = newState.pairingCode, code.count == 6 {
            let midpoint = code.index(code.startIndex, offsetBy: 3)
            codeLabel.stringValue = "\(code[..<midpoint]) \(code[midpoint...])"
            codeLabel.textColor = .white
            pairingHelpLabel.stringValue = "Enter this code on a new device. It works once and expires automatically."
        } else {
            codeLabel.stringValue = "— — —"
            codeLabel.textColor = Palette.inactive
            pairingHelpLabel.stringValue = newState.pairedDeviceCount > 0
                ? "Trusted devices can reconnect without another code."
                : "Select New Code to pair a device."
        }

        updateQR(for: newState.primaryURL)
        updateError(newState.errorMessage)
        updateCountdown()
        reportMeaningfulStateChange(from: previous, to: newState)
    }

    private func updateCountdown() {
        guard let expiry = state.pairingExpiresAt, state.pairingCode != nil else {
            countdownLabel.stringValue = "No active code"
            countdownLabel.textColor = Palette.secondaryText
            return
        }

        let remaining = max(0, Int(ceil(expiry.timeIntervalSinceNow)))
        let minutes = remaining / 60
        let seconds = remaining % 60
        countdownLabel.stringValue = remaining > 0
            ? String(format: "Expires in %02d:%02d", minutes, seconds)
            : "Code expired — create a new one"
        countdownLabel.textColor = remaining <= 15 ? Palette.error : (remaining <= 45 ? Palette.warning : Palette.accent)

        if remaining == 0 {
            let current = server.currentState()
            if current != state { apply(current) }
        }
    }

    private func setPhase(title: String, color: NSColor) {
        phaseLabel.stringValue = title
        phaseDot.layer?.backgroundColor = color.cgColor
    }

    private func updateError(_ message: String?) {
        guard let card = view.subviewsRecursive.first(where: { $0.identifier?.rawValue == "share-error-card" }) else { return }
        let clean = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        errorLabel.stringValue = clean
        card.isHidden = clean.isEmpty
    }

    private func updateQR(for url: URL?) {
        guard renderedQRURL != url else { return }
        renderedQRURL = url
        qrImageView.image = url.flatMap(Self.qrImage)
        qrPlaceholder.isHidden = qrImageView.image != nil
    }

    private static func qrImage(for url: URL) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        // Integer scaling keeps module edges sharp. The surrounding AppKit
        // surface provides the quiet white margin; only the URL is encoded.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 9, y: 9))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
        image.isTemplate = false
        return image
    }

    private func reportMeaningfulStateChange(from old: LocalShareServerState, to new: LocalShareServerState) {
        let message: String
        if new.pairedDeviceCount > old.pairedDeviceCount {
            message = "A device paired with NetVista Studio."
        } else if let error = new.errorMessage, error != old.errorMessage {
            message = error
        } else if new.phase != old.phase {
            switch new.phase {
            case .stopped: message = "Local sharing stopped."
            case .starting: message = "Starting local sharing…"
            case .ready: message = new.primaryURL.map { "Local sharing is ready at \($0.absoluteString)" } ?? "Local sharing is ready."
            case .failed: message = "Local sharing could not start."
            }
        } else {
            return
        }
        reportStatus(message)
    }

    private func reportStatus(_ message: String) {
        guard message != lastReportedStatus else { return }
        lastReportedStatus = message
        onStatus?(message)
    }

    @objc private func copyAddress() {
        guard let url = state.primaryURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        reportStatus("Copied the local sharing address.")
    }

    @objc private func openLocally() {
        guard let url = state.primaryURL else { return }
        if NSWorkspace.shared.open(url) { reportStatus("Opened the local sharing page on this Mac.") }
        else { reportStatus("The local sharing address could not be opened.") }
    }

    @objc private func createNewCode() {
        server.issueNewCode()
        reportStatus("Creating a fresh six-digit pairing code…")
    }

    @objc private func confirmForgetDevices() {
        guard state.pairedDeviceCount > 0 else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Forget all paired devices?"
        alert.informativeText = "Every device will need a new six-digit code before it can open shared projects again."
        alert.addButton(withTitle: "Forget Devices")
        alert.addButton(withTitle: "Cancel")

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.server.forgetAllDevices()
            self?.reportStatus("Forgot all paired devices.")
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    @objc private func stopSharing() {
        server.stop()
        reportStatus("Stopping local sharing…")
    }

    private func configureButton(_ button: NSButton, action: Selector, tint: NSColor) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = tint
    }

    private func sectionLabel(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = Palette.accent
        return label
    }

    private func styledCard(_ content: NSView, background: NSColor = Palette.card, border: NSColor = Palette.border) -> NSView {
        let card = NSView(frame: .zero)
        card.wantsLayer = true
        card.layer?.backgroundColor = background.cgColor
        card.layer?.borderColor = border.cgColor
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -15)
        ])
        return card
    }

    private func makeDivider() -> NSView {
        let line = NSView(frame: .zero)
        line.wantsLayer = true
        line.layer?.backgroundColor = Palette.border.cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView(frame: .zero)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private enum Palette {
        static let window = NSColor(calibratedRed: 0.065, green: 0.078, blue: 0.102, alpha: 1)
        static let card = NSColor(calibratedRed: 0.105, green: 0.125, blue: 0.16, alpha: 1)
        static let pill = NSColor(calibratedRed: 0.14, green: 0.165, blue: 0.21, alpha: 1)
        static let codeBackground = NSColor(calibratedRed: 0.045, green: 0.055, blue: 0.075, alpha: 1)
        static let border = NSColor(calibratedRed: 0.205, green: 0.235, blue: 0.29, alpha: 1)
        static let secondaryText = NSColor(calibratedRed: 0.62, green: 0.67, blue: 0.74, alpha: 1)
        static let accent = NSColor(calibratedRed: 0.27, green: 0.84, blue: 0.76, alpha: 1)
        static let address = NSColor(calibratedRed: 0.39, green: 0.65, blue: 1, alpha: 1)
        static let success = NSColor(calibratedRed: 0.25, green: 0.82, blue: 0.57, alpha: 1)
        static let inactive = NSColor(calibratedRed: 0.43, green: 0.47, blue: 0.54, alpha: 1)
        static let warning = NSColor(calibratedRed: 1, green: 0.69, blue: 0.24, alpha: 1)
        static let warningText = NSColor(calibratedRed: 1, green: 0.82, blue: 0.54, alpha: 1)
        static let warningBackground = NSColor(calibratedRed: 0.20, green: 0.15, blue: 0.075, alpha: 1)
        static let warningBorder = NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.11, alpha: 1)
        static let error = NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.38, alpha: 1)
        static let errorText = NSColor(calibratedRed: 1, green: 0.74, blue: 0.75, alpha: 1)
        static let errorBackground = NSColor(calibratedRed: 0.22, green: 0.095, blue: 0.105, alpha: 1)
        static let errorBorder = NSColor(calibratedRed: 0.48, green: 0.18, blue: 0.20, alpha: 1)
    }
}

private extension NSView {
    var subviewsRecursive: [NSView] {
        subviews + subviews.flatMap(\.subviewsRecursive)
    }
}
