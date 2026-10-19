import UIKit
import UniformTypeIdentifiers
import SceneKit

/// Independent native Game Maker. Uses the same validated document, connected
/// rules, collider/runtime, model importer, rig weights and source exporters as
/// Mac. Local preview is never exported as a fake finished game binary.
final class GameWorkspaceViewController: UIViewController, UIDocumentPickerDelegate, UITableViewDataSource, UITableViewDelegate {
    var permitsEditing: () -> Bool = { false }
    var onHome: (() -> Void)?
    private(set) var session = try! GameWorkspaceSession()
    let viewport = GameWorkspaceViewport(), graph = GameWorkspaceGraphView()
    private let header = UIScrollView(), transport = UIScrollView(), panel = UIView(), properties = UIScrollView()
    private let content = UIStackView(), table = UITableView(frame:.zero,style:.plain)
    private let tabs = UISegmentedControl(items:["Objects","Assets","Properties","Logic"])
    private let titleLabel = MobileTheme.label("Game Maker · 2D",size:13,weight:.semibold), status = MobileTheme.label("Add objects or import your own sprites and models.",size:11)
    private var headerButtons:[UIButton] = [], transportButtons:[UIButton] = []
    private var play:GamePlayState?, timer:CADisplayLink?, lastTick:CFTimeInterval = 0, heldKeys = Set<String>(), paused = false
    private var ruleIndex = 0, nodeID:UUID?, rigJoint = 0
    private var snap:Double = 0.5, snapEnabled = true, busy = false, pickerMode = "open", pendingExport:URL?
    private var draftTask:DispatchWorkItem?, savedRevision:UInt64?
    private var fileGeneration:UInt64 = 0
    private let files = DispatchQueue(label:"com.netvistastudio.game.files",qos:.userInitiated)
    private let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    private var draftURL:URL { documents.appendingPathComponent("WorkingGame.netvistagame") }
    var isPlaying:Bool { play != nil }
    var playState:GamePlayState? { play }
    private var editable:Bool { permitsEditing() && !busy && play == nil }
    private var selectedRule:GameRule? { guard let o = session.selectedObject,o.rules.indices.contains(ruleIndex) else { return nil }; return o.rules[ruleIndex] }
    deinit { timer?.invalidate(); draftTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = MobileTheme.window; overrideUserInterfaceStyle = .dark
        view.accessibilityIdentifier = "game.workspace"
        for child in [titleLabel,header,transport,viewport,graph,tabs,panel,status] as [UIView] { view.addSubview(child) }
        panel.backgroundColor = MobileTheme.panel; panel.addSubview(table); panel.addSubview(properties)
        table.backgroundColor = .clear; table.dataSource = self; table.delegate = self; table.rowHeight = 48
        properties.addSubview(content); content.axis = .vertical; content.spacing = 9; content.alignment = .fill
        tabs.selectedSegmentIndex = 0; tabs.addAction(UIAction { [weak self] _ in self?.buildPanel(); self?.view.setNeedsLayout() },for:.valueChanged)
        headerButtons = [button("Studio Home","house","home") { [weak self] in self?.returnHome() },button("New","doc.badge.plus","new") { [weak self] in self?.newGame() },button("Open","folder","open") { [weak self] in self?.pick("open") },button("Save","square.and.arrow.down","save") { [weak self] in self?.saveCopy() },button("Import","plus","import") { [weak self] in self?.pick("assets") },button("Export","square.and.arrow.up","export") { [weak self] in self?.exportMenu() },button("Rename","pencil","rename") { [weak self] in self?.prompt("Game name",value:self?.session.project.name ?? "") { value in self?.edit { try self?.session.edit { $0.name = value } } } }]
        transportButtons = [button("Undo","arrow.uturn.backward","undo") { [weak self] in self?.undo() },button("Redo","arrow.uturn.forward","redo") { [weak self] in self?.redo() },button("Play","play.fill","play") { [weak self] in self?.togglePlay() },button("Pause","pause.fill","pause") { [weak self] in self?.togglePause() },button("Step","forward.frame","step") { [weak self] in self?.stepFrame() },button("Restart","backward.end","restart") { [weak self] in self?.restartPlay() },button("+ Object","cube","add") { [weak self] in self?.addMenu() },button("Frame","viewfinder","frame") { [weak self] in self?.viewport.fit() },button("Snap ✓",nil,"snap") { [weak self] in guard let self else { return }; self.snapEnabled.toggle(); self.transportButtons[8].setTitle(self.snapEnabled ? "Snap ✓" : "Snap off",for:.normal) },button("Axis XZ",nil,"axis") { [weak self] in self?.choose("3D drag plane",items:["XZ","XY","YZ","X","Y","Z"]) { self?.viewport.movementAxis = $0; self?.transportButtons[9].setTitle("Axis "+$0,for:.normal) } }]
        let directions = [("←","left"),("↑","up"),("↓","down"),("→","right"),("Space","space"),("E","e")]
        for (title,key) in directions {
            let b = button(title,nil,"input."+key) {}; b.removeTarget(nil,action:nil,for:.allEvents)
            b.addAction(UIAction { [weak self] _ in self?.heldKeys.insert(key) },for:.touchDown)
            b.addAction(UIAction { [weak self] _ in self?.heldKeys.remove(key) },for:[.touchUpInside,.touchUpOutside,.touchCancel]); transportButtons.append(b)
        }
        headerButtons.forEach { header.addSubview($0) }; transportButtons.forEach { transport.addSubview($0) }
        viewport.onSelect = { [weak self] id in self?.select(id) }
        viewport.onMove = { [weak self] id,x,y,z,phase in self?.move(id,x:x,y:y,z:z,phase:phase) }
        graph.onSelect = { [weak self] id in self?.nodeID = id; self?.graph.selectedNode = id; self?.buildPanel() }
        graph.onPosition = { [weak self] id,p,phase in self?.moveNode(id,point:p,phase:phase) }
        if let stored = try? GameProject.open(draftURL) { try? session.load(stored) }
        refresh(); viewport.fit()
    }
    override func viewDidDisappear(_ animated:Bool) { super.viewDidDisappear(animated); stopPlay(); heldKeys.removeAll() }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); let safe = view.safeAreaInsets, w = view.bounds.width, h = view.bounds.height-safe.top-safe.bottom
        titleLabel.frame = CGRect(x:12,y:safe.top+4,width:max(1,w-24),height:22)
        header.frame = CGRect(x:8,y:safe.top+29,width:w-16,height:44); layoutRow(headerButtons,in:header)
        transport.frame = CGRect(x:8,y:header.frame.maxY+5,width:w-16,height:44); layoutRow(transportButtons,in:transport)
        let top = transport.frame.maxY+8, bottom = safe.top+h-25, space = max(100,bottom-top)
        status.frame = CGRect(x:10,y:bottom+3,width:w-20,height:20)
        let landscape = w >= 740 && w > view.bounds.height
        let logic = tabs.selectedSegmentIndex == 3
        if landscape {
            let pw = min(320,max(270,w*0.29)), cw = max(160,w-pw-22)
            tabs.frame = CGRect(x:cw+14,y:top,width:pw,height:44); panel.frame = CGRect(x:cw+14,y:top+52,width:pw,height:max(80,space-52))
            viewport.frame = CGRect(x:8,y:top,width:cw,height:logic ? max(110,space*0.58-4) : space)
            graph.frame = CGRect(x:8,y:viewport.frame.maxY+8,width:cw,height:max(80,bottom-viewport.frame.maxY-8))
        } else {
            viewport.frame = CGRect(x:8,y:top,width:w-16,height:max(125,space*0.43))
            tabs.frame = CGRect(x:8,y:viewport.frame.maxY+8,width:w-16,height:44)
            let pt = tabs.frame.maxY+7
            if logic { graph.frame = CGRect(x:8,y:pt,width:w-16,height:max(95,(bottom-pt)*0.46)); panel.frame = CGRect(x:8,y:graph.frame.maxY+6,width:w-16,height:max(70,bottom-graph.frame.maxY-6)) }
            else { panel.frame = CGRect(x:8,y:pt,width:w-16,height:max(80,bottom-pt)) }
        }
        graph.isHidden = !logic; table.frame = panel.bounds; properties.frame = panel.bounds
        let width = max(80,properties.bounds.width-24); content.frame = CGRect(x:12,y:12,width:width,height:1)
        let fitted = content.systemLayoutSizeFitting(CGSize(width:width,height:UIView.layoutFittingCompressedSize.height),withHorizontalFittingPriority:.required,verticalFittingPriority:.fittingSizeLevel)
        content.frame.size.height = fitted.height; properties.contentSize = CGSize(width:properties.bounds.width,height:fitted.height+24)
    }
    private func layoutRow(_ buttons:[UIButton],in scroll:UIScrollView) { var x:CGFloat = 0; for b in buttons { let width = max(52,min(128,b.intrinsicContentSize.width+18)); b.frame = CGRect(x:x,y:0,width:width,height:44); x += width+6 }; scroll.contentSize = CGSize(width:x,height:44) }
    private func button(_ title:String,_ symbol:String?,_ id:String,_ action:@escaping()->Void) -> UIButton { let b = MobileTheme.button(title,symbol:symbol,action:action); b.accessibilityIdentifier = "game."+id; return b }
    func refreshAccess() { guard isViewLoaded else { return }; if !permitsEditing() { stopPlay() }; refresh() }
    private func refresh() {
        guard isViewLoaded else { return }; titleLabel.text = "Game Maker · \(session.project.dimension.rawValue)  /  \(session.project.name)"
        viewport.canEdit = editable; viewport.selectedID = session.selectedID; graph.canEdit = editable
        if let play { viewport.display(play) } else { viewport.setProject(session.project) }
        headerButtons.enumerated().forEach { i,b in b.isEnabled = i == 0 || editable }
        for (i,b) in transportButtons.enumerated() { b.isEnabled = i == 0 ? editable && session.canUndo : i == 1 ? editable && session.canRedo : i == 2 ? permitsEditing() && !busy : [3,4,5].contains(i) ? play != nil : i >= 10 ? play != nil && !paused : editable }
        transportButtons[2].setTitle(play == nil ? "Play" : "Stop",for:.normal); transportButtons[3].setTitle(paused ? "Resume" : "Pause",for:.normal)
        buildPanel(); table.reloadData(); view.setNeedsLayout()
    }
    private func edit(_ update:() throws -> Void) { guard editable else { return }; do { try update(); refresh(); saveDraft() } catch { report(error) } }
    func select(_ id:UUID?) { session.select(id); ruleIndex = 0; nodeID = nil; refresh() }
    func undo() { guard editable else { return }; session.undo(); refresh(); saveDraft() }
    func redo() { guard editable else { return }; session.redo(); refresh(); saveDraft() }
    func addObject(_ kind:GameObjectKind) { edit { guard kind != .model else { return }; var object = GameObject(name:kind.rawValue.capitalized,kind:kind); object.solid = kind == .block; try session.add(object) }; tabs.selectedSegmentIndex = 2; buildPanel() }
    private func addMenu() { choose("Add object",items:GameObjectKind.allCases.filter { $0 != .model }.map(\.rawValue)) { [weak self] value in if let kind = GameObjectKind(rawValue:value) { self?.addObject(kind) } } }
    func move(_ id:UUID,x:Double,y:Double,z:Double,phase:Int) {
        guard editable else { return }; session.select(id)
        if phase == 0 { session.beginTransaction(); return }
        do { try session.updateSelected { $0.x = GameEditorMath.position(x,grid:snapEnabled ? snap : 0); $0.y = GameEditorMath.position(y,grid:snapEnabled ? snap : 0); $0.z = GameEditorMath.position(z,grid:snapEnabled ? snap : 0) }
            if phase == -1 { session.endTransaction(cancel:true) } else if phase == 2 { session.endTransaction() }
            viewport.setProject(session.project); viewport.selectedID = id
            if phase == 2 || phase == -1 { refresh(); saveDraft() }
        } catch { session.endTransaction(cancel:true); report(error); refresh() }
    }
    private func moveNode(_ id:UUID,point:CGPoint,phase:Int) {
        guard editable,var rule = selectedRule else { return }
        if phase == 0 { session.beginTransaction(); return }
        var g = rule.graph ?? .chain(rule); g.positions.removeAll { $0.id == id }; g.positions.append(GameNodePosition(id:id,x:Double(point.x),y:Double(point.y))); rule.graph = g
        do { try session.setRule(rule,at:ruleIndex); graph.rule = rule
            if phase == 2 || phase == -1 { session.endTransaction(cancel:phase == -1); refresh(); saveDraft() }
        } catch { session.endTransaction(cancel:true); report(error) }
    }
    private func buildPanel() {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        let tab = tabs.selectedSegmentIndex; table.isHidden = tab > 1; properties.isHidden = tab <= 1
        guard tab > 1 else { view.setNeedsLayout(); return }
        if tab == 3 { buildLogic(); view.setNeedsLayout(); return }
        guard let object = session.selectedObject else { note("Select an object in the scene or Objects panel to edit its properties."); return }
        heading(object.name); command("Rename object") { [weak self] in self?.prompt("Object name",value:object.name) { value in self?.objectEdit { $0.name = value } } }
        for (label,key) in [("Position X",\GameObject.x),("Position Y",\GameObject.y),("Position Z",\GameObject.z),("Size",\GameObject.size),("Width",\GameObject.scaleX),("Height",\GameObject.scaleY),("Depth",\GameObject.scaleZ),("Rotation °",\GameObject.rotation),("Opacity 0–1",\GameObject.opacity)] { number(label,object[keyPath:key]) { [weak self] value in self?.objectEdit { $0[keyPath:key] = value } } }
        command(object.visible ? "Hide object" : "Show object") { [weak self] in self?.objectEdit { $0.visible.toggle() } }
        command(object.solid ? "Solid collision ✓" : "Solid collision off") { [weak self] in self?.objectEdit { $0.solid.toggle() } }
        command("Colour · "+(object.colour ?? "Default")) { [weak self] in self?.prompt("Colour (#RRGGBB)",value:object.colour ?? "#589fd8") { value in self?.objectEdit { $0.colour = value } } }
        command("Duplicate") { [weak self] in self?.edit { try self?.session.duplicate() } }
        command("Delete object") { [weak self] in self?.edit { try self?.session.deleteSelected() } }
        command("Move earlier in draw order") { [weak self] in self?.edit { try self?.session.reorder(-1) } }
        command("Move later in draw order") { [weak self] in self?.edit { try self?.session.reorder(1) } }
        if object.imageID != nil { buildSpriteSheet(object) }
        if object.modelID != nil { buildRig(object) }
        heading("Behaviours"); for recipe in GameBehaviourRecipe.allCases { command(recipe.rawValue) { [weak self] in self?.applyRecipe(recipe) } }
        note("Rules are connected native blocks. Add a movement behaviour, press Play and use the arrow buttons or a keyboard. Stop restores your unmodified scene. Collisions are axis-aligned boxes, not a rigid-body simulation.")
        content.arrangedSubviews.forEach { $0.isUserInteractionEnabled = editable }; view.setNeedsLayout()
    }
    private func buildSpriteSheet(_ object:GameObject) {
        heading("Sprite animation")
        guard let sheet = object.spriteSheet else { command("Set up sprite sheet") { [weak self] in self?.objectEdit { $0.spriteSheet = GameSpriteSheet() } }; return }
        for (label,value,key) in [("Columns",sheet.columns,\GameSpriteSheet.columns),("Rows",sheet.rows,\GameSpriteSheet.rows),("Frames",sheet.frames,\GameSpriteSheet.frames)] { number(label,Double(value)) { [weak self] value in self?.objectEdit { $0.spriteSheet?[keyPath:key] = Int(max(1,min(4096,value))) } } }
        number("Frames / second",sheet.fps) { [weak self] value in self?.objectEdit { $0.spriteSheet?.fps = value } }
        command("Add sprite animation behaviour") { [weak self] in self?.objectEdit { $0.rules.append(GameRule(event:.start,actions:[GameAction(kind:.spriteAnimation,value:1)])) } }
        command("Remove sprite animation") { [weak self] in self?.objectEdit { $0.spriteSheet = nil } }
    }
    private func buildRig(_ object:GameObject) {
        heading("Character rig")
        guard let rig = object.rig else { command("Create humanoid skeleton") { [weak self] in self?.objectEdit { $0.rig = .humanoid() } }; return }
        rigJoint = min(rigJoint,rig.joints.count-1)
        command("Joint · "+rig.joints[rigJoint].name) { [weak self] in self?.choose("Fit joint",items:rig.joints.map(\.name)) { name in self?.rigJoint = rig.joints.firstIndex { $0.name == name } ?? 0; self?.buildPanel() } }
        for (label,key) in [("Joint X",\GameRigJoint.x),("Joint Y",\GameRigJoint.y),("Joint Z",\GameRigJoint.z)] { number(label,rig.joints[rigJoint][keyPath:key]) { [weak self] value in guard let self else { return }; self.objectEdit { $0.rig?.joints[self.rigJoint][keyPath:key] = value } } }
        number("Walk cycles / second",rig.speed) { [weak self] value in self?.objectEdit { $0.rig?.speed = value } }
        number("Stride degrees",rig.stride) { [weak self] value in self?.objectEdit { $0.rig?.stride = value } }
        command("Add walking behaviour") { [weak self] in self?.objectEdit { $0.rules.append(GameRule(event:.start,actions:[GameAction(kind:.walk,value:1)])) } }
        command("Remove rig") { [weak self] in self?.objectEdit { $0.rig = nil } }
        note("Fit this T-pose humanoid skeleton to an upright model. The shared desktop engine binds weighted vertices. Imported animation clips are not retained.")
    }
    private func objectEdit(_ update:@escaping(inout GameObject)->Void) { edit { try session.updateSelected(update) } }
    private func applyRecipe(_ recipe:GameBehaviourRecipe) { guard let object = session.selectedObject else { return }; let other = session.project.objects.first { $0.id != object.id }?.id; let rules = recipe.rules(for:object,contact:other); if rules.isEmpty { report(GameProjectError.invalid("Add a second object to use as the contact target first.")); return }; objectEdit { $0.rules += rules }; tabs.selectedSegmentIndex = 3; buildPanel() }
    private func buildLogic() {
        guard let object = session.selectedObject else { graph.rule = nil; note("Select an object, then add an event and action blocks to build its behaviour."); return }
        heading("\(object.name) · Behaviours")
        command("+ Event rule") { [weak self] in self?.choose("Event",items:GameEvent.allCases.map(\.title)) { title in guard let event = GameEvent.allCases.first(where: { $0.title == title }) else { return }; self?.objectEdit { $0.rules.append(GameRule(event:event)) }; self?.ruleIndex = max(0,(self?.session.selectedObject?.rules.count ?? 1)-1); self?.nodeID = nil; self?.buildPanel() } }
        guard !object.rules.isEmpty else { graph.rule = nil; note("No behaviour yet. Add an event above, or pick a recipe in Properties."); return }
        ruleIndex = min(ruleIndex,object.rules.count-1); let rule = object.rules[ruleIndex]
        command("Rule \(ruleIndex+1) · "+rule.event.title) { [weak self] in self?.choose("Rules",items:object.rules.enumerated().map { "\($0.offset+1) · \($0.element.event.title)" }) { title in self?.ruleIndex = max(0,(Int(title.components(separatedBy:" · ")[0]) ?? 1)-1); self?.nodeID = nil; self?.buildPanel() } }
        graph.rule = rule; graph.selectedNode = nodeID
        command(rule.enabled ? "Rule enabled ✓" : "Rule disabled") { [weak self] in self?.ruleEdit { $0.enabled.toggle() } }
        command("+ Action / condition") { [weak self] in self?.choose("Block",items:GameActionKind.allCases.map(\.title)) { title in if let kind = GameActionKind.allCases.first(where: { $0.title == title }) { self?.edit { guard let self else { return }; try self.session.addAction(kind,rule:self.ruleIndex) }; self?.nodeID = self?.selectedRule?.actions.last?.id; self?.buildPanel() } } }
        command("Frame graph") { [weak self] in self?.graph.frameAll() }
        let node = nodeID ?? rule.id
        if node == rule.id {
            heading("Event settings")
            command(rule.event.title) { [weak self] in self?.choose("Event",items:GameEvent.allCases.map(\.title)) { title in self?.ruleEdit { $0.event = GameEvent.allCases.first { $0.title == title } ?? .update } } }
            command("Key · "+rule.key) { [weak self] in self?.choose("Keyboard key",items:["w","a","s","d","up","down","left","right","space","e"]) { key in self?.ruleEdit { $0.key = key } } }
            number("Interval seconds",rule.interval) { [weak self] value in self?.ruleEdit { $0.interval = value } }
            target("Touch target",selected:rule.otherID,includeSelf:false) { [weak self] id in self?.ruleEdit { $0.otherID = id } }
            connection("Then →",node:rule.id,port:.next,rule:rule)
        } else if let action = rule.actions.first(where: { $0.id == node }) {
            heading(action.kind.title)
            target("Target",selected:action.targetID,includeSelf:true) { [weak self] id in self?.actionEdit(action.id) { $0.targetID = id } }
            for (label,key) in [("X",\GameAction.x),("Y",\GameAction.y),("Z",\GameAction.z),("Value",\GameAction.value)] { number(label,action[keyPath:key]) { [weak self] value in self?.actionEdit(action.id) { $0[keyPath:key] = value } } }
            command("Text / variable · "+(action.text ?? "Default")) { [weak self] in self?.prompt("Key, variable or movement",value:action.text ?? "") { value in self?.actionEdit(action.id) { $0.text = value.isEmpty ? nil : value } } }
            if action.kind.isCondition { connection("Yes →",node:action.id,port:.yes,rule:rule); connection("No →",node:action.id,port:.no,rule:rule) }
            else { connection("Then →",node:action.id,port:.next,rule:rule) }
            command("Delete block") { [weak self] in self?.ruleEdit { r in r.actions.removeAll { $0.id == action.id }; r.graph?.wires.removeAll { $0.from == action.id || $0.to == action.id }; r.graph?.positions.removeAll { $0.id == action.id } }; self?.nodeID = nil; self?.buildPanel() }
        }
        command("Delete this rule") { [weak self] in guard let self else { return }; self.objectEdit { $0.rules.remove(at:self.ruleIndex) }; self.nodeID = nil; self.ruleIndex = 0; self.buildPanel() }
        note("Tap blocks to edit. Hold and drag blocks to arrange them; pinch to zoom. Use Then / Yes / No to connect blocks. Disconnected blocks do not run. Repeating events replace loops.")
        content.arrangedSubviews.forEach { $0.isUserInteractionEnabled = editable }
    }
    private func ruleEdit(_ update:(inout GameRule)->Void) { guard var rule = selectedRule else { return }; update(&rule); edit { try session.setRule(rule,at:ruleIndex) } }
    private func actionEdit(_ id:UUID,_ update:(inout GameAction)->Void) { ruleEdit { rule in if let i = rule.actions.firstIndex(where: { $0.id == id }) { update(&rule.actions[i]) } } }
    private func target(_ title:String,selected:UUID?,includeSelf:Bool,change:@escaping(UUID?)->Void) {
        let objects = session.project.objects.filter { includeSelf || $0.id != session.selectedID }
        command(title+" · "+(objects.first { $0.id == selected }?.name ?? (includeSelf ? "This object" : "None"))) { [weak self] in self?.choose(title,items:[includeSelf ? "This object" : "None"]+objects.enumerated().map { "\($0.offset+1) · \($0.element.name)" }) { choice in let i = (Int(choice.components(separatedBy:" · ")[0]) ?? 0)-1; change(objects.indices.contains(i) ? objects[i].id : nil) } }
    }
    private func connection(_ label:String,node:UUID,port:GamePort,rule:GameRule) {
        let choices = rule.actions.filter { $0.id != node }, target = (rule.graph ?? .chain(rule)).wires.first { $0.from == node && $0.port == port }?.to
        command(label+" "+(rule.actions.first { $0.id == target }?.kind.title ?? "Disconnected")) { [weak self] in self?.choose("Connect output",items:["Disconnect"]+choices.enumerated().map { "\($0.offset+1) · \($0.element.kind.title)" }) { title in guard let self else { return }; let i = (Int(title.components(separatedBy:" · ")[0]) ?? 0)-1; self.edit { try self.session.connect(rule:self.ruleIndex,from:node,port:port,to:choices.indices.contains(i) ? choices[i].id : nil) } } }
    }
    private func heading(_ title:String) { content.addArrangedSubview(MobileTheme.label(title,size:13,weight:.semibold)) }
    private func note(_ text:String) { let label = MobileTheme.label(text,size:11); label.numberOfLines = 0; label.textColor = MobileTheme.secondary; content.addArrangedSubview(label) }
    private func command(_ title:String,_ action:@escaping()->Void) { let b = button(title,nil,"command."+title,action); b.heightAnchor.constraint(equalToConstant:44).isActive = true; content.addArrangedSubview(b) }
    private func number(_ title:String,_ value:Double,_ change:@escaping(Double)->Void) { command(title+" · "+String(format:"%.3g",value)) { [weak self] in self?.prompt(title,value:String(value),numeric:true) { text in guard let n = Double(text),n.isFinite else { self?.report(GameProjectError.invalid("Enter a finite number.")); return }; change(n) } } }
    private func prompt(_ title:String,value:String,numeric:Bool = false,_ action:@escaping(String)->Void) {
        guard editable,presentedViewController == nil else { return }; let alert = UIAlertController(title:title,message:nil,preferredStyle:.alert)
        alert.addTextField { $0.text = value; $0.autocorrectionType = .no; $0.autocapitalizationType = .none; if numeric { $0.keyboardType = .numbersAndPunctuation } }
        alert.addAction(UIAlertAction(title:"Cancel",style:.cancel)); alert.addAction(UIAlertAction(title:"Apply",style:.default) { _ in action(alert.textFields?[0].text ?? "") }); present(alert,animated:true)
    }
    private func choose(_ title:String,items:[String],action:@escaping(String)->Void) {
        guard presentedViewController == nil else { return }; let alert = UIAlertController(title:title,message:nil,preferredStyle:.actionSheet)
        for item in items { alert.addAction(UIAlertAction(title:item,style:.default) { _ in action(item) }) }; alert.addAction(UIAlertAction(title:"Cancel",style:.cancel))
        alert.popoverPresentationController?.sourceView = panel; alert.popoverPresentationController?.sourceRect = CGRect(x:panel.bounds.midX,y:24,width:1,height:1); present(alert,animated:true)
    }
    private func report(_ error:Error) { status.text = error.localizedDescription; guard viewIfLoaded?.window != nil,presentedViewController == nil else { return }; let alert = UIAlertController(title:"Game Maker",message:error.localizedDescription,preferredStyle:.alert); alert.addAction(UIAlertAction(title:"OK",style:.default)); present(alert,animated:true) }
    func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { tabs.selectedSegmentIndex == 1 ? session.project.assets.count : session.project.objects.count }
    func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style:.subtitle,reuseIdentifier:nil); cell.backgroundColor = .clear; cell.textLabel?.font = .systemFont(ofSize:13); cell.textLabel?.textColor = .white; cell.detailTextLabel?.textColor = MobileTheme.secondary
        if tabs.selectedSegmentIndex == 1 { let asset = session.project.assets[indexPath.row]; cell.textLabel?.text = URL(fileURLWithPath:asset.path).lastPathComponent; cell.detailTextLabel?.text = ByteCountFormatter.string(fromByteCount:Int64(asset.data.count),countStyle:.file); cell.imageView?.image = UIImage(data:asset.data) ?? UIImage(systemName:"cube") }
        else {
            let object = session.project.objects[indexPath.row]
            cell.textLabel?.text = object.name; cell.detailTextLabel?.text = "\(object.kind.rawValue) · \(object.rules.count) rules"
            cell.imageView?.image = UIImage(systemName:object.visible ? "cube" : "eye.slash")
            // UITableView's standard checkmark inserts a private accessory
            // button with a small hit area. Supply a real 44-point control so
            // the visible selection affordance is as usable as the row itself.
            let selection = UIButton(type:.system); selection.frame = CGRect(x:0,y:0,width:44,height:44)
            selection.setImage(UIImage(systemName:object.id == session.selectedID ? "checkmark.circle.fill" : "circle"),for:.normal)
            selection.tintColor = object.id == session.selectedID ? .systemTeal : MobileTheme.secondary
            selection.accessibilityIdentifier = "game.object.select."+object.id.uuidString
            selection.accessibilityLabel = "Select "+object.name
            selection.isEnabled = editable
            selection.addAction(UIAction { [weak self] _ in
                guard let self,self.editable else { return }
                self.select(object.id); self.tabs.selectedSegmentIndex = 2; self.buildPanel()
            },for:.touchUpInside)
            cell.accessoryType = .none; cell.accessoryView = selection
        }
        return cell
    }
    func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath) { guard editable else { return }; if tabs.selectedSegmentIndex == 1 { assetMenu(session.project.assets[indexPath.row]) } else { select(session.project.objects[indexPath.row].id); tabs.selectedSegmentIndex = 2; buildPanel() } }
    private func assetMenu(_ asset:GameAsset) {
        let image = UIImage(data:asset.data) != nil, mesh = ["obj","nvmesh"].contains(URL(fileURLWithPath:asset.path).pathExtension.lowercased())
        guard image || mesh else { report(GameProjectError.invalid("This embedded source file is preserved in your project. Add its compiled .nvmesh asset or image to the scene.")); return }
        var items = ["Add to scene"]; if image,session.selectedID != nil { items.append("Assign as selected texture") }
        choose("Asset",items:items) { [weak self] choice in guard let self else { return }; if choice.contains("texture") { self.objectEdit { $0.imageID = asset.id } }
            else { self.edit { if mesh && self.session.project.dimension != .threeD { throw GameProjectError.invalid("Create a 3D game to place a model.") }; var object = GameObject(name:URL(fileURLWithPath:asset.path).deletingPathExtension().lastPathComponent,kind:image ? .sprite : .model); if image { object.imageID = asset.id } else { _ = try GameMesh.read(asset); object.modelID = asset.id }; try self.session.add(object) }; self.tabs.selectedSegmentIndex = 2; self.buildPanel() }
        }
    }
    func newDocument(_ dimension:GameDimension) {
        edit { try session.newDocument(dimension) }
        ruleIndex = 0; nodeID = nil; viewport.fit()
    }
    private var hasWorkToPreserve:Bool { !session.project.objects.isEmpty || !session.project.assets.isEmpty }
    private func newGame() {
        guard editable else { return }
        let choices:() -> Void = { [weak self] in
            self?.choose("New empty game",items:["2D","3D"]) { [weak self] dimension in self?.newDocument(dimension == "3D" ? .threeD : .twoD) }
        }
        if hasWorkToPreserve { confirmReplacement(opening:false,proceed:choices) } else { choices() }
    }
    private func confirmReplacement(opening:Bool,proceed:@escaping()->Void) {
        guard editable,presentedViewController == nil else { return }
        let message = opening
            ? "Opening another game replaces this working draft and clears Undo history. Save a copy to Files first if you want to keep this scene."
            : "A new game replaces this working draft. Your current scene, embedded assets and blocks remain recoverable with Undo while this workspace stays open. Save a copy to Files to keep it permanently."
        let alert = UIAlertController(title:opening ? "Open another game?" : "Start a new game?",message:message,preferredStyle:.alert)
        weak var warning = alert
        alert.addAction(UIAlertAction(title:"Cancel",style:.cancel))
        func afterDismissal(_ action:@escaping()->Void) {
            warning?.dismiss(animated:true) { [weak self] in
                guard let self,self.editable,self.viewIfLoaded?.window != nil else { return }; action()
            }
        }
        alert.addAction(UIAlertAction(title:"Save current copy first…",style:.default) { [weak self] _ in afterDismissal { self?.saveCopy() } })
        alert.addAction(UIAlertAction(title:opening ? "Open another game…" : "Choose new game…",style:.default) { _ in afterDismissal(proceed) })
        present(alert,animated:true)
    }
    func togglePlay() {
        guard permitsEditing(),!busy else { return }; if play != nil { stopPlay(); return }
        session.endTransaction(); play = GamePlayState(objects:session.project.objects,dimension:session.project.dimension); play?.step(keys:[],seconds:0); paused = false; lastTick = 0
        let display = CADisplayLink(target:self,selector:#selector(tick(_:))); display.preferredFramesPerSecond = 60; display.add(to:.main,forMode:.common); timer = display; refresh(); becomeFirstResponder()
    }
    func stopPlay() { timer?.invalidate(); timer = nil; play = nil; paused = false; heldKeys.removeAll(); if isViewLoaded { refresh() } }
    func togglePause() { guard play != nil else { return }; paused.toggle(); heldKeys.removeAll(); lastTick = 0; refresh() }
    func stepFrame() { guard play != nil else { return }; paused = true; advance(seconds:1/60); refresh() }
    func restartPlay() { guard play != nil else { return }; play = GamePlayState(objects:session.project.objects,dimension:session.project.dimension); play?.step(keys:[],seconds:0); lastTick = 0; refresh() }
    @objc private func tick(_ display:CADisplayLink) { let dt = lastTick == 0 ? 0 : display.timestamp-lastTick; lastTick = display.timestamp; if !paused { advance(seconds:dt) } }
    func advance(seconds:Double,keys:Set<String>? = nil) { guard permitsEditing(),play != nil else { return }; play?.step(keys:keys ?? heldKeys,seconds:seconds); if let play { viewport.display(play); status.text = "Play · \(String(format:"%.1f",play.elapsed)) s · Score \(String(format:"%.3g",play.score)) · \(play.variables.count) variables" } }
    override var canBecomeFirstResponder:Bool { true }
    private func gameKey(_ key:UIKey) -> String? { switch key.keyCode { case .keyboardUpArrow:return "up"; case .keyboardDownArrow:return "down"; case .keyboardLeftArrow:return "left"; case .keyboardRightArrow:return "right"; case .keyboardSpacebar:return "space"; default:let c = key.charactersIgnoringModifiers.lowercased(); return ["w","a","s","d","e"].contains(c) ? c : nil } }
    override func pressesBegan(_ presses:Set<UIPress>,with event:UIPressesEvent?) { guard play != nil else { super.pressesBegan(presses,with:event); return }; for press in presses { if let key = press.key.flatMap(gameKey) { heldKeys.insert(key) } } }
    override func pressesEnded(_ presses:Set<UIPress>,with event:UIPressesEvent?) { for press in presses { if let key = press.key.flatMap(gameKey) { heldKeys.remove(key) } }; super.pressesEnded(presses,with:event) }
    override func pressesCancelled(_ presses:Set<UIPress>,with event:UIPressesEvent?) { heldKeys.removeAll(); super.pressesCancelled(presses,with:event) }
    private func returnHome() { fileGeneration &+= 1; busy = false; cleanExport(); stopPlay(); session.endTransaction(); saveDraft(); onHome?() }
    private func saveDraft() {
        draftTask?.cancel(); let project = session.project, revision = session.revision, destination = draftURL
        let task = DispatchWorkItem { [weak self] in do { try project.save(to:destination); DispatchQueue.main.async { if self?.session.revision == revision { self?.savedRevision = revision } } } catch { DispatchQueue.main.async { self?.status.text = "Draft was not saved: \(error.localizedDescription)" } } }; draftTask = task; files.asyncAfter(deadline:.now()+0.5,execute:task)
    }
    func openProject(url:URL) throws {
        guard permitsEditing(),!busy else { throw GameProjectError.invalid("Sign in and finish any current file operation before opening a game.") }
        loadViewIfNeeded()
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let project = try GameProject.open(url); stopPlay(); try session.load(project); refresh(); viewport.fit(); saveDraft()
    }
    private func pick(_ mode:String) {
        guard editable else { return }
        if mode == "open",hasWorkToPreserve { confirmReplacement(opening:true) { [weak self] in self?.showPicker(mode) }; return }
        showPicker(mode)
    }
    private func showPicker(_ mode:String) {
        guard editable,presentedViewController == nil else { return }; pickerMode = mode
        let types:[UTType] = mode == "open" ? [UTType(filenameExtension:"netvistagame") ?? .json] : [.image,.folder,.data]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes:types,asCopy:false); picker.allowsMultipleSelection = mode == "assets"; picker.delegate = self; present(picker,animated:true)
    }
    func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
        if pickerMode == "export" { cleanExport(); status.text = "Saved to Files."; return }
        guard permitsEditing(),let first = urls.first else { return }
        if pickerMode == "open" { do { try openProject(url:first) } catch { report(error) }; return }
        guard urls.count <= 32 else { report(GameProjectError.invalid("Import up to 32 files or asset folders at once.")); return }
        fileGeneration &+= 1; let generation = fileGeneration
        let original = session.project, revision = session.revision; busy = true; refresh()
        files.async { [weak self] in
            let access = urls.map { $0.startAccessingSecurityScopedResource() }; defer { for (i,url) in urls.enumerated() where access[i] { url.stopAccessingSecurityScopedResource() } }
            let result = Result { () -> GameProject in
                var candidate = original
                let modelURLs = urls.filter { GameModelImporter.extensions.contains($0.pathExtension.lowercased()) }
                if !modelURLs.isEmpty { candidate = try GameModelImporter.importModels(modelURLs,into:candidate) }
                let other = urls.filter { !modelURLs.contains($0) }; if !other.isEmpty { candidate = try GameModelImporter.importModels(other,into:candidate) }
                return candidate
            }
            DispatchQueue.main.async { guard let self,self.fileGeneration == generation else { return }; self.busy = false
                guard self.viewIfLoaded?.window != nil else { self.status.text = "Import cancelled because the workspace closed."; return }
                do { let candidate = try result.get(); guard self.permitsEditing(),self.session.revision == revision else { throw GameProjectError.invalid("The document or account changed during import. Import again into the current scene.") }; try self.session.edit { $0 = candidate }; self.tabs.selectedSegmentIndex = 1; self.refresh(); self.saveDraft(); self.status.text = "Assets embedded. Tap an asset to place it in the scene." } catch { self.refresh(); self.report(error) }
            }
        }
    }
    func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController) { cleanExport(); status.text = "Cancelled · your game is unchanged." }
    private func saveCopy() { exportFile(target:nil) }
    private func exportMenu() { choose("Export source project",items:[GameExportTarget.threeJS.rawValue,GameExportTarget.python.rawValue]) { [weak self] target in self?.exportFile(target:target == GameExportTarget.threeJS.rawValue ? .threeJS : .python) } }
    private func exportFile(target:GameExportTarget?) {
        guard editable else { return }; fileGeneration &+= 1; let generation = fileGeneration
        let project = session.project; busy = true; refresh()
        files.async { [weak self] in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NetVista-game-"+UUID().uuidString,isDirectory:true)
            let result = Result { () -> URL in
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                let name = project.name.components(separatedBy:CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator:"-").prefix(80)
                let destination = root.appendingPathComponent(String(name.isEmpty ? "NetVista-game" : name)+(target == nil ? ".netvistagame" : ""))
                if let target { try GameExporter.export(project,to:destination,target:target) } else { try project.save(to:destination) }; return destination
            }
            DispatchQueue.main.async { guard let self,self.fileGeneration == generation else { try? FileManager.default.removeItem(at:root); return }; self.busy = false; self.refresh()
                guard self.viewIfLoaded?.window != nil else { try? FileManager.default.removeItem(at:root); self.status.text = "Export cancelled because the workspace closed."; return }
                do { let url = try result.get(); guard self.permitsEditing(),self.presentedViewController == nil else { throw GameProjectError.invalid("Finish the open dialog, then save again.") }; self.pendingExport = root; self.pickerMode = "export"; let picker = UIDocumentPickerViewController(forExporting:[url],asCopy:true); picker.delegate = self; self.present(picker,animated:true) } catch { try? FileManager.default.removeItem(at:root); self.report(error) }
            }
        }
    }
    private func cleanExport() { if let url = pendingExport { try? FileManager.default.removeItem(at:url) }; pendingExport = nil }
}
