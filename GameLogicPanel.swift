import Cocoa

final class GameButton: NSButton {
    var invoke: (() -> Void)?
    init(_ title: String, _ action: @escaping () -> Void) {
        super.init(frame: .zero); self.title = title; bezelStyle = .rounded; target = self; self.action = #selector(run); invoke = action
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func run() { invoke?() }
}
final class GamePopup: NSPopUpButton {
    var picked: ((Int) -> Void)?
    init(_ titles: [String], selected: Int = 0, _ action: @escaping (Int) -> Void) {
        super.init(frame: .zero, pullsDown: false); addItems(withTitles: titles); selectItem(at: selected); target = self; self.action = #selector(run); picked = action
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func run() { picked?(indexOfSelectedItem) }
}
final class GameNumber: NSTextField, NSTextFieldDelegate {
    var accepted: ((Double) -> Void)?
    var range: ClosedRange<Double> = -10000...10000
    private var last: Double
    init(_ value: Double, width: CGFloat = 66, range: ClosedRange<Double> = -10000...10000, _ action: @escaping (Double) -> Void) {
        last = value; self.range = range; accepted = action
        super.init(frame: .zero); stringValue = String(format: "%.3g",value); delegate = self
        font = .monospacedDigitSystemFont(ofSize: 12,weight: .regular); alignment = .right
        widthAnchor.constraint(equalToConstant: width).isActive = true; toolTip = "Enter a number from \(range.lowerBound) to \(range.upperBound)."
    }
    required init?(coder: NSCoder) { fatalError() }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let value = Double(stringValue), value.isFinite, range.contains(value) else { stringValue = String(format: "%.3g",last); NSSound.beep(); return }
        if value != last { last = value; accepted?(value) }
    }
}
func gameLabel(_ value: String, strong: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: value); label.font = .systemFont(ofSize: strong ? 12 : 11,weight: strong ? .semibold : .regular)
    label.textColor = strong ? .labelColor : .secondaryLabelColor; return label
}
func gameRow(_ views: [NSView]) -> NSStackView { let row = NSStackView(views: views); row.spacing = 6; row.alignment = .centerY; return row }
private final class GameFlipped: NSView { override var isFlipped: Bool { true } }
final class GameScroll: NSScrollView {
    let stack = NSStackView()
    init() {
        super.init(frame: .zero); hasVerticalScroller = true; drawsBackground = false
        let document = GameFlipped(); documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; document.addSubview(stack)
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: contentView.widthAnchor),stack.leadingAnchor.constraint(equalTo: document.leadingAnchor,constant:12),stack.trailingAnchor.constraint(equalTo: document.trailingAnchor,constant:-12),stack.topAnchor.constraint(equalTo: document.topAnchor,constant:12),stack.bottomAnchor.constraint(equalTo: document.bottomAnchor,constant:-12)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func clear() { stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() } }
    func add(_ child: NSView, fill: Bool = false) { stack.addArrangedSubview(child); if fill { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true } }
}

/// Per-object event graphs. Wires, rather than visual ordering, determine execution.
final class GameLogicPanel: NSView {
    var changed: (([GameRule]) -> Void)?
    private var rules: [GameRule] = [], objects: [GameObject] = []
    private var owner: UUID?, active = 0
    private var dimension = GameDimension.twoD
    private let header = NSStackView(), canvas = GameGraphCanvas(), scroll = NSScrollView()
    private let hint = gameLabel("Drag an output dot to an input dot. Double-click a node to edit. Option-click an input to disconnect.")
    private var popover: NSPopover?
    override init(frame: NSRect) {
        super.init(frame: frame)
        header.spacing = 6; header.alignment = .centerY
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.documentView = canvas
        scroll.allowsMagnification = true; scroll.minMagnification = 0.25; scroll.maxMagnification = 2
        canvas.frame = NSRect(x:0,y:0,width:2000,height:1200)
        for v in [header,scroll,hint] { addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo:leadingAnchor,constant:8),header.topAnchor.constraint(equalTo:topAnchor,constant:6),header.trailingAnchor.constraint(lessThanOrEqualTo:trailingAnchor,constant:-8),header.heightAnchor.constraint(equalToConstant:28),scroll.leadingAnchor.constraint(equalTo:leadingAnchor),scroll.trailingAnchor.constraint(equalTo:trailingAnchor),scroll.topAnchor.constraint(equalTo:header.bottomAnchor,constant:6),scroll.bottomAnchor.constraint(equalTo:hint.topAnchor,constant:-4),hint.leadingAnchor.constraint(equalTo:leadingAnchor,constant:8),hint.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-8),hint.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-4)])
        canvas.modified = { [weak self] graph in
            guard let self, self.rules.indices.contains(self.active) else { return }
            do { try graph.validate(rule:self.rules[self.active]); self.rules[self.active].graph = graph; self.commit() }
            catch { self.hint.stringValue = error.localizedDescription; self.renderCanvas() }
        }
        canvas.edit = { [weak self] id in self?.editNode(id) }
        canvas.deleteSelection = { [weak self] in self?.removeSelected() }
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(object: GameObject?, objects: [GameObject], dimension: GameDimension) {
        if owner != object?.id { viewCommitAndClose(); active = 0; canvas.selection = nil; scroll.contentView.scroll(to:.zero) }
        owner = object?.id; rules = object?.rules ?? []; self.objects = objects; self.dimension = dimension; render()
    }
    func setEditing(_ enabled: Bool) { isHidden = !enabled; if !enabled { popover?.close() } }
    private func commit() { changed?(rules); render() }
    private func render() {
        header.arrangedSubviews.forEach { header.removeArrangedSubview($0); $0.removeFromSuperview() }
        guard owner != nil else { header.addArrangedSubview(gameLabel("Select an object to build its node graph",strong:true)); canvas.rule = nil; return }
        let addEvent = GameButton("+ Event") { [weak self] in guard let self, self.rules.count < 64 else { return }; var rule = GameRule(); rule.graph = .chain(rule); self.rules.append(rule); self.active = self.rules.count-1; self.commit() }
        header.addArrangedSubview(addEvent)
        if !rules.isEmpty {
            active = min(active,rules.count-1)
            let picker = GamePopup(rules.enumerated().map { "\($0.offset+1). \($0.element.event.title)" },selected:active) { [weak self] index in self?.viewCommitAndClose(); self?.active = index; self?.canvas.selection = nil; self?.render() }
            picker.widthAnchor.constraint(equalToConstant:155).isActive = true; header.addArrangedSubview(picker)
            header.addArrangedSubview(GameButton("+ Node") { [weak self] in self?.addNodeMenu() })
            header.addArrangedSubview(GameButton("Edit") { [weak self] in guard let self else { return }; self.editNode(self.canvas.selection ?? self.rules[self.active].id) })
            header.addArrangedSubview(GameButton("Delete") { [weak self] in self?.removeSelected() })
            header.addArrangedSubview(GameButton("Fit") { [weak self] in self?.fitGraph() })
        }
        renderCanvas()
    }
    private func renderCanvas() {
        canvas.rule = rules.indices.contains(active) ? rules[active] : nil
        if let rule = canvas.rule {
            let positions = (rule.graph ?? .chain(rule)).positions
            canvas.setFrameSize(NSSize(width:max(1600,(positions.map(\.x).max() ?? 0)+500),height:max(900,(positions.map(\.y).max() ?? 0)+300)))
        }
    }
    private func fitGraph() {
        guard let rule = canvas.rule else { return }
        let rects = ([rule.id]+rule.actions.map(\.id)).map { canvas.nodeRect($0) }
        guard let first = rects.first else { return }
        let area = rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx:-20,dy:-20)
        let scale = min(scroll.bounds.width/area.width,scroll.bounds.height/area.height)
        scroll.magnification = max(0.25,min(1,scale))
        scroll.contentView.scroll(to:NSPoint(x:max(0,area.minX),y:max(0,area.minY))); scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func addNodeMenu() {
        let menu = NSMenu()
        for (i,kind) in GameActionKind.allCases.enumerated() { let item = NSMenuItem(title:kind.title,action:#selector(addNode(_:)),keyEquivalent:""); item.target = self; item.tag = i; menu.addItem(item) }
        menu.popUp(positioning:nil,at:NSPoint(x:240,y:bounds.height-35),in:self)
    }
    @objc private func addNode(_ item: NSMenuItem) {
        guard rules.indices.contains(active), rules[active].actions.count < 64 else { return }
        let kind = GameActionKind.allCases[item.tag]
        let action = GameAction(kind:kind,value:kind == .keyboard ? 4 : 1,text:kind == .ifKey ? "space" : "health")
        var graph = rules[active].graph ?? .chain(rules[active])
        let origin = scroll.contentView.bounds.origin
        graph.positions.append(GameNodePosition(id:action.id,x:max(280,Double(origin.x)+300),y:max(40,Double(origin.y)+60+Double(rules[active].actions.count % 4)*130)))
        rules[active].actions.append(action); rules[active].graph = graph; canvas.selection = action.id; commit()
        hint.stringValue = "New node added. Drag a wire to its left input to make it run."
    }
    private func removeSelected() {
        viewCommitAndClose()
        guard rules.indices.contains(active), let id = canvas.selection else { return }
        if id == rules[active].id { rules.remove(at:active); active = max(0,active-1) }
        else {
            var graph = rules[active].graph ?? .chain(rules[active]); graph.wires.removeAll { $0.from == id || $0.to == id }; graph.positions.removeAll { $0.id == id }
            rules[active].actions.removeAll { $0.id == id }; rules[active].graph = graph
        }
        canvas.selection = nil; commit()
    }
    private func target(_ id: UUID?, caption: String, change: @escaping (UUID?) -> Void) -> NSView {
        let ids: [UUID?] = [nil] + objects.map { Optional($0.id) }
        let picker = GamePopup([caption]+objects.map(\.name),selected:ids.firstIndex(of:id) ?? 0) { change(ids[$0]) }; picker.widthAnchor.constraint(equalToConstant:220).isActive = true; return picker
    }
    private func editNode(_ id: UUID) {
        guard rules.indices.contains(active) else { return }
        let editingOwner = owner, editingRuleID = rules[active].id
        popover?.close(); canvas.selection = id; canvas.needsDisplay = true
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        if id == rules[active].id {
            stack.addArrangedSubview(gameLabel("EVENT",strong:true))
            stack.addArrangedSubview(GamePopup(GameEvent.allCases.map(\.title),selected:GameEvent.allCases.firstIndex(of:rules[active].event) ?? 0) { [weak self] i in guard let self, self.owner == editingOwner, self.rules.indices.contains(self.active), self.rules[self.active].id == editingRuleID else { return }; self.rules[self.active].event = GameEvent.allCases[i]; self.commit(); self.editNode(id) })
            let enabled = GameButton(rules[active].enabled ? "Enabled ✓" : "Disabled") { [weak self] in guard let self, self.owner == editingOwner, self.rules.indices.contains(self.active), self.rules[self.active].id == editingRuleID else { return }; self.rules[self.active].enabled.toggle(); self.commit(); self.editNode(id) }; stack.addArrangedSubview(enabled)
            if [.keyHeld,.keyPressed].contains(rules[active].event) {
                let keys = ["space","w","a","s","d","up","down","left","right","e"]
                stack.addArrangedSubview(GamePopup(keys,selected:keys.firstIndex(of:rules[active].key) ?? 0) { [weak self] i in guard let self, self.owner == editingOwner, self.rules.indices.contains(self.active), self.rules[self.active].id == editingRuleID else { return }; self.rules[self.active].key = keys[i]; self.commit() })
            }
            if rules[active].event == .timer { stack.addArrangedSubview(gameRow([gameLabel("Seconds"),GameNumber(rules[active].interval,range:0.02...3600) { [weak self] value in guard let self, self.owner == editingOwner, self.rules.indices.contains(self.active), self.rules[self.active].id == editingRuleID else { return }; self.rules[self.active].interval = value; self.commit() }])) }
            if rules[active].event == .touch { stack.addArrangedSubview(target(rules[active].otherID,caption:"Choose contact…") { [weak self] target in guard let self, self.owner == editingOwner, self.rules.indices.contains(self.active), self.rules[self.active].id == editingRuleID else { return }; self.rules[self.active].otherID = target; self.commit() }) }
        } else if let index = rules[active].actions.firstIndex(where: { $0.id == id }) {
            let action = rules[active].actions[index]
            stack.addArrangedSubview(gameLabel(action.kind.title,strong:true))
            stack.addArrangedSubview(target(action.targetID,caption:action.kind == .ifTouch ? "Choose contact…" : "This object") { [weak self] target in guard let self, self.owner == editingOwner, self.rules.indices.contains(self.active), self.rules[self.active].id == editingRuleID, self.rules[self.active].actions.indices.contains(index), self.rules[self.active].actions[index].id == id else { return }; self.rules[self.active].actions[index].targetID = target; self.commit() })
            if [.move,.position].contains(action.kind) {
                for (name,key) in [("X",\GameAction.x),("Y",\GameAction.y),("Z",\GameAction.z)] where dimension == .threeD || name != "Z" {
                    stack.addArrangedSubview(gameRow([gameLabel(name),GameNumber(action[keyPath:key]) { [weak self] value in guard let self, self.owner == editingOwner, self.rules.indices.contains(self.active), self.rules[self.active].id == editingRuleID, self.rules[self.active].actions.indices.contains(index), self.rules[self.active].actions[index].id == id else { return }; self.rules[self.active].actions[index][keyPath:key] = value; self.commit() }]))
                }
            } else if ![.show,.hide,.destroy,.ifKey,.ifTouch,.stopAnimation].contains(action.kind) {
                let caption = [.walk,.spriteAnimation].contains(action.kind) ? "Speed multiplier" : "Value"
                stack.addArrangedSubview(gameRow([gameLabel(caption),GameNumber(action.value) { [weak self] value in guard let self, self.owner == editingOwner, self.rules.indices.contains(self.active), self.rules[self.active].id == editingRuleID, self.rules[self.active].actions.indices.contains(index), self.rules[self.active].actions[index].id == id else { return }; self.rules[self.active].actions[index].value = value; self.commit() }]))
            }
            if action.kind == .ifKey {
                let keys = ["movement","space","w","a","s","d","up","down","left","right","e"]
                stack.addArrangedSubview(GamePopup(keys,selected:keys.firstIndex(of:action.text ?? "space") ?? 0) { [weak self] i in guard let self, self.owner == editingOwner, self.rules.indices.contains(self.active), self.rules[self.active].id == editingRuleID, self.rules[self.active].actions.indices.contains(index), self.rules[self.active].actions[index].id == id else { return }; self.rules[self.active].actions[index].text = keys[i]; self.commit() })
            }
            if [.setVariable,.addVariable,.ifVariable].contains(action.kind) {
                let field = GameText(action.text ?? "health") { [weak self] text in guard let self, self.owner == editingOwner, self.rules.indices.contains(self.active), self.rules[self.active].id == editingRuleID, self.rules[self.active].actions.indices.contains(index), self.rules[self.active].actions[index].id == id else { return }; self.rules[self.active].actions[index].text = text; self.commit() }; stack.addArrangedSubview(gameRow([gameLabel("Variable"),field]))
            }
            if action.kind.isCondition { stack.addArrangedSubview(gameLabel("Green output = Yes. Red output = No.")) }
        }
        stack.addArrangedSubview(GameButton("Done") { [weak self] in self?.viewCommitAndClose() })
        let controller = NSViewController(); controller.view = NSView(); controller.view.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:controller.view.leadingAnchor,constant:14),stack.trailingAnchor.constraint(equalTo:controller.view.trailingAnchor,constant:-14),stack.topAnchor.constraint(equalTo:controller.view.topAnchor,constant:14),stack.bottomAnchor.constraint(equalTo:controller.view.bottomAnchor,constant:-14)])
        controller.preferredContentSize = NSSize(width:310,height:stack.fittingSize.height+28)
        let pop = NSPopover(); pop.contentViewController = controller; pop.behavior = .semitransient; popover = pop
        let rect = canvas.nodeRect(id); pop.show(relativeTo:rect,of:canvas,preferredEdge:.maxY)
    }
    private func viewCommitAndClose() { window?.makeFirstResponder(nil); popover?.contentViewController?.view.window?.makeFirstResponder(nil); popover?.close() }
}
final class GameText: NSTextField, NSTextFieldDelegate {
    var accepted: (String) -> Void
    init(_ text: String, change: @escaping (String) -> Void) { accepted = change; super.init(frame:.zero); stringValue = text; delegate = self; widthAnchor.constraint(equalToConstant:180).isActive = true }
    required init?(coder:NSCoder) { fatalError() }
    func controlTextDidEndEditing(_ obj:Notification) { accepted(String(stringValue.prefix(128))) }
}

final class GameGraphCanvas: NSView {
    var rule: GameRule? { didSet { needsDisplay = true } }
    var selection: UUID? { didSet { needsDisplay = true } }
    var modified: ((GameGraph) -> Void)?, edit: ((UUID) -> Void)?, deleteSelection: (() -> Void)?
    private var moving: UUID?, offset = NSPoint.zero, draft: GameGraph?
    private var wiring: (UUID,GamePort)?, pointer = NSPoint.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var graph: GameGraph {
        if let draft { return draft }
        guard let rule else { return GameGraph() }
        var graph = rule.graph ?? .chain(rule)
        let defaults = GameGraph.chain(rule).positions
        for position in defaults where !graph.positions.contains(where: { $0.id == position.id }) { graph.positions.append(position) }
        return graph
    }
    func nodeRect(_ id: UUID) -> NSRect {
        let p = graph.positions.first { $0.id == id } ?? GameNodePosition(id:id,x:40,y:50)
        return NSRect(x:p.x,y:p.y,width:210,height:94)
    }
    private var ids: [UUID] { rule.map { [$0.id]+$0.actions.map(\.id) } ?? [] }
    private func ports(_ id: UUID) -> [GamePort] { rule?.actions.first(where: { $0.id == id })?.kind.isCondition == true ? [.yes,.no] : [.next] }
    private func socket(_ id: UUID, _ port: GamePort?) -> NSPoint {
        let rect = nodeRect(id); return NSPoint(x:port == nil ? rect.minX : rect.maxX,y:rect.minY+(port == .yes ? 42 : port == .no ? 75 : 55))
    }
    private func wire(_ a: NSPoint,_ b: NSPoint,_ colour: NSColor) {
        let path = NSBezierPath(); path.move(to:a); let d = max(60,abs(b.x-a.x)*0.45)
        path.curve(to:b,controlPoint1:NSPoint(x:a.x+d,y:a.y),controlPoint2:NSPoint(x:b.x-d,y:b.y)); colour.setStroke(); path.lineWidth = 2.5; path.stroke()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite:0.095,alpha:1).setFill(); dirtyRect.fill()
        NSColor(calibratedWhite:0.19,alpha:1).setFill()
        for x in stride(from:Int(dirtyRect.minX)/24*24,through:Int(dirtyRect.maxX),by:24) { for y in stride(from:Int(dirtyRect.minY)/24*24,through:Int(dirtyRect.maxY),by:24) { NSRect(x:x,y:y,width:1,height:1).fill() } }
        for w in graph.wires { wire(socket(w.from,w.port),socket(w.to,nil),w.port == .no ? .systemRed : w.port == .yes ? .systemGreen : .systemTeal) }
        if let wiring { wire(socket(wiring.0,wiring.1),pointer,.white) }
        for id in ids {
            let rect = nodeRect(id), action = rule?.actions.first { $0.id == id }, event = id == rule?.id
            let colour: NSColor = event ? .systemOrange : action?.kind.isCondition == true ? .systemPurple : .systemBlue
            let path = NSBezierPath(roundedRect:rect,xRadius:8,yRadius:8); NSColor(calibratedWhite:0.16,alpha:1).setFill(); path.fill(); (id == selection ? NSColor.white : colour.withAlphaComponent(0.7)).setStroke(); path.lineWidth = id == selection ? 2 : 1; path.stroke()
            let title = event ? rule!.event.title : action!.kind.title
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in:NSRect(x:rect.minX+14,y:rect.minY+12,width:182,height:20),withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:colour,.paragraphStyle:paragraph])
            let detail = event ? (rule!.enabled ? "Event · double-click to edit" : "Disabled") : action!.kind.isCondition ? "Branch  →  Yes / No" : "Action · double-click to edit"
            (detail as NSString).draw(at:NSPoint(x:rect.minX+14,y:rect.minY+43),withAttributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor(calibratedWhite:0.72,alpha:1)])
            if !event { dot(socket(id,nil),.systemTeal) }
            for port in ports(id) { dot(socket(id,port),port == .no ? .systemRed : port == .yes ? .systemGreen : colour) }
        }
    }
    private func dot(_ p:NSPoint,_ colour:NSColor) { colour.setFill(); NSBezierPath(ovalIn:NSRect(x:p.x-6,y:p.y-6,width:12,height:12)).fill() }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self); let p = convert(event.locationInWindow,from:nil); pointer = p
        for id in ids {
            for port in ports(id) where hypot(p.x-socket(id,port).x,p.y-socket(id,port).y) < 12 { wiring = (id,port); return }
            if id != rule?.id, event.modifierFlags.contains(.option), hypot(p.x-socket(id,nil).x,p.y-socket(id,nil).y) < 12 {
                var g = graph; g.wires.removeAll { $0.to == id }; modified?(g); return
            }
        }
        selection = ids.reversed().first { nodeRect($0).contains(p) }
        if let id = selection {
            if event.clickCount == 2 { edit?(id); return }
            moving = id; offset = NSPoint(x:p.x-nodeRect(id).minX,y:p.y-nodeRect(id).minY); draft = graph
        }
    }
    override func mouseDragged(with event:NSEvent) {
        pointer = convert(event.locationInWindow,from:nil)
        if let moving, let index = draft?.positions.firstIndex(where: { $0.id == moving }) {
            draft?.positions[index].x = Double(max(12,min(10000,pointer.x-offset.x))); draft?.positions[index].y = Double(max(12,min(10000,pointer.y-offset.y)))
        }
        autoscroll(with:event); needsDisplay = true
    }
    override func mouseUp(with event:NSEvent) {
        if let wiring {
            let p = convert(event.locationInWindow,from:nil)
            if let target = ids.first(where: { $0 != rule?.id && hypot(p.x-socket($0,nil).x,p.y-socket($0,nil).y) < 16 }) {
                var g = graph; g.wires.append(GameWire(from:wiring.0,port:wiring.1,to:target)); modified?(g)
            }
        } else if let draft { modified?(draft) }
        wiring = nil; moving = nil; draft = nil; needsDisplay = true
    }
    override func keyDown(with event:NSEvent) { if [51,117].contains(event.keyCode) { deleteSelection?() } else { super.keyDown(with:event) } }
}
