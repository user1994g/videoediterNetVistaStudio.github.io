import Cocoa

@main struct ModelingEditorChecks {
    static func main() throws {
        _ = NSApplication.shared
        let controller = ModelingEditorController()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:840),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width:1280,height:840)); window.orderFront(nil)
        window.layoutIfNeeded(); controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until:Date().addingTimeInterval(0.2))
        try controller.checkEditing()
        try controller.checkRegions()
        try controller.checkModelingWorkflow()
        try controller.checkSculpting()
        try controller.checkAdvancedModeling()
        try controller.checkPhysicsIntegration()
        for (w,h) in [(1280,840),(1050,680)] {
            window.setContentSize(NSSize(width:w,height:h)); window.layoutIfNeeded(); controller.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until:Date().addingTimeInterval(0.1)); try controller.checkRendering("\(w)")
        }
        window.orderOut(nil)
        print("PASS: modelling viewport renders and layout fits both window sizes")
    }
}
