import Foundation
import CryptoKit

/// Entirely offline. Every model-download request is intercepted and returns
/// a 256-byte GGUF-shaped fixture, never real weights or an executable.
private final class ModelingAIFakeProtocol: URLProtocol {
    enum Fixture { case normal, httpError, wrongSize, unknownSize, extraBytes, truncated, badHash, badMagic, html, unavailable, delayed, forbiddenRedirect }
    private static let lock = NSLock()
    private static var selected = Fixture.normal
    private static var recorded: [(URL,String)] = []
    private static var held: [ModelingAIFakeProtocol] = []
    static let modelData: Data = {
        var data = Data("GGUF".utf8)
        data.append(contentsOf:[3,0,0,0])
        data.append(Data(repeating:0,count:248))
        return data
    }()
    static var badMagicData: Data {
        var data = modelData; data.replaceSubrange(0..<4,with:Data("BAD!".utf8)); return data
    }
    static var requests: [(URL,String)] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func reset(_ fixture: Fixture = .normal) {
        lock.lock(); selected = fixture; recorded = []; held = []; lock.unlock()
    }
    static func finishDelayed() {
        lock.lock(); let pending = held; held = []; lock.unlock()
        for item in pending {
            // Intentionally deliver a response that was already in flight
            // even if the task was cancelled. It must never become installed.
            item.client?.urlProtocol(item,didLoad:modelData.subdata(in:8..<modelData.count))
            item.client?.urlProtocolDidFinishLoading(item)
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.recorded.append((request.url!,request.httpMethod ?? "GET")); let fixture = Self.selected; Self.lock.unlock()
        if fixture == .unavailable { client?.urlProtocol(self,didFailWithError:URLError(.cannotConnectToHost)); return }
        if fixture == .forbiddenRedirect {
            let destination = URL(string:"https://example.invalid/stolen.gguf")!
            let response = HTTPURLResponse(url:request.url!,statusCode:302,httpVersion:"HTTP/1.1",headerFields:["Location":destination.absoluteString])!
            client?.urlProtocol(self,wasRedirectedTo:URLRequest(url:destination),redirectResponse:response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var headers = ["Content-Type":fixture == .html ? "text/html" : "application/octet-stream",
                       "Content-Length":String(Self.modelData.count)]
        if fixture == .wrongSize { headers["Content-Length"] = String(Self.modelData.count+1) }
        if fixture == .unknownSize { headers.removeValue(forKey:"Content-Length") }
        let response = HTTPURLResponse(url:request.url!,statusCode:fixture == .httpError ? 503 : 200,httpVersion:"HTTP/1.1",headerFields:headers)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if fixture == .delayed {
            client?.urlProtocol(self,didLoad:Self.modelData.prefix(8))
            Self.lock.lock(); Self.held.append(self); Self.lock.unlock(); return
        }
        var data = fixture == .badMagic ? Self.badMagicData : Self.modelData
        if fixture == .badHash { data[data.count-1] = 1 }
        if fixture == .extraBytes { data.append(0) }
        if fixture == .truncated { data = data.prefix(data.count-1) }
        for offset in stride(from:0,to:data.count,by:17) {
            client?.urlProtocol(self,didLoad:data.subdata(in:offset..<min(offset+17,data.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// No process is spawned. Runtime calls record the fixed model URL, prompt and
/// structured schema, and can hold a response for cancellation/busy checks.
private final class ModelingAIFakeRuntime: ModelingAIPlanRunning {
    enum Mode { case normal, invalid, oversized, failure, pending }
    struct Call { let model:URL; let prompt:String; let schema:[String:Any] }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var waiting: [(Result<Data,Error>)->Void] = []
    private var cancelled = 0
    var mode = Mode.normal
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    var cancellations: Int { lock.lock(); defer { lock.unlock() }; return cancelled }
    func generate(model:URL,prompt:String,schema:[String:Any],completion:@escaping(Result<Data,Error>)->Void) {
        lock.lock(); recorded.append(.init(model:model,prompt:prompt,schema:schema)); let response = mode
        if response == .pending { waiting.append(completion) }
        lock.unlock()
        switch response {
        case .normal: completion(.success(try! JSONSerialization.data(withJSONObject:ModelingAIChecks.plan)))
        case .invalid: var plan = ModelingAIChecks.plan; plan["script"] = "execute bad code"; completion(.success(try! JSONSerialization.data(withJSONObject:plan)))
        case .oversized: completion(.success(Data(repeating:0x20,count:33000)))
        case .failure: completion(.failure(URLError(.cannotParseResponse)))
        case .pending: break
        }
    }
    func cancel() { lock.lock(); cancelled += 1; lock.unlock() }
    func finishPending(twice:Bool = false) {
        lock.lock(); let pending = waiting; waiting = []; lock.unlock()
        for completion in pending {
            let data = try! JSONSerialization.data(withJSONObject:ModelingAIChecks.plan)
            completion(.success(data)); if twice { completion(.success(data)) }
        }
    }
}

@main struct ModelingAIChecks {
    static let plan: [String:Any] = ["version":1,"title":"A sculpting base","explanation":"Start with a sphere, then shape it with sculpt brushes.",
        "actions":[["kind":"addPrimitive","primitive":"Sculpt Sphere","name":"Sculpting base",
                    "position":["x":0,"y":1,"z":0],"scale":["x":2,"y":2,"z":2],"colour":"#48AD9A"]]]
    static let context = ModelingAIContext(objectCount:3,selectedName:"Character",selectedVertices:100,selectedFaces:96)
    static let filename = "Qwen2.5-0.5B-Q4_K_M-v1"
    static func json(_ object: [String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:object) }
    static func digest(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func spec(data:Data = ModelingAIFakeProtocol.modelData) -> ModelingAIModelSpec {
        .init(url:URL(string:"https://huggingface.co/netvista-test/fixture/resolve/pinned/model.gguf")!,bytes:Int64(data.count),sha256:digest(data))
    }
    static func rejects(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Invalid modeling input was accepted") } catch {}
    }
    static func wait(_ message:String,timeout:TimeInterval = 5,until:()->Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !until() && Date() < deadline { _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01)) }
        precondition(until(),"Timed out: \(message)")
    }
    static func drain() { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
    private static func service(root:URL,modelSpec:ModelingAIModelSpec? = nil,runtime:ModelingAIFakeRuntime = ModelingAIFakeRuntime()) -> ModelingAI {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ModelingAIFakeProtocol.self]
        return ModelingAI(storageDirectory:root,sessionConfiguration:configuration,modelSpec:modelSpec ?? spec(),runtime:runtime)
    }
    static func checkPlans() throws {
        let valid = try ModelingAIPlan.decode(json(plan),context:context)
        precondition(valid.actions.first?.kind == .addPrimitive && valid.actions.first?.position?.y == 1)
        let detail = ModelingAIPlan(title:"More surface detail",explanation:"A controlled refinement.",actions:[.init(kind:.subdivideSelected,levels:2),.init(kind:.smoothSelected,iterations:3)])
        try detail.validate(context:context)
        try ModelingAIPlan(title:"Dragon base",explanation:"A starting shape for hand sculpting.",actions:[.init(kind:.dragonStarter)]).validate(context:context)
        rejects { try detail.validate(context:.init()) }
        rejects { try ModelingAIPlan(title:"Too much detail",explanation:"",actions:[.init(kind:.subdivideSelected,levels:2),.init(kind:.subdivideSelected,levels:2)]).validate(context:context) }
        rejects { try ModelingAIPlan(title:"Too much smoothing",explanation:"",actions:[.init(kind:.smoothSelected,iterations:5),.init(kind:.smoothSelected,iterations:5)]).validate(context:context) }
        rejects { try ModelingAIPlan(title:"Too many shapes",explanation:"",actions:(0..<9).map { _ in .init(kind:.addPrimitive,primitive:"Cube") }).validate() }
        rejects { try ModelingAIPlan(title:"Too many parts",explanation:"",actions:[.init(kind:.dragonStarter)]).validate(context:.init(objectCount:250)) }
        for invalid in [ModelingAIAction(kind:.addPrimitive,primitive:"ExecuteScript"),
            .init(kind:.addPrimitive,primitive:"Cube",position:.init(x:1e8)),
            .init(kind:.addPrimitive,primitive:"Cube",scale:.init(x:0,y:1,z:1)),
            .init(kind:.addPrimitive,primitive:"Sphere",name:"https://example.invalid/model"),
            .init(kind:.addPrimitive,primitive:"Cube",colour:"red"),.init(kind:.dragonStarter,primitive:"Cube"),
            .init(kind:.subdivideSelected,levels:99),.init(kind:.smoothSelected,iterations:0)] {
            rejects { try ModelingAIPlan(title:"Invalid",explanation:"",actions:[invalid]).validate(context:context) }
        }
        for title in ["#!/bad","```swift","javascript:bad","rm -rf something"] {
            rejects { try ModelingAIPlan(title:title,explanation:"",actions:[.init(kind:.dragonStarter)]).validate() }
        }
        for field in ["script","command","url","file","physicsCode","download"] {
            var bad = plan; bad[field] = "bad"; rejects { _ = try ModelingAIPlan.decode(json(bad)) }
            bad = plan; var actions = bad["actions"] as! [[String:Any]]; actions[0][field] = "bad"; bad["actions"] = actions
            rejects { _ = try ModelingAIPlan.decode(json(bad)) }
        }
        var malformed = plan
        malformed["actions"] = [["kind":"addPrimitive","primitive":"Cube","position":["x":0,"y":0,"z":0,"script":"bad"]]]
        rejects { _ = try ModelingAIPlan.decode(json(malformed)) }
        rejects { _ = try ModelingAIPlan.decode(Data(repeating:0x20,count:33000)) }
        rejects { _ = try ModelingAIPlan.decode(Data("not json".utf8)) }
        malformed["actions"] = [["kind":"subdivideSelected","levels":Int.max]]
        rejects { _ = try ModelingAIPlan.decode(json(malformed),context:context) }
        malformed["actions"] = (0..<100).map { _ in ["kind":"dragonStarter"] }
        rejects { _ = try ModelingAIPlan.decode(json(malformed),context:context) }
        malformed["actions"] = [["kind":"addPrimitive","primitive":"Cube","position":["x":1e300,"y":0,"z":0]]]
        rejects { _ = try ModelingAIPlan.decode(json(malformed),context:context) }
        rejects { try ModelingAIContext(objectCount:Int.max).validate() }
        rejects { try ModelingAIContext(selectedVertices:Int.max).validate() }
    }
    static func main() throws {
        try checkPlans()
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("netvista-model-ai-checks-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:base,withIntermediateDirectories:false)
        defer { try? fm.removeItem(at:base) }
        func folder(_ name:String) throws -> URL {
            let url = base.appendingPathComponent(name,isDirectory:true); try fm.createDirectory(at:url,withIntermediateDirectories:false); return url
        }
        try ModelingAIModelSpec.production.validate()
        precondition(ModelingAIModelSpec.production.url.path.contains("/resolve/9217f5db79a29953eb74d5343926648285ec7e67/"),"Production weights must remain revision pinned")
        precondition(ModelingAIModelSpec.production.bytes == 491_400_032 && ModelingAIModelSpec.production.sha256 == "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db","Production weights must retain the verified upstream LFS size and hash")
        for url in ["https://huggingface.co/x.gguf","https://hf.co/x.gguf","https://cdn-lfs.huggingface.co/x.gguf","https://cdn-lfs.hf.co/x.gguf","https://cas-bridge.xethub.hf.co/x.gguf?signature=fixture","https://us.aws.cdn.hf.co/x.gguf?signature=fixture"] {
            precondition(ModelingAIModelSpec.allowedDownloadURL(URL(string:url)!),"Trusted HTTPS model/CDN URL refused")
        }
        for url in ["http://huggingface.co/x.gguf","https://example.invalid/x.gguf","https://huggingface.co.evil.invalid/x.gguf","https://us.aws.cdn.hf.co.evil.invalid/x.gguf","https://aws.cdn.hf.co/x.gguf","https://user:password@huggingface.co/x.gguf","https://huggingface.co:444/x.gguf","https://huggingface.co/x.gguf#fragment","file:///tmp/model.gguf"] {
            precondition(!ModelingAIModelSpec.allowedDownloadURL(URL(string:url)!),"Untrusted model URL accepted: \(url)")
        }
        for invalid in [ModelingAIModelSpec(url:spec().url,bytes:0,sha256:spec().sha256),
                        .init(url:spec().url,bytes:Int64.max,sha256:spec().sha256),
                        .init(url:spec().url,bytes:256,sha256:"not-a-digest"),
                        .init(url:URL(string:"https://example.invalid/model.gguf")!,bytes:256,sha256:spec().sha256)] {
            rejects { try invalid.validate() }
        }

        ModelingAIFakeProtocol.reset()
        let root = try folder("happy"), runtime = ModelingAIFakeRuntime()
        let missingService = Self.service(root:root,runtime:runtime)
        let unrelated = root.appendingPathComponent("user-owned.txt"); try Data("preserve".utf8).write(to:unrelated)
        precondition(ModelingAIFakeProtocol.requests.isEmpty && runtime.calls.isEmpty,"Creating the service must not contact a server, download or run inference")
        missingService.checkAvailability(); wait("Missing local model") { missingService.status.phase == .notDownloaded }
        precondition(ModelingAIFakeProtocol.requests.isEmpty,"Check must inspect local storage, never download")
        var missing: Result<ModelingAIPlan,Error>?
        missingService.propose(prompt:"Make a dragon",context:context) { missing = $0 }
        wait("Missing model rejection") { missing != nil }; if case .success = missing! { preconditionFailure("No model was installed") }
        precondition(runtime.calls.isEmpty && ModelingAIFakeProtocol.requests.isEmpty,"Missing model must not trigger inference or download")

        // A fresh user may press Download immediately, before any Check action.
        let directRoot = try folder("direct"), directRuntime = ModelingAIFakeRuntime()
        let direct = Self.service(root:directRoot,runtime:directRuntime)
        direct.downloadModel(); direct.downloadModel()
        wait("Explicit direct download") { direct.status.phase == .ready }
        precondition(ModelingAIFakeProtocol.requests.count == 1,"Repeated Download must start only one request")
        precondition(direct.status.isInstalled && direct.status.canGenerate && directRuntime.calls.isEmpty)
        let installed = directRoot.appendingPathComponent(filename,isDirectory:true), model = installed.appendingPathComponent("model.gguf")
        let modelData = try Data(contentsOf:model)
        precondition(modelData == ModelingAIFakeProtocol.modelData)
        for file in ["receipt.json","MODEL-LICENSE.txt"] { precondition(fm.fileExists(atPath:installed.appendingPathComponent(file).path),"Installed model must include its validation receipt and license notice") }
        precondition(ModelingAIFakeProtocol.requests.allSatisfy { $0.1 == "GET" && ModelingAIModelSpec.allowedDownloadURL($0.0) },"Only the approved HTTPS weights request is permitted")

        let requestsAfterDownload = ModelingAIFakeProtocol.requests.count
        let restoredRuntime = ModelingAIFakeRuntime(), restored = Self.service(root:directRoot,runtime:restoredRuntime)
        restored.checkAvailability(); wait("Installed model after relaunch") { restored.status.phase == .ready }
        precondition(ModelingAIFakeProtocol.requests.count == requestsAfterDownload && restoredRuntime.calls.isEmpty,"Disk-ready persistence must not use the network or start a model process")
        var proposal: Result<ModelingAIPlan,Error>?
        restored.propose(prompt:"Make a sculpting base",context:context) { proposal = $0 }
        wait("Local proposal") { proposal != nil }
        let decoded = try proposal!.get(), expected = try ModelingAIPlan.decode(json(plan),context:context)
        precondition(decoded == expected && restoredRuntime.calls.count == 1)
        let call = restoredRuntime.calls[0]
        precondition(call.model.standardizedFileURL == model.standardizedFileURL && call.prompt.contains("Make a sculpting base") && call.schema["additionalProperties"] as? Bool == false)
        precondition(ModelingAIFakeProtocol.requests.count == requestsAfterDownload,"Inference must be local, with no prompt uploads")
        var tooBig: Result<ModelingAIPlan,Error>?
        restored.propose(prompt:String(repeating:"x",count:1601),context:context) { tooBig = $0 }
        wait("Input limit") { tooBig != nil }; if case .success = tooBig! { preconditionFailure("Oversized prompt accepted") }
        precondition(restoredRuntime.calls.count == 1,"Reject input before launching inference")

        for mode in [ModelingAIFakeRuntime.Mode.invalid,.oversized,.failure] {
            restoredRuntime.mode = mode; var result: Result<ModelingAIPlan,Error>?
            restored.propose(prompt:"Make something",context:context) { result = $0 }
            wait("Invalid local inference output") { result != nil }; if case .success = result! { preconditionFailure("Malformed model output accepted") }
        }
        restoredRuntime.mode = .pending
        var pendingResult: Result<ModelingAIPlan,Error>?, busyResult: Result<ModelingAIPlan,Error>?
        let before = restoredRuntime.calls.count
        restored.propose(prompt:"First plan",context:context) { pendingResult = $0 }
        wait("Pending local inference") { restored.status.phase == .generating && restoredRuntime.calls.count == before+1 }
        restored.propose(prompt:"Second plan",context:context) { busyResult = $0 }
        wait("Concurrent proposal rejection") { busyResult != nil }; if case .success = busyResult! { preconditionFailure("Two simultaneous inference jobs accepted") }
        precondition(restoredRuntime.calls.count == before+1,"Only one inference process may be running")
        restored.cancel(); wait("Cancelled local inference") { pendingResult != nil && !restored.status.isBusy }
        if case .success = pendingResult! { preconditionFailure("Cancelled inference succeeded") }
        precondition(restoredRuntime.cancellations > 0)
        restoredRuntime.finishPending(); drain()
        if case .success = pendingResult! { preconditionFailure("Late inference callback replaced cancellation") }
        var duplicateCallbacks = 0
        let callsBeforeDuplicate = restoredRuntime.calls.count
        restored.propose(prompt:"One complete plan",context:context) { result in
            duplicateCallbacks += 1
            if case .failure = result { preconditionFailure("Valid plan failed") }
        }
        wait("Second pending local inference") { restoredRuntime.calls.count == callsBeforeDuplicate+1 }
        restoredRuntime.finishPending(twice:true)
        wait("First complete inference callback") { duplicateCallbacks == 1 && restored.status.phase == .ready }
        drain(); precondition(duplicateCallbacks == 1,"Duplicate or late runtime completion must never apply/report a plan twice")

        for fixture in [ModelingAIFakeProtocol.Fixture.httpError,.wrongSize,.extraBytes,.truncated,.badHash,.html,.unavailable] {
            ModelingAIFakeProtocol.reset(fixture)
            let invalidRoot = try folder("invalid-\(fixture)"), invalid = Self.service(root:invalidRoot)
            invalid.downloadModel(); wait("Reject invalid download \(fixture)") { invalid.status.phase == .failed }
            precondition(!invalid.status.isInstalled && !fm.fileExists(atPath:invalidRoot.appendingPathComponent(filename).path),"Invalid model bytes must never become installed")
            if fixture == .badHash {
                ModelingAIFakeProtocol.reset(); invalid.downloadModel(); wait("Retry after a rejected download") { invalid.status.phase == .ready }
            }
        }
        // Vendor CDNs may stream without Content-Length. The pinned byte cap,
        // complete byte count and SHA still determine whether installation is safe.
        ModelingAIFakeProtocol.reset(.unknownSize)
        let chunked = Self.service(root:try folder("chunked")); chunked.downloadModel()
        wait("Exact pinned model with unknown CDN length") { chunked.status.phase == .ready }
        precondition(chunked.status.isInstalled)
        ModelingAIFakeProtocol.reset(.badMagic)
        let magicRoot = try folder("bad-magic"), magic = Self.service(root:magicRoot,modelSpec:spec(data:ModelingAIFakeProtocol.badMagicData))
        magic.downloadModel(); wait("Reject invalid GGUF magic with matching size/hash") { magic.status.phase == .failed }
        precondition(!magic.status.isInstalled)
        ModelingAIFakeProtocol.reset(.forbiddenRedirect)
        let redirect = Self.service(root:try folder("redirect")); redirect.downloadModel()
        wait("Reject external redirect") { redirect.status.phase == .failed }
        precondition(ModelingAIFakeProtocol.requests.count == 1 && ModelingAIFakeProtocol.requests.allSatisfy { $0.0.host != "example.invalid" },"A forbidden redirect must not contact its target")

        ModelingAIFakeProtocol.reset(.delayed)
        let cancelledRoot = try folder("cancelled"), cancelled = Self.service(root:cancelledRoot)
        cancelled.downloadModel()
        wait("Download progress") { cancelled.status.phase == .downloading && (cancelled.status.progress ?? 0) > 0 }
        cancelled.cancel(); wait("Cancelled download") { !cancelled.status.isBusy }
        ModelingAIFakeProtocol.finishDelayed(); drain()
        precondition(!cancelled.status.isInstalled && !fm.fileExists(atPath:cancelledRoot.appendingPathComponent(filename).path),"Cancelled/late download callbacks must not install weights")
        ModelingAIFakeProtocol.reset(); cancelled.downloadModel(); wait("Retry after cancellation") { cancelled.status.phase == .ready }

        // Remove only the exact owned model directory and retain user files.
        let keep = directRoot.appendingPathComponent("other-model.bin"); try Data("untouched".utf8).write(to:keep)
        restored.removeModel(); wait("Explicit model removal") { restored.status.phase == .notDownloaded }
        let keepData = try Data(contentsOf:keep)
        precondition(!fm.fileExists(atPath:installed.path) && keepData == Data("untouched".utf8))
        precondition(ModelingAIFakeProtocol.requests.count == 1,"Removal must not contact the network")

        // Local corruption is detected on relaunch before inference, without
        // automatically redownloading or deleting the suspect files.
        var corrupted = ModelingAIFakeProtocol.modelData; corrupted[corrupted.count-1] = 99
        let cancelledModel = cancelledRoot.appendingPathComponent(filename).appendingPathComponent("model.gguf")
        try corrupted.write(to:cancelledModel)
        let requestsBeforeCorruption = ModelingAIFakeProtocol.requests.count
        let corruptedRuntime = ModelingAIFakeRuntime(), corrupt = Self.service(root:cancelledRoot,runtime:corruptedRuntime)
        corrupt.checkAvailability(); wait("Corrupt model refusal") { corrupt.status.phase == .failed }
        precondition(!corrupt.status.isInstalled && corruptedRuntime.calls.isEmpty && ModelingAIFakeProtocol.requests.count == requestsBeforeCorruption)

        let outside = try folder("outside"), sentinel = outside.appendingPathComponent("do-not-remove.txt")
        try Data("safe".utf8).write(to:sentinel)
        let linkedRoot = base.appendingPathComponent("linked-root")
        try fm.createSymbolicLink(at:linkedRoot,withDestinationURL:outside)
        let linked = Self.service(root:linkedRoot); linked.downloadModel()
        wait("Storage symlink refusal") { linked.status.phase == .failed }
        let sentinelAfterDownload = try Data(contentsOf:sentinel)
        precondition(sentinelAfterDownload == Data("safe".utf8))
        let linkedInstallRoot = try folder("linked-install")
        try fm.createSymbolicLink(at:linkedInstallRoot.appendingPathComponent(filename),withDestinationURL:outside)
        let linkedInstall = Self.service(root:linkedInstallRoot); linkedInstall.removeModel()
        wait("Installed directory symlink refusal") { linkedInstall.status.phase == .failed }
        let sentinelAfterRemove = try Data(contentsOf:sentinel)
        precondition(sentinelAfterRemove == Data("safe".utf8))

        // A cached install cannot substitute a receipt or model through links,
        // enlarge receipts without limit, or claim a different pinned version.
        let chunkedDirectory = chunked.installedDirectory
        let receipt = chunkedDirectory.appendingPathComponent("receipt.json")
        let originalReceipt = try Data(contentsOf:receipt)
        let requestsBeforeBadReceipts = ModelingAIFakeProtocol.requests.count
        for invalidReceipt in [Data(repeating:0x20,count:65_537),Data("{\"version\":2,\"bytes\":256,\"sha256\":\"\(spec().sha256)\"}".utf8),Data("{}".utf8)] {
            try invalidReceipt.write(to:receipt)
            let invalid = Self.service(root:chunkedDirectory.deletingLastPathComponent())
            wait("Invalid receipt refusal") { invalid.status.phase == .failed }
            precondition(!invalid.status.isInstalled)
        }
        try fm.removeItem(at:receipt)
        try fm.createSymbolicLink(at:receipt,withDestinationURL:sentinel)
        let receiptLink = Self.service(root:chunkedDirectory.deletingLastPathComponent())
        wait("Receipt symlink refusal") { receiptLink.status.phase == .failed }
        try fm.removeItem(at:receipt); try originalReceipt.write(to:receipt)
        let chunkedModel = chunkedDirectory.appendingPathComponent("model.gguf")
        let outsideModel = outside.appendingPathComponent("not-owned.gguf")
        try ModelingAIFakeProtocol.modelData.write(to:outsideModel)
        try fm.removeItem(at:chunkedModel)
        try fm.createSymbolicLink(at:chunkedModel,withDestinationURL:outsideModel)
        let fileLink = Self.service(root:chunkedDirectory.deletingLastPathComponent())
        wait("Model file symlink refusal") { fileLink.status.phase == .failed }
        precondition(ModelingAIFakeProtocol.requests.count == requestsBeforeBadReceipts,"Corrupt/linked cache must never trigger a repair download")
        fileLink.removeModel(); wait("Remove linked contents without touching outside targets") { fileLink.status.phase == .notDownloaded }
        let preservedOutsideModel = try Data(contentsOf:outsideModel), preservedSentinel = try Data(contentsOf:sentinel)
        precondition(preservedOutsideModel == ModelingAIFakeProtocol.modelData && preservedSentinel == Data("safe".utf8))

        // The downloader itself must atomically refuse a dangling link. A
        // fileExists/createFile sequence can otherwise create the link target.
        let rawRoot = try folder("raw-downloader")
        let linkDestination = rawRoot.appendingPathComponent("pending.gguf")
        let absentTarget = outside.appendingPathComponent("must-not-be-created.gguf")
        try fm.createSymbolicLink(at:linkDestination,withDestinationURL:absentTarget)
        let rawConfiguration = URLSessionConfiguration.ephemeral; rawConfiguration.protocolClasses = [ModelingAIFakeProtocol.self]
        let requestsBeforeRaw = ModelingAIFakeProtocol.requests.count
        rejects {
            _ = try ModelingAIModelDownload(spec:spec(),destination:linkDestination,configuration:rawConfiguration,progress:{ _ in },completion:{ _ in })
        }
        precondition(!fm.fileExists(atPath:absentTarget.path),"Pending-file creation must not follow a dangling symlink")
        let existingDestination = rawRoot.appendingPathComponent("existing.gguf")
        try Data("preserve existing".utf8).write(to:existingDestination)
        rejects {
            _ = try ModelingAIModelDownload(spec:spec(),destination:existingDestination,configuration:rawConfiguration,progress:{ _ in },completion:{ _ in })
        }
        let existingData = try Data(contentsOf:existingDestination)
        precondition(existingData == Data("preserve existing".utf8),"The pending downloader must not truncate existing files")
        precondition(ModelingAIFakeProtocol.requests.count == requestsBeforeRaw,"Rejected file creation must not start a request")
        precondition(fm.fileExists(atPath:unrelated.path),"Unrelated initial storage must stay intact")
        print("PASS: strict native plans, opt-in direct download, HTTPS allowlist, streaming size/GGUF/SHA validation, progress/cancel/retry, persistent ready state, exact removal, symlink/corruption refusal and single local inference cancellation — no real model downloaded or process launched")
    }
}
