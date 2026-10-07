import Cocoa
import SpriteKit
import SceneKit

private func gameObjectColour(_ object: GameObject) -> NSColor {
    let hex = object.colour ?? (object.imageID != nil ? "#ffffff" : object.kind == .coin ? "#f5c45c" : "#589fd8")
    let value = UInt32(hex.dropFirst(),radix:16) ?? 0x589fd8
    return NSColor(srgbRed:CGFloat((value >> 16) & 255)/255,green:CGFloat((value >> 8) & 255)/255,blue:CGFloat(value & 255)/255,alpha:1)
}

private final class GameSpriteView: SKView {
    var selected: ((UUID?) -> Void)?
    var moved: ((UUID,CGPoint,Bool) -> Void)?
    var editing = true
    private var dragged: UUID?
    private var offset = CGPoint.zero
    private var didDrag = false
    override func mouseDown(with event: NSEvent) {
        guard editing, let scene else { return }; let point = scene.convertPoint(fromView:convert(event.locationInWindow,from:nil))
        let node = scene.nodes(at:point).first { $0.name.flatMap(UUID.init(uuidString:)) != nil }
        window?.makeFirstResponder(self); didDrag = false
        dragged = node?.name.flatMap(UUID.init(uuidString:)); selected?(dragged)
        if let node { offset = CGPoint(x:point.x-node.position.x,y:point.y-node.position.y) }
    }
    override func mouseDragged(with event: NSEvent) { didDrag = true; move(event,finished:false) }
    override func mouseUp(with event: NSEvent) { if didDrag { move(event,finished:true) }; dragged = nil }
    private func move(_ event: NSEvent, finished: Bool) {
        guard editing, let id = dragged, let scene else { return }; let p = scene.convertPoint(fromView:convert(event.locationInWindow,from:nil))
        moved?(id,CGPoint(x:(p.x-offset.x)/40,y:(p.y-offset.y)/40),finished)
    }
    override func scrollWheel(with event: NSEvent) {
        guard editing, let camera = scene?.camera else { return }
        if event.modifierFlags.contains(.option) { camera.setScale(max(0.1,min(20,camera.xScale*exp(event.scrollingDeltaY*0.015)))) }
        else { camera.position.x -= event.scrollingDeltaX*camera.xScale; camera.position.y += event.scrollingDeltaY*camera.yScale }
    }
}
private final class GameSceneView: SCNView {
    var selected: ((UUID?) -> Void)?
    var moved: ((UUID, SCNVector3, Bool) -> Void)?
    var selectedID: UUID?
    var selectedPosition = SCNVector3Zero
    var editing = true
    private var gesture: (id: UUID, axis: Int, origin: SCNVector3, pointer: NSPoint, vector: NSPoint)?
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        window?.makeFirstResponder(self)
        if editing, !event.modifierFlags.contains(.option), let hit = hitTest(point,options:nil).first {
            if let name = hit.node.name, name.hasPrefix("gizmo-"), let axis = Int(name.dropFirst(6)), let selectedID {
                let p = selectedPosition
                var end = p
                if axis == 0 { end.x += 1 }; if axis == 1 { end.y += 1 }; if axis == 2 { end.z += 1 }
                let a = projectPoint(p), b = projectPoint(end)
                gesture = (selectedID,axis,p,point,NSPoint(x:CGFloat(b.x-a.x),y:CGFloat(b.y-a.y)))
                return
            }
            var node = hit.node
            while node.name.flatMap(UUID.init(uuidString:)) == nil, let parent = node.parent { node = parent }
            if let id = node.name.flatMap(UUID.init(uuidString:)) { selected?(id) }
        }
        super.mouseDown(with:event)
    }
    override func mouseDragged(with event: NSEvent) {
        if gesture != nil { moveHandle(event, finished:false) } else { super.mouseDragged(with:event) }
    }
    override func mouseUp(with event: NSEvent) {
        if gesture != nil { moveHandle(event, finished:true); gesture = nil } else { super.mouseUp(with:event) }
    }
    private func moveHandle(_ event: NSEvent, finished: Bool) {
        guard let g = gesture, editing else { return }
        let p = convert(event.locationInWindow,from:nil)
        let delta = GameEditorMath.axisDistance(dx:Double(p.x-g.pointer.x),dy:Double(p.y-g.pointer.y),axisX:Double(g.vector.x),axisY:Double(g.vector.y))
        var result = g.origin
        if g.axis == 0 { result.x += delta }; if g.axis == 1 { result.y += delta }; if g.axis == 2 { result.z += delta }
        moved?(g.id,result,finished)
    }
}

final class GameEditorViewController: NSViewController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onShowStudioHome: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var project: GameProject
    private(set) var projectURL: URL?
    private(set) var dirty: Bool
    private var saved: GameProject?
    private var selected: UUID?
    private var play: GamePlayState?
    private var keys = Set<String>()
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var eventMonitor: Any?
    private var undoSteps: [GameProject] = [], redoSteps: [GameProject] = []
    private var dragStart: GameProject?
    private var paused = false
    private var grid: Double = 0.5
    private var snapEnabled = true
    private var lastDebugRefresh: Double = -1
    private var editorCamera2D: (CGPoint, CGFloat)?
    private var editorCamera3D: SCNMatrix4?
    private var gizmo: SCNNode?
    private var logicWasHidden = false
    private let spriteView = GameSpriteView()
    private let sceneView = GameSceneView()
    private var sprites: [UUID: SKNode] = [:], nodes: [UUID: SCNNode] = [:]
    private var textures: [UUID: NSImage] = [:], meshes: [UUID: GameMesh] = [:]
    private var rigs: [UUID: GameRigRenderer] = [:]
    private var jointIndex = 0
    private var previewTimer: Timer?
    private var previewTime: Double = 0
    private let table = NSTableView(), assetTable = NSTableView()
    private let objectSearch = NSSearchField(), assetSearch = NSSearchField()
    private let sceneCount = NSTextField(labelWithString: "WORLD OUTLINER")
    private let properties = GameScroll()
    private let logic = GameLogicPanel(frame:.zero)
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "Your scene is empty.\nImport a sprite or 3D model, then add it from Assets.\nOr use + Object to build with shapes.")
    private let titleField = NSTextField()
    private var playButton: GameButton!
    private var pauseButton: GameButton!, stepButton: GameButton!, restartButton: GameButton!
    private var snapButton: GameButton!, logicButton: GameButton!
    private var debugText = NSTextField(wrappingLabelWithString: "")
    private var undoButton: GameButton!, redoButton: GameButton!
    private var editingButtons: [NSControl] = []
    private var selectedObject: GameObject? { project.objects.first { $0.id == selected } }
    private var filteredObjects: [GameObject] { project.objects.filter { objectSearch.stringValue.isEmpty || $0.name.localizedCaseInsensitiveContains(objectSearch.stringValue) } }
    private var placeableAssets: [GameAsset] { project.assets.filter { (textures[$0.id] != nil || meshes[$0.id] != nil) && (assetSearch.stringValue.isEmpty || $0.path.localizedCaseInsensitiveContains(assetSearch.stringValue)) } }

    init(project: GameProject, url: URL? = nil) {
        self.project = project; projectURL = url; dirty = url == nil; saved = url == nil ? nil : project
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { previewTimer?.invalidate(); timer?.invalidate(); if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
    override func loadView() {
        view = NSView(); view.appearance = NSAppearance(named:.darkAqua); view.wantsLayer = true; view.layer?.backgroundColor = NSColor(calibratedWhite:0.1,alpha:1).cgColor
        let home = GameButton("Studio Home") { [weak self] in self?.onShowStudioHome?() }
        let open = GameButton("Open…") { [weak self] in self?.openGame() }
        let save = GameButton("Save") { [weak self] in _ = self?.save(as:false) }
        let saveAs = GameButton("Save As…") { [weak self] in _ = self?.save(as:true) }
        let export = GameButton("Export game…") { [weak self] in self?.exportGame() }
        playButton = GameButton("▶ Play") { [weak self] in self?.togglePlay() }
        pauseButton = GameButton("Pause") { [weak self] in self?.togglePause() }
        stepButton = GameButton("Step") { [weak self] in self?.stepFrame() }
        restartButton = GameButton("Restart") { [weak self] in self?.restartPlay() }
        stepButton.toolTip = "Advance the paused game by exactly one 60 Hz frame"
        pauseButton.isEnabled = false; stepButton.isEnabled = false; restartButton.isEnabled = false
        undoButton = GameButton("Undo") { [weak self] in self?.undoEdit() }; redoButton = GameButton("Redo") { [weak self] in self?.redoEdit() }
        titleField.stringValue = project.name; titleField.target = self; titleField.action = #selector(renameGame)
        titleField.widthAnchor.constraint(greaterThanOrEqualToConstant:130).isActive = true
        let toolbar = gameRow([home,gameLabel("GAME MAKER · \(project.dimension.rawValue)",strong:true),titleField,open,save,saveAs,export]); toolbar.spacing = 10
        snapButton = GameButton("Snap ✓") { [weak self] in guard let self else { return }; self.snapEnabled.toggle(); self.snapButton.title = self.snapEnabled ? "Snap ✓" : "Snap off" }
        let gridPicker = GamePopup(["0.1 units","0.5 units","1 unit","2 units"],selected:1) { [weak self] i in self?.grid = [0.1,0.5,1,2][i] }
        logicButton = GameButton("Hide logic") { [weak self] in self?.toggleLogic() }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let commands = gameRow([undoButton,redoButton,snapButton,gridPicker,logicButton,spacer,playButton,pauseButton,stepButton,restartButton])
        commands.spacing = 8
        let sidebar = NSStackView(); sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 8
        let objectsScroll = configure(table); objectsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:100).isActive = true
        let assetsScroll = configure(assetTable); assetsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:70).isActive = true
        let add = GameButton("+ Object") { [weak self] in self?.addObjectMenu() }
        let duplicate = GameButton("Duplicate") { [weak self] in self?.duplicateObject() }
        let layerUp = GameButton("↑") { [weak self] in self?.moveLayer(-1) }; layerUp.toolTip = "Move object earlier in the scene / draw order"
        let layerDown = GameButton("↓") { [weak self] in self?.moveLayer(1) }; layerDown.toolTip = "Move object later in the scene / draw order"
        let delete = GameButton("Delete") { [weak self] in self?.deleteObject() }
        let importButton = GameButton("Import sprites / models…") { [weak self] in self?.importAssets() }
        let place = GameButton("Add asset to scene") { [weak self] in self?.placeAsset() }
        objectSearch.placeholderString = "Search objects"; objectSearch.target = self; objectSearch.action = #selector(filterObjects)
        assetSearch.placeholderString = "Search assets"; assetSearch.target = self; assetSearch.action = #selector(filterAssets)
        for field in [objectSearch,assetSearch] { field.sendsSearchStringImmediately = true; field.widthAnchor.constraint(equalToConstant:206).isActive = true }
        sceneCount.font = .systemFont(ofSize:11,weight:.semibold); sceneCount.textColor = .secondaryLabelColor
        for child in [sceneCount,objectSearch,objectsScroll,gameRow([add,delete]),gameRow([duplicate,layerUp,layerDown]),gameLabel("CONTENT BROWSER",strong:true),assetSearch,assetsScroll,importButton,place] { sidebar.addArrangedSubview(child) }
        for scroll in [objectsScroll,assetsScroll] { scroll.widthAnchor.constraint(equalToConstant:206).isActive = true }
        let assetHint = NSTextField(wrappingLabelWithString:"PNG / JPG sprites · OBJ / DAE / STL / PLY / USD models\nAssets travel inside your game save."); assetHint.font = .systemFont(ofSize:11); assetHint.textColor = .secondaryLabelColor; assetHint.widthAnchor.constraint(equalToConstant:206).isActive = true; sidebar.addArrangedSubview(assetHint)
        let viewport = NSView()
        let render: NSView = project.dimension == .twoD ? spriteView : sceneView
        let fit = GameButton("Frame scene") { [weak self] in self?.frameScene() }
        let reset = GameButton("Game camera") { [weak self] in self?.resetCamera() }
        let focus = GameButton("Focus · F") { [weak self] in self?.focusSelected() }
        let tools = gameRow([gameLabel(project.dimension == .twoD ? "2D SCENE" : "PERSPECTIVE",strong:true),fit,focus,reset])
        toolbar.heightAnchor.constraint(equalToConstant:32).isActive = true
        commands.heightAnchor.constraint(equalToConstant:32).isActive = true
        tools.heightAnchor.constraint(equalToConstant:30).isActive = true
        status.heightAnchor.constraint(equalToConstant:18).isActive = true
        for child in [render,tools,empty] { viewport.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        empty.alignment = .center; empty.textColor = .secondaryLabelColor; empty.font = .systemFont(ofSize:14)
        NSLayoutConstraint.activate([tools.topAnchor.constraint(equalTo:viewport.topAnchor,constant:8),tools.leadingAnchor.constraint(equalTo:viewport.leadingAnchor,constant:10),render.topAnchor.constraint(equalTo:tools.bottomAnchor,constant:8),render.leadingAnchor.constraint(equalTo:viewport.leadingAnchor),render.trailingAnchor.constraint(equalTo:viewport.trailingAnchor),render.bottomAnchor.constraint(equalTo:viewport.bottomAnchor),empty.centerXAnchor.constraint(equalTo:render.centerXAnchor),empty.centerYAnchor.constraint(equalTo:render.centerYAnchor),empty.widthAnchor.constraint(lessThanOrEqualTo:render.widthAnchor,constant:-40)])
        let center = NSSplitView(); center.isVertical = false; center.dividerStyle = .thin
        for panel in [viewport,properties,logic] as [NSView] {
            panel.wantsLayer = true; panel.layer?.backgroundColor = NSColor(calibratedWhite:0.075,alpha:1).cgColor
            panel.layer?.borderWidth = 1; panel.layer?.borderColor = NSColor(calibratedWhite:0.19,alpha:1).cgColor
        }
        center.addArrangedSubview(viewport); center.addArrangedSubview(logic)
        viewport.heightAnchor.constraint(greaterThanOrEqualToConstant:240).isActive = true
        logic.heightAnchor.constraint(greaterThanOrEqualToConstant:190).isActive = true
        let balanced = viewport.heightAnchor.constraint(equalTo:logic.heightAnchor,multiplier:1.5); balanced.priority = .defaultLow; balanced.isActive = true
        for child in [toolbar,commands,sidebar,center,properties,status] { view.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12),toolbar.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),toolbar.topAnchor.constraint(equalTo:view.topAnchor,constant:10),
            commands.leadingAnchor.constraint(equalTo:toolbar.leadingAnchor),commands.trailingAnchor.constraint(equalTo:toolbar.trailingAnchor),commands.topAnchor.constraint(equalTo:toolbar.bottomAnchor,constant:8),
            sidebar.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12),sidebar.widthAnchor.constraint(equalToConstant:206),sidebar.topAnchor.constraint(equalTo:commands.bottomAnchor,constant:14),sidebar.bottomAnchor.constraint(equalTo:status.topAnchor,constant:-12),
            center.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:12),center.topAnchor.constraint(equalTo:commands.bottomAnchor,constant:10),center.bottomAnchor.constraint(equalTo:status.topAnchor,constant:-10),center.trailingAnchor.constraint(equalTo:properties.leadingAnchor,constant:-8),
            properties.widthAnchor.constraint(equalToConstant:240),properties.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-4),properties.topAnchor.constraint(equalTo:center.topAnchor),properties.bottomAnchor.constraint(equalTo:center.bottomAnchor),
            status.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:14),status.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-14),status.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-10)
        ])
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        editingButtons = [add,duplicate,layerUp,layerDown,delete,importButton,place,export,fit,focus,reset,snapButton,gridPicker,logicButton,objectSearch,assetSearch]
        spriteView.selected = { [weak self] id in self?.select(id) }; spriteView.moved = { [weak self] id,point,finished in self?.drag(id,point:point,finished:finished) }; sceneView.selected = { [weak self] id in self?.select(id) }
        sceneView.moved = { [weak self] id,point,finished in self?.drag3D(id,point:point,finished:finished) }
        logic.changed = { [weak self] rules in
            guard let self, let index = self.project.objects.firstIndex(where: { $0.id == self.selected }), self.play == nil else { return }
            self.remember(); self.project.objects[index].rules = rules; self.changed()
        }
        refreshAssets(); refresh(); rebuildScene(); status.stringValue = "Add an object or import assets. Select → Behaviour recipes to build a playable graph."
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp]) { [weak self] event in
            guard let self, event.window === self.view.window else { return event }
            if event.type == .keyDown, event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "s" { _ = self.save(as:event.modifierFlags.contains(.shift)); return nil }
                if event.charactersIgnoringModifiers == "z", !(self.view.window?.firstResponder is NSTextView) { if event.modifierFlags.contains(.shift) { self.redoEdit() } else { self.undoEdit() }; return nil }
                if event.charactersIgnoringModifiers == "d", self.play == nil, !(self.view.window?.firstResponder is NSTextView) { self.duplicateObject(); return nil }
            }
            if self.play == nil, !(self.view.window?.firstResponder is NSTextView), !event.modifierFlags.contains(.command), event.type == .keyDown {
                if event.charactersIgnoringModifiers == "f" { self.focusSelected(); return nil }
                let responder = self.view.window?.firstResponder
                if [51,117].contains(event.keyCode), responder === self.table || responder === self.spriteView || responder === self.sceneView { self.deleteObject(); return nil }
            }
            guard self.play != nil else { return event }; if event.keyCode == 53 { self.togglePlay(); return nil }
            guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return event }
            let codes: [UInt16:String] = [0:"a",1:"s",2:"d",13:"w",49:"space",14:"e",123:"left",124:"right",125:"down",126:"up"]
            guard let key = codes[event.keyCode] else { return event }
            if event.type == .keyDown { self.keys.insert(key) } else { self.keys.remove(key) }; return nil
        }
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.delegate = self; updateTitle() }
    private func configure(_ table: NSTableView) -> NSScrollView {
        let column = NSTableColumn(identifier:.init("name")); column.width = 200; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 28; table.dataSource = self; table.delegate = self
        table.backgroundColor = NSColor(calibratedWhite:0.075,alpha:1)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; return scroll
    }
    @objc private func filterObjects() { let keep = selected; table.reloadData(); select(keep) }
    @objc private func filterAssets() { assetTable.reloadData() }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === table ? filteredObjects.count : placeableAssets.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === table { let o = filteredObjects[row]; text = "\(o.visible ? "◈" : "○")  \(o.name)\(o.rules.isEmpty ? "" : "  ⚡")" }
        else { let a = placeableAssets[row]; text = "\(meshes[a.id] != nil ? "◇" : "▧")  \(URL(fileURLWithPath:a.path.hasSuffix(".nvmesh") ? String(a.path.dropLast(7)) : a.path).lastPathComponent)" }
        let label = NSTextField(labelWithString:text); label.lineBreakMode = .byTruncatingMiddle; label.font = .systemFont(ofSize:12); return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === table else { return }
        selected = filteredObjects.indices.contains(table.selectedRow) ? filteredObjects[table.selectedRow].id : nil
        refreshInspector(); refreshLogic(); highlight()
    }
    private func select(_ id: UUID?) {
        selected = id
        if let i = filteredObjects.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false) } else { table.deselectAll(nil) }
        // Selection can remain in the viewport while hidden by an outliner filter.
        selected = project.objects.contains(where: { $0.id == id }) ? id : nil
        refreshInspector(); refreshLogic(); highlight()
    }
    private func refresh() {
        let keep = selected; table.reloadData(); assetTable.reloadData(); select(keep)
        sceneCount.stringValue = "WORLD OUTLINER  ·  \(project.objects.count)"
        empty.isHidden = !project.objects.isEmpty || play != nil; updateTitle()
    }
    private func refreshLogic() { logic.show(object:selectedObject,objects:project.objects,dimension:project.dimension) }
    private func refreshInspector() {
        properties.clear(); properties.add(gameLabel("PROPERTIES",strong:true))
        if play != nil { showDebugger(); return }
        guard let object = selectedObject else { properties.add(gameLabel("No object selected")); properties.add(gameLabel("Add sprites, models or empty objects.")); return }
        properties.add(gameLabel(object.name,strong:true))
        let name = NSTextField(string:object.name); name.target = self; name.action = #selector(renameObject); name.widthAnchor.constraint(equalToConstant:208).isActive = true; properties.add(name)
        properties.add(GameButton("+ Behaviour recipe…") { [weak self] in self?.behaviourMenu() })
        properties.add(GameButton("Visual logic · \(object.rules.count) events") { [weak self] in self?.showLogic() })
        properties.add(gameLabel("TRANSFORM",strong:true))
        for (caption,key,range) in [("X",\GameObject.x,-10000.0...10000),("Y",\GameObject.y,-10000.0...10000),("Z",\GameObject.z,-10000.0...10000),("Size",\GameObject.size,0.01...1000),("Rotation °",\GameObject.rotation,-360000.0...360000),("Opacity",\GameObject.opacity,0.0...1)] where caption != "Z" || project.dimension == .threeD {
            let label = gameLabel(caption); label.widthAnchor.constraint(equalToConstant:94).isActive = true
            properties.add(gameRow([label,GameNumber(object[keyPath:key],width:100,range:range) { [weak self] value in self?.editObject { $0[keyPath:key] = value } }]))
        }
        properties.add(gameLabel("DIMENSIONS · multiplied by Size",strong:true))
        for (caption,key) in [("Width",\GameObject.scaleX),("Height",\GameObject.scaleY),("Depth",\GameObject.scaleZ)] where caption != "Depth" || project.dimension == .threeD {
            let label = gameLabel(caption); label.widthAnchor.constraint(equalToConstant:94).isActive = true
            properties.add(gameRow([label,GameNumber(object[keyPath:key],width:100,range:0.01...1000) { [weak self] value in self?.editObject { $0[keyPath:key] = value } }]))
        }
        let visible = GameButton(object.visible ? "◉ Visible" : "○ Hidden") { [weak self] in self?.editObject { $0.visible.toggle() }; self?.refreshInspector() }
        let solid = GameButton(object.solid ? "✓ Solid collider" : "+ Solid collider") { [weak self] in self?.editObject { $0.solid.toggle() }; self?.refreshInspector() }
        properties.add(gameRow([visible,solid])); properties.add(gameLabel("TEXTURE",strong:true))
        let images = project.assets.filter { textures[$0.id] != nil }
        let picker = GamePopup(["Default colour"] + images.map { URL(fileURLWithPath:$0.path).lastPathComponent },selected:images.firstIndex(where: { $0.id == object.imageID }).map { $0+1 } ?? 0) { [weak self] i in self?.editObject { $0.imageID = i == 0 ? nil : images[i-1].id }; self?.rebuildScene() }
        picker.widthAnchor.constraint(equalToConstant:208).isActive = true; properties.add(picker)
        properties.add(gameRow([gameLabel("Colour"),GameColourWell(gameObjectColour(object)) { [weak self] colour in guard let self, self.selected == object.id else { return }; self.editObject { $0.colour = colour }; self.rebuildScene() },GameButton("Reset") { [weak self] in self?.editObject { $0.colour = nil }; self?.rebuildScene(); self?.refreshInspector() }]))
        properties.add(GameButton("Reset transform") { [weak self] in self?.editObject { $0.x = 0; $0.y = 0; $0.z = 0; $0.rotation = 0; $0.size = 1; $0.scaleX = 1; $0.scaleY = 1; $0.scaleZ = 1 }; self?.refreshInspector() })
        characterProperties(object)
        for text in [project.dimension == .twoD ? "Drag to move · Scroll to pan · Option-scroll to zoom. F focuses selection. One unit = 40 pixels." : "Drag coloured handles to move on X / Y / Z. Drag background to orbit; scroll to zoom. F focuses selection. Y is height.","Snap uses the toolbar grid size. Solid objects block Move and WASD actions with box colliders. No automatic gravity."] {
            let guide = NSTextField(wrappingLabelWithString:text); guide.font = .systemFont(ofSize:11); guide.textColor = .secondaryLabelColor; guide.widthAnchor.constraint(equalToConstant:208).isActive = true; properties.add(guide)
        }
    }
    private func toggleLogic() { logic.isHidden.toggle(); logicButton.title = logic.isHidden ? "Show logic" : "Hide logic" }
    private func showLogic() { logic.isHidden = false; logicButton.title = "Hide logic"; refreshLogic(); logic.frameGraph() }
    private func behaviourMenu() {
        guard selectedObject != nil, play == nil else { return }
        let menu = NSMenu()
        for (index,recipe) in GameBehaviourRecipe.allCases.enumerated() {
            let item = NSMenuItem(title:recipe.rawValue,action:#selector(addBehaviour(_:)),keyEquivalent:""); item.target = self; item.tag = index; menu.addItem(item)
        }
        menu.popUp(positioning:nil,at:NSPoint(x:12,y:properties.bounds.height-80),in:properties)
    }
    @objc private func addBehaviour(_ item: NSMenuItem) {
        guard let object = selectedObject, play == nil else { return }
        let recipe = GameBehaviourRecipe.allCases[item.tag]
        var contact: UUID?
        if recipe == .pickup {
            let others = project.objects.filter { $0.id != object.id }
            guard !others.isEmpty else { status.stringValue = "Add another object first, then choose which player can collect this object."; return }
            let alert = NSAlert(); alert.messageText = "Who can collect \(object.name)?"; alert.informativeText = "Touching the selected object awards one point and removes this pickup."
            let picker = NSPopUpButton(frame:NSRect(x:0,y:0,width:280,height:28)); picker.addItems(withTitles:others.map(\.name)); alert.accessoryView = picker
            alert.addButton(withTitle:"Add behaviour"); alert.addButton(withTitle:"Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }; contact = others[picker.indexOfSelectedItem].id
        }
        addRecipe(recipe, contact:contact)
    }
    private func addRecipe(_ recipe: GameBehaviourRecipe, contact: UUID? = nil) {
        guard let object = selectedObject else { return }
        let rules = recipe.rules(for:object,contact:contact)
        guard !rules.isEmpty, object.rules.count + rules.count <= 64 else { status.stringValue = "Cannot add this recipe: check its target and the 64-event limit."; return }
        editObject { $0.rules += rules }; refresh(); showLogic(); logic.selectLastEvent()
        status.stringValue = "Added \(recipe.rawValue). Edit the connected nodes below, then press Play."
    }
    private func characterProperties(_ object: GameObject) {
        if object.kind == .sprite {
            properties.add(gameLabel("SPRITE SHEET",strong:true))
            if let sheet = object.spriteSheet {
                for (caption,key) in [("Columns",\GameSpriteSheet.columns),("Rows",\GameSpriteSheet.rows),("Frames",\GameSpriteSheet.frames)] {
                    properties.add(gameRow([gameLabel(caption),GameNumber(Double(sheet[keyPath:key]),range:1...Double(caption == "Frames" ? sheet.columns*sheet.rows : 64)) { [weak self] value in
                        self?.editObject { o in o.spriteSheet?[keyPath:key] = Int(value); if var s = o.spriteSheet { s.frames = min(s.frames,s.rows*s.columns); o.spriteSheet = s } }; self?.refreshInspector()
                    }]))
                }
                properties.add(gameRow([gameLabel("Frames / sec"),GameNumber(sheet.fps,range:0.1...60) { [weak self] value in self?.editObject { $0.spriteSheet?.fps = value } }]))
                properties.add(GameButton("Remove sprite animation") { [weak self] in self?.editObject { $0.spriteSheet = nil }; self?.refreshInspector(); self?.rebuildScene() })
            } else { properties.add(GameButton("Set up sprite sheet") { [weak self] in self?.editObject { $0.spriteSheet = GameSpriteSheet() }; self?.refreshInspector() }) }
            properties.add(GameButton("Add movement + animation") { [weak self] in self?.addCharacterLogic(sprite:true) })
        }
        if object.kind == .model {
            properties.add(gameLabel("CHARACTER RIG",strong:true))
            if let rig = object.rig {
                jointIndex = min(jointIndex,rig.joints.count-1)
                let picker = GamePopup(rig.joints.map(\.name),selected:jointIndex) { [weak self] index in self?.jointIndex = index; self?.refreshInspector(); self?.rigs[object.id]?.guides(selected:index) }
                picker.widthAnchor.constraint(equalToConstant:208).isActive = true; properties.add(picker)
                let joint = rig.joints[jointIndex]
                for (caption,key) in [("Joint X",\GameRigJoint.x),("Joint Y",\GameRigJoint.y),("Joint Z",\GameRigJoint.z)] {
                    properties.add(gameRow([gameLabel(caption),GameNumber(joint[keyPath:key],range:-10...10) { [weak self] value in guard let self else { return }; self.editObject { $0.rig?.joints[self.jointIndex][keyPath:key] = value }; self.rebuildScene() }]))
                }
                properties.add(gameRow([gameLabel("Cycles / sec"),GameNumber(rig.speed,range:0.1...10) { [weak self] value in self?.editObject { $0.rig?.speed = value }; self?.rebuildScene() }]))
                properties.add(gameRow([gameLabel("Stride °"),GameNumber(rig.stride,range:0...90) { [weak self] value in self?.editObject { $0.rig?.stride = value }; self?.rebuildScene() }]))
                properties.add(GameButton(previewTimer == nil ? "Preview walk" : "Stop walk preview") { [weak self] in self?.toggleRigPreview() })
                properties.add(GameButton("Add movement + walking") { [weak self] in self?.addCharacterLogic(sprite:false) })
                properties.add(GameButton("Remove rig") { [weak self] in self?.previewTimer?.invalidate(); self?.previewTimer = nil; self?.editObject { $0.rig = nil }; self?.refreshInspector(); self?.rebuildScene() })
            } else {
                properties.add(GameButton("Create humanoid rig") { [weak self] in self?.editObject { $0.rig = .humanoid() }; self?.jointIndex = 0; self?.rebuildScene(); self?.refreshInspector() })
            }
            let guide = NSTextField(wrappingLabelWithString:"For upright, front-facing humanoids. Fit the joint dots to the body; weights rebind when a joint changes. Imported animation clips are not retained."); guide.font = .systemFont(ofSize:11); guide.widthAnchor.constraint(equalToConstant:208).isActive = true; properties.add(guide)
        }
    }
    private func toggleRigPreview() {
        if previewTimer != nil { previewTimer?.invalidate(); previewTimer = nil; previewTime = 0; applyTransforms() }
        else { previewTime = 0; previewTimer = Timer.scheduledTimer(withTimeInterval:1.0/30,repeats:true) { [weak self] _ in self?.previewTime += 1.0/30; self?.applyTransforms() } }
        refreshInspector()
    }
    private func addCharacterLogic(sprite:Bool) {
        let movement = GameAction(kind:.keyboard,value:4)
        let condition = GameAction(kind:.ifKey,value:1,text:"movement")
        let animate = GameAction(kind:sprite ? .spriteAnimation : .walk,value:1)
        let stop = GameAction(kind:.stopAnimation,value:1)
        var rule = GameRule(actions:[movement,condition,animate,stop])
        rule.graph = GameGraph(wires:[GameWire(from:rule.id,to:movement.id),GameWire(from:movement.id,to:condition.id),GameWire(from:condition.id,port:.yes,to:animate.id),GameWire(from:condition.id,port:.no,to:stop.id)],positions:[GameNodePosition(id:rule.id,x:30,y:100),GameNodePosition(id:movement.id,x:300,y:100),GameNodePosition(id:condition.id,x:570,y:100),GameNodePosition(id:animate.id,x:840,y:35),GameNodePosition(id:stop.id,x:840,y:190)])
        editObject { if $0.rules.count < 64 { $0.rules.append(rule) } }; refreshLogic()
        status.stringValue = "Connected movement → moving-key branch → animation / stop. Press Play and use WASD."
    }
    private func remember(_ before: GameProject? = nil) { undoSteps.append(before ?? project); if undoSteps.count > 30 { undoSteps.removeFirst() }; redoSteps.removeAll() }
    private func changed() { dirty = saved != project; updateTitle() }
    private func updateTitle() {
        view.window?.title = "\(project.name) — \(project.dimension.rawValue) Game Maker"; view.window?.isDocumentEdited = dirty; view.window?.representedURL = projectURL
        undoButton?.isEnabled = play == nil && !undoSteps.isEmpty; redoButton?.isEnabled = play == nil && !redoSteps.isEmpty
    }
    private func editObject(_ edit: (inout GameObject) -> Void) {
        guard play == nil, let index = project.objects.firstIndex(where: { $0.id == selected }) else { return }
        let before = project; edit(&project.objects[index]); guard project != before else { return }; remember(before); changed(); applyTransforms(); highlight()
    }
    @objc private func renameObject(_ field: NSTextField) { let name = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); if !name.isEmpty { let keep = selected; editObject { $0.name = name }; table.reloadData(); select(keep) } }
    @objc private func renameGame() { let name = titleField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); if play == nil, !name.isEmpty, name != project.name { remember(); project.name = name; changed() } }
    private func undoEdit() { guard play == nil, let previous = undoSteps.popLast() else { return }; redoSteps.append(project); project = previous; titleField.stringValue = project.name; refreshAssets(); changed(); refresh(); rebuildScene() }
    private func redoEdit() { guard play == nil, let next = redoSteps.popLast() else { return }; undoSteps.append(project); project = next; titleField.stringValue = project.name; refreshAssets(); changed(); refresh(); rebuildScene() }
    private func drag(_ id: UUID, point: CGPoint, finished: Bool) {
        guard play == nil, let index = project.objects.firstIndex(where: { $0.id == id }) else { return }
        if dragStart == nil { dragStart = project }
        project.objects[index].x = GameEditorMath.position(point.x,grid:snapEnabled ? grid : 0)
        project.objects[index].y = GameEditorMath.position(point.y,grid:snapEnabled ? grid : 0)
        applyTransforms(); finishDrag(finished)
    }
    private func drag3D(_ id: UUID, point: SCNVector3, finished: Bool) {
        guard play == nil, let index = project.objects.firstIndex(where: { $0.id == id }) else { return }
        if dragStart == nil { dragStart = project }
        let old = dragStart!.objects[index]
        // Only snap axes that actually moved; dragging X must not change Y/Z.
        project.objects[index].x = point.x == old.x ? old.x : GameEditorMath.position(point.x,grid:snapEnabled ? grid : 0)
        project.objects[index].y = point.y == old.y ? old.y : GameEditorMath.position(point.y,grid:snapEnabled ? grid : 0)
        project.objects[index].z = point.z == old.z ? old.z : GameEditorMath.position(point.z,grid:snapEnabled ? grid : 0)
        applyTransforms(); finishDrag(finished)
    }
    private func finishDrag(_ finished: Bool) {
        if finished { if let before = dragStart, before != project { remember(before); changed() }; dragStart = nil; refreshInspector() }
    }
    private func addObjectMenu() {
        guard play == nil else { return }; view.window?.makeFirstResponder(nil)
        let titles = [project.dimension == .twoD ? "Rectangle" : "Cube",project.dimension == .twoD ? "Circle" : "Sphere","Empty object",project.dimension == .twoD ? "Platform" : "Floor","Wall"]
        let menu = NSMenu()
        for (index,title) in titles.enumerated() { let item = NSMenuItem(title:title,action:#selector(addPrimitive(_:)),keyEquivalent:""); item.tag = index; item.target = self; menu.addItem(item) }
        menu.popUp(positioning:nil,at:NSPoint(x:14,y:view.bounds.height-260),in:view)
    }
    @objc private func addPrimitive(_ item: NSMenuItem) {
        var object = GameObject(name:item.title,kind:item.tag == 1 ? .coin : item.tag == 2 ? .empty : .block)
        if item.tag == 3 { object.scaleX = 12; object.scaleY = 0.5; object.scaleZ = 12; object.y = project.dimension == .twoD ? -3 : -0.75; object.solid = true; object.colour = "#64748B" }
        if item.tag == 4 { object.scaleX = 0.5; object.scaleY = 4; object.scaleZ = 8; object.x = 4; object.y = project.dimension == .twoD ? 0 : 1; object.solid = true; object.colour = "#94A3B8" }
        addObject(object)
    }
    private func addObject(_ object: GameObject) {
        guard play == nil, project.objects.count < 2000 else { return }; remember(); project.objects.append(object); selected = object.id; objectSearch.stringValue = ""; changed(); refresh(); rebuildScene()
    }
    private func moveLayer(_ delta:Int) {
        guard play == nil, let index = project.objects.firstIndex(where: { $0.id == selected }), project.objects.indices.contains(index+delta) else { return }
        remember(); project.objects.swapAt(index,index+delta); changed(); refresh(); applyTransforms()
    }
    private func duplicateObject() {
        guard var object = selectedObject else { return }; object.id = UUID(); object.name += " copy"; object.x = min(10000,object.x+1)
        for r in object.rules.indices {
            let old = object.rules[r]; var mapping: [UUID:UUID] = [old.id:UUID()]
            for a in old.actions { mapping[a.id] = UUID() }
            object.rules[r].id = mapping[old.id]!
            if object.rules[r].otherID == selected { object.rules[r].otherID = object.id }
            for a in object.rules[r].actions.indices {
                object.rules[r].actions[a].id = mapping[old.actions[a].id]!
                if object.rules[r].actions[a].targetID == selected { object.rules[r].actions[a].targetID = nil }
                if let selected, object.rules[r].actions[a].text == "patrol_" + selected.uuidString { object.rules[r].actions[a].text = "patrol_" + object.id.uuidString }
            }
            if var graph = old.graph {
                graph.wires = graph.wires.map { GameWire(from:mapping[$0.from]!,port:$0.port,to:mapping[$0.to]!) }
                graph.positions = graph.positions.map { GameNodePosition(id:mapping[$0.id]!,x:$0.x,y:$0.y) }
                object.rules[r].graph = graph
            }
        }
        addObject(object)
    }
    private func deleteObject() {
        guard play == nil, let selected else { return }; remember(); project.objects.removeAll { $0.id == selected }
        for i in project.objects.indices { for r in project.objects[i].rules.indices {
            if project.objects[i].rules[r].otherID == selected { project.objects[i].rules[r].otherID = nil; project.objects[i].rules[r].enabled = false }
            let removed = Set(project.objects[i].rules[r].actions.filter { $0.targetID == selected }.map(\.id))
            project.objects[i].rules[r].actions.removeAll { removed.contains($0.id) }
            project.objects[i].rules[r].graph?.wires.removeAll { removed.contains($0.from) || removed.contains($0.to) }
            project.objects[i].rules[r].graph?.positions.removeAll { removed.contains($0.id) }
        } }
        self.selected = nil; changed(); refresh(); rebuildScene()
    }
    private func refreshAssets() {
        textures.removeAll(); meshes.removeAll()
        let baked = Set(project.assets.filter { $0.path.hasSuffix(".nvmesh") }.map { String($0.path.dropLast(7)) })
        for asset in project.assets {
            let ext = URL(fileURLWithPath:asset.path).pathExtension.lowercased()
            if ["png","jpg","jpeg"].contains(ext) { textures[asset.id] = NSImage(data:asset.data) }
            if (ext == "nvmesh" || (ext == "obj" && !baked.contains(asset.path))), project.dimension == .threeD { meshes[asset.id] = try? GameMesh.read(asset) }
        }
        assetTable.reloadData()
    }
    private func importAssets() {
        guard play == nil else { return }; view.window?.makeFirstResponder(nil)
        let panel = NSOpenPanel(); panel.title = "Import sprites, 3D models, or an asset folder"
        panel.message = "Select a folder to include model materials, textures and all supporting files. Models import as editable static meshes; use Character Rig to add walking."
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            var candidate = project
            if project.dimension == .threeD { candidate = try GameModelImporter.importModels(panel.urls,into:project) }
            else { try candidate.importFiles(panel.urls) }
            remember(); project = candidate; refreshAssets(); refreshInspector(); changed()
            if !placeableAssets.isEmpty { assetTable.selectRowIndexes(IndexSet(integer:placeableAssets.count-1),byExtendingSelection:false) }
            status.stringValue = "Imported \(panel.urls.count) assets. Select one in Assets → Add asset to scene."
        } catch { show(error) }
    }
    private func placeAsset() {
        guard placeableAssets.indices.contains(assetTable.selectedRow) else { status.stringValue = "Select a sprite or 3D model in Assets first."; return }
        let asset = placeableAssets[assetTable.selectedRow]; let model = meshes[asset.id] != nil
        var object = GameObject(name:URL(fileURLWithPath:asset.path.hasSuffix(".nvmesh") ? String(asset.path.dropLast(7)) : asset.path).deletingPathExtension().lastPathComponent,kind:model ? .model : .sprite,imageID:model ? nil : asset.id)
        object.modelID = model ? asset.id : nil; addObject(object)
    }
    private func save(as saveAs: Bool) -> Bool {
        view.window?.makeFirstResponder(nil); renameGame(); var destination = projectURL
        if destination == nil || saveAs {
            let panel = NSSavePanel(); panel.title = "Save game project with embedded assets"; panel.allowedFileTypes = ["netvistagame"]
            panel.nameFieldStringValue = project.name.replacingOccurrences(of:"/",with:"-") + ".netvistagame"; panel.directoryURL = projectURL?.deletingLastPathComponent() ?? FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first
            guard panel.runModal() == .OK, let url = panel.url else { return false }; destination = url
        }
        do { try project.save(to:destination!); projectURL = destination; saved = project; dirty = false; updateTitle(); NSDocumentController.shared.noteNewRecentDocumentURL(destination!); status.stringValue = "Saved scene, blocks and all imported assets."; return true } catch { show(error); return false }
    }
    private func openGame() { let panel = NSOpenPanel(); panel.allowedFileTypes = ["netvistagame"]; if panel.runModal() == .OK, let url = panel.url { NSApp.delegate?.application?(NSApp,open:[url]) } }
    private func exportGame() {
        guard play == nil else { return }; view.window?.makeFirstResponder(nil); renameGame()
        let alert = NSAlert(); alert.messageText = "Export a playable source project"; alert.informativeText = "Both targets include your 2D or 3D scene, assets and behaviour blocks. Three.js needs Node.js for setup; Python needs Panda3D. This exports source, not an installer."
        alert.addButton(withTitle:"Three.js"); alert.addButton(withTitle:"Python"); alert.addButton(withTitle:"Cancel")
        let answer = alert.runModal(); guard answer != .alertThirdButtonReturn else { return }
        let panel = NSSavePanel(); panel.title = "Create a new game export folder"; panel.nameFieldStringValue = project.name.replacingOccurrences(of:"/",with:"-") + (answer == .alertFirstButtonReturn ? "-JavaScript" : "-Python"); panel.directoryURL = FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try GameExporter.export(project,to:destination,target:answer == .alertFirstButtonReturn ? .threeJS : .python); status.stringValue = "Export complete. Open README.md in the exported folder to run your game."; NSWorkspace.shared.activateFileViewerSelecting([destination.appendingPathComponent("README.md")]) } catch { show(error) }
    }
    func confirmClose() -> Bool {
        view.window?.makeFirstResponder(nil); renameGame(); guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to \(project.name)?"; alert.informativeText = "Your scene, behaviour blocks and imported assets will be saved together."
        alert.addButton(withTitle:"Save"); alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Don't Save")
        switch alert.runModal() { case .alertFirstButtonReturn: return save(as:false); case .alertThirdButtonReturn: return true; default: return false }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }
    func windowWillClose(_ notification: Notification) { previewTimer?.invalidate(); timer?.invalidate(); timer = nil; onClose?() }
    func windowDidResignKey(_ notification: Notification) { keys.removeAll(); lastTick = ProcessInfo.processInfo.systemUptime }
    private func show(_ error: Error) { NSAlert(error:error).runModal() }
    private func togglePlay() {
        previewTimer?.invalidate(); previewTimer = nil
        view.window?.makeFirstResponder(nil); renameGame()
        if play != nil {
            timer?.invalidate(); timer = nil; play = nil; paused = false; playButton.title = "▶ Play"; status.stringValue = "Stopped. Scene restored — gameplay never edits your saved objects."
        } else {
            editorCamera2D = spriteView.scene?.camera.map { ($0.position,$0.xScale) }
            editorCamera3D = sceneView.pointOfView?.transform
            logicWasHidden = logic.isHidden
            play = GamePlayState(objects:project.objects,dimension:project.dimension); playButton.title = "■ Stop"; lastTick = ProcessInfo.processInfo.systemUptime
            timer = Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in self?.tick() }; RunLoop.main.add(timer!,forMode:.common)
            status.stringValue = project.objects.isEmpty ? "Playing an empty scene. Stop and add objects to build your game." : "Playing your behaviour blocks. Esc to stop."
        }
        keys.removeAll(); spriteView.editing = play == nil; sceneView.editing = play == nil; titleField.isEnabled = play == nil
        editingButtons.forEach { $0.isEnabled = play == nil }; table.isEnabled = play == nil; assetTable.isEnabled = play == nil
        logic.setEditing(play == nil)
        if play == nil { logic.isHidden = logicWasHidden }
        empty.isHidden = play != nil || !project.objects.isEmpty
        rebuildScene(preserveCamera:false)
        if play == nil {
            if let saved = editorCamera2D { spriteView.scene?.camera?.position = saved.0; spriteView.scene?.camera?.setScale(saved.1) }
            if let saved = editorCamera3D { sceneView.pointOfView?.transform = saved }
            highlight()
        }
        refreshInspector(); updateTransport(); updateTitle()
    }
    private func updateTransport() {
        pauseButton.isEnabled = play != nil; pauseButton.title = paused ? "▶ Resume" : "Pause"
        stepButton.isEnabled = play != nil && paused; restartButton.isEnabled = play != nil
    }
    private func togglePause() {
        guard play != nil else { return }; paused.toggle(); keys.removeAll(); lastTick = ProcessInfo.processInfo.systemUptime
        updateTransport(); updateDebugger()
    }
    private func stepFrame() {
        guard play != nil, paused else { return }; play?.step(keys:[],seconds:1.0/60); applyTransforms(); updateDebugger()
    }
    private func restartPlay() {
        guard play != nil else { return }; play = GamePlayState(objects:project.objects,dimension:project.dimension)
        keys.removeAll(); lastTick = ProcessInfo.processInfo.systemUptime; applyTransforms(); updateDebugger()
    }
    private func showDebugger() {
        properties.clear(); properties.add(gameLabel("LIVE GAME STATE",strong:true))
        debugText = NSTextField(wrappingLabelWithString: "")
        debugText.font = .monospacedSystemFont(ofSize:12,weight:.regular); debugText.textColor = .labelColor
        properties.add(debugText,fill:true)
        let hint = NSTextField(wrappingLabelWithString:"Pause to inspect. Step advances one frame. Restart resets gameplay without leaving Play. Stop restores the original scene.")
        hint.font = .systemFont(ofSize:11); hint.textColor = .secondaryLabelColor; properties.add(hint,fill:true)
        updateDebugger()
    }
    private func updateDebugger() {
        guard let play else { return }; lastDebugRefresh = play.elapsed
        var lines = [paused ? "PAUSED" : "RUNNING",String(format:"Time       %.2f s",play.elapsed),String(format:"Score      %.0f",play.score),"Objects    \(play.objects.count-play.destroyed.count) / \(play.objects.count)","", "VARIABLES"]
        if play.variables.isEmpty { lines.append("No variables yet") }
        for key in play.variables.keys.sorted().prefix(30) { lines.append("\(key.prefix(20))\n  \(String(format:"%.3g",play.variables[key]!))") }
        if let object = play.objects.first(where: { $0.id == selected }) {
            lines += ["", "SELECTED OBJECT",object.name,String(format:"X %.2f  Y %.2f",object.x,object.y),String(format:"Z %.2f  Size %.2f",object.z,object.size),play.destroyed.contains(object.id) ? "Destroyed" : object.visible ? "Visible" : "Hidden"]
        }
        debugText.stringValue = lines.joined(separator:"\n")
        status.stringValue = String(format:"%@ · %.2f s · Score %.0f · Esc to stop",paused ? "PAUSED" : "PLAY",play.elapsed,play.score)
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime; let dt = now-lastTick; lastTick = now
        guard play != nil, !paused, view.window?.isKeyWindow == true else { keys.removeAll(); return }; play?.step(keys:keys,seconds:dt); applyTransforms()
        if let play, play.elapsed-lastDebugRefresh >= 0.15 { updateDebugger() }
    }
    private func rebuildScene(preserveCamera: Bool = true) {
        let camera2D = play == nil && preserveCamera ? spriteView.scene?.camera.map { ($0.position,$0.xScale) } : nil
        let camera3D = play == nil && preserveCamera ? sceneView.pointOfView?.transform : nil
        sprites.removeAll(); nodes.removeAll(); rigs.removeAll()
        gizmo = nil
        if project.dimension == .twoD {
            let scene = SKScene(size:CGSize(width:840,height:520)); scene.anchorPoint = CGPoint(x:0.5,y:0.5); scene.scaleMode = .aspectFit; scene.backgroundColor = NSColor(calibratedRed:0.09,green:0.106,blue:0.137,alpha:1)
            let camera = SKCameraNode(); scene.addChild(camera); scene.camera = camera
            if let previous = camera2D { camera.position = previous.0; camera.setScale(previous.1) }
            if play == nil {
                for x in -50...50 { let line = SKShapeNode(rectOf:CGSize(width:1,height:4000)); line.position.x = CGFloat(x*40); line.fillColor = .darkGray; line.strokeColor = .clear; line.alpha = 0.2; line.zPosition = -1; scene.addChild(line) }
                for y in -50...50 { let line = SKShapeNode(rectOf:CGSize(width:4000,height:1)); line.position.y = CGFloat(y*40); line.fillColor = .darkGray; line.strokeColor = .clear; line.alpha = 0.2; line.zPosition = -1; scene.addChild(line) }
                let frame = SKShapeNode(rectOf:CGSize(width:840,height:520)); frame.strokeColor = NSColor.white.withAlphaComponent(0.35); frame.lineWidth = 1; frame.zPosition = -0.5; scene.addChild(frame)
                let label = SKLabelNode(text:"GAME CAMERA · 21 × 13"); label.fontName = "Menlo"; label.fontSize = 11; label.fontColor = .gray; label.position = CGPoint(x:0,y:270); label.zPosition = -0.5; scene.addChild(label)
            }
            for object in project.objects {
                let node: SKNode
                if let id = object.imageID, let image = textures[id] { let sprite = SKSpriteNode(texture:SKTexture(image:image)); sprite.size = CGSize(width:40,height:40); sprite.color = gameObjectColour(object); sprite.colorBlendFactor = object.colour == nil ? 0 : 1; node = sprite }
                else { let shape = object.kind == .coin ? SKShapeNode(circleOfRadius:20) : SKShapeNode(rectOf:CGSize(width:40,height:40)); shape.fillColor = object.kind == .empty ? .clear : gameObjectColour(object); shape.strokeColor = object.kind == .empty ? .gray : .clear; node = shape }
                node.name = object.id.uuidString; scene.addChild(node); sprites[object.id] = node
            }; spriteView.presentScene(scene)
        } else {
            let scene = SCNScene(); scene.background.contents = NSColor(calibratedRed:0.09,green:0.106,blue:0.137,alpha:1)
            let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.fieldOfView = 45; camera.camera?.zFar = 30000; camera.position = SCNVector3(0,15,17); camera.look(at:SCNVector3Zero); scene.rootNode.addChildNode(camera)
            let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni; light.light?.intensity = 1400; light.position = SCNVector3(-4,12,8); scene.rootNode.addChildNode(light)
            let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 450; scene.rootNode.addChildNode(ambient)
            if play == nil { for i in -10...10 { for axis in [true,false] { let line = SCNNode(geometry:SCNBox(width:axis ? 20 : 0.015,height:0.005,length:axis ? 0.015 : 20,chamferRadius:0)); line.position = SCNVector3(axis ? 0 : Float(i),-0.501,axis ? Float(i) : 0); line.geometry?.firstMaterial?.diffuse.contents = NSColor.darkGray; scene.rootNode.addChildNode(line) } } }
            for object in project.objects {
                let geometry: SCNGeometry
                if let id = object.modelID, let mesh = meshes[id] {
                    let vertices = stride(from:0,to:mesh.positions.count,by:3).map { SCNVector3(mesh.positions[$0],mesh.positions[$0+1],mesh.positions[$0+2]) }
                    let uv = stride(from:0,to:mesh.uv.count,by:2).map { CGPoint(x:Double(mesh.uv[$0]),y:Double(mesh.uv[$0+1])) }
                    geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(textureCoordinates:uv)],elements:[SCNGeometryElement(indices:Array(0..<Int32(vertices.count)),primitiveType:.triangles)])
                } else if object.kind == .sprite { geometry = SCNPlane(width:1,height:1) }
                else if object.kind == .coin { geometry = SCNSphere(radius:0.5) }
                else { geometry = SCNBox(width:1,height:1,length:1,chamferRadius:0) }
                let material = SCNMaterial(); material.diffuse.contents = object.imageID.flatMap { textures[$0] } ?? gameObjectColour(object); material.isDoubleSided = true
                if object.imageID != nil { material.multiply.contents = gameObjectColour(object) }
                material.lightingModel = object.kind == .sprite || object.kind == .model ? .constant : .lambert; geometry.materials = [material]
                let node: SCNNode
                if let rig = object.rig, let id = object.modelID, let mesh = meshes[id] {
                    let renderer = GameRigRenderer(mesh:mesh,rig:rig,material:material); rigs[object.id] = renderer; node = renderer.root
                    if play == nil, object.id == selected { renderer.guides(selected:jointIndex) }
                } else { node = SCNNode(geometry:geometry) }
                node.name = object.id.uuidString; scene.rootNode.addChildNode(node); nodes[object.id] = node
            }
            if let previous = camera3D { camera.transform = previous }
            sceneView.scene = scene; sceneView.pointOfView = camera; sceneView.allowsCameraControl = play == nil; sceneView.antialiasingMode = .multisampling4X
        }; applyTransforms(); highlight()
    }
    private func applyTransforms() {
        for (i,o) in (play?.objects ?? project.objects).enumerated() {
            let hidden = !o.visible || play?.destroyed.contains(o.id) == true || (play != nil && o.kind == .empty)
            if let node = sprites[o.id] { node.position = CGPoint(x:o.x*40,y:o.y*40); node.xScale = o.size*o.scaleX; node.yScale = o.size*o.scaleY; node.zRotation = o.rotation * .pi/180; node.zPosition = CGFloat(i)*0.001; node.alpha = o.opacity; node.isHidden = hidden }
            if let sprite = sprites[o.id] as? SKSpriteNode, let sheet = o.spriteSheet, let image = o.imageID.flatMap({ textures[$0] }) {
                let animated = play?.animations[o.id] == "sprite"
                let time = animated ? (play?.elapsed ?? 0) * (play?.animationSpeeds[o.id] ?? 1) : 0
                let frame = Int(time * sheet.fps) % sheet.frames
                let rect = CGRect(x:Double(frame % sheet.columns)/Double(sheet.columns),y:1-Double(frame / sheet.columns+1)/Double(sheet.rows),width:1/Double(sheet.columns),height:1/Double(sheet.rows))
                if sprite.userData?["frame"] as? String != "\(frame):\(sheet.columns):\(sheet.rows)" { sprite.texture = SKTexture(rect:rect,in:SKTexture(image:image)); if sprite.userData == nil { sprite.userData = NSMutableDictionary() }; sprite.userData?["frame"] = "\(frame):\(sheet.columns):\(sheet.rows)" }
            }
            if let node = nodes[o.id], o.kind == .sprite, let sheet = o.spriteSheet {
                let time = play?.animations[o.id] == "sprite" ? (play?.elapsed ?? 0)*(play?.animationSpeeds[o.id] ?? 1) : 0
                let frame = Int(time*sheet.fps) % sheet.frames
                var transform = SCNMatrix4MakeScale(1/Double(sheet.columns),1/Double(sheet.rows),1)
                transform.m41 = Double(frame % sheet.columns)/Double(sheet.columns)
                transform.m42 = 1-Double(frame / sheet.columns+1)/Double(sheet.rows)
                node.geometry?.firstMaterial?.diffuse.contentsTransform = transform
            }
            if let rig = rigs[o.id] {
                rig.pose(time:(play?.elapsed ?? previewTime)*(play?.animationSpeeds[o.id] ?? 1),walking:play?.animations[o.id] == "walk" || (previewTimer != nil && selected == o.id))
            }
            if let node = nodes[o.id] { node.position = SCNVector3(o.x,o.y,o.z); node.scale = SCNVector3(o.size*o.scaleX,o.size*o.scaleY,o.size*o.scaleZ); node.eulerAngles.y = CGFloat(o.rotation * .pi/180); node.opacity = o.opacity; node.isHidden = hidden || o.kind == .empty }
        }
        updateGizmo()
    }
    private func highlight() {
        for (id,node) in sprites { node.childNode(withName:"selection")?.removeFromParent(); if play == nil, id == selected { let border = SKShapeNode(rectOf:CGSize(width:44,height:44)); border.name = "selection"; border.strokeColor = .white; border.lineWidth = 1; border.zPosition = 1; node.addChild(border) } }
        for (id,renderer) in rigs { if play == nil, id == selected { renderer.guides(selected:jointIndex) } else { renderer.root.childNode(withName:"rig-guides",recursively:false)?.removeFromParentNode() } }
        for (id,node) in nodes { node.geometry?.firstMaterial?.emission.contents = play == nil && id == selected ? NSColor(calibratedWhite:0.15,alpha:1) : NSColor.black }
        updateGizmo()
    }
    private func updateGizmo() {
        guard play == nil, project.dimension == .threeD, let object = selectedObject, let scene = sceneView.scene else {
            gizmo?.removeFromParentNode(); gizmo = nil; sceneView.selectedID = nil; return
        }
        if gizmo == nil {
            let root = SCNNode()
            for (axis,colour) in [NSColor.systemRed,.systemGreen,.systemBlue].enumerated() {
                let arm = SCNNode()
                if axis == 0 { arm.eulerAngles.z = -.pi/2 }; if axis == 2 { arm.eulerAngles.x = .pi/2 }
                for (geometry,offset) in [(SCNCylinder(radius:0.035,height:0.85) as SCNGeometry,0.425),(SCNCone(topRadius:0,bottomRadius:0.12,height:0.3) as SCNGeometry,1.0)] {
                    let material = SCNMaterial(); material.diffuse.contents = colour; material.lightingModel = .constant; material.readsFromDepthBuffer = false; material.writesToDepthBuffer = false
                    geometry.materials = [material]
                    let handle = SCNNode(geometry:geometry); handle.position.y = offset; handle.name = "gizmo-\(axis)"; handle.renderingOrder = 1000
                    arm.addChildNode(handle)
                }
                root.addChildNode(arm)
            }
            scene.rootNode.addChildNode(root); gizmo = root
        }
        let position = SCNVector3(object.x,object.y,object.z)
        gizmo?.position = position
        let size = max(1.5,min(6,object.size*0.8))
        gizmo?.scale = SCNVector3(size,size,size)
        sceneView.selectedID = object.id; sceneView.selectedPosition = position
    }
    private func focusSelected() {
        guard let object = selectedObject, play == nil else { return }
        frameObjects([object]); status.stringValue = "Focused \(object.name). \(project.dimension == .threeD ? "Red X · Green Y · Blue Z handles move the object." : "Drag to move; scroll to pan; Option-scroll to zoom.")"
    }
    private func resetCamera() {
        if project.dimension == .twoD { spriteView.scene?.camera?.position = .zero; spriteView.scene?.camera?.setScale(1) }
        else { sceneView.pointOfView?.position = SCNVector3(0,15,17); sceneView.pointOfView?.look(at:SCNVector3Zero) }
    }
    private func frameScene() {
        frameObjects(project.objects.filter(\.visible))
    }
    private func frameObjects(_ objects: [GameObject]) {
        guard !objects.isEmpty else { resetCamera(); return }
        let lowX = objects.map { $0.x-$0.size*$0.scaleX/2 }.min()!, highX = objects.map { $0.x+$0.size*$0.scaleX/2 }.max()!
        let lowY = objects.map { $0.y-$0.size*$0.scaleY/2 }.min()!, highY = objects.map { $0.y+$0.size*$0.scaleY/2 }.max()!
        let lowZ = objects.map { $0.z-$0.size*$0.scaleZ/2 }.min()!, highZ = objects.map { $0.z+$0.size*$0.scaleZ/2 }.max()!
        let x = (lowX+highX)/2, y = (lowY+highY)/2, z = (lowZ+highZ)/2
        if project.dimension == .twoD { spriteView.scene?.camera?.position = CGPoint(x:x*40,y:y*40); spriteView.scene?.camera?.setScale(max(0.2,max((highX-lowX+2)/21,(highY-lowY+2)/13))) }
        else {
            let span = max(4,max(highX-lowX,max(highY-lowY,highZ-lowZ))*1.5+2)
            sceneView.pointOfView?.position = SCNVector3(x,y+span,z+span); sceneView.pointOfView?.look(at:SCNVector3(x,y,z))
        }
    }
    #if GAME_EDITOR_CHECKS
    func checkWorkflowFeatures() throws {
        let original = project
        let actor = project.objects[0]
        select(actor.id)
        editObject { $0.scaleX = 3; $0.scaleY = 0.5; $0.scaleZ = 2; $0.colour = "#00FF80" }; rebuildScene()
        if project.dimension == .twoD {
            precondition(sprites[actor.id]?.xScale == actor.size*3 && sprites[actor.id]?.yScale == actor.size*0.5)
            let colour = (sprites[actor.id] as? SKShapeNode)?.fillColor.usingColorSpace(.sRGB)
            precondition(colour?.greenComponent == 1)
        } else {
            precondition(nodes[actor.id]?.scale.x == actor.size*3 && nodes[actor.id]?.scale.z == actor.size*2)
            let colour = (nodes[actor.id]?.geometry?.firstMaterial?.diffuse.contents as? NSColor)?.usingColorSpace(.sRGB)
            precondition(colour?.greenComponent == 1)
        }
        undoEdit(); precondition(project == original)
        let undoCount = undoSteps.count
        if project.dimension == .twoD {
            drag(actor.id,point:CGPoint(x:1.24,y:-1.26),finished:false)
            drag(actor.id,point:CGPoint(x:2.24,y:-2.26),finished:true)
            precondition(selectedObject!.x == 2 && selectedObject!.y == -2.5)
        } else {
            drag3D(actor.id,point:SCNVector3(1.24,actor.y,actor.z),finished:false)
            drag3D(actor.id,point:SCNVector3(2.24,actor.y,actor.z),finished:true)
            precondition(selectedObject!.x == 2 && selectedObject!.y == actor.y)
        }
        precondition(undoSteps.count == undoCount+1,"A whole drag must create only one undo step")
        undoEdit(); precondition(project == original)
        addRecipe(.patrol)
        duplicateObject()
        let duplicate = selectedObject!
        precondition(duplicate.rules.flatMap(\.actions).contains { $0.text == "patrol_"+duplicate.id.uuidString })
        precondition(!duplicate.rules.flatMap(\.actions).contains { $0.text == "patrol_"+actor.id.uuidString })
        objectSearch.stringValue = "copy"; filterObjects()
        precondition(filteredObjects.count == 1 && filteredObjects[0].id == duplicate.id)
        deleteObject(); precondition(project.objects.count == 1 && project.objects[0].id == actor.id)
        objectSearch.stringValue = ""; filterObjects(); select(actor.id)
        let beforePlay = project
        togglePlay(); togglePause()
        precondition(paused && stepButton.isEnabled && !debugText.stringValue.isEmpty)
        let beforeTime = play!.elapsed
        stepFrame(); precondition(abs(play!.elapsed-beforeTime-1.0/60) < 0.000001)
        restartPlay(); precondition(play!.elapsed == 0 && paused)
        togglePause(); precondition(!paused && !stepButton.isEnabled)
        togglePlay(); precondition(project == beforePlay)
        if project.dimension == .twoD {
            spriteView.scene?.camera?.position = CGPoint(x:210,y:90); spriteView.scene?.camera?.setScale(2)
            rebuildScene(); precondition(spriteView.scene?.camera?.position.x == 210 && spriteView.scene?.camera?.xScale == 2)
            togglePlay(); togglePlay(); precondition(spriteView.scene?.camera?.position.x == 210)
        } else {
            sceneView.pointOfView?.position = SCNVector3(10,12,18)
            rebuildScene(); precondition(sceneView.pointOfView?.position.x == 10)
            togglePlay(); togglePlay(); precondition(sceneView.pointOfView?.position.x == 10)
            resetCamera(); select(actor.id); view.layoutSubtreeIfNeeded()
            _ = sceneView.snapshot()
            // Drag the red X arrow with actual view mouse events.
            let object = selectedObject!, scale = max(1.5,min(6,object.size*0.8))
            let handle = sceneView.projectPoint(SCNVector3(object.x+scale,object.y,object.z))
            let origin = sceneView.projectPoint(SCNVector3(object.x,object.y,object.z))
            let unit = sceneView.projectPoint(SCNVector3(object.x+1,object.y,object.z))
            let point = NSPoint(x:handle.x,y:handle.y)
            precondition(sceneView.hitTest(point,options:nil).contains { $0.node.name == "gizmo-0" },"The visible X handle must be hit-testable")
            func event(_ type:NSEvent.EventType,_ p:NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with:type,location:sceneView.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:view.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
            }
            let end = NSPoint(x:point.x+(unit.x-origin.x)*2,y:point.y+(unit.y-origin.y)*2)
            sceneView.mouseDown(with:event(.leftMouseDown,point)); sceneView.mouseDragged(with:event(.leftMouseDragged,end)); sceneView.mouseUp(with:event(.leftMouseUp,end))
            precondition(abs(selectedObject!.x-object.x-2) < 0.001,"Mouse dragging a gizmo must change the scene, not orbit the camera")
            undoEdit(); precondition(selectedObject?.x == object.x)
        }
        try project.validate()
        print("PASS: \(project.dimension.rawValue) snap/undo, filtered deletion, independent patrols, Pause/Step/Restart, camera preservation and direct handles")
    }
    func checkViewportRendering(width: Int) throws {
        let image: NSImage
        if project.dimension == .threeD { image = sceneView.snapshot() }
        else {
            guard let scene = spriteView.scene, let texture = spriteView.texture(from:scene,crop:CGRect(x:-420,y:-260,width:840,height:520)) else { preconditionFailure("SpriteKit failed to render") }
            image = NSImage(cgImage:texture.cgImage(),size:NSSize(width:840,height:520))
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let data = bitmap.representation(using:.png,properties:[:]) else { preconditionFailure("No viewport pixels") }
        precondition(bitmap.pixelsWide > 50 && bitmap.pixelsHigh > 50)
        try data.write(to:URL(fileURLWithPath:"/private/tmp/netvista-viewport-\(project.dimension.rawValue)-\(width).png"))
    }
    func checkCharacterFeatures() throws {
        project.objects = []; project.assets = []; selected = nil
        if project.dimension == .twoD {
            let image = NSImage(size:NSSize(width:64,height:16)); image.lockFocus()
            for (i,colour) in [NSColor.red,.green,.blue,.yellow].enumerated() { colour.setFill(); NSRect(x:i*16,y:0,width:16,height:16).fill() }; image.unlockFocus()
            let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
            let asset = GameAsset(path:"fixture/sheet.png",data:bitmap.representation(using:.png,properties:[:])!)
            project.assets = [asset]; refreshAssets()
            var sprite = GameObject(name:"Animated sprite",kind:.sprite,size:3,imageID:asset.id)
            sprite.spriteSheet = GameSpriteSheet(columns:4,rows:1,frames:4,fps:10); addObject(sprite); addCharacterLogic(sprite:true)
            togglePlay(); play?.step(keys:["d"],seconds:0.05); play?.step(keys:["d"],seconds:0.05); applyTransforms()
            precondition(sprites[sprite.id]?.userData?["frame"] as? String == "1:4:1")
            play?.step(keys:[],seconds:0.05); applyTransforms(); precondition(sprites[sprite.id]?.userData?["frame"] as? String == "0:4:1")
            togglePlay()
        } else {
            var mesh = GameMesh()
            let faces = [[0,1,3,0,3,2],[4,6,7,4,7,5],[0,4,5,0,5,1],[2,3,7,2,7,6],[0,2,6,0,6,4],[1,5,7,1,7,3]]
            for (x,y,w,h) in [(0.0,0.15,0.20,0.30),(0,0.42,0.16,0.16),(0.28,0.27,0.38,0.09),(-0.28,0.27,0.38,0.09),(0.09,-0.25,0.10,0.45),(-0.09,-0.25,0.10,0.45)] {
                let points = (0..<8).map { i in [Float(x + (i & 1 == 0 ? -w/2 : w/2)),Float(y + (i & 2 == 0 ? -h/2 : h/2)),Float(i & 4 == 0 ? -0.05 : 0.05)] }
                for face in faces { for i in face { mesh.positions += points[i]; mesh.uv += [0,0] } }
            }
            let asset = GameAsset(path:"fixture/character.nvmesh",data:try JSONEncoder().encode(mesh)); project.assets = [asset]; refreshAssets()
            var character = GameObject(name:"Walking character",kind:.model,size:6); character.modelID = asset.id; character.rig = .humanoid(); addObject(character); addCharacterLogic(sprite:false)
            precondition(rigs[character.id] != nil)
            togglePlay(); play?.step(keys:["d"],seconds:0.05); applyTransforms()
            precondition(rigs[character.id]!.root.childNode(withName:"Left thigh",recursively:true)!.eulerAngles.x != 0)
            play?.step(keys:[],seconds:0.05); applyTransforms()
            precondition(rigs[character.id]!.root.childNode(withName:"Left thigh",recursively:true)!.eulerAngles.x == 0)
            togglePlay(); previewTime = 0.13; rigs[character.id]?.pose(time:previewTime,walking:true)
        }
        print("PASS: \(project.dimension.rawValue) character animation, movement graph and idle reset")
    }
    func checkEditingAndPlay() {
        _ = view; precondition(project.objects.isEmpty); togglePlay(); precondition(play != nil); togglePlay(); precondition(project.objects.isEmpty)
        addObject(GameObject(name:"Test object",kind:.block)); editObject { $0.x = 4; $0.rules = [GameRule(actions:[GameAction(kind:.keyboard)])] }; refreshLogic()
        let before = project; togglePlay(); play?.step(keys:["d"],seconds:0.05); precondition(play!.objects[0].x > 4); togglePlay(); precondition(project == before)
        duplicateObject(); precondition(project.objects.count == 2); deleteObject(); precondition(project.objects.count == 1)
        undoEdit(); precondition(project.objects.count == 2); redoEdit(); precondition(project.objects.count == 1)
        select(project.objects.first?.id); refreshLogic(); precondition(project.dimension == .twoD ? sprites.count == project.objects.count : nodes.count == project.objects.count)
        addCharacterLogic(sprite:project.dimension == .twoD)
        precondition(project.objects[0].rules.last?.graph?.wires.count == 4)
        let withGraph = project; duplicateObject(); precondition(project.objects.count == 2)
        do { try project.validate() } catch { preconditionFailure("Duplicate broke graph: \(error)") }
        deleteObject(); undoEdit(); redoEdit(); precondition(project.objects.count == withGraph.objects.count)
        select(project.objects.first?.id); deleteObject(); precondition(project.objects.isEmpty); togglePlay(); togglePlay(); undoEdit(); precondition(project.objects.count == 1)
        select(project.objects.first?.id)
    }
    #endif
}
