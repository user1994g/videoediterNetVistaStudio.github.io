import Cocoa
import SpriteKit
import SceneKit

private final class GameSpriteView: SKView {
    var selected: ((UUID?) -> Void)?
    var moved: ((UUID,CGPoint,Bool) -> Void)?
    var editing = true
    private var dragged: UUID?
    private var offset = CGPoint.zero
    override func mouseDown(with event: NSEvent) {
        guard editing, let scene else { return }; let point = scene.convertPoint(fromView:convert(event.locationInWindow,from:nil))
        let node = scene.nodes(at:point).first { $0.name.flatMap(UUID.init(uuidString:)) != nil }
        dragged = node?.name.flatMap(UUID.init(uuidString:)); selected?(dragged)
        if let node { offset = CGPoint(x:point.x-node.position.x,y:point.y-node.position.y) }
    }
    override func mouseDragged(with event: NSEvent) { move(event,finished:false) }
    override func mouseUp(with event: NSEvent) { move(event,finished:true); dragged = nil }
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
    var editing = true
    override func mouseDown(with event: NSEvent) {
        if editing, var node = hitTest(convert(event.locationInWindow,from:nil),options:nil).first?.node {
            while node.name.flatMap(UUID.init(uuidString:)) == nil, let parent = node.parent { node = parent }
            if let id = node.name.flatMap(UUID.init(uuidString:)) { selected?(id) }
        }
        super.mouseDown(with:event)
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
    private let spriteView = GameSpriteView()
    private let sceneView = GameSceneView()
    private var sprites: [UUID: SKNode] = [:], nodes: [UUID: SCNNode] = [:]
    private var textures: [UUID: NSImage] = [:], meshes: [UUID: GameMesh] = [:]
    private var rigs: [UUID: GameRigRenderer] = [:]
    private var jointIndex = 0
    private var previewTimer: Timer?
    private var previewTime: Double = 0
    private let table = NSTableView(), assetTable = NSTableView()
    private let properties = GameScroll()
    private let logic = GameLogicPanel(frame:.zero)
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "Your scene is empty.\nImport a sprite or 3D model, then add it from Assets.\nOr use + Object to build with shapes.")
    private let titleField = NSTextField()
    private var playButton: GameButton!
    private var undoButton: GameButton!, redoButton: GameButton!
    private var editingButtons: [NSControl] = []
    private var selectedObject: GameObject? { project.objects.first { $0.id == selected } }
    private var placeableAssets: [GameAsset] { project.assets.filter { textures[$0.id] != nil || meshes[$0.id] != nil } }

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
        undoButton = GameButton("Undo") { [weak self] in self?.undoEdit() }; redoButton = GameButton("Redo") { [weak self] in self?.redoEdit() }
        titleField.stringValue = project.name; titleField.target = self; titleField.action = #selector(renameGame)
        titleField.widthAnchor.constraint(greaterThanOrEqualToConstant:130).isActive = true
        let toolbar = gameRow([home,gameLabel("GAME MAKER · \(project.dimension.rawValue)",strong:true),titleField,undoButton,redoButton,open,save,saveAs,export,playButton]); toolbar.spacing = 8
        let sidebar = NSStackView(); sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 10
        let objectsScroll = configure(table); objectsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:150).isActive = true
        let assetsScroll = configure(assetTable); assetsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:100).isActive = true
        let add = GameButton("+ Object") { [weak self] in self?.addObjectMenu() }
        let duplicate = GameButton("Duplicate") { [weak self] in self?.duplicateObject() }
        let layerUp = GameButton("↑") { [weak self] in self?.moveLayer(-1) }; layerUp.toolTip = "Move object earlier in the scene / draw order"
        let layerDown = GameButton("↓") { [weak self] in self?.moveLayer(1) }; layerDown.toolTip = "Move object later in the scene / draw order"
        let delete = GameButton("Delete") { [weak self] in self?.deleteObject() }
        let importButton = GameButton("Import sprites / models…") { [weak self] in self?.importAssets() }
        let place = GameButton("Add asset to scene") { [weak self] in self?.placeAsset() }
        for child in [gameLabel("SCENE / LAYERS",strong:true),objectsScroll,gameRow([add,delete]),gameRow([duplicate,layerUp,layerDown]),gameLabel("ASSETS",strong:true),assetsScroll,importButton,place] { sidebar.addArrangedSubview(child) }
        for scroll in [objectsScroll,assetsScroll] { scroll.widthAnchor.constraint(equalToConstant:206).isActive = true }
        let assetHint = NSTextField(wrappingLabelWithString:"PNG / JPG sprites · OBJ / DAE / STL / PLY / USD models\nAssets travel inside your game save."); assetHint.font = .systemFont(ofSize:11); assetHint.textColor = .secondaryLabelColor; assetHint.widthAnchor.constraint(equalToConstant:206).isActive = true; sidebar.addArrangedSubview(assetHint)
        let viewport = NSView()
        let render: NSView = project.dimension == .twoD ? spriteView : sceneView
        let fit = GameButton("Frame scene") { [weak self] in self?.frameScene() }
        let reset = GameButton("Game camera") { [weak self] in self?.resetCamera() }
        let tools = gameRow([gameLabel("SCENE",strong:true),fit,reset,gameLabel(project.dimension == .twoD ? "Scroll: pan · ⌥ scroll: zoom" : "Drag: orbit · Scroll: zoom")])
        toolbar.heightAnchor.constraint(equalToConstant:32).isActive = true
        tools.heightAnchor.constraint(equalToConstant:30).isActive = true
        status.heightAnchor.constraint(equalToConstant:18).isActive = true
        for child in [render,tools,empty] { viewport.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        empty.alignment = .center; empty.textColor = .secondaryLabelColor; empty.font = .systemFont(ofSize:14)
        NSLayoutConstraint.activate([tools.topAnchor.constraint(equalTo:viewport.topAnchor,constant:8),tools.leadingAnchor.constraint(equalTo:viewport.leadingAnchor,constant:10),render.topAnchor.constraint(equalTo:tools.bottomAnchor,constant:8),render.leadingAnchor.constraint(equalTo:viewport.leadingAnchor),render.trailingAnchor.constraint(equalTo:viewport.trailingAnchor),render.bottomAnchor.constraint(equalTo:viewport.bottomAnchor),empty.centerXAnchor.constraint(equalTo:render.centerXAnchor),empty.centerYAnchor.constraint(equalTo:render.centerYAnchor),empty.widthAnchor.constraint(lessThanOrEqualTo:render.widthAnchor,constant:-40)])
        let center = NSSplitView(); center.isVertical = false; center.dividerStyle = .thin
        center.addArrangedSubview(viewport); center.addArrangedSubview(logic)
        viewport.heightAnchor.constraint(greaterThanOrEqualToConstant:240).isActive = true
        logic.heightAnchor.constraint(greaterThanOrEqualToConstant:240).isActive = true
        let balanced = viewport.heightAnchor.constraint(equalTo:logic.heightAnchor,multiplier:1.1); balanced.priority = .defaultLow; balanced.isActive = true
        for child in [toolbar,sidebar,center,properties,status] { view.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12),toolbar.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),toolbar.topAnchor.constraint(equalTo:view.topAnchor,constant:10),
            sidebar.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12),sidebar.widthAnchor.constraint(equalToConstant:206),sidebar.topAnchor.constraint(equalTo:toolbar.bottomAnchor,constant:18),sidebar.bottomAnchor.constraint(equalTo:status.topAnchor,constant:-12),
            center.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:12),center.topAnchor.constraint(equalTo:toolbar.bottomAnchor,constant:12),center.bottomAnchor.constraint(equalTo:status.topAnchor,constant:-10),center.trailingAnchor.constraint(equalTo:properties.leadingAnchor,constant:-8),
            properties.widthAnchor.constraint(equalToConstant:240),properties.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-4),properties.topAnchor.constraint(equalTo:center.topAnchor),properties.bottomAnchor.constraint(equalTo:center.bottomAnchor),
            status.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:14),status.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-14),status.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-10)
        ])
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        editingButtons = [add,duplicate,layerUp,layerDown,delete,importButton,place,export,fit,reset]
        spriteView.selected = { [weak self] id in self?.select(id) }; spriteView.moved = { [weak self] id,point,finished in self?.drag(id,point:point,finished:finished) }; sceneView.selected = { [weak self] id in self?.select(id) }
        logic.changed = { [weak self] rules in
            guard let self, let index = self.project.objects.firstIndex(where: { $0.id == self.selected }), self.play == nil else { return }
            self.remember(); self.project.objects[index].rules = rules; self.changed()
        }
        refreshAssets(); refresh(); rebuildScene(); status.stringValue = "Empty by design. Add your assets, then connect an event to action blocks."
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp]) { [weak self] event in
            guard let self, event.window === self.view.window else { return event }
            if event.type == .keyDown, event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "s" { _ = self.save(as:event.modifierFlags.contains(.shift)); return nil }
                if event.charactersIgnoringModifiers == "z", !(self.view.window?.firstResponder is NSTextView) { if event.modifierFlags.contains(.shift) { self.redoEdit() } else { self.undoEdit() }; return nil }
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
        table.headerView = nil; table.rowHeight = 30; table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; return scroll
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === table ? project.objects.count : placeableAssets.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === table { let o = project.objects[row]; text = "\(o.visible ? "◈" : "○")  \(o.name)" }
        else { let a = placeableAssets[row]; text = "\(meshes[a.id] != nil ? "◇" : "▧")  \(URL(fileURLWithPath:a.path.hasSuffix(".nvmesh") ? String(a.path.dropLast(7)) : a.path).lastPathComponent)" }
        let label = NSTextField(labelWithString:text); label.lineBreakMode = .byTruncatingMiddle; label.font = .systemFont(ofSize:12); return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === table else { return }
        selected = project.objects.indices.contains(table.selectedRow) ? project.objects[table.selectedRow].id : nil
        refreshInspector(); refreshLogic(); highlight()
    }
    private func select(_ id: UUID?) {
        selected = id
        if let i = project.objects.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false) } else { table.deselectAll(nil) }
        refreshInspector(); refreshLogic(); highlight()
    }
    private func refresh() {
        let keep = selected; table.reloadData(); assetTable.reloadData(); select(keep)
        empty.isHidden = !project.objects.isEmpty || play != nil; updateTitle()
    }
    private func refreshLogic() { logic.show(object:selectedObject,objects:project.objects,dimension:project.dimension) }
    private func refreshInspector() {
        properties.clear(); properties.add(gameLabel("PROPERTIES",strong:true))
        guard let object = selectedObject else { properties.add(gameLabel("No object selected")); properties.add(gameLabel("Add sprites, models or empty objects.")); return }
        properties.add(gameLabel(object.name,strong:true))
        let name = NSTextField(string:object.name); name.target = self; name.action = #selector(renameObject); name.widthAnchor.constraint(equalToConstant:208).isActive = true; properties.add(name)
        properties.add(gameLabel("TRANSFORM",strong:true))
        for (caption,key,range) in [("X",\GameObject.x,-10000.0...10000),("Y",\GameObject.y,-10000.0...10000),("Z",\GameObject.z,-10000.0...10000),("Size",\GameObject.size,0.01...1000),("Rotation °",\GameObject.rotation,-360000.0...360000),("Opacity",\GameObject.opacity,0.0...1)] where caption != "Z" || project.dimension == .threeD {
            let label = gameLabel(caption); label.widthAnchor.constraint(equalToConstant:94).isActive = true
            properties.add(gameRow([label,GameNumber(object[keyPath:key],width:100,range:range) { [weak self] value in self?.editObject { $0[keyPath:key] = value } }]))
        }
        let visible = GameButton(object.visible ? "◉ Visible" : "○ Hidden") { [weak self] in self?.editObject { $0.visible.toggle() }; self?.refreshInspector() }
        let solid = GameButton(object.solid ? "✓ Solid collider" : "+ Solid collider") { [weak self] in self?.editObject { $0.solid.toggle() }; self?.refreshInspector() }
        properties.add(gameRow([visible,solid])); properties.add(gameLabel("TEXTURE",strong:true))
        let images = project.assets.filter { textures[$0.id] != nil }
        let picker = GamePopup(["Default colour"] + images.map { URL(fileURLWithPath:$0.path).lastPathComponent },selected:images.firstIndex(where: { $0.id == object.imageID }).map { $0+1 } ?? 0) { [weak self] i in self?.editObject { $0.imageID = i == 0 ? nil : images[i-1].id }; self?.rebuildScene() }
        picker.widthAnchor.constraint(equalToConstant:208).isActive = true; properties.add(picker)
        characterProperties(object)
        for text in [project.dimension == .twoD ? "Drag sprites to position them. One world unit = 40 pixels. The game camera frames 21 × 13 units." : "Y is height. WASD moves on X/Z. Sprites are flat XY planes. Models are centered and normalized to one unit.","Solid objects block Move and WASD actions. Collisions use axis-aligned boxes. Set position teleports. No gravity is added automatically."] {
            let guide = NSTextField(wrappingLabelWithString:text); guide.font = .systemFont(ofSize:11); guide.textColor = .secondaryLabelColor; guide.widthAnchor.constraint(equalToConstant:208).isActive = true; properties.add(guide)
        }
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
        if dragStart == nil { dragStart = project }; project.objects[index].x = max(-10000,min(10000,point.x)); project.objects[index].y = max(-10000,min(10000,point.y)); applyTransforms()
        if finished { if let before = dragStart, before != project { remember(before); changed() }; dragStart = nil; refreshInspector() }
    }
    private func addObjectMenu() {
        guard play == nil else { return }; view.window?.makeFirstResponder(nil)
        let titles = [project.dimension == .twoD ? "Rectangle" : "Cube",project.dimension == .twoD ? "Circle" : "Sphere","Empty object","Cancel"]
        let alert = NSAlert(); alert.messageText = "Add an object"; alert.informativeText = "Objects start with no behaviours. Imported sprites and models are in Assets."; titles.forEach { alert.addButton(withTitle:$0) }
        let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if (0...2).contains(response) { addObject(GameObject(name:titles[response],kind:[.block,.coin,.empty][response])) }
    }
    private func addObject(_ object: GameObject) {
        guard play == nil, project.objects.count < 2000 else { return }; remember(); project.objects.append(object); selected = object.id; changed(); refresh(); rebuildScene()
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
            for a in object.rules[r].actions.indices {
                object.rules[r].actions[a].id = mapping[old.actions[a].id]!
                if object.rules[r].actions[a].targetID == selected { object.rules[r].actions[a].targetID = nil }
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
            timer?.invalidate(); timer = nil; play = nil; playButton.title = "▶ Play"; status.stringValue = "Stopped. Scene restored — gameplay never edits your saved objects."
        } else {
            play = GamePlayState(objects:project.objects,dimension:project.dimension); playButton.title = "■ Stop"; lastTick = ProcessInfo.processInfo.systemUptime
            timer = Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in self?.tick() }; RunLoop.main.add(timer!,forMode:.common)
            status.stringValue = project.objects.isEmpty ? "Playing an empty scene. Stop and add objects to build your game." : "Playing your behaviour blocks. Esc to stop."
        }
        keys.removeAll(); spriteView.editing = play == nil; sceneView.editing = play == nil; titleField.isEnabled = play == nil
        editingButtons.forEach { $0.isEnabled = play == nil }; table.isEnabled = play == nil; assetTable.isEnabled = play == nil
        properties.isHidden = play != nil; logic.setEditing(play == nil); empty.isHidden = play != nil || !project.objects.isEmpty; rebuildScene(); updateTitle()
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime; let dt = now-lastTick; lastTick = now
        guard play != nil, view.window?.isKeyWindow == true else { keys.removeAll(); return }; play?.step(keys:keys,seconds:dt); applyTransforms()
        if let play { status.stringValue = String(format:"PLAY  ·  %.1f s  ·  Score %.0f  ·  Esc to stop",play.elapsed,play.score) }
    }
    private func rebuildScene() {
        sprites.removeAll(); nodes.removeAll(); rigs.removeAll()
        if project.dimension == .twoD {
            let scene = SKScene(size:CGSize(width:840,height:520)); scene.anchorPoint = CGPoint(x:0.5,y:0.5); scene.scaleMode = .aspectFit; scene.backgroundColor = NSColor(calibratedRed:0.09,green:0.106,blue:0.137,alpha:1)
            let camera = SKCameraNode(); scene.addChild(camera); scene.camera = camera
            if play == nil {
                for x in -50...50 { let line = SKShapeNode(rectOf:CGSize(width:1,height:4000)); line.position.x = CGFloat(x*40); line.fillColor = .darkGray; line.strokeColor = .clear; line.alpha = 0.2; line.zPosition = -1; scene.addChild(line) }
                for y in -50...50 { let line = SKShapeNode(rectOf:CGSize(width:4000,height:1)); line.position.y = CGFloat(y*40); line.fillColor = .darkGray; line.strokeColor = .clear; line.alpha = 0.2; line.zPosition = -1; scene.addChild(line) }
            }
            for object in project.objects {
                let node: SKNode
                if let id = object.imageID, let image = textures[id] { let sprite = SKSpriteNode(texture:SKTexture(image:image)); sprite.size = CGSize(width:40,height:40); node = sprite }
                else { let shape = object.kind == .coin ? SKShapeNode(circleOfRadius:20) : SKShapeNode(rectOf:CGSize(width:40,height:40)); shape.fillColor = object.kind == .empty ? .clear : object.kind == .coin ? .systemYellow : .systemBlue; shape.strokeColor = object.kind == .empty ? .gray : .clear; node = shape }
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
                let material = SCNMaterial(); material.diffuse.contents = object.imageID.flatMap { textures[$0] } ?? (object.kind == .coin ? NSColor.systemYellow : NSColor.systemBlue); material.isDoubleSided = true
                material.lightingModel = object.kind == .sprite || object.kind == .model ? .constant : .lambert; geometry.materials = [material]
                let node: SCNNode
                if let rig = object.rig, let id = object.modelID, let mesh = meshes[id] {
                    let renderer = GameRigRenderer(mesh:mesh,rig:rig,material:material); rigs[object.id] = renderer; node = renderer.root
                    if play == nil, object.id == selected { renderer.guides(selected:jointIndex) }
                } else { node = SCNNode(geometry:geometry) }
                node.name = object.id.uuidString; scene.rootNode.addChildNode(node); nodes[object.id] = node
            }
            sceneView.scene = scene; sceneView.pointOfView = camera; sceneView.allowsCameraControl = play == nil; sceneView.antialiasingMode = .multisampling4X
        }; applyTransforms(); highlight()
    }
    private func applyTransforms() {
        for (i,o) in (play?.objects ?? project.objects).enumerated() {
            let hidden = !o.visible || play?.destroyed.contains(o.id) == true || (play != nil && o.kind == .empty)
            if let node = sprites[o.id] { node.position = CGPoint(x:o.x*40,y:o.y*40); node.setScale(o.size); node.zRotation = o.rotation * .pi/180; node.zPosition = CGFloat(i)*0.001; node.alpha = o.opacity; node.isHidden = hidden }
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
            if let node = nodes[o.id] { node.position = SCNVector3(o.x,o.y,o.z); node.scale = SCNVector3(o.size,o.size,o.size); node.eulerAngles.y = CGFloat(o.rotation * .pi/180); node.opacity = o.opacity; node.isHidden = hidden || o.kind == .empty }
        }
    }
    private func highlight() {
        for (id,node) in sprites { node.childNode(withName:"selection")?.removeFromParent(); if play == nil, id == selected { let border = SKShapeNode(rectOf:CGSize(width:44,height:44)); border.name = "selection"; border.strokeColor = .white; border.lineWidth = 1; border.zPosition = 1; node.addChild(border) } }
        for (id,renderer) in rigs { if play == nil, id == selected { renderer.guides(selected:jointIndex) } else { renderer.root.childNode(withName:"rig-guides",recursively:false)?.removeFromParentNode() } }
        for (id,node) in nodes { node.geometry?.firstMaterial?.emission.contents = play == nil && id == selected ? NSColor(calibratedWhite:0.15,alpha:1) : NSColor.black }
    }
    private func resetCamera() {
        if project.dimension == .twoD { spriteView.scene?.camera?.position = .zero; spriteView.scene?.camera?.setScale(1) }
        else { sceneView.pointOfView?.position = SCNVector3(0,15,17); sceneView.pointOfView?.look(at:SCNVector3Zero) }
    }
    private func frameScene() {
        guard !project.objects.isEmpty else { resetCamera(); return }
        let xs = project.objects.map(\.x), ys = project.objects.map(\.y), zs = project.objects.map(\.z)
        let x = (xs.min()!+xs.max()!)/2, y = (ys.min()!+ys.max()!)/2, z = (zs.min()!+zs.max()!)/2
        if project.dimension == .twoD { spriteView.scene?.camera?.position = CGPoint(x:x*40,y:y*40); spriteView.scene?.camera?.setScale(max(1,max((xs.max()!-xs.min()!+4)/21,(ys.max()!-ys.min()!+4)/13))) }
        else { let span = max(10,max(xs.max()!-xs.min()!,max(ys.max()!-ys.min()!,zs.max()!-zs.min()!))+4); sceneView.pointOfView?.position = SCNVector3(x,y+span,z+span); sceneView.pointOfView?.look(at:SCNVector3(x,y,z)) }
    }
    #if GAME_EDITOR_CHECKS
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
