import Cocoa

@main struct SharePanelLayoutChecks {
    static func main() {
        _ = NSApplication.shared
        let server = LocalShareServer(authority: SharePairingAuthority(store: ShareMemoryDeviceStore())) { nil }
        let panel = SharePanelViewController(server: server)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 690), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = panel
        for width in [580.0, 720.0, 1000.0] {
            window.setContentSize(NSSize(width: width, height: 690)); window.layoutIfNeeded(); panel.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            let root = panel.view.subviews.first as! NSStackView
            FileHandle.standardError.write(Data("Share layout requested \(width), actual \(panel.view.bounds.width), root \(root.frame.width)\n".utf8))
            precondition(abs(root.frame.width - panel.view.bounds.width) < 2)
            for child in root.arrangedSubviews { precondition(abs(child.frame.width - panel.view.bounds.width) < 2) }
        }
        print("PASS: Share panel full-width layout at compact/standard/wide sizes")
        window.close()
    }
}
