import UIKit
@preconcurrency import AVKit
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

@MainActor
class MobileEditorCore: UIViewController, UIDocumentPickerDelegate {
    let panel = UIColor(white: 0.12, alpha: 1)
    let accent = UIColor(red: 1, green: 0.28, blue: 0.33, alpha: 1)
    let history = MobileHistory()
    let account = StudioAccount(store: MobileSessionStore(), transport: MobileAccount.transport)
    var project = MobileProject()
    var selected: Int?
    var pickerMode = "video"
    var previewTask: Task<Void, Never>?
    var currentSequence: MobileSequence?
    var previewGeneration = 0
    var previewBuilding = false
    var desiredPreviewTime: Double?
    var previewTargetTime: Double = 0
    private var previewSeekInFlight = false
    private var seekRequestGeneration = 0
    var pendingPlay = false
    private(set) var usingCompatibilityPreview = false
    private var itemStatusObservation: NSKeyValueObservation?
    private var previewProxySession: AVAssetExportSession?
    private var previewProgressTimer: Timer?
    private var previewProxyURL: URL?
    private var previewOwnedFiles = Set<URL>()
    var exportSession: AVAssetExportSession?
    var progressTimer: Timer?
    var exporting = false { didSet { if isViewLoaded { refresh() } } }
    var exportGeneration = 0
    var importing = false { didSet { if isViewLoaded { refresh() } } }
    var pendingTemporary: URL?
    var observer: Any?
    let player = AVPlayer()
    let playerController = AVPlayerViewController()
    let titleField = UITextField()
    let status = UILabel()
    let timeLabel = UILabel()
    let seek = UISlider()
    let start = UISlider()
    let end = UISlider()
    let startLabel = UILabel()
    let endLabel = UILabel()
    let clipLabel = UILabel()
    let accountOverlay = UIView()
    let accountStatus = UILabel()
    var exportAlert: UIAlertController?
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var media: URL { documents.appendingPathComponent("Media", isDirectory: true) }
    var autosave: URL { documents.appendingPathComponent("WorkingProject.json") }
    var canEdit: Bool { account.lastVerified != nil && account.session != nil && !exporting && !importing }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.075, alpha: 1)
        overrideUserInterfaceStyle = .dark
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        if let saved = try? MobileProject.read(autosave) { project = saved }
        buildUI()
        playerController.player = player; playerController.showsPlaybackControls = false
        playerController.videoGravity = .resizeAspect
        playerController.view.isUserInteractionEnabled = false
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 15), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                // A pending build or seek owns the logical playhead. Publishing
                // an old/failed player's zero time here loses the user's target.
                guard !self.previewBuilding, !self.previewSeekInFlight,
                      self.player.currentItem?.status == .readyToPlay else { return }
                self.previewTargetTime = time.seconds.isFinite ? time.seconds : 0
                if !self.seek.isTracking { self.seek.value = Float(time.seconds.isFinite ? time.seconds : 0) }
                self.timeLabel.text = "\(self.clock(time.seconds)) / \(self.clock(self.project.totalDuration))"
                self.playbackTimeChanged(time.seconds.isFinite ? time.seconds : 0)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(willBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        account.onChange = { [weak self] in self?.refreshAccount() }
        account.onInvalidated = { [weak self] in self?.player.pause(); self?.pendingPlay = false }
        account.start()
        refresh(); rebuildPreview()
    }

    func label(_ text: String, size: CGFloat = 14, weight: UIFont.Weight = .regular) -> UILabel {
        let value = UILabel(); value.text = text; value.font = .systemFont(ofSize: size, weight: weight)
        value.textColor = .label; value.numberOfLines = 0; return value
    }
    func button(_ name: String, image: String? = nil, action: Selector, primary: Bool = false) -> UIButton {
        let value = UIButton(type: .system)
        var config = primary ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        config.title = name; config.image = image.flatMap { UIImage(systemName: $0) }
        config.imagePadding = 7; config.baseBackgroundColor = primary ? accent : .darkGray
        config.baseForegroundColor = .white; config.cornerStyle = .medium
        value.configuration = config; value.addTarget(self, action: action, for: .touchUpInside)
        value.accessibilityLabel = name; return value
    }
    func stack(_ axis: NSLayoutConstraint.Axis, _ views: [UIView], spacing: CGFloat = 12) -> UIStackView {
        let value = UIStackView(arrangedSubviews: views); value.axis = axis; value.spacing = spacing; return value
    }
    // The native workspace subclass owns all view construction and responsive layout.
    func buildUI() { }
    func playbackTimeChanged(_ seconds: Double) { }
    func selectedClipChanged() { }
    func previewStateChanged(_ text: String?) { }

    func clock(_ seconds: Double) -> String {
        let value = max(0, min(31_536_000, seconds.isFinite ? seconds : 0))
        let frames = Int(floor(value * 30))
        return String(format: "%02d:%02d:%02d:%02d", frames / 108_000, frames / 1800 % 60, frames / 30 % 60, frames % 30)
    }
    func message(_ text: String) { status.text = text }
    func error(_ error: Error) { message(error.localizedDescription); alert("Could not complete", error.localizedDescription) }
    func alert(_ title: String, _ text: String) {
        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
    func saveWorking() { do { try project.write(autosave) } catch { message("Autosave failed: \(error.localizedDescription)") } }
    func change(_ mutation: (inout MobileProject) -> Void) {
        history.record(project); mutation(&project); saveWorking(); refresh(); rebuildPreview()
    }
    func refresh() {
        titleField.text = project.name
        if let selected, !project.clips.indices.contains(selected) { self.selected = nil }
        let clip = selected.flatMap { project.clips.indices.contains($0) ? project.clips[$0] : nil }
        clipLabel.text = clip?.name ?? "Select a clip"
        for slider in [start, end] { slider.isEnabled = clip != nil; slider.minimumValue = 0; slider.maximumValue = Float(clip?.duration ?? 1) }
        start.value = Float(clip?.inPoint ?? 0); end.value = Float(clip?.outPoint ?? 1)
        updateTrimLabels(); seek.maximumValue = Float(max(0.01, project.totalDuration))
    }
    func rebuildPreview() {
        cancelPreviewWork(); let ticket = previewGeneration
        guard !project.clips.isEmpty else {
            pendingPlay = false; previewBuilding = false; desiredPreviewTime = nil; currentSequence = nil
            previewTargetTime = 0; seek.value = 0; timeLabel.text = clock(0); playbackTimeChanged(0)
            itemStatusObservation = nil; player.replaceCurrentItem(with: nil); removeCurrentProxy(); previewStateChanged(nil); return
        }
        previewBuilding = true
        let snapshot = project; let at = min(previewTargetTime, snapshot.totalDuration)
        previewTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if ticket == self.previewGeneration {
                    self.previewBuilding = false; self.previewProxySession = nil
                    self.previewProgressTimer?.invalidate(); self.previewProgressTimer = nil
                }
            }
            do {
                let compatibility = self.usingCompatibilityPreview
                let sequence = try await MobileVideoEngine.sequence(snapshot, media: self.media, height: 720, livePreview: !compatibility)
                guard !Task.isCancelled, ticket == self.previewGeneration else { return }
                // Slider edits can arrive while source metadata is loading. Do
                // not install a newly built sequence with those effects stale.
                for clip in self.project.clips { sequence.updateEffects(id: clip.id, effects: clip.effects) }
                let item: AVPlayerItem
                var output: URL?
                if compatibility {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("NetVista-preview-\(UUID().uuidString).mp4")
                    self.previewOwnedFiles.insert(url)
                    var installed = false
                    defer { if !installed { self.deletePreviewFile(url) } }
                    let session = try MobileVideoEngine.exporter(sequence, output: url)
                    self.previewProxySession = session
                    self.message("Compatibility preview · Rendering locally at 720p…")
                    if self.player.currentItem == nil || self.player.currentItem?.status == .failed { self.previewStateChanged("Preparing native compatibility preview…") }
                    self.previewProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, ticket == self.previewGeneration, let session = self.previewProxySession else { return }
                            self.message("Compatibility preview · \(Int(session.progress * 100))% · Native 720p rendering")
                        }
                    }
                    await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
                    guard !Task.isCancelled, ticket == self.previewGeneration else { return }
                    guard session.status == .completed else { throw session.error ?? MobileProjectError.noVideo }
                    item = AVPlayerItem(url: url); output = url; installed = true
                } else {
                    item = AVPlayerItem(asset: sequence.composition); item.videoComposition = sequence.videoComposition
                }
                self.currentSequence = sequence
                self.observePreview(item, ticket: ticket, compatibility: compatibility)
                self.player.replaceCurrentItem(with: item)
                self.removeCurrentProxy(); self.previewProxyURL = output
                self.previewStateChanged(nil)
                var requested = self.desiredPreviewTime ?? at
                repeat {
                    self.desiredPreviewTime = nil
                    self.previewTargetTime = min(snapshot.totalDuration, max(0, requested.isFinite ? requested : 0))
                    await self.seekPlayer(to: self.previewTargetTime)
                    guard !Task.isCancelled, ticket == self.previewGeneration else { return }
                    if let latest = self.desiredPreviewTime { requested = latest } else { break }
                } while true
                guard item.status != .failed else { return }
                if self.pendingPlay && self.canEdit { self.player.play() }
                if item.status == .readyToPlay { self.pendingPlay = false }
                self.message("\(snapshot.clips.count) clips · \(self.clock(snapshot.totalDuration)) · \(compatibility ? "Compatibility preview · " : "")Changes autosaved on this device.")
            } catch {
                if !Task.isCancelled, ticket == self.previewGeneration {
                    self.pendingPlay = false
                    self.previewStateChanged("Preview could not be prepared. Your project is safe.")
                    self.message("Preview failed: \(error.localizedDescription)")
                }
            }
        }
    }
    /// Called as soon as a proxy becomes stale, before the debounced rebuild.
    /// Older exports cannot install frames with settings the user has changed.
    func cancelPreviewWork() {
        previewGeneration += 1
        pendingPlay = pendingPlay || player.rate > 0
        previewTask?.cancel(); previewProxySession?.cancelExport(); previewProxySession = nil
        previewProgressTimer?.invalidate(); previewProgressTimer = nil; player.pause()
        seekRequestGeneration += 1; previewSeekInFlight = false; player.currentItem?.cancelPendingSeeks()
    }
    private func observePreview(_ item: AVPlayerItem, ticket: Int, compatibility: Bool) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, ticket == self.previewGeneration, self.player.currentItem === item,
                      item.status == .failed else { return }
                if !compatibility {
                    // Some OS versions reject custom-compositor playback even
                    // when offline Core Image export succeeds. Fall back only
                    // after this real failure, never by device-name guessing.
                    self.usingCompatibilityPreview = true
                    self.desiredPreviewTime = self.desiredPreviewTime ?? self.previewTargetTime
                    self.player.replaceCurrentItem(with: nil)
                    self.message("Native player compatibility mode · Preparing local preview…")
                    self.rebuildPreview()
                } else {
                    self.pendingPlay = false; self.player.pause(); self.player.replaceCurrentItem(with: nil)
                    self.previewStateChanged("Preview is unavailable. Your project is safe.")
                    self.message("Compatibility playback failed: \(item.error?.localizedDescription ?? "Unknown media error")")
                }
            }
        }
    }
    private func removeCurrentProxy() { if let url = previewProxyURL { deletePreviewFile(url) }; previewProxyURL = nil }
    private func deletePreviewFile(_ url: URL) { guard previewOwnedFiles.remove(url) != nil else { return }; try? FileManager.default.removeItem(at: url) }

    deinit {
        previewTask?.cancel(); previewProxySession?.cancelExport(); previewProgressTimer?.invalidate()
        itemStatusObservation?.invalidate()
        if let observer { player.removeTimeObserver(observer) }
        for url in previewOwnedFiles { try? FileManager.default.removeItem(at: url) }
    }
    func updateTrimLabels() {
        startLabel.text = String(format: "IN    %.2f s", start.value)
        endLabel.text = String(format: "OUT   %.2f s", end.value)
    }
    @objc func trimPreview(_ slider: UISlider) {
        if start.value >= end.value - 0.04 {
            if slider === start { start.value = max(0, end.value - 0.04) }
            else { end.value = min(end.maximumValue, start.value + 0.04) }
        }
        updateTrimLabels()
    }
    @objc func commitTrim(_ slider: UISlider) {
        guard canEdit, let selected else { refresh(); return }
        do {
            var next = project; try next.trim(selected, start: Double(start.value), end: Double(end.value))
            history.record(project); project = next; saveWorking(); refresh(); rebuildPreview()
        } catch { self.error(error); refresh() }
    }
    @objc func numericTrim() {
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
    @objc func nameChanged() {
        let name = titleField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard canEdit, !name.isEmpty else { titleField.text = project.name; return }
        guard name != project.name else { return }
        history.record(project); project.name = String(name.prefix(150)); saveWorking(); refresh()
    }
    @objc func playPause() {
        guard canEdit else { return }
        if previewBuilding { pendingPlay.toggle(); playbackTimeChanged(timelineSeconds()); return }
        guard player.currentItem != nil else { return }
        if player.rate > 0 { player.pause() }
        else { if player.currentTime().seconds >= project.totalDuration - 0.04 { player.seek(to: .zero) }; player.play() }
    }
    @objc func scrub() {
        pendingPlay = false; player.pause()
        let target = min(project.totalDuration, max(0, Double(seek.value)))
        previewTargetTime = target; playbackTimeChanged(target)
        if previewBuilding || player.currentItem?.status != .readyToPlay { desiredPreviewTime = target; return }
        desiredPreviewTime = nil; previewSeekInFlight = true
        Task { [weak self] in await self?.seekPlayer(to: target) }
    }
    private func seekPlayer(to target: Double) async {
        seekRequestGeneration += 1; let ticket = seekRequestGeneration
        previewSeekInFlight = true
        let finished = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        guard ticket == seekRequestGeneration else { return }
        previewSeekInFlight = false
        if finished, player.currentItem?.status == .readyToPlay, previewTargetTime == target {
            seek.value = Float(target); playbackTimeChanged(target)
        }
    }
    private func timelineSeconds() -> Double { previewTargetTime }
    @objc func undoAction() { guard canEdit, let previous = history.undo(project) else { return }; project = previous; saveWorking(); refresh(); rebuildPreview() }
    @objc func redoAction() { guard canEdit, let next = history.redo(project) else { return }; project = next; saveWorking(); refresh(); rebuildPreview() }
    @objc func moveEarlier() { moveSelected(-1) }
    @objc func moveLater() { moveSelected(1) }
    func moveSelected(_ offset: Int) {
        guard canEdit, let selected, project.clips.indices.contains(selected + offset) else { return }
        change { $0.move(selected, to: selected + offset) }; self.selected = selected + offset; refresh()
    }
    @objc func duplicateClip() {
        guard canEdit, let selected else { return }; var copy = project.clips[selected]; copy.id = UUID()
        change { $0.clips.insert(copy, at: selected + 1) }; self.selected = selected + 1; refresh(); selectedClipChanged()
    }
    @objc func removeClip() {
        guard canEdit, let selected else { return }; change { $0.clips.remove(at: selected) }; self.selected = nil; refresh()
    }
    @objc func newProject() {
        guard canEdit else { return }
        let confirm = UIAlertController(title: "Start a new movie?", message: "Save a project package first if you want to keep the current edit. Imported media is not deleted.", preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        confirm.addAction(UIAlertAction(title: "New movie", style: .default) { [weak self] _ in self?.change { $0 = MobileProject() }; self?.selected = nil })
        present(confirm, animated: true)
    }
    @objc func importVideos() {
        guard canEdit else { return }; pickerMode = "video"
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie], asCopy: false)
        picker.allowsMultipleSelection = true; picker.delegate = self; present(picker, animated: true)
    }
    @objc func openProject() {
        guard canEdit else { return }; pickerMode = "project"
        let type = UTType("com.netvistastudio.mobile-project") ?? .package
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [type, .folder], asCopy: false)
        picker.delegate = self; present(picker, animated: true)
    }
    @objc func saveProject() {
        // Saving remains available after session invalidation so an account failure cannot destroy work.
        guard !exporting, !importing else { return }
        view.endEditing(true)
        saveWorking()
        importing = true
        let snapshot = project
        Task { do {
            let package = FileManager.default.temporaryDirectory.appendingPathComponent("Movie-\(UUID().uuidString.prefix(8)).netvistamobile", isDirectory: true)
            pendingTemporary = package
            let resources = package.appendingPathComponent("Media", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let mediaDirectory = media
            for file in Set((snapshot.clips + snapshot.library).map(\.file)) {
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
            message("Choose a Files location. The project keeps source media, trims, order, motion, colour and animation keyframes.")
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
            if !added.isEmpty { change { $0.library.append(contentsOf: added); $0.clips.append(contentsOf: added) }; selected = project.clips.count - added.count; refresh(); selectedClipChanged() }
            if !failures.isEmpty { alert("Some videos could not be imported", failures.joined(separator: "\n")) }
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanupTemporary(); message("File operation cancelled. Your working project is safe.")
    }
    func cleanupTemporary() {
        if let pendingTemporary { try? FileManager.default.removeItem(at: pendingTemporary) }
        pendingTemporary = nil
    }
    func loadPackage(_ url: URL) {
        importing = true; message("Opening portable project…")
        Task {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() }; importing = false }
            var importedFiles: [URL] = []; var committed = false
            defer { if !committed { for file in importedFiles { try? FileManager.default.removeItem(at: file) } } }
            do {
                var value = try MobileProject.read(url.appendingPathComponent("project.json"))
                var mapped: [String: String] = [:]
                var durations: [String: Double] = [:]
                for original in value.clips + value.library {
                    let old = original.file
                    if let duration = durations[old] {
                        guard duration + 0.01 >= original.outPoint else { throw MobileProjectError.invalidClip }; continue
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
                    guard duration + 0.01 >= original.outPoint else { throw MobileProjectError.invalidClip }
                    mapped[old] = copied; durations[old] = duration
                }
                value.clips = try value.clips.map { original in
                    var clip = original; clip.file = mapped[original.file]!; clip.duration = durations[original.file]!
                    try clip.validate(); return clip
                }
                value.library = try value.library.map { original in
                    var clip = original; clip.file = mapped[original.file]!; clip.duration = durations[original.file]!
                    try clip.validate(); return clip
                }
                change { $0 = value }; committed = true; selected = nil; desiredPreviewTime = 0; refresh()
            } catch { self.error(error) }
        }
    }

    @objc func exportAction() {
        guard canEdit else { return }
        guard !project.clips.isEmpty else { alert("No clips to export", "Import at least one video first."); return }
        let options = UIAlertController(title: "Export movie", message: "MP4 · 16:9 · 30 fps\nAll clips are fit within the frame without cropping.", preferredStyle: .alert)
        for (name, height) in [("720p", 720), ("1080p", 1080), ("4K", 2160)] {
            options.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in self?.beginExport(height) })
        }
        options.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(options, animated: true)
    }
    func beginExport(_ height: Int) {
        view.endEditing(true)
        exportGeneration += 1
        let ticket = exportGeneration
        exporting = true; player.pause()
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

    func refreshAccount() {
        accountStatus.text = account.status
        accountOverlay.isHidden = account.lastVerified != nil && account.session != nil
        if account.busy { accountStatus.text = "\(account.status)" }
    }
    @objc func accountAction() {
        guard let email = account.email else { signIn(); return }
        let sheet = UIAlertController(title: email, message: account.status, preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: "Check account", style: .default) { [weak self] _ in self?.account.check(force: true) })
        sheet.addAction(UIAlertAction(title: "Sign out", style: .destructive) { [weak self] _ in self?.account.signOut(); self?.player.pause() })
        sheet.addAction(UIAlertAction(title: "Close", style: .cancel)); present(sheet, animated: true)
    }
    @objc func signIn() {
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
    @objc func openAccountWebsite() { UIApplication.shared.open(URL(string: "https://netvistastudio.com/account/")!) }
    @objc func willBackground() { pendingPlay = false; player.pause(); saveWorking() }
    @objc func willForeground() { account.checkIfDue() }

}

/// The mobile workspace uses the same native panel hierarchy, compact typography
/// and colour tokens as the desktop editor. Small windows collapse side panels;
/// they do not scale desktop labels down or replace the timeline with a list.
@MainActor
class EditorViewController: MobileEditorCore, UITableViewDataSource, UITableViewDelegate {
    private let header = UIView(), workspace = UIView(), home = UIScrollView()
    private let brand = UIView(), logo = UIImageView(), wordmark = MobileTheme.label("NetVista", size: 17, weight: .semibold)
    private let studio = MobileTheme.label("STUDIO", size: 10, weight: .bold)
    private let mediaPanel = UIView(), centrePanel = UIView(), inspectorPanel = UIView()
    private let monitor = UIView(), emptyMonitor = MobileTheme.label("Import media to start editing", size: 12)
    private let transport = UIView(), timelineToolbar = UIScrollView(), navigation = UIView()
    private let inspectorScroll = UIScrollView(), inspectorContent = UIView()
    private let poolTable = UITableView(frame: .zero, style: .plain)
    private let timeline = MobileTimelineView()
    private let poolTitle = MobileTheme.label("MEDIA POOL", size: 10, weight: .bold)
    private let inspectorTitle = MobileTheme.label("INSPECTOR", size: 10, weight: .bold)
    private let programTitle = MobileTheme.label("PROGRAM MONITOR", size: 10, weight: .bold)
    private let homeTitle = MobileTheme.label("Welcome to your studio.", size: 27, weight: .semibold)
    private let homeSubtitle = MobileTheme.label("Open an editor or continue your saved movie.", size: 13)
    private let hero = UIView(), heroPhoto = UIImageView(), heroTitle = MobileTheme.label("Video Editor", size: 22, weight: .semibold)
    private let heroDetails = MobileTheme.label("Timeline, motion and colour. A native workspace on every device.", size: 12)
    private let homeLimits = MobileTheme.label("Mobile video workspace preview · Photo, Game Maker, 3D, advanced grading and independent multitrack audio are not available here yet.", size: 12)
    private let recentTitle = MobileTheme.label("Working project", size: 17, weight: .semibold)
    private let recentDetails = MobileTheme.label("", size: 13)
    private var headerButtons: [UIButton] = [], timelineButtons: [UIButton] = [], navButtons: [UIButton] = []
    private var homeButton: UIButton!, menuButton: UIButton!, openEditorButton: UIButton!, continueButton: UIButton!
    private var importButton: UIButton!, addButton: UIButton!, addAllButton: UIButton!
    private var playButton: UIButton!, stopButton: UIButton!, backButton: UIButton!, nextButton: UIButton!
    private var rows: [String: MobilePropertyRow] = [:]
    private let animationPanel = MobileAnimationPanel()
    private var animationProperty: MobileEffectProperty = .opacity
    private var animationInterpolation: MobileKeyframeInterpolation = .linear
    private var autoKeyframe = false
    private var inspectorItems: [(UIView, CGFloat)] = []
    private var trimViews: [UIView] = [], motionViews: [UIView] = [], colourViews: [UIView] = []
    private var clipActions: [UIButton] = []
    private var homeVisible = true
    private var page = "Edit"
    private var drawer: String?
    private var selectedSource: Int?
    private var propertyBefore: MobileProject?
    private var propertySourceTime: Double?
    private var propertySeekTask: Task<Void, Never>?
    private var propertySeekGeneration = 0
    private var previewUnavailableMessage: String?

    override func buildUI() {
        view.backgroundColor = MobileTheme.window
        for panel in [header, workspace, mediaPanel, centrePanel, inspectorPanel, transport, navigation, monitor] { view.addSubview(panel) }
        header.backgroundColor = MobileTheme.top; workspace.backgroundColor = MobileTheme.workspace
        for panel in [mediaPanel, inspectorPanel] { panel.backgroundColor = MobileTheme.panel; workspace.addSubview(panel) }
        centrePanel.backgroundColor = MobileTheme.workspace; workspace.addSubview(centrePanel)
        header.addSubview(brand); brand.addSubview(logo); brand.addSubview(wordmark); brand.addSubview(studio)
        logo.image = UIImage(named: "NetVistaStudio.png"); logo.contentMode = .scaleAspectFit; studio.textColor = MobileTheme.accent
        brand.accessibilityIdentifier = "studio.brand"
        homeButton = action("Studio Home", symbol: "house", id: "studio.home") { [weak self] in self?.showHome() }
        menuButton = action("More", symbol: "ellipsis", id: "studio.more") { [weak self] in self?.showMenu() }
        header.addSubview(homeButton); header.addSubview(menuButton)
        titleField.textColor = .white; titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.backgroundColor = MobileTheme.control; titleField.layer.cornerRadius = 5
        titleField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 10)); titleField.leftViewMode = .always
        titleField.returnKeyType = .done; titleField.accessibilityIdentifier = "project.title"
        titleField.addTarget(self, action: #selector(nameChanged), for: .editingDidEnd); header.addSubview(titleField)
        headerButtons = [action("Undo", symbol: "arrow.uturn.backward", id: "edit.undo") { [weak self] in self?.undoAction() },
                         action("Redo", symbol: "arrow.uturn.forward", id: "edit.redo") { [weak self] in self?.redoAction() },
                         action("Account", symbol: "person.crop.circle", id: "studio.account") { [weak self] in self?.accountAction() },
                         action("Open", id: "project.open") { [weak self] in self?.openProject() },
                         action("Save", id: "project.save") { [weak self] in self?.saveProject() },
                         action("Export", id: "project.export") { [weak self] in self?.exportAction() }]
        headerButtons.forEach { header.addSubview($0) }; headerButtons.last?.backgroundColor = MobileTheme.accent
        buildHome(); buildMedia(); buildMonitor(); buildTimeline(); buildInspector(); buildNavigation(); buildAccountOverlay()
        status.font = .systemFont(ofSize: 10); status.textColor = MobileTheme.secondary; status.numberOfLines = 1
        status.accessibilityIdentifier = "studio.status"; view.addSubview(status)
        showHome()
    }

    private func action(_ title: String, symbol: String? = nil, id: String, _ body: @escaping () -> Void) -> UIButton {
        let button = MobileTheme.button(title, symbol: symbol, action: body); button.accessibilityIdentifier = id; return button
    }
    private func buildHome() {
        home.backgroundColor = MobileTheme.window; home.alwaysBounceVertical = true; home.accessibilityIdentifier = "studio.home.content"; view.addSubview(home)
        for item in [homeTitle, homeSubtitle, hero, homeLimits, recentTitle, recentDetails] { home.addSubview(item) }
        hero.backgroundColor = MobileTheme.panel; hero.layer.cornerRadius = 7; hero.clipsToBounds = true
        heroPhoto.image = UIImage(named: "home-video-coast.png"); heroPhoto.contentMode = .scaleAspectFill; heroPhoto.clipsToBounds = true
        for item in [heroPhoto, heroTitle, heroDetails] { hero.addSubview(item) }
        homeSubtitle.textColor = MobileTheme.secondary; heroDetails.textColor = MobileTheme.secondary
        heroDetails.numberOfLines = 0; homeLimits.numberOfLines = 0; homeLimits.textColor = MobileTheme.secondary
        openEditorButton = action("Open editor", symbol: "film", id: "studio.open.video") { [weak self] in self?.openWorkspace() }
        openEditorButton.backgroundColor = .white; openEditorButton.setTitleColor(MobileTheme.top, for: .normal); openEditorButton.tintColor = MobileTheme.top
        hero.addSubview(openEditorButton)
        continueButton = action("Continue project", symbol: "play", id: "studio.continue") { [weak self] in self?.openWorkspace() }; home.addSubview(continueButton)
    }
    private func buildMedia() {
        mediaPanel.accessibilityIdentifier = "workspace.media.pool"; mediaPanel.addSubview(poolTitle)
        importButton = action("Import", symbol: "plus", id: "media.import") { [weak self] in self?.importVideos() }; mediaPanel.addSubview(importButton)
        poolTable.backgroundColor = MobileTheme.panel; poolTable.separatorColor = MobileTheme.line
        poolTable.dataSource = self; poolTable.delegate = self; poolTable.rowHeight = 62
        poolTable.accessibilityIdentifier = "media.sources"; mediaPanel.addSubview(poolTable)
        addButton = action("Add selected", id: "media.add.selected") { [weak self] in self?.addSource() }
        addAllButton = action("Add all", id: "media.add.all") { [weak self] in self?.addAllSources() }
        mediaPanel.addSubview(addButton); mediaPanel.addSubview(addAllButton)
    }
    private func buildMonitor() {
        monitor.backgroundColor = .black; monitor.clipsToBounds = true; monitor.accessibilityIdentifier = "workspace.program.monitor"
        centrePanel.addSubview(monitor); addChild(playerController); monitor.addSubview(playerController.view); playerController.didMove(toParent: self)
        emptyMonitor.textAlignment = .center; emptyMonitor.textColor = MobileTheme.secondary; monitor.addSubview(emptyMonitor)
        transport.backgroundColor = MobileTheme.top; centrePanel.addSubview(transport); transport.addSubview(programTitle)
        playButton = action("Play", symbol: "play.fill", id: "transport.play") { [weak self] in self?.playPause() }
        stopButton = action("Stop", symbol: "stop.fill", id: "transport.stop") { [weak self] in self?.stop() }
        backButton = action("", symbol: "backward.end", id: "transport.previous.frame") { [weak self] in self?.step(-1) }
        nextButton = action("", symbol: "forward.end", id: "transport.next.frame") { [weak self] in self?.step(1) }
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); timeLabel.textColor = .white
        timeLabel.accessibilityIdentifier = "transport.timecode"; timeLabel.textAlignment = .right
        for item in [backButton!, playButton!, stopButton!, nextButton!, timeLabel] { transport.addSubview(item) }
        seek.isHidden = true
    }
    private func buildTimeline() {
        timeline.accessibilityIdentifier = "workspace.timeline"; centrePanel.addSubview(timeline)
        timelineToolbar.showsHorizontalScrollIndicator = false; timelineToolbar.backgroundColor = MobileTheme.panel
        centrePanel.addSubview(timelineToolbar)
        timelineButtons = [action("Select", symbol: "cursorarrow", id: "timeline.select.tool") { [weak self] in self?.timeline.blade = false; self?.refreshTools() },
                           action("Blade", symbol: "scissors", id: "timeline.blade.tool") { [weak self] in self?.timeline.blade = true; self?.refreshTools() },
                           action("Split", id: "timeline.split") { [weak self] in self?.splitAtPlayhead() },
                           action("−", id: "timeline.zoom.out") { [weak self] in self?.timeline.zoom(0.75) },
                           action("Fit", id: "timeline.zoom.fit") { [weak self] in self?.timeline.fit() },
                           action("+", id: "timeline.zoom.in") { [weak self] in self?.timeline.zoom(1.33) }]
        timelineButtons.forEach { timelineToolbar.addSubview($0) }
        timeline.onSelect = { [weak self] index, seconds in self?.selected = index; self?.seekTo(seconds); self?.refresh() }
        timeline.onSeek = { [weak self] seconds in self?.seekTo(seconds) }
        timeline.onMove = { [weak self] index, destination in
            guard let self, self.canEdit, index != destination else { return }
            let id = self.project.clips[index].id; self.change { $0.move(index, to: destination) }
            self.selected = self.project.clips.firstIndex { $0.id == id }; self.refresh()
        }
        timeline.onSplit = { [weak self] index, seconds in self?.split(index, local: seconds) }
        timeline.onTrim = { [weak self] index, begin, finish in
            guard let self, self.canEdit else { return }; do {
                var next = self.project; try next.trim(index, start: begin, end: finish)
                self.history.record(self.project); self.project = next; self.selected = index; self.saveWorking(); self.refresh(); self.rebuildPreview()
            } catch { self.error(error) }
        }
    }
    private func buildInspector() {
        inspectorPanel.accessibilityIdentifier = "workspace.inspector"; inspectorPanel.addSubview(inspectorTitle)
        inspectorPanel.addSubview(inspectorScroll); inspectorScroll.addSubview(inspectorContent); inspectorScroll.alwaysBounceVertical = true
        clipLabel.font = .systemFont(ofSize: 13, weight: .semibold); clipLabel.textColor = .white; clipLabel.numberOfLines = 2
        addInspector(clipLabel, height: 48)
        for label in [startLabel, endLabel] { label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); label.textColor = MobileTheme.secondary }
        for slider in [start, end] {
            slider.tintColor = MobileTheme.accent; slider.addTarget(self, action: #selector(trimPreview(_:)), for: .valueChanged)
            slider.addTarget(self, action: #selector(commitTrim(_:)), for: [.touchUpInside, .touchUpOutside])
        }
        for pair in [(startLabel as UIView, CGFloat(24)), (start as UIView, 44), (endLabel as UIView, 24), (end as UIView, 44)] { addInspector(pair.0, height: pair.1); trimViews.append(pair.0) }
        let trim = action("Set trim…", symbol: "scissors", id: "clip.trim") { [weak self] in self?.numericTrim() }
        addInspector(trim, height: 44); trimViews.append(trim); clipActions.append(trim)
        let motionTitle = section("MOTION & OPACITY"); motionViews.append(motionTitle)
        property("positionX", "Position X", range: -2...2, group: &motionViews)
        property("positionY", "Position Y", range: -2...2, group: &motionViews)
        property("scale", "Scale / Zoom", range: 0.05...10, multiplier: 100, group: &motionViews)
        property("rotation", "Rotation", range: -360...360, group: &motionViews)
        property("opacity", "Opacity", range: 0...1, multiplier: 100, group: &motionViews)
        let colourTitle = section("PRIMARY COLOUR"); colourViews.append(colourTitle)
        property("brightness", "Brightness", range: -1...1, group: &colourViews)
        property("contrast", "Contrast", range: 0...4, multiplier: 100, group: &colourViews)
        property("saturation", "Saturation", range: 0...4, multiplier: 100, group: &colourViews)
        animationPanel.onProperty = { [weak self] property in self?.animationProperty = property; self?.refreshAnimationControls() }
        animationPanel.onInterpolation = { [weak self] interpolation in self?.setKeyframeInterpolation(interpolation) }
        animationPanel.onAuto = { [weak self] in guard let self else { return }; self.autoKeyframe.toggle(); self.refreshAnimationControls() }
        animationPanel.onAdd = { [weak self] in self?.addKeyframe() }
        animationPanel.onRemove = { [weak self] in self?.removeKeyframe() }
        animationPanel.onClear = { [weak self] in self?.clearKeyframeTrack() }
        animationPanel.onPrevious = { [weak self] in self?.navigateKeyframe(-1) }
        animationPanel.onNext = { [weak self] in self?.navigateKeyframe(1) }
        animationPanel.track.onSeek = { [weak self] seconds in self?.seekSelectedSource(seconds) }
        addInspector(animationPanel, height: 430)
        let actions: [(String, String, String, () -> Void)] = [
            ("Duplicate", "plus.square.on.square", "clip.duplicate", { [weak self] in self?.duplicateClip() }),
            ("Delete clip", "trash", "clip.delete", { [weak self] in self?.removeClip() }),
            ("Reset properties", "arrow.counterclockwise", "clip.reset.properties", { [weak self] in self?.resetProperties() })]
        for (title, symbol, id, handler) in actions {
            let button = action(title, symbol: symbol, id: id, handler); addInspector(button, height: 44); clipActions.append(button)
        }
        let instructions = MobileTheme.label("◆ adds a keyframe at the playhead. Adjusting an animated property adds or updates its key there. Tap diamonds to seek; pinch the animation lane to zoom. Curves stay attached to source time when clips are split, moved or trimmed. V1 and A1 remain linked.", size: 11)
        instructions.textColor = MobileTheme.secondary; instructions.numberOfLines = 0; addInspector(instructions, height: 120)
    }
    private func addInspector(_ item: UIView, height: CGFloat) { inspectorContent.addSubview(item); inspectorItems.append((item, height)) }
    private func section(_ title: String) -> UILabel { let label = MobileTheme.label(title, size: 10, weight: .bold); label.textColor = MobileTheme.secondary; addInspector(label, height: 32); return label }
    private func property(_ key: String, _ title: String, range: ClosedRange<Double>, multiplier: Double = 1, group: inout [UIView]) {
        let row = MobilePropertyRow(key: key, title: title, range: range, multiplier: multiplier); rows[key] = row
        row.accessibilityIdentifier = "property.\(key)"; row.slider.accessibilityIdentifier = "property.\(key).slider"
        row.onBegin = { [weak self] in
            guard let self, self.canEdit else { return }; self.propertyBefore = self.project; self.propertySourceTime = self.selectedSourceTime
            if self.autoKeyframe || self.selected.flatMap({ self.project.clips.indices.contains($0) ? self.project.clips[$0].effects.keyframes[key] : nil }) != nil {
                self.player.pause(); self.pendingPlay = false
            }
        }
        row.onChange = { [weak self] key, value, ended in self?.changeProperty(key, value: value, ended: ended) }
        row.onNumeric = { [weak self] key in self?.numericProperty(key) }
        row.onKeyframe = { [weak self] key in guard let self, let property = MobileEffectProperty(rawValue: key) else { return }; self.animationProperty = property; self.addKeyframe() }
        addInspector(row, height: 44); group.append(row)
    }
    private func buildNavigation() {
        navigation.backgroundColor = MobileTheme.top; workspace.addSubview(navigation)
        for name in ["Edit", "Effects", "Colour", "Media", "Inspector"] {
            let button = action(name, id: "workspace.page.\(name.lowercased())") { [weak self] in self?.selectPage(name) }
            navButtons.append(button); navigation.addSubview(button)
        }
    }
    private func buildAccountOverlay() {
        accountOverlay.backgroundColor = MobileTheme.window.withAlphaComponent(0.97)
        accountOverlay.accessibilityIdentifier = "account.locked.workspace"; workspace.addSubview(accountOverlay)
        accountStatus.textColor = MobileTheme.secondary; accountStatus.font = .systemFont(ofSize: 13); accountStatus.numberOfLines = 0
        let heading = MobileTheme.label("Your NetVista account", size: 20, weight: .semibold); heading.tag = 801
        let login = action("Sign in", symbol: "person.crop.circle", id: "account.sign.in") { [weak self] in self?.signIn() }; login.tag = 802
        let create = action("Create account", id: "account.create") { [weak self] in self?.openAccountWebsite() }; create.tag = 803
        for item in [heading, accountStatus, login, create] { accountOverlay.addSubview(item) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets, width = view.bounds.width, available = max(1, view.bounds.height - safe.top - safe.bottom)
        let compactHeader = width < 900
        let headerHeight: CGFloat = compactHeader && !homeVisible && available > 420 ? 90 : 56
        header.frame = CGRect(x: 0, y: safe.top, width: width, height: headerHeight)
        brand.frame = CGRect(x: 12, y: 10, width: 166, height: 36); logo.frame = CGRect(x: 0, y: 4, width: 28, height: 28)
        wordmark.frame = CGRect(x: 36, y: 2, width: 80, height: 32); studio.frame = CGRect(x: 119, y: 2, width: 47, height: 32)
        homeButton.frame = CGRect(x: 186, y: 6, width: compactHeader ? 44 : 98, height: 44)
        homeButton.setTitle(compactHeader ? "" : "Studio Home", for: .normal); homeButton.isHidden = homeVisible
        menuButton.frame = CGRect(x: width - 56, y: 6, width: 44, height: 44); menuButton.setTitle("", for: .normal)
        menuButton.isHidden = !compactHeader
        for button in headerButtons { button.isHidden = compactHeader || homeVisible }
        if homeVisible && !compactHeader {
            headerButtons[2].isHidden = false
            headerButtons[2].frame = CGRect(x: width - 156, y: 6, width: 94, height: 44)
            menuButton.isHidden = false
        }
        if compactHeader {
            titleField.frame = headerHeight > 56
                ? CGRect(x: 12, y: 54, width: max(1, width - 24), height: 30)
                : CGRect(x: 234, y: 13, width: max(1, width - 296), height: 30)
            titleField.isHidden = homeVisible
        } else {
            var x = width - 440
            for (index, button) in headerButtons.enumerated() where !homeVisible {
                let buttonWidth: CGFloat = index < 2 ? 44 : index == 2 ? 88 : 72
                button.frame = CGRect(x: x, y: 6, width: buttonWidth, height: 44); x += buttonWidth + 5
                if index < 2 { button.setTitle("", for: .normal) }
            }
            titleField.frame = CGRect(x: homeVisible ? 188 : 292, y: 13, width: max(120, width - (homeVisible ? 648 : 752)), height: 30)
            titleField.isHidden = homeVisible
        }
        status.frame = CGRect(x: 12, y: view.bounds.height - safe.bottom - 22, width: width - 24, height: 20)
        let contentFrame = CGRect(x: safe.left, y: safe.top + headerHeight, width: width - safe.left - safe.right, height: max(1, available - headerHeight - 22))
        workspace.frame = contentFrame; home.frame = contentFrame
        layoutHome(); layoutWorkspace()
    }
    private func layoutHome() {
        let width = home.bounds.width, margin: CGFloat = width < 600 ? 20 : 44, contentWidth = max(1, min(1100, width - margin * 2))
        let x = (width - contentWidth) / 2
        homeTitle.frame = CGRect(x: x, y: 30, width: contentWidth, height: 40)
        homeTitle.font = .systemFont(ofSize: width < 420 ? 24 : 27, weight: .semibold)
        homeSubtitle.frame = CGRect(x: x, y: 76, width: contentWidth, height: 32); homeSubtitle.numberOfLines = 2
        let imageHeight = min(350, max(180, contentWidth * 0.43))
        hero.frame = CGRect(x: x, y: 130, width: contentWidth, height: imageHeight + 138)
        heroPhoto.frame = CGRect(x: 0, y: 0, width: contentWidth, height: imageHeight)
        heroTitle.frame = CGRect(x: 18, y: imageHeight + 14, width: contentWidth - 36, height: 30)
        heroDetails.frame = CGRect(x: 18, y: imageHeight + 46, width: contentWidth - 36, height: 34)
        openEditorButton.frame = CGRect(x: 18, y: imageHeight + 84, width: 140, height: 44)
        let bottom = hero.frame.maxY
        homeLimits.frame = CGRect(x: x, y: bottom + 16, width: contentWidth, height: 62)
        recentTitle.frame = CGRect(x: x, y: bottom + 92, width: contentWidth, height: 26)
        recentDetails.frame = CGRect(x: x, y: bottom + 124, width: contentWidth, height: 24)
        continueButton.frame = CGRect(x: x, y: bottom + 160, width: 164, height: 44)
        home.contentSize = CGSize(width: width, height: bottom + 224)
    }
    private func layoutWorkspace() {
        let width = workspace.bounds.width, height = workspace.bounds.height, wide = width >= 1000
        let navigationHeight: CGFloat = 44
        navigation.frame = CGRect(x: 0, y: height - navigationHeight, width: width, height: navigationHeight)
        let visibleNav = wide ? Array(navButtons.prefix(3)) : navButtons
        let navWidth = min(110, width / CGFloat(visibleNav.count))
        for button in navButtons { button.isHidden = !visibleNav.contains(button) }
        for (index, button) in visibleNav.enumerated() { button.frame = CGRect(x: CGFloat(index) * navWidth, y: 0, width: navWidth, height: 44) }
        let bodyHeight = max(1, height - navigationHeight)
        let left: CGFloat = wide ? 210 : 0, right: CGFloat = wide ? 260 : 0
        let phoneDock = !wide && width < 600 && bodyHeight > width && drawer != nil
        let dockHeight: CGFloat = phoneDock ? max(160, bodyHeight * 0.52) : 0
        let landscapePhone = !wide && bodyHeight < 340 && width >= 500
        centrePanel.frame = CGRect(x: left, y: 0, width: max(1, width - left - right), height: bodyHeight)
        mediaPanel.isHidden = !wide && drawer != "Media"; inspectorPanel.isHidden = !wide && drawer != "Inspector"
        let drawerWidth = phoneDock ? width : wide ? right : landscapePhone ? min(320, width / 2) : min(320, width * 0.86)
        let panelY: CGFloat = phoneDock ? bodyHeight - dockHeight : 0
        let panelHeight: CGFloat = phoneDock ? dockHeight : bodyHeight
        let mediaWidth = phoneDock ? width : wide ? left : landscapePhone ? min(320, width / 2) : min(320, width * 0.86)
        mediaPanel.frame = CGRect(x: landscapePhone ? width - mediaWidth : 0, y: panelY, width: mediaWidth, height: panelHeight)
        inspectorPanel.frame = CGRect(x: width - drawerWidth, y: panelY, width: drawerWidth, height: panelHeight)
        let centreWidth = centrePanel.bounds.width
        let shortLandscape = bodyHeight < 340 && centreWidth >= 500
        let monitorWidth = shortLandscape ? max(230, centreWidth * 0.43) : centreWidth
        let timelineHeight = min(224, max(160, bodyHeight * (width < 600 ? 0.37 : 0.34)))
        let monitorHeight = phoneDock ? max(72, bodyHeight - dockHeight - 44) : shortLandscape ? max(1, bodyHeight - 44) : max(72, bodyHeight - timelineHeight - 88)
        monitor.frame = CGRect(x: 0, y: 0, width: monitorWidth, height: monitorHeight)
        playerController.view.frame = monitor.bounds; emptyMonitor.frame = monitor.bounds
        transport.frame = CGRect(x: 0, y: monitorHeight, width: monitorWidth, height: 44)
        programTitle.isHidden = monitorWidth < 560; programTitle.frame = CGRect(x: 12, y: 0, width: 140, height: 44)
        let begin: CGFloat = monitorWidth >= 560 ? 152 : 4
        backButton.frame = CGRect(x: begin, y: 0, width: 44, height: 44)
        playButton.frame = CGRect(x: begin + 46, y: 0, width: 64, height: 44)
        stopButton.frame = CGRect(x: begin + 112, y: 0, width: 64, height: 44)
        nextButton.frame = CGRect(x: begin + 178, y: 0, width: 44, height: 44)
        timeLabel.frame = CGRect(x: begin + 226, y: 0, width: max(1, monitorWidth - begin - 234), height: 44)
        if monitorWidth < 450 { timeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium) }
        backButton.isHidden = monitorWidth < 330; nextButton.isHidden = monitorWidth < 330
        if monitorWidth < 330 {
            playButton.frame = CGRect(x: 4, y: 0, width: 64, height: 44)
            stopButton.frame = CGRect(x: 70, y: 0, width: 64, height: 44)
            timeLabel.frame = CGRect(x: 140, y: 0, width: max(1, monitorWidth - 148), height: 44)
        }
        // Landscape phones need the monitor and timeline side by side: stacking
        // them into a 200pt-high safe area leaves only a few pixels for clips.
        let timelineX: CGFloat = shortLandscape ? monitorWidth : 0
        let timelineY: CGFloat = shortLandscape ? 0 : monitorHeight + 44
        let timelineWidth = centreWidth - timelineX
        timelineToolbar.frame = CGRect(x: timelineX, y: timelineY, width: timelineWidth, height: 44)
        var toolbarX: CGFloat = 6
        for (index, button) in timelineButtons.enumerated() { let w: CGFloat = index < 3 ? 72 : 44; button.frame = CGRect(x: toolbarX, y: 0, width: w, height: 44); toolbarX += w + 4 }
        timelineToolbar.contentSize = CGSize(width: toolbarX, height: 44)
        timeline.frame = CGRect(x: timelineX, y: timelineY + 44, width: timelineWidth, height: max(1, bodyHeight - timelineY - 44))
        timeline.isHidden = phoneDock; timelineToolbar.isHidden = phoneDock
        layoutMedia(); layoutInspector()
        if !wide { if drawer == "Media" { workspace.bringSubviewToFront(mediaPanel) }; if drawer == "Inspector" { workspace.bringSubviewToFront(inspectorPanel) } }
        workspace.bringSubviewToFront(navigation)
        accountOverlay.frame = CGRect(x: 0, y: 0, width: width, height: bodyHeight)
        let cardWidth = min(420, max(1, width - 40)), cardX = (width - cardWidth) / 2, cardY = max(20, bodyHeight / 2 - 130)
        accountOverlay.viewWithTag(801)?.frame = CGRect(x: cardX, y: cardY, width: cardWidth, height: 40)
        accountStatus.frame = CGRect(x: cardX, y: cardY + 48, width: cardWidth, height: 66)
        accountOverlay.viewWithTag(802)?.frame = CGRect(x: cardX, y: cardY + 122, width: cardWidth, height: 44)
        accountOverlay.viewWithTag(803)?.frame = CGRect(x: cardX, y: cardY + 174, width: cardWidth, height: 44)
        if !accountOverlay.isHidden { workspace.bringSubviewToFront(accountOverlay) }
    }
    private func layoutMedia() {
        let w = mediaPanel.bounds.width, h = mediaPanel.bounds.height
        poolTitle.frame = CGRect(x: 12, y: 0, width: max(1, w - 94), height: 44); importButton.frame = CGRect(x: w - 82, y: 0, width: 76, height: 44)
        poolTable.frame = CGRect(x: 0, y: 45, width: w, height: max(1, h - 97))
        addButton.frame = CGRect(x: 6, y: h - 48, width: max(1, w - 88), height: 44); addAllButton.frame = CGRect(x: w - 76, y: h - 48, width: 70, height: 44)
    }
    private func layoutInspector() {
        inspectorTitle.text = page == "Colour" ? "COLOUR" : page == "Effects" ? "EFFECT CONTROLS" : "INSPECTOR"
        inspectorTitle.frame = CGRect(x: 12, y: 0, width: inspectorPanel.bounds.width - 24, height: 44)
        inspectorScroll.frame = CGRect(x: 0, y: 44, width: inspectorPanel.bounds.width, height: max(1, inspectorPanel.bounds.height - 44))
        for item in trimViews { item.isHidden = page != "Edit" }
        for item in motionViews { item.isHidden = page == "Colour" }
        for item in colourViews { item.isHidden = page != "Colour" }
        var y: CGFloat = 4
        for (item, height) in inspectorItems where !item.isHidden { item.frame = CGRect(x: 12, y: y, width: max(1, inspectorPanel.bounds.width - 24), height: height); y += height + 4 }
        inspectorContent.frame = CGRect(x: 0, y: 0, width: inspectorPanel.bounds.width, height: y + 12)
        inspectorScroll.contentSize = inspectorContent.bounds.size
    }

    func showHome() { homeVisible = true; home.isHidden = false; workspace.isHidden = true; pendingPlay = false; player.pause(); refresh(); view.setNeedsLayout() }
    func openWorkspace() { homeVisible = false; home.isHidden = true; workspace.isHidden = false; refresh(); view.setNeedsLayout() }
    func selectPage(_ name: String) {
        if name == "Media" || name == "Inspector" { drawer = drawer == name ? nil : name }
        else { page = name; drawer = view.bounds.width < 1000 && name != "Edit" ? "Inspector" : nil }
        refreshTools(); view.setNeedsLayout()
    }
    private func showMenu() {
        let menu = UIAlertController(title: "NetVista Studio", message: nil, preferredStyle: .actionSheet)
        for (title, body) in [("Studio Home", { [weak self] in self?.showHome() }), ("New movie", { [weak self] in self?.newProject() }),
                              ("Open project", { [weak self] in self?.openProject() }), ("Save project", { [weak self] in self?.saveProject() }),
                              ("Export movie", { [weak self] in self?.exportAction() }), ("Undo", { [weak self] in self?.undoAction() }),
                              ("Redo", { [weak self] in self?.redoAction() }), ("Previous frame", { [weak self] in self?.step(-1) }),
                              ("Next frame", { [weak self] in self?.step(1) }), ("Account", { [weak self] in self?.accountAction() })] {
            menu.addAction(UIAlertAction(title: title, style: .default) { _ in body() })
        }
        menu.addAction(UIAlertAction(title: "Cancel", style: .cancel)); menu.popoverPresentationController?.sourceView = menuButton
        menu.popoverPresentationController?.sourceRect = menuButton.bounds; present(menu, animated: true)
    }
    override func refresh() {
        super.refresh()
        if let selectedSource, !project.library.indices.contains(selectedSource) { self.selectedSource = nil }
        timeline.project = project; timeline.selected = selected; timeline.canEdit = canEdit
        emptyMonitor.isHidden = !project.clips.isEmpty && previewUnavailableMessage == nil
        emptyMonitor.text = previewUnavailableMessage ?? "Import media to start editing"; poolTable.reloadData()
        let effects = selected.flatMap { project.clips.indices.contains($0) ? project.clips[$0].effects : nil }
        refreshAnimationControls()
        for button in clipActions { button.isEnabled = selected != nil && canEdit }
        for slider in [start, end] { slider.isEnabled = effects != nil && canEdit }
        playButton.isEnabled = canEdit && !project.clips.isEmpty
        addButton.isEnabled = selectedSource != nil && canEdit; addAllButton.isEnabled = !project.library.isEmpty && canEdit
        importButton.isEnabled = canEdit; titleField.isEnabled = canEdit
        headerButtons.first?.isEnabled = canEdit && !history.undo.isEmpty; headerButtons[1].isEnabled = canEdit && !history.redo.isEmpty
        headerButtons[3].isEnabled = canEdit; headerButtons[4].isEnabled = !importing && !exporting
        headerButtons[5].isEnabled = canEdit && !project.clips.isEmpty
        recentDetails.text = "\(project.name) · \(project.clips.count) clips · \(clock(project.totalDuration))"
        continueButton.isEnabled = !project.clips.isEmpty
        refreshTools(); layoutInspector()
    }
    override func refreshAccount() { super.refreshAccount(); refresh(); view.setNeedsLayout() }
    override func playbackTimeChanged(_ seconds: Double) {
        timeline.time = seconds; if player.rate > 0 { timeline.revealPlayhead() }
        refreshAnimationControls()
        if transport.bounds.width < 560 { timeLabel.text = clock(seconds) }
        let playing = player.rate > 0 || pendingPlay
        playButton?.setTitle(playing ? "Pause" : "Play", for: .normal)
        playButton?.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)), for: .normal)
    }
    override func previewStateChanged(_ text: String?) {
        previewUnavailableMessage = text
        emptyMonitor.text = text ?? "Import media to start editing"; emptyMonitor.numberOfLines = 2
        emptyMonitor.isHidden = text == nil && !project.clips.isEmpty
    }
    override func selectedClipChanged() {
        guard let selected, project.clips.indices.contains(selected) else { return }
        if drawer == "Media" { drawer = nil; view.setNeedsLayout() }
        let begin = project.clips.prefix(selected).reduce(0) { $0 + $1.length }
        seekTo(begin + min(1.0 / 30, project.clips[selected].length / 2))
        timeline.revealPlayhead()
    }
    private func refreshTools() {
        guard !timelineButtons.isEmpty else { return }
        timelineButtons[0].backgroundColor = timeline.blade ? MobileTheme.control : MobileTheme.video
        timelineButtons[1].backgroundColor = timeline.blade ? MobileTheme.video : MobileTheme.control
        timelineButtons[2].isEnabled = selected != nil && canEdit
        for button in navButtons { button.backgroundColor = button.currentTitle == page || button.currentTitle == drawer ? MobileTheme.control : MobileTheme.top }
    }
    private func seekTo(_ value: Double) { let seconds = min(project.totalDuration, max(0, value)); player.pause(); seek.value = Float(seconds); playbackTimeChanged(seconds); scrub() }
    private func stop() { seekTo(0) }
    private func step(_ frames: Double) { seekTo(previewTargetTime + frames / 30) }
    private func splitAtPlayhead() {
        guard let index = selected else { return }; let start = project.clips.prefix(index).reduce(0) { $0 + $1.length }
        split(index, local: previewTargetTime - start)
    }
    private func split(_ index: Int, local seconds: Double) {
        guard canEdit else { return }; do {
            var next = project; try next.split(index, at: seconds); history.record(project); project = next; selected = index + 1
            saveWorking(); refresh(); rebuildPreview()
        } catch { alert("Choose a point inside the clip", "Leave at least one frame on each side of the cut. Scrub the ruler, then press Split, or tap inside a clip with the Blade tool.") }
    }
    private func addSource() { guard canEdit, let selectedSource, project.library.indices.contains(selectedSource) else { return }; addSources([project.library[selectedSource]]) }
    private func addAllSources() { guard canEdit else { return }; addSources(project.library) }
    private func addSources(_ sources: [MobileClip]) {
        guard !sources.isEmpty else { return }; let start = project.clips.count
        change { project in project.clips.append(contentsOf: sources.map { original in var clip = original; clip.id = UUID(); return clip }) }
        selected = start; refresh(); selectedClipChanged()
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { project.library.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "source") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "source")
        let source = project.library[indexPath.row]; cell.backgroundColor = indexPath.row == selectedSource ? MobileTheme.control : MobileTheme.panel
        cell.textLabel?.text = source.name; cell.textLabel?.font = .systemFont(ofSize: 12, weight: .medium); cell.textLabel?.textColor = .white
        cell.detailTextLabel?.text = "\(String(format: "%.2f", source.duration)) seconds · Video"; cell.detailTextLabel?.textColor = MobileTheme.secondary
        cell.detailTextLabel?.font = .systemFont(ofSize: 10); cell.imageView?.image = UIImage(systemName: "film"); cell.imageView?.tintColor = MobileTheme.secondary
        cell.accessibilityIdentifier = "media.source.\(indexPath.row)"; return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { selectedSource = indexPath.row; refresh() }
    private func propertyValue(_ key: String, _ value: MobileClipEffects) -> Double {
        guard let property = MobileEffectProperty(rawValue: key) else { return 0 }; return value.value(for: property)
    }
    private func assignProperty(_ key: String, value: Double, effects: inout MobileClipEffects) {
        guard let property = MobileEffectProperty(rawValue: key) else { return }; effects.setValue(value, for: property)
    }
    private var selectedSourceTime: Double {
        guard let selected, project.clips.indices.contains(selected) else { return 0 }
        let clip = project.clips[selected], begin = project.clips.prefix(selected).reduce(0) { $0 + $1.length }
        return min(clip.outPoint, max(clip.inPoint, clip.inPoint + previewTargetTime - begin))
    }
    private func refreshAnimationControls() {
        let clip = selected.flatMap { project.clips.indices.contains($0) ? project.clips[$0] : nil }
        let sourceTime = selectedSourceTime
        let evaluated = clip?.effects.evaluated(at: sourceTime) ?? MobileClipEffects()
        for (key, row) in rows {
            row.set(propertyValue(key, evaluated), enabled: clip != nil && canEdit)
            if let property = MobileEffectProperty(rawValue: key) {
                row.setAnimation(active: !(clip?.effects.frames(for: property).isEmpty ?? true),
                                 atKeyframe: clip?.effects.keyframeIndex(for: property, at: sourceTime) != nil)
            }
        }
        let interpolation = clip.flatMap { value in value.effects.keyframeIndex(for: animationProperty, at: sourceTime).map { value.effects.frames(for: animationProperty)[$0].interpolation } } ?? animationInterpolation
        animationPanel.configure(clip: clip, property: animationProperty, sourceTime: sourceTime,
            interpolation: interpolation, autoKey: autoKeyframe, enabled: clip != nil && canEdit)
    }
    private func seekSelectedSource(_ seconds: Double) {
        guard let selected, project.clips.indices.contains(selected) else { return }
        let clip = project.clips[selected], begin = project.clips.prefix(selected).reduce(0) { $0 + $1.length }
        seekTo(begin + min(clip.length - 1.0 / 600, max(0, seconds - clip.inPoint)))
    }
    private func navigateKeyframe(_ direction: Int) {
        guard let selected, project.clips.indices.contains(selected) else { return }; let clip = project.clips[selected]
        let time = selectedSourceTime
        let frames = clip.effects.frames(for: animationProperty).filter { $0.sourceSeconds >= clip.inPoint && $0.sourceSeconds <= clip.outPoint }
        let next = direction < 0 ? frames.last(where: { $0.sourceSeconds < time - 1.0 / 600 }) : frames.first(where: { $0.sourceSeconds > time + 1.0 / 600 })
        if let next { seekSelectedSource(next.sourceSeconds) }
    }
    private func applyAnimatedEffects(_ effects: MobileClipEffects) {
        guard canEdit, let selected, project.clips.indices.contains(selected), effects != project.clips[selected].effects else { return }
        guard (try? effects.validate(duration: project.clips[selected].duration)) != nil else { return }
        history.record(project); project.clips[selected].effects = effects
        updateEffectPreview(ended: true); saveWorking(); refresh()
    }
    private func addKeyframe() {
        guard canEdit, let selected, project.clips.indices.contains(selected) else { return }
        var effects = project.clips[selected].effects
        let value = Double(rows[animationProperty.rawValue]?.slider.value ?? Float(effects.value(for: animationProperty, at: selectedSourceTime)))
        let interpolation = effects.keyframeIndex(for: animationProperty, at: selectedSourceTime).map { effects.frames(for: animationProperty)[$0].interpolation } ?? animationInterpolation
        do { try effects.upsertKeyframe(for: animationProperty, at: selectedSourceTime, value: value, interpolation: interpolation); applyAnimatedEffects(effects) }
        catch { self.error(error) }
    }
    private func removeKeyframe() {
        guard canEdit, let selected, project.clips.indices.contains(selected) else { return }
        var effects = project.clips[selected].effects
        // Keep the visible value if removing the final key disables animation.
        effects.setValue(effects.value(for: animationProperty, at: selectedSourceTime), for: animationProperty)
        effects.removeKeyframe(for: animationProperty, at: selectedSourceTime); applyAnimatedEffects(effects)
    }
    private func clearKeyframeTrack() {
        guard canEdit, let selected, project.clips.indices.contains(selected) else { return }
        let dialog = UIAlertController(title: "Clear \(animationProperty.title) animation?", message: "All keys for this property will be removed. The current visible value will remain. Undo can restore the curve.", preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let id = project.clips[selected].id, property = animationProperty
        dialog.addAction(UIAlertAction(title: "Clear track", style: .destructive) { [weak self] _ in
            guard let self, let current = self.selected, self.project.clips.indices.contains(current), self.project.clips[current].id == id else { return }
            var effects = self.project.clips[current].effects
            effects.setValue(effects.value(for: property, at: self.selectedSourceTime), for: property)
            effects.keyframes.removeValue(forKey: property.rawValue); self.applyAnimatedEffects(effects)
        }); present(dialog, animated: true)
    }
    private func setKeyframeInterpolation(_ interpolation: MobileKeyframeInterpolation) {
        animationInterpolation = interpolation
        guard canEdit, let selected, project.clips.indices.contains(selected) else { refreshAnimationControls(); return }
        var effects = project.clips[selected].effects
        guard let index = effects.keyframeIndex(for: animationProperty, at: selectedSourceTime) else { refreshAnimationControls(); return }
        var track = effects.frames(for: animationProperty); track[index].interpolation = interpolation
        effects.keyframes[animationProperty.rawValue] = track; applyAnimatedEffects(effects)
    }
    private func changeProperty(_ key: String, value: Double, ended: Bool) {
        guard canEdit, let selected, project.clips.indices.contains(selected) else { propertyBefore = nil; propertySourceTime = nil; refresh(); return }
        if propertyBefore == nil { propertyBefore = project; propertySourceTime = selectedSourceTime }
        var effects = project.clips[selected].effects; assignProperty(key, value: value, effects: &effects)
        if let property = MobileEffectProperty(rawValue: key), autoKeyframe || !effects.frames(for: property).isEmpty {
            let sourceTime = propertySourceTime ?? selectedSourceTime
            let interpolation = effects.keyframeIndex(for: property, at: sourceTime).map { effects.frames(for: property)[$0].interpolation } ?? animationInterpolation
            do { try effects.upsertKeyframe(for: property, at: sourceTime, value: value, interpolation: interpolation) }
            catch { self.error(error); return }
            animationProperty = property
        }
        guard (try? effects.validate(duration: project.clips[selected].duration)) != nil else { return }
        project.clips[selected].effects = effects
        updateEffectPreview(ended: ended)
        if ended { if let before = propertyBefore, before != project { history.record(before) }; propertyBefore = nil; propertySourceTime = nil; saveWorking(); refresh() }
        else { refreshAnimationControls() }
    }
    private func updateEffectPreview(ended: Bool) {
        guard let selected, project.clips.indices.contains(selected) else { return }
        let effects = project.clips[selected].effects
        currentSequence?.updateEffects(id: project.clips[selected].id, effects: effects)
        propertySeekGeneration += 1; let ticket = propertySeekGeneration
        propertySeekTask?.cancel()
        if usingCompatibilityPreview {
            cancelPreviewWork(); previewBuilding = true
            propertySeekTask = Task { [weak self] in
                if !ended { try? await Task.sleep(nanoseconds: 120_000_000) }
                guard let self, !Task.isCancelled, ticket == self.propertySeekGeneration else { return }
                self.rebuildPreview()
            }
        } else {
            propertySeekTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard let self, !Task.isCancelled, ticket == self.propertySeekGeneration else { return }
                if self.player.rate == 0, let item = self.player.currentItem, let sequence = self.currentSequence {
                    item.videoComposition = sequence.videoComposition.mutableCopy() as? AVVideoComposition
                    await self.player.seek(to: self.player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }
    private func numericProperty(_ key: String) {
        guard canEdit, let selected, let row = rows[key] else { return }
        let dialog = UIAlertController(title: row.slider.accessibilityLabel, message: "\(String(format: "%.1f", Double(row.slider.minimumValue) * row.multiplier)) – \(String(format: "%.1f", Double(row.slider.maximumValue) * row.multiplier))", preferredStyle: .alert)
        dialog.addTextField { field in field.text = String(format: "%.2f", self.propertyValue(key, self.project.clips[selected].effects.evaluated(at: self.selectedSourceTime)) * row.multiplier); field.keyboardType = .numbersAndPunctuation }
        dialog.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        dialog.addAction(UIAlertAction(title: "Apply", style: .default) { [weak self] _ in
            guard let self, let value = Double(dialog.textFields?.first?.text ?? ""), value.isFinite,
                  value / row.multiplier >= Double(row.slider.minimumValue), value / row.multiplier <= Double(row.slider.maximumValue) else { return }
            self.changeProperty(key, value: value / row.multiplier, ended: true)
        }); present(dialog, animated: true)
    }
    private func resetProperties() { guard canEdit, let selected else { return }; change { $0.clips[selected].effects = MobileClipEffects() } }
}
