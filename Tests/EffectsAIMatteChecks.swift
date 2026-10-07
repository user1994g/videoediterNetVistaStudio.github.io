import Cocoa
import CoreImage

/// Full-app module test: compile with -D NETVISTA_STUDIO_TESTING and the same
/// Swift sources/frameworks as build_app.sh. Never downloads an actual model.
@main struct EffectsAIMatteChecks {
    static func allViews(_ node: NSView) -> [NSView] {
        [node] + node.subviews.flatMap(allViews)
    }
    static func control<T: NSView>(_ identifier: String, in view: NSView, as type: T.Type) -> T {
        guard let result = allViews(view).first(where: { $0.identifier?.rawValue == identifier }) as? T else {
            preconditionFailure("Missing AI effect control: \(identifier)")
        }
        return result
    }
    static func main() throws {
        _ = NSApplication.shared
        let controller = EffectsStudioViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        var values = EffectControlValues()
        var clip = TimelineClip(assetID: UUID(), name: "Synthetic Person", url: URL(fileURLWithPath: "/private/tmp/no-video-needed.mov"), outPoint: 10)
        controller.load(values, selectionName: "None", property: .opacity, interpolation: .linear,
                        keyframeText: "", clip: nil, timelineTime: 0)
        let download: NSButton = control("ai-matte-download", in: controller.view, as: NSButton.self)
        let enable: NSButton = control("ai-matte-enabled", in: controller.view, as: NSButton.self)
        let strength: NSSlider = control("ai-matte-strength", in: controller.view, as: NSSlider.self)
        precondition(!enable.isEnabled, "Cannot enable a clip effect with no selection")
        if !LocalAIMatte.shared.status.isBusy { precondition(download.isEnabled, "Model management must not require a clip") }
        precondition(enable.state == .off)

        values.effects.ultraKey.enabled = true
        values.effects.ultraKey.aiAssistEnabled = true
        values.effects.ultraKey.aiAssistStrength = 0.63
        clip.effects = values.effects
        controller.load(values, selectionName: clip.name, property: .ultraKeyTolerance, interpolation: .linear,
                        keyframeText: "", clip: clip, timelineTime: 3)
        precondition(enable.state == .on && abs(strength.doubleValue - 0.63) < 0.001)
        precondition(enable.isEnabled, "A saved setting must always be disableable")
        var preview: EffectControlValues?
        controller.onPreview = { preview = $0 }
        // Exercise the real control action, not a private test-only values copy.
        enable.state = .off
        precondition(NSApp.sendAction(enable.action!, to: enable.target, from: enable))
        precondition(preview?.effects.ultraKey.aiAssistEnabled == false)
        precondition(preview?.effects.ultraKey.aiAssistStrength == 0.63)
        precondition(preview?.effects.ultraKey.enabled == true)
        if !LocalAIMatte.shared.status.isInstalled {
            precondition(!strength.isEnabled)
            // A playhead refresh preserves saved flags, without downloading.
            // Give the intentional slider feedback-loop suppression time to end.
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            controller.updatePlayhead(localTime: 4, evaluatedValues: values)
            precondition(enable.state == .on && strength.doubleValue == 0.63)
            let label: NSTextField = control("ai-matte-status", in: controller.view, as: NSTextField.self)
            precondition(label.stringValue.contains("chroma key only"))
        }
        for size in [NSSize(width: 1180, height: 820), NSSize(width: 1050, height: 680)] {
            window.setContentSize(size); window.layoutIfNeeded(); controller.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            FileHandle.standardError.write(Data("Effects layout: requested \(size), window content \(window.contentView!.bounds.size), root \(controller.view.frame.size)\n".utf8))
            precondition(controller.view.frame.size == window.contentView!.bounds.size, "Effects root must match the native window content area")
        }
        // Saved settings round-trip through the actual video project clip.
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: JSONEncoder().encode(clip))
        precondition(decoded.effects.ultraKey.aiAssistEnabled && decoded.effects.ultraKey.aiAssistStrength == 0.63)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let source = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        var pixel = [Float](repeating: 0, count: 4)
        context.render(source, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 8, y: 8, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        precondition(pixel[1] > 0.95, "Do not mistake an unavailable graphics context for a passing pipeline test")
        if !LocalAIMatte.shared.status.isInstalled {
            let keyed = NativeTimelineVisualPipeline.applyGrade(to: source, clip: decoded, timelineTime: 1)
            context.render(keyed, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 8, y: 8, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            precondition(pixel[3] < 0.01, "Shared preview/export pipeline must safely key without a downloaded model")
        }
        let editor = EditorController()
        let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        editorWindow.contentViewController = editor
        editor.checkEffectsAIMatteKeyframePersistence()
        print("PASS: AI effect controls, missing-model state, explicit download management, clip settings round-trip, preview actions, playhead refresh and native window sizes")
    }
}
