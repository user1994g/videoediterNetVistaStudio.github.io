import Cocoa
import CoreImage
import UniformTypeIdentifiers

/// A compact, native colour workspace. It keeps the familiar three-way wheels
/// but adds a fast node stack, curve editor, HSL qualifier, scopes and LUT
/// export without sending the user to a browser or a second application.
final class AdvancedColorStudioViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onPreview: ((ColorControlValues) -> Void)?
    var onApply: ((ColorControlValues) -> Void)?
    var onCancelPreview: (() -> Void)?
    var onRequestSavedValues: (() -> ColorControlValues?)?
    var onExportLUT: (([GradeNode], Int) -> Void)?
    var onRequestScopeImage: (() -> CIImage?)?

    private let selectionLabel = NSTextField(labelWithString: "No video clip selected")
    private let nodeTable = NSTableView(frame: .zero)
    private let nodeScroll = NSScrollView()
    private let nodeName = NSTextField(string: "Grade 1")
    private let nodeEnabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let nodeMix = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let nodeExposure = NSSlider(value: 0, minValue: -4, maxValue: 4, target: nil, action: nil)
    private let nodeContrast = NSSlider(value: 1, minValue: 0, maxValue: 3, target: nil, action: nil)
    private let nodeSaturation = NSSlider(value: 1, minValue: 0, maxValue: 3, target: nil, action: nil)
    private let nodeHue = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    private let baseExposure = NSSlider(value: 0, minValue: -3, maxValue: 3, target: nil, action: nil)
    private let baseContrast = NSSlider(value: 1, minValue: 0.25, maxValue: 2, target: nil, action: nil)
    private let baseSaturation = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let baseTemperature = NSSlider(value: 6500, minValue: 2000, maxValue: 10000, target: nil, action: nil)
    private let baseTint = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    private let baseVibrance = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let liftPanel = ColorWheelPanel(title: "Lift", detail: "Shadows / black point", chromaLimit: 0.18)
    private let gammaPanel = ColorWheelPanel(title: "Gamma", detail: "Midtones", chromaLimit: 0.16)
    private let gainPanel = ColorWheelPanel(title: "Gain", detail: "Highlights / white point", chromaLimit: 0.20)
    private let curvePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let curveView = GradeCurveEditorView(frame: .zero)
    private let qualifierEnabled = NSButton(checkboxWithTitle: "Isolate this colour range", target: nil, action: nil)
    private let qualifierInverted = NSButton(checkboxWithTitle: "Invert qualifier", target: nil, action: nil)
    private let qualifierHue = NSSlider(value: 60, minValue: 0, maxValue: 360, target: nil, action: nil)
    private let qualifierWidth = NSSlider(value: 60, minValue: 1, maxValue: 180, target: nil, action: nil)
    private let qualifierSatMin = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let qualifierSatMax = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let qualifierLumMin = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let qualifierLumMax = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let qualifierSoftness = NSSlider(value: 0.18, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let scopeTabs = NSSegmentedControl(labels: ["Waveform", "Parade", "Histogram", "Vectorscope"], trackingMode: .selectOne, target: nil, action: nil)
    private let scopeView = GradeScopeView(frame: .zero)
    private let lutName = NSTextField(labelWithString: "No LUT assigned")
    private let lutStrength = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let lutDimension = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bypass = NSButton(checkboxWithTitle: "Bypass grade", target: nil, action: nil)
    private let tabs = NSSegmentedControl(labels: ["Nodes", "Primaries", "Curves", "Qualifier", "Scopes", "LUT"], trackingMode: .selectOne, target: nil, action: nil)
    private let contentStack = NSStackView()
    private var tabViews: [NSView] = []
    private var nodes: [GradeNode] = []
    private var selectedNodeIndex: Int?
    private var baseValues = ColorControlValues()
    private var hasVideoSelection = false
    private var currentSelectionName = "No timeline video selected"
    private var curveKind = 0
    private var selectedLUT: ClipLUTSettings?
    private var scopeImage: CIImage?

    private var selectedNode: GradeNode? {
        guard let index = selectedNodeIndex, nodes.indices.contains(index) else { return nil }
        return nodes[index]
    }

    var currentValues: ColorControlValues { values() }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        onCancelPreview?()
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1120, height: 820))
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(hex: "171B22").cgColor

        let root = NSStackView(); root.orientation = .vertical; root.alignment = .width; root.spacing = 10; root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), root.topAnchor.constraint(equalTo: view.topAnchor, constant: 14), root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)])

        let header = NSStackView(); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 10
        let title = NSTextField(labelWithString: "COLOUR WORKSPACE"); title.font = .systemFont(ofSize: 17, weight: .bold); title.textColor = .white
        let badge = NSTextField(labelWithString: "NODE GRADING • LIVE"); badge.font = .systemFont(ofSize: 9, weight: .bold); badge.textColor = NSColor(hex: "55D6A0")
        header.addArrangedSubview(title); header.addArrangedSubview(badge); header.addArrangedSubview(NSView()); bypass.target = self; bypass.action = #selector(bypassChanged); header.addArrangedSubview(bypass)
        root.addArrangedSubview(header)
        selectionLabel.font = .systemFont(ofSize: 11, weight: .medium); selectionLabel.textColor = NSColor(hex: "A8B1C0"); selectionLabel.lineBreakMode = .byTruncatingMiddle; root.addArrangedSubview(selectionLabel)

        tabs.target = self; tabs.action = #selector(tabChanged); tabs.selectSegment(withTag: 0); tabs.segmentCount = 6
        for index in 0..<6 { tabs.setLabel(["Nodes", "Primaries", "Curves", "Qualifier", "Scopes", "LUT"][index], forSegment: index); tabs.setTag(index, forSegment: index) }
        root.addArrangedSubview(tabs)

        contentStack.orientation = .vertical; contentStack.alignment = .width; contentStack.spacing = 0; contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(contentStack); contentStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        tabViews = [makeNodesView(), makePrimariesView(), makeCurvesView(), makeQualifierView(), makeScopesView(), makeLUTView()]
        tabViews.forEach { contentStack.addArrangedSubview($0); $0.isHidden = true }
        tabViews[0].isHidden = false

        let actions = NSStackView(); actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 8
        let revert = advancedButton("Revert Preview", #selector(revertPreview)); let apply = advancedButton("Apply to Selected Clips", #selector(apply)); apply.contentTintColor = .systemOrange; let reset = advancedButton("Reset", #selector(reset))
        actions.addArrangedSubview(revert); actions.addArrangedSubview(apply); actions.addArrangedSubview(reset); actions.addArrangedSubview(NSView()); root.addArrangedSubview(actions)
    }

    func load(_ values: ColorControlValues, selectionName: String, isEnabled: Bool = true) {
        baseValues = values; nodes = values.gradeNodes; selectedLUT = values.cubeLUT; currentSelectionName = selectionName; hasVideoSelection = isEnabled
        // Projects from before the node stack stored their three-way wheels
        // directly on the clip. Present those corrections as one editable node
        // so opening the new workspace never appears to lose a grade.
        if nodes.isEmpty && (values.lift != .init() || values.midtones != .init() || values.gain != .init()) {
            var legacy = GradeNode(name: "Legacy three-way grade")
            legacy.lift = values.lift; legacy.gamma = values.midtones; legacy.gain = values.gain
            nodes = [legacy]
            baseValues.lift = .init(); baseValues.midtones = .init(); baseValues.gain = .init()
        }
        selectionLabel.stringValue = "Selected: \(selectionName)"
        baseExposure.doubleValue = values.exposure; baseContrast.doubleValue = values.contrast; baseSaturation.doubleValue = values.saturation; baseTemperature.doubleValue = values.temperature; baseTint.doubleValue = values.tint; baseVibrance.doubleValue = values.vibrance
        if nodes.isEmpty { selectedNodeIndex = nil } else { selectedNodeIndex = min(selectedNodeIndex ?? 0, nodes.count - 1) }
        updateNodeTable(); loadSelectedNodeControls(); updateEnabledState(); updateLUTLabel(); refreshScopes()
    }

    func updateScopeImage(_ image: CIImage?) { scopeImage = image; scopeView.image = image; scopeView.needsDisplay = true }
    func resetWheels() { liftPanel.load(.init()); gammaPanel.load(.init()); gainPanel.load(.init()) }
    func resetLUT() { selectedLUT = nil; updateLUTLabel() }

    // MARK: Node stack
    private func makeNodesView() -> NSView {
        let root = NSStackView(); root.orientation = .horizontal; root.alignment = .top; root.spacing = 12
        let side = NSStackView(); side.orientation = .vertical; side.alignment = .width; side.spacing = 7; side.wantsLayer = true; side.layer?.backgroundColor = NSColor(hex: "20252E").cgColor; side.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10); side.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let sideTitle = NSTextField(labelWithString: "GRADE NODES"); sideTitle.font = .systemFont(ofSize: 10, weight: .bold); sideTitle.textColor = NSColor(hex: "8FAEFF"); side.addArrangedSubview(sideTitle)
        nodeScroll.drawsBackground = false; nodeScroll.hasVerticalScroller = true; nodeScroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("gradeNode")); column.title = "Nodes"; nodeTable.addTableColumn(column); nodeTable.headerView = nil; nodeTable.backgroundColor = .clear; nodeTable.selectionHighlightStyle = .sourceList; nodeTable.rowSizeStyle = .medium; nodeTable.delegate = self; nodeTable.dataSource = self; nodeScroll.documentView = nodeTable; side.addArrangedSubview(nodeScroll)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 5; buttons.addArrangedSubview(advancedButton("+", #selector(addNode))); buttons.addArrangedSubview(advancedButton("Duplicate", #selector(duplicateNode))); buttons.addArrangedSubview(advancedButton("−", #selector(removeNode))); side.addArrangedSubview(buttons)
        let order = NSStackView(); order.orientation = .horizontal; order.spacing = 5; order.addArrangedSubview(advancedButton("↑", #selector(moveNodeUp))); order.addArrangedSubview(advancedButton("↓", #selector(moveNodeDown))); side.addArrangedSubview(order)
        root.addArrangedSubview(side)

        let editor = NSStackView(); editor.orientation = .vertical; editor.alignment = .width; editor.spacing = 9
        let heading = NSTextField(labelWithString: "SELECTED NODE"); heading.font = .systemFont(ofSize: 10, weight: .bold); heading.textColor = NSColor(hex: "8FAEFF"); editor.addArrangedSubview(heading)
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8; row.addArrangedSubview(nodeName); nodeName.target = self; nodeName.action = #selector(nodeNameChanged); row.addArrangedSubview(nodeEnabled); nodeEnabled.target = self; nodeEnabled.action = #selector(controlChanged); editor.addArrangedSubview(row)
        editor.addArrangedSubview(advancedSliderRow("Mix / opacity", nodeMix, #selector(controlChanged)))
        editor.addArrangedSubview(advancedSliderRow("Exposure", nodeExposure, #selector(controlChanged)))
        editor.addArrangedSubview(advancedSliderRow("Contrast", nodeContrast, #selector(controlChanged)))
        editor.addArrangedSubview(advancedSliderRow("Saturation", nodeSaturation, #selector(controlChanged)))
        editor.addArrangedSubview(advancedSliderRow("Hue shift", nodeHue, #selector(controlChanged)))
        let hint = NSTextField(wrappingLabelWithString: "Nodes are evaluated top-to-bottom. Add several grades for a non-destructive stack; disable a node to compare the look without deleting it."); hint.font = .systemFont(ofSize: 11); hint.textColor = NSColor(hex: "9AA5B5"); editor.addArrangedSubview(hint)
        let looks = NSStackView(); looks.orientation = .horizontal; looks.spacing = 6; GradeCreativeLook.allCases.forEach { look in let b = advancedButton(look.title, #selector(applyCreativeLook)); b.tag = GradeCreativeLook.allCases.firstIndex(of: look) ?? 0; looks.addArrangedSubview(b) }; editor.addArrangedSubview(looks)
        editor.addArrangedSubview(NSView()); root.addArrangedSubview(editor)
        return root
    }

    // MARK: Primaries and curves
    private func makePrimariesView() -> NSView {
        let document = NSStackView(); document.orientation = .vertical; document.alignment = .width; document.spacing = 10
        document.addArrangedSubview(advancedHeading("PRIMARY CONTROLS", "Base controls remain compatible with older NetVista projects."))
        let base = NSStackView(); base.orientation = .horizontal; base.alignment = .top; base.spacing = 14; base.distribution = .fillEqually
        base.addArrangedSubview(advancedSliderColumn([("Exposure", baseExposure), ("Contrast", baseContrast), ("Saturation", baseSaturation)])); base.addArrangedSubview(advancedSliderColumn([("Temperature", baseTemperature), ("Tint", baseTint), ("Vibrance", baseVibrance)])); document.addArrangedSubview(base)
        document.addArrangedSubview(advancedHeading("THREE-WAY WHEELS", "Select a grade node first; the wheel controls belong to that node."))
        let wheels = NSStackView(); wheels.orientation = .horizontal; wheels.alignment = .top; wheels.spacing = 10; wheels.distribution = .fillEqually; wheels.addArrangedSubview(liftPanel); wheels.addArrangedSubview(gammaPanel); wheels.addArrangedSubview(gainPanel); document.addArrangedSubview(wheels)
        [baseExposure, baseContrast, baseSaturation, baseTemperature, baseTint, baseVibrance].forEach { $0.target = self; $0.action = #selector(controlChanged); $0.isContinuous = true }
        liftPanel.onChange = { [weak self] in self?.wheelChanged() }; gammaPanel.onChange = { [weak self] in self?.wheelChanged() }; gainPanel.onChange = { [weak self] in self?.wheelChanged() }
        return advancedScroll(document)
    }

    private func makeCurvesView() -> NSView {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .width; root.spacing = 10
        root.addArrangedSubview(advancedHeading("CURVES", "Drag points on the graph. RGB, hue and luma curves are evaluated by the same native renderer used for export."))
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8; row.addArrangedSubview(NSTextField(labelWithString: "CURVE")); ["Master", "Red", "Green", "Blue", "Hue vs Hue", "Hue vs Sat", "Hue vs Lum", "Luma vs Sat"].forEach { curvePicker.addItem(withTitle: $0) }; curvePicker.target = self; curvePicker.action = #selector(curveSelectionChanged); row.addArrangedSubview(curvePicker); row.addArrangedSubview(NSView()); row.addArrangedSubview(advancedButton("Reset curve", #selector(resetCurve))); root.addArrangedSubview(row)
        curveView.onChange = { [weak self] curve in self?.curveChanged(curve) }; curveView.heightAnchor.constraint(equalToConstant: 430).isActive = true; root.addArrangedSubview(curveView)
        let hint = NSTextField(wrappingLabelWithString: "Tip: add a point by clicking the curve, then drag it. The curve is stored in the selected node and survives project saves."); hint.font = .systemFont(ofSize: 11); hint.textColor = NSColor(hex: "9AA5B5"); root.addArrangedSubview(hint); root.addArrangedSubview(NSView()); return root
    }

    private func makeQualifierView() -> NSView {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .width; root.spacing = 10; root.addArrangedSubview(advancedHeading("HSL QUALIFIER / SECONDARY", "Isolate a hue, saturation and luminance range. Qualifier softness keeps edges natural."))
        qualifierEnabled.target = self; qualifierEnabled.action = #selector(controlChanged); qualifierInverted.target = self; qualifierInverted.action = #selector(controlChanged); root.addArrangedSubview(qualifierEnabled); root.addArrangedSubview(qualifierInverted)
        let grid = NSStackView(); grid.orientation = .vertical; grid.alignment = .width; grid.spacing = 8
        grid.addArrangedSubview(advancedSliderRow("Hue center", qualifierHue, #selector(controlChanged))); grid.addArrangedSubview(advancedSliderRow("Hue width", qualifierWidth, #selector(controlChanged))); grid.addArrangedSubview(advancedSliderRow("Saturation minimum", qualifierSatMin, #selector(controlChanged))); grid.addArrangedSubview(advancedSliderRow("Saturation maximum", qualifierSatMax, #selector(controlChanged))); grid.addArrangedSubview(advancedSliderRow("Luminance minimum", qualifierLumMin, #selector(controlChanged))); grid.addArrangedSubview(advancedSliderRow("Luminance maximum", qualifierLumMax, #selector(controlChanged))); grid.addArrangedSubview(advancedSliderRow("Edge softness", qualifierSoftness, #selector(controlChanged))); root.addArrangedSubview(grid); root.addArrangedSubview(NSView()); return advancedScroll(root)
    }

    private func makeScopesView() -> NSView {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .width; root.spacing = 10; root.addArrangedSubview(advancedHeading("SCOPES", "Scopes use the current source frame when available, so adjustments can be judged objectively.")); scopeTabs.target = self; scopeTabs.action = #selector(scopeChanged); scopeTabs.selectSegment(withTag: 0); root.addArrangedSubview(scopeTabs); scopeView.mode = 0; scopeView.heightAnchor.constraint(equalToConstant: 500).isActive = true; root.addArrangedSubview(scopeView); root.addArrangedSubview(NSView()); return root
    }

    private func makeLUTView() -> NSView {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .width; root.spacing = 10; root.addArrangedSubview(advancedHeading("LUT LAB", "Export the current node stack as a portable .cube LUT, or import a LUT as a legacy creative stage."))
        let card = NSStackView(); card.orientation = .vertical; card.alignment = .width; card.spacing = 8; card.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14); card.wantsLayer = true; card.layer?.backgroundColor = NSColor(hex: "212731").cgColor; card.layer?.cornerRadius = 10
        let top = NSStackView(); top.orientation = .horizontal; top.alignment = .centerY; top.spacing = 8; top.addArrangedSubview(lutName); top.addArrangedSubview(NSView()); top.addArrangedSubview(advancedButton("Import .cube…", #selector(importLUT))); card.addArrangedSubview(top)
        card.addArrangedSubview(advancedSliderRow("Imported LUT mix", lutStrength, #selector(lutChanged)))
        let exportRow = NSStackView(); exportRow.orientation = .horizontal; exportRow.alignment = .centerY; exportRow.spacing = 8; exportRow.addArrangedSubview(NSTextField(labelWithString: "Export size")); ["17³", "33³", "65³"].forEach { lutDimension.addItem(withTitle: $0) }; lutDimension.selectItem(at: 1); exportRow.addArrangedSubview(lutDimension); exportRow.addArrangedSubview(advancedButton("Export current nodes…", #selector(exportLUT))); exportRow.addArrangedSubview(advancedButton("Remove imported LUT", #selector(removeLUT))); card.addArrangedSubview(exportRow); root.addArrangedSubview(card); root.addArrangedSubview(NSView()); return root
    }

    // MARK: Actions/state
    @objc private func tabChanged() { let index = max(0, tabs.selectedSegment); for (i, view) in tabViews.enumerated() { view.isHidden = i != index } }
    @objc private func addNode() { nodes.append(GradeNode(id: UUID(), name: "Grade \(nodes.count + 1)")); selectedNodeIndex = nodes.count - 1; updateNodeTable(); loadSelectedNodeControls(); controlChanged() }
    @objc private func duplicateNode() { guard let index = selectedNodeIndex, nodes.indices.contains(index) else { return }; var copy = nodes[index]; copy.id = UUID(); copy.name += " copy"; nodes.insert(copy, at: index + 1); selectedNodeIndex = index + 1; updateNodeTable(); loadSelectedNodeControls(); controlChanged() }
    @objc private func removeNode() { guard let index = selectedNodeIndex, nodes.indices.contains(index) else { return }; nodes.remove(at: index); selectedNodeIndex = nodes.isEmpty ? nil : min(index, nodes.count - 1); updateNodeTable(); loadSelectedNodeControls(); controlChanged() }
    @objc private func moveNodeUp() { guard let index = selectedNodeIndex, index > 0 else { return }; nodes.swapAt(index, index - 1); selectedNodeIndex = index - 1; updateNodeTable(); controlChanged() }
    @objc private func moveNodeDown() { guard let index = selectedNodeIndex, index + 1 < nodes.count else { return }; nodes.swapAt(index, index + 1); selectedNodeIndex = index + 1; updateNodeTable(); controlChanged() }
    @objc private func nodeNameChanged() { guard let index = selectedNodeIndex, nodes.indices.contains(index) else { return }; nodes[index].name = nodeName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Grade" : nodeName.stringValue; updateNodeTable(); controlChanged() }
    @objc private func controlChanged() { guard let index = selectedNodeIndex, nodes.indices.contains(index) else { preview(); return }; nodes[index].enabled = nodeEnabled.state == .on; nodes[index].mix = nodeMix.doubleValue; nodes[index].exposure = nodeExposure.doubleValue; nodes[index].contrast = nodeContrast.doubleValue; nodes[index].saturation = nodeSaturation.doubleValue; nodes[index].hueShift = nodeHue.doubleValue; var qualifier = nodes[index].qualifier; qualifier.enabled = qualifierEnabled.state == .on; qualifier.inverted = qualifierInverted.state == .on; qualifier.hueCenter = qualifierHue.doubleValue; qualifier.hueWidth = qualifierWidth.doubleValue; qualifier.saturationMin = min(qualifierSatMin.doubleValue, qualifierSatMax.doubleValue); qualifier.saturationMax = max(qualifierSatMin.doubleValue, qualifierSatMax.doubleValue); qualifier.luminanceMin = min(qualifierLumMin.doubleValue, qualifierLumMax.doubleValue); qualifier.luminanceMax = max(qualifierLumMin.doubleValue, qualifierLumMax.doubleValue); qualifier.softness = qualifierSoftness.doubleValue; nodes[index].qualifier = qualifier; preview() }
    private func wheelChanged() { guard let index = selectedNodeIndex, nodes.indices.contains(index) else { return }; nodes[index].lift = liftPanel.value; nodes[index].gamma = gammaPanel.value; nodes[index].gain = gainPanel.value; preview() }
    @objc private func curveSelectionChanged() { curveKind = max(0, curvePicker.indexOfSelectedItem); curveView.curve = selectedNode.map { self.curve(for: $0) } ?? .identity }
    private func curve(for node: GradeNode) -> GradeCurve { switch curveKind { case 1: return node.curves.red; case 2: return node.curves.green; case 3: return node.curves.blue; case 4: return node.curves.hueVsHue; case 5: return node.curves.hueVsSat; case 6: return node.curves.hueVsLum; case 7: return node.curves.lumaVsSat; default: return node.curves.master } }
    private func setCurve(_ curve: GradeCurve, on node: inout GradeNode) { switch curveKind { case 1: node.curves.red = curve; case 2: node.curves.green = curve; case 3: node.curves.blue = curve; case 4: node.curves.hueVsHue = curve; case 5: node.curves.hueVsSat = curve; case 6: node.curves.hueVsLum = curve; case 7: node.curves.lumaVsSat = curve; default: node.curves.master = curve } }
    private func curveChanged(_ curve: GradeCurve) { guard let index = selectedNodeIndex, nodes.indices.contains(index) else { return }; setCurve(curve, on: &nodes[index]); preview() }
    @objc private func resetCurve() { curveView.curve = .identity; curveChanged(.identity) }
    @objc private func applyCreativeLook(_ sender: NSButton) { guard GradeCreativeLook.allCases.indices.contains(sender.tag) else { return }; let look = GradeCreativeLook.allCases[sender.tag]; if selectedNodeIndex == nil { nodes.append(look.node()); selectedNodeIndex = nodes.count - 1 } else if let index = selectedNodeIndex { nodes[index] = look.node() }; updateNodeTable(); loadSelectedNodeControls(); controlChanged() }
    @objc private func scopeChanged() { scopeView.mode = scopeTabs.selectedSegment; scopeView.needsDisplay = true }
    @objc private func bypassChanged() { preview() }
    @objc private func lutChanged() { guard var lut = selectedLUT else { return }; lut.strength = lutStrength.doubleValue; selectedLUT = lut; updateLUTLabel(); preview() }
    @objc private func importLUT() { let panel = NSOpenPanel(); panel.title = "Import 3D LUT"; panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]; panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first; guard panel.runModal() == .OK, let url = panel.url else { return }; do { selectedLUT = try ClipLUTSettings(embeddingFileAt: url, strength: lutStrength.doubleValue); updateLUTLabel(); preview() } catch { NSAlert(error: error).runModal() } }
    @objc private func removeLUT() { selectedLUT = nil; updateLUTLabel(); preview() }
    @objc private func exportLUT() { guard hasVideoSelection else { return }; let index = lutDimension.indexOfSelectedItem; let size = [17, 33, 65].indices.contains(index) ? [17, 33, 65][index] : 33; onExportLUT?(nodes, size) }
    @objc private func preview() { guard hasVideoSelection else { return }; onPreview?(bypass.state == .on ? ColorControlValues() : values()) }
    @objc private func apply() { guard hasVideoSelection else { return }; bypass.state = .off; onApply?(values()) }
    @objc private func revertPreview() { guard hasVideoSelection else { return }; if let saved = onRequestSavedValues?() { load(saved, selectionName: currentSelectionName, isEnabled: true) }; onCancelPreview?() }
    @objc private func reset() { guard hasVideoSelection else { return }; baseValues = ColorControlValues(); nodes = []; selectedNodeIndex = nil; selectedLUT = nil; updateNodeTable(); loadSelectedNodeControls(); preview() }

    private func values() -> ColorControlValues { var output = baseValues; output.exposure = baseExposure.doubleValue; output.contrast = baseContrast.doubleValue; output.saturation = baseSaturation.doubleValue; output.temperature = baseTemperature.doubleValue; output.tint = baseTint.doubleValue; output.vibrance = baseVibrance.doubleValue; output.lift = baseValues.lift; output.midtones = baseValues.midtones; output.gain = baseValues.gain; output.cubeLUT = selectedLUT; output.gradeNodes = nodes; return output }
    private func updateNodeTable() { nodeTable.reloadData(); if let index = selectedNodeIndex, nodes.indices.contains(index) { nodeTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) } }
    private func loadSelectedNodeControls() {
        guard let node = selectedNode else {
            nodeName.isEnabled = false; nodeEnabled.isEnabled = false
            nodeName.stringValue = "No grade node selected"; nodeEnabled.state = .off
            nodeMix.doubleValue = 1; nodeExposure.doubleValue = 0; nodeContrast.doubleValue = 1; nodeSaturation.doubleValue = 1; nodeHue.doubleValue = 0
            liftPanel.load(.init()); gammaPanel.load(.init()); gainPanel.load(.init())
            qualifierEnabled.state = .off; qualifierInverted.state = .off; qualifierHue.doubleValue = 60; qualifierWidth.doubleValue = 60; qualifierSatMin.doubleValue = 0; qualifierSatMax.doubleValue = 1; qualifierLumMin.doubleValue = 0; qualifierLumMax.doubleValue = 1; qualifierSoftness.doubleValue = 0.18
            curveView.curve = .identity
            return
        }
        nodeName.isEnabled = true; nodeName.stringValue = node.name; nodeEnabled.isEnabled = true; nodeEnabled.state = node.enabled ? .on : .off; nodeMix.doubleValue = node.mix; nodeExposure.doubleValue = node.exposure; nodeContrast.doubleValue = node.contrast; nodeSaturation.doubleValue = node.saturation; nodeHue.doubleValue = node.hueShift; liftPanel.load(node.lift); gammaPanel.load(node.gamma); gainPanel.load(node.gain); let q = node.qualifier; qualifierEnabled.state = q.enabled ? .on : .off; qualifierInverted.state = q.inverted ? .on : .off; qualifierHue.doubleValue = q.hueCenter; qualifierWidth.doubleValue = q.hueWidth; qualifierSatMin.doubleValue = q.saturationMin; qualifierSatMax.doubleValue = q.saturationMax; qualifierLumMin.doubleValue = q.luminanceMin; qualifierLumMax.doubleValue = q.luminanceMax; qualifierSoftness.doubleValue = q.softness; curveView.curve = curve(for: node)
    }
    private func updateEnabledState() { let controls: [NSControl] = [tabs, bypass, baseExposure, baseContrast, baseSaturation, baseTemperature, baseTint, baseVibrance, curvePicker, qualifierEnabled, qualifierInverted, qualifierHue, qualifierWidth, qualifierSatMin, qualifierSatMax, qualifierLumMin, qualifierLumMax, qualifierSoftness, lutStrength, lutDimension]; controls.forEach { $0.isEnabled = hasVideoSelection }; nodeTable.isEnabled = hasVideoSelection; updateNodeTable() }
    private func updateLUTLabel() { if let lut = selectedLUT { lutName.stringValue = "Imported: \(lut.fileURL.lastPathComponent) • \(Int(lut.strength * 100))%"; lutStrength.doubleValue = lut.strength } else { lutName.stringValue = "No imported LUT"; lutStrength.doubleValue = 1 } }
    private func refreshScopes() { updateScopeImage(onRequestScopeImage?()) }

    // MARK: Table view
    func numberOfRows(in tableView: NSTableView) -> Int { nodes.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { let cell = NSTableCellView(); let label = NSTextField(labelWithString: "\(nodes[row].enabled ? "●" : "○")  \(nodes[row].name)"); label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = nodes[row].enabled ? .white : .secondaryLabelColor; cell.addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]); return cell }
    func tableViewSelectionDidChange(_ notification: Notification) { let index = nodeTable.selectedRow; guard nodes.indices.contains(index) else { return }; selectedNodeIndex = index; loadSelectedNodeControls(); updateNodeTable() }

    private func advancedHeading(_ title: String, _ subtitle: String) -> NSView { let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3; let h = NSTextField(labelWithString: title); h.font = .systemFont(ofSize: 10, weight: .bold); h.textColor = NSColor(hex: "8FAEFF"); let s = NSTextField(labelWithString: subtitle); s.font = .systemFont(ofSize: 11); s.textColor = NSColor(hex: "9AA5B5"); stack.addArrangedSubview(h); stack.addArrangedSubview(s); return stack }
    private func advancedSliderRow(_ title: String, _ slider: NSSlider, _ action: Selector) -> NSView { let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 3; let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; let label = NSTextField(labelWithString: title.uppercased()); label.font = .systemFont(ofSize: 9, weight: .bold); label.textColor = NSColor(hex: "C0C7D1"); row.addArrangedSubview(label); row.addArrangedSubview(NSView()); let value = NSTextField(labelWithString: ""); value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); value.alignment = .right; value.textColor = .white; row.addArrangedSubview(value); slider.target = self; slider.action = action; slider.isContinuous = true; slider.toolTip = title; stack.addArrangedSubview(row); stack.addArrangedSubview(slider); return stack }
    private func advancedSliderColumn(_ controls: [(String, NSSlider)]) -> NSView { let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 8; controls.forEach { stack.addArrangedSubview(advancedSliderRow($0.0, $0.1, #selector(controlChanged))) }; return stack }
    private func advancedScroll(_ document: NSView) -> NSScrollView { let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), document.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor), document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)]); return scroll }
    private func advancedButton(_ title: String, _ action: Selector) -> NSButton { let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 11, weight: .medium); return button }
}

final class GradeCurveEditorView: NSView {
    var curve: GradeCurve = .identity { didSet { needsDisplay = true } }
    var onChange: ((GradeCurve) -> Void)?
    private var activePoint: Int?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; layer?.backgroundColor = NSColor(hex: "11151B").cgColor; layer?.cornerRadius = 9; layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor; layer?.borderWidth = 1 }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect); let inset: CGFloat = 34; let graph = bounds.insetBy(dx: inset, dy: inset); NSColor(hex: "1C222B").setFill(); graph.fill(); NSColor.white.withAlphaComponent(0.08).setStroke(); for i in 0...10 { let x = graph.minX + graph.width * CGFloat(i) / 10; let y = graph.minY + graph.height * CGFloat(i) / 10; let path = NSBezierPath(); path.move(to: NSPoint(x: x, y: graph.minY)); path.line(to: NSPoint(x: x, y: graph.maxY)); path.move(to: NSPoint(x: graph.minX, y: y)); path.line(to: NSPoint(x: graph.maxX, y: y)); path.stroke() }; let line = NSBezierPath(); let points = GradeCurve.sanitized(curve.points); for (i, point) in points.enumerated() { let p = map(point, graph); if i == 0 { line.move(to: p) } else { line.line(to: p) } }; NSColor.systemBlue.setStroke(); line.lineWidth = 2.5; line.stroke(); for (i, point) in points.enumerated() { let p = map(point, graph); let radius: CGFloat = i == activePoint ? 7 : 5; NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)).fill(); NSColor.systemBlue.setStroke(); NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)).stroke() } }
    override func mouseDown(with event: NSEvent) { let graph = bounds.insetBy(dx: 34, dy: 34); let point = convert(event.locationInWindow, from: nil); let values = GradeCurve.sanitized(curve.points); activePoint = values.enumerated().min { distance(map($0.element, graph), point) < distance(map($1.element, graph), point) }?.offset; if let index = activePoint, distance(map(values[index], graph), point) > 18 { activePoint = nil }; if activePoint == nil { let created = GradeCurvePoint(x: Double((point.x - graph.minX) / graph.width), y: Double((point.y - graph.minY) / graph.height)); var next = values + [created]; next = GradeCurve.sanitized(next); activePoint = next.firstIndex { abs($0.x - created.x) < 0.012 && abs($0.y - created.y) < 0.012 }; curve = GradeCurve(points: next) }; update(with: point, graph: graph) }
    override func mouseDragged(with event: NSEvent) { update(with: convert(event.locationInWindow, from: nil), graph: bounds.insetBy(dx: 34, dy: 34)) }
    private func update(with point: NSPoint, graph: CGRect) { guard let index = activePoint else { return }; var points = GradeCurve.sanitized(curve.points); guard points.indices.contains(index) else { return }; let x = min(1, max(0, Double((point.x - graph.minX) / graph.width))); let y = min(1, max(0, Double((point.y - graph.minY) / graph.height))); if index == 0 { points[index].x = 0 } else if index == points.count - 1 { points[index].x = 1 } else { points[index].x = x }; points[index].y = y; curve = GradeCurve(points: points); onChange?(curve) }
    private func map(_ point: GradeCurvePoint, _ rect: CGRect) -> NSPoint { NSPoint(x: rect.minX + CGFloat(point.x) * rect.width, y: rect.minY + CGFloat(point.y) * rect.height) }
    private func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

final class GradeScopeView: NSView {
    var mode = 0 { didSet { needsDisplay = true } }
    var image: CIImage? { didSet { cachedPixels = nil; needsDisplay = true } }
    private var cachedPixels: [UInt8]?
    private var cachedSize = CGSize.zero
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; layer?.backgroundColor = NSColor(hex: "11151B").cgColor; layer?.cornerRadius = 9 }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { let graph = bounds.insetBy(dx: 26, dy: 24); NSColor(hex: "11151B").setFill(); bounds.fill(); NSColor.white.withAlphaComponent(0.08).setStroke(); for i in 0...10 { let x = graph.minX + graph.width * CGFloat(i) / 10; let y = graph.minY + graph.height * CGFloat(i) / 10; let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: graph.minY)); p.line(to: NSPoint(x: x, y: graph.maxY)); p.move(to: NSPoint(x: graph.minX, y: y)); p.line(to: NSPoint(x: graph.maxX, y: y)); p.stroke() }; let samples = pixels(); if samples.isEmpty { let label = NSTextField(labelWithString: "Scope preview appears when a source frame is available"); label.textColor = .secondaryLabelColor; label.alignment = .center; label.frame = graph; label.draw(graph); return }; switch mode { case 1: drawParade(samples, graph); case 2: drawHistogram(samples, graph); case 3: drawVectorscope(samples, graph); default: drawWaveform(samples, graph) } }
    private func pixels() -> [UInt8] { if let cachedPixels { return cachedPixels }; guard let image else { return [] }; let size = CGSize(width: min(320, max(1, image.extent.width)), height: min(180, max(1, image.extent.height))); var data = [UInt8](repeating: 0, count: Int(size.width * size.height * 4)); let context = CIContext(options: [.workingColorSpace: NSNull()]); guard let cg = context.createCGImage(image, from: image.extent), let provider = cg.dataProvider, let raw = provider.data as Data? else { return [] }; data = [UInt8](raw); cachedPixels = data; cachedSize = size; return data }
    private func drawWaveform(_ data: [UInt8], _ rect: CGRect) { let path = NSBezierPath(); let columns = 180; for x in 0..<columns { var low = 1.0, high = 0.0; stride(from: x * 4, to: data.count, by: columns * 4).forEach { i in guard i + 2 < data.count else { return }; let l = (0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])) / 255; low = min(low, l); high = max(high, l) }; let px = rect.minX + rect.width * CGFloat(x) / CGFloat(columns - 1); path.move(to: NSPoint(x: px, y: rect.minY + rect.height * CGFloat(low))); path.line(to: NSPoint(x: px, y: rect.minY + rect.height * CGFloat(high)))}; NSColor.systemGreen.withAlphaComponent(0.75).setStroke(); path.stroke() }
    private func drawParade(_ data: [UInt8], _ rect: CGRect) { let colors: [NSColor] = [.systemRed, .systemGreen, .systemBlue]; for channel in 0..<3 { let sub = CGRect(x: rect.minX + rect.width * CGFloat(channel) / 3, y: rect.minY, width: rect.width / 3, height: rect.height); let path = NSBezierPath(); for x in 0..<60 { var low = 1.0, high = 0.0; stride(from: x * 4 + channel, to: data.count, by: 60 * 4).forEach { i in guard i < data.count else { return }; let value = Double(data[i]) / 255; low = min(low, value); high = max(high, value) }; let px = sub.minX + sub.width * CGFloat(x) / 59; path.move(to: NSPoint(x: px, y: sub.minY + sub.height * CGFloat(low))); path.line(to: NSPoint(x: px, y: sub.minY + sub.height * CGFloat(high)))}; colors[channel].withAlphaComponent(0.75).setStroke(); path.stroke() } }
    private func drawHistogram(_ data: [UInt8], _ rect: CGRect) { var counts = [Int](repeating: 0, count: 64); for i in stride(from: 0, to: data.count - 2, by: 4) { let l = Int((0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])) / 256 * 64); counts[min(63, max(0, l))] += 1 }; let maxCount = max(1, counts.max() ?? 1); let path = NSBezierPath(); for i in counts.indices { let x = rect.minX + rect.width * CGFloat(i) / 63; path.move(to: NSPoint(x: x, y: rect.minY)); path.line(to: NSPoint(x: x, y: rect.minY + rect.height * CGFloat(counts[i]) / CGFloat(maxCount))) }; NSColor.systemOrange.withAlphaComponent(0.75).setStroke(); path.stroke() }
    private func drawVectorscope(_ data: [UInt8], _ rect: CGRect) { let centre = NSPoint(x: rect.midX, y: rect.midY); let radius = min(rect.width, rect.height) * 0.42; NSColor.systemGreen.withAlphaComponent(0.7).setStroke(); NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)).stroke(); let dots = stride(from: 0, to: data.count - 2, by: max(4, data.count / 2500)); for i in dots { let r = Double(data[i]) / 255, g = Double(data[i + 1]) / 255, b = Double(data[i + 2]) / 255; let x = (r - b) * 0.7, y = (2 * g - r - b) * 0.4; let p = NSPoint(x: centre.x + CGFloat(x) * radius, y: centre.y + CGFloat(y) * radius); NSColor(calibratedRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 0.55).setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)).fill() } }
}
