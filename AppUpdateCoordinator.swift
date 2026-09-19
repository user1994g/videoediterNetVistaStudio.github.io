import Cocoa

/// One updater for Home, the Video Editor and the application menu.
/// Network callbacks only change UI on the main queue.
final class AppUpdateCoordinator: NSObject {
    private let service = AppUpdateService()
    var hostWindow: (() -> NSWindow?)?
    var prepareRecovery: (() throws -> URL)?
    var canRestart: (() -> String?)?
    var onStateChanged: ((String,Bool) -> Void)?
    private var checking = false
    private var pending: NetVistaAvailableUpdate?
    private var dismissedTags = Set<String>()
    private var transfer: NetVistaUpdateDownload?
    private var job: URL?
    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var cancelButton: NSButton?
    private var installing = false
    private var cancellationRequested = false
    private var timer: Timer?
    private var promptShowing = false
    private(set) var handedOff = false
    var busy: Bool { checking || installing }

    func start() {
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in self?.check(manual:false) }
        timer = Timer.scheduledTimer(withTimeInterval:6*60*60,repeats:true) { [weak self] _ in self?.check(manual:false) }
    }
    func check(manual: Bool = true) {
        guard !checking, !installing, !promptShowing else { progressWindow?.makeKeyAndOrderFront(nil); return }
        if let pending, manual { present(pending,manual:true); return }
        checking = true; onStateChanged?("Checking…",false)
        service.checkForUpdate { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                switch result {
                case .success(.some(let update)):
                    self.pending = update; self.onStateChanged?("Update available",true)
                    if manual || !self.dismissedTags.contains(update.release.tag) { self.present(update,manual:manual) }
                case .success(nil):
                    self.onStateChanged?("Update",true)
                    if manual { self.message("You're up to date", "NetVista Studio \(self.service.currentTag) is the newest published version for this Mac.") }
                case .failure(let error):
                    self.onStateChanged?("Update",true)
                    // A startup check stays quiet offline; manual checks explain failures.
                    if manual { self.message("Could not check for updates",error.localizedDescription) }
                }
            }
        }
    }
    private func present(_ update: NetVistaAvailableUpdate, manual: Bool) {
        guard !promptShowing, !installing else { return }
        if NSApp.modalWindow != nil || NSApp.windows.contains(where:{ $0.attachedSheet != nil }) {
            DispatchQueue.main.asyncAfter(deadline:.now()+5) { [weak self] in
                guard let self, self.pending == update, manual || !self.dismissedTags.contains(update.release.tag) else { return }
                self.present(update,manual:manual)
            }
            return
        }
        promptShowing = true
        let alert = NSAlert()
        alert.messageText = "NetVista Studio has an update"
        alert.informativeText = "Version \(update.release.tag) is available. You're using \(service.currentTag).\n\nUpdate will download the new version, preserve your open projects, and restart this app in the same location."
        alert.addButton(withTitle:"Update"); alert.addButton(withTitle:"Not right now")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let answer = alert.runModal(); promptShowing = false
        if answer == .alertFirstButtonReturn { install(update) }
        else { dismissedTags.insert(update.release.tag) }
    }
    private func install(_ update: NetVistaAvailableUpdate) {
        guard !installing else { return }
        do {
            if let reason = canRestart?() { throw NetVistaUpdateError.unsafePackage(reason) }
            let target = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            try NetVistaUpdateInstaller.checkTarget(target)
            guard NSRunningApplication.runningApplications(withBundleIdentifier:NetVistaUpdateInstaller.bundleID)
                .filter({ $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == target.path }).count <= 1 else {
                throw NetVistaUpdateError.unsafePackage("Close the other running copy of NetVista Studio before updating.")
            }
            let job = try NetVistaUpdateInstaller.makeJobDirectory()
            self.job = job; installing = true; cancellationRequested = false
            onStateChanged?("Updating…",false); showProgress()
            transfer = service.download(update,to:job,progress:{ [weak self] fraction in
                DispatchQueue.main.async {
                    self?.progressBar?.isIndeterminate = false; self?.progressBar?.doubleValue = fraction*100
                    self?.progressLabel?.stringValue = "Downloading update — \(Int(fraction*100))%"
                }
            }) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.transfer = nil
                    if self.cancellationRequested { self.finishCancelled(); return }
                    switch result {
                    case .success(let archive): self.prepare(archive:archive,update:update,job:job,target:target)
                    case .failure(let error): self.fail(error)
                    }
                }
            }
        } catch { fail(error) }
    }
    private func prepare(archive: URL, update: NetVistaAvailableUpdate, job: URL, target: URL) {
        cancelButton?.isEnabled = false
        progressLabel?.stringValue = "Preparing the new version…"
        progressBar?.isIndeterminate = true; progressBar?.startAnimation(nil)
        // Recovery is captured immediately before quit, after slow disk work.
        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { try NetVistaUpdateInstaller.prepare(archive:archive,job:job,target:target,tag:update.release.tag,recoveryManifest:nil) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                do {
                    let prepared = try result.get()
                    do {
                        if let reason = self.canRestart?() { throw NetVistaUpdateError.unsafePackage(reason) }
                        self.progressLabel?.stringValue = "Saving your open work and restarting…"
                        guard let recovery = self.prepareRecovery else { throw NetVistaUpdateError.invalidResponse }
                        let manifest = try recovery()
                        let plan = NetVistaInstallPlan(id:prepared.id,target:prepared.target,workDirectory:prepared.workDirectory,
                            jobDirectory:prepared.jobDirectory,parentPID:prepared.parentPID,expectedTag:prepared.expectedTag,recoveryManifest:manifest)
                        try JSONEncoder().encode(plan).write(to:plan.planURL,options:.atomic)
                        try NetVistaUpdateInstaller.startHelper(plan)
                        self.handedOff = true; self.closeProgress()
                        NSApp.terminate(nil)
                    } catch { NetVistaUpdateInstaller.discard(prepared); throw error }
                } catch { self.fail(error) }
            }
        }
    }
    @objc private func cancelDownload() {
        guard installing, !handedOff, cancelButton?.isEnabled == true else { return }
        cancellationRequested = true; cancelButton?.isEnabled = false
        progressLabel?.stringValue = "Cancelling…"; transfer?.cancel()
    }
    private func finishCancelled() { cleanup(); closeProgress(); installing = false; onStateChanged?("Update available",true) }
    private func fail(_ error: Error) {
        cleanup(); closeProgress(); installing = false
        onStateChanged?(pending == nil ? "Update" : "Update available",true)
        message("Could not update NetVista Studio",error.localizedDescription)
    }
    private func cleanup() {
        if let job, job.deletingLastPathComponent().path == NetVistaUpdateInstaller.cacheRoot.path {
            try? FileManager.default.removeItem(at:job)
        }
        job = nil
    }
    private func showProgress() {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:440,height:172),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "Updating NetVista Studio"; window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString:"Starting download…"); label.frame = NSRect(x:24,y:111,width:392,height:24)
        label.font = .systemFont(ofSize:14,weight:.medium)
        let bar = NSProgressIndicator(frame:NSRect(x:24,y:80,width:392,height:16)); bar.style = .bar
        bar.minValue = 0; bar.maxValue = 100; bar.isIndeterminate = true; bar.startAnimation(nil)
        let cancel = NSButton(title:"Cancel",target:self,action:#selector(cancelDownload)); cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x:321,y:20,width:96,height:32)
        window.contentView?.addSubview(label); window.contentView?.addSubview(bar); window.contentView?.addSubview(cancel)
        progressWindow = window; progressLabel = label; progressBar = bar; cancelButton = cancel
        if let host = hostWindow?(), host.isVisible { host.beginSheet(window) }
        else { window.center(); window.makeKeyAndOrderFront(nil) }
    }
    private func closeProgress() {
        if let window = progressWindow { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        progressWindow = nil; progressLabel = nil; progressBar = nil; cancelButton = nil
    }
    private func message(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.addButton(withTitle:"OK"); alert.runModal()
    }
    func mayQuit() -> Bool {
        if handedOff || !installing { return true }
        progressWindow?.makeKeyAndOrderFront(nil)
        return false
    }
}
