import Cocoa
import CryptoKit

/// Native UI tests use tiny fixture bytes and an intercepted URLSession.
/// Neither weights nor a runtime executable are downloaded or launched.
private final class ModelingToolsDownloadProtocol: URLProtocol {
    enum Mode { case normal, held, failure }
    private static let lock = NSLock()
    private static var mode = Mode.normal
    private static var count = 0
    static let data: Data = {
        var result = Data("GGUF".utf8); result.append(contentsOf:[3,0,0,0]); result.append(Data(repeating:0,count:248)); return result
    }()
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset(_ new: Mode = .normal) { lock.lock(); mode = new; count = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let mode = Self.mode; Self.lock.unlock()
        let response = HTTPURLResponse(url:request.url!,statusCode:mode == .failure ? 503 : 200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/octet-stream","Content-Length":String(Self.data.count)])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if mode == .held { client?.urlProtocol(self,didLoad:Self.data.prefix(8)); return }
        client?.urlProtocol(self,didLoad:Self.data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ModelingToolsRuntime: ModelingAIPlanRunning {
    private(set) var calls = 0
    func generate(model:URL,prompt:String,schema:[String:Any],completion:@escaping(Result<Data,Error>)->Void) {
        calls += 1
        let plan = ModelingAIPlan(title:"A starter",explanation:"A native sphere for manual sculpting.",actions:[.init(kind:.addPrimitive,primitive:"Sphere")])
        completion(.success(try! JSONEncoder().encode(plan)))
    }
    func cancel() {}
}

@main struct ModelingToolsChecks {
    static func buttons(_ view:NSView) -> [GameButton] {
        (view as? GameButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    static func window(_ controller:NSViewController) -> NSWindow {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:450),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.appearance = NSAppearance(named:.darkAqua)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.orderFront(nil); window.layoutIfNeeded(); controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until:Date().addingTimeInterval(0.1)); return window
    }
    static func layout(_ controller:NSViewController,_ window:NSWindow,_ label:String) throws {
        for width in [680,620] {
            window.setContentSize(NSSize(width:width,height:450)); window.layoutIfNeeded(); controller.view.layoutSubtreeIfNeeded()
            for button in buttons(controller.view) {
                let frame = button.convert(button.bounds,to:controller.view)
                precondition(frame.minX >= 0 && frame.maxX <= controller.view.bounds.width+1,"\(button.title) must fit inside the native utility window")
            }
        }
        let view = controller.view
        if let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in:view.bounds,to:bitmap) }
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/private/tmp/netvista-modeling-\(label)-ui.png"))
        }
    }
    static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named:.darkAqua)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NetVistaModelingTools-"+UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ModelingToolsDownloadProtocol.self]
        let fixture = ModelingToolsDownloadProtocol.data
        let spec = ModelingAIModelSpec(url:URL(string:"https://huggingface.co/netvista-test/fixture/resolve/pinned/model.gguf")!,bytes:Int64(fixture.count),sha256:SHA256.hash(data:fixture).map { String(format:"%02x",$0) }.joined())
        let runtime = ModelingToolsRuntime()
        let service = ModelingAI(storageDirectory:directory,sessionConfiguration:config,modelSpec:spec,runtime:runtime)
        ModelingToolsDownloadProtocol.reset()
        let before = service.status.phase
        var applied = 0
        let assist = ModelingAssistController(context:{ .init() },stamp:{ "test" },apply:{ _ in applied += 1 },service:service)
        let aiWindow = window(assist)
        let aiButtons = buttons(assist.view)
        for title in ["Check installation","Download model…","Ask local AI","Apply Plan","Cancel","Not now","Remove model…"] {
            precondition(aiButtons.contains { $0.title == title })
        }
        func aiButton(_ title:String) -> GameButton { buttons(assist.view).first { $0.title == title }! }
        func wait(_ title:String,until:()->Bool) {
            let deadline = Date().addingTimeInterval(4)
            while !until() && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
            precondition(until(),"Timed out: \(title)")
            RunLoop.current.run(until:Date().addingTimeInterval(0.02))
        }
        precondition(aiButtons.first { $0.title == "Apply Plan" }?.isEnabled == false)
        precondition(aiButtons.first { $0.title == "Ask local AI" }?.isEnabled == false)
        precondition(aiButton("Download model…").isEnabled && !aiButton("Remove model…").isEnabled,"Explicit Download works before any Check")
        precondition(service.status.phase == before && applied == 0 && runtime.calls == 0 && ModelingToolsDownloadProtocol.requests == 0,"Opening the helper must not check/download/generate or change a scene")
        precondition(!aiButtons.contains { $0.title.contains("Ollama") },"The bundled helper must not require installing a second app")
        aiButton("Not now").invoke?(); precondition(!aiWindow.isVisible && ModelingToolsDownloadProtocol.requests == 0 && applied == 0)
        aiWindow.orderFront(nil)
        #if MODELING_TOOLS_CHECKS
        assist.downloadConfirmationForTesting = { false }
        aiButton("Download model…").invoke?()
        precondition(ModelingToolsDownloadProtocol.requests == 0 && service.status.phase == before,"Declining confirmation must not start a request")
        assist.downloadConfirmationForTesting = { true }
        ModelingToolsDownloadProtocol.reset(.held)
        aiButton("Download model…").invoke?()
        wait("Visible progress") { service.status.phase == .downloading && (service.status.progress ?? 0) > 0 }
        precondition(!aiButton("Download model…").isEnabled && !aiButton("Not now").isEnabled && aiButton("Cancel").isEnabled)
        func indicators(_ v:NSView) -> [NSProgressIndicator] { (v as? NSProgressIndicator).map { [$0] } ?? v.subviews.flatMap(indicators) }
        precondition(indicators(assist.view).contains { !$0.isHidden && !$0.isIndeterminate && $0.doubleValue > 0 },"Download progress is a visible native bar")
        aiButton("Cancel").invoke?()
        wait("Cancel restores download") { !service.status.isBusy }
        precondition(aiButton("Download model…").isEnabled && aiButton("Not now").isEnabled && applied == 0)
        ModelingToolsDownloadProtocol.reset(.failure)
        aiButton("Download model…").invoke?()
        wait("Failed download") { service.status.phase == .failed }
        precondition(aiButton("Retry download…").isEnabled && !aiButton("Ask local AI").isEnabled)
        ModelingToolsDownloadProtocol.reset()
        aiButton("Retry download…").invoke?()
        wait("Ready without preliminary Check") { service.status.phase == .ready }
        precondition(!aiButton("Downloaded").isEnabled && aiButton("Ask local AI").isEnabled && aiButton("Remove model…").isEnabled)
        let beforeCheck = ModelingToolsDownloadProtocol.requests
        aiButton("Check installation").invoke?()
        wait("Disk-only installation check") { service.status.phase == .ready }
        precondition(ModelingToolsDownloadProtocol.requests == beforeCheck,"Checking installation is local-only")
        aiButton("Ask local AI").invoke?()
        wait("Review plan") { aiButton("Apply Plan").isEnabled }
        precondition(runtime.calls == 1 && applied == 0,"Local generation only proposes a plan")
        assist.removalConfirmationForTesting = { false }
        aiButton("Remove model…").invoke?(); precondition(service.status.isInstalled && aiButton("Apply Plan").isEnabled)
        assist.removalConfirmationForTesting = { true }
        aiButton("Remove model…").invoke?()
        wait("Removed model") { service.status.phase == .notDownloaded }
        precondition(aiButton("Download model…").isEnabled && !aiButton("Ask local AI").isEnabled && !aiButton("Apply Plan").isEnabled && applied == 0,"Removal clears stale proposals without changing the scene")
        precondition(!FileManager.default.fileExists(atPath:service.modelFile.path))
        #endif
        try layout(assist,aiWindow,"ai-helper"); aiWindow.orderOut(nil)

        var state = ModelingPhysicsPreview.State.stopped, time:TimeInterval = 0, pauses = 0
        let physics = ModelingPhysicsController(read:{ (state,time,1) },play:{ state = .playing },pause:{ pauses += 1; state = .paused },step:{ state = .paused; time += 1.0/60.0 },reset:{ state = .stopped; time = 0 },bake:{ time = 0 })
        let physicsWindow = window(physics)
        func button(_ title:String) -> GameButton { buttons(physics.view).first { $0.title == title }! }
        precondition(!button("Pause").isEnabled && !button("Bake pose to mesh").isEnabled)
        button("Play").invoke?(); precondition(state == .playing && button("Pause").isEnabled && !button("Play").isEnabled)
        button("Pause").invoke?(); precondition(state == .paused && button("Play").isEnabled)
        button("Step 1 frame").invoke?(); precondition(time > 0 && button("Bake pose to mesh").isEnabled)
        button("Reset").invoke?(); precondition(time == 0 && !button("Bake pose to mesh").isEnabled)
        try layout(physics,physicsWindow,"physics")
        button("Play").invoke?(); let previousPauses = pauses; physicsWindow.close()
        precondition(pauses == previousPauses+1 && state == .paused,"Closing a physics utility pauses its timer; resigning key does not")
        print("PASS: native initial Download/no automatic activity, consent/Not now, visible progress/cancel/retry, disk-only checks, local plan review and confirmed removal; physics transport unchanged; both utility layouts fit at 620 and 680 points")
    }
}
