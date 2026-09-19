import Cocoa

extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex,radix:16) ?? 0
        self.init(deviceRed:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255,alpha:1)
    }
}
@main struct StudioHomeChecks {
    static func main() throws {
        _ = NSApplication.shared
        let controller = WelcomeViewController()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1160,height:720),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.contentViewController = controller
        controller.checkRecentFiltering()
        // Offscreen only: never orderFront or activate.
        for (width,height) in [(1160,720),(900,578),(1240,880),(1726,1075)] {
            window.setContentSize(NSSize(width:width,height:height)); window.layoutIfNeeded(); controller.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until:Date().addingTimeInterval(0.15))
            controller.checkHomeActions()
            try controller.checkRecentRouting()
            precondition(controller.view.frame.size == NSSize(width:width,height:height))
            if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in:controller.view.bounds) {
                controller.view.cacheDisplay(in:controller.view.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/private/tmp/netvista-home-\(width).png"))
            }
            print("PASS: Studio Home \(width)×\(height), editor and recent-file routes, filters, scroll navigation, no horizontal overflow")
        }
    }
}
