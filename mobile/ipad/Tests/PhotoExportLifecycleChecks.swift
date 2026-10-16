import UIKit
import CoreImage

@MainActor enum PhotoExportLifecycleChecks {
    static func run(in host: UIViewController) async throws {
        let helper = PhotoEditorViewController(); helper.permitsEditing = { true }
        host.addChild(helper); host.view.addSubview(helper.view); helper.didMove(toParent: host)
        helper.view.frame = host.view.bounds
        defer { helper.willMove(toParent: nil); helper.view.removeFromSuperview(); helper.removeFromParent() }
        helper.onHome = { [weak helper] in
            helper?.willMove(toParent: nil); helper?.view.removeFromSuperview(); helper?.removeFromParent()
        }
        let ext = "qa-" + UUID().uuidString, started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        helper.exportFile(extension: ext) { _, _ in
            started.signal()
            guard release.wait(timeout: .now() + 10) == .success else { throw PhotoBrushError.invalid("QA export was not released") }
            return Data("immutable export probe".utf8)
        }
        var didStart = false
        for _ in 0..<100 {
            if started.wait(timeout: .now()) == .success { didStart = true; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try PhotoWorkspaceChecks.check(didStart && helper.preparingExport, "Photo export runs in its worker, not the main thread")
        let save = try PhotoWorkspaceChecks.button(helper.view, "photo.save")
        try PhotoWorkspaceChecks.check(!save.isEnabled,
                                       "A pending export prevents duplicate save jobs")
        try PhotoWorkspaceChecks.button(helper.view, "photo.home").sendActions(for: .touchUpInside)
        try PhotoWorkspaceChecks.check(helper.view.window == nil, "Real Home action detaches the exporting workspace")
        release.signal()
        for _ in 0..<100 where helper.preparingExport { try? await Task.sleep(nanoseconds: 50_000_000) }
        try PhotoWorkspaceChecks.check(!helper.preparingExport && helper.presentedViewController == nil,
                                       "Completed export never presents a Files dialog on a closed workspace")
        let leftovers = try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == ext }
        try PhotoWorkspaceChecks.check(leftovers.isEmpty, "Abandoned photo export removes only its generated temporary file")
    }
}
