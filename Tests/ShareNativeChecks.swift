import Cocoa

@main struct ShareNativeChecks {
    static func main() {
        _ = NSApplication.shared
        let controller = EditorController()
        controller.checkShareCollaboration()
        var document = NetVistaSceneDocument()
        document.objects = [SceneObjectRecord(name: "Preview cube", kind: .cube)]
        let jpeg = SceneSharePreviewRenderer.jpeg(document: document, time: 0)
        precondition(jpeg != nil && NSBitmapImageRep(data: jpeg!)?.pixelsWide == 960, "Real SceneKit LAN preview must produce a bounded JPEG")
        print("PASS: native SceneKit JPEG preview")
        let server = LocalShareServer(authority: SharePairingAuthority(store: ShareMemoryDeviceStore())) { nil }
        let panel = SharePanelViewController(server: server)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 690), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = panel
        for width in [580.0, 720.0, 1000.0] {
            window.setContentSize(NSSize(width: width, height: 690)); window.layoutIfNeeded(); panel.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            let root = panel.view.subviews.first as! NSStackView
            let actualWidth = panel.view.bounds.width
            FileHandle.standardError.write(Data("Share layout requested \(width), actual \(actualWidth), root \(root.frame.width)\n".utf8))
            precondition(abs(root.frame.width - actualWidth) < 2)
            for child in root.arrangedSubviews { precondition(abs(child.frame.width - actualWidth) < 2, "Share root sections must fill the window") }
        }
        print("PASS: Share panel width layout at 580 / 720 / 1000 points")
        window.close()
    }
}
