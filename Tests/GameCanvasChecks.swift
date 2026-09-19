import Cocoa

@main struct GameCanvasChecks {
    static func main() throws {
        _ = NSApplication.shared
        let canvas = GameGraphCanvas()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:440),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = canvas
        let action = GameAction(kind:.move,x:2)
        var rule = GameRule(actions:[action]); rule.graph = .chain(rule); rule.graph?.wires = []
        canvas.rule = rule
        var commits = 0
        canvas.modified = { graph in rule.graph = graph; canvas.rule = rule; commits += 1 }
        func event(_ type:NSEvent.EventType,_ p:NSPoint,_ flags:NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:canvas.convert(p,to:nil),modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        }
        canvas.mouseDown(with:event(.leftMouseDown,NSPoint(x:250,y:105)))
        canvas.mouseDragged(with:event(.leftMouseDragged,NSPoint(x:320,y:105)))
        canvas.mouseUp(with:event(.leftMouseUp,NSPoint(x:320,y:105)))
        precondition(rule.graph?.wires == [GameWire(from:rule.id,to:action.id)],"Dragging sockets must create a real wire")
        canvas.mouseDown(with:event(.leftMouseDown,NSPoint(x:350,y:65)))
        canvas.mouseDragged(with:event(.leftMouseDragged,NSPoint(x:470,y:165)))
        canvas.mouseUp(with:event(.leftMouseUp,NSPoint(x:470,y:165)))
        precondition(rule.graph?.positions.first { $0.id == action.id }?.x == 440)
        canvas.mouseDown(with:event(.leftMouseDown,NSPoint(x:440,y:205),.option))
        precondition(rule.graph?.wires.isEmpty == true && commits == 3,"Disconnect must remove only the incoming wires")
        if let bitmap = canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds) { canvas.cacheDisplay(in:canvas.bounds,to:bitmap); try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/private/tmp/netvista-node-canvas.png")) }
        print("PASS: mouse-driven port wiring, node dragging and input disconnection")
    }
}
