// Run with ShareServer.swift and its companion sources, not the app's entry point.
import Cocoa
import Darwin

@main struct ShareServerChecks {
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private struct Response {
        let status: Int
        let body: Data
        let http: HTTPURLResponse

        func header(_ name: String) -> String? { http.value(forHTTPHeaderField: name) }
    }

    private final class ResponseBox {
        private let lock = NSLock()
        private var response: Response?
        private var error: Error?

        func complete(data: Data?, response: URLResponse?, error: Error?) {
            lock.lock(); defer { lock.unlock() }
            if let http = response as? HTTPURLResponse {
                self.response = Response(status: http.statusCode, body: data ?? Data(), http: http)
            }
            self.error = error
        }

        func result() -> Response {
            lock.lock(); defer { lock.unlock() }
            guard let response, error == nil else {
                fatalError("Local HTTP request failed: \(error?.localizedDescription ?? "no HTTP response")")
            }
            return response
        }
    }

    private static func waitForPhase(_ phase: LocalShareServerPhase, on server: LocalShareServer,
                                     action: () -> Void) -> LocalShareServerState {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var reached: LocalShareServerState?
        server.onStateChange = { state in
            guard state.phase == phase else { return }
            lock.lock()
            let first = reached == nil
            if first { reached = state }
            lock.unlock()
            if first { done.signal() }
        }
        action()
        precondition(done.wait(timeout: .now() + 8) == .success, "Server did not reach \(phase)")
        lock.lock(); defer { lock.unlock() }
        return reached!
    }

    static func main() {
        let authority = SharePairingAuthority(store: ShareMemoryDeviceStore())
        let mediaID = UUID()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data(repeating: 42, count: 12 * 1024 * 1024)
        try! bytes.write(to: file)
        let snapshot = ShareProjectSnapshot(title: "Share test", mediaCount: 1, clipCount: 0,
            sceneCount: 0, timelineDuration: 0, manifestData: Data("{}".utf8),
            manifestFilename: "test.json", media: [ShareMediaResource(id: mediaID, name: "test.bin", kind: "video", duration: 0, fileURL: file)])
        let server = LocalShareServer(authority: authority, advertisesBonjour: false) { snapshot }
        var started = false
        server.onStateChange = { state in
            guard !started, state.phase == .ready, let url = state.primaryURL else { return }
            started = true
            DispatchQueue.global().async {
                defer { try? FileManager.default.removeItem(at: file) }
                var baseURL = url
                let configuration = URLSessionConfiguration.ephemeral
                configuration.connectionProxyDictionary = [:]
                configuration.httpShouldSetCookies = false
                configuration.httpCookieStorage = nil
                let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                func request(_ path: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) -> Response {
                    let done = DispatchSemaphore(value: 0)
                    let box = ResponseBox()
                    var request = URLRequest(url: baseURL.appendingPathComponent(path))
                    request.httpMethod = method
                    request.httpBody = body
                    request.timeoutInterval = 5
                    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                    session.dataTask(with: request) { data, response, error in
                        box.complete(data: data, response: response, error: error)
                        done.signal()
                    }.resume()
                    precondition(done.wait(timeout: .now() + 8) == .success)
                    return box.result()
                }
                let landing = request("")
                precondition(landing.status == 200)
                precondition(Int(landing.header("Content-Length") ?? "") == landing.body.count)
                let landingHead = request("", method: "HEAD")
                precondition(landingHead.status == 200 && landingHead.body.isEmpty)
                precondition((Int(landingHead.header("Content-Length") ?? "") ?? 0) > 0, "HEAD must declare the GET body length")
                precondition(server.currentState().remoteConnectionCount == 0, "Local self-test must not claim a phone connected")
                let fallbackReady = DispatchSemaphore(value: 0)
                let second = LocalShareServer(authority: SharePairingAuthority(store: ShareMemoryDeviceStore()),
                    preferredPorts: [UInt16(url.port!), UInt16(url.port! + 1)]) { snapshot }
                second.onStateChange = { state in
                    if state.phase == .ready {
                        precondition(state.primaryURL?.port == url.port! + 1, "Occupied port must use the next stable port")
                        fallbackReady.signal()
                    }
                }
                second.startWithNewCode()
                precondition(fallbackReady.wait(timeout: .now() + 8) == .success)
                _ = waitForPhase(.stopped, on: second) { second.stop() }
                precondition(request("manifest").status == 401)
                precondition(request("", headers: ["Host": "untrusted.example"]).status == 400)
                let pairingBody = Data("code=\(state.pairingCode!)".utf8)
                let foreignPair = request("pair", method: "POST", headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Origin": "http://untrusted.example"
                ], body: pairingBody)
                precondition(foreignPair.status == 403, "Foreign origins must not pair a device")
                precondition(authority.activeChallenge()?.code == state.pairingCode, "Rejected origin must not consume the pairing code")
                precondition(authority.pairedDeviceCount() == 0)
                let paired = request("pair", method: "POST", headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Origin": String(baseURL.absoluteString.dropLast())
                ], body: pairingBody)
                precondition(paired.status == 303 && paired.header("Location") == "/", "Pairing must redirect to the companion page")
                guard let setCookie = paired.header("Set-Cookie"),
                      let cookie = setCookie.split(separator: ";").first.map(String.init),
                      cookie.hasPrefix("nv_device=") else { fatalError("Pairing did not return a device cookie") }
                precondition(setCookie.contains("HttpOnly") && setCookie.contains("SameSite=Strict") && setCookie.contains("Path=/"))
                precondition(authority.pairedDeviceCount() == 1 && authority.activeChallenge() == nil)
                precondition(request("pair", method: "POST", body: pairingBody).status == 410, "Pairing codes must work only once")
                let manifest = request("manifest", headers: ["Cookie": cookie])
                precondition(manifest.status == 200 && manifest.body == snapshot.manifestData)
                let manifestHead = request("manifest", method: "HEAD", headers: ["Cookie": cookie])
                precondition(manifestHead.status == 200 && manifestHead.body.isEmpty)
                precondition(Int(manifestHead.header("Content-Length") ?? "") == snapshot.manifestData.count)
                let mediaHead = request("media/\(mediaID)", method: "HEAD", headers: ["Cookie": cookie])
                precondition(mediaHead.status == 200 && mediaHead.body.isEmpty)
                precondition(Int(mediaHead.header("Content-Length") ?? "") == bytes.count)
                let range = request("media/\(mediaID)", headers: ["Cookie": cookie, "Range": "bytes=0-63"])
                precondition(range.status == 206 && range.body == bytes.prefix(64))
                precondition(range.header("Content-Range") == "bytes 0-63/\(bytes.count)")
                // Pause the reader beyond the old total-connection deadline.
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                precondition(fd >= 0)
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = UInt16(url.port!).bigEndian
                _ = url.host!.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                precondition(connected == 0)
                var timeout = timeval(tv_sec: 20, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                let get = "GET /media/\(mediaID) HTTP/1.1\r\nHost: \(url.host!):\(url.port!)\r\nCookie: \(cookie)\r\n\r\n"
                _ = get.withCString { send(fd, $0, strlen($0), 0) }
                Thread.sleep(forTimeInterval: 12)
                var received = Data(), buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = recv(fd, &buffer, buffer.count, 0)
                    precondition(count >= 0)
                    if count == 0 { break }
                    received.append(contentsOf: buffer.prefix(count))
                }
                close(fd)
                let divider = received.range(of: Data("\r\n\r\n".utf8))!
                precondition(received.suffix(from: divider.upperBound) == bytes)
                _ = waitForPhase(.stopped, on: server) { server.stop() }
                precondition(server.currentState().primaryURL == nil && authority.activeChallenge() == nil)
                let restarted = waitForPhase(.ready, on: server) { server.startWithNewCode() }
                guard let restartedURL = restarted.primaryURL else { fatalError("Restart did not publish a LAN address") }
                baseURL = restartedURL
                precondition(restarted.pairingCode != nil && restarted.pairedDeviceCount == 1)
                precondition(request("manifest", headers: ["Cookie": cookie]).status == 200, "Remembered devices must survive listener restart")
                server.forgetAllDevices()
                // This request is accepted on the same serial queue after the
                // forget operation, so it also synchronizes revocation.
                let revoked = request("manifest", headers: ["Cookie": cookie])
                precondition(revoked.status == 401 && revoked.header("Set-Cookie")?.contains("Max-Age=0") == true)
                precondition(authority.pairedDeviceCount() == 0)
                precondition(request("media/\(mediaID)", headers: ["Cookie": cookie]).status == 401)
                _ = waitForPhase(.stopped, on: server) { server.stop() }
                print("PASS: stable port fallback, local-vs-remote status, LAN HTTP, HEAD lengths, host/origin protection, browser pairing, authentication, ranges, slow transfer, listener restart, revocation")
                try? FileManager.default.removeItem(at: file)
                exit(0)
            }
        }
        server.startWithNewCode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fatalError("Share test timed out") }
        dispatchMain()
    }
}
