import Cocoa

/// A native, optional assistant. Opening this window does not contact a
/// service, install software or download a model. The app manages the optional
/// model file and runs its bundled CPU helper locally after explicit opt-in.
final class ModelingAssistController: NSViewController {
    private let context: () -> ModelingAIContext
    private let stamp: () -> String
    private let apply: (ModelingAIPlan) throws -> Void
    private let service: ModelingAI
    private let statusLabel = NSTextField(wrappingLabelWithString:"")
    private let progress = NSProgressIndicator()
    private let prompt = NSTextView(), result = NSTextView()
    private var check: GameButton!, download: GameButton!, generate: GameButton!, accept: GameButton!, cancel: GameButton!, remove: GameButton!, dismiss: GameButton!
    private var observer: NSObjectProtocol?
    private var pending: ModelingAIPlan?
    private var pendingStamp = ""
    private var pendingContext = ModelingAIContext()
    private var generation = UUID()

    #if MODELING_TOOLS_CHECKS
    var downloadConfirmationForTesting: (() -> Bool)?
    var removalConfirmationForTesting: (() -> Bool)?
    #endif

    init(context:@escaping ()->ModelingAIContext,stamp:@escaping ()->String,apply:@escaping (ModelingAIPlan)throws->Void,service:ModelingAI = .shared) {
        self.context = context; self.stamp = stamp; self.apply = apply; self.service = service; super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func loadView() {
        view = NSView(frame:NSRect(x:0,y:0,width:680,height:640)); view.appearance = NSAppearance(named:.darkAqua)
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor(calibratedWhite:0.1,alpha:1).cgColor
        let scroll = GameScroll(); view.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo:view.topAnchor),scroll.bottomAnchor.constraint(equalTo:view.bottomAnchor),scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor)])
        scroll.add(gameLabel("LOCAL MODELING HELPER",strong:true))
        let intro = NSTextField(wrappingLabelWithString:"Describe a shape, then review the steps before applying. This small text model can arrange native shapes, add an editable dragon starter, subdivide or smooth a selected mesh. It is not an automatic text-to-mesh generator.")
        scroll.add(intro,fill:true)
        let requirements = NSTextField(wrappingLabelWithString:"Optional download: \(ModelingAI.modelName), about \(Self.modelSize). The local CPU runtime is already included—no separate app, account or server setup. Downloading needs internet and free disk space; afterwards your prompts and models stay on this computer. Manual modeling always works without AI.")
        requirements.font = .systemFont(ofSize:11); requirements.textColor = .secondaryLabelColor; scroll.add(requirements,fill:true)
        scroll.add(statusLabel,fill:true)
        progress.minValue = 0; progress.maxValue = 1; progress.style = .bar; scroll.add(progress,fill:true)
        check = GameButton("Check installation") { [weak self] in self?.service.checkAvailability() }
        download = GameButton("Download model…") { [weak self] in self?.confirmDownload() }
        download.bezelColor = .controlAccentColor
        cancel = GameButton("Cancel") { [weak self] in self?.generation = UUID(); self?.pending = nil; self?.accept.isEnabled = false; self?.result.string = "Cancelled. Your scene is unchanged."; self?.service.cancel() }
        scroll.add(gameRow([download,cancel]))
        remove = GameButton("Remove model…") { [weak self] in self?.confirmRemoval() }
        dismiss = GameButton("Not now") { [weak self] in guard let self, !self.service.status.isBusy else { return }; self.view.window?.close() }
        scroll.add(gameRow([check,remove,dismiss]))
        scroll.add(gameLabel("YOUR REQUEST",strong:true))
        prompt.string = "Help me make a dragon starter with parts I can sculpt."
        scroll.add(textArea(prompt,height:90,editable:true),fill:true)
        generate = GameButton("Ask local AI") { [weak self] in self?.ask() }; scroll.add(generate)
        scroll.add(gameLabel("REVIEW THE PLAN",strong:true))
        result.string = "A suggested plan will appear here. No change is made until you press Apply Plan."
        scroll.add(textArea(result,height:155,editable:false),fill:true)
        accept = GameButton("Apply Plan") { [weak self] in self?.applyPending() }; accept.isEnabled = false
        scroll.add(gameRow([accept,GameButton("Clear plan") { [weak self] in self?.generation = UUID(); self?.pending = nil; self?.accept.isEnabled = false; self?.result.string = "Plan cleared. Your model is unchanged." }]))
        let footer = NSTextField(wrappingLabelWithString:"Every plan is checked against native modeling limits and applies as one undoable operation. Generated code, commands, downloads and external assets are never executed. Built-in starters do not need AI.")
        footer.font = .systemFont(ofSize:11); footer.textColor = .secondaryLabelColor; scroll.add(footer,fill:true)
        let attribution = NSTextField(wrappingLabelWithString:ModelingAI.licenseNotice)
        attribution.font = .systemFont(ofSize:10); attribution.textColor = .secondaryLabelColor; scroll.add(attribution,fill:true)
        observer = NotificationCenter.default.addObserver(forName:ModelingAI.statusDidChange,object:service,queue:.main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    private static var modelSize: String { ByteCountFormatter.string(fromByteCount:ModelingAI.modelDownloadBytes,countStyle:.decimal) }
    private func textArea(_ text:NSTextView,height:CGFloat,editable:Bool) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        text.isRichText = false; text.isEditable = editable; text.isSelectable = true; text.font = .systemFont(ofSize:12)
        text.textContainerInset = NSSize(width:8,height:8); text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.frame = NSRect(x:0,y:0,width:600,height:height); text.minSize = NSSize(width:0,height:height); text.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.textContainer?.containerSize = NSSize(width:600,height:CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text; scroll.heightAnchor.constraint(equalToConstant:height).isActive = true; return scroll
    }
    private func refresh() {
        let state = service.status
        statusLabel.stringValue = state.message
        progress.isIndeterminate = state.progress == nil
        if let value = state.progress { progress.doubleValue = value }
        if state.isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        progress.isHidden = !state.isBusy
        check.isEnabled = !state.isBusy; download.isEnabled = state.canDownload
        download.title = state.isInstalled ? "Downloaded" : (state.phase == .failed ? "Retry download…" : "Download model…")
        remove.isEnabled = state.canRemove
        dismiss.title = state.isInstalled ? "Close" : "Not now"; dismiss.isEnabled = !state.isBusy
        generate.isEnabled = state.canGenerate; cancel.isEnabled = state.isBusy
        if !state.isInstalled && !state.isBusy { pending = nil }
        if state.isBusy { accept.isEnabled = false }
        else { accept.isEnabled = pending != nil }
    }
    private func confirmDownload() {
        guard service.status.canDownload else { return }
        #if MODELING_TOOLS_CHECKS
        if let confirmation = downloadConfirmationForTesting { if confirmation() { service.downloadModel() }; return }
        #endif
        let alert = NSAlert(); alert.messageText = "Download the optional local model?"
        alert.informativeText = "NetVista will download \(ModelingAI.modelName) (about \(Self.modelSize)) from Qwen's official model repository on Hugging Face and save it in this app's local AI model folder. Allow at least \(Self.modelSize) plus 32 MB of free disk space.\n\nThe included CPU runtime runs it on this computer. No account or separate app is needed, and your modeling prompts and 3D geometry are not uploaded. This is a planning helper, not automatic text-to-mesh generation. It is separate from the Video Editor's person-matting model."
        alert.addButton(withTitle:"Download model"); alert.addButton(withTitle:"Not now")
        if alert.runModal() == .alertFirstButtonReturn { service.downloadModel() }
    }
    private func confirmRemoval() {
        guard service.status.canRemove else { return }
        #if MODELING_TOOLS_CHECKS
        if let confirmation = removalConfirmationForTesting { if confirmation() { removeConfirmed() }; return }
        #endif
        let alert = NSAlert(); alert.messageText = "Remove the optional modeling AI model?"
        alert.informativeText = "Only NetVista's downloaded modeling model will be removed, freeing about \(Self.modelSize). Your 3D projects, manual tools and the Video Editor's separate AI model are unchanged. You can download this model again later."
        alert.addButton(withTitle:"Remove model"); alert.addButton(withTitle:"Keep model")
        if alert.runModal() == .alertFirstButtonReturn { removeConfirmed() }
    }
    private func removeConfirmed() {
        generation = UUID(); pending = nil; accept.isEnabled = false
        result.string = "Removing the optional model. Your scene is unchanged."
        service.removeModel()
    }
    private func ask() {
        let text = prompt.string.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { result.string = "Describe what you want to model first."; return }
        pending = nil; accept.isEnabled = false; pendingStamp = stamp(); pendingContext = context()
        let token = UUID(); generation = token
        result.string = "Thinking locally… your scene has not changed."
        service.propose(prompt:text,context:pendingContext) { [weak self] response in
            guard let self, self.generation == token else { return }
            switch response {
            case .success(let plan):
                guard self.pendingStamp == self.stamp(), self.pendingContext == self.context() else {
                    self.result.string = "The scene or selection changed while the helper was thinking. Ask again with the current model."; self.pending = nil; self.refresh(); return
                }
                self.pending = plan
                self.result.string = plan.title+"\n\n"+plan.explanation+"\n\n"+plan.actions.enumerated().map { "\($0.offset+1). \($0.element.summary)" }.joined(separator:"\n")
            case .failure(let error): self.result.string = error.localizedDescription
            }
            self.refresh()
        }
    }
    private func applyPending() {
        guard !service.status.isBusy else { return }
        guard let plan = pending else { return }
        guard pendingStamp == stamp(), pendingContext == context() else {
            pending = nil; accept.isEnabled = false; result.string = "Your scene or selection changed. Ask for a new plan before applying."; return
        }
        do {
            try plan.validate(context:context()); try apply(plan)
            result.string += "\n\nApplied. Use Undo in the 3D Editor to restore the previous model."
            pending = nil; accept.isEnabled = false
        } catch { result.string += "\n\nNot applied: "+error.localizedDescription }
    }
}

final class ModelingPhysicsController: NSViewController, NSWindowDelegate {
    private let read: () -> (ModelingPhysicsPreview.State,TimeInterval,Int)
    private let play: ()->Void, pause: ()->Void, step: ()->Void, reset: ()->Void, bake: ()->Void
    private let status = NSTextField(wrappingLabelWithString:"")
    private var playButton:GameButton!, pauseButton:GameButton!, bakeButton:GameButton!
    init(read:@escaping ()->(ModelingPhysicsPreview.State,TimeInterval,Int),play:@escaping ()->Void,pause:@escaping ()->Void,step:@escaping ()->Void,reset:@escaping ()->Void,bake:@escaping ()->Void) {
        self.read = read; self.play = play; self.pause = pause; self.step = step; self.reset = reset; self.bake = bake; super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func loadView() {
        view = NSView(frame:NSRect(x:0,y:0,width:640,height:450)); view.appearance = NSAppearance(named:.darkAqua)
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor(calibratedWhite:0.1,alpha:1).cgColor
        let scroll = GameScroll(); view.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo:view.topAnchor),scroll.bottomAnchor.constraint(equalTo:view.bottomAnchor),scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor)])
        scroll.add(gameLabel("RIGID-BODY PREVIEW",strong:true))
        let instructions = NSTextField(wrappingLabelWithString:"1. In Object mode, select a mesh and set its Physics mode to Dynamic body.\n2. Set any obstacles to Static collider; Off objects do not collide.\n3. Press Play and watch the main 3D viewport. Pause or step to inspect.\n4. Bake only if you want to keep the current pose.")
        scroll.add(instructions,fill:true)
        scroll.add(status,fill:true)
        playButton = GameButton("Play") { [weak self] in self?.play(); self?.refresh() }
        pauseButton = GameButton("Pause") { [weak self] in self?.pause(); self?.refresh() }
        bakeButton = GameButton("Bake pose to mesh") { [weak self] in
            self?.pause()
            let alert = NSAlert(); alert.messageText = "Bake this physics pose?"; alert.informativeText = "This changes the model's geometry to the current preview position. It is one undoable operation; it does not create animation keyframes."
            alert.addButton(withTitle:"Bake pose"); alert.addButton(withTitle:"Cancel")
            if alert.runModal() == .alertFirstButtonReturn { self?.bake(); self?.refresh() }
        }
        scroll.add(gameRow([playButton,pauseButton,GameButton("Step 1 frame") { [weak self] in self?.step(); self?.refresh() },GameButton("Reset") { [weak self] in self?.reset(); self?.refresh() }]))
        scroll.add(bakeButton)
        let caveats = NSTextField(wrappingLabelWithString:"SceneKit rigid bodies • box colliders • ground at Y = 0\n\nThis is a modeling preview, not cloth, fluid, jointed-rig or soft-body simulation. Box colliders approximate detailed shapes. Simulation runs at 60 steps/second and does not alter authored vertices unless you choose Bake. Editing or changing modes ends the preview and restores the authored model.")
        caveats.textColor = .secondaryLabelColor; caveats.font = .systemFont(ofSize:11); scroll.add(caveats,fill:true)
        refresh()
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.delegate = self }
    func windowWillClose(_ notification:Notification) { pause() }
    func refresh() {
        guard isViewLoaded else { return }; let (state,time,bodies) = read()
        let label = state == .playing ? "Playing" : state == .paused ? "Paused" : "Stopped"
        status.stringValue = String(format:"%@ · %.2f seconds · %d dynamic bodies",label,time,bodies)
        playButton.isEnabled = state != .playing; pauseButton.isEnabled = state == .playing; bakeButton.isEnabled = time > 0 && bodies > 0
    }
}
