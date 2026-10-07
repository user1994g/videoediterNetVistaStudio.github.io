import Cocoa

/// Compile with NETVISTA_STUDIO_TESTING and the real app source list.
/// Runs real native control actions without importing media or AI downloads.
@main struct VideoWorkspaceChecks {
    static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    static func button(_ title: String, _ root: NSView) -> NSButton {
        guard let button = views(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
            preconditionFailure("Missing button: \(title)")
        }
        return button
    }
    static func perform(_ button: NSButton) {
        precondition(button.isEnabled, "Disabled action: \(button.title)")
        precondition(NSApp.sendAction(button.action!, to: button.target, from: button))
    }
    static func layout(_ window: NSWindow) {
        window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
    }
    static func assertChrome(_ root: NSView) {
        for identifier in ["studio-workspace-header", "studio-workspace-footer"] {
            guard let chrome = views(root).first(where: { $0.identifier?.rawValue == identifier }) else { preconditionFailure("Missing shared chrome") }
            let frame = chrome.convert(chrome.bounds, to: root)
            precondition(frame.width > 0 && frame.height > 0 && root.bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(identifier) clipped: \(frame) in \(root.bounds)")
            precondition(frame.width >= root.bounds.width - 40, "\(identifier) must stretch across the tool window: \(frame) in \(root.bounds), parent \(String(describing: chrome.superview?.frame))")
        }
    }
    static func snapshot(_ root: NSView, path: String) throws {
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: path)) }
    }
    static func main() throws {
        _ = NSApplication.shared
        let colour = AdvancedColorStudioViewController()
        let colourWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        colourWindow.contentViewController = colour
        var values = ColorControlValues(); values.exposure = 1.25; values.saturation = 1.5
        var a = GradeNode(name: "A"); a.exposure = 0.3; a.saturation = 1.25
        var b = GradeNode(name: "B"); b.exposure = -0.7; b.saturation = 0.6
        values.gradeNodes = [a, b]
        var previews: [ColorControlValues] = []
        colour.onPreview = { previews.append($0) }
        colour.load(values, selectionName: "Two selected clips")
        perform(button("↓", colour.view))
        precondition(colour.currentValues.gradeNodes.map(\.name) == ["B", "A"])
        precondition(colour.currentValues.gradeNodes[0].exposure == -0.7 && colour.currentValues.gradeNodes[1].exposure == 0.3, "Reorder must never overwrite a node from stale controls")
        perform(button("↑", colour.view))
        precondition(colour.currentValues.gradeNodes == [a, b])

        let nodeExposure = views(colour.view).compactMap { $0 as? NSSlider }.first { $0.toolTip == "Exposure" }!
        nodeExposure.doubleValue = 0.8
        precondition(NSApp.sendAction(nodeExposure.action!, to: nodeExposure.target, from: nodeExposure))
        precondition(colour.currentValues.gradeNodes[0].exposure == 0.8)
        let precise = views(nodeExposure.superview!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        precondition(precise.stringValue == "0.80", "Numeric readout must track sliders")
        precise.stringValue = "-1.4"; precondition(NSApp.sendAction(precise.action!, to: precise.target, from: precise))
        precondition(colour.currentValues.gradeNodes[0].exposure == -1.4)
        precise.stringValue = "nan"; precondition(NSApp.sendAction(precise.action!, to: precise.target, from: precise))
        precondition(colour.currentValues.gradeNodes[0].exposure == -1.4, "Reject non-finite numeric entry")
        perform(button("Reset Grade", colour.view))
        precondition(colour.currentValues.exposure == 0 && colour.currentValues.saturation == 1 && colour.currentValues.gradeNodes.isEmpty, "Reset must reset base sliders, not only nodes")
        precondition(!nodeExposure.isEnabled)
        let disabledWheel = views(colour.view).compactMap { $0 as? ColorWheelControl }.first!
        let beforeWheel = disabledWheel.adjustment
        let wheelPoint = disabledWheel.convert(NSPoint(x: disabledWheel.bounds.midX + 40, y: disabledWheel.bounds.midY), to: nil)
        let mouseDown = NSEvent.mouseEvent(with: .leftMouseDown, location: wheelPoint, modifierFlags: [], timestamp: 0, windowNumber: colourWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let mouseDrag = NSEvent.mouseEvent(with: .leftMouseDragged, location: wheelPoint, modifierFlags: [], timestamp: 0, windowNumber: colourWindow.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        disabledWheel.mouseDown(with: mouseDown); disabledWheel.mouseDragged(with: mouseDrag)
        precondition(!disabledWheel.isEnabled && disabledWheel.adjustment == beforeWheel, "No-node wheel must ignore direct mouse events")
        perform(button("+ Grade Node", colour.view))
        precondition(nodeExposure.isEnabled && colour.currentValues.gradeNodes.count == 1)
        var applied: ColorControlValues?
        colour.onApply = { applied = $0 }; perform(button("Apply to Selected Clips", colour.view))
        precondition(applied?.gradeNodes.count == 1 && !previews.isEmpty)

        let colourTabs = views(colour.view).first { $0.identifier?.rawValue == "colour-workspace-tabs" } as! NSSegmentedControl
        for size in [NSSize(width: 1000, height: 760), NSSize(width: 820, height: 620)] {
            colourWindow.setContentSize(size)
            for tab in 0..<6 { colourTabs.selectedSegment = tab; NSApp.sendAction(colourTabs.action!, to: colourTabs.target, from: colourTabs); layout(colourWindow); assertChrome(colour.view) }
        }
        colourTabs.selectedSegment = 1; NSApp.sendAction(colourTabs.action!, to: colourTabs.target, from: colourTabs); layout(colourWindow)
        try snapshot(colour.view, path: "/private/tmp/netvista-colour-workspace.png")
        colour.load(ColorControlValues(), selectionName: "None", isEnabled: false)
        precondition(!button("+ Grade Node", colour.view).isEnabled && !button("Apply to Selected Clips", colour.view).isEnabled)
        precondition(colourTabs.isEnabled, "Navigation must remain accessible without a clip")

        let effects = EffectsStudioViewController()
        let effectsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        effectsWindow.contentViewController = effects
        var clip = TimelineClip(assetID: UUID(), name: "Synthetic Clip", url: URL(fileURLWithPath: "/private/tmp/no-media-needed.mov"), outPoint: 10)
        clip.animation.channels = [AnimationChannel(property: .scale, keyframes: [ScalarKeyframe(time: 0, value: 1), ScalarKeyframe(time: 2, value: 1.6), ScalarKeyframe(time: 5, value: 0.8)])]
        effects.load(EffectControlValues(), selectionName: clip.name, property: .scale, interpolation: .linear, keyframeText: "", clip: clip, timelineTime: 2)
        layout(effectsWindow)
        var keyed: (Double, AnimatableProperty)?
        effects.onKeyframe = { value, property, _ in keyed = (value.transform.scale, property) }
        perform(button("◆ Zoom 50%", effects.view))
        precondition(keyed?.0 == 0.5 && keyed?.1 == .scale, "Quick keys must write real animation callbacks")
        let scaleReadout = views(effects.view).compactMap { $0 as? NSTextField }.first { $0.toolTip == "Enter Scale / Zoom precisely, then press Return" }!
        let opacityReadout = views(effects.view).compactMap { $0 as? NSTextField }.first { $0.toolTip == "Enter Opacity precisely, then press Return" }!
        precondition(scaleReadout.stringValue == "50.0%" && opacityReadout.stringValue == "100.0%", "Scale/opacity readouts must retain percent suffixes")
        var effectPreview: EffectControlValues?
        effects.onPreview = { effectPreview = $0 }
        func addEffect(_ title: String) {
            let choose = views(effects.view).compactMap { $0 as? NSButton }.first { $0.title == title && $0.superview.map { views($0).compactMap { $0 as? NSButton }.contains { $0.title == "+ Add" } } == true }!
            perform(button("+ Add", choose.superview!))
        }
        addEffect("Gaussian Blur"); addEffect("Sharpen")
        precondition((effectPreview?.effects.blurRadius ?? 0) > 0 && (effectPreview?.effects.sharpenAmount ?? 0) > 0)
        let sharpenRow = views(effects.view).first { $0.identifier?.rawValue == "applied-sharpen" }!
        perform(button("↑", sharpenRow))
        let order = effectPreview!.effects.effectOrder
        precondition(order.firstIndex(of: .sharpen)! < order.firstIndex(of: .blur)!, "Reorder applied effects changes the actual render stack")
        let blurRow = views(effects.view).first { $0.identifier?.rawValue == "applied-blur" }!
        perform(button("×", blurRow))
        precondition(effectPreview!.effects.blurRadius == 0 && effectPreview!.effects.sharpenAmount > 0, "Remove only the chosen effect")
        perform(button("Motion", effects.view))
        let search = views(effects.view).first { $0.identifier?.rawValue == "effects-browser-search" } as! NSSearchField
        search.stringValue = "nothing matches"; NSApp.sendAction(search.action!, to: search.target, from: search)
        precondition(views(effects.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("No matching effects") && !$0.isHidden })
        search.stringValue = ""; NSApp.sendAction(search.action!, to: search.target, from: search)
        let effectsTabs = views(effects.view).first { $0.identifier?.rawValue == "effects-workspace-tabs" } as! NSSegmentedControl
        effectsTabs.selectedSegment = 1; NSApp.sendAction(effectsTabs.action!, to: effectsTabs.target, from: effectsTabs)
        let linkedValue = views(effects.view).first { $0.identifier?.rawValue == "keyframe-property-value" } as! NSSlider
        linkedValue.doubleValue = 1.6
        NSApp.sendAction(linkedValue.action!, to: linkedValue.target, from: linkedValue)
        precondition(effectPreview?.transform.scale == 1.6, "Keyframe tab value edits the real selected property")
        let keyValueField = views(effects.view).compactMap { $0 as? NSTextField }.first { $0.toolTip == "Enter Keyframe property precisely, then press Return" }!
        precondition(keyValueField.stringValue == "160.0%", "Linked keyframe readout must retain the selected property's units")
        for size in [NSSize(width: 1000, height: 760), NSSize(width: 820, height: 620)] {
            effectsWindow.setContentSize(size)
            for tab in 0..<2 { effectsTabs.selectedSegment = tab; NSApp.sendAction(effectsTabs.action!, to: effectsTabs.target, from: effectsTabs); layout(effectsWindow); assertChrome(effects.view) }
        }
        try snapshot(effects.view, path: "/private/tmp/netvista-keyframes-workspace.png")
        effectsTabs.selectedSegment = 0; NSApp.sendAction(effectsTabs.action!, to: effectsTabs.target, from: effectsTabs); layout(effectsWindow)
        try snapshot(effects.view, path: "/private/tmp/netvista-effects-workspace.png")
        effects.load(EffectControlValues(), selectionName: "None", property: .scale, interpolation: .linear, keyframeText: "", clip: nil, timelineTime: 0)
        precondition(effectsTabs.isEnabled && search.isEnabled)
        precondition(!button("Apply to Selected Clips", effects.view).isEnabled)
        print("PASS: shared Effects/Colour native chrome, small-window layouts, precise numeric controls, reset, empty selection, node reorder, batch callback and scale keyframes")
    }
}
