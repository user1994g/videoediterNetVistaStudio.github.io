// Run with ShareServer.swift, not the app's main entry point.
import Cocoa
import Darwin

@main struct ShareServerChecks {
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
                func request(_ path: String, headers: [String: String] = [:]) -> Int {
                    let done = DispatchSemaphore(value: 0)
                    var status = 0
                    var request = URLRequest(url: url.appendingPathComponent(path))
                    request.timeoutInterval = 5
                    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                    URLSession.shared.dataTask(with: request) { _, response, _ in
                        status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        done.signal()
                    }.resume()
                    precondition(done.wait(timeout: .now() + 8) == .success)
                    return status
                }
                precondition(request("") == 200)
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
                second.stop()
                precondition(request("manifest") == 401)
                precondition(request("", headers: ["Host": "untrusted.example"]) == 400)
                guard case .paired(let token) = authority.pair(code: state.pairingCode!, clientID: "test") else { fatalError("Pairing failed") }
                let cookie = "nv_device=\(token)"
                precondition(request("manifest", headers: ["Cookie": cookie]) == 200)
                precondition(request("media/\(mediaID)", headers: ["Cookie": cookie, "Range": "bytes=0-63"]) == 206)
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
                authority.forgetAllDevices()
                precondition(request("manifest", headers: ["Cookie": cookie]) == 401)
                server.stop()
                print("PASS: stable port fallback, local-vs-remote status, LAN HTTP, host protection, pairing, authentication, ranges, slow transfer, revocation")
                try? FileManager.default.removeItem(at: file)
                exit(0)
            }
        }
        server.startWithNewCode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { fatalError("Share test timed out") }
        dispatchMain()
    }
}
