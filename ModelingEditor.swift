import Cocoa
import SceneKit
import simd

private extension ModelPoint {
    var scn: SCNVector3 { SCNVector3(x,y,z) }
    init(_ v: SCNVector3) { self.init(x:Double(v.x),y:Double(v.y),z:Double(v.z)) }
}
private enum SculptPhase { case begin, update, end, hover, cancel }
private final class ModelingSlider: NSStackView {
    private let slider: NSSlider, valueLabel = NSTextField(labelWithString:"")
    private let change: (Double) -> Void
    init(_ title:String, value:Double, range:ClosedRange<Double>, change:@escaping (Double)->Void) {
        slider = NSSlider(value:value,minValue:range.lowerBound,maxValue:range.upperBound,target:nil,action:nil); self.change = change
        super.init(frame:.zero); orientation = .vertical; alignment = .leading; spacing = 5
        addArrangedSubview(gameRow([gameLabel(title,strong:true),valueLabel])); addArrangedSubview(slider)
        slider.widthAnchor.constraint(equalToConstant:220).isActive = true
        slider.isContinuous = true; slider.target = self; slider.action = #selector(updated)
        valueLabel.stringValue = String(format:"%.2f",value)
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func updated() { valueLabel.stringValue = String(format:"%.2f",slider.doubleValue); change(slider.doubleValue) }
}
private final class SculptCursor: NSView {
    var ring: [NSPoint] = [] { didSet { needsDisplay = true } }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect:NSRect) {
        guard let first = ring.first else { return }
        let path = NSBezierPath(); path.move(to:first); ring.dropFirst().forEach { path.line(to:$0) }; path.close()
        NSColor.black.withAlphaComponent(0.6).setStroke(); path.lineWidth = 3; path.stroke()
        NSColor.systemOrange.setStroke(); path.lineWidth = 1.3; path.stroke()
    }
}
private final class ModelingViewport: SCNView {
    var picked: ((SCNHitTestResult?,NSEvent.ModifierFlags) -> Void)?
    var vertexWorld: (() -> SCNVector3?)?
    var draggedVertex: ((ModelPoint,Bool) -> Void)?
    var sculpting = false
    var sculpt: ((NSPoint,NSEvent.ModifierFlags,SculptPhase) -> Void)?
    var contextualMenu: ((NSPoint) -> NSMenu)?
    let brushCursor = SculptCursor()
    private var sculptDrag = false
    private var tracking: NSTrackingArea?
    private var depth: CGFloat?
    private var offset = NSPoint.zero
    private var didDrag = false
    override func menu(for event:NSEvent) -> NSMenu? { contextualMenu?(convert(event.locationInWindow,from:nil)) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect:.zero,options:[.activeInKeyWindow,.mouseMoved,.mouseEnteredAndExited,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(tracking!)
        if brushCursor.superview == nil { addSubview(brushCursor) }
        brushCursor.frame = bounds; brushCursor.autoresizingMask = [.width,.height]
    }
    override func mouseMoved(with event:NSEvent) { if sculpting { sculpt?(convert(event.locationInWindow,from:nil),event.modifierFlags,.hover) } else { super.mouseMoved(with:event) } }
    override func mouseExited(with event:NSEvent) { brushCursor.ring = [] }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow,from:nil)
        if sculpting && !event.modifierFlags.contains(.option) { sculptDrag = true; sculpt?(p,event.modifierFlags,.begin); return }
        let hit = hitTest(p,options:[.categoryBitMask:5]).first // meshes (1) + vertex handles (4), not the ground grid
        if !event.modifierFlags.contains(.option) {
            picked?(hit,event.modifierFlags)
            if hit?.node.name?.hasPrefix("vertex:") == true, let world = vertexWorld?() {
                let projected = projectPoint(world); depth = projected.z
                offset = NSPoint(x:projected.x-p.x,y:projected.y-p.y); didDrag = false; return
            }
        }
        super.mouseDown(with:event)
    }
    override func mouseDragged(with event: NSEvent) {
        if sculptDrag { sculpt?(convert(event.locationInWindow,from:nil),event.modifierFlags,.update); return }
        if let depth { didDrag = true; let p = convert(event.locationInWindow,from:nil); draggedVertex?(ModelPoint(unprojectPoint(SCNVector3(p.x+offset.x,p.y+offset.y,depth))),false) }
        else { super.mouseDragged(with:event) }
    }
    override func mouseUp(with event: NSEvent) {
        if sculptDrag { sculpt?(convert(event.locationInWindow,from:nil),event.modifierFlags,.end); sculptDrag = false; return }
        if let depth {
            if didDrag { let p = convert(event.locationInWindow,from:nil); draggedVertex?(ModelPoint(unprojectPoint(SCNVector3(p.x+offset.x,p.y+offset.y,depth))),true) }
            self.depth = nil
        } else { super.mouseUp(with:event) }
    }
}

/// A modelling document is independent of game/video scenes. Reuses the native
/// property controls, but edits indexed topology rather than game behaviours.
final class ModelingEditorController: NSViewController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onShowStudioHome: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var document: ModelingDocument
    private(set) var projectURL: URL?
    private var saved: ModelingDocument
    private var selection: UUID?
    private var face: Int?, vertex: Int?
    private var selectedFaces = Set<Int>()
    private var faceSelection: Set<Int> {
        guard let face, !selectedFaces.contains(face) else { return selectedFaces }
        return selectedFaces.union([face])
    }
    private var mode = 0 // Object / Face / Vertex
    private var wireframe = false
    private var undoSteps: [ModelingDocument] = [], redoSteps: [ModelingDocument] = []
    private var dragStart: ModelingDocument?
    private var eventMonitor: Any?
    private let viewport = ModelingViewport()
    private let table = NSTableView(), properties = GameScroll()
    private let titleField = NSTextField(), status = NSTextField(labelWithString:"")
    private var undoButton: GameButton!, redoButton: GameButton!
    private var modePicker: GamePopup!
    private var extrusion: Double = 0.25, inset: Double = 0.2
    private var snap = false
    private var brush = ModelingBrush.draw
    private var brushRadius = 0.25, brushStrength = 0.5
    private var symmetry = false, frontOnly = true, subtract = false
    private var autoSculptDetail = true
    private var detail = ModelingDetail.balanced
    private var revision = 0
    private var sculptSource: ModelingMesh?
    private let physics = ModelingPhysicsPreview()
    private var physicsConfigured = false
    private var physicsWindow: NSWindow?, assistWindow: NSWindow?
    private var physicsPanel: ModelingPhysicsController?
    private var proportional = false
    private var axisLock = 0
    private var sculptStart: ModelingDocument?
    private var sculptTopology: ModelingSculptTopology?
    private var sculptCenter = ModelPoint(), sculptNormal = ModelPoint()
    private var sculptDepth: CGFloat = 0
    private var sculptPointer = NSPoint.zero, lastStamp: NSPoint?
    private var strokeBrush = ModelingBrush.draw
    private var faceScale = 1.2
    private var propertiesTab = 0
    private var loopDirection = 0, loopPosition = 0.5, showingLoopCut = false
    private var loopPreviewNode: SCNNode?
    private weak var loopCutMessage: NSTextField?
    private weak var loopApplyButton: GameButton?
    private weak var loopCutHeader: NSView?
    private var loopPreviewCache: (revision:Int,id:UUID,face:Int,direction:Int,low:ModelingLoopCutPreview,high:ModelingLoopCutPreview)?
    private var index: Int? { document.objects.firstIndex { $0.id == selection } }
    private var object: ModelingObject? { index.map { document.objects[$0] } }
    private var faceMaps: [UUID:[Int]] = [:]
    private var nodes: [UUID:SCNNode] = [:]
    private var markers: SCNNode?
    private var dirty: Bool { document != saved }

    init(document: ModelingDocument = ModelingDocument(), url: URL? = nil) {
        self.document = document; saved = document; projectURL = url; selection = document.objects.first?.id
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
    override func loadView() {
        view = NSView(frame:NSRect(x:0,y:0,width:1280,height:840)); view.appearance = NSAppearance(named:.darkAqua); view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite:0.1,alpha:1).cgColor
        titleField.stringValue = document.name; titleField.target = self; titleField.action = #selector(renameDocument)
        titleField.widthAnchor.constraint(greaterThanOrEqualToConstant:120).isActive = true
        undoButton = GameButton("Undo") { [weak self] in self?.undoEdit() }; redoButton = GameButton("Redo") { [weak self] in self?.redoEdit() }
        let header = gameRow([GameButton("Studio Home") { [weak self] in self?.onShowStudioHome?() },gameLabel("3D EDITOR",strong:true),titleField,GameButton("Open…") { [weak self] in self?.openProject() },GameButton("Save") { [weak self] in _ = self?.save(false) },GameButton("Save As…") { [weak self] in _ = self?.save(true) },GameButton("Export OBJ…") { [weak self] in self?.exportOBJ() }])
        modePicker = GamePopup(["Object mode","Face mode","Vertex mode","Sculpt mode"]) { [weak self] value in self?.setMode(value) }
        let tools = gameRow([undoButton,redoButton,modePicker,GameButton("Frame all") { [weak self] in self?.frameAll() },GameButton("Focus · F") { [weak self] in self?.focusSelection() },GamePopup(["Solid","Wireframe"]) { [weak self] value in self?.stopPhysics(); self?.wireframe = value == 1; self?.render() },GamePopup(["Free move","Snap 0.1"]) { [weak self] value in self?.snap = value == 1 },GamePopup(["Perspective","Front","Right","Top","Back","Left","Bottom"]) { [weak self] in self?.setView($0) }])
        let sidebar = GameScroll()
        let column = NSTableColumn(identifier:.init("object")); column.width = 184; table.addTableColumn(column); table.headerView = nil
        table.dataSource = self; table.delegate = self; table.rowHeight = 28; table.backgroundColor = NSColor(calibratedWhite:0.075,alpha:1)
        let objectScroll = NSScrollView(); objectScroll.documentView = table; objectScroll.hasVerticalScroller = true
        objectScroll.heightAnchor.constraint(equalToConstant:180).isActive = true
        for child in [gameLabel("SCENE COLLECTION",strong:true),objectScroll,gameRow([GameButton("Duplicate") { [weak self] in self?.duplicate() },GameButton("Delete object") { [weak self] in self?.deleteObject() }]),gameLabel("ADD MESH",strong:true)] as [NSView] { sidebar.add(child,fill:true) }
        for names in [["Cube","Sphere"],["Plane","Cylinder"]] { sidebar.add(gameRow(names.map { name in GameButton(name) { [weak self] in self?.addPrimitive(name) } })) }
        sidebar.add(GamePopup(["Detail: Draft","Detail: Balanced","Detail: High"],selected:1) { [weak self] in self?.detail = [ModelingDetail.draft,.balanced,.high][$0] },fill:true)
        sidebar.add(GameButton("Sculpt sphere") { [weak self] in self?.addSculptSphere() },fill:true)
        sidebar.add(GameButton("Dragon starter") { [weak self] in self?.addDragon() },fill:true)
        sidebar.add(GameButton("Import OBJ…") { [weak self] in self?.importOBJ() },fill:true)
        sidebar.add(gameLabel("MODELING TOOLS",strong:true))
        sidebar.add(GameButton("Sculpt surface") { [weak self] in self?.setMode(3) },fill:true)
        sidebar.add(GameButton("Join visible meshes…") { [weak self] in self?.joinVisible() },fill:true)
        sidebar.add(GameButton("Local AI helper…") { [weak self] in self?.openAssist() },fill:true)
        sidebar.add(GameButton("Physics preview…") { [weak self] in self?.openPhysics() },fill:true)
        let help = NSTextField(wrappingLabelWithString:"Right-click the model for tools.\n\nOption-drag: orbit · Scroll: zoom\nTab: Object / Face · A: all faces\nE: extrude · I: inset · Control-R: cut\nL: linked faces · M: sculpt mask\nShift: smooth · Control: invert\n[ / ]: brush size · Esc: cancel")
        help.font = .systemFont(ofSize:11); help.textColor = .secondaryLabelColor; sidebar.add(help,fill:true)
        viewport.allowsCameraControl = true; viewport.antialiasingMode = .multisampling4X; viewport.backgroundColor = NSColor(calibratedWhite:0.08,alpha:1)
        for v in [header,tools,sidebar,viewport,properties,status] { view.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo:view.topAnchor,constant:12),header.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12),header.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),header.heightAnchor.constraint(equalToConstant:32),
            tools.topAnchor.constraint(equalTo:header.bottomAnchor,constant:10),tools.leadingAnchor.constraint(equalTo:header.leadingAnchor),tools.heightAnchor.constraint(equalToConstant:30),tools.trailingAnchor.constraint(lessThanOrEqualTo:view.trailingAnchor,constant:-12),
            sidebar.topAnchor.constraint(equalTo:tools.bottomAnchor,constant:16),sidebar.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:4),sidebar.widthAnchor.constraint(equalToConstant:214),sidebar.bottomAnchor.constraint(equalTo:status.topAnchor,constant:-12),
            viewport.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:12),viewport.topAnchor.constraint(equalTo:sidebar.topAnchor),viewport.bottomAnchor.constraint(equalTo:status.topAnchor,constant:-10),viewport.trailingAnchor.constraint(equalTo:properties.leadingAnchor,constant:-8),
            properties.topAnchor.constraint(equalTo:viewport.topAnchor),properties.bottomAnchor.constraint(equalTo:viewport.bottomAnchor),properties.widthAnchor.constraint(equalToConstant:252),properties.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-4),
            status.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:14),status.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),status.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-10),status.heightAnchor.constraint(equalToConstant:20)
        ])
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        viewport.picked = { [weak self] hit,flags in self?.pick(hit,extending:flags.contains(.shift)) }
        viewport.vertexWorld = { [weak self] in guard let self, let o = self.object, let v = self.vertex, o.mesh.vertices.indices.contains(v) else { return nil }; return o.world(o.mesh.vertices[v]).scn }
        viewport.draggedVertex = { [weak self] p,finish in self?.dragVertex(p,finished:finish) }
        viewport.sculpt = { [weak self] p,flags,phase in self?.sculptAt(p,flags:flags,phase:phase) }
        viewport.contextualMenu = { [weak self] point in self?.contextMenu(at:point) ?? NSMenu() }
        physics.onUpdate = { [weak self] in self?.physicsUpdated() }
        createScene(); refresh(); frameAll()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self, event.window === self.view.window else { return event }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" { _ = self.save(event.modifierFlags.contains(.shift)); return nil }
            guard !(self.view.window?.firstResponder is NSTextView) else { return event }
            if event.keyCode == 53, self.sculptStart != nil { self.finishSculpt(cancel:true); return nil }
            if self.sculptStart != nil { return event }
            if event.keyCode == 53, self.showingLoopCut { self.showingLoopCut = false; self.render(); self.inspector(); return nil }
            if !event.modifierFlags.contains(.command), event.keyCode == 48 { self.setMode(self.mode == 0 ? 1 : 0); return nil }
            if !event.modifierFlags.contains(.command), self.mode == 1 {
                switch event.charactersIgnoringModifiers {
                case "a": self.selectAllFaces(clear:event.modifierFlags.contains(.option)); return nil
                case "e": self.extrudeSelectedFaces(); return nil
                case "i": self.insetSelectedFaces(); return nil
                case "l": self.adjustFaceSelection("linked"); return nil
                case "r" where event.modifierFlags.contains(.control): self.previewLoopCut(); return nil
                default: break
                }
            }
            if !event.modifierFlags.contains(.command), self.mode == 3, event.charactersIgnoringModifiers == "m" {
                if event.modifierFlags.contains(.option) { self.edit { $0.mesh.clearSculptMask() } }
                else { self.brush = .mask; self.inspector() }; return nil
            }
            if self.mode == 3, let key = event.charactersIgnoringModifiers, ["[","]"].contains(key) {
                self.brushRadius = max(0.001,min(1000,self.brushRadius * (key == "[" ? 0.8 : 1.25))); self.inspector(); return nil
            }
            if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "z" { event.modifierFlags.contains(.shift) ? self.redoEdit() : self.undoEdit(); return nil }
                if event.charactersIgnoringModifiers == "d" { self.duplicate(); return nil }
            } else if event.charactersIgnoringModifiers == "f" { self.focusSelection(); return nil }
            else if [51,117].contains(event.keyCode) { self.deleteSelection(); return nil }
            return event
        }
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.delegate = self; view.window?.acceptsMouseMovedEvents = true; updateTitle() }
    func windowDidResignKey(_ notification:Notification) { finishSculpt() }
    func numberOfRows(in tableView:NSTableView) -> Int { document.objects.count }
    func tableView(_ tableView:NSTableView, viewFor tableColumn:NSTableColumn?, row:Int) -> NSView? { gameLabel("\(document.objects[row].visible ? "◈" : "○")  \(document.objects[row].name)",strong:true) }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard table.selectedRow >= 0, document.objects.indices.contains(table.selectedRow) else { return }
        guard selection != document.objects[table.selectedRow].id else { return }
        finishSculpt()
        selectedFaces.removeAll()
        selection = document.objects[table.selectedRow].id; face = nil; vertex = nil; render(); inspector()
    }
    private func setMode(_ value:Int) { stopPhysics(); finishSculpt(); view.window?.makeFirstResponder(nil); mode = value; if value != 0 { propertiesTab = 0 }; showingLoopCut = false; viewport.sculpting = value == 3; viewport.brushCursor.ring = []; modePicker.selectItem(at:value); face = nil; vertex = nil; selectedFaces.removeAll(); render(); inspector() }
    private func pick(_ hit:SCNHitTestResult?, extending:Bool = false) {
        stopPhysics()
        guard let hit else { return }
        if let name = hit.node.name, name.hasPrefix("vertex:"), let value = Int(name.dropFirst(7)), mode == 2 {
            vertex = value; face = nil; render(); inspector(); return
        }
        guard let name = hit.node.name, let id = UUID(uuidString:name), let i = document.objects.firstIndex(where: { $0.id == id }) else { return }
        let keepFaces = selection == id && extending ? faceSelection : []
        table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false); selection = id
        vertex = nil
        face = mode == 1 ? faceMaps[id].flatMap { $0.indices.contains(hit.faceIndex) ? $0[hit.faceIndex] : nil } : nil
        selectedFaces = keepFaces
        if let face {
            if extending && selectedFaces.contains(face) { selectedFaces.remove(face); self.face = selectedFaces.sorted().first }
            else { selectedFaces.insert(face) }
        }
        render(); inspector()
    }
    private func selectAllFaces(clear:Bool = false) {
        selectedFaces = clear ? [] : Set(object?.mesh.faces.indices ?? 0..<0)
        face = selectedFaces.sorted().first; render(); inspector()
    }
    private func extrudeSelectedFaces() {
        let faces = faceSelection
        guard !faces.isEmpty, abs(extrusion) > 0.00001 else { return }
        edit { try $0.mesh.extrudeRegion(faces,distance:extrusion) }
    }
    private func insetSelectedFaces() {
        let faces = faceSelection
        guard !faces.isEmpty else { return }
        edit { try $0.mesh.extrudeIndividualFaces(faces,distance:0,inset:self.inset) }
    }
    private func extrudeIndividualFaces() {
        let faces = faceSelection
        guard !faces.isEmpty, abs(extrusion) > 0.00001 else { return }
        edit { try $0.mesh.extrudeIndividualFaces(faces,distance:self.extrusion) }
    }
    private func adjustFaceSelection(_ operation:String) {
        guard let object, !faceSelection.isEmpty else { return }
        do { selectedFaces = try object.mesh.adjustedFaceSelection(faceSelection,operation:operation); face = selectedFaces.sorted().first; render(); inspector() }
        catch { show(error) }
    }
    private func previewLoopCut() {
        guard let object, let f = face, object.mesh.faces.indices.contains(f) else { return }
        do {
            _ = try currentLoopPreview(object,face:f); showingLoopCut = true; propertiesTab = 0; render(); inspector()
            view.layoutSubtreeIfNeeded()
            if let document = properties.documentView, let header = loopCutHeader, let button = loopApplyButton {
                let rect = header.convert(header.bounds,to:document).union(button.convert(button.bounds,to:document)).insetBy(dx:0,dy:-6)
                document.scrollToVisible(rect)
            }
        }
        catch { showingLoopCut = false; show(error) }
    }
    private func applyLoopCut() {
        guard showingLoopCut, let i = index, let f = face else { return }
        do {
            var candidate = document
            let result = try candidate.objects[i].mesh.loopCut(face:f,direction:loopDirection,fraction:loopPosition)
            try candidate.validate(); stopPhysics(); remember(document); document = candidate
            selectedFaces = result; face = f; showingLoopCut = false; refresh()
        } catch { show(error) }
    }
    private func contextMenu(at point:NSPoint) -> NSMenu {
        let hit = viewport.hitTest(point,options:[.categoryBitMask:1]).first
        if let hit, let id = hit.node.name.flatMap(UUID.init(uuidString:)) {
            let pickedFace = faceMaps[id].flatMap { $0.indices.contains(hit.faceIndex) ? $0[hit.faceIndex] : nil }
            if id != selection || (mode == 1 && pickedFace.map { !faceSelection.contains($0) } == true) { pick(hit) }
        }
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title:String,_ action:String,_ enabled:Bool = true) {
            let item = NSMenuItem(title:title,action:#selector(contextAction(_:)),keyEquivalent:"")
            item.target = self; item.representedObject = action; item.isEnabled = enabled; menu.addItem(item)
        }
        add("Focus selection","focus",object != nil)
        if mode == 1 {
            let selected = !faceSelection.isEmpty
            add("Extrude region","extrude",selected); add("Extrude individual faces","individual",selected); add("Inset individual faces","inset",selected)
            add("Preview loop cut…","cut",face.map { object?.mesh.faces.indices.contains($0) == true && object?.mesh.faces[$0].count == 4 } ?? false)
            menu.addItem(.separator())
            add("Grow selection","grow",selected); add("Shrink selection","shrink",selected); add("Select linked faces","linked",selected)
            add("Delete selected faces","delete",selected)
        } else {
            add("Edit faces","faces",object != nil); add("Sculpt surface","sculpt",object != nil)
            add("Duplicate object","duplicate",object != nil); add("Delete object","deleteobject",object != nil)
        }
        menu.addItem(.separator()); add("Object mode","objects"); add("Frame all","all")
        return menu
    }
    @objc private func contextAction(_ sender:NSMenuItem) {
        switch sender.representedObject as? String {
        case "focus": focusSelection()
        case "all": frameAll()
        case "objects": setMode(0)
        case "faces": setMode(1)
        case "sculpt": setMode(3)
        case "duplicate": duplicate()
        case "delete": deleteSelection()
        case "deleteobject": deleteObject()
        case "extrude": extrudeSelectedFaces()
        case "individual": extrudeIndividualFaces()
        case "inset": insetSelectedFaces()
        case "cut": previewLoopCut()
        case "grow","shrink","linked": adjustFaceSelection(sender.representedObject as! String)
        default: break
        }
    }
    private func trimHistory() {
        // A logical estimate, not a claim about process RSS. Retain at least
        // the latest complete operation, even for very large meshes.
        func bytes(_ d:ModelingDocument) -> Int { d.objects.reduce(0) { $0 + $1.mesh.vertices.count*32 + $1.mesh.faces.reduce(0) { $0+32+$1.count*8 } } }
        while undoSteps.count > 1 && (undoSteps.count > 30 || undoSteps.reduce(0) { $0+bytes($1) } > 192*1024*1024) { undoSteps.removeFirst() }
    }
    private func remember(_ before:ModelingDocument) { undoSteps.append(before); trimHistory(); redoSteps.removeAll(); revision += 1 }
    private func change(_ operation:(inout ModelingDocument) throws -> Void) {
        stopPhysics(); finishSculpt()
        do { var candidate = document; try operation(&candidate); try candidate.validate(); guard candidate != document else { return }; showingLoopCut = false; remember(document); document = candidate; refresh() }
        catch { show(error) }
    }
    private func edit(_ operation:(inout ModelingObject) throws -> Void) { guard let i = index else { return }; change { try operation(&$0.objects[i]) } }
    private func undoEdit() { stopPhysics(); finishSculpt(); guard let previous = undoSteps.popLast() else { return }; redoSteps.append(document); revision += 1; document = previous; showingLoopCut = false; face = nil; vertex = nil; selectedFaces.removeAll(); refresh() }
    private func redoEdit() { stopPhysics(); finishSculpt(); guard let next = redoSteps.popLast() else { return }; undoSteps.append(document); trimHistory(); revision += 1; document = next; showingLoopCut = false; face = nil; vertex = nil; selectedFaces.removeAll(); refresh() }
    private func refresh() {
        titleField.stringValue = document.name
        if index == nil { selection = document.objects.first?.id; face = nil; vertex = nil; selectedFaces.removeAll() }
        let keepFace = face, keepVertex = vertex
        table.reloadData(); if let i = index { table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false) }
        face = keepFace; vertex = keepVertex
        if let f = face, object?.mesh.faces.indices.contains(f) != true { face = nil }
        let validFaces = object?.mesh.faces.indices ?? 0..<0
        selectedFaces = selectedFaces.filter(validFaces.contains)
        if let v = vertex, object?.mesh.vertices.indices.contains(v) != true { vertex = nil }
        render(); inspector(); updateTitle()
    }
    private func updateTitle() { view.window?.title = "\(document.name) — 3D Editor"; view.window?.isDocumentEdited = dirty; view.window?.representedURL = projectURL; undoButton?.isEnabled = !undoSteps.isEmpty; redoButton?.isEnabled = !redoSteps.isEmpty }
    @objc private func renameDocument() { let name = String(titleField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).prefix(256)); if !name.isEmpty { change { $0.name = name } } }
    @objc private func renameObject(_ field:NSTextField) { let name = String(field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).prefix(256)); if !name.isEmpty { edit { $0.name = name } } }
    private func addPrimitive(_ name:String) { let o = ModelingObject(name:name,mesh:.primitive(name)); selection = o.id; face = nil; vertex = nil; selectedFaces.removeAll(); change { $0.objects.append(o) }; focusSelection() }
    private func addSculptSphere() {
        do {
            let level = detail == .draft ? 1 : detail == .high ? 3 : 2
            var o = ModelingObject(name:"Sculpt sphere",mesh:try .sculptSphere(detail:level)); o.smoothShading = true
            selection = o.id; change { $0.objects.append(o) }; setMode(3); focusSelection()
        } catch { show(error) }
    }
    private func addDragon() {
        do {
            let parts = try ModelingGenerators.dragon(detail:detail)
            change { $0.objects.append(contentsOf:parts) }
            if document.objects.contains(where:{ $0.id == parts.first?.id }) {
                selection = parts.first?.id; setMode(3); refresh(); frame(parts)
                status.stringValue = "Editable dragon starter — select a part, then sculpt its surface. Parts are separate, not a welded character or rig."
            }
        } catch { show(error) }
    }
    private func joinVisible() {
        let parts = document.objects.filter(\.visible)
        guard parts.count > 1 else { status.stringValue = "Show at least two meshes to join them."; return }
        let alert = NSAlert(); alert.messageText = "Join \(parts.count) visible meshes?"
        alert.informativeText = "This combines their geometry with transforms baked and uses one surface colour. It does not weld intersecting surfaces or preserve separate physics bodies. You can undo this."
        alert.addButton(withTitle:"Join meshes"); alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            var joined = ModelingObject(name:"Joined model",mesh:try .joined(parts)); joined.smoothShading = true
            let ids = Set(parts.map(\.id)); change { $0.objects.removeAll { ids.contains($0.id) }; $0.objects.append(joined) }
            if document.objects.contains(where:{ $0.id == joined.id }) { selection = joined.id; face = nil; vertex = nil; selectedFaces.removeAll(); refresh(); focusSelection() }
        } catch { show(error) }
    }
    private func subdivide(_ smooth:Bool) {
        guard let o = object else { return }
        do {
            let estimate = try o.mesh.subdivisionEstimate(smooth:smooth)
            let otherV = document.objects.reduce(0) { $0+$1.mesh.vertices.count }-o.mesh.vertices.count
            let otherF = document.objects.reduce(0) { $0+$1.mesh.faces.count }-o.mesh.faces.count
            guard estimate.withinLimit, otherV+estimate.vertices <= ModelingLimits.projectVertices, otherF+estimate.faces <= ModelingLimits.projectFaces else {
                throw ModelingError.invalid("That detail level exceeds the safe mesh/scene budget. Use a smaller selected part instead.")
            }
            face = nil; vertex = nil; selectedFaces.removeAll()
            edit { try $0.mesh.subdivide(smooth:smooth); if smooth { $0.smoothShading = true } }
        } catch { show(error) }
    }
    private func aiContext() -> ModelingAIContext {
        .init(objectCount:document.objects.count,selectedName:object.map { String($0.name.prefix(128)) },selectedVertices:object?.mesh.vertices.count ?? 0,selectedFaces:object?.mesh.faces.count ?? 0)
    }
    private func openAssist() {
        finishSculpt()
        if let window = assistWindow { window.makeKeyAndOrderFront(nil); return }
        let controller = ModelingAssistController(context:{ [weak self] in self?.aiContext() ?? .init() },stamp:{ [weak self] in "\(self?.revision ?? 0)/\(self?.selection?.uuidString ?? "")" },apply:{ [weak self] plan in
            guard let self else { throw ModelingError.invalid("The modeling project is closed.") }; try self.applyAIPlan(plan)
        })
        assistWindow = toolWindow(controller,title:"NetVista Studio — Local Modeling Helper",size:NSSize(width:680,height:640))
    }
    private func applyAIPlan(_ plan:ModelingAIPlan) throws {
        stopPhysics(); finishSculpt()
        try plan.validate(context:aiContext())
        let selectedID = selection
        var candidate = document
        for action in plan.actions {
            switch action.kind {
            case .addPrimitive:
                let primitive = action.primitive!
                let mesh = primitive == "Sculpt Sphere" ? try ModelingMesh.sculptSphere() : ModelingMesh.primitive(primitive)
                var object = ModelingObject(name:action.name ?? primitive,mesh:mesh)
                if let p = action.position { object.position = p }; if let r = action.rotation { object.rotation = r }; if let s = action.scale { object.scale = s }
                if let c = action.colour { object.colour = c }; if primitive == "Sculpt Sphere" { object.smoothShading = true }
                candidate.objects.append(object)
            case .dragonStarter: candidate.objects += try ModelingGenerators.dragon(detail:.balanced)
            case .subdivideSelected:
                guard let i = candidate.objects.firstIndex(where:{ $0.id == selectedID }) else { throw ModelingError.invalid("Select a mesh first.") }
                for _ in 0..<(action.levels ?? 1) { try candidate.objects[i].mesh.subdivide(smooth:true) }
                candidate.objects[i].smoothShading = true
            case .smoothSelected:
                guard let i = candidate.objects.firstIndex(where:{ $0.id == selectedID }) else { throw ModelingError.invalid("Select a mesh first.") }
                try candidate.objects[i].mesh.relax(iterations:action.iterations ?? 1)
                candidate.objects[i].smoothShading = true
            }
            try candidate.validate() // Reject the whole transaction, never leave partial work.
        }
        if candidate != document { remember(document); document = candidate; refresh(); frameAll() }
        status.stringValue = "Applied local helper plan: \(plan.title). Undo restores the entire change."
    }
    private func toolWindow(_ controller:NSViewController,title:String,size:NSSize) -> NSWindow {
        let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = title; window.minSize = NSSize(width:min(size.width,620),height:min(size.height,450)); window.contentViewController = controller
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named:.darkAqua); window.center(); window.makeKeyAndOrderFront(nil); return window
    }
    private func openPhysics() {
        finishSculpt()
        if let window = physicsWindow { physicsPanel?.refresh(); window.makeKeyAndOrderFront(nil); return }
        let panel = ModelingPhysicsController(read:{ [weak self] in
            guard let self else { return (.stopped,0,0) }; return (self.physics.state,self.physics.time,self.physics.dynamicBodyCount)
        },play:{ [weak self] in self?.playPhysics() },pause:{ [weak self] in self?.physics.pause() },step:{ [weak self] in self?.playPhysics(step:true) },reset:{ [weak self] in self?.physics.reset() },bake:{ [weak self] in self?.bakePhysics() })
        physicsPanel = panel; physicsWindow = toolWindow(panel,title:"NetVista Studio — Physics Preview",size:NSSize(width:640,height:450))
    }
    private func playPhysics(step:Bool = false) {
        finishSculpt(); view.window?.makeFirstResponder(nil)
        if !physicsConfigured && mode != 0 { setMode(0) }
        do {
            if !physicsConfigured {
                let participants = document.objects.filter(\.visible).compactMap { object -> ModelingPhysicsParticipant? in
                    guard let node = nodes[object.id] else { return nil }; return .init(id:object.id,node:node,settings:object.physics ?? .init())
                }
                try physics.configure(participants:participants)
                physicsConfigured = true
            }
            guard physics.dynamicBodyCount > 0 else { status.stringValue = "Set at least one visible object's Physics mode to Dynamic body in its properties."; physicsPanel?.refresh(); return }
            if step { physics.step() } else { physics.play() }; physicsUpdated()
        } catch { stopPhysics(); show(error) }
    }
    private func stopPhysics() {
        guard physicsConfigured else { return }; physicsConfigured = false; physics.end(); physicsPanel?.refresh()
    }
    private func physicsUpdated() {
        guard physicsConfigured else { physicsPanel?.refresh(); return }
        viewport.needsDisplay = true
        status.stringValue = String(format:"Physics preview · %.2f s · %d dynamic bodies · saved geometry is unchanged until Bake",physics.time,physics.dynamicBodyCount)
        physicsPanel?.refresh()
    }
    private func bakePhysics() {
        guard physicsConfigured, physics.time > 0 else { return }; physics.pause()
        var candidate = document
        for i in candidate.objects.indices where candidate.objects[i].physics?.mode == .dynamic && candidate.objects[i].visible {
            let o = candidate.objects[i]
            candidate.objects[i].mesh.vertices = o.mesh.vertices.map { v in
                let p = o.world(v)
                guard let result = physics.transformedPoint(for:o.id,x:p.x,y:p.y,z:p.z) else { return v }
                return o.local(.init(x:result.x,y:result.y,z:result.z))
            }
        }
        stopPhysics()
        do { try candidate.validate(); if candidate != document { remember(document); document = candidate; refresh() }; status.stringValue = "Baked the current physics pose to geometry. One Undo restores the original model." }
        catch { render(); show(error) }
    }
    private func finishSculpt(cancel:Bool = false) {
        guard let before = sculptStart else { return }
        if cancel { document = before; render() } else if document != before { remember(before) }
        sculptStart = nil; sculptSource = nil; sculptTopology = nil; lastStamp = nil
        inspector(); updateTitle()
    }
    private func surfaceHit(_ p:NSPoint) -> SCNHitTestResult? {
        // Mesh-only hits: the ground must not steal a sculpt stroke. Use the
        // result's own normal rather than translating a triangle ID across a
        // topology/presentation update (see brushNormal).
        viewport.hitTest(p,options:[.categoryBitMask:1,.searchMode:SCNHitTestSearchMode.closest.rawValue]).first { hit in
            guard let name = hit.node.name else { return false }; return UUID(uuidString:name) != nil
        }
    }
    private func cursor(at hit:SCNHitTestResult?) {
        guard let hit, let o = object, hit.node.name == o.id.uuidString else { viewport.brushCursor.ring = []; return }
        let c = o.local(ModelPoint(hit.worldCoordinates))
        let n = brushNormal(hit,on:o)
        guard n.length > 0.5 else { viewport.brushCursor.ring = []; return }
        let tangent = n.cross(abs(n.y) < 0.9 ? ModelPoint(y:1) : ModelPoint(x:1)).unit, bitangent = n.cross(tangent).unit
        viewport.brushCursor.ring = (0..<48).map { i in
            let angle = Double(i)*2 * .pi/48
            let point = viewport.projectPoint(o.world(c+(tangent*cos(angle)+bitangent*sin(angle))*brushRadius).scn)
            return NSPoint(x:point.x,y:point.y)
        }
    }
    private func brushNormal(_ hit:SCNHitTestResult,on object:ModelingObject) -> ModelPoint {
        // A hit carries its own geometric surface normal. Triangle IDs may
        // still refer to last frame after topology prep; never reinterpret an
        // old ID through a new face map. World → local normal uses the
        // transpose of the object's linear transform, not point conversion.
        let n = ModelPoint(hit.worldNormal).rotated(object.rotation,inverse:true)
        return ModelPoint(x:n.x*object.scale.x,y:n.y*object.scale.y,z:n.z*object.scale.z).unit
    }
    private func sculptAt(_ p:NSPoint, flags:NSEvent.ModifierFlags, phase:SculptPhase) {
        if phase == .cancel { finishSculpt(cancel:true); return }
        if phase == .end { finishSculpt(); return }
        if phase == .begin { stopPhysics() }
        var hit = surfaceHit(p)
        if phase == .hover { cursor(at:hit); return }
        if phase == .begin {
            guard let firstHit = hit else { return }
            // Select the object under the brush, but never switch mid-stroke.
            if firstHit.node.name != selection?.uuidString { pick(firstHit) }
            guard let i = index else { return }
            sculptStart = document
            do {
                if autoSculptDetail && document.objects[i].mesh.vertices.count < 200 {
                    var prepared = document.objects[i].mesh
                    while prepared.faces.count < 512 && !prepared.faces.isEmpty {
                        let estimate = try prepared.subdivisionEstimate()
                        let otherVertices = document.objects.reduce(0) { $0+$1.mesh.vertices.count }-document.objects[i].mesh.vertices.count
                        let otherFaces = document.objects.reduce(0) { $0+$1.mesh.faces.count }-document.objects[i].mesh.faces.count
                        guard estimate.withinLimit, estimate.vertices+otherVertices <= ModelingLimits.projectVertices, estimate.faces+otherFaces <= ModelingLimits.projectFaces else { break }
                        try prepared.subdivide()
                    }
                    document.objects[i].mesh = prepared
                    face = nil; vertex = nil; selectedFaces.removeAll()
                    render(only:document.objects[i].id); hit = surfaceHit(p)
                }
            } catch { finishSculpt(cancel:true); show(error); return }
            guard let hit, let o = object else { finishSculpt(cancel:true); return }
            sculptSource = o.mesh; sculptTopology = ModelingSculptTopology(o.mesh)
            sculptCenter = o.local(ModelPoint(hit.worldCoordinates)); sculptNormal = brushNormal(hit,on:o)
            sculptDepth = viewport.projectPoint(hit.worldCoordinates).z; sculptPointer = p; lastStamp = nil
            strokeBrush = flags.contains(.shift) ? .smooth : brush
        }
        guard let i = index, let before = sculptStart else { return }
        let activeBrush = flags.contains(.shift) ? ModelingBrush.smooth : strokeBrush
        if strokeBrush == .grab {
            // A grab evaluates from the original stroke mesh; pointer event rate
            // cannot accumulate movement or move the falloff region.
            let source = before.objects[i]
            let start = ModelPoint(viewport.unprojectPoint(SCNVector3(sculptPointer.x,sculptPointer.y,sculptDepth)))
            let end = ModelPoint(viewport.unprojectPoint(SCNVector3(p.x,p.y,sculptDepth)))
            var mesh = sculptSource ?? source.mesh
            mesh.sculpt(brush:.grab,center:sculptCenter,normal:sculptNormal,radius:brushRadius,strength:brushStrength,symmetry:symmetry,frontOnly:frontOnly,delta:source.local(end)-source.local(start),topology:sculptTopology)
            document.objects[i].mesh = mesh
        } else {
            // Resample the pointer path in screen space. A fast drag now lays a
            // connected line of stamps instead of leaving event-sized gaps.
            // One geometry upload per event keeps SceneKit work bounded.
            let origin = lastStamp ?? p, distance = hypot(p.x-origin.x,p.y-origin.y)
            let projectedRadius = viewport.brushCursor.ring.first.map { hypot($0.x-p.x,$0.y-p.y) } ?? 24
            let spacing = max(2,min(12,projectedRadius*0.12))
            if lastStamp != nil && distance < spacing { cursor(at:hit); return }
            let count = max(1,min(document.objects[i].mesh.vertices.count > 20_000 ? 4 : 16,Int(ceil(distance/spacing))))
            var touched = false
            for step in 1...count {
                let t = CGFloat(step)/CGFloat(count), point = NSPoint(x:origin.x+(p.x-origin.x)*t,y:origin.y+(p.y-origin.y)*t)
                guard let sample = surfaceHit(point), sample.node.name == document.objects[i].id.uuidString else { continue }
                let center = document.objects[i].local(ModelPoint(sample.worldCoordinates)), normal = brushNormal(sample,on:document.objects[i])
                document.objects[i].mesh.sculpt(brush:activeBrush,center:center,normal:normal,radius:brushRadius,strength:brushStrength,invert:subtract != flags.contains(.control),symmetry:symmetry,frontOnly:frontOnly,topology:sculptTopology)
                touched = true
            }
            lastStamp = touched ? p : nil
            guard touched else { viewport.brushCursor.ring = []; return }
        }
        render(only:document.objects[i].id); cursor(at:surfaceHit(p))
    }
    private func duplicate() { guard var o = object else { return }; o.id = UUID(); o.name = String((o.name+" copy").prefix(256)); o.position.x += 1; selection = o.id; face = nil; vertex = nil; selectedFaces.removeAll(); change { $0.objects.append(o) } }
    private func deleteObject() {
        finishSculpt(); guard let id = selection else { return }
        face = nil; vertex = nil; selectedFaces.removeAll(); change { $0.objects.removeAll { $0.id == id } }
    }
    private func deleteSelection() {
        if mode == 1, !faceSelection.isEmpty {
            let faces = faceSelection; selectedFaces.removeAll(); face = nil
            edit { $0.mesh.deleteFaces(faces) }; inspector(); return
        }
        if mode == 2 { status.stringValue = "To remove geometry, switch to Face mode and delete faces. Vertex deletion is not supported yet."; return }
        if mode == 0 || mode == 3 { deleteObject() }
    }
    private func dragVertex(_ world:ModelPoint, finished:Bool) {
        if dragStart == nil { stopPhysics() }
        guard [world.x,world.y,world.z].allSatisfy(\.isFinite) else { return }
        guard let i = index, let v = vertex, document.objects[i].mesh.vertices.indices.contains(v) else { return }
        if dragStart == nil { dragStart = document }
        var p = document.objects[i].local(world)
        func bounded(_ value:Double) -> Double { max(-100000,min(100000,snap ? (value*10).rounded()/10 : value)) }
        p.x = bounded(p.x); p.y = bounded(p.y); p.z = bounded(p.z)
        guard let original = dragStart?.objects[i] else { return }
        let origin = original.mesh.vertices[v]
        if axisLock != 0 {
            if axisLock != 1 { p.x = origin.x }; if axisLock != 2 { p.y = origin.y }; if axisLock != 3 { p.z = origin.z }
        }
        if proportional {
            let delta = p-origin
            document.objects[i].mesh.vertices = original.mesh.vertices.map { point in
                (point+delta*ModelingMesh.influence(distance:(point-origin).length,radius:brushRadius)).bounded
            }
        } else { document.objects[i].mesh.vertices[v] = p }
        render(only:document.objects[i].id)
        if finished { if let before = dragStart, before != document { remember(before) }; dragStart = nil; inspector(); updateTitle() }
    }
    private func inspector() {
        properties.clear(); properties.add(gameLabel("MESH PROPERTIES",strong:true))
        guard let o = object else {
            let hint = NSTextField(wrappingLabelWithString:"Start modelling\n\nAdd a Cube, Sphere, Plane or Cylinder from the left. Switch to Face mode to extrude and inset, or Vertex mode to reshape individual points.")
            properties.add(hint,fill:true); return
        }
        let name = NSTextField(string:o.name); name.target = self; name.action = #selector(renameObject(_:)); properties.add(name,fill:true)
        properties.add(gameLabel("\(o.mesh.vertices.count) vertices · \(o.mesh.faces.count) faces"))
        let tabs = NSSegmentedControl(labels:["Geometry","Transform","Physics"],trackingMode:.selectOne,target:self,action:#selector(propertiesTabChanged(_:)))
        tabs.segmentStyle = .rounded; tabs.selectedSegment = propertiesTab; properties.add(tabs,fill:true)
        if propertiesTab == 1 { addTransformProperties(o); return }
        if propertiesTab == 2 { addPhysicsProperties(o); return }
        if mode == 3 {
            properties.add(gameLabel("SCULPT BRUSH",strong:true))
            let picker = GamePopup(ModelingBrush.allCases.map(\.rawValue)) { [weak self] value in self?.brush = ModelingBrush.allCases[value]; self?.inspector() }
            picker.selectItem(at:ModelingBrush.allCases.firstIndex(of:brush) ?? 0); properties.add(picker,fill:true)
            let description = NSTextField(wrappingLabelWithString:brush.help); description.font = .systemFont(ofSize:11); description.textColor = .secondaryLabelColor; properties.add(description,fill:true)
            properties.add(ModelingSlider("Radius",value:brushRadius,range:0.01...max(1,brushRadius*2)) { [weak self] in self?.brushRadius = $0 })
            properties.add(ModelingSlider("Strength",value:brushStrength,range:0.01...1) { [weak self] in self?.brushStrength = $0 })
            let direction = GamePopup(brush == .mask ? ["Paint mask","Erase mask"] : ["Add / raise","Subtract / carve"]) { [weak self] in self?.subtract = $0 == 1 }; direction.selectItem(at:subtract ? 1 : 0); properties.add(direction)
            let mirror = GamePopup(["Symmetry off","Mirror X"]) { [weak self] in self?.symmetry = $0 == 1 }; mirror.selectItem(at:symmetry ? 1 : 0); properties.add(mirror)
            let surface = GamePopup(["Front-facing only","Through surface"]) { [weak self] in self?.frontOnly = $0 == 0 }; surface.selectItem(at:frontOnly ? 0 : 1); properties.add(surface)
            let detailToggle = GamePopup(["Auto sculpt detail: On","Auto sculpt detail: Off"]) { [weak self] in self?.autoSculptDetail = $0 == 0 }; detailToggle.selectItem(at:autoSculptDetail ? 0 : 1); properties.add(detailToggle,fill:true)
            properties.add(gameLabel("SCULPT MASK",strong:true))
            let masked = o.mesh.sculptMask?.filter { $0 > 0.01 }.count ?? 0
            properties.add(gameLabel("\(masked) protected vertices · dark = masked"))
            properties.add(gameRow([GameButton("Clear mask") { [weak self] in self?.edit { $0.mesh.clearSculptMask() } },GameButton("Invert mask") { [weak self] in self?.edit { $0.mesh.invertSculptMask() } }]))
            let hint = NSTextField(wrappingLabelWithString:"Click and drag directly on any side of the mesh. Shift smooths; Control reverses. Option-drag orbits; use Back/Left views for hidden sides.\n\nAuto detail adds geometry to sparse meshes on your first stroke, preserving the silhouette. Preparation + stroke = one undo. Masked regions stay fixed.")
            hint.font = .systemFont(ofSize:11); hint.textColor = .secondaryLabelColor; properties.add(hint,fill:true)
        }
        if mode == 1 {
            properties.add(gameLabel(faceSelection.isEmpty ? "Click a face to select" : "\(faceSelection.count) FACES SELECTED",strong:true))
            let hint = NSTextField(wrappingLabelWithString:"Shift-click adds/removes faces. A selects all; Option-A clears. E extrudes a connected region; I insets individual faces.")
            hint.font = .systemFont(ofSize:11); hint.textColor = .secondaryLabelColor; properties.add(hint,fill:true)
            properties.add(gameRow([GameButton("Select all") { [weak self] in self?.selectAllFaces() },GameButton("Deselect") { [weak self] in self?.selectAllFaces(clear:true) }]))
            for row in [[("Grow","grow"),("Shrink","shrink")],[("Select linked · L","linked")]] {
                properties.add(gameRow(row.map { title,operation in
                    let button = GameButton(title) { [weak self] in self?.adjustFaceSelection(operation) }
                    button.isEnabled = !faceSelection.isEmpty; return button
                }))
            }
            properties.add(gameLabel("EXTRUSION",strong:true))
            properties.add(gameRow([gameLabel("Distance"),GameNumber(extrusion,range: -1000...1000) { [weak self] in self?.extrusion = $0 }]))
            let extrude = GameButton("Extrude region · E") { [weak self] in self?.extrudeSelectedFaces() }; extrude.isEnabled = !faceSelection.isEmpty; properties.add(extrude)
            let individual = GameButton("Extrude individual faces") { [weak self] in self?.extrudeIndividualFaces() }; individual.isEnabled = !faceSelection.isEmpty; properties.add(individual)
            properties.add(gameRow([gameLabel("Inset fraction"),GameNumber(inset,range:0.01...0.95) { [weak self] in self?.inset = $0 }]))
            let insetButton = GameButton("Inset individual faces · I") { [weak self] in self?.insetSelectedFaces() }; insetButton.isEnabled = !faceSelection.isEmpty; properties.add(insetButton)
            let delete = GameButton("Delete selected faces") { [weak self] in self?.deleteSelection() }; delete.isEnabled = !faceSelection.isEmpty; properties.add(delete)
            let move = GameButton("Move region along normal") { [weak self] in guard let self else { return }; let faces = self.faceSelection; self.edit { try $0.mesh.moveRegion(faces,distance:self.extrusion) } }; move.isEnabled = !faceSelection.isEmpty; properties.add(move)
            properties.add(gameRow([gameLabel("Scale factor"),GameNumber(faceScale,range:0.01...10) { [weak self] in self?.faceScale = $0 }]))
            let scale = GameButton("Scale selected region") { [weak self] in guard let self else { return }; let faces = self.faceSelection; self.edit { try $0.mesh.scaleRegion(faces,factor:self.faceScale) } }; scale.isEnabled = !faceSelection.isEmpty; properties.add(scale)
            let cutHeader = gameLabel("LOOP CUT",strong:true); properties.add(cutHeader); loopCutHeader = cutHeader
            let direction = GamePopup(["Direction A","Direction B"],selected:loopDirection) { [weak self] value in self?.loopDirection = value; self?.renderLoopCut() }
            direction.toolTip = "Cut through either pair of opposite edges on the active quad."; properties.add(direction,fill:true)
            properties.add(ModelingSlider("Cut position",value:loopPosition,range:0.01...0.99) { [weak self] value in self?.loopPosition = value; self?.renderLoopCut() })
            let preview = GameButton("Preview loop cut · Control-R") { [weak self] in self?.previewLoopCut() }
            preview.isEnabled = face.map { o.mesh.faces.indices.contains($0) && o.mesh.faces[$0].count == 4 } ?? false; properties.add(preview,fill:true)
            let message = NSTextField(wrappingLabelWithString:"Select a quad, preview the yellow cut, then Apply. The cut follows connected quads; triangles and non-manifold edges are refused.")
            message.font = .systemFont(ofSize:11); message.textColor = .secondaryLabelColor; properties.add(message,fill:true); loopCutMessage = message
            if showingLoopCut {
                let apply = GameButton("Apply loop cut") { [weak self] in self?.applyLoopCut() }; loopApplyButton = apply
                properties.add(gameRow([apply,GameButton("Cancel") { [weak self] in self?.showingLoopCut = false; self?.renderLoopCut(); self?.inspector() }]))
            }
            renderLoopCut()
        }
        if mode == 2 {
            let axes = GamePopup(["Free drag","X axis only","Y axis only","Z axis only"]) { [weak self] in self?.axisLock = $0 }; axes.selectItem(at:axisLock); properties.add(axes)
            let falloff = GamePopup(["Single vertex","Proportional editing"]) { [weak self] in self?.proportional = $0 == 1 }; falloff.selectItem(at:proportional ? 1 : 0); properties.add(falloff)
            properties.add(ModelingSlider("Influence radius",value:brushRadius,range:0.01...max(1,brushRadius*2)) { [weak self] in self?.brushRadius = $0 })
            properties.add(gameLabel(vertex.map { "VERTEX \($0+1) · LOCAL POSITION" } ?? "Click a vertex dot to edit",strong:true))
            if let v = vertex, o.mesh.vertices.indices.contains(v) {
                for (caption,key) in [("X",\ModelPoint.x),("Y",\ModelPoint.y),("Z",\ModelPoint.z)] {
                    properties.add(gameRow([gameLabel(caption),GameNumber(o.mesh.vertices[v][keyPath:key],range: -100000...100000) { [weak self] value in self?.edit { $0.mesh.vertices[v][keyPath:key] = value } }]))
                }
            }
            if o.mesh.vertices.count > 2500 { properties.add(gameLabel("Dots limited to first 2,500 vertices.")) }
        }
        properties.add(gameLabel("SURFACE & TOPOLOGY",strong:true))
        properties.add(GameButton(o.smoothShading == true ? "Shading: Smooth → Flat" : "Shading: Flat → Smooth") { [weak self] in self?.edit { $0.smoothShading = !($0.smoothShading ?? false) } })
        if let next = try? o.mesh.subdivisionEstimate() { properties.add(gameLabel("Next detail: \(next.vertices) vertices / \(next.faces) faces")) }
        properties.add(GameButton("Subdivide · preserve shape") { [weak self] in self?.subdivide(false) },fill:true)
        properties.add(GameButton("Smooth subdivide · round shape") { [weak self] in self?.subdivide(true) },fill:true)
        properties.add(gameRow([gameLabel("Surface"),GameColourWell(Self.colour(o.colour)) { [weak self] colour in guard self?.selection == o.id else { return }; self?.edit { $0.colour = colour } }]))
    }
    @objc private func propertiesTabChanged(_ control:NSSegmentedControl) {
        view.window?.makeFirstResponder(nil); propertiesTab = max(0,min(2,control.selectedSegment)); inspector()
    }
    private func addTransformProperties(_ o:ModelingObject) {
        properties.add(gameLabel("OBJECT TRANSFORM",strong:true))
        for (title,key,range) in [("Position",\ModelingObject.position,-100000.0...100000),("Rotation °",\ModelingObject.rotation,-100000.0...100000),("Scale",\ModelingObject.scale,0.001...1000)] {
            properties.add(gameLabel(title,strong:true))
            for (axis,coordinate) in [("X",\ModelPoint.x),("Y",\ModelPoint.y),("Z",\ModelPoint.z)] {
                properties.add(gameRow([gameLabel(axis),GameNumber(o[keyPath:key][keyPath:coordinate],width:130,range:range) { [weak self] value in self?.edit { $0[keyPath:key][keyPath:coordinate] = value } }]))
            }
        }
        properties.add(GameButton(o.visible ? "Hide object" : "Show object") { [weak self] in self?.edit { $0.visible.toggle() } })
        properties.add(GameButton("Apply transforms to mesh") { [weak self] in self?.edit { object in object.mesh.vertices = object.mesh.vertices.map { object.world($0) }; object.position = .init(); object.rotation = .init(); object.scale = .init(x:1,y:1,z:1) } })
        let hint = NSTextField(wrappingLabelWithString:"Transforms affect the whole object in every editing mode. Geometry controls change the mesh itself. Apply transforms bakes the current pose into the vertices.")
        hint.font = .systemFont(ofSize:11); hint.textColor = .secondaryLabelColor; properties.add(hint,fill:true)
    }
    private func addPhysicsProperties(_ o:ModelingObject) {
        properties.add(gameLabel("RIGID-BODY PHYSICS",strong:true))
        let settings = o.physics ?? .init()
        let physicsMode = GamePopup(ModelingPhysicsMode.allCases.map(\.title)) { [weak self] value in
            self?.edit { if $0.physics == nil { $0.physics = .init() }; $0.physics!.mode = ModelingPhysicsMode.allCases[value] }
        }
        physicsMode.selectItem(at:ModelingPhysicsMode.allCases.firstIndex(of:settings.mode) ?? 0); properties.add(physicsMode,fill:true)
        if settings.mode != .off {
            for (title,key,range) in [("Mass",\ModelingPhysicsSettings.mass,0.01...10000.0),("Friction",\ModelingPhysicsSettings.friction,0.0...1.0),("Bounce",\ModelingPhysicsSettings.restitution,0.0...1.0),("Damping",\ModelingPhysicsSettings.damping,0.0...1.0)] {
                properties.add(gameRow([gameLabel(title),GameNumber(settings[keyPath:key],width:110,range:range) { [weak self] value in self?.edit { if $0.physics == nil { $0.physics = .init() }; $0.physics![keyPath:key] = value } }]))
            }
            let gravity = GamePopup(["Gravity on","Gravity off"]) { [weak self] value in self?.edit { if $0.physics == nil { $0.physics = .init() }; $0.physics!.affectedByGravity = value == 0 } }; gravity.selectItem(at:settings.affectedByGravity ? 0 : 1); properties.add(gravity)
        }
        let physicsHelp = NSTextField(wrappingLabelWithString:"Optional box colliders and rigid bodies. Ground is Y = 0. Preview does not change your model until you press Bake. No soft-body or cloth simulation.")
        physicsHelp.font = .systemFont(ofSize:11); physicsHelp.textColor = .secondaryLabelColor; properties.add(physicsHelp,fill:true)
        properties.add(GameButton("Open Physics preview…") { [weak self] in self?.openPhysics() },fill:true)
    }
    private static func colour(_ hex:String) -> NSColor { let value = UInt32(hex.dropFirst(),radix:16) ?? 0x92A9BE; return NSColor(srgbRed:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:1) }
    private func createScene() {
        let scene = SCNScene(); scene.background.contents = NSColor(calibratedRed:0.085,green:0.095,blue:0.11,alpha:1)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.zNear = 0.05; camera.camera?.zFar = 10000; camera.position = SCNVector3(4,3,5); camera.look(at:SCNVector3Zero); scene.rootNode.addChildNode(camera)
        let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni; light.light?.intensity = 1100; light.position = SCNVector3(4,8,5); scene.rootNode.addChildNode(light)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 500; scene.rootNode.addChildNode(ambient)
        for i in -20...20 { for axis in [true,false] {
            let n = SCNNode(geometry:SCNBox(width:axis ? 40 : 0.012,height:0.005,length:axis ? 0.012 : 40,chamferRadius:0)); n.position = SCNVector3(axis ? 0 : Double(i),-0.002,axis ? Double(i) : 0)
            n.geometry?.firstMaterial?.diffuse.contents = i == 0 ? (axis ? NSColor.systemRed.withAlphaComponent(0.4) : NSColor.systemBlue.withAlphaComponent(0.4)) : NSColor(calibratedWhite:0.18,alpha:1)
            n.categoryBitMask = 2 // navigation grid must never steal object/brush hits
            scene.rootNode.addChildNode(n)
        } }
        viewport.scene = scene; viewport.pointOfView = camera
    }
    private func render(only changedID:UUID? = nil) {
        // The simulator must never retain a node detached by a redraw.
        stopPhysics()
        guard let root = viewport.scene?.rootNode else { return }
        let selectedFaceIDs = faceSelection
        if let changedID { nodes.removeValue(forKey:changedID)?.removeFromParentNode(); faceMaps.removeValue(forKey:changedID) }
        else { nodes.values.forEach { $0.removeFromParentNode() }; nodes.removeAll(); faceMaps.removeAll() }
        markers?.removeFromParentNode()
        for o in document.objects where o.visible && (changedID == nil || changedID == o.id) {
            var positions: [SCNVector3] = [], colours: [Float] = [], normals: [SCNVector3] = [], mapping: [Int] = [], triangles: [UInt32] = []
            let world = o.mesh.vertices.map { o.world($0) }
            let smoothNormals = o.smoothShading == true ? ModelingMesh(vertices:world,faces:o.mesh.faces).vertexNormals() : []
            let indexed = !smoothNormals.isEmpty && mode != 1
            if indexed {
                // Shared vertex buffers make a dense sculpt use its actual
                // vertex count, rather than six copies per quad every stamp.
                positions = world.map(\.scn); normals = smoothNormals.map(\.scn)
                let c = Self.colour(o.colour)
                for i in world.indices {
                    let mask = mode == 3 && o.id == selection ? (o.mesh.sculptMask?[i] ?? 0) : 0, shade = Float(1-mask*0.8)
                    colours += [Float(c.redComponent)*shade,Float(c.greenComponent)*shade,Float(c.blueComponent)*shade,1]
                }
                for (f,indices) in o.mesh.faces.enumerated() { for j in 1..<indices.count-1 {
                    triangles += [UInt32(indices[0]),UInt32(indices[j]),UInt32(indices[j+1])]; mapping.append(f)
                } }
            } else { for (f,indices) in o.mesh.faces.enumerated() {
                let points = indices.map { world[$0] }
                let n = (points[1]-points[0]).cross(points[2]-points[0]).unit.scn
                let c = o.id == selection && selectedFaceIDs.contains(f) && mode == 1 ? NSColor.systemOrange.usingColorSpace(.sRGB)! : Self.colour(o.colour)
                for j in 1..<indices.count-1 {
                    for k in [0,j,j+1] {
                        positions.append(points[k].scn); normals.append(smoothNormals.isEmpty ? n : smoothNormals[indices[k]].scn)
                        let mask = mode == 3 && o.id == selection ? (o.mesh.sculptMask?[indices[k]] ?? 0) : 0
                        let shade = Float(1-mask*0.8)
                        colours += [Float(c.redComponent)*shade,Float(c.greenComponent)*shade,Float(c.blueComponent)*shade,1]
                    }
                    mapping.append(f)
                }
            }; triangles = Array(0..<UInt32(positions.count)) }
            let data = colours.withUnsafeBufferPointer { Data(buffer:$0) }
            let colorSource = SCNGeometrySource(data:data,semantic:.color,vectorCount:positions.count,usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)
            let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:positions),SCNGeometrySource(normals:normals),colorSource],elements:[SCNGeometryElement(indices:triangles,primitiveType:.triangles)])
            let material = SCNMaterial(); material.lightingModel = .lambert; material.isDoubleSided = true; material.fillMode = wireframe ? .lines : .fill
            material.diffuse.contents = NSColor.white; material.emission.contents = o.id == selection ? NSColor(calibratedWhite:0.045,alpha:1) : NSColor.black
            geometry.materials = [material]
            let node = SCNNode(geometry:geometry); node.name = o.id.uuidString; root.addChildNode(node); nodes[o.id] = node; faceMaps[o.id] = mapping
        }
        if mode == 2, let o = object, o.visible {
            let group = SCNNode(); let radius = max(0.006,min(0.12,extent(o)*0.008))
            for (i,p) in o.mesh.vertices.prefix(2500).enumerated() {
                let sphere = SCNSphere(radius:radius); sphere.segmentCount = 6
                sphere.firstMaterial?.diffuse.contents = vertex == i ? NSColor.systemOrange : NSColor.white; sphere.firstMaterial?.lightingModel = .constant
                let dot = SCNNode(geometry:sphere); dot.name = "vertex:\(i)"; dot.categoryBitMask = 4; dot.position = o.world(p).scn; group.addChildNode(dot)
            }
            root.addChildNode(group); markers = group
        }
        renderLoopCut()
        let selected = mode == 1 ? "\(faceSelection.count) faces selected" : mode == 2 ? (vertex.map { "Vertex \($0+1) selected" } ?? "No vertex selected") : (object?.name ?? "No object selected")
        status.stringValue = document.objects.isEmpty ? "Empty modelling project — add a mesh or a sculpt sphere to begin." : "\(document.objects.count) objects · \(document.objects.reduce(0) { $0+$1.mesh.faces.count }) faces · \(["Object","Face","Vertex","Sculpt"][mode]) · \(selected) · \(mode == 3 ? "Option-drag: orbit · Shift: smooth" : "Right-click: tools · F: focus")"
    }
    private func renderLoopCut() {
        loopPreviewNode?.removeFromParentNode(); loopPreviewNode = nil
        guard showingLoopCut, mode == 1, let o = object, o.visible, let f = face,
              o.mesh.faces.indices.contains(f), let root = viewport.scene?.rootNode else { loopApplyButton?.isEnabled = false; return }
        do {
            let preview = try currentLoopPreview(o,face:f)
            let positions = preview.segments.flatMap { [o.world($0.start).scn,o.world($0.end).scn] }
            let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:positions)],elements:[SCNGeometryElement(indices:Array(0..<UInt32(positions.count)),primitiveType:.line)])
            let material = SCNMaterial(); material.lightingModel = .constant; material.diffuse.contents = NSColor.systemYellow
            material.readsFromDepthBuffer = false; material.writesToDepthBuffer = false; geometry.materials = [material]
            let node = SCNNode(geometry:geometry); node.categoryBitMask = 8; node.renderingOrder = 10; root.addChildNode(node); loopPreviewNode = node
            loopCutMessage?.stringValue = "Preview: \(preview.faceCount) quads at \(Int((loopPosition*100).rounded()))% · result \(preview.result.vertices) vertices / \(preview.result.faces) faces. Apply creates one undo step."
            loopApplyButton?.isEnabled = true
        } catch {
            loopCutMessage?.stringValue = error.localizedDescription; loopApplyButton?.isEnabled = false
        }
        viewport.needsDisplay = true
    }
    private func currentLoopPreview(_ object:ModelingObject,face:Int) throws -> ModelingLoopCutPreview {
        // Topology is fixed while sliding. Cache the two endpoint plans so a
        // continuous position slider moves only the cut-line points, not a
        // quarter-million-face adjacency graph on every mouse event.
        if loopPreviewCache?.revision != revision || loopPreviewCache?.id != object.id || loopPreviewCache?.face != face || loopPreviewCache?.direction != loopDirection {
            loopPreviewCache = nil
            if let low = try? object.mesh.loopCutPreview(face:face,direction:loopDirection,fraction:0.01),
               let high = try? object.mesh.loopCutPreview(face:face,direction:loopDirection,fraction:0.99),low.result == high.result,low.faceCount == high.faceCount {
                loopPreviewCache = (revision,object.id,face,loopDirection,low,high)
            }
        }
        let preview:ModelingLoopCutPreview
        if let cache = loopPreviewCache {
            let t = (loopPosition-0.01)/0.98
            let segments = zip(cache.low.segments,cache.high.segments).map { low,high in
                ModelingCutSegment(start:low.start+(high.start-low.start)*t,end:low.end+(high.end-low.end)*t)
            }
            preview = .init(segments:segments,result:cache.low.result)
        } else {
            // A twisted strip may be valid only at its midpoint; preserve the
            // planner's exact refusal for off-centre positions in that case.
            preview = try object.mesh.loopCutPreview(face:face,direction:loopDirection,fraction:loopPosition)
        }
        guard document.objects.reduce(0,{ $0+$1.mesh.vertices.count })-object.mesh.vertices.count+preview.result.vertices <= ModelingLimits.projectVertices,
              document.objects.reduce(0,{ $0+$1.mesh.faces.count })-object.mesh.faces.count+preview.result.faces <= ModelingLimits.projectFaces else {
            throw ModelingError.invalid("This cut exceeds the project's total geometry budget. Remove other objects or reduce their detail first.")
        }
        return preview
    }
    private func extent(_ object:ModelingObject) -> Double {
        let p = object.mesh.vertices.map { object.world($0) }; guard let first = p.first else { return 1 }
        var low = first, high = first
        for v in p { low.x = min(low.x,v.x); low.y = min(low.y,v.y); low.z = min(low.z,v.z); high.x = max(high.x,v.x); high.y = max(high.y,v.y); high.z = max(high.z,v.z) }
        return max(high.x-low.x,max(high.y-low.y,high.z-low.z))
    }
    private func frame(_ objects:[ModelingObject]) {
        let p = objects.flatMap { object in object.mesh.vertices.map { object.world($0) } }
        guard let first = p.first else { return }; var low = first, high = first
        for v in p { low.x = min(low.x,v.x); low.y = min(low.y,v.y); low.z = min(low.z,v.z); high.x = max(high.x,v.x); high.y = max(high.y,v.y); high.z = max(high.z,v.z) }
        let c = (low+high)*0.5, size = max(0.3,(high-low).length)*1.4
        viewport.defaultCameraController.stopInertia()
        let camera = viewport.pointOfView
        let heading = camera.map { (ModelPoint($0.worldPosition)-ModelPoint(viewport.defaultCameraController.target)).unit } ?? ModelPoint(x:1,y:0.65,z:1).unit
        let up = camera.map { ModelPoint($0.worldUp) } ?? ModelPoint(y:1)
        SCNTransaction.begin(); SCNTransaction.disableActions = true
        // Keep depth precision useful for selection/unprojection at every model scale.
        viewport.pointOfView?.camera?.zNear = max(0.001,size/1000)
        viewport.pointOfView?.camera?.zFar = max(100,size*100)
        viewport.pointOfView?.camera?.orthographicScale = size*0.65
        viewport.pointOfView?.position = (c+heading*(size*1.55)).scn
        if let camera { aimCamera(camera,at:c,up:up) }
        viewport.defaultCameraController.target = c.scn
        SCNTransaction.commit(); SCNTransaction.flush(); viewport.needsDisplay = true
    }
    private func frameAll() { frame(document.objects.filter(\.visible)) }
    private func focusSelection() { if let object { frame([object]) } }
    private func aimCamera(_ camera:SCNNode,at center:ModelPoint,up:ModelPoint) {
        // An explicit orthonormal camera basis is stable for the 180-degree
        // Back view too. SceneKit's look-at overload can retain the old facing
        // at that antiparallel orientation on some native runtimes.
        let position = ModelPoint(camera.worldPosition), forward = (center-position).unit
        let right = forward.cross(up).unit, vertical = right.cross(forward).unit
        guard right.length > 0.5, vertical.length > 0.5 else { return }
        func vector(_ p:ModelPoint,_ w:Float) -> SIMD4<Float> { .init(Float(p.x),Float(p.y),Float(p.z),w) }
        camera.simdWorldTransform = simd_float4x4(columns:(vector(right,0),vector(vertical,0),vector(forward * -1,0),vector(position,1)))
    }
    private func setView(_ preset:Int) {
        guard let camera = viewport.pointOfView else { return }
        viewport.defaultCameraController.stopInertia()
        SCNTransaction.begin(); SCNTransaction.disableActions = true
        let points = document.objects.filter(\.visible).flatMap { o in o.mesh.vertices.map { o.world($0) } }
        let center = points.isEmpty ? ModelPoint() : points.reduce(ModelPoint(),+)*(1/Double(points.count))
        let distance = max(1,points.map { ($0-center).length }.max() ?? 1)*3.5
        camera.camera?.usesOrthographicProjection = preset != 0
        camera.camera?.orthographicScale = distance*0.65
        camera.camera?.zNear = max(0.001,distance/1000); camera.camera?.zFar = max(100,distance*100)
        let directions = [ModelPoint(x:1,y:0.65,z:1).unit,ModelPoint(z:1),ModelPoint(x:1),ModelPoint(y:1,z:0.0001),ModelPoint(z:-1),ModelPoint(x:-1),ModelPoint(y:-1,z:0.0001)]
        camera.position = (center+directions[max(0,min(6,preset))]*distance).scn
        aimCamera(camera,at:center,up:preset == 3 ? .init(z:-1) : preset == 6 ? .init(z:1) : .init(y:1))
        viewport.defaultCameraController.target = center.scn; viewport.brushCursor.ring = []
        SCNTransaction.commit(); SCNTransaction.flush(); viewport.needsDisplay = true
    }
    private func show(_ error:Error) { NSAlert(error:error).runModal() }
    private func openProject() { let panel = NSOpenPanel(); panel.allowedFileTypes = ["netvistamodel"]; if panel.runModal() == .OK, let url = panel.url { NSApp.delegate?.application?(NSApp,open:[url]) } }
    private func importOBJ() {
        let panel = NSOpenPanel(); panel.allowedFileTypes = ["obj"]; panel.message = "Import triangle/quad geometry. Materials, textures and rigs are not imported."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= ModelingLimits.objBytes else { throw ModelingError.invalid("Import an OBJ smaller than 64 MB.") }
            let mesh = try ModelingMesh.readOBJ(Data(contentsOf:url)); let o = ModelingObject(name:String(url.deletingPathExtension().lastPathComponent.prefix(256)),mesh:mesh)
            selection = o.id; face = nil; vertex = nil; selectedFaces.removeAll(); change { $0.objects.append(o) }; focusSelection()
        } catch { show(error) }
    }
    @discardableResult private func save(_ saveAs:Bool) -> Bool {
        finishSculpt()
        view.window?.makeFirstResponder(nil); renameDocument(); var url = projectURL
        if saveAs || url == nil {
            let panel = NSSavePanel(); panel.allowedFileTypes = ["netvistamodel"]; panel.nameFieldStringValue = document.name.replacingOccurrences(of:"/",with:"-")+".netvistamodel"
            panel.directoryURL = projectURL?.deletingLastPathComponent() ?? FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first
            guard panel.runModal() == .OK else { return false }; url = panel.url
        }
        guard let url else { return false }
        do { try document.save(url); projectURL = url; saved = document; updateTitle(); NSDocumentController.shared.noteNewRecentDocumentURL(url); status.stringValue = "Saved editable mesh geometry and objects."; return true } catch { show(error); return false }
    }
    private func exportOBJ() {
        finishSculpt()
        view.window?.makeFirstResponder(nil)
        do {
            let text = try document.obj()
            let panel = NSSavePanel(); panel.allowedFileTypes = ["obj"]; panel.nameFieldStringValue = document.name.replacingOccurrences(of:"/",with:"-")+".obj"; panel.directoryURL = FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first
            panel.message = "Exports visible geometry with transforms baked. Save a .netvistamodel to retain separate objects and colours."
            if panel.runModal() == .OK, let url = panel.url { try text.write(to:url,atomically:true,encoding:.utf8); status.stringValue = "Exported OBJ — ready to import into Game Maker, the video 3D Scene, or another modeller." }
        } catch { show(error) }
    }
    func confirmClose() -> Bool {
        stopPhysics()
        finishSculpt()
        view.window?.makeFirstResponder(nil); renameDocument(); guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to \(document.name)?"; alert.addButton(withTitle:"Save"); alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Don't Save")
        switch alert.runModal() { case .alertFirstButtonReturn: return save(false); case .alertThirdButtonReturn: return true; default: return false }
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { confirmClose() }
    func windowWillClose(_ notification:Notification) { stopPhysics(); assistWindow?.close(); physicsWindow?.close(); onClose?() }
    #if MODELING_EDITOR_CHECKS
    func checkModelingWorkflow() throws {
        change { $0.objects.removeAll() }; addPrimitive("Cube"); setMode(1)
        face = 5; selectedFaces = [5]; render(); inspector()
        func control<T:NSView>(_ type:T.Type,_ root:NSView,where predicate:(T)->Bool = { _ in true }) -> T? {
            if let result = root as? T, predicate(result) { return result }
            return root.subviews.compactMap { control(type,$0,where:predicate) }.first
        }
        guard let tabs = control(NSSegmentedControl.self,properties) else { preconditionFailure("Missing property tabs") }
        tabs.selectedSegment = 1; propertiesTabChanged(tabs)
        precondition(control(NSTextField.self,properties,where: { $0.stringValue == "OBJECT TRANSFORM" }) != nil)
        precondition(control(NSTextField.self,properties,where: { $0.stringValue == "RIGID-BODY PHYSICS" }) == nil,"Physics must not clutter Transform properties")
        tabs.selectedSegment = 2; propertiesTabChanged(tabs)
        precondition(control(NSTextField.self,properties,where: { $0.stringValue == "RIGID-BODY PHYSICS" }) != nil)
        precondition(control(NSTextField.self,properties,where: { $0.stringValue == "OBJECT TRANSFORM" }) == nil)
        tabs.selectedSegment = 0; propertiesTabChanged(tabs)
        guard let preview = control(GameButton.self,properties,where: { $0.title == "Preview loop cut · Control-R" }) else { preconditionFailure("Missing loop-cut preview") }
        let original = document, undoCount = undoSteps.count
        preview.invoke?()
        precondition(showingLoopCut && loopPreviewNode != nil && document == original,"Preview must not change authored geometry")
        precondition(loopCutMessage?.stringValue.contains("4 quads") == true)
        guard let position = control(NSSlider.self,properties) else { preconditionFailure("Missing loop-cut position slider") }
        position.doubleValue = 0.25; position.sendAction(position.action!,to:position.target)
        precondition(loopCutMessage?.stringValue.contains("25%") == true && document == original)
        focusSelection(); try checkRendering("loop-cut")
        guard let apply = control(GameButton.self,properties,where: { $0.title == "Apply loop cut" }) else { preconditionFailure("Missing Apply loop-cut action") }
        apply.invoke?()
        precondition(object!.mesh.faces.count == 10 && object!.mesh.vertices.count == 12 && faceSelection.count == 8)
        precondition(undoSteps.count == undoCount+1 && !showingLoopCut && loopPreviewNode == nil)
        undoEdit(); precondition(document == original,"A whole quad-strip cut must be one undo step")
        face = 5; selectedFaces = [5]; inspector(); adjustFaceSelection("grow")
        precondition(faceSelection.count == 5 && undoSteps.count == undoCount,"Selection changes must not pollute edit history")
        adjustFaceSelection("shrink"); precondition(faceSelection == [5])
        adjustFaceSelection("linked"); precondition(faceSelection.count == 6)
        face = 5; selectedFaces = [0,5]; inspector()
        guard let individual = control(GameButton.self,properties,where: { $0.title == "Extrude individual faces" }) else { preconditionFailure("Missing individual-face extrusion") }
        individual.invoke?(); precondition(object!.mesh.faces.count == 14)
        undoEdit(); precondition(document == original)
        let menu = contextMenu(at:NSPoint(x:-100,y:-100))
        precondition(!menu.autoenablesItems && menu.items.contains { $0.title == "Preview loop cut…" && !$0.isEnabled },"Context actions must visibly disable when no face is selected")
        setMode(3); precondition(propertiesTab == 0)
        precondition(control(GamePopup.self,properties,where: { $0.itemTitles.contains("Draw") }) != nil,"Entering Sculpt always exposes the brush controls")
        setMode(0)
        print("PASS: uncluttered inspector tabs, non-mutating loop preview, live position, Apply/undo, grow/shrink/linked, individual extrusion and contextual tools")
    }
    func checkAdvancedModeling() throws {
        change { $0.objects.removeAll() }; addPrimitive("Cube"); setMode(3); focusSelection(); setView(2)
        view.layoutSubtreeIfNeeded(); SCNTransaction.flush()
        RunLoop.current.run(until:Date().addingTimeInterval(0.2)); _ = viewport.snapshot()
        brush = .draw; brushRadius = 0.3; brushStrength = 0.6; subtract = false; frontOnly = true
        func pointer() -> NSPoint { let p = viewport.projectPoint(object!.world(.init()).scn); return .init(x:p.x,y:p.y) }
        func mouse(_ type:NSEvent.EventType,_ p:NSPoint) -> NSEvent { NSEvent.mouseEvent(with:type,location:viewport.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:view.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)! }
        let original = document, count = undoSteps.count, p = pointer()
        precondition(surfaceHit(p)?.node.name == selection?.uuidString,"Cube side must be hittable at \(p); camera \(String(describing:viewport.pointOfView?.position)); hits \(viewport.hitTest(p,options:nil).map { $0.node.name ?? "ground" })")
        viewport.mouseDown(with:mouse(.leftMouseDown,p)); viewport.mouseDragged(with:mouse(.leftMouseDragged,NSPoint(x:p.x+10,y:p.y))); viewport.mouseUp(with:mouse(.leftMouseUp,p))
        precondition(object!.mesh.faces.count >= 512 && object!.mesh.vertices.contains { $0.x > 0.501 },"Clicking the middle of a cube side must add working detail and deform its actual geometry: faces=\(object!.mesh.faces.count), maxX=\(object!.mesh.vertices.map(\.x).max()!), center=\(sculptCenter), normal=\(sculptNormal)")
        precondition(undoSteps.count == count+1,"Auto detail plus a whole stroke is one undo")
        undoEdit(); precondition(document == original && object!.mesh.vertices.count == 8)
        viewport.mouseDown(with:mouse(.leftMouseDown,p)); finishSculpt(cancel:true); viewport.mouseUp(with:mouse(.leftMouseUp,p))
        precondition(document == original,"Cancelling restores the sparse topology too")
        autoSculptDetail = false
        viewport.mouseDown(with:mouse(.leftMouseDown,p)); viewport.mouseUp(with:mouse(.leftMouseUp,p))
        precondition(document == original,"Auto detail is optional, not a mandatory project rewrite")
        autoSculptDetail = true; brush = .grab
        viewport.mouseDown(with:mouse(.leftMouseDown,p)); viewport.mouseDragged(with:mouse(.leftMouseDragged,NSPoint(x:p.x+30,y:p.y+10))); viewport.mouseUp(with:mouse(.leftMouseUp,p))
        precondition(object!.mesh.faces.count >= 512 && document != original,"Grab must evaluate against the prepared dense mesh, not the original eight corners")
        undoEdit(); precondition(document == original)
        brush = .draw; setView(4); focusSelection(); precondition(viewport.pointOfView!.worldFront.z > 0.99,"Focus must retain the Back view rather than jumping to a perspective angle")
        SCNTransaction.flush(); RunLoop.current.run(until:Date().addingTimeInterval(0.15)); _ = viewport.snapshot(); let backPointer = pointer()
        precondition(surfaceHit(backPointer)?.node.name == selection?.uuidString,"Back view must hit the cube: pointer=\(backPointer), camera=\(viewport.pointOfView!.position) forward=\(viewport.pointOfView!.worldFront) rawhits=\(viewport.hitTest(backPointer,options:nil).map { $0.node.name ?? "ground" })")
        viewport.mouseDown(with:mouse(.leftMouseDown,backPointer)); viewport.mouseUp(with:mouse(.leftMouseUp,backPointer))
        precondition(object!.mesh.vertices.contains { $0.z < -0.501 },"The back side must be sculptable too: center=\(sculptCenter) normal=\(sculptNormal) minZ=\(object!.mesh.vertices.map(\.z).min()!)")
        undoEdit(); precondition(document == original)
        edit { $0.mesh = try .sculptSphere(detail:4); $0.smoothShading = true }
        let sources = nodes[selection!]!.geometry!.sources(for:.vertex)
        precondition(sources.first!.vectorCount == object!.mesh.vertices.count,"Dense smooth meshes need indexed buffers, not triangle-expanded vertex copies")
        setMode(0)
        let beforePlan = document
        let plan = ModelingAIPlan(title:"Arrange shapes",explanation:"A local data-only plan.",actions:[.init(kind:.addPrimitive,primitive:"Cube",name:"Planned cube",position:.init(x:2,y:1,z:0),colour:"#D04020")])
        try applyAIPlan(plan); precondition(document.objects.count == beforePlan.objects.count+1); undoEdit(); precondition(document == beforePlan)
        let invalid = ModelingAIPlan(title:"Too much detail",explanation:"Must be rejected atomically.",actions:[.init(kind:.addPrimitive,primitive:"Plane"),.init(kind:.subdivideSelected,levels:2)])
        do { try applyAIPlan(invalid); preconditionFailure("Oversized helper plan should not apply") } catch { precondition(document == beforePlan,"Failed AI plans must not leave any added object") }
        change { $0.objects.removeAll() }; detail = .balanced; addDragon()
        precondition(document.objects.count == 48 && mode == 3)
        precondition(document.objects.contains { $0.name.lowercased().contains("wing") } && document.objects.contains { $0.name.lowercased().contains("tail") })
        try document.validate()
        let previewDocument = document, startingAI = ModelingAI.shared.status.phase
        try checkRendering("dragon")
        openAssist(); precondition(ModelingAI.shared.status.phase == startingAI,"Opening a helper window must not contact a remote service or download anything")
        assistWindow?.orderOut(nil)
        precondition(document == previewDocument)
        print("PASS: cube-side and back-side sculpt, automatic detail undo/cancel/opt-out/Grab, dense indexed rendering, editable dragon and atomic local-AI plan application")
    }
    func checkPhysicsIntegration() throws {
        change { $0.objects.removeAll() }; addPrimitive("Cube"); setMode(0)
        edit { $0.position.y = 3; $0.physics = ModelingPhysicsSettings(mode:.dynamic) }
        let before = document
        playPhysics(step:true); physics.step(frames:30)
        precondition(physicsConfigured && physics.time > 0.4 && document == before,"Physics playback must not edit the document")
        let node = nodes[selection!]!, beforeY = node.transform.m42
        precondition(beforeY < -0.4,"The world-baked model node must show actual falling motion")
        bakePhysics()
        precondition(!physicsConfigured && document != before && object!.mesh.vertices[0].y < before.objects[0].mesh.vertices[0].y-0.4)
        undoEdit(); precondition(document == before,"Bake is one undoable geometry change")
        playPhysics(step:true); physics.step(frames:10); render()
        precondition(!physicsConfigured && nodes[selection!]!.transform.m42 == 0,"Redrawing restores authored nodes and stops physics before replacing them")
        precondition(document == before)
        openPhysics(); physicsWindow?.orderOut(nil)
        focusSelection()
        print("PASS: native physics playback preserves authored meshes, world/local Bake, one-step undo and redraw lifecycle")
    }
    func checkRegions() throws {
        change { for i in $0.objects.indices { $0.objects[i].visible = false } }
        addPrimitive("Plane"); edit { try $0.mesh.subdivide() }; setMode(1); setView(3); focusSelection(); setView(3)
        view.layoutSubtreeIfNeeded(); SCNTransaction.flush(); RunLoop.current.run(until:Date().addingTimeInterval(0.15)); _ = viewport.snapshot()
        func pointer(_ f:Int) -> NSPoint { let p = viewport.projectPoint(object!.world(object!.mesh.center(of:f)).scn); return .init(x:p.x,y:p.y) }
        func mouse(_ type:NSEvent.EventType,_ p:NSPoint,_ flags:NSEvent.ModifierFlags = []) -> NSEvent { NSEvent.mouseEvent(with:type,location:viewport.convert(p,to:nil),modifierFlags:flags,timestamp:0,windowNumber:view.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)! }
        for f in [0,1] {
            let p = pointer(f), flags: NSEvent.ModifierFlags = f == 0 ? [] : [.shift]
            viewport.mouseDown(with:mouse(.leftMouseDown,p,flags)); viewport.mouseUp(with:mouse(.leftMouseUp,p,flags))
        }
        precondition(faceSelection == Set([0,1]),"Shift-click must retain neighbouring face selections")
        let p = pointer(1)
        viewport.mouseDown(with:mouse(.leftMouseDown,p,[.shift])); viewport.mouseUp(with:mouse(.leftMouseUp,p,[.shift]))
        precondition(faceSelection == Set([0]),"Shift-click again removes only that face")
        selectedFaces = [0,1]; face = 1; inspector()
        let before = document, undoCount = undoSteps.count
        func button(_ title:String,_ root:NSView) -> GameButton? {
            if let button = root as? GameButton, button.title == title { return button }
            return root.subviews.compactMap { button(title,$0) }.first
        }
        guard let extrude = button("Extrude region · E",properties) else { preconditionFailure("Missing region action") }
        extrude.invoke?()
        precondition(object!.mesh.faces.count == 10 && undoSteps.count == undoCount+1,"The visible region action creates only six boundary walls and one undo step")
        undoEdit(); precondition(document == before)
        selectedFaces = [0,1]; face = 1; inspector(); deleteSelection()
        precondition(object!.mesh.faces.count == 2 && faceSelection.isEmpty)
        undoEdit(); precondition(document == before)
        try document.validate()
        print("PASS: real Shift-click face regions, toggle selection, region extrusion button, multi-face deletion and one-step undo")
    }
    func checkSculpting() throws {
        change { for i in $0.objects.indices { $0.objects[i].visible = false } }
        addSculptSphere(); view.layoutSubtreeIfNeeded(); SCNTransaction.flush()
        RunLoop.current.run(until:Date().addingTimeInterval(0.15)); _ = viewport.snapshot()
        func sliders(_ v:NSView) -> [NSSlider] { (v as? NSSlider).map { [$0] } ?? v.subviews.flatMap(sliders) }
        let controls = sliders(properties); precondition(controls.count == 2)
        controls[0].doubleValue = 0.32; controls[0].sendAction(controls[0].action,to:controls[0].target)
        controls[1].doubleValue = 0.6; controls[1].sendAction(controls[1].action,to:controls[1].target)
        precondition(abs(brushRadius-0.32) < 1e-9 && abs(brushStrength-0.6) < 1e-9,"Both brush sliders must change the live settings")
        let center = viewport.projectPoint(object!.world(.init()).scn), p = NSPoint(x:center.x,y:center.y)
        precondition(surfaceHit(p)?.node.name == selection?.uuidString,"Sculpt sphere must be hittable")
        func mouse(_ type:NSEvent.EventType,_ p:NSPoint,_ flags:NSEvent.ModifierFlags = []) -> NSEvent { NSEvent.mouseEvent(with:type,location:viewport.convert(p,to:nil),modifierFlags:flags,timestamp:0,windowNumber:view.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)! }
        let initial = document, count = undoSteps.count
        viewport.mouseDown(with:mouse(.leftMouseDown,p))
        for step in 1...5 { viewport.mouseDragged(with:mouse(.leftMouseDragged,NSPoint(x:p.x+CGFloat(step)*4,y:p.y))) }
        viewport.mouseUp(with:mouse(.leftMouseUp,NSPoint(x:p.x+20,y:p.y)))
        precondition(document != initial && undoSteps.count == count+1,"Entire sculpt stroke must be one undo")
        let sculpted = document; undoEdit(); precondition(document == initial); redoEdit(); precondition(document == sculpted); undoEdit()
        viewport.mouseDown(with:mouse(.leftMouseDown,p)); viewport.mouseDragged(with:mouse(.leftMouseDragged,NSPoint(x:p.x+12,y:p.y))); finishSculpt(cancel:true)
        viewport.mouseUp(with:mouse(.leftMouseUp,p)); precondition(document == initial,"Cancel must restore the whole stroke")
        brush = .mask
        viewport.mouseDown(with:mouse(.leftMouseDown,p)); viewport.mouseDragged(with:mouse(.leftMouseDragged,NSPoint(x:p.x+40,y:p.y))); viewport.mouseUp(with:mouse(.leftMouseUp,p))
        precondition(object!.mesh.sculptMask != nil && object!.mesh.vertices == initial.objects[index!].mesh.vertices,"Mouse-driven masks protect geometry without moving it")
        let painted = document; undoEdit(); precondition(document == initial); redoEdit(); precondition(document == painted); undoEdit()
        edit { $0.mesh.sculptMask = Array(repeating:1,count:$0.mesh.vertices.count) }
        let masked = document; brush = .draw
        viewport.mouseDown(with:mouse(.leftMouseDown,p)); viewport.mouseDragged(with:mouse(.leftMouseDragged,NSPoint(x:p.x+16,y:p.y))); viewport.mouseUp(with:mouse(.leftMouseUp,p))
        precondition(document == masked,"A fully masked model does not move while sculpting")
        edit { $0.mesh.clearSculptMask() }; precondition(document == initial)
        brush = .grab
        viewport.mouseDown(with:mouse(.leftMouseDown,p)); viewport.mouseDragged(with:mouse(.leftMouseDragged,NSPoint(x:p.x+35,y:p.y+20))); viewport.mouseUp(with:mouse(.leftMouseUp,p))
        precondition(document != initial,"Grab must deform the mesh through real mouse events")
        undoEdit(); precondition(document == initial)
        let normals = object!.mesh.vertices
        setMode(2); vertex = 0; proportional = true; axisLock = 2; brushRadius = 0.3
        let world = object!.world(normals[0]); dragVertex(world+ModelPoint(x:0.2,y:0.1,z:0.3),finished:true)
        let changed = zip(normals,object!.mesh.vertices).filter { ($0-$1).length > 1e-9 }
        precondition(changed.count > 1 && changed.allSatisfy { abs($0.x-$1.x) < 1e-9 && abs($0.z-$1.z) < 1e-9 },"Proportional move must respect the local axis lock")
        undoEdit(); precondition(document == initial)
        proportional = false; axisLock = 0; setMode(3); brush = .draw
        for preset in 0...3 { setView(preset); precondition(viewport.pointOfView?.camera?.usesOrthographicProjection == (preset != 0)) }
        setView(0)
        precondition(viewport.pointOfView!.worldUp.y > 0.7,"Perspective must reset the roll after Top view")
        // Keep a real sculpt visible in the rendering checks.
        sculptAt(p,flags:[],phase:.begin); sculptAt(NSPoint(x:p.x+8,y:p.y),flags:[],phase:.update); sculptAt(p,flags:[],phase:.end)
        try document.validate()
        print("PASS: native brush sliders, mouse-driven sculpt/Grab/Mask, full mask protection, stroke undo/redo/cancel, proportional editing, axis locks and view presets")
    }
    func checkEditing() throws {
        _ = view
        precondition(document.objects.isEmpty)
        var home = 0; onShowStudioHome = { home += 1 }; onShowStudioHome?(); precondition(home == 1)
        addPrimitive("Cube"); precondition(document.objects.count == 1)
        let cube = document
        setMode(1); face = 5; edit { try $0.mesh.extrude(face:5,distance:0.5) }
        precondition(object?.mesh.faces.count == 10)
        undoEdit(); precondition(document == cube); redoEdit(); precondition(object?.mesh.faces.count == 10)
        face = 5; edit { try $0.mesh.extrude(face:5,distance:0,inset:0.2) }
        precondition(object?.mesh.faces.count == 14)
        let beforeDelete = document; deleteSelection(); precondition(object?.mesh.faces.count == 13); undoEdit(); precondition(document == beforeDelete)
        setMode(2); vertex = 0
        let beforeDrag = document, count = undoSteps.count
        let p = object!.world(object!.mesh.vertices[0])
        dragVertex(p + ModelPoint(x:0.2),finished:false); dragVertex(p + ModelPoint(x:0.4),finished:true)
        precondition(undoSteps.count == count+1)
        undoEdit(); precondition(document == beforeDrag)
        setMode(0); duplicate(); precondition(document.objects.count == 2); deleteSelection(); precondition(document.objects.count == 1); undoEdit(); precondition(document.objects.count == 2)
        redoEdit(); precondition(document.objects.count == 1)
        edit { $0.position = ModelPoint(x:1); $0.rotation = ModelPoint(y:30); $0.scale = ModelPoint(x:1.5,y:1,z:1) }
        setMode(2); focusSelection(); view.layoutSubtreeIfNeeded(); _ = viewport.snapshot()
        SCNTransaction.flush(); RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        // Pick and drag an actually visible marker through the real mouse path.
        var candidate: (Int,NSPoint)?
        for (i,p) in object!.mesh.vertices.enumerated() {
            let projected = viewport.projectPoint(object!.world(p).scn), point = NSPoint(x:projected.x,y:projected.y)
            if viewport.hitTest(point,options:nil).first?.node.name == "vertex:\(i)" { candidate = (i,point); break }
        }
        guard let (v,pointer) = candidate else { preconditionFailure("No visible vertex markers") }
        let initial = document
        func mouse(_ type:NSEvent.EventType,_ p:NSPoint) -> NSEvent { NSEvent.mouseEvent(with:type,location:viewport.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:view.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)! }
        viewport.mouseDown(with:mouse(.leftMouseDown,pointer))
        let destination = NSPoint(x:pointer.x+30,y:pointer.y+12)
        viewport.mouseDragged(with:mouse(.leftMouseDragged,destination)); viewport.mouseUp(with:mouse(.leftMouseUp,destination))
        precondition(vertex == v && document != initial,"Dragging a marker must edit its vertex")
        let moved = viewport.projectPoint(object!.world(object!.mesh.vertices[v]).scn)
        precondition(abs(moved.x-destination.x) < 1 && abs(moved.y-destination.y) < 1,"The vertex must follow the cursor")
        undoEdit(); precondition(document == initial)
        setMode(1)
        var clickedFace = false
        for f in object!.mesh.faces.indices {
            let projected = viewport.projectPoint(object!.world(object!.mesh.center(of:f)).scn)
            let pointer = NSPoint(x:projected.x,y:projected.y)
            guard viewport.hitTest(pointer,options:nil).first?.node.name == selection?.uuidString else { continue }
            viewport.mouseDown(with:mouse(.leftMouseDown,pointer)); viewport.mouseUp(with:mouse(.leftMouseUp,pointer))
            if face != nil { clickedFace = true; break }
        }
        precondition(clickedFace,"A visible face must be selectable with the mouse")
        try document.validate()
        print("PASS: native modelling add/duplicate/delete, extrude/inset, face deletion, undo/redo, and mouse-driven vertex editing")
    }
    func checkRendering(_ label:String) throws {
        view.layoutSubtreeIfNeeded()
        precondition(viewport.frame.width > 350 && viewport.frame.height > 400)
        precondition(properties.frame.maxX <= view.bounds.width && status.frame.minY >= 0)
        let image = viewport.snapshot()
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff) { try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/private/tmp/netvista-model-viewport-\(label).png")) }
        if let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) { view.cacheDisplay(in:view.bounds,to:bitmap); try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/private/tmp/netvista-model-editor-\(label).png")) }
    }
    #endif
}
