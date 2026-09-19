import Cocoa

// Standalone host for the real Photo Editor; no app windows are opened.
extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex,radix:16) ?? 0
        self.init(deviceRed:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255,alpha:1)
    }
}
@main struct PhotoWorkspaceChecks {
    static func main() throws {
        _ = NSApplication.shared
        let controller = PhotoEditorViewController()
        try controller.runPhotoRegressionChecks(projectURL:URL(fileURLWithPath:"/private/tmp/netvista-photo-roundtrip.netvistaphoto"))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1320,height:820),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.contentViewController = controller
        controller.showBrushesForChecks()
        for (width,height) in [(1320,820),(980,640)] {
            window.setContentSize(NSSize(width:width,height:height)); window.layoutIfNeeded(); controller.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until:Date().addingTimeInterval(0.2))
            controller.checkBrushInputEvents()
            print("Layout \(width): root \(controller.view.frame); regions \(controller.view.subviews.map { $0.frame })")
            precondition(controller.view.frame.width == CGFloat(width) && controller.view.frame.height == CGFloat(height), "Workspace must fit the requested size")
            if let workspace = controller.view.subviews.first?.subviews.first { print("Canvas regions: \(workspace.frame) \(workspace.subviews.map { $0.frame })") }
            if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in:controller.view.bounds) {
                controller.view.cacheDisplay(in:controller.view.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/private/tmp/netvista-photos-\(width).png"))
            }
        }
    }
}
