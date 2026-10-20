// Separate simulator-only QA executable. This file is never compiled by
// build_ipa.sh, which takes only Sources/*.swift. No production auth bypass.
import UIKit
import AVFoundation
import CoreVideo

@MainActor
final class WorkspaceCheckEditor: EditorViewController {
    var captureExpectedEditError = false
    var capturedEditErrors: [String] = []
    override var canEdit: Bool { !exporting && !importing }
    override func refreshAccount() {
        accountOverlay.isHidden = true
        refresh()
    }
    override func error(_ error: Error) {
        if captureExpectedEditError { capturedEditErrors.append(error.localizedDescription) }
        else { super.error(error) }
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
        if CommandLine.arguments.contains("--creative-only") {
            do { try await checkCreativeWorkspaces() }
            catch { fail(error.localizedDescription) }
            try? "PASS: native four-workspace diagnostic\n".write(to: documents.appendingPathComponent("workspace-result.txt"), atomically: true, encoding: .utf8)
            return
        }
        if CommandLine.arguments.contains("--photo-only") {
            do { try await PhotoWorkspaceChecks.run(editor: editor, documents: documents) }
            catch { fail(error.localizedDescription) }
            try? "PASS: native photo-only diagnostic\n".write(to: documents.appendingPathComponent("workspace-result.txt"), atomically: true, encoding: .utf8)
            return
        }
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
        let beforeAnimation = editor.project
        editor.selectPage("Effects"); await settle()
        editor.seek.value = 0.25; editor.scrub()
        control("property.opacity.keyframe").sendActions(for: .touchUpInside)
        require(editor.project.clips[0].effects.frames(for: .opacity).count == 1, "Property diamond creates a real saved key")
        require(control("property.opacity.keyframe").bounds.width >= 44 && control("property.opacity.keyframe").bounds.height >= 44,
                "Property animation diamond needs a 44-point touch target")
        editor.seek.value = 1.25; editor.scrub(); slider("opacity", value: 0)
        let keys = editor.project.clips[0].effects.frames(for: .opacity)
        require(keys.count == 2 && abs(keys[0].sourceSeconds - 0.25) < 0.001 && keys[0].value == 0.5 &&
                abs(keys[1].sourceSeconds - 1.25) < 0.001 && keys[1].value == 0,
                "Animated slider adds a source-time key at the actual logical playhead, preserving the previous key")
        let animatedHidden = await previewRGB(at: 1.3)
        require(max(animatedHidden.0, animatedHidden.1, animatedHidden.2) < 8, "Native keyframe controls must hide real AVPlayer frames: \(animatedHidden)")
        editor.seek.value = 1.25; editor.scrub()
        control("animation.previous").sendActions(for: .touchUpInside)
        require(abs(editor.previewTargetTime - 0.25) < 0.002, "Previous seeks real key, not just highlighting a diamond")
        control("animation.next").sendActions(for: .touchUpInside)
        require(abs(editor.previewTargetTime - 1.25) < 0.002, "Next seeks the actual next source key")
        control("animation.remove").sendActions(for: .touchUpInside)
        require(editor.project.clips[0].effects.frames(for: .opacity).count == 1, "Remove here deletes a real saved key")
        editor.undoAction(); require(editor.project.clips[0].effects.frames(for: .opacity).count == 2, "Undo restores removed keyframe")
        control("animation.auto").sendActions(for: .touchUpInside); slider("brightness", value: -0.2)
        require(editor.project.clips[0].effects.frames(for: .brightness).count == 1, "Auto key animates an initially static colour property")
        control("animation.auto").sendActions(for: .touchUpInside)
        guard let lane = views(editor.view).compactMap({ $0 as? MobileKeyframeTrack }).first else { fail("Missing native diamond lane") }
        require(lane.frames.count == 1 && lane.sourceRange == 0...3 && lane.bounds.height >= 44, "Animation lane is backed by selected property's saved keys")
        lane.onSeek?(0.7); require(abs(editor.previewTargetTime - 0.7) < 0.002, "Diamond lane seeks real sequence")
        editor.saveWorking(); require((try! MobileProject.read(editor.autosave)).clips[0].effects.keyframes == editor.project.clips[0].effects.keyframes,
            "Animation keys persist in native draft")
        editor.change { $0 = beforeAnimation }
        // A valid3-second clip can reach the total10k-key cap without exceeding
        // source time or minimum key spacing. Rejection must finish its gesture
        // without leaving a stale source time for the next numeric commit.
        var capped = MobileClipEffects()
        for property in MobileEffectProperty.allCases {
            capped.keyframes[property.rawValue] = (0..<1_250).map {
                MobileEffectKeyframe(sourceSeconds: Double($0) * 0.002, value: capped.value(for: property))
            }
        }
        try! capped.validate(duration: 3)
        editor.project.clips[0].effects = capped; editor.refresh()
        editor.seek.value = 2.7; editor.scrub()
        let beforeFailedEdit = editor.project, undoCount = editor.history.undo.count
        editor.captureExpectedEditError = true; slider("opacity", value: 0.4)
        require(editor.project == beforeFailedEdit && editor.history.undo.count == undoCount,
                "Rejected capped slider must not change project or add Undo history")
        require(editor.capturedEditErrors.count == 1, "Capped gesture should report exactly one error, not repeat on touch-up")
        require(editor.capturedEditErrors[0].contains("keyframe limit") && editor.capturedEditErrors[0].contains("Remove unused"),
                "Cap failure should explain animation limits and recovery, not report a media/trim problem")
        editor.seek.value = 0.7; editor.scrub()
        let opacityRow = views(editor.view).compactMap { $0 as? MobilePropertyRow }.first { $0.key == "opacity" }!
        opacityRow.onChange?("opacity", 0.25, true) // The same commit callback used by numeric properties, without touchDown.
        require(editor.capturedEditErrors.count == 1 && editor.history.undo.count == undoCount + 1 &&
                abs(editor.project.clips[0].effects.value(for: .opacity, at: 0.7) - 0.25) < 0.0001,
                "A numeric commit after rejection must use the new source time and create one valid Undo")
        editor.captureExpectedEditError = false
        // Simulate a second-finger selection during an unfinished slider drag.
        editor.selected = 0; editor.refresh()
        opacityRow.onBegin?(); let otherClipBefore = editor.project.clips[1]
        editor.selected = 1; editor.refresh(); opacityRow.onChange?("opacity", 0.1, true)
        require(editor.project.clips[1] == otherClipBefore, "Old slider gesture must not edit a newly selected clip")
        // A toolbar command can arrive from a second finger after the slider
        // has already changed the project, not just after its touch-down.
        // The live edit must become the earlier Undo entry; stale move/up
        // events must never append the pre-command snapshot afterwards.
        editor.change { $0 = beforeAnimation }; editor.selected = 0; editor.refresh()
        let gestureBase = editor.project, duplicateUndoCount = editor.history.undo.count
        opacityRow.onBegin?(); opacityRow.onChange?("opacity", 0.4, false)
        let beforeDuplicate = editor.project
        control("clip.duplicate").sendActions(for: .touchUpInside)
        let afterDuplicate = editor.project
        require(afterDuplicate.clips.count == gestureBase.clips.count + 1 &&
                editor.history.undo.count == duplicateUndoCount + 2,
                "An active slider commits before Duplicate as two ordered Undo steps")
        opacityRow.onChange?("opacity", 0.9, false); opacityRow.onChange?("opacity", 0.9, true)
        require(editor.project == afterDuplicate && editor.history.undo.count == duplicateUndoCount + 2,
                "A stale slider move/up must not edit the new duplicate or append history")
        editor.undoAction(); require(editor.project == beforeDuplicate, "First Undo removes only the duplicate, keeping the prior slider edit")
        editor.undoAction(); require(editor.project == gestureBase, "Second Undo removes only the prior slider edit")
        editor.redoAction(); require(editor.project == beforeDuplicate, "First Redo restores the slider edit without the duplicate")
        editor.redoAction(); require(editor.project == afterDuplicate, "Second Redo restores the duplicate after the slider edit")

        editor.change { $0 = gestureBase }; editor.selected = 0; editor.refresh()
        let deleteUndoCount = editor.history.undo.count
        opacityRow.onBegin?(); opacityRow.onChange?("opacity", 0.3, false)
        let beforeDelete = editor.project
        control("clip.delete").sendActions(for: .touchUpInside)
        let afterDelete = editor.project
        opacityRow.onChange?("opacity", 0.8, false); opacityRow.onChange?("opacity", 0.8, true)
        require(editor.project == afterDelete && afterDelete.clips.count == gestureBase.clips.count - 1 &&
                editor.history.undo.count == deleteUndoCount + 2,
                "Delete must finalize the slider edit and ignore its remaining events")
        editor.undoAction(); require(editor.project == beforeDelete, "Undo Delete restores the edited clip without rolling back its prior property value")
        editor.undoAction(); require(editor.project == gestureBase, "The next Undo restores the pre-slider state")

        editor.selected = 0; editor.refresh(); let directUndoCount = editor.history.undo.count
        opacityRow.onBegin?(); opacityRow.onChange?("opacity", 0.2, false)
        let beforeDirectUndo = editor.project
        editor.undoAction()
        require(editor.project == gestureBase && editor.history.undo.count == directUndoCount && editor.history.redo.last == beforeDirectUndo,
                "Undo during a drag must undo that drag and retain it for Redo")
        let redoCountAfterUndo = editor.history.redo.count
        opacityRow.onChange?("opacity", 0.7, false); opacityRow.onChange?("opacity", 0.7, true)
        require(editor.project == gestureBase && editor.history.undo.count == directUndoCount && editor.history.redo.count == redoCountAfterUndo,
                "Stale slider events after Undo must not reapply the edit or erase Redo")
        editor.redoAction(); require(editor.project == beforeDirectUndo, "Redo restores the interrupted slider's complete value")
        editor.undoAction(); editor.selected = 0; editor.refresh()
        // Ten valid10k-key clips reach the project cap. Adding to an empty
        // eleventh clip is locally valid, so only project-aware validation can
        // prevent the edit, Auto Key, duplicate and split from crossing100k.
        var aggregate = beforeAnimation
        aggregate.clips = (0..<10).map { number in
            var clip = beforeAnimation.clips[0]; clip.id = UUID(); clip.name = "Full \(number)"; clip.effects = capped; return clip
        }
        var empty = beforeAnimation.clips[0]; empty.id = UUID(); empty.effects = MobileClipEffects(); aggregate.clips.append(empty)
        try! aggregate.validate(); require(aggregate.totalKeyframeCount == 100_000, "Aggregate cap fixture")
        editor.project = aggregate; editor.selected = 10; editor.refresh()
        editor.seek.value = 32.7; editor.scrub()
        let aggregateUndo = editor.history.undo.count, aggregateErrors = editor.capturedEditErrors.count
        editor.captureExpectedEditError = true
        control("property.opacity.keyframe").sendActions(for: .touchUpInside)
        control("animation.add").sendActions(for: .touchUpInside)
        control("animation.auto").sendActions(for: .touchUpInside); slider("opacity", value: 0.2)
        control("animation.auto").sendActions(for: .touchUpInside)
        require(editor.project == aggregate && editor.history.undo.count == aggregateUndo &&
                editor.capturedEditErrors.count == aggregateErrors + 3,
                "Diamond/Add/Auto slider must reject aggregate overflow without mutation, Undo or repeated gesture errors")
        editor.selected = 0; editor.refresh(); control("clip.duplicate").sendActions(for: .touchUpInside)
        let aggregateTimeline = views(editor.view).compactMap { $0 as? MobileTimelineView }.first!
        aggregateTimeline.onSplit?(0, 1)
        require(editor.project == aggregate && editor.selected == 0 && editor.history.undo.count == aggregateUndo &&
                editor.capturedEditErrors.count == aggregateErrors + 5,
                "Failed duplicate/split must remain atomic, keep selection and report the actual animation limit")
        editor.captureExpectedEditError = false
        editor.selected = 0; editor.change { $0 = beforeAnimation }
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
        await checkExportSettings()
        do { try await PhotoWorkspaceChecks.run(editor: editor, documents: documents) }
        catch { fail(error.localizedDescription) }
        do { try await checkCreativeWorkspaces() }
        catch { fail(error.localizedDescription) }
        try? "PASS: actual AVPlayer frames, second-clip playback, opacity 0/50 and undo preview; native Home artwork; phone/tablet portrait/landscape and split-window layout; real animation diamonds, animated playback, Add/Remove/Previous/Next/Auto key, seekable lane, undo and saved tracks; real property controls, split/duplicate/delete/reorder callback, draft/effects/media-pool persistence; no account traffic. Simulator QA is not physical-device signing or codec coverage.\n".write(to: documents.appendingPathComponent("workspace-result.txt"), atomically: true, encoding: .utf8)
    }
    func checkExportSettings() async {
        func transition(_ message: String, _ ready: () -> Bool) async {
            for _ in 0..<60 {
                if ready() { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            require(ready(), message)
        }
        let original = editor.project
        editor.exportAction()
        await transition("Export settings finish opening in a real window") {
            guard let shown = (editor.presentedViewController ?? host.presentedViewController) as? MovieExportSettingsViewController else { return false }
            return shown.viewIfLoaded?.window != nil && !shown.isBeingPresented
        }
        guard let settings = (editor.presentedViewController ?? host.presentedViewController) as? MovieExportSettingsViewController,
              settings.view.window != nil else { fail("Export opens the actual combined resolution/FPS page") }
        require(settings.height == 1080 && settings.fps == 30, "Export starts with explicit1080p/30 defaults")
        settings.resolutions.selectedSegmentIndex = 2; settings.resolutions.sendActions(for: .valueChanged)
        settings.frameRates.selectedSegmentIndex = 4; settings.frameRates.sendActions(for: .valueChanged)
        require(settings.summary.text == "3840 × 2160 pixels · 60 fps", "Export summary reflects both real choices before rendering")
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 768, height: 1024)] {
            settings.view.frame.size = size; settings.view.setNeedsLayout(); settings.view.layoutIfNeeded()
            for item in [settings.resolutions, settings.frameRates, settings.exportButton, settings.cancelButton] {
                require(item.bounds.height >= 44 && item.bounds.width <= size.width, "Export controls are usable on phone/tablet and scroll in landscape")
            }
        }
        settings.cancelButton.sendActions(for: .touchUpInside)
        await transition("Cancelled export settings finish dismissing without a render") {
            settings.viewIfLoaded?.window == nil && editor.presentedViewController == nil && host.presentedViewController == nil
        }
        require(editor.project == original && !editor.exporting && editor.exportSession == nil,
                "Cancelling export settings never renders or mutates the project")
        // The same native Render button forwards exactly the displayed pair.
        let recorder = MovieExportSettingsViewController(); var permitted = true; var exports: [(Int, Int)] = []
        recorder.permitsExport = { permitted }; recorder.onExport = { exports.append(($0, $1)) }
        recorder.modalPresentationStyle = .pageSheet
        host.present(recorder, animated: false)
        await transition("Export recorder is fully presented before button input") {
            recorder.viewIfLoaded?.window != nil && !recorder.isBeingPresented && recorder.presentingViewController === host
        }
        recorder.resolutions.selectedSegmentIndex = 0; recorder.frameRates.selectedSegmentIndex = 1
        permitted = false; recorder.updateSummary(); recorder.exportButton.sendActions(for: .touchUpInside)
        require(exports.isEmpty && recorder.presentingViewController != nil, "Revoked export permission cannot dismiss into a stale render")
        permitted = true; recorder.updateSummary(); recorder.exportButton.sendActions(for: .touchUpInside)
        recorder.exportButton.sendActions(for: .touchUpInside)
        await transition("Render callback follows the completed dismissal; actual exports=\(exports)") {
            !exports.isEmpty && recorder.viewIfLoaded?.window == nil && host.presentedViewController == nil
        }
        require(exports.count == 1 && exports[0].0 == 720 && exports[0].1 == 25,
                "Render forwards the actual chosen resolution and frame rate together exactly once; actual=\(exports)")
        require(host.presentedViewController == nil && editor.project == original, "Export settings leave the independent editing session unchanged")
    }
    func checkCreativeWorkspaces() async throws {
        func waitForTransition(_ description:String,_ ready:()->Bool) async {
            // UIKit/SceneKit transitions can take longer under simulator load.
            // Wait for the real presentation and attachment state, not a fixed
            // animation sleep; the predicate remains a strict bounded oracle.
            for _ in 0..<60 {
                if ready() {return}
                try? await Task.sleep(nanoseconds:50_000_000)
            }
            require(ready(),description)
        }
        let video = editor.project
        let photo = editor.photoEditor
        editor.showHome(); await settle()
        for id in ["studio.open.video", "studio.open.photo", "studio.open.game", "studio.open.modeling"] {
            require(control(id).bounds.height >= 44, "Every editor has an accessible Home launch action")
        }
        control("studio.open.game").sendActions(for: .touchUpInside)
        await waitForTransition("Game Maker finishes opening into an actual window") {
            guard let game = editor.gameEditor else {return false}
            return game.viewIfLoaded?.window != nil && !game.isBeingPresented &&
                (editor.presentedViewController === game || host.presentedViewController === game)
        }
        guard let game = editor.gameEditor, game.viewIfLoaded?.window != nil,
              editor.presentedViewController === game || host.presentedViewController === game else {
            fail("Home must open a real independent Game Maker; instance=\(editor.gameEditor != nil), presenter=\(String(describing: editor.gameEditor?.presentingViewController)), window=\(editor.gameEditor?.viewIfLoaded?.window != nil)")
        }
        try await GameWorkspaceChecks.run(controller: game, documents: documents)
        let savedGame = game.session.project
        try PhotoWorkspaceChecks.button(game.view, "game.home").sendActions(for: .touchUpInside)
        await waitForTransition("Game Home returns to the shared launcher") {
            editor.presentedViewController == nil && host.presentedViewController == nil && game.viewIfLoaded?.window == nil
        }
        control("studio.open.modeling").sendActions(for: .touchUpInside)
        await waitForTransition("3D Editor finishes opening into an actual window") {
            guard let model = editor.modelingEditor else {return false}
            return model.viewIfLoaded?.window != nil && !model.isBeingPresented &&
                (editor.presentedViewController === model || host.presentedViewController === model)
        }
        guard let model = editor.modelingEditor, model.viewIfLoaded?.window != nil,
              editor.presentedViewController === model || host.presentedViewController === model else { fail("Home must open a real independent 3D Editor") }
        try await ModelingWorkspaceChecks.run(controller: model, documents: documents)
        let savedModel = model.document
        try PhotoWorkspaceChecks.button(model.view, "model.home").sendActions(for: .touchUpInside)
        await waitForTransition("3D Home returns to the shared launcher") {
            editor.presentedViewController == nil && host.presentedViewController == nil && model.viewIfLoaded?.window == nil
        }
        control("studio.open.game").sendActions(for: .touchUpInside)
        await waitForTransition("Reopening Game Maker finishes without replacing its workspace") {
            game.viewIfLoaded?.window != nil && !game.isBeingPresented &&
                (editor.presentedViewController === game || host.presentedViewController === game)
        }
        require(editor.gameEditor === game && game.session.project == savedGame,
                "Switching apps retains the authored game, not a replacement session")
        try PhotoWorkspaceChecks.button(game.view, "game.home").sendActions(for: .touchUpInside)
        await waitForTransition("Reopened Game Maker returns to Home") {
            editor.presentedViewController == nil && host.presentedViewController == nil && game.viewIfLoaded?.window == nil
        }
        require(editor.modelingEditor === model && model.document == savedModel && editor.photoEditor === photo && editor.project == video,
                "Each editor retains its independent project through the shared Home navigation")
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
