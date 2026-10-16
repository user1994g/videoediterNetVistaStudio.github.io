import UIKit
import SceneKit
import UniformTypeIdentifiers
import simd

/// Touch/pointer workspace for the same editable indexed meshes and project
/// schema as the Mac 3D Editor. SceneKit displays geometry, not a remote stream.
@MainActor final class ModelingWorkspaceViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate, UIColorPickerViewControllerDelegate {
    var permitsEditing: () -> Bool = { false }
    var onHome: (() -> Void)?
    private(set) var document: ModelingDocument
    private(set) var selectedID: UUID?
    private(set) var selectedFaces = Set<Int>(), selectedVertex: Int?
    private(set) var mode = 0
    private(set) var undoSteps: [ModelingDocument] = [], redoSteps: [ModelingDocument] = []
    let viewport = ModelingWorkspaceViewport(frame: .zero)
    private let documentLabel = MobileTheme.label("3D Editor · NetVista Studio", size: 13, weight: .semibold)
    private let header = UIScrollView(), tools = UIScrollView(), panel = UIView(), inspector = UIScrollView(), propertyStack = UIStackView()
    private let table = UITableView(frame: .zero, style: .plain)
    private let tabs = UISegmentedControl(items: ["Objects", "Properties"])
    private let status = MobileTheme.label("Add a mesh to start modeling.", size: 11)
    private let modePicker = UISegmentedControl(items: ["Object", "Face", "Vertex", "Sculpt"])
    private let lockedLabel = MobileTheme.label("Sign in from Studio Home to edit.", size: 14)
    private var headerButtons: [UIButton] = [], toolButtons: [UIButton] = []
    private var panelVisible = false, wireframe = false, snap = false, multiSelect = false
    private(set) var brush = ModelingBrush.draw
    private var brushRadius = 0.3, brushStrength = 0.5, symmetry = false, frontOnly = true, subtract = false, autoDetail = true
    private var extrusion = 0.25, inset = 0.2, faceScale = 1.2, loopFraction = 0.5, loopDirection = 0
    private var detail = ModelingDetail.balanced
    private var nodes: [UUID: SCNNode] = [:], faceMaps: [UUID: [Int]] = [:], markers: SCNNode?, loopNode: SCNNode?
    private var strokeStart: ModelingDocument?, sculptTopology: ModelingSculptTopology?, sculptSource: ModelingMesh?
    private var strokeID: UUID?, strokeCenter = ModelPoint(), strokeNormal = ModelPoint(), strokePoint = CGPoint.zero, strokeDepth: Float = 0
    private var lastStamp: CGPoint?, lastUpload = 0.0, propertyStart: ModelingDocument?
    private let physics = ModelingPhysicsPreview()
    private var physicsConfigured = false
    private var saved: ModelingDocument
    private let restoresDraft: Bool
    private var fileBusy = false, pendingExport: URL?, pickerMode = "project", autosave: DispatchWorkItem?
    private var fileGeneration = UUID()
    private var lastDraftDocument: ModelingDocument?
    private let fileQueue = DispatchQueue(label: "com.netvistastudio.model.files", qos: .userInitiated)
    private var draftURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WorkingModel.netvistamodel") }
    private var selectedIndex: Int? { document.objects.firstIndex { $0.id == selectedID } }
    var selectedObject: ModelingObject? { selectedIndex.map { document.objects[$0] } }
    var geometryNodes: [UUID: SCNNode] { nodes }
    var isPhysicsPlaying: Bool { physics.state == .playing }

    init(document: ModelingDocument = .init(), restoreDraft: Bool = true) {
        self.document = document; saved = document; restoresDraft = restoreDraft; selectedID = document.objects.first?.id
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func viewWillAppear(_ animated: Bool) {super.viewWillAppear(animated); refreshAccess()}
    override func viewDidLoad() {
        super.viewDidLoad(); overrideUserInterfaceStyle = .dark; view.backgroundColor = MobileTheme.window
        if restoresDraft, FileManager.default.fileExists(atPath: draftURL.path) {
            do { document = try ModelingDocument.open(draftURL); saved = document; selectedID = document.objects.first?.id }
            catch { status.text = "The 3D draft could not be opened. It has not been overwritten: \(error.localizedDescription)" }
        }
        lastDraftDocument = document
        for item in [documentLabel, header, tools, viewport, panel, status, lockedLabel] { view.addSubview(item) }
        for scroll in [header, tools] { scroll.backgroundColor = MobileTheme.top; scroll.showsHorizontalScrollIndicator = false }
        panel.backgroundColor = MobileTheme.panel; panel.addSubview(tabs); panel.addSubview(table); panel.addSubview(inspector)
        table.dataSource = self; table.delegate = self; table.rowHeight = 56; table.backgroundColor = .clear
        table.register(UITableViewCell.self, forCellReuseIdentifier: "model.object"); table.accessibilityIdentifier = "model.objects"
        tabs.selectedSegmentIndex = 0; tabs.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        inspector.addSubview(propertyStack); propertyStack.axis = .vertical; propertyStack.spacing = 10; propertyStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            propertyStack.leadingAnchor.constraint(equalTo: inspector.contentLayoutGuide.leadingAnchor, constant: 12),
            propertyStack.trailingAnchor.constraint(equalTo: inspector.contentLayoutGuide.trailingAnchor, constant: -12),
            propertyStack.topAnchor.constraint(equalTo: inspector.contentLayoutGuide.topAnchor, constant: 12),
            propertyStack.bottomAnchor.constraint(equalTo: inspector.contentLayoutGuide.bottomAnchor, constant: -18),
            propertyStack.widthAnchor.constraint(equalTo: inspector.frameLayoutGuide.widthAnchor, constant: -24)])
        headerButtons = [button("Studio Home", "house", "home") { [weak self] in self?.leaveWorkspace(); self?.onHome?() },
                         button("New", "doc.badge.plus", "new") { [weak self] in self?.confirmNew() },
                         button("Open", "folder", "open") { [weak self] in self?.pick("project") },
                         button("Save", "square.and.arrow.down", "save") { [weak self] in self?.exportProject() },
                         button("Import OBJ", "square.and.arrow.down.on.square", "import") { [weak self] in self?.pick("obj") },
                         button("Export OBJ", "square.and.arrow.up", "export") { [weak self] in self?.exportOBJ() },
                         button("Undo", "arrow.uturn.backward", "undo") { [weak self] in self?.undo() },
                         button("Redo", "arrow.uturn.forward", "redo") { [weak self] in self?.redo() },
                         button("Panels", "sidebar.right", "panels") { [weak self] in self?.panelVisible.toggle(); self?.view.setNeedsLayout() }]
        headerButtons.forEach { header.addSubview($0) }
        modePicker.selectedSegmentIndex = 0; modePicker.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modePicker.accessibilityIdentifier = "model.mode"; tools.addSubview(modePicker)
        toolButtons = [button("Add mesh", "plus", "add") { [weak self] in self?.addMenu() },
                       button("Frame all", "viewfinder", "frame") { [weak self] in guard let self else { return }; self.viewport.frame(objects: self.document.objects) },
                       button("View", "cube", "view") { [weak self] in self?.viewMenu() },
                       button("−", nil, "zoom.out") { [weak self] in self?.viewport.zoom(0.8) },
                       button("+", nil, "zoom.in") { [weak self] in self?.viewport.zoom(1.25) },
                       button("Play physics", "play", "physics.play") { [weak self] in self?.attempt { try self?.playPhysics() } },
                       button("Pause", "pause", "physics.pause") { [weak self] in self?.physics.pause(); self?.updateStatus() },
                       button("Reset", "stop", "physics.reset") { [weak self] in self?.stopPhysics(); self?.updateStatus() }]
        toolButtons.forEach { tools.addSubview($0) }
        viewport.onPick = { [weak self] in self?.pickSurface($0) }; viewport.onStroke = { [weak self] point, phase in self?.surfaceInput(point, phase: phase) }
        physics.onUpdate = { [weak self] in self?.updateStatus() }
        lockedLabel.backgroundColor = MobileTheme.top; lockedLabel.textAlignment = .center; status.textColor = MobileTheme.secondary
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        refresh(); viewport.frame(objects: document.objects)
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); leaveWorkspace() }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets, width = max(1, view.bounds.width - safe.left - safe.right), height = max(1, view.bounds.height - safe.top - safe.bottom), top = safe.top
        let wide = width >= 900, panelWidth: CGFloat = wide ? 300 : min(330, width - 20)
        documentLabel.frame = CGRect(x: safe.left + 12, y: top, width: width - 24, height: 30)
        header.frame = CGRect(x: safe.left, y: top + 30, width: width, height: 50)
        var x: CGFloat = 8
        for (i,b) in headerButtons.enumerated() { let w: CGFloat = i == 0 ? 108 : (i == 4 || i == 5 ? 103 : 70); b.frame = CGRect(x:x,y:3,width:w,height:44); x += w+6 }
        header.contentSize = CGSize(width:x,height:50)
        tools.frame = CGRect(x:safe.left,y:top+80,width:width,height:50)
        modePicker.frame = CGRect(x:8,y:3,width:250,height:44); x = 266
        for b in toolButtons { let w:CGFloat = b.accessibilityIdentifier?.contains("zoom") == true ? 44 : 102; b.frame = CGRect(x:x,y:3,width:w,height:44); x += w+6 }
        tools.contentSize = CGSize(width:x,height:50)
        let body = max(1,height-154)
        viewport.frame = CGRect(x:safe.left,y:top+130,width:width-(wide ? panelWidth:0),height:body)
        panel.frame = CGRect(x:safe.left+width-panelWidth,y:top+130,width:panelWidth,height:body); panel.isHidden = !wide && !panelVisible
        tabs.frame = CGRect(x:10,y:4,width:panelWidth-20,height:44)
        for child in [table,inspector] { child.frame = CGRect(x:0,y:52,width:panelWidth,height:max(1,body-52)) }
        status.frame = CGRect(x:safe.left+10,y:top+height-24,width:width-20,height:24)
        lockedLabel.frame = CGRect(x:safe.left,y:top+130,width:viewport.bounds.width,height:48); view.bringSubviewToFront(lockedLabel)
    }
    private func button(_ title: String, _ symbol: String?, _ id: String, _ action: @escaping () -> Void) -> UIButton {
        let result = MobileTheme.button(title, symbol:symbol, action:action); result.accessibilityIdentifier = "model."+id; return result
    }
    private func attempt(_ body: () throws -> Void) { do { try body() } catch { status.text = error.localizedDescription } }
    private func requireAccess() throws { guard permitsEditing(), !fileBusy else { throw ModelingError.invalid(fileBusy ? "Wait for the current file operation." : "Sign in from Studio Home to edit.") } }
    func refreshAccess() {
        guard isViewLoaded else { return }; let allowed = permitsEditing() && !fileBusy
        if !allowed { finishStroke(cancel:true); stopPhysics() }
        lockedLabel.isHidden = allowed; viewport.navigationEnabled = allowed; modePicker.isEnabled = allowed
        for (i,b) in headerButtons.enumerated() { b.isEnabled = i == 0 || (allowed && (i != 6 || !undoSteps.isEmpty) && (i != 7 || !redoSteps.isEmpty)) }
        toolButtons.forEach { $0.isEnabled = allowed }; table.isUserInteractionEnabled = allowed; inspector.isUserInteractionEnabled = allowed
    }
    private func updateStatus() {
        if physicsConfigured { status.text = String(format:"Physics · %.2f s · %d bodies · authored mesh unchanged",physics.time,physics.dynamicBodyCount); return }
        let vertices = document.objects.reduce(0) { $0+$1.mesh.vertices.count }, faces = document.objects.reduce(0) { $0+$1.mesh.faces.count }
        status.text = "\(document.objects.count) objects · \(vertices) vertices · \(faces) faces · Two fingers orbit · Pinch zoom · Three fingers pan"
    }
    private func refresh() {
        documentLabel.text = "3D Editor · \(document.name)" + (document == saved ? "" : " •")
        if !document.objects.contains(where: {$0.id == selectedID}) { selectedID = document.objects.first?.id; selectedFaces = []; selectedVertex = nil }
        table.reloadData(); render(); buildProperties(); updateStatus(); refreshAccess(); scheduleDraft()
    }
    @objc private func tabChanged() { table.isHidden = tabs.selectedSegmentIndex != 0; inspector.isHidden = tabs.selectedSegmentIndex != 1 }
    @objc private func modeChanged() { setMode(modePicker.selectedSegmentIndex) }
    func setMode(_ value: Int) {
        guard permitsEditing(), (0...3).contains(value) else { return }; finishStroke(); stopPhysics()
        mode = value; modePicker.selectedSegmentIndex = value; selectedFaces = []; selectedVertex = nil
        viewport.editsSurface = value >= 2; viewport.overlay.points = []; render(); buildProperties()
    }
    func selectObject(_ id: UUID) {
        guard permitsEditing(), document.objects.contains(where: {$0.id == id}) else { return }; finishStroke(); stopPhysics()
        selectedID = id; selectedFaces = []; selectedVertex = nil; table.reloadData(); render(); buildProperties()
    }
    func perform(_ operation: (inout ModelingDocument) throws -> Void) throws {
        try requireAccess(); finishStroke(); stopPhysics(); var candidate = document; try operation(&candidate); try candidate.validate()
        guard candidate != document else { return }; remember(document); document = candidate; selectedFaces = []; selectedVertex = nil; refresh()
    }
    private func remember(_ value: ModelingDocument) {
        undoSteps.append(value); redoSteps.removeAll(); trimHistory()
    }
    private func trimHistory() {
        // Preserve original resolution, but release older snapshots on dense
        // sculpts rather than allowing undo memory to grow without bounds.
        while undoSteps.count > 1 && (undoSteps.count > 40 || undoSteps.reduce(0,{ total,doc in total+doc.objects.reduce(0,{$0+$1.mesh.vertices.count}) }) > 1_500_000) { undoSteps.removeFirst() }
        while redoSteps.count > 40 { redoSteps.removeFirst() }
    }
    func undo() {
        guard permitsEditing(), !fileBusy else { return }; finishStroke(); stopPhysics()
        guard let previous = undoSteps.popLast() else { return }; redoSteps.append(document); document = previous; selectedFaces = []; selectedVertex = nil; refresh()
    }
    func redo() {
        guard permitsEditing(), !fileBusy else { return }; finishStroke(); stopPhysics()
        guard let next = redoSteps.popLast() else { return }; undoSteps.append(document); document = next; trimHistory(); selectedFaces = []; selectedVertex = nil; refresh()
    }
    func addPrimitive(_ name: String) throws {
        var object = ModelingObject(name:name,mesh:name == "Sculpt sphere" ? try .sculptSphere(detail:detail.sphereLevel) : .primitive(name))
        if name == "Sculpt sphere" { object.smoothShading = true }
        try perform { $0.objects.append(object) }; selectedID = object.id; refresh(); viewport.frame(objects:[object])
    }
    func duplicateSelection() throws {
        guard var object = selectedObject else { return }; object.id = UUID(); object.name = String((object.name+" copy").prefix(256)); object.position.x += 0.25
        try perform { $0.objects.append(object) }; selectedID = object.id; refresh()
    }
    func deleteSelection() throws {
        guard let id = selectedID else { return }; try perform { $0.objects.removeAll {$0.id == id} }
    }
    func renameSelection(_ name: String) throws {
        guard let id = selectedID else { return }; try perform { document in guard let i = document.objects.firstIndex(where: {$0.id == id}) else { return }; document.objects[i].name = String(name.prefix(256)) }
    }
    func editSelected(_ operation: (inout ModelingObject) throws -> Void) throws {
        guard let id = selectedID else { throw ModelingError.invalid("Select a mesh first.") }
        try perform { document in guard let i = document.objects.firstIndex(where: {$0.id == id}) else { return }; try operation(&document.objects[i]) }
    }
    func topology(_ name: String) throws {
        let faces = selectedFaces
        switch name {
        case "Subdivide": try editSelected { try $0.mesh.subdivide() }
        case "Smooth subdivision": try editSelected { try $0.mesh.subdivide(smooth:true) }
        case "Relax": try editSelected { try $0.mesh.relax() }
        case "Extrude": try editSelected { try $0.mesh.extrudeRegion(faces,distance:extrusion) }
        case "Individual extrude": try editSelected { try $0.mesh.extrudeIndividualFaces(faces,distance:extrusion) }
        case "Inset": try editSelected { try $0.mesh.extrudeIndividualFaces(faces,distance:0,inset:inset) }
        case "Move faces": try editSelected { try $0.mesh.moveRegion(faces,distance:extrusion) }
        case "Scale faces": try editSelected { try $0.mesh.scaleRegion(faces,factor:faceScale) }
        case "Delete faces": try editSelected { guard !faces.isEmpty else { throw ModelingError.invalid("Tap a face first.") }; $0.mesh.deleteFaces(faces) }
        case "Loop cut":
            guard let face = faces.sorted().first else { throw ModelingError.invalid("Tap a quad face first.") }
            try editSelected { _ = try $0.mesh.loopCut(face:face,direction:loopDirection,fraction:loopFraction) }
        default: throw ModelingError.invalid("Choose an available topology operation.")
        }
    }
    func selectFaces(_ operation: String) throws {
        try requireAccess(); guard let object = selectedObject else { return }
        switch operation { case "All": selectedFaces = Set(object.mesh.faces.indices)
        case "None": selectedFaces = []
        default: selectedFaces = try object.mesh.adjustedFaceSelection(selectedFaces,operation:operation.lowercased()) }
        render(); buildProperties()
    }
    private func addMenu() {
        guard permitsEditing() else { return }; menu("Add editable geometry", choices:["Cube","Sphere","Plane","Cylinder","Sculpt sphere","Dragon starter","Join visible meshes"]) { [weak self] name in
            guard let self else { return }; self.attempt {
                if name == "Dragon starter" { let objects = try ModelingGenerators.dragon(detail:self.detail); try self.perform {$0.objects += objects}; self.selectedID = objects.first?.id; self.refresh(); self.viewport.frame(objects:objects) }
                else if name == "Join visible meshes" { let mesh = try ModelingMesh.joined(self.document.objects.filter(\.visible)); let object = ModelingObject(name:"Joined mesh",mesh:mesh); try self.perform { $0.objects.removeAll(where: \.visible); $0.objects.append(object) }; self.selectedID = object.id; self.refresh() }
                else { try self.addPrimitive(name) }
            }
        }
    }
    private func viewMenu() {
        menu("Viewport",choices:["Perspective","Front","Right","Top","Back","Left","Bottom","Solid / wireframe","Focus selected"]) { [weak self] item in
            guard let self else { return }
            if item == "Solid / wireframe" { self.wireframe.toggle(); self.render() }
            else if item == "Focus selected" { if let object = self.selectedObject { self.viewport.frame(objects:[object]) } }
            else { self.viewport.setDirection(item) }
        }
    }
    private func menu(_ title: String, choices: [String], select: @escaping (String) -> Void) {
        let alert = UIAlertController(title:title,message:nil,preferredStyle:.actionSheet)
        for choice in choices { alert.addAction(UIAlertAction(title:choice,style:.default) {_ in select(choice)}) }
        alert.addAction(UIAlertAction(title:"Cancel",style:.cancel))
        alert.popoverPresentationController?.sourceView = view; alert.popoverPresentationController?.sourceRect = CGRect(x:view.bounds.midX,y:100,width:1,height:1)
        present(alert,animated:true)
    }
    private func ask(_ title: String, value: String, apply: @escaping (String) -> Void) {
        let alert = UIAlertController(title:title,message:nil,preferredStyle:.alert)
        alert.addTextField { $0.text = value }; alert.addAction(UIAlertAction(title:"Cancel",style:.cancel))
        alert.addAction(UIAlertAction(title:"Apply",style:.default) {_ in apply(alert.textFields?.first?.text ?? value) }); present(alert,animated:true)
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { document.objects.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier:"model.object",for:indexPath), object = document.objects[indexPath.row]
        var content = cell.defaultContentConfiguration(); content.text = object.name; content.textProperties.font = .systemFont(ofSize:13,weight:.medium)
        content.secondaryText = "\(object.mesh.vertices.count) vertices · \(object.mesh.faces.count) faces"; content.secondaryTextProperties.font = .systemFont(ofSize:10)
        content.image = UIImage(systemName:object.visible ? "cube.fill":"cube"); content.imageProperties.tintColor = object.id == selectedID ? .systemOrange : MobileTheme.secondary
        cell.contentConfiguration = content; cell.backgroundColor = object.id == selectedID ? MobileTheme.control : .clear
        let visibility = button(object.visible ? "Hide":"Show",object.visible ? "eye":"eye.slash","visibility.\(object.id)") { [weak self] in
            self?.attempt { try self?.perform { document in guard let i = document.objects.firstIndex(where:{$0.id == object.id}) else {return}; document.objects[i].visible.toggle() } }
        }
        visibility.frame = CGRect(x:0,y:0,width:44,height:44); visibility.setTitle("",for:.normal); cell.accessoryView = visibility
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { selectObject(document.objects[indexPath.row].id); tabs.selectedSegmentIndex = 1; tabChanged() }
    private func clearProperties() { propertyStack.arrangedSubviews.forEach { propertyStack.removeArrangedSubview($0); $0.removeFromSuperview() } }
    private func section(_ name: String) { propertyStack.addArrangedSubview(MobileTheme.label(name.uppercased(),size:11,weight:.bold)) }
    private func help(_ text: String) { let label = MobileTheme.label(text,size:11); label.numberOfLines = 0; label.textColor = MobileTheme.secondary; propertyStack.addArrangedSubview(label) }
    private func action(_ title: String, _ id: String, _ body: @escaping () throws -> Void) {
        let b = button(title,nil,id) { [weak self] in self?.attempt(body) }; b.heightAnchor.constraint(equalToConstant:44).isActive = true; propertyStack.addArrangedSubview(b)
    }
    private func toggle(_ title: String, value: Bool, action: @escaping (Bool) -> Void) {
        let row = UIStackView(); row.axis = .horizontal; row.alignment = .center; row.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive = true; row.addArrangedSubview(MobileTheme.label(title))
        let control = UISwitch(); control.isOn = value; control.addAction(UIAction {_ in action(control.isOn)},for:.valueChanged); row.addArrangedSubview(control); propertyStack.addArrangedSubview(row)
    }
    private func number(_ title: String, value: Double, apply: @escaping (Double) throws -> Void) {
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 8; row.addArrangedSubview(MobileTheme.label(title))
        let input = UITextField(); input.text = String(format:"%.3f",value); input.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular)
        input.textAlignment = .right; input.textColor = .white; input.backgroundColor = MobileTheme.top; input.borderStyle = .roundedRect
        input.keyboardType = .numbersAndPunctuation; input.widthAnchor.constraint(equalToConstant:110).isActive = true
        input.heightAnchor.constraint(equalToConstant:44).isActive = true
        input.accessibilityIdentifier = "model.property."+title; input.addAction(UIAction { [weak self] _ in
            self?.attempt { guard let value = Double(input.text ?? ""), value.isFinite else { throw ModelingError.invalid("Enter a finite number for \(title).") }; try apply(value) }
        },for:.editingDidEnd); row.addArrangedSubview(input); propertyStack.addArrangedSubview(row)
    }
    private func buildProperties() {
        clearProperties(); tabChanged()
        guard let object = selectedObject else { section("Scene"); help("Add a mesh, or import a triangle/quad OBJ. Projects keep separate objects, colours, sculpt masks and physics settings."); return }
        section(object.name)
        action("Rename", "rename") { [weak self] in self?.ask("Object name",value:object.name) { name in self?.attempt { try self?.renameSelection(name) } } }
        action("Duplicate object", "duplicate") { [weak self] in try self?.duplicateSelection() }
        action("Delete object", "delete") { [weak self] in try self?.deleteSelection() }
        if mode == 0 || mode == 2 {
            section(mode == 2 ? "Selected vertex" : "Transform")
            if mode == 2 { help("Tap a surface to select its nearest vertex. Drag the vertex on screen. Two fingers orbit without editing.") }
            for axis in 0..<3 {
                let names = ["X","Y","Z"], point = mode == 2 ? selectedVertex.flatMap {object.mesh.vertices.indices.contains($0) ? object.mesh.vertices[$0]:nil} : object.position
                if let point { number("Position "+names[axis],value:[point.x,point.y,point.z][axis]) { [weak self] value in
                    guard let self else { return }; let vertex = self.selectedVertex
                    try self.editSelected { object in
                        if self.mode == 2 { guard let vertex, object.mesh.vertices.indices.contains(vertex) else {return}; if axis == 0 {object.mesh.vertices[vertex].x = value}; if axis == 1 {object.mesh.vertices[vertex].y = value}; if axis == 2 {object.mesh.vertices[vertex].z = value} }
                        else {if axis == 0 {object.position.x = value}; if axis == 1 {object.position.y = value}; if axis == 2 {object.position.z = value}}
                    }
                } }
                if mode == 0 {
                    number("Rotation "+names[axis],value:[object.rotation.x,object.rotation.y,object.rotation.z][axis]) { [weak self] value in try self?.editSelected { if axis == 0 {$0.rotation.x = value}; if axis == 1 {$0.rotation.y = value}; if axis == 2 {$0.rotation.z = value} } }
                    number("Scale "+names[axis],value:[object.scale.x,object.scale.y,object.scale.z][axis]) { [weak self] value in try self?.editSelected { if axis == 0 {$0.scale.x = value}; if axis == 1 {$0.scale.y = value}; if axis == 2 {$0.scale.z = value} } }
                }
            }
            toggle("Snap moves to 0.1",value:snap) { [weak self] in self?.snap = $0 }
        }
        if mode == 1 {
            section("\(selectedFaces.count) selected faces")
            toggle("Extend face selection",value:multiSelect) { [weak self] in self?.multiSelect = $0 }
            for selection in ["All","None","Grow","Shrink","Linked"] { action(selection+" faces","faces."+selection.lowercased()) { [weak self] in try self?.selectFaces(selection) } }
            number("Distance",value:extrusion) { [weak self] in guard abs($0) <= 1000 else {throw ModelingError.invalid("Use a distance up to 1,000.")}; self?.extrusion = $0 }
            number("Inset fraction",value:inset) { [weak self] in guard (0...0.95).contains($0) else {throw ModelingError.invalid("Inset is 0–0.95.")}; self?.inset = $0 }
            number("Face scale",value:faceScale) { [weak self] in guard $0 > 0 else {throw ModelingError.invalid("Scale must be positive.")}; self?.faceScale = $0 }
            for operation in ["Extrude","Individual extrude","Inset","Move faces","Scale faces","Delete faces"] { action(operation,"topology."+operation.lowercased()) { [weak self] in try self?.topology(operation) } }
            section("Loop cut")
            number("Loop position",value:loopFraction) { [weak self] in guard (0.01...0.99).contains($0) else {throw ModelingError.invalid("Loop position is 0.01–0.99.")}; self?.loopFraction = $0; self?.previewLoop() }
            toggle("Other loop direction",value:loopDirection == 1) { [weak self] in self?.loopDirection = $0 ? 1:0; self?.previewLoop() }
            action("Preview loop cut","loop.preview") { [weak self] in self?.previewLoop() }
            action("Apply loop cut","topology.loop cut") { [weak self] in try self?.topology("Loop cut") }
        }
        if mode == 3 {
            section("Sculpt surface")
            action("Brush · "+brush.rawValue,"brush") { [weak self] in self?.menu("Sculpt brush",choices:ModelingBrush.allCases.map(\.rawValue)) { name in if let value = ModelingBrush(rawValue:name) {self?.brush = value; self?.buildProperties()} } }
            help(brush.help)
            number("Brush radius",value:brushRadius) { [weak self] in guard (0.001...1000).contains($0) else {throw ModelingError.invalid("Brush radius is 0.001–1,000 model units.")}; self?.brushRadius = $0 }
            number("Brush strength",value:brushStrength) { [weak self] in guard (0.01...1).contains($0) else {throw ModelingError.invalid("Strength is 0.01–1.")}; self?.brushStrength = $0 }
            toggle("Subtract / invert",value:subtract) { [weak self] in self?.subtract = $0 }
            toggle("X symmetry",value:symmetry) { [weak self] in self?.symmetry = $0 }
            toggle("Front-facing vertices only",value:frontOnly) { [weak self] in self?.frontOnly = $0 }
            toggle("Add detail to coarse meshes",value:autoDetail) { [weak self] in self?.autoDetail = $0 }
            action("Clear sculpt mask","mask.clear") { [weak self] in try self?.editSelected {$0.mesh.clearSculptMask()} }
            action("Invert sculpt mask","mask.invert") { [weak self] in try self?.editSelected {$0.mesh.invertSculptMask()} }
            help("One finger sculpts the actual touched side. Two fingers orbit. Pinch zooms. A whole stroke is one Undo; switching tools commits it.")
        }
        section("Mesh detail")
        action("Subdivide","topology.subdivide") { [weak self] in try self?.topology("Subdivide") }
        action("Smooth subdivision","topology.smooth subdivision") { [weak self] in try self?.topology("Smooth subdivision") }
        action("Relax surface","topology.relax") { [weak self] in try self?.topology("Relax") }
        section("Surface")
        toggle("Smooth shading",value:object.smoothShading == true) { [weak self] value in self?.attempt {try self?.editSelected {$0.smoothShading = value}} }
        action("Material colour","colour") { [weak self] in
            guard let self else {return}; let picker = UIColorPickerViewController(); picker.selectedColor = Self.colour(object.colour); picker.supportsAlpha = false; picker.delegate = self; self.present(picker,animated:true)
        }
        section("Rigid-body physics")
        let settings = object.physics ?? .init()
        action("Body · "+settings.mode.title,"physics.mode") { [weak self] in self?.menu("Physics body",choices:ModelingPhysicsMode.allCases.map(\.title)) { title in
            guard let mode = ModelingPhysicsMode.allCases.first(where:{$0.title == title}) else {return}; self?.attempt {try self?.editSelected {var p = $0.physics ?? .init(); p.mode = mode; $0.physics = p}}
        } }
        number("Mass",value:settings.mass) { [weak self] value in try self?.editSelected {var p = $0.physics ?? .init(); p.mass = value; try p.validate(); $0.physics = p} }
        number("Friction",value:settings.friction) { [weak self] value in try self?.editSelected {var p = $0.physics ?? .init(); p.friction = value; try p.validate(); $0.physics = p} }
        number("Bounce",value:settings.restitution) { [weak self] value in try self?.editSelected {var p = $0.physics ?? .init(); p.restitution = value; try p.validate(); $0.physics = p} }
        toggle("Gravity",value:settings.affectedByGravity) { [weak self] value in self?.attempt {try self?.editSelected {var p = $0.physics ?? .init(); p.affectedByGravity = value; $0.physics = p}} }
        help("Native rigid bodies with box colliders and a floor at Y = 0. Play never changes saved geometry; Reset restores the authored pose. No cloth, fluid or soft-body simulation.")
    }
    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        var r:CGFloat = 0,g:CGFloat = 0,b:CGFloat = 0,a:CGFloat = 0
        guard viewController.selectedColor.getRed(&r,green:&g,blue:&b,alpha:&a) else {return}
        let hex = String(format:"#%02X%02X%02X",Int(r*255),Int(g*255),Int(b*255)); attempt {try editSelected {$0.colour = hex}}
    }
    static func colour(_ hex: String) -> UIColor { MobileTheme.color(UInt32(hex.dropFirst(),radix:16) ?? 0x92A9BE) }

    private func render(only changedID: UUID? = nil) {
        guard let root = viewport.scene?.rootNode else {return}
        if physicsConfigured {stopPhysics()}
        if let changedID { nodes.removeValue(forKey:changedID)?.removeFromParentNode(); faceMaps.removeValue(forKey:changedID) }
        else { nodes.values.forEach {$0.removeFromParentNode()}; nodes.removeAll(); faceMaps.removeAll() }
        markers?.removeFromParentNode(); markers = nil; loopNode?.removeFromParentNode(); loopNode = nil
        for object in document.objects where object.visible && (changedID == nil || changedID == object.id) {
            let world = object.mesh.vertices.map {object.world($0)}
            let smooth = object.smoothShading == true ? ModelingMesh(vertices:world,faces:object.mesh.faces).vertexNormals() : []
            var positions: [SCNVector3] = [], normals: [SCNVector3] = [], triangles: [UInt32] = [], mapping: [Int] = [], colors: [Float] = []
            var r:CGFloat = 0,g:CGFloat = 0,b:CGFloat = 0,a:CGFloat = 0; Self.colour(object.colour).getRed(&r,green:&g,blue:&b,alpha:&a)
            func appendColour(vertex: Int, selected: Bool) {
                let protection = mode == 3 && object.id == selectedID ? (object.mesh.sculptMask?[vertex] ?? 0) : 0
                let shade = Float(1-protection*0.8)
                colors += selected ? [1,0.5,0.1,1] : [Float(r)*shade,Float(g)*shade,Float(b)*shade,1]
            }
            if !smooth.isEmpty && mode != 1 {
                positions = world.map(\.mobileSCN); normals = smooth.map(\.mobileSCN)
                for v in world.indices {appendColour(vertex:v,selected:false)}
                for (f,face) in object.mesh.faces.enumerated() {for j in 1..<face.count-1 {triangles += [UInt32(face[0]),UInt32(face[j]),UInt32(face[j+1])]; mapping.append(f)}}
            } else {
                for (f,face) in object.mesh.faces.enumerated() {
                    let normal = (world[face[1]]-world[face[0]]).cross(world[face[2]]-world[face[0]]).unit
                    for j in 1..<face.count-1 {for v in [face[0],face[j],face[j+1]] {
                        positions.append(world[v].mobileSCN); normals.append((smooth.isEmpty ? normal : smooth[v]).mobileSCN)
                        appendColour(vertex:v,selected:mode == 1 && object.id == selectedID && selectedFaces.contains(f))
                    }; mapping.append(f)}
                }; triangles = Array(0..<UInt32(positions.count))
            }
            let colorData = colors.withUnsafeBufferPointer {Data(buffer:$0)}
            let color = SCNGeometrySource(data:colorData,semantic:.color,vectorCount:positions.count,usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)
            let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:positions),SCNGeometrySource(normals:normals),color],elements:[SCNGeometryElement(indices:triangles,primitiveType:.triangles)])
            let material = SCNMaterial(); material.lightingModel = .lambert; material.isDoubleSided = true; material.diffuse.contents = UIColor.white
            material.emission.contents = object.id == selectedID ? UIColor(white:0.045,alpha:1):UIColor.black; material.fillMode = wireframe ? .lines:.fill; geometry.materials = [material]
            let node = SCNNode(geometry:geometry); node.name = object.id.uuidString; node.categoryBitMask = 1; root.addChildNode(node)
            nodes[object.id] = node; faceMaps[object.id] = mapping
        }
        if mode == 2, let object = selectedObject, object.visible, let vertex = selectedVertex, object.mesh.vertices.indices.contains(vertex) {
            let dot = SCNSphere(radius:max(0.004,min(0.08,viewport.distance*0.006))); dot.segmentCount = 10
            dot.firstMaterial?.diffuse.contents = UIColor.systemOrange; dot.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry:dot); node.position = object.world(object.mesh.vertices[vertex]).mobileSCN; node.categoryBitMask = 4
            root.addChildNode(node); markers = node
        }
        SCNTransaction.flush(); viewport.setNeedsDisplay()
    }
    func pickSurface(_ point: CGPoint) {
        guard permitsEditing(), !fileBusy, let hit = viewport.surfaceHit(point), let id = UUID(uuidString:hit.node.name ?? ""), let index = document.objects.firstIndex(where:{$0.id == id}) else {return}
        // A second pointer/select command commits the old owner's stroke
        // before changing the active object/vertex.
        finishStroke()
        if selectedID != id { selectedFaces = []; selectedVertex = nil }
        selectedID = id
        let object = document.objects[index]
        if mode == 1, let map = faceMaps[id], map.indices.contains(hit.faceIndex) {
            let face = map[hit.faceIndex]
            if multiSelect {if !selectedFaces.insert(face).inserted {selectedFaces.remove(face)}} else {selectedFaces = [face]}
        }
        if mode == 2 {
            let hitPoint = ModelPoint(mobile:hit.worldCoordinates)
            let candidates = faceMaps[id].flatMap {map in map.indices.contains(hit.faceIndex) ? object.mesh.faces[map[hit.faceIndex]]:nil} ?? Array(object.mesh.vertices.indices)
            selectedVertex = candidates.min { (object.world(object.mesh.vertices[$0])-hitPoint).length < (object.world(object.mesh.vertices[$1])-hitPoint).length }
        }
        table.reloadData(); render(); buildProperties()
    }
    private func localNormal(_ hit: SCNHitTestResult, object: ModelingObject) -> ModelPoint {
        let n = ModelPoint(mobile:hit.worldNormal).rotated(object.rotation,inverse:true)
        return ModelPoint(x:n.x*object.scale.x,y:n.y*object.scale.y,z:n.z*object.scale.z).unit
    }
    /// Invoked by production UIKit gestures and deterministic simulator checks.
    /// Geometry, not its preview image, is the source of every hit and stamp.
    func surfaceInput(_ point: CGPoint, phase: Int) {
        guard permitsEditing(), !fileBusy else { finishStroke(cancel:true); return }
        if phase == 3 {finishStroke(cancel:true); return}
        if phase == 0 {
            finishStroke(); stopPhysics()
            guard let hit = viewport.surfaceHit(point), let id = UUID(uuidString:hit.node.name ?? ""), let i = document.objects.firstIndex(where:{$0.id == id}) else {return}
            if mode == 2 {pickSurface(point)} else {selectedID = id}
            strokeStart = document; strokeID = id; strokePoint = point; lastStamp = nil
            strokeCenter = document.objects[i].local(ModelPoint(mobile:hit.worldCoordinates)); strokeNormal = localNormal(hit,object:document.objects[i])
            if mode == 3, autoDetail, document.objects[i].mesh.vertices.count < 200 {
                do {
                    var candidate = document
                    while candidate.objects[i].mesh.faces.count < 512 && !candidate.objects[i].mesh.faces.isEmpty {
                        try candidate.objects[i].mesh.subdivide(); try candidate.validate()
                    }
                    document = candidate
                } catch {finishStroke(cancel:true); status.text = error.localizedDescription; return}
            }
            sculptSource = document.objects[i].mesh; sculptTopology = ModelingSculptTopology(document.objects[i].mesh)
            if mode == 2, let vertex = selectedVertex, document.objects[i].mesh.vertices.indices.contains(vertex) {strokeDepth = viewport.projectPoint(document.objects[i].world(document.objects[i].mesh.vertices[vertex]).mobileSCN).z}
            else {strokeDepth = viewport.projectPoint(hit.worldCoordinates).z}
        }
        guard let id = strokeID, let i = document.objects.firstIndex(where:{$0.id == id}), strokeStart != nil else {return}
        if phase == 1 && CACurrentMediaTime()-lastUpload < 1.0/30.0 {return}
        if mode == 2, let vertex = selectedVertex, document.objects[i].mesh.vertices.indices.contains(vertex) {
            let begin = ModelPoint(mobile:viewport.unprojectPoint(SCNVector3(Float(strokePoint.x),Float(strokePoint.y),strokeDepth)))
            let end = ModelPoint(mobile:viewport.unprojectPoint(SCNVector3(Float(point.x),Float(point.y),strokeDepth)))
            let object = document.objects[i], source = sculptSource!.vertices[vertex]
            var local = source + object.local(end)-object.local(begin)
            if snap {local = .init(x:(local.x*10).rounded()/10,y:(local.y*10).rounded()/10,z:(local.z*10).rounded()/10)}
            document.objects[i].mesh.vertices[vertex] = local.bounded
        } else if mode == 3 {
            if brush == .grab {
                let begin = ModelPoint(mobile:viewport.unprojectPoint(SCNVector3(Float(strokePoint.x),Float(strokePoint.y),strokeDepth)))
                let end = ModelPoint(mobile:viewport.unprojectPoint(SCNVector3(Float(point.x),Float(point.y),strokeDepth)))
                var mesh = sculptSource!; let object = document.objects[i]
                mesh.sculpt(brush:.grab,center:strokeCenter,normal:strokeNormal,radius:brushRadius,strength:brushStrength,symmetry:symmetry,frontOnly:frontOnly,delta:object.local(end)-object.local(begin),topology:sculptTopology)
                document.objects[i].mesh = mesh
            } else {
                let origin = lastStamp ?? point, length = hypot(point.x-origin.x,point.y-origin.y)
                let samples = max(1,min(document.objects[i].mesh.vertices.count > 20_000 ? 4:12,Int(ceil(length/5))))
                for step in 1...samples {
                    let fraction = CGFloat(step)/CGFloat(samples), sample = CGPoint(x:origin.x+(point.x-origin.x)*fraction,y:origin.y+(point.y-origin.y)*fraction)
                    let object = document.objects[i]
                    // The initial hit's own normal remains valid after automatic
                    // subdivision; do not reinterpret an old triangle index.
                    let center: ModelPoint, normal: ModelPoint
                    if phase == 0 {center = strokeCenter; normal = strokeNormal}
                    else if let hit = viewport.surfaceHit(sample), hit.node.name == id.uuidString {center = object.local(ModelPoint(mobile:hit.worldCoordinates)); normal = localNormal(hit,object:object)}
                    else {continue}
                    document.objects[i].mesh.sculpt(brush:brush,center:center,normal:normal,radius:brushRadius,strength:brushStrength,invert:subtract,symmetry:symmetry,frontOnly:frontOnly,topology:sculptTopology)
                    viewport.cursor(object:document.objects[i],center:center,normal:normal,radius:brushRadius)
                }; lastStamp = point
            }
        }
        lastUpload = CACurrentMediaTime(); render(only:id)
        if phase == 2 {finishStroke()}
    }
    func finishStroke(cancel: Bool = false) {
        guard let initial = strokeStart else {return}
        if cancel {document = initial} else if document != initial {remember(initial)}
        strokeStart = nil; strokeID = nil; sculptSource = nil; sculptTopology = nil; lastStamp = nil
        viewport.overlay.points = []; refresh()
    }
    func previewLoop() {
        loopNode?.removeFromParentNode(); loopNode = nil
        guard let object = selectedObject, let face = selectedFaces.sorted().first else {status.text = "Tap a quad face to preview a cut."; return}
        do {
            let preview = try object.mesh.loopCutPreview(face:face,direction:loopDirection,fraction:loopFraction)
            let points = preview.segments.flatMap {[object.world($0.start).mobileSCN,object.world($0.end).mobileSCN]}
            let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:points)],elements:[SCNGeometryElement(indices:Array(0..<Int32(points.count)),primitiveType:.line)])
            let material = SCNMaterial(); material.diffuse.contents = UIColor.systemYellow; material.lightingModel = .constant; material.readsFromDepthBuffer = false
            geometry.materials = [material]; let node = SCNNode(geometry:geometry); node.categoryBitMask = 8; node.renderingOrder = 10
            viewport.scene?.rootNode.addChildNode(node); loopNode = node; status.text = "Preview · \(preview.faceCount) cuts → \(preview.result.faces) faces. Apply keeps shared edges connected."
        } catch {status.text = error.localizedDescription}
    }
    func playPhysics() throws {
        try requireAccess(); finishStroke()
        if !physicsConfigured {
            let participants = document.objects.filter { $0.visible && ($0.physics?.mode ?? .off) != .off }.compactMap { object -> ModelingPhysicsParticipant? in
                guard let node = nodes[object.id] else {return nil}; return .init(id:object.id,node:node,settings:object.physics ?? .init())
            }
            guard participants.contains(where:{$0.settings.mode == .dynamic}) else {throw ModelingError.invalid("Set a mesh's Physics body to Dynamic, then press Play.")}
            try physics.configure(participants:participants); physicsConfigured = true
        }; physics.play(); viewport.isPlaying = true; updateStatus()
    }
    func stopPhysics() {physics.end(); physicsConfigured = false; viewport.isPlaying = false}
    private func confirmNew() {
        guard permitsEditing() else {return}
        let alert = UIAlertController(title:"New 3D project?",message:"Save the current project first if you want a separate copy. You can also Undo a new scene.",preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"Cancel",style:.cancel)); alert.addAction(UIAlertAction(title:"New empty scene",style:.default) { [weak self] _ in
            self?.attempt {try self?.perform {$0 = ModelingDocument()}; self?.viewport.frame(objects:[])}
        }); present(alert,animated:true)
    }
    func openProject(url: URL) throws {
        try requireAccess(); let candidate = try ModelingDocument.open(url); finishStroke(); stopPhysics()
        remember(document); document = candidate; saved = candidate; selectedID = candidate.objects.first?.id; selectedFaces = []; selectedVertex = nil
        if isViewLoaded {refresh(); viewport.frame(objects:candidate.objects)}
    }
    func loadDocument(_ candidate: ModelingDocument) throws {
        try requireAccess(); try candidate.validate(); finishStroke(); stopPhysics(); remember(document)
        document = candidate; selectedID = candidate.objects.first?.id; selectedFaces = []; selectedVertex = nil
        if isViewLoaded {refresh(); viewport.frame(objects:candidate.objects)}
    }
    private func pick(_ kind: String) {
        guard permitsEditing(), !fileBusy else {return}; finishStroke(); stopPhysics(); pickerMode = kind
        let type = UTType(filenameExtension:kind == "obj" ? "obj":"netvistamodel") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes:[type],asCopy:true); picker.delegate = self; present(picker,animated:true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let exported = pendingExport { pendingExport = nil; try? FileManager.default.removeItem(at:exported.deletingLastPathComponent()); return }
        guard permitsEditing(), !fileBusy, let url = urls.first else {return}; let kind = pickerMode
        let ticket = UUID(); fileGeneration = ticket; fileBusy = true; refreshAccess(); status.text = "Opening \(url.lastPathComponent)…"
        fileQueue.async { [weak self] in
            let accessed = url.startAccessingSecurityScopedResource(); defer {if accessed {url.stopAccessingSecurityScopedResource()}}
            let result: Result<ModelingDocument,Error> = Result {
                if kind == "project" {return try ModelingDocument.open(url)}
                guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= ModelingLimits.objBytes else {throw ModelingError.invalid("Use an OBJ under 64 MB.")}
                let mesh = try ModelingMesh.readOBJ(Data(contentsOf:url)); var document = ModelingDocument()
                document.objects = [ModelingObject(name:String(url.deletingPathExtension().lastPathComponent.prefix(256)),mesh:mesh)]; return document
            }
            DispatchQueue.main.async {
                guard let self, self.fileGeneration == ticket else {return}; self.fileBusy = false; self.refreshAccess(); guard self.permitsEditing() else {return}
                self.attempt {let loaded = try result.get(); if kind == "project" {try self.loadDocument(loaded); self.saved = loaded; self.refresh()}
                    else {try self.perform {$0.objects += loaded.objects}; self.selectedID = loaded.objects.first?.id; self.refresh(); self.viewport.frame(objects:loaded.objects)}}
            }
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if let exported = pendingExport {pendingExport = nil; try? FileManager.default.removeItem(at:exported.deletingLastPathComponent())}
    }
    private func exportProject() {exportFile(asOBJ:false)}
    private func exportOBJ() {exportFile(asOBJ:true)}
    private func exportFile(asOBJ: Bool) {
        guard permitsEditing(), !fileBusy else {return}; finishStroke(); stopPhysics(); let snapshot = document
        let ticket = UUID(); fileGeneration = ticket; fileBusy = true; refreshAccess(); status.text = asOBJ ? "Preparing visible geometry…":"Saving editable 3D project…"
        fileQueue.async { [weak self] in
            let result: Result<URL,Error> = Result {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NetVistaModelExport-"+UUID().uuidString,isDirectory:true)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let name = snapshot.name.unicodeScalars.map {CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" ? String($0):"_"}.joined()
                let url = directory.appendingPathComponent(String((name.isEmpty ? "Untitled Model":name).prefix(128))).appendingPathExtension(asOBJ ? "obj":"netvistamodel")
                do {if asOBJ {try snapshot.obj().write(to:url,atomically:true,encoding:.utf8)} else {try snapshot.save(url)}; return url}
                catch {try? FileManager.default.removeItem(at:directory); throw error}
            }
            DispatchQueue.main.async {
                guard let self, self.fileGeneration == ticket, self.isViewLoaded, self.view.window != nil, self.presentedViewController == nil else {
                    // Encoding owns exactly one generated temporary directory.
                    // Leaving Home never presents a detached Files dialog or
                    // leaves a completed export occupying storage.
                    if case .success(let url) = result {try? FileManager.default.removeItem(at:url.deletingLastPathComponent())}
                    if let self, self.fileGeneration == ticket {self.fileBusy = false; self.refreshAccess()}
                    return
                }; self.fileBusy = false; self.refreshAccess()
                self.attempt {let url = try result.get(); guard self.permitsEditing() else {try? FileManager.default.removeItem(at:url.deletingLastPathComponent()); return}
                    self.pendingExport = url; let picker = UIDocumentPickerViewController(forExporting:[url],asCopy:true); picker.delegate = self; self.present(picker,animated:true)
                    self.status.text = asOBJ ? "OBJ contains visible geometry with transforms baked. Save a project to retain materials, masks and separate objects.":"Choose where to save your editable .netvistamodel project."
                }
            }
        }
    }
    private func scheduleDraft() {guard restoresDraft else {return}; autosave?.cancel(); let work = DispatchWorkItem { [weak self] in self?.saveDraft() }; autosave = work; DispatchQueue.main.asyncAfter(deadline:.now()+1,execute:work)}
    private func saveDraft() {
        guard restoresDraft, permitsEditing(), document != lastDraftDocument else {return}
        let snapshot = document, url = draftURL; lastDraftDocument = snapshot
        fileQueue.async { [weak self] in do {try snapshot.save(url)} catch {DispatchQueue.main.async {self?.status.text = "3D autosave failed: \(error.localizedDescription)"; self?.lastDraftDocument = nil}} }
    }
    private func leaveWorkspace() {
        finishStroke(); stopPhysics(); saveDraft(); fileGeneration = UUID(); fileBusy = false
    }
    @objc private func backgrounded() {leaveWorkspace()}
}
