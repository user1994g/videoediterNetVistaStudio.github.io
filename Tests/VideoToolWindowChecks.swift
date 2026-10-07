import Cocoa

/// Compile with NETVISTA_STUDIO_TESTING and the actual build_app.sh sources.
/// Optionally pass a short local movie fixture to exercise real preview seeks.
@main struct VideoToolWindowChecks {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let controller = EditorController()
        let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        editorWindow.isReleasedWhenClosed = false
        editorWindow.contentViewController = controller
        editorWindow.center(); editorWindow.makeKeyAndOrderFront(nil)
        let movie = CommandLine.arguments.dropFirst().first ?? "/private/tmp/netvista-no-media-needed.mov"
        controller.checkConcurrentVideoToolWindows(mediaURL: URL(fileURLWithPath: movie))
        editorWindow.close()
    }
}
