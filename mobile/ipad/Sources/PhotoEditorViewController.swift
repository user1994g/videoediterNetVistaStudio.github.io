import UIKit
import CoreImage
import UniformTypeIdentifiers
import ImageIO

/// Native touch/pointer adapter for the Mac photo document, compositor and
/// brush engine. No remote service or reduced-resolution project format.
@MainActor
final class PhotoEditorViewController: UIViewController, UIDocumentPickerDelegate, UIColorPickerViewControllerDelegate {
    var permitsEditing: () -> Bool = { false }
    var onHome: (() -> Void)?
    private(set) var session = try! PhotoEditingSession(size: CGSize(width: 1920, height: 1080), name: "Untitled photo", background: .white)
    let canvas = PhotoCanvasView()
    private let documentBar = UIView(), brandLabel = MobileTheme.label("Photos · NetVista Studio", size: 12, weight: .semibold)
    private let header = UIScrollView(), tools = UIScrollView(), options = UIScrollView(), panel = UIView()
    private let layerTable = PhotoLayerPanelView(), properties = UIScrollView(), propertyContent = UIStackView()
    private let tabs = UISegmentedControl(items: ["Layers", "Properties", "Brushes"])
    private let status = MobileTheme.label("", size: 11), titleLabel = MobileTheme.label("", size: 13, weight: .semibold)
    private let zoomLabel = MobileTheme.label("Fit", size: 11), lockNotice = MobileTheme.label("Sign in from Studio Home to edit.", size: 14)
    private var headerButtons: [UIButton] = [], toolButtons: [UIButton] = [], optionButtons: [UIButton] = []
    private var panelVisible = false, activeTool = MobilePhotoTool.brush
    private var brushes = PhotoBrush.defaults, brushIndex = 1, brushSize = 40.0, hardness = 0.0, opacity = 1.0, flow = 1.0
    private let brushBrowser = PhotoBrushLibraryView()
    private let palette = MobilePhotoPaletteView()
    private var palettePickerIndex: Int?, regionTolerance = 24.0
    private weak var currentToneCurve: MobilePhotoToneCurveView?
    private let brushImportQueue = DispatchQueue(label: "com.netvistastudio.photo.brush-imports", qos: .userInitiated)
    private var brushImportBusy = false, lastBrushImportReport = ""
    private var foreground = UIColor.black, maskEditing = false, sampleNext = false
    private var selectionMask: CIImage?, selectionPath: CGPath?, points: [CGPoint] = []
    private var selectionGeneration = 0
    private var cloneSource: CGPoint?, cloneLayer: UUID?, stroke: PhotoRasterStroke?, strokeLayer: UUID?, strokeOnMask = false
    private var gestureLayer: UUID?, gesturePosition = CGPoint.zero, gestureStart = CGPoint.zero
    private var lastStrokeFrame = 0.0
    private var propertyGestureLayer: UUID?
    private var propertyGestureControl: UUID?
    private var propertiesGeneration = 0
    private var pickerMode = "image", pendingExport: URL?
    private(set) var preparingExport = false
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let renderQueue = DispatchQueue(label: "com.netvistastudio.photo.preview", qos: .userInitiated)
    private let fileQueue = DispatchQueue(label: "com.netvistastudio.photo.files", qos: .utility)
    private var renderGeneration = 0, renderScheduled = false, autosaveWork: DispatchWorkItem?
    private(set) var renderedRevision: UInt64?
    private var lastSavedRevision: UInt64?
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var draftURL: URL { docs.appendingPathComponent("WorkingPhoto.netvistaphoto") }
    private var brushURL: URL { docs.appendingPathComponent("PhotoBrushLibrary.json") }

    override func viewDidLoad() {
        super.viewDidLoad(); overrideUserInterfaceStyle = .dark; view.backgroundColor = MobileTheme.window
        if let data = try? Data(contentsOf: draftURL) {
            do { try session.load(data: data, projectURL: draftURL) }
            catch { status.text = "Your photo draft could not be opened: \(error.localizedDescription). It has not been overwritten." }
        }
        // Opening an unreadable draft must never replace it with the blank fallback.
        lastSavedRevision = session.revision
        if let data = try? Data(contentsOf: brushURL), data.count <= 96 * 1024 * 1024,
           let saved = try? JSONDecoder().decode([PhotoBrush].self, from: data), !saved.isEmpty,
           saved.count <= 1024, saved.allSatisfy(\.isValid) { brushes = saved; brushIndex = min(1, saved.count - 1) }
        for item in [documentBar, header, tools, options, canvas, panel, status, lockNotice] { view.addSubview(item) }
        documentBar.backgroundColor = MobileTheme.top; documentBar.addSubview(brandLabel); documentBar.addSubview(titleLabel)
        titleLabel.textColor = MobileTheme.secondary
        for item in [header, tools, options] { item.backgroundColor = MobileTheme.top; item.showsHorizontalScrollIndicator = false }
        panel.backgroundColor = MobileTheme.panel; panel.addSubview(tabs); panel.addSubview(layerTable); panel.addSubview(properties)
        tabs.selectedSegmentIndex = 0; tabs.addTarget(self, action: #selector(panelChanged), for: .valueChanged)
        layerTable.onSelect = { [weak self] id in
            guard let self else { return }; self.finishGesture(); self.session.select(id); self.maskEditing = false; self.refresh()
        }
        layerTable.onVisibility = { [weak self] id in
            guard let self, let layer = self.session.layers.first(where: { $0.id == id }) else { return }
            self.edit { try self.session.setVisibility(id, to: !layer.isVisible) }
        }
        layerTable.onActions = { [weak self] id in
            guard let self, self.permitsEditing() else { return }
            self.finishGesture(); self.session.select(id); self.maskEditing = false; self.refresh(); self.layerActions()
        }
        layerTable.accessibilityIdentifier = "photo.layers"
        properties.addSubview(propertyContent); propertyContent.axis = .vertical; propertyContent.spacing = 9
        propertyContent.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            propertyContent.leadingAnchor.constraint(equalTo: properties.contentLayoutGuide.leadingAnchor, constant: 12),
            propertyContent.trailingAnchor.constraint(equalTo: properties.contentLayoutGuide.trailingAnchor, constant: -12),
            propertyContent.topAnchor.constraint(equalTo: properties.contentLayoutGuide.topAnchor, constant: 12),
            propertyContent.bottomAnchor.constraint(equalTo: properties.contentLayoutGuide.bottomAnchor, constant: -12),
            propertyContent.widthAnchor.constraint(equalTo: properties.frameLayoutGuide.widthAnchor, constant: -24)
        ])
        headerButtons = [make("Studio Home", "house", "home") { [weak self] in self?.finishGesture(); self?.saveDraft(); self?.onHome?() },
                         make("New", "doc.badge.plus", "new") { [weak self] in self?.newDocument() },
                         make("Open", "folder", "open") { [weak self] in self?.pick("project") },
                         make("Import", "plus", "import") { [weak self] in self?.pick("image") },
                         make("Save", "square.and.arrow.down", "save") { [weak self] in self?.exportProject() },
                         make("Export", "square.and.arrow.up", "export") { [weak self] in self?.exportImage() },
                         make("Undo", "arrow.uturn.backward", "undo") { [weak self] in self?.undo() },
                         make("Redo", "arrow.uturn.forward", "redo") { [weak self] in self?.redo() },
                         make("Panels", "sidebar.right", "panels") { [weak self] in self?.panelVisible.toggle(); self?.view.setNeedsLayout() }]
        headerButtons.forEach { header.addSubview($0) }
        for tool in MobilePhotoTool.allCases {
            let button = make(tool.rawValue, tool.symbol, "tool.\(tool.rawValue.lowercased())") { [weak self] in self?.selectTool(tool) }
            toolButtons.append(button); tools.addSubview(button)
        }
        optionButtons = [make("Colour", "circle.fill", "colour") { [weak self] in self?.chooseColour() },
                         make("Layer +", "square.3.layers.3d", "layer.add") { [weak self] in self?.layerMenu() },
                         make("Select source", "scope", "clone.source") { [weak self] in self?.sampleNext = true; self?.status.text = "Tap the source on this layer, then paint." },
                         make("Deselect", "rectangle.dashed", "deselect") { [weak self] in self?.clearSelection() },
                         make("Crop", "crop", "crop") { [weak self] in self?.crop() },
                         make("−", nil, "zoom.out") { [weak self] in self?.canvas.zoomBy(0.8) },
                         make("Fit", nil, "zoom.fit") { [weak self] in self?.canvas.fit() },
                         make("+", nil, "zoom.in") { [weak self] in self?.canvas.zoomBy(1.25) },
                         make("Rulers", "ruler", "rulers") { [weak self] in self?.canvas.showsRulers.toggle() }]
        optionButtons.forEach { options.addSubview($0) }; options.addSubview(zoomLabel)
        canvas.onInput = { [weak self] point, phase in self?.handleInput(point, phase: phase) }
        canvas.onZoom = { [weak self] value in self?.zoomLabel.text = String(format: "%.0f%%", value) }
        status.textColor = MobileTheme.secondary; lockNotice.textAlignment = .center; lockNotice.backgroundColor = MobileTheme.top
        refresh(); selectTool(.brush)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    private func make(_ title: String, _ symbol: String?, _ id: String, _ action: @escaping () -> Void) -> UIButton {
        let button = MobileTheme.button(title, symbol: symbol, action: action); button.accessibilityIdentifier = "photo.\(id)"; return button
    }
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); becomeFirstResponder() }
    private func isEditingText(_ view: UIView) -> Bool {
        if view.isFirstResponder && (view is UITextField || view is UITextView) { return true }
        return view.subviews.contains { isEditingText($0) }
    }
    override var keyCommands: [UIKeyCommand]? {
        guard isViewLoaded, view.window != nil, permitsEditing(), presentedViewController == nil, !isEditingText(view) else { return nil }
        let specifications: [(String, UIKeyModifierFlags, String)] = [
            ("b", [], "Brush"), ("e", [], "Eraser"), ("v", [], "Move"), ("h", [], "Hand"),
            ("z", .command, "Undo"), ("z", [.command, .shift], "Redo"), ("d", .command, "Deselect"),
            ("=", .command, "Zoom in"), ("+", .command, "Zoom in"), ("-", .command, "Zoom out"), ("0", .command, "Fit canvas")]
        return specifications.map { input, flags, title in
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(photoKey(_:)))
            command.discoverabilityTitle = title; command.wantsPriorityOverSystemBehavior = true; return command
        }
    }
    @objc private func photoKey(_ command: UIKeyCommand) {
        guard permitsEditing(), presentedViewController == nil, !isEditingText(view) else { return }
        if command.modifierFlags.contains(.command) {
            switch command.input {
            case "z": command.modifierFlags.contains(.shift) ? redo() : undo()
            case "d": finishGesture(); clearSelection()
            case "=", "+": canvas.zoomBy(1.25)
            case "-": canvas.zoomBy(0.8)
            case "0": canvas.fit()
            default: break
            }
        } else {
            switch command.input { case "b": selectTool(.brush); case "e": selectTool(.eraser); case "v": selectTool(.move); case "h": selectTool(.hand); default: break }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets, width = max(1, view.bounds.width - safe.left - safe.right)
        let height = max(1, view.bounds.height - safe.top - safe.bottom), top = safe.top, wide = width >= 900
        let railLayout = wide || height < 500
        documentBar.frame = CGRect(x: safe.left, y: top, width: width, height: 30)
        brandLabel.frame = CGRect(x: 10, y: 0, width: min(180, width * 0.48), height: 30)
        titleLabel.frame = CGRect(x: brandLabel.frame.maxX + 10, y: 0, width: max(1, width - brandLabel.frame.maxX - 20), height: 30)
        titleLabel.textAlignment = .right
        header.frame = CGRect(x: safe.left, y: top + 30, width: width, height: 52)
        var x: CGFloat = 8
        for (i, button) in headerButtons.enumerated() { let w: CGFloat = i == 0 ? 108 : i == 8 ? 74 : 68; button.frame = CGRect(x: x, y: 4, width: w, height: 44); x += w + 6 }
        header.contentSize = CGSize(width: x, height: 52)
        let bodyTop: CGFloat = railLayout ? 132 : 182, body = max(1, height - bodyTop - 24), rail: CGFloat = railLayout ? 52 : 0
        tools.frame = CGRect(x: safe.left, y: top + (railLayout ? bodyTop : 82), width: railLayout ? rail : width, height: railLayout ? body : 50)
        tools.showsVerticalScrollIndicator = railLayout
        x = 8
        for (index, button) in toolButtons.enumerated() {
            button.setTitle(railLayout ? "" : MobilePhotoTool.allCases[index].rawValue, for: .normal)
            button.frame = railLayout ? CGRect(x: 4, y: 4 + CGFloat(index) * 48, width: 44, height: 44) : CGRect(x: x, y: 3, width: 82, height: 44)
            x += 86
        }
        tools.contentSize = railLayout ? CGSize(width: rail, height: CGFloat(toolButtons.count) * 48 + 8) : CGSize(width: x, height: 50)
        options.frame = CGRect(x: safe.left, y: top + (railLayout ? 82 : 132), width: width, height: 50)
        x = 8
        for button in optionButtons {
            let identifier = button.accessibilityIdentifier ?? ""
            let w: CGFloat = identifier.hasPrefix("photo.zoom.") ? 44 : identifier == "photo.clone.source" ? 118 : identifier == "photo.selection.lift" ? 108 : 85
            button.frame = CGRect(x: x, y: 3, width: w, height: 44); x += w + 5
        }
        zoomLabel.frame = CGRect(x: x + 6, y: 3, width: 65, height: 44); options.contentSize = CGSize(width: x + 85, height: 50)
        let panelWidth: CGFloat = wide ? 304 : min(340, width - 16)
        canvas.frame = CGRect(x: safe.left + rail, y: top + bodyTop, width: width - rail - (wide ? panelWidth : 0), height: body)
        panel.frame = CGRect(x: safe.left + width - panelWidth, y: top + bodyTop, width: panelWidth, height: body)
        panel.isHidden = !wide && !panelVisible
        tabs.frame = CGRect(x: 10, y: 8, width: panelWidth - 20, height: 36)
        for item in [layerTable, properties] { item.frame = CGRect(x: 0, y: 52, width: panelWidth, height: max(1, body - 52)) }
        status.frame = CGRect(x: safe.left + 10, y: top + height - 24, width: width - 20, height: 24)
        lockNotice.frame = CGRect(x: safe.left + rail, y: top + bodyTop, width: width - rail, height: 60)
        view.bringSubviewToFront(lockNotice)
    }
    func refreshAccess() {
        guard isViewLoaded else { return }
        let allowed = permitsEditing(); lockNotice.isHidden = allowed
        canvas.isUserInteractionEnabled = allowed
        for (i, button) in headerButtons.enumerated() { button.isEnabled = i == 0 || allowed }
        for i in [4, 5] { headerButtons[i].isEnabled = allowed && !preparingExport }
        toolButtons.forEach { $0.isEnabled = allowed }; optionButtons.forEach { $0.isEnabled = allowed }
        if !allowed { cancelGesture() }
    }
    private func refresh(rebuildProperties: Bool = true) {
        guard isViewLoaded else { return }
        canvas.documentSize = session.documentSize
        layerTable.setLayers(session.layers, selectedID: session.selectedLayerID, revision: session.revision)
        headerButtons[6].isEnabled = session.canUndo; headerButtons[7].isEnabled = session.canRedo
        titleLabel.text = "\(session.documentName) · \(Int(session.documentSize.width)) × \(Int(session.documentSize.height))"
        if status.text?.isEmpty != false { status.text = "\(session.documentName) · \(Int(session.documentSize.width)) × \(Int(session.documentSize.height)) · \(session.layers.count) layers" }
        if rebuildProperties { buildProperties() }; requestRender(); refreshAccess()
        headerButtons[6].isEnabled = permitsEditing() && session.canUndo; headerButtons[7].isEnabled = permitsEditing() && session.canRedo
    }
    private func edit(_ body: () throws -> Void) {
        guard permitsEditing() else { refreshAccess(); return }
        finishGesture()
        do { try body(); refresh(); saveDraft() } catch { report(error) }
    }
    private func report(_ error: Error) { status.text = error.localizedDescription; showError(error.localizedDescription) }
    private func showError(_ text: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Photo Editor", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
    private func requestRender() {
        renderGeneration += 1
        guard !renderScheduled else { return }; renderScheduled = true
        // At most one render is queued; superseded frames are never published.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1 / 30) { [weak self] in
            guard let self else { return }
            let ticket = self.renderGeneration, state = self.session.state, revision = self.session.revision, context = self.context
            self.renderQueue.async { [weak self] in
                let image = PhotoRenderEngine.composite(state.layers, documentSize: state.documentSize, maxSide: 1800, bypassAdjustments: false, opaqueBackground: false)
                let cg = image.flatMap { context.createCGImage($0, from: $0.extent) }
                DispatchQueue.main.async {
                    guard let self else { return }; self.renderScheduled = false
                    if self.renderGeneration == ticket {
                        self.canvas.image = cg.map { UIImage(cgImage: $0) }
                        self.renderedRevision = cg == nil ? nil : revision
                    }
                    else { self.requestRender() }
                }
            }
        }
    }
    private func saveDraft() {
        guard session.revision != lastSavedRevision else { return }
        autosaveWork?.cancel()
        let state = session.state, revision = session.revision, url = draftURL, context = context
        let work = DispatchWorkItem { [weak self] in
            do {
                let copy = try PhotoEditingSession(snapshot: state)
                let data = try copy.encodedProject(context: context); try data.write(to: url, options: .atomic)
                DispatchQueue.main.async { [weak self] in self?.lastSavedRevision = revision }
            } catch { DispatchQueue.main.async { [weak self] in self?.status.text = "Photo autosave failed: \(error.localizedDescription). Use Save to keep a copy." } }
        }
        autosaveWork = work; fileQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    @objc private func backgrounded() { finishGesture(); saveDraft() }
    @objc private func panelChanged() { finishGesture(); buildProperties() }
    private func clearSelection() { selectionGeneration += 1; selectionMask = nil; selectionPath = nil; canvas.outline = nil }
    func undo() { finishGesture(); guard permitsEditing() else { return }; session.undo(); clearSelection(); refresh(); saveDraft() }
    func redo() { finishGesture(); guard permitsEditing() else { return }; session.redo(); clearSelection(); refresh(); saveDraft() }
    func selectTool(_ tool: MobilePhotoTool) {
        finishGesture(); selectionGeneration += 1; activeTool = tool; canvas.tool = tool
        for (index, button) in toolButtons.enumerated() { button.backgroundColor = MobilePhotoTool.allCases[index] == tool ? MobileTheme.accent : MobileTheme.control }
        status.text = "\(tool.rawValue) · Pinch to zoom, two fingers to pan."
        if [.brush, .eraser, .clone, .heal, .wand, .bucket].contains(tool) { tabs.selectedSegmentIndex = 2 }
        buildProperties()
    }
    private func menu(_ title: String, items: [(String, () -> Void)], anchor: UIView? = nil) {
        let menu = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (title, action) in items { menu.addAction(UIAlertAction(title: title, style: .default) { _ in action() }) }
        menu.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        menu.popoverPresentationController?.sourceView = anchor ?? tabs
        menu.popoverPresentationController?.sourceRect = (anchor ?? tabs).bounds
        present(menu, animated: true)
    }
    private func layerMenu() {
        menu("Add to document", items: [
            ("Transparent layer", { [weak self] in self?.edit { _ = try self?.session.addBlankLayer(name: "Layer") } }),
            ("Import image as layer", { [weak self] in self?.pick("image") }),
            ("Adjustment layer", { [weak self] in self?.edit { _ = try self?.session.addAdjustmentLayer(name: "Adjustments") }; self?.tabs.selectedSegmentIndex = 1; self?.buildProperties() }),
            ("Group selected layer", { [weak self] in self?.groupSelected() }),
            ("Lift selected pixels", { [weak self] in self?.liftSelectedPixels() }),
            ("Layer actions…", { [weak self] in self?.layerActions() })
        ], anchor: optionButtons[1])
    }
    private func layerActions() {
        guard let layer = session.selectedLayer else { return }
        menu(layer.name, items: [
            ("Edit properties", { [weak self] in self?.tabs.selectedSegmentIndex = 1; self?.panelVisible = true; self?.buildProperties(); self?.view.setNeedsLayout() }),
            ("Rename", { [weak self] in self?.prompt("Layer name", value: layer.name) { text in self?.edit { try self?.session.mutateLayer(layer.id, label: "Rename layer") { $0.name = text } } } }),
            ("Duplicate", { [weak self] in self?.edit { _ = try self?.session.duplicate(layer.id) } }),
            ("Move up", { [weak self] in self?.moveLayer(layer.id, delta: -1) }),
            ("Move down", { [weak self] in self?.moveLayer(layer.id, delta: 1) }),
            (layer.extras.isGroup ? "Ungroup folder" : "Move to folder…", { [weak self] in self?.folderActions(layer.id) }),
            (layer.isLocked ? "Unlock" : "Lock", { [weak self] in self?.edit { try self?.session.setLocked(layer.id, to: !layer.isLocked) } }),
            (layer.extras.maskPNG == nil ? "Add white mask" : "Paint mask", { [weak self] in self?.addMask() }),
            ("Mask operations…", { [weak self] in self?.maskActions() }),
            ("Paint image pixels", { [weak self] in self?.maskEditing = false; self?.status.text = "Painting layer pixels" }),
            ("Remove mask", { [weak self] in self?.edit { try self?.session.mutateLayer(layer.id, label: "Remove mask") { $0.extras.maskPNG = nil; $0.maskPreview = nil } }; self?.maskEditing = false }),
            ("Delete layer", { [weak self] in self?.edit { try self?.session.remove(layer.id) } })
        ])
    }
    private func moveLayer(_ id: UUID, delta: Int) {
        edit { try session.reorder(id, by: delta) }
    }
    private func folderActions(_ id: UUID) {
        guard let layer = session.layers.first(where: { $0.id == id }) else { return }
        if layer.extras.isGroup { edit { try session.ungroup(id) }; return }
        var items: [(String, () -> Void)] = [("New folder around this layer", { [weak self] in self?.edit { _ = try self?.session.group([id], name: "Group") } }),
            ("Move out of folder", { [weak self] in self?.edit { try self?.session.moveToGroup(id, groupID: nil) } })]
        for folder in session.layers where folder.extras.isGroup && !folder.isLocked && folder.id != layer.extras.groupID {
            items.append(("Move into: \(folder.name)", { [weak self] in self?.edit { try self?.session.moveToGroup(id, groupID: folder.id) } }))
        }
        menu("Layer folders", items: items)
    }
    @objc private func liftSelectedPixels() {
        guard let mask = selectionMask, let id = session.selectedLayerID else { showError("Select pixels on an unlocked image layer first."); return }
        edit { _ = try session.liftSelection(mask: mask, layerID: id, context: context); clearSelection(); maskEditing = false; selectTool(.move) }
    }
    private func maskActions() {
        guard let id = session.selectedLayerID else { return }
        func selection(_ reveal: Bool) {
            guard let mask = selectionMask else { showError("Make a selection first."); return }
            edit { try session.maskSelection(id, mask: mask, reveal: reveal, context: context); maskEditing = true; foreground = .black; selectTool(.brush) }
        }
        menu("Layer mask", items: [
            ("Reveal all", { [weak self] in guard let self else { return }; self.edit { try self.session.addMask(id, context: self.context); self.maskEditing = true; self.foreground = .black; self.selectTool(.brush) } }),
            ("Reveal selection", { selection(true) }), ("Hide selection", { selection(false) }),
            ("Invert existing mask", { [weak self] in guard let self else { return }; self.edit { try self.session.invertMask(id, context: self.context); self.maskEditing = true; self.foreground = .black; self.selectTool(.brush) } }),
            ("Remove mask", { [weak self] in self?.edit { try self?.session.removeMask(id) }; self?.maskEditing = false })
        ])
    }
    private func groupSelected() {
        guard let id = session.selectedLayerID else { return }
        edit { _ = try session.group([id], name: "Group") }
    }
    private func addMask() {
        guard let layer = session.selectedLayer else { return }
        edit {
            if layer.extras.maskPNG == nil {
                let image = CIImage(color: .white).cropped(to: layer.extras.isAdjustment ? CGRect(origin: .zero, size: session.documentSize) : layer.sourceImage.extent)
                let png = try PhotoPixels.png(image, context: context)
                try session.mutateLayer(layer.id, label: "Add mask") { $0.extras.maskPNG = png }
            }
            maskEditing = true; foreground = .black; status.text = "Mask: black hides, white reveals. Eraser restores white."
        }
    }
    private func prompt(_ title: String, value: String, action: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = value; $0.selectAll(nil) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Apply", style: .default) { _ in if let text = alert.textFields?.first?.text, !text.isEmpty { action(text) } })
        present(alert, animated: true)
    }
    private func chooseColour(swatch: Int? = nil) {
        guard permitsEditing() else { return }; finishGesture(); palettePickerIndex = swatch
        let picker = UIColorPickerViewController(); picker.selectedColor = swatch.flatMap { palette.colours.indices.contains($0) ? palette.colours[$0] : nil } ?? foreground
        picker.delegate = self; present(picker, animated: true)
    }
    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        guard permitsEditing() else { return }; foreground = viewController.selectedColor; optionButtons[0].tintColor = foreground
        if let index = palettePickerIndex { palette.setColour(foreground, at: index) }
    }
    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) { palettePickerIndex = nil }

    private func buildProperties() {
        propertiesGeneration += 1
        currentToneCurve = nil
        layerTable.isHidden = tabs.selectedSegmentIndex != 0; properties.isHidden = tabs.selectedSegmentIndex == 0
        for view in propertyContent.arrangedSubviews { propertyContent.removeArrangedSubview(view); view.removeFromSuperview() }
        guard tabs.selectedSegmentIndex != 0 else { return }
        func heading(_ title: String) { let label = MobileTheme.label(title, size: 12, weight: .semibold); propertyContent.addArrangedSubview(label); label.heightAnchor.constraint(equalToConstant: 26).isActive = true }
        func command(_ title: String, _ action: @escaping () -> Void) { let b = make(title, nil, "command.\(title)", action); b.heightAnchor.constraint(equalToConstant: 44).isActive = true; propertyContent.addArrangedSubview(b) }
        if tabs.selectedSegmentIndex == 2 {
            heading("BRUSH LIBRARY")
            command("Import ABR / image / NetVista tip…") { [weak self] in
                guard let self, !self.brushImportBusy else { return }; self.pick("brush")
            }
            (propertyContent.arrangedSubviews.last as? UIButton)?.isEnabled = !brushImportBusy
            command("Create brush from selected layer") { [weak self] in self?.defineBrush() }
            (propertyContent.arrangedSubviews.last as? UIButton)?.isEnabled = !brushImportBusy
            command("Save selected tip…") { [weak self] in self?.saveBrushTip() }
            if brushImportBusy { heading("IMPORTING · You can keep painting") }
            if !lastBrushImportReport.isEmpty {
                command("Brush import report…") { [weak self] in guard let self else { return }; self.showError(self.lastBrushImportReport) }
            }
            if brushBrowser.brushCount != brushes.count { brushBrowser.setBrushes(brushes, selectedIndex: brushIndex) }
            else { brushBrowser.setSelectedIndex(brushIndex) }
            brushBrowser.onSelect = { [weak self] index in
                guard let self, self.permitsEditing(), self.brushes.indices.contains(index) else { return }
                self.finishGesture(); self.brushIndex = index; let brush = self.brushes[index]; self.hardness = brush.hardness
                if let diameter = brush.diameter { self.brushSize = diameter }; self.buildProperties()
            }
            propertyContent.addArrangedSubview(brushBrowser)
            heading("TIP & INK")
            addControl("Size", value: brushSize, range: 1...2048) { [weak self] value in self?.brushSize = value }
            addControl("Hardness", value: hardness, range: 0...1, enabled: brushes[brushIndex].kind != "sample") { [weak self] value in self?.hardness = value }
            addControl("Opacity", value: opacity, range: 0...1) { [weak self] value in self?.opacity = value }
            addControl("Flow", value: flow, range: 0.01...1) { [weak self] value in self?.flow = value }
            addControl("Tolerance", value: regionTolerance, range: 0...255) { [weak self] value in self?.regionTolerance = value }
            heading("PAINT COLOUR · hold a swatch to edit")
            palette.onSelect = { [weak self] colour in guard let self, self.permitsEditing() else { return }; self.finishGesture(); self.foreground = colour; self.optionButtons[0].tintColor = colour }
            palette.onEdit = { [weak self] index, _ in self?.chooseColour(swatch: index) }
            propertyContent.addArrangedSubview(palette)
            let note = MobileTheme.label("ABR imports tip shapes and static settings. Adobe mixer/dual-brush dynamics are not reproduced by the desktop engine.", size: 11)
            note.numberOfLines = 0; note.textColor = MobileTheme.secondary; propertyContent.addArrangedSubview(note)
            return
        }
        guard let layer = session.selectedLayer else { heading("Select a layer to edit"); return }
        heading(layer.name.uppercased())
        command("Layer actions…") { [weak self] in self?.layerActions() }
        command("Blend: \(layer.blendMode.rawValue)") { [weak self] in
            self?.menu("Blend mode", items: PhotoBlendMode.allCases.map { mode in (mode.rawValue, { [weak self] in self?.edit { try self?.session.setBlendMode(layer.id, to: mode) } }) })
        }
        func property(_ name: String, _ value: Double, _ range: ClosedRange<Double>, _ apply: @escaping (PhotoLayer, Double) -> Void) {
            addControl(name, value: value, range: range, layer: layer.id) { [weak self] value in
                guard let self, self.session.selectedLayerID == layer.id else { return }
                do { try self.session.mutateLayer(layer.id, label: name) { apply($0, value) }; self.syncCurveControls(); self.requestRender() }
                catch { self.cancelGesture(); self.status.text = error.localizedDescription }
            }
        }
        property("Layer opacity", layer.opacity, 0...1) { $0.opacity = $1 }
        if !layer.extras.isGroup {
            heading("LAYER MASK")
            command(layer.extras.maskPNG == nil ? "Add mask" : "Paint mask") { [weak self] in self?.addMask() }
            if layer.extras.maskPNG != nil {
                command("Paint image pixels") { [weak self] in self?.finishGesture(); self?.maskEditing = false; self?.status.text = "Painting layer pixels" }
                command("Remove mask") { [weak self] in self?.edit { try self?.session.removeMask(layer.id) }; self?.maskEditing = false }
            }
        }
        if !layer.extras.isGroup && !layer.extras.isAdjustment {
            heading("TRANSFORM")
            property("Position X", layer.position.x, -Double(session.documentSize.width)...Double(session.documentSize.width)) { $0.position.x = $1 }
            property("Position Y", layer.position.y, -Double(session.documentSize.height)...Double(session.documentSize.height)) { $0.position.y = $1 }
            property("Scale", layer.scale, 0.01...10) { $0.scale = $1 }
            property("Rotation", layer.rotation, -180...180) { $0.rotation = $1 }
            property("Skew", layer.extras.skew, -2...2) { $0.extras.skew = $1 }
            command("Flip horizontal") { [weak self] in self?.edit { try self?.session.mutateLayer(layer.id, label: "Flip layer") { $0.adjustments.mirrored.toggle() } } }
            if layer.extras.text != nil { command("Edit text…") { [weak self] in self?.text(at: .zero, existing: layer) } }
        }
        heading("LIGHT & COLOUR")
        property("Exposure", layer.adjustments.exposure, -5...5) { $0.adjustments.exposure = $1 }
        property("Brightness", layer.adjustments.brightness, -1...1) { $0.adjustments.brightness = $1 }
        property("Contrast", layer.adjustments.contrast, 0...4) { $0.adjustments.contrast = $1 }
        property("Saturation", layer.adjustments.saturation, 0...3) { $0.adjustments.saturation = $1 }
        property("Vibrance", layer.adjustments.vibrance, -1...1) { $0.adjustments.vibrance = $1 }
        property("Highlights", layer.adjustments.highlights, 0...2) { $0.adjustments.highlights = $1 }
        property("Shadows", layer.adjustments.shadows, -1...1) { $0.adjustments.shadows = $1 }
        property("Temperature", layer.adjustments.temperature, 2000...12000) { $0.adjustments.temperature = $1 }
        property("Tint", layer.adjustments.tint, -150...150) { $0.adjustments.tint = $1 }
        property("Hue", layer.extras.hue, -180...180) { $0.extras.hue = $1 }
        heading("LEVELS & CURVE")
        let curve = MobilePhotoToneCurveView(frame: .zero), curveGeneration = propertiesGeneration, curveID = UUID()
        curve.values = [layer.extras.curveShadows, layer.extras.midtone, layer.extras.curveHighlights]; curve.isEnabled = permitsEditing() && session.isEditable(layer.id)
        curve.onBegin = { [weak self] in
            guard let self, self.permitsEditing(), self.propertiesGeneration == curveGeneration, self.session.selectedLayerID == layer.id else { return false }
            self.finishGesture()
            do { try self.session.beginTransaction("Tone curve"); self.propertyGestureLayer = layer.id; self.propertyGestureControl = curveID; return true }
            catch { self.status.text = error.localizedDescription; return false }
        }
        curve.onChange = { [weak self] values in
            guard let self, self.permitsEditing(), self.propertiesGeneration == curveGeneration, self.propertyGestureLayer == layer.id,
                  self.propertyGestureControl == curveID, self.session.selectedLayerID == layer.id else { return }
            do { try self.session.mutateLayer(layer.id, label: "Tone curve") { $0.extras.curveShadows = values[0]; $0.extras.midtone = values[1]; $0.extras.curveHighlights = values[2] }; self.syncCurveControls(); self.requestRender() }
            catch { self.cancelGesture(); self.status.text = error.localizedDescription }
        }
        curve.onEnd = { [weak self] cancelled in
            guard let self, self.propertiesGeneration == curveGeneration, self.propertyGestureLayer == layer.id, self.propertyGestureControl == curveID else { return }
            if cancelled { self.cancelGesture() } else { self.finishGesture() }; self.refresh()
        }
        currentToneCurve = curve; propertyContent.addArrangedSubview(curve)
        property("Black point", layer.extras.black, 0...0.95) { $0.extras.black = min($1, $0.extras.white - 0.01) }
        property("White point", layer.extras.white, 0.05...1) { $0.extras.white = max($1, $0.extras.black + 0.01) }
        property("Curve shadows", layer.extras.curveShadows, 0...1) { $0.extras.curveShadows = $1 }
        property("Curve midtones", layer.extras.midtone, 0...1) { $0.extras.midtone = $1 }
        property("Curve highlights", layer.extras.curveHighlights, 0...1) { $0.extras.curveHighlights = $1 }
        heading("FILTERS")
        property("Blur", layer.adjustments.blur, 0...50) { $0.adjustments.blur = $1 }
        property("Sharpen", layer.adjustments.sharpen, 0...2) { $0.adjustments.sharpen = $1 }
        property("Sepia", layer.adjustments.sepia, 0...1) { $0.adjustments.sepia = $1 }
        property("Vignette", layer.adjustments.vignette, 0...2) { $0.adjustments.vignette = $1 }
        property("Noise", layer.extras.noise, 0...1) { $0.extras.noise = $1 }
        command("Reset adjustments") { [weak self] in self?.edit { try self?.session.mutateLayer(layer.id, label: "Reset adjustments") { $0.adjustments = PhotoAdjustments(); $0.extras.hue = 0; $0.extras.black = 0; $0.extras.white = 1; $0.extras.midtone = 0.5; $0.extras.curveShadows = 0.25; $0.extras.curveHighlights = 0.75; $0.extras.noise = 0 } } }
    }
    private func syncCurveControls() {
        guard let layer = session.selectedLayer, let curve = currentToneCurve else { return }
        let values = [layer.extras.curveShadows, layer.extras.midtone, layer.extras.curveHighlights]
        curve.values = values
        func children(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(children) }
        let controls = children(propertyContent)
        for (name, value) in zip(["Curve shadows", "Curve midtones", "Curve highlights"], values) {
            (controls.first { $0.accessibilityIdentifier == "photo.property.\(name)" } as? UISlider)?.value = Float(value)
            (controls.first { $0.accessibilityIdentifier == "photo.number.\(name)" } as? UIButton)?.setTitle(String(format: "%.2f", value), for: .normal)
        }
    }
    private func addControl(_ name: String, value: Double, range: ClosedRange<Double>, layer: UUID? = nil, enabled: Bool = true, changed: @escaping (Double) -> Void) {
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 0
        let label = MobileTheme.label(name, size: 12), generation = propertiesGeneration, controlID = UUID()
        let valueButton = make(String(format: "%.2f", value), nil, "number.\(name)") { [weak self] in
            guard let self, enabled, self.permitsEditing(), self.propertiesGeneration == generation else { return }
            self.finishGesture()
            self.prompt(name, value: String(value)) { [weak self] text in
                guard let self, self.permitsEditing(), self.propertiesGeneration == generation,
                      layer == nil || self.session.selectedLayerID == layer else { return }
                guard let value = Double(text), value.isFinite, range.contains(value) else { self.showError("Enter a value between \(range.lowerBound) and \(range.upperBound)."); return }
                changed(value); self.refresh(); self.saveDraft()
            }
        }
        let title = UIStackView(arrangedSubviews: [label, valueButton]); valueButton.widthAnchor.constraint(equalToConstant: 82).isActive = true
        title.heightAnchor.constraint(equalToConstant: 44).isActive = true
        valueButton.isEnabled = enabled && (layer.map(session.isEditable) ?? true)
        let slider = UISlider(); slider.minimumValue = Float(range.lowerBound); slider.maximumValue = Float(range.upperBound); slider.value = Float(value)
        slider.tintColor = MobileTheme.accent; slider.accessibilityLabel = name; slider.accessibilityIdentifier = "photo.property.\(name)"
        slider.isEnabled = enabled && (layer.map(session.isEditable) ?? true)
        slider.addAction(UIAction { [weak self] _ in
            guard let self, enabled, let layer, self.propertiesGeneration == generation,
                  self.session.selectedLayerID == layer, self.permitsEditing() else { return }
            self.finishGesture()
            do { try self.session.beginTransaction(name); self.propertyGestureLayer = layer; self.propertyGestureControl = controlID } catch { self.report(error) }
        }, for: .touchDown)
        slider.addAction(UIAction { [weak self, weak slider, weak label] _ in
            guard let self, enabled, let slider, self.permitsEditing(), self.propertiesGeneration == generation,
                  layer == nil || self.session.selectedLayerID == layer else { return }
            // A detached slider cannot resume a transaction after a second control changed the layer.
            guard self.propertyGestureControl == nil || self.propertyGestureControl == controlID else { return }
            if slider.isTracking && layer != nil && self.propertyGestureLayer != layer { return }
            changed(Double(slider.value)); label?.text = name; valueButton.setTitle(String(format: "%.2f", slider.value), for: .normal)
            if !slider.isTracking && self.propertyGestureLayer == nil { self.session.finishTransaction(); self.saveDraft() }
        }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in
            guard let self, self.propertiesGeneration == generation, self.propertyGestureLayer == layer,
                  self.propertyGestureControl == controlID else { return }
            self.finishGesture(); self.refresh()
        }, for: [.touchUpInside, .touchUpOutside])
        slider.addAction(UIAction { [weak self] _ in
            guard let self, self.propertiesGeneration == generation, self.propertyGestureLayer == layer,
                  self.propertyGestureControl == controlID else { return }
            self.cancelGesture(); self.refresh()
        }, for: .touchCancel)
        stack.addArrangedSubview(title); stack.addArrangedSubview(slider); slider.heightAnchor.constraint(equalToConstant: 44).isActive = true; propertyContent.addArrangedSubview(stack)
    }
    private func layerTransform(_ layer: PhotoLayerSnapshot, sourcePixels: Bool = true) -> CGAffineTransform {
        if layer.extras.isAdjustment { return .identity }
        if sourcePixels {
            return PhotoRenderEngine.pixelTransform(size: layer.sourceImage.extent.size, position: layer.position, scale: layer.scale, rotation: layer.rotation, skew: layer.extras.skew, mirrored: layer.adjustments.mirrored, document: session.documentSize)
        }
        return PhotoRenderEngine.layerTransform(size: layer.sourceImage.extent.size, position: layer.position, scale: layer.scale, rotation: layer.rotation, skew: layer.extras.skew, document: session.documentSize)
    }
    private func localSelection(_ layer: PhotoLayerSnapshot, onMask: Bool = false) -> CIImage? { selectionMask?.transformed(by: layerTransform(layer, sourcePixels: !onMask).inverted()).cropped(to: layer.sourceImage.extent) }
    func finishGesture() {
        if let stroke, let id = strokeLayer {
            do {
                if strokeOnMask { try session.setMask(id, image: stroke.image(), context: context) }
                else { try session.replacePixels(id, image: PhotoPixels.frozen(stroke.image(), context: context)) }
            } catch { session.cancelTransaction(); status.text = error.localizedDescription }
        }
        stroke = nil; strokeLayer = nil; gestureLayer = nil; propertyGestureLayer = nil; propertyGestureControl = nil
        session.finishTransaction(); saveDraft()
    }
    private func cancelGesture() {
        stroke = nil; strokeLayer = nil; gestureLayer = nil; propertyGestureLayer = nil; propertyGestureControl = nil
        selectionGeneration += 1; canvas.outline = selectionPath
        session.cancelTransaction(); requestRender()
    }
    func handleInput(_ point: CGPoint, phase: Int) {
        guard permitsEditing() else { return }
        if phase < 0 { cancelGesture(); return }
        do {
            if [.brush, .eraser, .clone, .heal].contains(activeTool) { try paint(point, phase: phase); return }
            if phase == 0 {
                finishGesture(); points = [point]; gestureStart = point
                if [.marquee, .lasso, .wand, .bucket].contains(activeTool) { selectionGeneration += 1 }
                if activeTool == .move, let layer = session.selectedLayer, session.isEditable(layer.id) {
                    guard !layer.extras.isAdjustment else { status.text = "Adjustment layers affect the canvas. Select an image or folder to move."; return }
                    try session.beginTransaction("Move layer"); gestureLayer = layer.id; gesturePosition = point
                }
                if activeTool == .eyedropper, let image = session.render() { foreground = PhotoPixels.color(at: point, image: image, context: context); optionButtons[0].tintColor = foreground }
                if activeTool == .text { text(at: point, existing: nil) }
                if activeTool == .wand || activeTool == .bucket { try flood(point, fill: activeTool == .bucket) }
            }
            if activeTool == .move, let id = gestureLayer, id == session.selectedLayerID {
                try session.translate(id, by: CGPoint(x: point.x - gesturePosition.x, y: point.y - gesturePosition.y)); gesturePosition = point
                requestRender(); if phase == 2 { finishGesture(); refresh() }; return
            }
            if [.marquee, .lasso, .rectangle, .ellipse, .line, .polygon].contains(activeTool) {
                if phase > 0 { points.append(point) }; let path = gesturePath(); canvas.outline = path
                if phase == 2 && points.count > 1 {
                    if activeTool == .marquee || activeTool == .lasso { selectionPath = path; selectionMask = pathMask(path) }
                    else { try createShape(path); canvas.outline = selectionPath; refresh(); saveDraft() }
                }
            }
        } catch { cancelGesture(); status.text = error.localizedDescription }
    }
    private func paint(_ point: CGPoint, phase: Int) throws {
        guard let layer = session.selectedLayer, session.isEditable(layer.id), !layer.extras.isGroup, layer.isVisible,
              !session.layers.contains(where: { $0.id == layer.extras.groupID && !$0.isVisible }) else { throw PhotoBrushError.invalid("Select a visible, unlocked image layer.") }
        let onMask = maskEditing && layer.extras.maskPNG != nil
        let local = point.applying(layerTransform(layer, sourcePixels: !onMask).inverted())
        if phase == 0 {
            finishGesture()
            if sampleNext && [.clone, .heal].contains(activeTool) { cloneSource = local; cloneLayer = layer.id; sampleNext = false; status.text = "Source set. Paint to \(activeTool.rawValue.lowercased())."; return }
            strokeOnMask = onMask
            guard strokeOnMask || (!layer.extras.isAdjustment && layer.extras.text == nil) else { throw PhotoBrushError.invalid("Paint on a new pixel layer, or add a mask to this layer.") }
            var sample: CGImage?, offset = CGPoint.zero
            if [.clone, .heal].contains(activeTool) {
                guard let source = cloneSource, cloneLayer == layer.id, !strokeOnMask else { throw PhotoBrushError.invalid("Press Select source and tap this layer first.") }
                offset = CGPoint(x: source.x - local.x, y: source.y - local.y)
                var sampled = layer.sourceImage
                if activeTool == .heal {
                    let average = sampled.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, brushSize / 3)])
                    let a = PhotoPixels.components(PhotoPixels.color(at: source, image: average, context: context)), b = PhotoPixels.components(PhotoPixels.color(at: local, image: average, context: context))
                    sampled = sampled.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: b.red - a.red, y: b.green - a.green, z: b.blue - a.blue, w: 0)])
                }
                sample = context.createCGImage(sampled, from: sampled.extent)
            }
            let base = strokeOnMask ? (layer.extras.maskPNG.flatMap { CIImage(data: $0) } ?? layer.sourceImage) : layer.sourceImage
            guard let next = PhotoRasterStroke(base: base, brush: brushes[brushIndex], size: brushSize / layer.scale, hardness: hardness,
                opacity: opacity, flow: flow, color: strokeOnMask && activeTool == .eraser ? .white : foreground,
                erase: activeTool == .eraser && !strokeOnMask, selection: localSelection(layer, onMask: strokeOnMask), clone: sample, cloneOffset: offset) else { throw PhotoBrushError.invalid("This device could not allocate the brush surface.") }
            try session.beginTransaction(activeTool.rawValue); stroke = next; strokeLayer = layer.id; lastStrokeFrame = 0
        }
        guard let stroke, strokeLayer == layer.id else { return }; stroke.append(local)
        let now = Date.timeIntervalSinceReferenceDate
        if phase == 2 || now - lastStrokeFrame > 1 / 30 {
            let image = stroke.image()
            try session.mutateLayer(layer.id, label: activeTool.rawValue) { if strokeOnMask { $0.maskPreview = image } else { $0.sourceImage = image } }
            requestRender(); lastStrokeFrame = now
        }
        if phase == 2 { finishGesture(); refresh(rebuildProperties: false) }
    }
    private func gesturePath() -> CGPath {
        let path = CGMutablePath(); guard let first = points.first, let last = points.last else { return path }
        let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(first.x - last.x), height: abs(first.y - last.y))
        if [.marquee, .rectangle].contains(activeTool) { path.addRect(rect) }
        else if activeTool == .ellipse { path.addEllipse(in: rect) }
        else if activeTool == .line { path.move(to: first); path.addLine(to: last) }
        else { path.addLines(between: points); path.closeSubpath() }
        return path
    }
    private func pathMask(_ path: CGPath) -> CIImage? {
        guard let cg = PhotoPixels.context(session.documentSize) else { return nil }
        cg.setFillColor(UIColor.black.cgColor); cg.fill(CGRect(origin: .zero, size: session.documentSize))
        cg.addPath(path); cg.setFillColor(UIColor.white.cgColor); cg.fillPath(); return cg.makeImage().map { CIImage(cgImage: $0) }
    }
    private func createShape(_ path: CGPath) throws {
        guard let cg = PhotoPixels.context(session.documentSize) else { throw PhotoBrushError.invalid("Unable to allocate shape pixels.") }
        cg.addPath(path); cg.setFillColor(foreground.cgColor); cg.setStrokeColor(foreground.cgColor); cg.setLineWidth(brushSize)
        if activeTool == .line { cg.strokePath() } else { cg.fillPath() }
        guard let pixels = cg.makeImage() else { return }; var image = CIImage(cgImage: pixels)
        if let selectionMask { image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent), kCIInputMaskImageKey: selectionMask]) }
        try session.addRaster(image, name: activeTool.rawValue, fit: false)
    }
    private func flood(_ point: CGPoint, fill: Bool) throws {
        guard let layer = session.selectedLayer else { return }
        if fill && (!session.isEditable(layer.id) || layer.extras.isGroup || layer.extras.isAdjustment || layer.extras.text != nil) { throw PhotoBrushError.invalid("Choose an unlocked pixel layer to fill.") }
        guard let source = fill ? layer.sourceImage : session.render() else { return }
        let sample = fill ? point.applying(layerTransform(layer).inverted()) : point
        let revision = session.revision, selectionTicket = selectionGeneration, tolerance = Int(regionTolerance.rounded()), mask = localSelection(layer), color = CIColor(color: foreground), context = context
        status.text = "Finding connected colour…"
        renderQueue.async { [weak self] in
            guard var region = PhotoPixels.region(at: sample, image: source, tolerance: tolerance, context: context) else { return }
            if fill, let mask { region = region.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask]) }
            let result = fill ? PhotoPixels.frozen(CIImage(color: color).cropped(to: source.extent).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: source, kCIInputMaskImageKey: region]), context: context) : region
            DispatchQueue.main.async { [weak self] in
                guard let self, self.permitsEditing(), self.session.revision == revision, self.selectionGeneration == selectionTicket, self.session.selectedLayerID == layer.id else { return }
                if fill { self.edit { try self.session.replacePixels(layer.id, image: result, label: "Fill region") } }
                else { self.selectionMask = result; self.selectionPath = PhotoPixels.maskBounds(result, context: context).map { CGPath(rect: $0, transform: nil) }; self.canvas.outline = self.selectionPath }
                self.status.text = fill ? "Region filled" : "Connected region selected"
            }
        }
    }
    private func crop() {
        guard let mask = selectionMask, let bounds = PhotoPixels.maskBounds(mask, context: context) else { showError("Make a selection before cropping."); return }
        edit { try session.crop(to: bounds, context: context); clearSelection(); canvas.fit() }
    }
    private func text(at point: CGPoint, existing: PhotoLayerSnapshot?) {
        let alert = UIAlertController(title: existing == nil ? "Text layer" : "Edit text", message: "Font name and size in document pixels. Colour uses the current swatch.", preferredStyle: .alert)
        for value in [existing?.extras.text ?? "Your text", existing?.extras.fontName ?? "Helvetica", String(Int(existing?.extras.fontSize ?? 64))] { alert.addTextField { $0.text = value } }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Apply", style: .default) { [weak self] _ in
            guard let self, let fields = alert.textFields, let value = fields[0].text, !value.isEmpty, value.count <= 10000,
                  let size = Double(fields[2].text ?? ""), (1...2000).contains(size) else { return }
            self.edit {
                let fontName = fields[1].text ?? "Helvetica", font = UIFont(name: fontName, size: size) ?? .systemFont(ofSize: size)
                let string = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: self.foreground])
                let bounds = string.boundingRect(with: CGSize(width: 16000, height: 16000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                let textSize = CGSize(width: ceil(bounds.width) + 8, height: ceil(bounds.height) + 8)
                guard PhotoPixels.validSize(textSize) else { throw PhotoBrushError.invalid("This text layer is too large.") }
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
                let image = UIGraphicsImageRenderer(size: textSize, format: format).image { _ in string.draw(at: CGPoint(x: 4, y: 4)) }
                guard let cg = image.cgImage else { return }
                let c = PhotoPixels.components(self.foreground)
                let position = existing == nil ? CGPoint(x: point.x - self.session.documentSize.width / 2 + textSize.width / 2,
                    y: point.y - self.session.documentSize.height / 2 + textSize.height / 2) : nil
                try self.session.setTextRaster(image: CIImage(cgImage: cg), existingID: existing?.id, text: value,
                    fontName: font.fontName, fontSize: size, color: [c.red, c.green, c.blue, c.alpha], position: position, context: self.context)
            }
        }); present(alert, animated: true)
    }
    private func newDocument() {
        menu("New document", items: [("HD · 1920 × 1080", { [weak self] in self?.createDocument(CGSize(width: 1920, height: 1080)) }),
            ("Square · 1080 × 1080", { [weak self] in self?.createDocument(CGSize(width: 1080, height: 1080)) }),
            ("Portrait · 1080 × 1920", { [weak self] in self?.createDocument(CGSize(width: 1080, height: 1920)) }),
            ("A4 · 2480 × 3508 · 300 dpi", { [weak self] in self?.createDocument(CGSize(width: 2480, height: 3508), dpi: 300) }),
            ("Custom size…", { [weak self] in self?.customDocument() })], anchor: headerButtons[1])
    }
    private func customDocument() {
        let alert = UIAlertController(title: "New document", message: "Width, height and DPI. Up to 16,000 pixels per side / 64 megapixels.", preferredStyle: .alert)
        for value in ["1920", "1080", "72"] { alert.addTextField { $0.text = value; $0.keyboardType = .numberPad } }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak self] _ in
            guard let f = alert.textFields, let w = Double(f[0].text ?? ""), let h = Double(f[1].text ?? ""), let dpi = Double(f[2].text ?? "") else { return }; self?.createDocument(CGSize(width: w, height: h), dpi: dpi)
        }); present(alert, animated: true)
    }
    private func createDocument(_ size: CGSize, dpi: Double = 72) {
        menu("Canvas background", items: [("White", { [weak self] in self?.replaceDocument(size, dpi: dpi, color: .white) }),
            ("Transparent", { [weak self] in self?.replaceDocument(size, dpi: dpi, color: nil) }),
            ("Current colour", { [weak self] in guard let self else { return }; self.replaceDocument(size, dpi: dpi, color: CIColor(color: self.foreground)) })], anchor: headerButtons[1])
    }
    private func replaceDocument(_ size: CGSize, dpi: Double, color: CIColor?) {
        edit { try session.newDocument(size: size, background: color, dpi: dpi); clearSelection(); maskEditing = false; cloneSource = nil; canvas.fit(); status.text = "New canvas · Undo restores your previous document." }
    }
    private func pick(_ mode: String) {
        guard permitsEditing() else { return }; finishGesture(); pickerMode = mode
        let types: [UTType] = mode == "image" ? [.image] : mode == "project" ? [UTType(filenameExtension: "netvistaphoto") ?? .data] : [.data, .image]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true); picker.delegate = self
        picker.allowsMultipleSelection = mode != "project"; present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if pickerMode == "export" { cleanupExport(); status.text = "Saved a copy to Files."; return }
        guard permitsEditing() else { return }
        if pickerMode == "brush" { importBrushURLs(urls); return }
        for url in urls {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let limit = pickerMode == "project" ? PhotoEditingSession.maximumProjectBytes : 128 * 1024 * 1024
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= limit else { throw PhotoBrushError.invalid("This file exceeds the import limit.") }
                let data = try Data(contentsOf: url)
                if pickerMode == "project" { try loadProject(data, name: url.lastPathComponent) }
                else {
                    guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw PhotoBrushError.invalid("This image could not be decoded.") }
                    try session.addRaster(image, name: url.lastPathComponent); refresh(); saveDraft()
                }
            } catch { report(error) }
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cleanupExport(); status.text = "Cancelled · your document is unchanged." }
    func loadProject(_ data: Data, name: String) throws {
        finishGesture(); try session.load(data: data, projectURL: docs.appendingPathComponent(name), imageResolver: { _ in nil })
        clearSelection(); maskEditing = false; cloneSource = nil; canvas.fit(); refresh(); saveDraft()
    }
    private func exportProject() { exportFile(extension: "netvistaphoto") { state, context in try PhotoEditingSession(snapshot: state).encodedProject(context: context) } }
    private func exportImage() {
        menu("Export full-resolution image", items: [("PNG · transparency", { [weak self] in self?.exportRaster(jpeg: false) }),
            ("JPEG · white background", { [weak self] in self?.exportRaster(jpeg: true) })], anchor: headerButtons[5])
    }
    private func exportRaster(jpeg: Bool) {
        exportFile(extension: jpeg ? "jpg" : "png") { state, context in
            guard let image = PhotoRenderEngine.composite(state.layers, documentSize: state.documentSize, maxSide: nil, bypassAdjustments: false, opaqueBackground: jpeg),
                  let cg = context.createCGImage(image, from: image.extent) else { throw PhotoBrushError.invalid("Unable to render this document on this device.") }
            let data = NSMutableData(); guard let dest = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil) else { throw PhotoBrushError.invalid("Image encoder unavailable.") }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.95, kCGImagePropertyDPIWidth: state.dpi, kCGImagePropertyDPIHeight: state.dpi] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw PhotoBrushError.invalid("Image encoding failed.") }; return data as Data
        }
    }
    func exportFile(extension ext: String, encode: @escaping (PhotoDocumentSnapshot, CIContext) throws -> Data) {
        guard permitsEditing(), !preparingExport, pendingExport == nil else { return }
        finishGesture(); let state = session.state, context = context
        preparingExport = true; refreshAccess()
        status.text = "Preparing full-resolution file…"
        fileQueue.async { [weak self] in
            do {
                let data = try encode(state, context), url = FileManager.default.temporaryDirectory.appendingPathComponent("NetVista-photo-\(UUID().uuidString).\(ext)")
                try data.write(to: url, options: .atomic)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { try? FileManager.default.removeItem(at: url); return }
                    self.preparingExport = false; self.refreshAccess()
                    guard self.viewIfLoaded?.window != nil, self.permitsEditing() else {
                        try? FileManager.default.removeItem(at: url)
                        self.status.text = "Export was not opened. Return to this editor and export again."
                        return
                    }
                    guard self.presentedViewController == nil else { try? FileManager.default.removeItem(at: url); self.status.text = "Finish the open dialog, then export again."; return }
                    self.pendingExport = url; self.pickerMode = "export"
                    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true); picker.delegate = self; self.present(picker, animated: true)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }; self.preparingExport = false; self.refreshAccess()
                    if self.viewIfLoaded?.window != nil { self.report(error) }
                    else { self.status.text = error.localizedDescription }
                }
            }
        }
    }
    private func cleanupExport() { if let url = pendingExport { try? FileManager.default.removeItem(at: url) }; pendingExport = nil }
    nonisolated private static func importBrush(_ data: Data, name: String, extension ext: String, context: CIContext) throws -> (brushes: [PhotoBrush], warnings: [String]) {
        let imported: [PhotoBrush]
        if ext.lowercased() == "abr" { let report = try PhotoABR.readReport(data, name: name); return (report.brushes, report.warnings) }
        else if ext.lowercased() == "netvistabrush" {
            let brush = try JSONDecoder().decode(PhotoBrush.self, from: data)
            guard brush.isValid else { throw PhotoBrushError.invalid("Invalid NetVista brush tip.") }; imported = [brush]
        } else if let image = CIImage(data: data, options: [.applyOrientationProperty: true]) { imported = [try sampledBrush(image, name: name, context: context)] }
        else { throw PhotoBrushError.invalid("Choose an ABR pack, .netvistabrush file, or image tip.") }
        return (imported, [])
    }
    nonisolated private static func sampledBrush(_ source: CIImage, name: String, context: CIContext) throws -> PhotoBrush {
        guard PhotoPixels.validSize(source.extent.size) else { throw PhotoBrushError.invalid("Invalid tip image size.") }
        let factor = min(1, 512 / max(source.extent.width, source.extent.height))
        let image = PhotoRenderEngine.normalized(source).transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let w = max(1, Int(image.extent.width)), h = max(1, Int(image.extent.height)); var rgba = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &rgba, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let coverage = stride(from: 0, to: rgba.count, by: 4).map { i -> UInt8 in
            let alpha = Double(rgba[i + 3]); guard alpha > 0 else { return 0 }
            let light = (Double(rgba[i]) + Double(rgba[i + 1]) + Double(rgba[i + 2])) / 3
            return UInt8(max(0, min(255, alpha - light)))
        }
        guard coverage.contains(where: { $0 > 0 }) else { throw PhotoBrushError.invalid("Use dark marks on white or transparent pixels to define a brush.") }
        return PhotoBrush(name: name, kind: "sample", hardness: 1, width: w, height: h, samples: Data(coverage))
    }
    private func importBrushURLs(_ urls: [URL]) {
        guard !brushImportBusy else { status.text = "Wait for the current brush import to finish."; return }
        guard !urls.isEmpty, urls.count <= 32 else { showError("Choose up to 32 brush files per import."); return }
        runBrushLibraryWork { existing, context in
            var library = existing, notes: [String] = [], importedCount = 0
            for url in urls {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let limit = 128 * 1024 * 1024
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= limit else { throw PhotoBrushError.invalid("File exceeds 128 MB.") }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard data.count <= limit else { throw PhotoBrushError.invalid("File exceeds 128 MB.") }
                    let result = try Self.importBrush(data, name: url.deletingPathExtension().lastPathComponent, extension: url.pathExtension, context: context)
                    let next = library + result.brushes
                    guard next.count <= 1024, next.reduce(0, { $0 + ($1.samples?.count ?? 0) }) <= 64 * 1024 * 1024 else {
                        throw PhotoBrushError.invalid("Library limit: 1,024 tips / 64 MB of sampled tips. Import a smaller pack.")
                    }
                    library = next; importedCount += result.brushes.count
                    notes += result.warnings.map { "\(url.lastPathComponent): \($0)" }
                } catch { notes.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            return (library, importedCount, notes)
        }
    }
    /// One serialized mutation may run at a time. Selection/settings remain
    /// available, but Define and another Import cannot race this captured library.
    private func runBrushLibraryWork(_ produce: @escaping ([PhotoBrush], CIContext) throws -> (library: [PhotoBrush], importedCount: Int, notes: [String])) {
        guard permitsEditing(), !brushImportBusy else { return }
        finishGesture(); brushImportBusy = true; lastBrushImportReport = ""; buildProperties()
        status.text = "Reading brush tips… You can keep painting."
        let existing = brushes, context = context, destination = brushURL
        brushImportQueue.async { [weak self] in
            do {
                let result = try produce(existing, context)
                if result.importedCount > 0 {
                    guard result.library.count <= 1024, result.library.allSatisfy(\.isValid),
                          result.library.reduce(0, { $0 + ($1.samples?.count ?? 0) }) <= 64 * 1024 * 1024 else { throw PhotoBrushError.invalid("Brush library exceeds its limits.") }
                    let encoded = try JSONEncoder().encode(result.library)
                    guard encoded.count <= 96 * 1024 * 1024 else { throw PhotoBrushError.invalid("The encoded brush library exceeds 96 MB.") }
                    try encoded.write(to: destination, options: .atomic)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }; self.brushImportBusy = false
                    self.lastBrushImportReport = result.notes.joined(separator: "\n\n")
                    if result.importedCount > 0 {
                        self.brushes = result.library; self.brushIndex = existing.count
                        let selected = self.brushes[self.brushIndex]; self.hardness = selected.hardness
                        if let diameter = selected.diameter { self.brushSize = diameter }
                    }
                    self.buildProperties()
                    self.status.text = "Imported \(result.importedCount) tips. " + (result.notes.isEmpty ? "Select a brush and paint." : "Open Brush import report for compatibility details.")
                    if !result.notes.isEmpty, self.view.window != nil { self.showError(result.notes.prefix(8).joined(separator: "\n\n") + (result.notes.count > 8 ? "\n\nSee Brush import report for all details." : "")) }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }; self.brushImportBusy = false; self.lastBrushImportReport = error.localizedDescription
                    self.buildProperties(); self.status.text = "Brush import failed: \(error.localizedDescription)"
                    if self.view.window != nil { self.showError(error.localizedDescription) }
                }
            }
        }
    }
    private func saveBrushTip() {
        guard brushes.indices.contains(brushIndex) else { return }
        var brush = brushes[brushIndex]; brush.hardness = hardness; brush.diameter = brushSize
        exportFile(extension: "netvistabrush") { _, _ in
            guard brush.isValid else { throw PhotoBrushError.invalid("This brush tip has invalid settings.") }
            return try JSONEncoder().encode(brush)
        }
    }
    private func defineBrush() {
        guard permitsEditing(), !brushImportBusy else { status.text = "Wait for the brush import to finish before defining a tip."; return }
        finishGesture()
        guard let layer = session.selectedLayer, !layer.extras.isGroup, !layer.extras.isAdjustment else { return }
        prompt("Brush name", value: layer.name) { [weak self] name in
            guard let self, !self.brushImportBusy else { return }
            let selection = self.localSelection(layer), source = layer.sourceImage
            self.runBrushLibraryWork { existing, context in
                var image = source
                if let selection {
                    image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: source.extent), kCIInputMaskImageKey: selection])
                    if let bounds = PhotoPixels.maskBounds(selection, context: context) { image = PhotoRenderEngine.normalized(image.cropped(to: bounds)) }
                }
                let brush = try Self.sampledBrush(image, name: name, context: context)
                return (existing + [brush], 1, [])
            }
        }
    }
}
