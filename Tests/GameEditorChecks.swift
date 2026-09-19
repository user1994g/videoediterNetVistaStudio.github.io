import Cocoa

@main struct GameEditorChecks {
    static func main() throws {
        _ = NSApplication.shared
        for dimension in [GameDimension.twoD, .threeD] {
            let controller = GameEditorViewController(project: .starter(dimension))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentViewController = controller
            window.orderFront(nil)
            controller.checkEditingAndPlay()
            try controller.checkCharacterFeatures()
            for (width, height) in [(1280,840), (1100,680)] {
                window.setContentSize(NSSize(width: width, height: height)); window.layoutIfNeeded(); controller.view.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                try controller.checkViewportRendering(width:width)
                if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/netvista-game-\(dimension.rawValue)-\(width).png"))
                }
            }
            window.orderOut(nil)
            print("PASS: \(dimension.rawValue) native editor, add/edit/delete objects, Play/Stop preserves project, two window sizes")
        }
    }
}
