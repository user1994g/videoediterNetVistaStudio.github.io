import UIKit
import CoreImage

@MainActor enum PhotoColourControlsChecks {
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw PhotoBrushError.invalid("Photo colour controls: " + message) }
    }
    private static func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    private static func slider(_ photo: PhotoEditorViewController, _ name: String) throws -> UISlider {
        guard let result = views(photo.view).first(where: { $0.accessibilityIdentifier == "photo.property.\(name)" }) as? UISlider else { throw PhotoBrushError.invalid("Missing native control: " + name) }; return result
    }
    private static func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }
    static func run(photo: PhotoEditorViewController) async throws {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let restoredData = try photo.session.encodedProject(context: context)
        defer { try? photo.loadProject(restoredData, name: "Restored after colour checks.netvistaphoto") }
        let dims = CGSize(width: 128, height: 96), fixture = try PhotoEditingSession(size: dims, background: nil)
        let source = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 96))
            .composited(over: CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: CGRect(origin: .zero, size: dims)))
        try fixture.replacePixels(fixture.selectedLayerID!, image: source)
        try photo.loadProject(fixture.encodedProject(context: context), name: "Colour QA.netvistaphoto")
        func red(_ x: Int) -> Float {
            var pixel = [Float](repeating: 0, count: 4)
            context.render(photo.session.render()!, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: x, y: 48, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return pixel[0]
        }
        guard let tabs = views(photo.view).compactMap({ $0 as? UISegmentedControl }).first(where: { $0.titleForSegment(at: 0) == "Layers" }) else { throw PhotoBrushError.invalid("Missing actual photo inspector tabs") }
        tabs.selectedSegmentIndex = 1; tabs.sendActions(for: .valueChanged)
        photo.view.setNeedsLayout(); photo.view.layoutIfNeeded(); await settle()
        guard let curve = views(photo.view).compactMap({ $0 as? MobilePhotoToneCurveView }).first else { throw PhotoBrushError.invalid("Missing native tone curve") }
        try check(curve.bounds.width > 24 && curve.bounds.height > 24, "Visible tone graph receives a usable layout before editing")
        let unlaid = MobilePhotoToneCurveView(frame: .zero); var prematureInput = false
        unlaid.onBegin = { prematureInput = true; return true }
        unlaid.input(CGPoint(x: CGFloat.infinity, y: CGFloat.nan), phase: 0)
        unlaid.input(.zero, phase: 0)
        try check(!prematureInput, "Early/unlaid-out tone input is ignored without converting NaN to an integer")
        let before = red(32), history = photo.session.undoCount
        curve.input(curve.point(at: 1, output: 0.5), phase: 0)
        curve.input(curve.point(at: 1, output: 0.2), phase: 1)
        curve.input(curve.point(at: 1, output: 0.35), phase: 2)
        try check(abs(photo.session.selectedLayer!.extras.midtone - 0.35) < 0.001 && photo.session.undoCount == history + 1,
                  "A complete native curve drag edits the shared grading value in one Undo step")
        try check(abs(red(32) - before) > 0.04, "Dragging the curve changes real rendered pixels")
        photo.undo(); try check(abs(red(32) - before) < 0.03, "Undo restores actual curve pixels")
        photo.redo(); let midpoint = photo.session.selectedLayer!.extras.midtone
        photo.view.setNeedsLayout(); photo.view.layoutIfNeeded(); await settle()
        guard let cancelCurve = views(photo.view).compactMap({ $0 as? MobilePhotoToneCurveView }).first else { throw PhotoBrushError.invalid("Missing rebuilt curve") }
        let cancelHistory = photo.session.undoCount
        cancelCurve.input(cancelCurve.point(at: 1, output: 0.8), phase: 0); cancelCurve.input(cancelCurve.point(at: 1, output: 0.95), phase: 1); cancelCurve.input(.zero, phase: -1)
        try check(photo.session.selectedLayer!.extras.midtone == midpoint && photo.session.undoCount == cancelHistory, "Cancelled curve gestures restore values without phantom history")
        let numeric = try slider(photo, "Curve shadows"); numeric.value = 0.42; numeric.sendActions(for: .valueChanged)
        let refreshedCurve = views(photo.view).compactMap { $0 as? MobilePhotoToneCurveView }.first!
        try check(abs(refreshedCurve.values[0] - 0.42) < 0.001, "Numeric sliders and curve anchors stay synchronized")
        let stale = numeric
        tabs.selectedSegmentIndex = 0; tabs.sendActions(for: .valueChanged)
        tabs.selectedSegmentIndex = 1; tabs.sendActions(for: .valueChanged)
        stale.sendActions(for: .touchDown)
        try check(!photo.session.isEditing, "Detached controls cannot begin an invisible edit")
        let live = try slider(photo, "Layer opacity"), startingOpacity = photo.session.selectedLayer!.opacity
        let startingHistory = photo.session.undoCount
        live.sendActions(for: .touchDown); live.value = 0.25; live.sendActions(for: .valueChanged)
        stale.sendActions(for: .touchUpInside); stale.sendActions(for: .touchCancel)
        try check(photo.session.isEditing && abs(photo.session.selectedLayer!.opacity - 0.25) < 0.001,
                  "Detached lifecycle events cannot finish or cancel a live control transaction")
        live.sendActions(for: .touchCancel)
        try check(!photo.session.isEditing && photo.session.selectedLayer!.opacity == startingOpacity && photo.session.undoCount == startingHistory,
                  "Cancelling a real slider transaction restores its value without phantom Undo")
        let first = try slider(photo, "Layer opacity"), second = try slider(photo, "Exposure")
        first.sendActions(for: .touchDown); first.value = 0.6; first.sendActions(for: .valueChanged)
        second.sendActions(for: .touchDown); second.value = 1; second.sendActions(for: .valueChanged)
        first.sendActions(for: .touchUpInside)
        try check(photo.session.isEditing, "An earlier control in the same panel cannot finish a later control's gesture")
        second.sendActions(for: .touchCancel)
        try check(photo.session.selectedLayer!.adjustments.exposure == 0 && abs(photo.session.selectedLayer!.opacity - 0.6) < 0.001,
                  "Control ownership preserves the previous committed edit and cancels only its own edit")

        try photo.loadProject(fixture.encodedProject(context: context), name: "Tolerance QA.netvistaphoto")
        photo.selectTool(.wand)
        let tolerance = try slider(photo, "Tolerance"); tolerance.value = 0; tolerance.sendActions(for: .valueChanged)
        photo.handleInput(CGPoint(x: 16, y: 48), phase: 0)
        for _ in 0..<30 where photo.canvas.outline == nil { await settle() }
        try check(photo.canvas.outline?.boundingBoxOfPath.width == 64, "Zero tolerance selects only exactly matching connected pixels")
        let deselect = views(photo.view).first { $0.accessibilityIdentifier == "photo.deselect" } as! UIButton
        deselect.sendActions(for: .touchUpInside); tolerance.value = 255; tolerance.sendActions(for: .valueChanged)
        photo.handleInput(CGPoint(x: 16, y: 48), phase: 0)
        for _ in 0..<30 where photo.canvas.outline == nil { await settle() }
        try check(photo.canvas.outline?.boundingBoxOfPath.width == 128, "High tolerance includes the adjoining different colour")
        deselect.sendActions(for: .touchUpInside); photo.selectTool(.bucket)
        let colour = UIColorPickerViewController(); colour.selectedColor = .black; photo.colorPickerViewControllerDidSelectColor(colour)
        let fillTolerance = try slider(photo, "Tolerance"); fillTolerance.value = 0; fillTolerance.sendActions(for: .valueChanged)
        let fillRevision = photo.session.revision, fillHistory = photo.session.undoCount
        photo.handleInput(CGPoint(x: 16, y: 48), phase: 0)
        for _ in 0..<30 where photo.session.revision == fillRevision { await settle() }
        try check(red(16) < 0.03 && red(96) > 0.3 && photo.session.undoCount == fillHistory + 1, "Fill shares editable tolerance and one reversible real pixel edit")
        photo.undo(); try check(red(16) > 0.2 && red(96) > 0.3, "Undo restores both regions after fill")

        let suite = "netvista-photo-palette-qa-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let palette = MobilePhotoPaletteView(defaults: defaults); palette.frame = CGRect(x: 4, y: 4, width: 280, height: 102)
        photo.view.addSubview(palette); defer { palette.removeFromSuperview() }; palette.layoutIfNeeded()
        palette.setColour(UIColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1), at: 2)
        let reopened = MobilePhotoPaletteView(defaults: defaults)
        let saved = PhotoPixels.components(reopened.colours[2]); try check(abs(saved.red - 0.2) < 0.001 && abs(saved.blue - 0.7) < 0.001, "Custom palette persists using the desktop RGB format")
        var picked: UIColor?; palette.onSelect = { picked = $0 }
        let swatch = palette.subviews.first { $0.accessibilityIdentifier == "photo.palette.swatch.2" } as! UIButton
        swatch.sendActions(for: .touchUpInside)
        try check(picked != nil && abs(PhotoPixels.components(picked!).green - 0.4) < 0.001, "Actual native swatch action selects the custom paint colour")
    }
}
