import Cocoa

@main struct ShareCompanionServerChecks {
    static func main() {
        let authority = SharePairingAuthority(store: ShareMemoryDeviceStore())
        let projectID = UUID(), clipID = UUID(), sceneID = UUID(), objectID = UUID()
        var project = ShareCollaborationProject(projectID: projectID, title: "LAN test", clips: [.init(id: clipID, name: "Clip")],
            scenes: [.init(id: sceneID, name: "Scene", objects: [.init(id: objectID, name: "Cube", kind: "cube")])])
        let host = ShareCollaborationHost(provider: { project }, applyColour: { _, values in project.clips[0].values = values; return true },
            applyTransform: { _, _, value in project.scenes[0].objects[0].transform = value; return true })
        let server = LocalShareServer(authority: authority, preferredPorts: Array(8897...8906),
            collaborationSnapshot: { DispatchQueue.main.sync { host.snapshot() } },
            collaborationCommand: { command, device, name in DispatchQueue.main.sync { host.process(command, deviceID: device, deviceName: name) } },
            resetCollaboration: { DispatchQueue.main.async { host.reset() } },
            previewProvider: { kind, id, _, completion in completion(kind == "clip" && id == clipID ? Data([1, 2, 3]) : nil) }
        ) { ShareProjectSnapshot(title: "LAN test", mediaCount: 0, clipCount: 1, sceneCount: 1, timelineDuration: 1, manifestData: Data("{}".utf8), manifestFilename: "summary.json", media: []) }
        var started = false
        server.onStateChange = { state in
            guard !started, state.phase == .ready, let base = state.primaryURL else { return }
            started = true
            DispatchQueue.global().async {
                let configuration = URLSessionConfiguration.ephemeral; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.connectionProxyDictionary = [:]
                let session = URLSession(configuration: configuration)
                func request(_ path: String, method: String = "GET", cookie: String? = nil, csrf: String? = nil, origin: String? = nil, body: Data? = nil) -> (Int, Data) {
                    let wait = DispatchSemaphore(value: 0)
                    var answer = (0, Data())
                    var request = URLRequest(url: URL(string: path, relativeTo: base)!)
                    request.httpMethod = method; request.timeoutInterval = 8; request.httpBody = body
                    if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
                    if let csrf { request.setValue(csrf, forHTTPHeaderField: "X-NetVista-CSRF") }
                    if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
                    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
                    session.dataTask(with: request) { data, response, _ in answer = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()); wait.signal() }.resume()
                    precondition(wait.wait(timeout: .now() + 10) == .success)
                    return answer
                }
                let challenge = authority.activeChallenge()!
                guard case .paired(let tokenA) = authority.pair(code: challenge.code, clientID: "a") else { fatalError() }
                let newCode = authority.issueCode()
                guard case .paired(let tokenB) = authority.pair(code: newCode.code, clientID: "b") else { fatalError() }
                let cookieA = "nv_device=\(tokenA)", cookieB = "nv_device=\(tokenB)"
                func csrf(_ cookie: String) -> String {
                    let response = request("/", cookie: cookie)
                    precondition(response.0 == 200)
                    let html = String(decoding: response.1, as: UTF8.self)
                    return html.components(separatedBy: "const csrf=\"")[1].components(separatedBy: "\"")[0]
                }
                let csrfA = csrf(cookieA), csrfB = csrf(cookieB), origin = String(base.absoluteString.dropLast())
                precondition(csrfA != csrfB)
                precondition(request("/api/project").0 == 401)
                precondition(request("/preview.jpg?kind=clip&id=\(clipID)&time=0").0 == 401)
                func post(_ command: ShareCollaborationCommand, cookie: String, csrf: String?, origin: String?) -> (Int, ShareCollaborationResult?) {
                    let response = request("/api/command", method: "POST", cookie: cookie, csrf: csrf, origin: origin, body: try! JSONEncoder().encode(command))
                    return (response.0, try? JSONDecoder().decode(ShareCollaborationResult.self, from: response.1))
                }
                let joinColour = ShareCollaborationCommand(kind: .join, projectID: projectID, domain: .colour)
                precondition(post(joinColour, cookie: cookieA, csrf: nil, origin: origin).0 == 403)
                precondition(post(joinColour, cookie: cookieA, csrf: csrfA, origin: "http://evil.example").0 == 403)
                precondition(post(joinColour, cookie: cookieA, csrf: csrfA, origin: nil).0 == 403)
                precondition(post(joinColour, cookie: cookieA, csrf: csrfB, origin: origin).0 == 403)
                let colour = post(joinColour, cookie: cookieA, csrf: csrfA, origin: origin).1!
                let scene = post(.init(kind: .join, projectID: projectID, domain: .scene), cookie: cookieB, csrf: csrfB, origin: origin).1!
                precondition(colour.status == .ok && scene.status == .ok && scene.snapshot.sessions.count == 2)
                var values = ShareColourValues(); values.exposure = 1.5
                let command = ShareCollaborationCommand(kind: .colour, projectID: projectID, sessionID: colour.sessionID, targetID: clipID, expectedRevision: colour.snapshot.clips[0].revision, colour: values)
                precondition(post(command, cookie: cookieB, csrf: csrfB, origin: origin).1?.status == .unauthorized)
                let applied = post(command, cookie: cookieA, csrf: csrfA, origin: origin).1!
                precondition(applied.status == .ok && applied.snapshot.clips[0].values.exposure == 1.5)
                var stale = command; stale.id = UUID(); stale.colour?.exposure = 2
                precondition(post(stale, cookie: cookieA, csrf: csrfA, origin: origin).1?.status == .conflict)
                let preview = request("/preview.jpg?kind=clip&id=\(clipID)&time=0", cookie: cookieA)
                precondition(preview.0 == 200 && preview.1 == Data([1, 2, 3]))
                precondition(request("/preview.jpg?kind=clip&id=\(UUID())&time=0", cookie: cookieA).0 == 404)
                precondition(request("/preview.jpg?kind=clip&id=\(clipID)&time=nan", cookie: cookieA).0 == 400)
                authority.forgetAllDevices()
                precondition(request("/api/project", cookie: cookieA).0 == 401)
                precondition(post(command, cookie: cookieA, csrf: csrfA, origin: origin).0 == 401)
                server.stop(); session.invalidateAndCancel()
                print("PASS: LAN companion cookies, per-device CSRF/origin enforcement, device-bound slots, concurrent domains, persisted grade, stale-write conflict, bounded authorized preview, revocation")
                exit(0)
            }
        }
        server.startWithNewCode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { fatalError("Companion server checks timed out") }
        RunLoop.main.run()
    }
}
