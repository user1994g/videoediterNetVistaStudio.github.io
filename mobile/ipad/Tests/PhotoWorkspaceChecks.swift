import UIKit
import CoreImage

/// Compiled only into the isolated QA app. Drives production buttons, property
/// events and the same document-coordinate input handler used by UIKit touches.
@MainActor enum PhotoWorkspaceChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw PhotoBrushError.invalid("Photo UI check: " + message) }
    }
    static func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    static func button(_ root: UIView, _ id: String) throws -> UIButton {
        guard let button = views(root).first(where: { $0.accessibilityIdentifier == id }) as? UIButton else { throw PhotoBrushError.invalid("Missing photo control: " + id) }; return button
    }
    static func pause() async { try? await Task.sleep(nanoseconds: 400_000_000) }
    static func run(editor: EditorViewController, documents: URL) async throws {
        let video = editor.project
        editor.showHome(); try button(editor.view, "studio.open.photo").sendActions(for: .touchUpInside); await pause()
        guard let photo = editor.photoEditor else { throw PhotoBrushError.invalid("Home did not open the actual Photo workspace") }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let initial = try PhotoEditingSession(size: CGSize(width: 128, height: 96), background: nil)
        try photo.loadProject(initial.encodedProject(context: context), name: "Native test.netvistaphoto")
        let canvas = photo.canvas
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            guard let image = photo.session.render() else { return 0 }
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return bytes[3]
        }
        try check(alpha(64, 48) == 0, "New transparent canvas")
        try button(photo.view, "photo.tool.brush").sendActions(for: .touchUpInside)
        let history = photo.session.undoCount
        photo.handleInput(CGPoint(x: 40, y: 48), phase: 0)
        photo.handleInput(CGPoint(x: 64, y: 48), phase: 1)
        photo.handleInput(CGPoint(x: 88, y: 48), phase: 2)
        try check(alpha(64, 48) > 230 && photo.session.undoCount == history + 1, "One actual brush stroke paints and creates exactly one Undo")
        try button(photo.view, "photo.undo").sendActions(for: .touchUpInside)
        try check(alpha(64, 48) == 0, "Native Undo removes stroke")
        try button(photo.view, "photo.redo").sendActions(for: .touchUpInside)
        try check(alpha(64, 48) > 230, "Native Redo restores stroke")

        try button(photo.view, "photo.tool.eraser").sendActions(for: .touchUpInside)
        try check(canvas.tool == .eraser, "Native Eraser button selects tool (enabled \(try button(photo.view, "photo.tool.eraser").isEnabled), tool \(canvas.tool))")
        photo.handleInput(CGPoint(x: 64, y: 48), phase: 0); photo.handleInput(CGPoint(x: 64, y: 48), phase: 2)
        try check(alpha(64, 48) < 35, "Eraser changes layer alpha (actual \(alpha(64, 48)), undo \(photo.session.undoCount), status \(views(photo.view).compactMap { ($0 as? UILabel)?.text }.joined(separator: "; ")))")
        photo.undo()
        try button(photo.view, "photo.tool.select").sendActions(for: .touchUpInside)
        photo.handleInput(CGPoint(x: 10, y: 10), phase: 0); photo.handleInput(CGPoint(x: 30, y: 30), phase: 2)
        try button(photo.view, "photo.tool.rectangle").sendActions(for: .touchUpInside)
        photo.handleInput(CGPoint(x: 0, y: 0), phase: 0); photo.handleInput(CGPoint(x: 100, y: 90), phase: 2)
        try check(photo.session.layers.count == 2 && alpha(20, 20) > 250 && alpha(5, 5) == 0, "Shape layer respects selection")
        try button(photo.view, "photo.deselect").sendActions(for: .touchUpInside)
        let id = photo.session.selectedLayerID!
        try button(photo.view, "photo.tool.move").sendActions(for: .touchUpInside)
        photo.handleInput(CGPoint(x: 20, y: 20), phase: 0); photo.handleInput(CGPoint(x: 30, y: 35), phase: 2)
        try check(photo.session.selectedLayer?.position == CGPoint(x: 10, y: 15), "Drag uses document pixels and positive Y")

        let tabs = views(photo.view).compactMap { $0 as? UISegmentedControl }.first!
        tabs.selectedSegmentIndex = 1; tabs.sendActions(for: .valueChanged)
        guard let slider = views(photo.view).first(where: { $0.accessibilityIdentifier == "photo.property.Layer opacity" }) as? UISlider else { throw PhotoBrushError.invalid("Missing actual photo opacity slider") }
        slider.value = 0.5; slider.sendActions(for: .valueChanged)
        try check(abs((photo.session.selectedLayer?.opacity ?? 0) - 0.5) < 0.001 && photo.session.selectedLayerID == id, "Native property control edits selected layer")
        try check(alpha(22, 27) > 110 && alpha(22, 27) < 145, "Opacity produces real half-transparent pixels")
        try button(photo.view, "photo.undo").sendActions(for: .touchUpInside)
        try check(photo.session.selectedLayer?.opacity == 1, "Keyboard/accessibility-style slider edit is undoable")

        // A non-nil preview may still be the previous document. Wait for the
        // exact edit revision and verify the displayed image, not just the model.
        for _ in 0..<30 where photo.renderedRevision != photo.session.revision { await pause() }
        try check(photo.renderedRevision == photo.session.revision, "Latest edit reaches the asynchronous canvas")
        guard let preview = canvas.image?.cgImage else { throw PhotoBrushError.invalid("Missing actual canvas pixels") }
        let displayed = CIImage(cgImage: preview)
        func previewAlpha(_ x: Int, _ y: Int) -> UInt8 {
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(displayed, toBitmap: &bytes, rowBytes: 4,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return bytes[3]
        }
        try check(previewAlpha(64, 48) > 230 && previewAlpha(30, 35) > 250 && previewAlpha(5, 5) == 0,
                  "Displayed preview includes the restored stroke, moved shape and transparent background")

        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 1024, height: 768)] {
            photo.view.frame = CGRect(origin: .zero, size: size); photo.view.setNeedsLayout(); photo.view.layoutIfNeeded()
            try check(canvas.bounds.width > 100 && canvas.bounds.height > 100, "Usable canvas at \(size)")
            let document = CGPoint(x: 22, y: 71), roundTrip = canvas.documentPoint(canvas.viewPoint(document))
            try check(abs(roundTrip.x - document.x) < 0.001 && abs(roundTrip.y - document.y) < 0.001, "Viewport inverse transform")
            try button(photo.view, "photo.zoom.in").sendActions(for: .touchUpInside)
            try check(canvas.zoom > 1, "Native zoom control")
            try button(photo.view, "photo.zoom.fit").sendActions(for: .touchUpInside)
            let horizontalTicks = canvas.rulerTicks(horizontal: true), verticalTicks = canvas.rulerTicks(horizontal: false)
            try check(!horizontalTicks.isEmpty && !verticalTicks.isEmpty && horizontalTicks.count < 256 && verticalTicks.count < 256,
                      "Rulers draw bounded visible document-pixel ticks")
            for tick in horizontalTicks {
                try check(abs(canvas.documentPoint(CGPoint(x: tick.position, y: 24)).x - tick.value) < 0.001, "Horizontal ruler follows zoom and document origin")
            }
            for tick in verticalTicks {
                try check(abs(canvas.documentPoint(CGPoint(x: 24, y: tick.position)).y - tick.value) < 0.001, "Vertical ruler uses positive-Y document pixels")
            }
            try button(photo.view, "photo.rulers").sendActions(for: .touchUpInside)
            try check(!canvas.showsRulers, "Native ruler visibility control")
            try button(photo.view, "photo.rulers").sendActions(for: .touchUpInside)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let image = renderer.image { _ in photo.view.drawHierarchy(in: photo.view.bounds, afterScreenUpdates: true) }
            guard let screenshot = CIImage(image: image) else { throw PhotoBrushError.invalid("Missing rendered workspace") }
            func visiblePixel(_ document: CGPoint) -> [UInt8] {
                let point = canvas.convert(canvas.viewPoint(document), to: photo.view)
                var bytes = [UInt8](repeating: 0, count: 4)
                context.render(screenshot, toBitmap: &bytes, rowBytes: 4,
                               bounds: CGRect(x: floor(point.x), y: floor(size.height - point.y), width: 1, height: 1),
                               format: .RGBA8, colorSpace: nil)
                return bytes
            }
            let painted = visiblePixel(CGPoint(x: 30, y: 35)), clear = visiblePixel(CGPoint(x: 5, y: 5))
            try check(painted[0] < 50 && painted[1] < 50 && painted[2] < 50 && painted[3] > 250 && clear[0] > 100,
                      "Actual workspace displays paint against the checkerboard at \(size)")
            try image.pngData()?.write(to: documents.appendingPathComponent("photo-\(Int(size.width))x\(Int(size.height)).png"))
        }
        let saved = try photo.session.encodedProject(context: context)
        let restored = try PhotoEditingSession(); try restored.load(data: saved)
        try check(restored.layers.count == 2 && restored.selectedLayer?.position == CGPoint(x: 10, y: 15), "Desktop-native layered save round trip")
        try saved.write(to: documents.appendingPathComponent("photo-native-roundtrip.netvistaphoto"))

        let flipped = try PhotoEditingSession(size: CGSize(width: 128, height: 96), background: nil)
        let flippedID = flipped.selectedLayerID!
        try flipped.mutateLayer(flippedID) { $0.adjustments.mirrored = true }
        try photo.loadProject(flipped.encodedProject(context: context), name: "Flipped.netvistaphoto")
        try button(photo.view, "photo.tool.brush").sendActions(for: .touchUpInside)
        photo.handleInput(CGPoint(x: 24, y: 48), phase: 0); photo.handleInput(CGPoint(x: 24, y: 48), phase: 2)
        try check(alpha(24, 48) > 230 && alpha(104, 48) == 0, "Brush paints under the cursor after a horizontal flip")
        var sourcePixel = [UInt8](repeating: 0, count: 4)
        context.render(photo.session.selectedLayer!.sourceImage, toBitmap: &sourcePixel, rowBytes: 4,
                       bounds: CGRect(x: 104, y: 48, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        try check(sourcePixel[3] > 230, "Flipped image tools write to inverse-mapped source pixels")

        let masked = try PhotoEditingSession(size: CGSize(width: 128, height: 96), background: .white)
        let maskedID = masked.selectedLayerID!
        try masked.mutateLayer(maskedID) { $0.adjustments.mirrored = true }
        try masked.addMask(maskedID, context: context)
        try photo.loadProject(masked.encodedProject(context: context), name: "Masked flip.netvistaphoto")
        tabs.selectedSegmentIndex = 1; tabs.sendActions(for: .valueChanged)
        try button(photo.view, "photo.command.Paint mask").sendActions(for: .touchUpInside)
        try button(photo.view, "photo.tool.brush").sendActions(for: .touchUpInside)
        guard let library = views(photo.view).compactMap({ $0 as? PhotoBrushLibraryView }).first,
              let collection = library.subviews.compactMap({ $0 as? UICollectionView }).first else {
            throw PhotoBrushError.invalid("Missing native brush library")
        }
        // Use full hard coverage to isolate inverse mapping from soft-tip
        // falloff and grayscale mask colour-space encoding.
        library.collectionView(collection, didSelectItemAt: IndexPath(item: 0, section: 0))
        photo.handleInput(CGPoint(x: 24, y: 48), phase: 0); photo.handleInput(CGPoint(x: 24, y: 48), phase: 2)
        try photo.session.encodedProject(context: context).write(to: documents.appendingPathComponent("photo-mirrored-mask.netvistaphoto"))
        try check(alpha(24, 48) <= 1 && alpha(104, 48) == 255, "Mask brush stays under the cursor and is not mirrored twice (left \(alpha(24, 48)), right \(alpha(104, 48)), layer \(photo.session.selectedLayer!.name))")

        try button(photo.view, "photo.tool.select").sendActions(for: .touchUpInside)
        photo.handleInput(CGPoint(x: 10, y: 10), phase: 0); photo.handleInput(CGPoint(x: 30, y: 30), phase: 2)
        let committedOutline = canvas.outline
        photo.handleInput(CGPoint(x: 60, y: 40), phase: 0); photo.handleInput(CGPoint(x: 90, y: 70), phase: 1)
        photo.handleInput(CGPoint(x: 90, y: 70), phase: -1)
        try check(canvas.outline == committedOutline, "Cancelling a selection gesture restores the committed selection")
        try button(photo.view, "photo.tool.wand").sendActions(for: .touchUpInside)
        photo.handleInput(CGPoint(x: 104, y: 48), phase: 0)
        try button(photo.view, "photo.deselect").sendActions(for: .touchUpInside)
        await pause()
        try check(canvas.outline == nil, "An older asynchronous Wand cannot restore a deselected region")
        photo.undo()
        try button(photo.view, "photo.tool.rectangle").sendActions(for: .touchUpInside)
        photo.handleInput(CGPoint(x: 50, y: 50), phase: 0); photo.handleInput(CGPoint(x: 80, y: 80), phase: 2)
        try check(canvas.outline == nil, "Drawing a shape after Undo cannot resurrect an obsolete selection outline")
        try await PhotoBrushLibraryChecks.run(in: photo.view)
        try await PhotoLayerPanelChecks.run(in: photo.view)
        try await PhotoColourControlsChecks.run(photo: photo)
        try await PhotoExportLifecycleChecks.run(in: photo)
        photo.permitsEditing = { false }; photo.refreshAccess()
        let lockedRevision = photo.session.revision
        photo.handleInput(CGPoint(x: 20, y: 20), phase: 0); photo.handleInput(CGPoint(x: 80, y: 50), phase: 2)
        try check(photo.session.revision == lockedRevision && !canvas.isUserInteractionEnabled, "Account gate prevents authoring after invalidation")
        photo.permitsEditing = { true }; photo.refreshAccess()
        try button(photo.view, "photo.home").sendActions(for: .touchUpInside); await pause()
        try check(editor.project == video, "Photo document never replaces video project")
        try "PASS: real Studio Home Photo entry, blank native document, brush/eraser/selection/shape/move input, actual opacity pixels, multi-step Undo/Redo, canvas zoom/mapping, phone/tablet layouts, native layered round trip, access gate and independent video state.\n".write(to: documents.appendingPathComponent("photo-workspace-result.txt"), atomically: true, encoding: .utf8)
    }
}
