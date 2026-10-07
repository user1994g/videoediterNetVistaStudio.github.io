import UIKit
@preconcurrency import AVKit
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class EditorViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate {
    private let panel = UIColor(white: 0.12, alpha: 1)
    private let accent = UIColor(red: 1, green: 0.28, blue: 0.33, alpha: 1)
    private let history = MobileHistory()
    private let account = StudioAccount(store: MobileSessionStore(), transport: MobileAccount.transport)
    private var project = MobileProject()
    private var selected: Int?
    private var pickerMode = "video"
    private var previewTask: Task<Void, Never>?
    private var exportSession: AVAssetExportSession?
    private var progressTimer: Timer?
    private var exporting = false
    private var exportGeneration = 0
    private var importing = false
    private var pendingTemporary: URL?
    private var observer: Any?
    private let player = AVPlayer()
    private let playerController = AVPlayerViewController()
    private let clips = UITableView(frame: .zero, style: .plain)
    private let titleField = UITextField()
    private let status = UILabel()
    private let timeLabel = UILabel()
    private let seek = UISlider()
    private let start = UISlider()
    private let end = UISlider()
    private let startLabel = UILabel()
    private let endLabel = UILabel()
    private let clipLabel = UILabel()
    private let accountOverlay = UIView()
    private let accountStatus = UILabel()
    private let body = UIStackView()
    private let trimPanel = UIStackView()
    private var exportAlert: UIAlertController?
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var media: URL { documents.appendingPathComponent("Media", isDirectory: true) }
    private var autosave: URL { documents.appendingPathComponent("WorkingProject.json") }
    private var canEdit: Bool { account.lastVerified != nil && account.session != nil && !exporting && !importing }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.075, alpha: 1)
        overrideUserInterfaceStyle = .dark
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        if let saved = try? MobileProject.read(autosave) { project = saved }
        buildUI()
        playerController.player = player; playerController.showsPlaybackControls = false
        playerController.videoGravity = .resizeAspect
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 15), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if !self.seek.isTracking { self.seek.value = Float(time.seconds.isFinite ? time.seconds : 0) }
                self.timeLabel.text = "\(self.clock(time.seconds)) / \(self.clock(self.project.totalDuration))"
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(willBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        account.onChange = { [weak self] in self?.refreshAccount() }
        account.onInvalidated = { [weak self] in self?.player.pause() }
        account.start()
        refresh(); rebuildPreview()
    }

    private func label(_ text: String, size: CGFloat = 14, weight: UIFont.Weight = .regular) -> UILabel {
        let value = UILabel(); value.text = text; value.font = .systemFont(ofSize: size, weight: weight)
        value.textColor = .label; value.numberOfLines = 0; return value
    }
    private func button(_ name: String, image: String? = nil, action: Selector, primary: Bool = false) -> UIButton {
        let value = UIButton(type: .system)
        var config = primary ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        config.title = name; config.image = image.flatMap { UIImage(systemName: $0) }
        config.imagePadding = 7; config.baseBackgroundColor = primary ? accent : .darkGray
        config.baseForegroundColor = .white; config.cornerStyle = .medium
        value.configuration = config; value.addTarget(self, action: action, for: .touchUpInside)
        value.accessibilityLabel = name; return value
    }
    private func stack(_ axis: NSLayoutConstraint.Axis, _ views: [UIView], spacing: CGFloat = 12) -> UIStackView {
        let value = UIStackView(arrangedSubviews: views); value.axis = axis; value.spacing = spacing; return value
    }
    private func buildUI() {
        let logo = UIImageView(image: UIImage(named: "NetVistaStudio.png")); logo.contentMode = .scaleAspectFit
        logo.widthAnchor.constraint(equalToConstant: 36).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let brand = stack(.horizontal, [logo, label("NetVista Studio", size: 19, weight: .bold), label("IPAD BETA", size: 10, weight: .bold)])
        let header = stack(.horizontal, [brand, UIView(), button("Account", image: "person.crop.circle", action: #selector(accountAction))])
        titleField.textColor = .white; titleField.font = .systemFont(ofSize: 23, weight: .semibold)
        titleField.placeholder = "Movie name"; titleField.accessibilityLabel = "Project name"
        titleField.addTarget(self, action: #selector(nameChanged), for: .editingDidEnd)
        let heading = stack(.horizontal, [titleField, button("Export", image: "square.and.arrow.up", action: #selector(exportAction), primary: true)])
        let toolbar = stack(.horizontal, [
            button("New", image: "doc.badge.plus", action: #selector(newProject)),
            button("Import", image: "plus", action: #selector(importVideos)),
            button("Open", image: "folder", action: #selector(openProject)),
            button("Save", image: "square.and.arrow.down", action: #selector(saveProject)),
            UIView(), button("Undo", action: #selector(undoAction)), button("Redo", action: #selector(redoAction))])
        let toolbarScroll = UIScrollView(); toolbarScroll.showsHorizontalScrollIndicator = false
        toolbarScroll.addSubview(toolbar); toolbar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.topAnchor),
            toolbar.bottomAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.bottomAnchor),
            toolbar.heightAnchor.constraint(equalTo: toolbarScroll.frameLayoutGuide.heightAnchor),
            toolbar.widthAnchor.constraint(greaterThanOrEqualTo: toolbarScroll.frameLayoutGuide.widthAnchor),
            toolbarScroll.heightAnchor.constraint(equalToConstant: 44)])
        addChild(playerController)
        let monitor = UIView(); monitor.backgroundColor = .black; monitor.layer.cornerRadius = 8; monitor.clipsToBounds = true
        monitor.addSubview(playerController.view); playerController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerController.view.leadingAnchor.constraint(equalTo: monitor.leadingAnchor),
            playerController.view.trailingAnchor.constraint(equalTo: monitor.trailingAnchor),
            playerController.view.topAnchor.constraint(equalTo: monitor.topAnchor),
            playerController.view.bottomAnchor.constraint(equalTo: monitor.bottomAnchor)])
        playerController.didMove(toParent: self)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .secondaryLabel; timeLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        seek.accessibilityLabel = "Timeline playhead"; seek.tintColor = accent
        seek.addTarget(self, action: #selector(scrub), for: .valueChanged)
        let transport = stack(.horizontal, [button("Play / Pause", image: "playpause.fill", action: #selector(playPause)), seek, timeLabel])
        let playback = stack(.vertical, [label("PROGRAM MONITOR", size: 10, weight: .bold), monitor, transport])
        let monitorMin = monitor.heightAnchor.constraint(greaterThanOrEqualToConstant: 150); monitorMin.priority = .defaultHigh; monitorMin.isActive = true
        let timelineTitle = stack(.horizontal, [label("SEQUENCE", size: 11, weight: .bold), UIView(), label("Drag handles to reorder", size: 11)])
        clips.backgroundColor = panel; clips.separatorColor = UIColor(white: 0.25, alpha: 1)
        clips.layer.cornerRadius = 8; clips.dataSource = self; clips.delegate = self
        clips.setEditing(true, animated: false); clips.allowsSelectionDuringEditing = true
        clips.rowHeight = 62; clips.accessibilityLabel = "Video clips in sequence"
        let timeline = stack(.vertical, [timelineTitle, clips])
        timeline.heightAnchor.constraint(equalToConstant: 210).isActive = true
        let left = stack(.vertical, [playback, timeline])
        trimPanel.axis = .vertical; trimPanel.spacing = 14
        trimPanel.backgroundColor = panel; trimPanel.layer.cornerRadius = 8
        trimPanel.isLayoutMarginsRelativeArrangement = true
        trimPanel.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        clipLabel.font = .systemFont(ofSize: 17, weight: .semibold); clipLabel.numberOfLines = 2
        startLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        endLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        start.tintColor = accent; end.tintColor = accent
        start.accessibilityLabel = "Clip start seconds"; end.accessibilityLabel = "Clip end seconds"
        for slider in [start, end] {
            slider.addTarget(self, action: #selector(trimPreview(_:)), for: .valueChanged)
            slider.addTarget(self, action: #selector(commitTrim(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        [label("CLIP PROPERTIES", size: 10, weight: .bold), clipLabel, startLabel, start, endLabel, end,
         button("Set trim…", image: "scissors", action: #selector(numericTrim)),
         stack(.horizontal, [button("Earlier", image: "arrow.up", action: #selector(moveEarlier)), button("Later", image: "arrow.down", action: #selector(moveLater))]),
         button("Duplicate", image: "plus.square.on.square", action: #selector(duplicateClip)),
         button("Remove clip", image: "trash", action: #selector(removeClip)),
         label("Standalone mobile beta\nImport → arrange → trim → export. Desktop effects, 3D and game tools are not included in this first mobile edition.", size: 11), UIView()].forEach { trimPanel.addArrangedSubview($0) }
        trimPanel.widthAnchor.constraint(equalToConstant: 250).isActive = true
        body.axis = .horizontal; body.spacing = 16; body.addArrangedSubview(left); body.addArrangedSubview(trimPanel)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabel; status.numberOfLines = 2
        status.text = "Import videos from Files to start a movie."
        let root = stack(.vertical, [header, heading, toolbarScroll, body, status], spacing: 16)
        root.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            root.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20)])
        accountOverlay.backgroundColor = UIColor(white: 0.07, alpha: 0.98)
        accountOverlay.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(accountOverlay)
        NSLayoutConstraint.activate([
            accountOverlay.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            accountOverlay.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            accountOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            accountOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        accountStatus.numberOfLines = 4; accountStatus.textColor = .secondaryLabel; accountStatus.textAlignment = .center
        let welcome = stack(.vertical, [label("Your studio. Anywhere.", size: 28, weight: .bold),
            label("Sign in with the same NetVista account as the website.\nYour media and projects stay on this iPad.", size: 16),
            accountStatus, button("Sign in", image: "person.crop.circle", action: #selector(signIn), primary: true),
            button("Create account / Reset password", action: #selector(openAccountWebsite))], spacing: 20)
        welcome.translatesAutoresizingMaskIntoConstraints = false; accountOverlay.addSubview(welcome)
        NSLayoutConstraint.activate([welcome.centerXAnchor.constraint(equalTo: accountOverlay.centerXAnchor),
            welcome.centerYAnchor.constraint(equalTo: accountOverlay.centerYAnchor),
            welcome.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            welcome.leadingAnchor.constraint(greaterThanOrEqualTo: accountOverlay.leadingAnchor, constant: 30),
            welcome.trailingAnchor.constraint(lessThanOrEqualTo: accountOverlay.trailingAnchor, constant: -30)])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Compact split-screen keeps the canvas and sequence usable without clipped properties.
        trimPanel.isHidden = view.bounds.width < 800
    }
    private func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0)); return String(format: "%02d:%02d", value / 60, value % 60)
    }
    private func message(_ text: String) { status.text = text }
    private func error(_ error: Error) { message(error.localizedDescription); alert("Could not complete", error.localizedDescription) }
    private func alert(_ title: String, _ text: String) {
        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
    private func saveWorking() { do { try project.write(autosave) } catch { message("Autosave failed: \(error.localizedDescription)") } }
    private func change(_ mutation: (inout MobileProject) -> Void) {
        history.record(project); mutation(&project); saveWorking(); refresh(); rebuildPreview()
    }
    private func refresh() {
        titleField.text = project.name; clips.reloadData()
        if let selected, !project.clips.indices.contains(selected) { self.selected = nil }
        let clip = selected.flatMap { project.clips.indices.contains($0) ? project.clips[$0] : nil }
        clipLabel.text = clip?.name ?? "Select a clip"
        for slider in [start, end] { slider.isEnabled = clip != nil; slider.minimumValue = 0; slider.maximumValue = Float(clip?.duration ?? 1) }
        start.value = Float(clip?.inPoint ?? 0); end.value = Float(clip?.outPoint ?? 1)
        updateTrimLabels(); seek.maximumValue = Float(max(0.01, project.totalDuration))
        if let selected { clips.selectRow(at: IndexPath(row: selected, section: 0), animated: false, scrollPosition: .none) }
    }
    private func rebuildPreview() {
        previewTask?.cancel(); player.pause()
        guard !project.clips.isEmpty else { player.replaceCurrentItem(with: nil); return }
        let snapshot = project; let at = min(player.currentTime().seconds, snapshot.totalDuration)
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sequence = try await MobileVideoEngine.sequence(snapshot, media: self.media, height: 720)
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: sequence.composition); item.videoComposition = sequence.videoComposition
                self.player.replaceCurrentItem(with: item)
                await self.player.seek(to: CMTime(seconds: max(0, at.isFinite ? at : 0), preferredTimescale: 600))
                self.message("\(snapshot.clips.count) clips · \(self.clock(snapshot.totalDuration)) · Changes autosaved on this iPad.")
            } catch { if !Task.isCancelled { self.error(error) } }
        }
    }
    private func updateTrimLabels() {
        startLabel.text = String(format: "IN    %.2f s", start.value)
        endLabel.text = String(format: "OUT   %.2f s", end.value)
    }
    @objc private func trimPreview(_ slider: UISlider) {
        if start.value >= end.value - 0.04 {
            if slider === start { start.value = max(0, end.value - 0.04) }
            else { end.value = min(end.maximumValue, start.value + 0.04) }
        }
        updateTrimLabels()
    }
    @objc private func commitTrim(_ slider: UISlider) {
        guard canEdit, let selected else { refresh(); return }
        do {
            var next = project; try next.trim(selected, start: Double(start.value), end: Double(end.value))
            history.record(project); project = next; saveWorking(); refresh(); rebuildPreview()
        } catch { self.error(error); refresh() }
    }
    @objc private func numericTrim() {
        guard canEdit, let selected else { return }
        let clip = project.clips[selected]
        let value = UIAlertController(title: "Trim \(clip.name)", message: "Start and end in source seconds (0 – \(String(format: "%.2f", clip.duration))).", preferredStyle: .alert)
        value.addTextField { $0.text = String(format: "%.2f", clip.inPoint); $0.keyboardType = .decimalPad; $0.placeholder = "Start seconds" }
        value.addTextField { $0.text = String(format: "%.2f", clip.outPoint); $0.keyboardType = .decimalPad; $0.placeholder = "End seconds" }
        value.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        value.addAction(UIAlertAction(title: "Apply", style: .default) { [weak self] _ in
            guard let self, let a = Double(value.textFields?[0].text ?? ""), let b = Double(value.textFields?[1].text ?? "") else { return }
            do { var next = self.project; try next.trim(selected, start: a, end: b)
                self.history.record(self.project); self.project = next; self.saveWorking(); self.refresh(); self.rebuildPreview()
            } catch { self.error(error) }
        }); present(value, animated: true)
    }
    @objc private func nameChanged() {
        let name = titleField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { titleField.text = project.name; return }
        change { $0.name = String(name.prefix(150)) }
    }
    @objc private func playPause() {
        guard canEdit, player.currentItem != nil else { return }
        if player.rate > 0 { player.pause() }
        else { if player.currentTime().seconds >= project.totalDuration - 0.04 { player.seek(to: .zero) }; player.play() }
    }
    @objc private func scrub() { player.pause(); player.seek(to: CMTime(seconds: Double(seek.value), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    @objc private func undoAction() { guard canEdit, let previous = history.undo(project) else { return }; project = previous; saveWorking(); refresh(); rebuildPreview() }
    @objc private func redoAction() { guard canEdit, let next = history.redo(project) else { return }; project = next; saveWorking(); refresh(); rebuildPreview() }
    @objc private func moveEarlier() { moveSelected(-1) }
    @objc private func moveLater() { moveSelected(1) }
    private func moveSelected(_ offset: Int) {
        guard canEdit, let selected, project.clips.indices.contains(selected + offset) else { return }
        change { $0.move(selected, to: selected + offset) }; self.selected = selected + offset; refresh()
    }
    @objc private func duplicateClip() {
        guard canEdit, let selected else { return }; var copy = project.clips[selected]; copy.id = UUID()
        change { $0.clips.insert(copy, at: selected + 1) }; self.selected = selected + 1; refresh()
    }
    @objc private func removeClip() {
        guard canEdit, let selected else { return }; change { $0.clips.remove(at: selected) }; self.selected = nil; refresh()
    }
    @objc private func newProject() {
        guard canEdit else { return }
        let confirm = UIAlertController(title: "Start a new movie?", message: "Save a project package first if you want to keep the current edit. Imported media is not deleted.", preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        confirm.addAction(UIAlertAction(title: "New movie", style: .default) { [weak self] _ in self?.change { $0 = MobileProject() }; self?.selected = nil })
        present(confirm, animated: true)
    }
    @objc private func importVideos() {
        guard canEdit else { return }; pickerMode = "video"
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie], asCopy: false)
        picker.allowsMultipleSelection = true; picker.delegate = self; present(picker, animated: true)
    }
    @objc private func openProject() {
        guard canEdit else { return }; pickerMode = "project"
        let type = UTType("com.netvistastudio.mobile-project") ?? .package
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [type, .folder], asCopy: false)
        picker.delegate = self; present(picker, animated: true)
    }
    @objc private func saveProject() {
        // Saving remains available after session invalidation so an account failure cannot destroy work.
        guard !exporting, !importing else { return }
        saveWorking()
        importing = true
        let snapshot = project
        Task { do {
            let package = FileManager.default.temporaryDirectory.appendingPathComponent("Movie-\(UUID().uuidString.prefix(8)).netvistamobile", isDirectory: true)
            pendingTemporary = package
            let resources = package.appendingPathComponent("Media", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let mediaDirectory = media
            for file in Set(snapshot.clips.map(\.file)) {
                try await Task.detached {
                    try FileManager.default.copyItem(at: mediaDirectory.appendingPathComponent(file), to: resources.appendingPathComponent(file))
                }.value
            }
            try snapshot.write(package.appendingPathComponent("project.json"))
            importing = false
            pickerMode = "save"
            let picker = UIDocumentPickerViewController(forExporting: [package], asCopy: true)
            pendingTemporary = package
            picker.delegate = self; present(picker, animated: true)
            message("Choose a Files location for the portable project. It contains your media and trim/order settings.")
        } catch { importing = false; cleanupTemporary(); self.error(error) } }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        if pickerMode == "save" || pickerMode == "export" { cleanupTemporary(); message("Saved to Files."); return }
        if pickerMode == "project" { loadPackage(urls[0]); return }
        guard canEdit else { return }
        importing = true; message("Importing videos…")
        Task {
            var added: [MobileClip] = []; var failures: [String] = []
            for source in urls {
                let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
                let file = "\(UUID().uuidString).\(source.pathExtension.isEmpty ? "mov" : source.pathExtension)"
                let destination = media.appendingPathComponent(file)
                do {
                    try await Task.detached { try FileManager.default.copyItem(at: source, to: destination) }.value
                    let duration = try await MobileVideoEngine.inspect(destination)
                    added.append(MobileClip(name: source.lastPathComponent, file: file, duration: duration, outPoint: duration))
                } catch {
                    try? FileManager.default.removeItem(at: destination); failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            importing = false
            if !added.isEmpty { change { $0.clips.append(contentsOf: added) }; selected = project.clips.count - added.count; refresh() }
            if !failures.isEmpty { alert("Some videos could not be imported", failures.joined(separator: "\n")) }
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanupTemporary(); message("File operation cancelled. Your working project is safe.")
    }
    private func cleanupTemporary() {
        if let pendingTemporary { try? FileManager.default.removeItem(at: pendingTemporary) }
        pendingTemporary = nil
    }
    private func loadPackage(_ url: URL) {
        importing = true; message("Opening portable project…")
        Task {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() }; importing = false }
            var importedFiles: [URL] = []; var committed = false
            defer { if !committed { for file in importedFiles { try? FileManager.default.removeItem(at: file) } } }
            do {
                var value = try MobileProject.read(url.appendingPathComponent("project.json"))
                var mapped: [String: String] = [:]
                var durations: [String: Double] = [:]
                for index in value.clips.indices {
                    let old = value.clips[index].file
                    if let copied = mapped[old], let duration = durations[old] {
                        value.clips[index].file = copied; value.clips[index].duration = duration
                        try value.clips[index].validate(); continue
                    }
                    let source = url.appendingPathComponent("Media").appendingPathComponent(old)
                    let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          source.resolvingSymlinksInPath().path.hasPrefix(url.resolvingSymlinksInPath().appendingPathComponent("Media").path + "/") else {
                        throw MobileProjectError.missingMedia(old)
                    }
                    let copied = "\(UUID().uuidString).\(source.pathExtension)"
                    let destination = media.appendingPathComponent(copied)
                    importedFiles.append(destination)
                    try await Task.detached { try FileManager.default.copyItem(at: source, to: destination) }.value
                    let duration = try await MobileVideoEngine.inspect(destination)
                    guard duration + 0.01 >= value.clips[index].outPoint else { throw MobileProjectError.invalidClip }
                    mapped[old] = copied; durations[old] = duration
                    value.clips[index].file = copied; value.clips[index].duration = duration
                    try value.clips[index].validate()
                }
                change { $0 = value }; committed = true; selected = nil; refresh()
            } catch { self.error(error) }
        }
    }

    @objc private func exportAction() {
        guard canEdit, !project.clips.isEmpty else { alert("No clips to export", "Import at least one video first."); return }
        let options = UIAlertController(title: "Export movie", message: "MP4 · 16:9 · 30 fps\nAll clips are fit within the frame without cropping.", preferredStyle: .alert)
        for (name, height) in [("720p", 720), ("1080p", 1080), ("4K", 2160)] {
            options.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in self?.beginExport(height) })
        }
        options.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(options, animated: true)
    }
    private func beginExport(_ height: Int) {
        exportGeneration += 1
        let ticket = exportGeneration
        exporting = true; player.pause(); view.endEditing(true)
        let alert = UIAlertController(title: "Exporting movie", message: "Preparing sequence…\nKeep NetVista open until export finishes.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel export", style: .destructive) { [weak self] _ in
            guard let self, ticket == self.exportGeneration else { return }
            self.exportGeneration += 1; self.exportSession?.cancelExport(); self.exportSession = nil
            self.progressTimer?.invalidate(); self.progressTimer = nil; self.exportAlert = nil; self.exporting = false
            self.message("Export cancelled. Your working project is safe.")
        })
        exportAlert = alert; present(alert, animated: true)
        let snapshot = project
        Task {
            do {
                let sequence = try await MobileVideoEngine.sequence(snapshot, media: media, height: height)
                guard exporting, ticket == exportGeneration else { return }
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("NetVista-Movie-\(UUID().uuidString.prefix(8)).mp4")
                let session = try MobileVideoEngine.exporter(sequence, output: output); exportSession = session
                progressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let current = self.exportSession else { return }
                        self.exportAlert?.message = "\(Int(current.progress * 100))% · \(height)p · 30 fps\nKeep NetVista open until export finishes."
                    }
                }
                session.exportAsynchronously { [weak self] in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        guard ticket == self.exportGeneration else { try? FileManager.default.removeItem(at: output); return }
                        self.progressTimer?.invalidate(); self.progressTimer = nil; self.exportSession = nil; self.exporting = false
                        let finish = {
                            if session.status == .completed {
                                self.pickerMode = "export"
                                let picker = UIDocumentPickerViewController(forExporting: [output], asCopy: true)
                                self.pendingTemporary = output
                                picker.delegate = self; self.present(picker, animated: true)
                                self.message("Export finished. Save the MP4 in Files.")
                            } else if session.status != .cancelled {
                                try? FileManager.default.removeItem(at: output)
                                self.error(session.error ?? MobileProjectError.noVideo)
                            } else { try? FileManager.default.removeItem(at: output); self.message("Export cancelled. Your project is safe.") }
                        }
                        if self.exportAlert?.presentingViewController != nil { self.exportAlert?.dismiss(animated: true, completion: finish) }
                        else { finish() }
                        self.exportAlert = nil
                    }
                }
            } catch {
                guard ticket == exportGeneration else { return }
                exporting = false; exportAlert?.dismiss(animated: true) { [weak self] in self?.error(error) }; exportAlert = nil
            }
        }
    }

    private func refreshAccount() {
        accountStatus.text = account.status
        accountOverlay.isHidden = account.lastVerified != nil && account.session != nil
        if account.busy { accountStatus.text = "\(account.status)" }
    }
    @objc private func accountAction() {
        guard let email = account.email else { signIn(); return }
        let sheet = UIAlertController(title: email, message: account.status, preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: "Check account", style: .default) { [weak self] _ in self?.account.check(force: true) })
        sheet.addAction(UIAlertAction(title: "Sign out", style: .destructive) { [weak self] _ in self?.account.signOut(); self?.player.pause() })
        sheet.addAction(UIAlertAction(title: "Close", style: .cancel)); present(sheet, animated: true)
    }
    @objc private func signIn() {
        guard !account.busy else { return }
        let value = UIAlertController(title: "NetVista account", message: "Sign in to unlock this standalone editor. No media is uploaded.", preferredStyle: .alert)
        value.addTextField { $0.placeholder = "Email"; $0.keyboardType = .emailAddress; $0.autocapitalizationType = .none; $0.textContentType = .username }
        value.addTextField { $0.placeholder = "Password"; $0.isSecureTextEntry = true; $0.textContentType = .password }
        value.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        value.addAction(UIAlertAction(title: "Sign in", style: .default) { [weak self] _ in
            let email = value.textFields?[0].text ?? ""; let password = value.textFields?[1].text ?? ""
            self?.account.signIn(email: email, password: password, remember: true)
            value.textFields?[1].text = nil
        }); present(value, animated: true)
    }
    @objc private func openAccountWebsite() { UIApplication.shared.open(URL(string: "https://netvistastudio.com/account/")!) }
    @objc private func willBackground() { player.pause(); saveWorking() }
    @objc private func willForeground() { account.checkIfDue() }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { project.clips.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil); let clip = project.clips[indexPath.row]
        cell.textLabel?.text = "\(indexPath.row + 1).  \(clip.name)"
        cell.detailTextLabel?.text = String(format: "%.2f s  →  %.2f s   ·   %.2f s", clip.inPoint, clip.outPoint, clip.length)
        cell.imageView?.image = UIImage(systemName: "film"); cell.imageView?.tintColor = accent
        cell.backgroundColor = panel; cell.detailTextLabel?.textColor = .secondaryLabel; cell.showsReorderControl = true
        let chosen = UIView(); chosen.backgroundColor = accent.withAlphaComponent(0.2); cell.selectedBackgroundView = chosen
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selected = indexPath.row; refresh()
        let time = project.clips.prefix(indexPath.row).reduce(0) { $0 + $1.length }
        player.pause(); player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        if trimPanel.isHidden { numericTrim() }
    }
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { canEdit }
    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }
    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
    func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        guard canEdit else { refresh(); return }; change { $0.move(source.row, to: destination.row) }; selected = destination.row; refresh()
    }
}
