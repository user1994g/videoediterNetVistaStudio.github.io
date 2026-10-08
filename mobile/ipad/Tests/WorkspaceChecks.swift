// Separate simulator-only QA executable. This file is never compiled by
// build_ipa.sh, which takes only Sources/*.swift. No production auth bypass.
import UIKit
import AVFoundation
import CoreVideo

@MainActor
final class WorkspaceCheckEditor: EditorViewController {
    override var canEdit: Bool { !exporting && !importing }
    override func refreshAccount() {
        accountOverlay.isHidden = true
        refresh()
    }
}

@MainActor
final class WorkspaceCheckDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var editor: WorkspaceCheckEditor!
    var host: UIViewController!
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "NetVista workspace", sessionRole: session.role)
        configuration.delegateClass = WorkspaceCheckScene.self
        return configuration
    }
    func start(in scene: UIWindowScene) {
        do {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent("workspace-result.txt"))
            let media = documents.appendingPathComponent("Media", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            var project = MobileProject()
            for (name, colour) in [("Coast test.mov", "red"), ("Flower test.mov", "blue")] {
                let source = Bundle.main.url(forResource: colour, withExtension: "mov")!
                let destination = media.appendingPathComponent("\(colour).mov")
                if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: source, to: destination) }
                project.clips.append(MobileClip(name: name, file: "\(colour).mov", duration: 3, inPoint: 0, outPoint: 3))
            }
            project.library = project.clips
            try project.write(documents.appendingPathComponent("WorkingProject.json"))
        } catch { fail("Fixture setup: \(error)") }
        // This fresh, isolated simulator bundle has no remembered account flag,
        // therefore the real account service neither reads credentials nor sends
        // a login request. Only this test subclass permits local fixture editing.
        let window = UIWindow(windowScene: scene)
        host = UIViewController(); host.view.backgroundColor = MobileTheme.window
        editor = WorkspaceCheckEditor(); host.addChild(editor)
        host.view.addSubview(editor.view); editor.didMove(toParent: host)
        window.rootViewController = host; window.makeKeyAndVisible(); self.window = window
        editor.view.frame = host.view.bounds; editor.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        Task { try? await Task.sleep(nanoseconds: 1_000_000_000); await check() }
    }

    func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    func control(_ id: String) -> UIButton {
        guard let value = views(editor.view).first(where: { $0.accessibilityIdentifier == id }) as? UIButton else { fail("Missing control \(id)") }
        return value
    }
    func require(_ condition: @autoclosure () -> Bool, _ text: String) { if !condition() { fail(text) } }
    func fail(_ text: String) -> Never {
        try? "FAIL: \(text)".write(to: documents.appendingPathComponent("workspace-result.txt"), atomically: true, encoding: .utf8)
        fatalError(text)
    }
    func settle() async { editor.view.setNeedsLayout(); editor.view.layoutIfNeeded(); try? await Task.sleep(nanoseconds: 100_000_000) }
    func snapshot(_ name: String) {
        let folder = documents.appendingPathComponent("ui-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(bounds: editor.view.bounds).image { _ in editor.view.drawHierarchy(in: editor.view.bounds, afterScreenUpdates: true) }
        try? image.pngData()?.write(to: folder.appendingPathComponent("\(name).png"))
    }
    func verifyLayout(_ size: CGSize, page: String) {
        editor.view.frame = CGRect(origin: .zero, size: size)
        editor.view.setNeedsLayout(); editor.view.layoutIfNeeded()
        let all = views(editor.view)
        for id in ["workspace.program.monitor", "workspace.timeline"] {
            guard let item = all.first(where: { $0.accessibilityIdentifier == id }) else { fail("Missing \(id)") }
            let rect = item.convert(item.bounds, to: editor.view)
            require(rect.minX >= -1 && rect.maxX <= size.width + 1 && rect.maxY <= size.height + 1, "\(id) outside \(size) on \(page): \(rect)")
            require(rect.width >= 200 && rect.height >= 70, "\(id) unusable \(size)/\(page): \(rect)")
        }
        if size.width < 600, let inspector = all.first(where: { $0.accessibilityIdentifier == "workspace.inspector" }),
           !inspector.isHidden, let monitor = all.first(where: { $0.accessibilityIdentifier == "workspace.program.monitor" }) {
            let a = inspector.convert(inspector.bounds, to: editor.view), b = monitor.convert(monitor.bounds, to: editor.view)
            require(!a.intersects(b), "Phone inspector must not cover the live monitor: \(a)/\(b)")
        }
        for item in all {
            guard let button = item as? UIButton, let id = button.accessibilityIdentifier,
                  !id.hasPrefix("property."), button.window != nil else { continue }
            var parent: UIView? = button
            var hidden = false
            while let ancestor = parent { hidden = hidden || ancestor.isHidden; parent = ancestor.superview }
            if hidden { continue }
            require(button.bounds.height >= 43, "Touch control \(id) too short: \(button.bounds)")
            require(button.titleLabel?.numberOfLines == 1, "Wrapped button \(id)")
        }
    }
    func slider(_ key: String, value: Float) {
        guard let slider = views(editor.view).first(where: { $0.accessibilityIdentifier == "property.\(key).slider" }) as? UISlider else { fail("Missing slider \(key)") }
        slider.sendActions(for: .touchDown); slider.value = value
        slider.sendActions(for: .valueChanged); slider.sendActions(for: .touchUpInside)
    }
    func previewRGB(at seconds: Double) async -> (Int, Int, Int) {
        // Allow the real slider debounce to fire before waiting for its replacement.
        try? await Task.sleep(nanoseconds: 300_000_000)
        for _ in 0..<300 {
            if !editor.previewBuilding && editor.player.currentItem?.status == .readyToPlay { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let item = editor.player.currentItem, item.status == .readyToPlay,
              !editor.previewBuilding else { fail("Edited preview must become ready: \(editor.status.text ?? "")") }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        await editor.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        editor.player.play()
        var frame: CVPixelBuffer?
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            frame = output.copyPixelBuffer(forItemTime: editor.player.currentTime(), itemTimeForDisplay: nil)
            if frame != nil { break }
        }
        editor.player.pause(); item.remove(output)
        guard let frame else { fail("Edited AVPlayer preview must produce real frames") }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let pointer = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let offset = CVPixelBufferGetHeight(frame) / 2 * CVPixelBufferGetBytesPerRow(frame) + CVPixelBufferGetWidth(frame) / 2 * 4
        return (Int(pointer[offset + 2]), Int(pointer[offset + 1]), Int(pointer[offset]))
    }
    func check() async {
        require(editor.project.clips.count == 2, "Actual private draft must restore")
        require(editor.account.session == nil, "QA must never use a real account")
        require(!editor.playerController.view.isUserInteractionEnabled, "Monitor must be inspection-only; transport owns playback")
        snapshot("home")
        control("studio.open.video").sendActions(for: .touchUpInside); await settle()
        editor.selected = 0; editor.refresh()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let raw = AVPlayer(url: editor.media.appendingPathComponent("red.mov"))
        raw.play()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let rawState = "Raw fixture player=\(raw.status.rawValue), item=\(raw.currentItem?.status.rawValue ?? -1), error=\(String(describing: raw.currentItem?.error)), time=\(raw.currentTime().seconds)"
        try? rawState.write(to: documents.appendingPathComponent("raw-preview-state.txt"), atomically: true, encoding: .utf8)
        raw.pause()
        for _ in 0..<300 {
            if !editor.previewBuilding && editor.player.currentItem?.status == .readyToPlay { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        require(editor.player.currentItem != nil, "Real AVFoundation preview must load")
        let item = editor.player.currentItem!
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let readiness = "player=\(editor.player.status.rawValue), item=\(item.status.rawValue), playerError=\(String(describing: editor.player.error)), itemError=\(String(describing: item.error)), log=\(String(describing: item.errorLog()?.events))"
        try? readiness.write(to: documents.appendingPathComponent("preview-state.txt"), atomically: true, encoding: .utf8)
        require(item.status == .readyToPlay, "Native AVPlayer preview must be ready, not merely allocated: \(readiness)")
        editor.player.play()
        var frame: CVPixelBuffer?
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if editor.player.currentTime().seconds > 0.1 {
                frame = output.copyPixelBuffer(forItemTime: editor.player.currentTime(), itemTimeForDisplay: nil)
                if frame != nil { break }
            }
        }
        editor.player.pause()
        require(editor.player.currentTime().seconds > 0.05, "Native transport advances real composition frames")
        require(frame != nil, "Real AVPlayer compositor must produce a frame")
        if let frame {
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            let pointer = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
            let offset = CVPixelBufferGetHeight(frame) / 2 * CVPixelBufferGetBytesPerRow(frame) + CVPixelBufferGetWidth(frame) / 2 * 4
            let blue = pointer[offset], green = pointer[offset + 1], red = pointer[offset + 2]
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
            require(red > 180 && green < 45 && blue < 45, "Live AVPlayer must display the actual red fixture, not a black fallback: \(red),\(green),\(blue)")
        }
        item.remove(output)
        let second = await previewRGB(at: 3.2)
        require(second.2 > 180 && second.0 < 45 && second.1 < 45, "Sequence must show the second clip, not jump back to first: \(second)")
        await editor.player.seek(to: .zero)
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 768, height: 1024), CGSize(width: 1024, height: 768), CGSize(width: 600, height: 640)] {
            for page in ["Edit", "Effects", "Colour"] {
                editor.selectPage(page); await settle(); verifyLayout(size, page: page)
                snapshot("\(Int(size.width))x\(Int(size.height))-\(page.lowercased())")
            }
        }
        editor.view.frame = host.view.bounds
        editor.selectPage("Effects"); await settle()
        slider("scale", value: 1.25); slider("opacity", value: 0.5)
        require(editor.project.clips[0].effects.scale == 1.25 && editor.project.clips[0].effects.opacity == 0.5, "Native sliders update selected clip")
        let faded = await previewRGB(at: 0.2)
        require(faded.0 > 160 && faded.0 < 205 && faded.1 < 25 && faded.2 < 25, "Edited opacity must appear in actual playback using linear-light compositing: \(faded)")
        slider("opacity", value: 0)
        let hidden = await previewRGB(at: 0.2)
        require(max(hidden.0, hidden.1, hidden.2) < 8, "Opacity zero must hide the actual video: \(hidden)")
        editor.undoAction()
        let restored = await previewRGB(at: 0.2)
        require(restored.0 > 160 && restored.0 < 205, "Undo must rebuild real edited preview: \(restored)")
        editor.undoAction(); require(editor.project.clips[0].effects.opacity == 1, "Undo property")
        editor.redoAction(); require(editor.project.clips[0].effects.opacity == 0.5, "Redo property")
        editor.selectPage("Colour"); await settle(); slider("saturation", value: 0.6)
        require(abs(editor.project.clips[0].effects.saturation - 0.6) < 0.00001, "Real colour control")
        editor.selectPage("Edit"); await settle()
        let timeline = views(editor.view).compactMap { $0 as? MobileTimelineView }.first!
        timeline.onSplit?(0, 1)
        require(editor.project.clips.count == 3, "Timeline split")
        control("clip.duplicate").sendActions(for: .touchUpInside)
        require(editor.project.clips.count == 4, "Duplicate button")
        control("clip.delete").sendActions(for: .touchUpInside)
        require(editor.project.clips.count == 3, "Delete button")
        editor.undoAction(); require(editor.project.clips.count == 4, "Undo delete")
        editor.redoAction(); require(editor.project.clips.count == 3, "Redo delete")
        let first = editor.project.clips[0].id
        timeline.onMove?(0, 2)
        require(editor.project.clips[2].id == first, "Timeline move callback")
        editor.saveWorking()
        let saved = try! MobileProject.read(editor.autosave)
        require(saved == editor.project && saved.library.count == 2, "Native persistence and media pool retained")
        editor.showHome(); await settle(); control("studio.continue").sendActions(for: .touchUpInside)
        await settle(); snapshot("editor-final")
        try? "PASS: actual AVPlayer frames, second-clip playback, opacity 0/50 and undo preview; native Home artwork; phone/tablet portrait/landscape and split-window layout; real property controls, undo/redo, split/duplicate/delete/reorder callback, draft/effects/media-pool persistence; no account traffic. Simulator QA is not physical-device signing or codec coverage.\n".write(to: documents.appendingPathComponent("workspace-result.txt"), atomically: true, encoding: .utf8)
    }
}

@MainActor final class WorkspaceCheckScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene, let delegate = UIApplication.shared.delegate as? WorkspaceCheckDelegate else { return }
        delegate.start(in: scene); window = delegate.window
    }
}

@main struct WorkspaceCheckEntry {
    @MainActor static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(WorkspaceCheckDelegate.self))
    }
}
