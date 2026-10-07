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
    private var numericFields: [ObjectIdentifier: (slider: NSSlider, field: NSTextField)] = [:]
    private var numericSliders: [ObjectIdentifier: NSSlider] = [:]
    private var actionButtons: [(button: NSButton, selector: Selector)] = []
    private var isUpdatingNodeTable = false
    private let nodeContextLabel = NSTextField(labelWithString: "Add a grade node to use wheels, curves and qualifiers")

    private var selectedNode: GradeNode? {
        guard let index = selectedNodeIndex, nodes.indices.contains(index) else { return nil }
        return nodes[index]
    }

    var currentValues: ColorControlValues { values() }

    override func loadView() {
        baseExposure.identifier = NSUserInterfaceItemIdentifier("colour-base-exposure")
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1120, height: 820))
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        StudioTheme.shared.register(view, as: .workspace)

        let root = NSStackView(); root.orientation = .vertical; root.alignment = .width; root.spacing = 10; root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), root.topAnchor.constraint(equalTo: view.topAnchor, constant: 14), root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)])

        root.addArrangedSubview(StudioWorkspaceUI.header(title: "Colour Controls", selection: selectionLabel))

        tabs.target = self; tabs.action = #selector(tabChanged); tabs.selectSegment(withTag: 0); tabs.segmentCount = 6
        for index in 0..<6 { tabs.setLabel(["Nodes", "Primaries", "Curves", "Qualifier", "Scopes", "LUT"][index], forSegment: index); tabs.setTag(index, forSegment: index) }
        tabs.identifier = NSUserInterfaceItemIdentifier("colour-workspace-tabs")
        let navigation = NSStackView(); navigation.orientation = .horizontal; navigation.alignment = .centerY; navigation.spacing = 8
        navigation.addArrangedSubview(tabs); navigation.addArrangedSubview(NSView())
        bypass.target = self; bypass.action = #selector(bypassChanged); navigation.addArrangedSubview(bypass)
        root.addArrangedSubview(StudioWorkspaceUI.toolbar(navigation))
        let context = NSStackView(); context.orientation = .horizontal; context.alignment = .centerY; context.spacing = 8
        nodeContextLabel.font = .systemFont(ofSize: 11); StudioTheme.shared.register(nodeContextLabel, as: .secondaryText)
        nodeContextLabel.lineBreakMode = .byTruncatingTail; nodeContextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.addArrangedSubview(nodeContextLabel); context.addArrangedSubview(NSView())
        context.addArrangedSubview(advancedButton("+ Grade Node", #selector(addNode)))
        root.addArrangedSubview(context)

        contentStack.orientation = .vertical; contentStack.alignment = .width; contentStack.spacing = 0; contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(contentStack); contentStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        contentStack.setContentHuggingPriority(.defaultLow, for: .vertical)
        tabViews = [makeNodesView(), makePrimariesView(), makeCurvesView(), makeQualifierView(), makeScopesView(), makeLUTView()]
        tabViews.forEach { contentStack.addArrangedSubview($0); $0.isHidden = true }
        tabViews[0].isHidden = false

        let revert = advancedButton("Revert Preview", #selector(revertPreview)); let apply = advancedButton("Apply to Selected Clips", #selector(apply)); StudioTheme.shared.register(apply, as: .accentControl); let reset = advancedButton("Reset Grade", #selector(reset))
        root.addArrangedSubview(StudioWorkspaceUI.footer(note: "Changes preview immediately. Apply saves the complete grade to all selected clips; Revert restores the saved grade.", buttons: [revert, reset, apply]))
        StudioWorkspaceUI.alignContent(root)
        updateEnabledState(); refreshNumericFields()
    }

    func load(_ values: ColorControlValues, selectionName: String, isEnabled: Bool = true) {
        baseValues = values; nodes = values.gradeNodes; selectedLUT = values.cubeLUT; currentSelectionName = selectionName; hasVideoSelection = isEnabled; bypass.state = .off
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
        updateNodeTable(); loadSelectedNodeControls(); updateEnabledState(); updateLUTLabel(); refreshNumericFields(); refreshScopes()
    }

    func updateScopeImage(_ image: CIImage?) { scopeImage = image; scopeView.image = image; scopeView.needsDisplay = true }
    func resetWheels() { liftPanel.load(.init()); gammaPanel.load(.init()); gainPanel.load(.init()) }
    func resetLUT() { selectedLUT = nil; updateLUTLabel() }

    // MARK: Node stack
    private func makeNodesView() -> NSView {
        let root = NSStackView(); root.orientation = .horizontal; root.alignment = .top; root.spacing = 12
        let side = NSStackView(); side.orientation = .vertical; side.alignment = .width; side.spacing = 7; StudioWorkspaceUI.panel(side); side.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10); side.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let sideTitle = StudioWorkspaceUI.label("GRADE NODES", size: 11, weight: .semibold, secondary: false); side.addArrangedSubview(sideTitle)
        nodeScroll.drawsBackground = false; nodeScroll.hasVerticalScroller = true; nodeScroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("gradeNode")); column.title = "Nodes"; nodeTable.addTableColumn(column); nodeTable.headerView = nil; nodeTable.backgroundColor = .clear; nodeTable.selectionHighlightStyle = .sourceList; nodeTable.rowSizeStyle = .medium; nodeTable.delegate = self; nodeTable.dataSource = self; nodeScroll.documentView = nodeTable; side.addArrangedSubview(nodeScroll)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 5; buttons.addArrangedSubview(advancedButton("+", #selector(addNode))); buttons.addArrangedSubview(advancedButton("Duplicate", #selector(duplicateNode))); buttons.addArrangedSubview(advancedButton("−", #selector(removeNode))); side.addArrangedSubview(buttons)
        let order = NSStackView(); order.orientation = .horizontal; order.spacing = 5; order.addArrangedSubview(advancedButton("↑", #selector(moveNodeUp))); order.addArrangedSubview(advancedButton("↓", #selector(moveNodeDown))); side.addArrangedSubview(order)
        root.addArrangedSubview(side)
        side.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true

        let editor = StudioWorkspaceStack(); editor.orientation = .vertical; editor.alignment = .width; editor.spacing = 9; editor.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12); StudioWorkspaceUI.panel(editor, role: .card)
        let heading = StudioWorkspaceUI.label("SELECTED NODE", size: 11, weight: .semibold, secondary: false); editor.addArrangedSubview(heading)
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8; row.addArrangedSubview(nodeName); nodeName.target = self; nodeName.action = #selector(nodeNameChanged); row.addArrangedSubview(nodeEnabled); nodeEnabled.target = self; nodeEnabled.action = #selector(controlChanged); editor.addArrangedSubview(row)
        editor.addArrangedSubview(advancedSliderRow("Mix / opacity", nodeMix, #selector(controlChanged)))
        editor.addArrangedSubview(advancedSliderRow("Exposure", nodeExposure, #selector(controlChanged)))
        editor.addArrangedSubview(advancedSliderRow("Contrast", nodeContrast, #selector(controlChanged)))
        editor.addArrangedSubview(advancedSliderRow("Saturation", nodeSaturation, #selector(controlChanged)))
        editor.addArrangedSubview(advancedSliderRow("Hue shift", nodeHue, #selector(controlChanged)))
        let hint = NSTextField(wrappingLabelWithString: "Nodes are evaluated top-to-bottom. Add several grades for a non-destructive stack; disable a node to compare the look without deleting it."); hint.font = .systemFont(ofSize: 11); hint.textColor = NSColor(hex: "9AA5B5"); editor.addArrangedSubview(hint)
        editor.addArrangedSubview(advancedHeading("CREATIVE LOOKS", "Replace the selected node, or start a new one."))
        let cases = GradeCreativeLook.allCases
        for offset in stride(from: 0, to: cases.count, by: 3) {
            let looks = NSStackView(); looks.orientation = .horizontal; looks.spacing = 6; looks.distribution = .fillEqually
            for index in offset..<min(cases.count, offset + 3) { let b = advancedButton(cases[index].title, #selector(applyCreativeLook)); b.tag = index; looks.addArrangedSubview(b) }
            editor.addArrangedSubview(looks)
        }
        root.addArrangedSubview(advancedScroll(editor))
        return root
    }

    // MARK: Primaries and curves
    private func makePrimariesView() -> NSView {
        let document = StudioWorkspaceStack(); document.orientation = .vertical; document.alignment = .width; document.spacing = 12
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
        let root = StudioWorkspaceStack(); root.orientation = .vertical; root.alignment = .width; root.spacing = 10
        root.addArrangedSubview(advancedHeading("CURVES", "Drag points on the graph. RGB, hue and luma curves are evaluated by the same native renderer used for export."))
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8; row.addArrangedSubview(NSTextField(labelWithString: "CURVE")); ["Master", "Red", "Green", "Blue", "Hue vs Hue", "Hue vs Sat", "Hue vs Lum", "Luma vs Sat"].forEach { curvePicker.addItem(withTitle: $0) }; curvePicker.target = self; curvePicker.action = #selector(curveSelectionChanged); row.addArrangedSubview(curvePicker); row.addArrangedSubview(NSView()); row.addArrangedSubview(advancedButton("Reset curve", #selector(resetCurve))); root.addArrangedSubview(row)
        curveView.onChange = { [weak self] curve in self?.curveChanged(curve) }; curveView.heightAnchor.constraint(equalToConstant: 360).isActive = true; root.addArrangedSubview(curveView)
        let hint = NSTextField(wrappingLabelWithString: "Click to add a point, drag to adjust. Double-click an interior point to remove it. Curves belong to the selected grade node."); hint.font = .systemFont(ofSize: 11); hint.textColor = NSColor(hex: "9AA5B5"); root.addArrangedSubview(hint); return advancedScroll(root)
    }

    private func makeQualifierView() -> NSView {
        let root = StudioWorkspaceStack(); root.orientation = .vertical; root.alignment = .width; root.spacing = 10; root.addArrangedSubview(advancedHeading("HSL QUALIFIER / SECONDARY", "Isolate a hue, saturation and luminance range. Qualifier softness keeps edges natural."))
        qualifierEnabled.target = self; qualifierEnabled.action = #selector(controlChanged); qualifierInverted.target = self; qualifierInverted.action = #selector(controlChanged); root.addArrangedSubview(qualifierEnabled); root.addArrangedSubview(qualifierInverted)
        let grid = NSStackView(); grid.orientation = .vertical; grid.alignment = .width; grid.spacing = 8
        grid.addArrangedSubview(advancedSliderRow("Hue center", qualifierHue, #selector(controlChanged))); grid.addArrangedSubview(advancedSliderRow("Hue width", qualifierWidth, #selector(controlChanged))); grid.addArrangedSubview(advancedSliderRow("Saturation minimum", qualifierSatMin, #selector(controlChanged))); grid.addArrangedSubview(advancedSliderRow("Saturation maximum", qualifierSatMax, #selector(controlChanged))); grid.addArrangedSubview(advancedSliderRow("Luminance minimum", qualifierLumMin, #selector(controlChanged))); grid.addArrangedSubview(advancedSliderRow("Luminance maximum", qualifierLumMax, #selector(controlChanged))); grid.addArrangedSubview(advancedSliderRow("Edge softness", qualifierSoftness, #selector(controlChanged))); root.addArrangedSubview(grid); root.addArrangedSubview(NSView()); return advancedScroll(root)
    }

    private func makeScopesView() -> NSView {
        let root = StudioWorkspaceStack(); root.orientation = .vertical; root.alignment = .width; root.spacing = 10; root.addArrangedSubview(advancedHeading("SCOPES", "Scopes describe the current preview frame. Use the timeline to inspect another point.")); scopeTabs.target = self; scopeTabs.action = #selector(scopeChanged); scopeTabs.selectedSegment = 0; root.addArrangedSubview(scopeTabs); scopeView.mode = 0; scopeView.heightAnchor.constraint(equalToConstant: 380).isActive = true; root.addArrangedSubview(scopeView); return advancedScroll(root)
    }

    private func makeLUTView() -> NSView {
        let root = StudioWorkspaceStack(); root.orientation = .vertical; root.alignment = .width; root.spacing = 10; root.addArrangedSubview(advancedHeading("LUT LAB", "Export the current node stack as a portable .cube LUT. Base controls and an imported LUT are separate stages and are not included in that export."))
        let card = NSStackView(); card.orientation = .vertical; card.alignment = .width; card.spacing = 8; card.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14); StudioWorkspaceUI.panel(card, role: .card)
        let top = NSStackView(); top.orientation = .horizontal; top.alignment = .centerY; top.spacing = 8; top.addArrangedSubview(lutName); top.addArrangedSubview(NSView()); top.addArrangedSubview(advancedButton("Import .cube…", #selector(importLUT))); card.addArrangedSubview(top)
        card.addArrangedSubview(advancedSliderRow("Imported LUT mix", lutStrength, #selector(lutChanged)))
        let exportRow = NSStackView(); exportRow.orientation = .horizontal; exportRow.alignment = .centerY; exportRow.spacing = 8; exportRow.addArrangedSubview(NSTextField(labelWithString: "Export size")); ["17³", "33³", "65³"].forEach { lutDimension.addItem(withTitle: $0) }; lutDimension.selectItem(at: 1); exportRow.addArrangedSubview(lutDimension); exportRow.addArrangedSubview(advancedButton("Export current nodes…", #selector(exportLUT))); exportRow.addArrangedSubview(advancedButton("Remove imported LUT", #selector(removeLUT))); card.addArrangedSubview(StudioWorkspaceUI.toolbar(exportRow)); root.addArrangedSubview(card); return advancedScroll(root)
    }

    // MARK: Actions/state
    @objc private func tabChanged() { let index = max(0, tabs.selectedSegment); for (i, view) in tabViews.enumerated() { view.isHidden = i != index }; if index == 4 { refreshScopes() } }
    @objc private func addNode() { guard hasVideoSelection else { return }; nodes.append(GradeNode(id: UUID(), name: "Grade \(nodes.count + 1)")); selectedNodeIndex = nodes.count - 1; updateNodeTable(); loadSelectedNodeControls(); preview() }
    @objc private func duplicateNode() { guard let index = selectedNodeIndex, nodes.indices.contains(index) else { return }; var copy = nodes[index]; copy.id = UUID(); copy.name += " copy"; nodes.insert(copy, at: index + 1); selectedNodeIndex = index + 1; updateNodeTable(); loadSelectedNodeControls(); controlChanged() }
    @objc private func removeNode() { guard let index = selectedNodeIndex, nodes.indices.contains(index) else { return }; nodes.remove(at: index); selectedNodeIndex = nodes.isEmpty ? nil : min(index, nodes.count - 1); updateNodeTable(); loadSelectedNodeControls(); controlChanged() }
    @objc private func moveNodeUp() { guard let index = selectedNodeIndex, index > 0 else { return }; nodes.swapAt(index, index - 1); selectedNodeIndex = index - 1; updateNodeTable(); loadSelectedNodeControls(); preview() }
    @objc private func moveNodeDown() { guard let index = selectedNodeIndex, index + 1 < nodes.count else { return }; nodes.swapAt(index, index + 1); selectedNodeIndex = index + 1; updateNodeTable(); loadSelectedNodeControls(); preview() }
    @objc private func nodeNameChanged() { guard let index = selectedNodeIndex, nodes.indices.contains(index) else { return }; nodes[index].name = nodeName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Grade" : nodeName.stringValue; updateNodeTable(); controlChanged() }
    @objc private func controlChanged() { refreshNumericFields(); guard let index = selectedNodeIndex, nodes.indices.contains(index) else { preview(); return }; nodes[index].enabled = nodeEnabled.state == .on; nodes[index].mix = nodeMix.doubleValue; nodes[index].exposure = nodeExposure.doubleValue; nodes[index].contrast = nodeContrast.doubleValue; nodes[index].saturation = nodeSaturation.doubleValue; nodes[index].hueShift = nodeHue.doubleValue; var qualifier = nodes[index].qualifier; qualifier.enabled = qualifierEnabled.state == .on; qualifier.inverted = qualifierInverted.state == .on; qualifier.hueCenter = qualifierHue.doubleValue; qualifier.hueWidth = qualifierWidth.doubleValue; qualifier.saturationMin = min(qualifierSatMin.doubleValue, qualifierSatMax.doubleValue); qualifier.saturationMax = max(qualifierSatMin.doubleValue, qualifierSatMax.doubleValue); qualifier.luminanceMin = min(qualifierLumMin.doubleValue, qualifierLumMax.doubleValue); qualifier.luminanceMax = max(qualifierLumMin.doubleValue, qualifierLumMax.doubleValue); qualifier.softness = qualifierSoftness.doubleValue; nodes[index].qualifier = qualifier; preview() }
    private func wheelChanged() { guard let index = selectedNodeIndex, nodes.indices.contains(index) else { return }; nodes[index].lift = liftPanel.value; nodes[index].gamma = gammaPanel.value; nodes[index].gain = gainPanel.value; preview() }
    @objc private func curveSelectionChanged() { curveKind = max(0, curvePicker.indexOfSelectedItem); curveView.curve = selectedNode.map { self.curve(for: $0) } ?? .identity }
    private func curve(for node: GradeNode) -> GradeCurve { switch curveKind { case 1: return node.curves.red; case 2: return node.curves.green; case 3: return node.curves.blue; case 4: return node.curves.hueVsHue; case 5: return node.curves.hueVsSat; case 6: return node.curves.hueVsLum; case 7: return node.curves.lumaVsSat; default: return node.curves.master } }
    private func setCurve(_ curve: GradeCurve, on node: inout GradeNode) { switch curveKind { case 1: node.curves.red = curve; case 2: node.curves.green = curve; case 3: node.curves.blue = curve; case 4: node.curves.hueVsHue = curve; case 5: node.curves.hueVsSat = curve; case 6: node.curves.hueVsLum = curve; case 7: node.curves.lumaVsSat = curve; default: node.curves.master = curve } }
    private func curveChanged(_ curve: GradeCurve) { guard let index = selectedNodeIndex, nodes.indices.contains(index) else { return }; setCurve(curve, on: &nodes[index]); preview() }
    @objc private func resetCurve() { curveView.curve = .identity; curveChanged(.identity) }
    @objc private func applyCreativeLook(_ sender: NSButton) { guard GradeCreativeLook.allCases.indices.contains(sender.tag) else { return }; let look = GradeCreativeLook.allCases[sender.tag]; if selectedNodeIndex == nil { nodes.append(look.node()); selectedNodeIndex = nodes.count - 1 } else if let index = selectedNodeIndex { nodes[index] = look.node() }; updateNodeTable(); loadSelectedNodeControls(); controlChanged() }
    @objc private func scopeChanged() { scopeView.mode = scopeTabs.selectedSegment; scopeView.needsDisplay = true }
    @objc private func bypassChanged() { preview() }
    @objc private func lutChanged() { guard var lut = selectedLUT else { return }; lut.strength = lutStrength.doubleValue; selectedLUT = lut; updateLUTLabel(); refreshNumericFields(); preview() }
    @objc private func importLUT() { let panel = NSOpenPanel(); panel.title = "Import 3D LUT"; panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]; panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first; guard panel.runModal() == .OK, let url = panel.url else { return }; do { selectedLUT = try ClipLUTSettings(embeddingFileAt: url, strength: lutStrength.doubleValue); updateLUTLabel(); preview() } catch { NSAlert(error: error).runModal() } }
    @objc private func removeLUT() { selectedLUT = nil; updateLUTLabel(); preview() }
    @objc private func exportLUT() { guard hasVideoSelection else { return }; let index = lutDimension.indexOfSelectedItem; let size = [17, 33, 65].indices.contains(index) ? [17, 33, 65][index] : 33; onExportLUT?(nodes, size) }
    @objc private func preview() { guard hasVideoSelection else { return }; onPreview?(bypass.state == .on ? ColorControlValues() : values()) }
    @objc private func apply() { guard hasVideoSelection else { return }; bypass.state = .off; onApply?(values()) }
    @objc private func revertPreview() { guard hasVideoSelection else { return }; if let saved = onRequestSavedValues?() { load(saved, selectionName: currentSelectionName, isEnabled: true) }; onCancelPreview?() }
    @objc private func reset() { guard hasVideoSelection else { return }; load(ColorControlValues(), selectionName: currentSelectionName, isEnabled: true); preview() }

    private func values() -> ColorControlValues { var output = baseValues; output.exposure = baseExposure.doubleValue; output.contrast = baseContrast.doubleValue; output.saturation = baseSaturation.doubleValue; output.temperature = baseTemperature.doubleValue; output.tint = baseTint.doubleValue; output.vibrance = baseVibrance.doubleValue; output.lift = baseValues.lift; output.midtones = baseValues.midtones; output.gain = baseValues.gain; output.cubeLUT = selectedLUT; output.gradeNodes = nodes; return output }
    private func updateNodeTable() { isUpdatingNodeTable = true; defer { isUpdatingNodeTable = false }; nodeTable.reloadData(); if let index = selectedNodeIndex, nodes.indices.contains(index) { nodeTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) } else { nodeTable.deselectAll(nil) } }
    private func loadSelectedNodeControls() {
        defer { updateEnabledState(); refreshNumericFields() }
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
    private func updateEnabledState() {
        tabs.isEnabled = true
        [bypass, baseExposure, baseContrast, baseSaturation, baseTemperature, baseTint, baseVibrance, lutDimension].forEach { $0.isEnabled = hasVideoSelection }
        let hasNode = hasVideoSelection && selectedNode != nil
        let nodeControls: [NSControl] = [nodeName, nodeEnabled, nodeMix, nodeExposure, nodeContrast, nodeSaturation, nodeHue, curvePicker, qualifierEnabled, qualifierInverted, qualifierHue, qualifierWidth, qualifierSatMin, qualifierSatMax, qualifierLumMin, qualifierLumMax, qualifierSoftness]
        nodeControls.forEach { $0.isEnabled = hasNode }
        curveView.isEditingEnabled = hasNode
        func enableWheel(_ view: NSView) { if let control = view as? NSControl { control.isEnabled = hasNode }; view.subviews.forEach(enableWheel) }
        [liftPanel, gammaPanel, gainPanel].forEach { enableWheel($0); $0.alphaValue = hasNode ? 1 : 0.45; StudioWorkspaceUI.panel($0, role: .card) }
        lutStrength.isEnabled = hasVideoSelection && selectedLUT != nil
        nodeTable.isEnabled = hasVideoSelection
        nodeContextLabel.stringValue = selectedNode.map { "Editing node: \($0.name) • \(nodes.count) in stack" } ?? (hasVideoSelection ? "Add a grade node to use wheels, curves and qualifiers" : "Select video clips on the timeline to begin grading")
        let nodeActions: [Selector] = [#selector(duplicateNode), #selector(removeNode), #selector(moveNodeUp), #selector(moveNodeDown), #selector(resetCurve)]
        for item in actionButtons {
            if item.selector == #selector(moveNodeUp) { item.button.isEnabled = hasNode && (selectedNodeIndex ?? 0) > 0 }
            else if item.selector == #selector(moveNodeDown) { item.button.isEnabled = hasNode && (selectedNodeIndex ?? 0) + 1 < nodes.count }
            else if item.selector == #selector(removeLUT) { item.button.isEnabled = hasVideoSelection && selectedLUT != nil }
            else { item.button.isEnabled = nodeActions.contains(item.selector) ? hasNode : hasVideoSelection }
        }
        for item in numericFields.values { item.field.isEnabled = item.slider.isEnabled }
    }
    private func updateLUTLabel() { if let lut = selectedLUT { lutName.stringValue = "Imported: \(lut.fileURL.lastPathComponent) • \(Int(lut.strength * 100))%"; lutStrength.doubleValue = lut.strength } else { lutName.stringValue = "No imported LUT"; lutStrength.doubleValue = 1 }; updateEnabledState(); refreshNumericFields() }
    private func refreshScopes() { updateScopeImage(onRequestScopeImage?()) }

    // MARK: Table view
    func numberOfRows(in tableView: NSTableView) -> Int { nodes.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { let cell = NSTableCellView(); let label = NSTextField(labelWithString: "\(nodes[row].enabled ? "●" : "○")  \(nodes[row].name)"); label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = nodes[row].enabled ? .white : .secondaryLabelColor; cell.addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]); return cell }
    func tableViewSelectionDidChange(_ notification: Notification) { guard !isUpdatingNodeTable else { return }; let index = nodeTable.selectedRow; guard nodes.indices.contains(index) else { return }; selectedNodeIndex = index; loadSelectedNodeControls() }

    private func advancedHeading(_ title: String, _ subtitle: String) -> NSView { let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 4; stack.addArrangedSubview(StudioWorkspaceUI.label(title, size: 11, weight: .semibold, secondary: false)); stack.addArrangedSubview(StudioWorkspaceUI.label(subtitle, size: 11, wrapping: true)); return stack }
    private func advancedSliderRow(_ title: String, _ slider: NSSlider, _ action: Selector) -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 4
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        row.addArrangedSubview(StudioWorkspaceUI.label(title, weight: .medium, secondary: false)); row.addArrangedSubview(NSView())
        let field = NSTextField(string: ""); StudioWorkspaceUI.numericField(field, title: title)
        field.target = self; field.action = #selector(numericChanged(_:)); row.addArrangedSubview(field)
        numericFields[ObjectIdentifier(slider)] = (slider, field); numericSliders[ObjectIdentifier(field)] = slider
        slider.target = self; slider.action = action; slider.isContinuous = true; slider.toolTip = title
        slider.setAccessibilityLabel(title)
        stack.addArrangedSubview(row); stack.addArrangedSubview(slider); return stack
    }
    @objc private func numericChanged(_ sender: NSTextField) {
        guard let slider = numericSliders[ObjectIdentifier(sender)] else { return }
        guard let number = Double(sender.stringValue.replacingOccurrences(of: ",", with: ".")), number.isFinite else { refreshNumericFields(); return }
        slider.doubleValue = min(slider.maxValue, max(slider.minValue, number))
        if let action = slider.action { NSApp.sendAction(action, to: slider.target, from: slider) }
    }
    private func refreshNumericFields() { for item in numericFields.values { item.field.stringValue = String(format: item.slider.maxValue > 500 ? "%.0f" : "%.2f", item.slider.doubleValue) } }
    private func advancedSliderColumn(_ controls: [(String, NSSlider)]) -> NSView { let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 8; controls.forEach { stack.addArrangedSubview(advancedSliderRow($0.0, $0.1, #selector(controlChanged))) }; return stack }
    private func advancedScroll(_ document: NSView) -> NSScrollView { StudioWorkspaceUI.scroll(document) }
    private func advancedButton(_ title: String, _ action: Selector) -> NSButton { let button = StudioWorkspaceUI.button(title, target: self, action: action); actionButtons.append((button, action)); return button }
}

final class GradeCurveEditorView: NSView {
    var curve: GradeCurve = .identity { didSet { needsDisplay = true } }
    var onChange: ((GradeCurve) -> Void)?
    var isEditingEnabled = true { didSet { alphaValue = isEditingEnabled ? 1 : 0.45 } }
    private var activePoint: Int?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; layer?.backgroundColor = NSColor(hex: "11151B").cgColor; layer?.cornerRadius = 9; layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor; layer?.borderWidth = 1 }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect); let inset: CGFloat = 34; let graph = bounds.insetBy(dx: inset, dy: inset); NSColor(hex: "1C222B").setFill(); graph.fill(); NSColor.white.withAlphaComponent(0.08).setStroke(); for i in 0...10 { let x = graph.minX + graph.width * CGFloat(i) / 10; let y = graph.minY + graph.height * CGFloat(i) / 10; let path = NSBezierPath(); path.move(to: NSPoint(x: x, y: graph.minY)); path.line(to: NSPoint(x: x, y: graph.maxY)); path.move(to: NSPoint(x: graph.minX, y: y)); path.line(to: NSPoint(x: graph.maxX, y: y)); path.stroke() }; let line = NSBezierPath(); let points = GradeCurve.sanitized(curve.points); for (i, point) in points.enumerated() { let p = map(point, graph); if i == 0 { line.move(to: p) } else { line.line(to: p) } }; NSColor.systemBlue.setStroke(); line.lineWidth = 2.5; line.stroke(); for (i, point) in points.enumerated() { let p = map(point, graph); let radius: CGFloat = i == activePoint ? 7 : 5; NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)).fill(); NSColor.systemBlue.setStroke(); NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)).stroke() } }
    override func mouseDown(with event: NSEvent) {
        guard isEditingEnabled else { return }
        let graph = bounds.insetBy(dx: 34, dy: 34), point = convert(event.locationInWindow, from: nil)
        guard graph.width > 0, graph.height > 0, graph.contains(point) else { return }
        var values = GradeCurve.sanitized(curve.points)
        activePoint = values.enumerated().min { distance(map($0.element, graph), point) < distance(map($1.element, graph), point) }?.offset
        if let index = activePoint, distance(map(values[index], graph), point) > 18 { activePoint = nil }
        if event.clickCount > 1, let index = activePoint, index > 0, index < values.count - 1 {
            values.remove(at: index); activePoint = nil; curve = GradeCurve(points: values); onChange?(curve); return
        }
        if activePoint == nil {
            let created = GradeCurvePoint(x: Double((point.x - graph.minX) / graph.width), y: Double((point.y - graph.minY) / graph.height))
            values = GradeCurve.sanitized(values + [created])
            activePoint = values.firstIndex { abs($0.x - created.x) < 0.012 && abs($0.y - created.y) < 0.012 }
            curve = GradeCurve(points: values)
        }
        update(with: point, graph: graph)
    }
    override func mouseDragged(with event: NSEvent) { guard isEditingEnabled else { return }; update(with: convert(event.locationInWindow, from: nil), graph: bounds.insetBy(dx: 34, dy: 34)) }
    private func update(with point: NSPoint, graph: CGRect) {
        guard let index = activePoint, graph.width > 0, graph.height > 0 else { return }
        var points = GradeCurve.sanitized(curve.points); guard points.indices.contains(index) else { return }
        let x = min(1, max(0, Double((point.x - graph.minX) / graph.width)))
        let y = min(1, max(0, Double((point.y - graph.minY) / graph.height)))
        if index == 0 { points[index].x = 0 }
        else if index == points.count - 1 { points[index].x = 1 }
        else { points[index].x = min(points[index + 1].x - 0.001, max(points[index - 1].x + 0.001, x)) }
        points[index].y = y; curve = GradeCurve(points: points); onChange?(curve)
    }
    private func map(_ point: GradeCurvePoint, _ rect: CGRect) -> NSPoint { NSPoint(x: rect.minX + CGFloat(point.x) * rect.width, y: rect.minY + CGFloat(point.y) * rect.height) }
    private func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
