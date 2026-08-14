import Cocoa
import Network
import CryptoKit
import Security
import UniformTypeIdentifiers
import Darwin

// MARK: - Immutable project data exposed to the LAN service

struct ShareMediaResource {
    let id: UUID
    let name: String
    let kind: String
    let duration: Double
    let fileURL: URL
}

struct ShareProjectSnapshot {
    let title: String
    let mediaCount: Int
    let clipCount: Int
    let sceneCount: Int
    let timelineDuration: Double
    let manifestData: Data
    let manifestFilename: String
    let media: [ShareMediaResource]
}

enum LocalShareServerPhase: Equatable {
    case stopped
    case starting
    case ready
    case failed
}

struct LocalShareServerState: Equatable {
    var phase: LocalShareServerPhase = .stopped
    var primaryURL: URL?
    var alternateURL: URL?
    var pairingCode: String?
    var pairingExpiresAt: Date?
    var pairedDeviceCount = 0
    var errorMessage: String?

    var isRunning: Bool { phase == .starting || phase == .ready }
}

// MARK: - Persistent paired-device verifiers

protocol SharePairedDeviceStore: AnyObject {
    func loadTokenHashes() -> [String]
    func saveTokenHashes(_ hashes: [String])
}

/// Only SHA-256 verifiers are stored. The raw 256-bit browser token remains in
/// Safari's HttpOnly cookie and never enters a project file or application log.
final class ShareKeychainDeviceStore: SharePairedDeviceStore {
    private let service = "local.netvista.studio.share"
    private let account = "paired-device-token-hashes-v1"

    func loadTokenHashes() -> [String] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }

    func saveTokenHashes(_ hashes: [String]) {
        let unique = Array(Set(hashes)).sorted().suffix(64)
        guard let data = try? JSONEncoder().encode(Array(unique)) else { return }
        let query = baseQuery()
        let changes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addition as CFDictionary, nil)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class ShareMemoryDeviceStore: SharePairedDeviceStore {
    private var hashes: [String]
    init(hashes: [String] = []) { self.hashes = hashes }
    func loadTokenHashes() -> [String] { hashes }
    func saveTokenHashes(_ hashes: [String]) { self.hashes = hashes }
}

enum SharePairingOutcome: Equatable {
    case paired(token: String)
    case invalid
    case expired
    case rateLimited
}

/// Thread-safe pairing authority. Challenge expiry uses monotonic uptime, so a
/// clock change cannot extend a code. Persistent device tokens outlive codes
/// and server restarts until the user explicitly forgets them.
final class SharePairingAuthority {
    struct Challenge: Equatable {
        let code: String
        let expiresAt: Date
    }

    private let lock = NSLock()
    private let store: SharePairedDeviceStore
    private let codeLifetime: TimeInterval
    private let uptime: () -> TimeInterval
    private let wallClock: () -> Date
    private let codeGenerator: () -> String
    private let tokenGenerator: () -> String
    private var activeCode: String?
    private var expiryUptime: TimeInterval = 0
    private var expiryDate: Date?
    private var failedAttemptsByClient: [String: Int] = [:]
    private var failedAttemptsTotal = 0
    private let maximumAttemptsPerClient = 5
    private let maximumAttemptsPerCode = 30

    init(
        store: SharePairedDeviceStore = ShareKeychainDeviceStore(),
        codeLifetime: TimeInterval = 120,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wallClock: @escaping () -> Date = Date.init,
        codeGenerator: @escaping () -> String = SharePairingAuthority.secureSixDigitCode,
        tokenGenerator: @escaping () -> String = SharePairingAuthority.secureDeviceToken
    ) {
        self.store = store
        self.codeLifetime = max(1, codeLifetime)
        self.uptime = uptime
        self.wallClock = wallClock
        self.codeGenerator = codeGenerator
        self.tokenGenerator = tokenGenerator
    }

    func issueCode() -> Challenge {
        lock.lock(); defer { lock.unlock() }
        let code = codeGenerator()
        activeCode = code
        expiryUptime = uptime() + codeLifetime
        let date = wallClock().addingTimeInterval(codeLifetime)
        expiryDate = date
        failedAttemptsByClient.removeAll(keepingCapacity: true)
        failedAttemptsTotal = 0
        return Challenge(code: code, expiresAt: date)
    }

    func activeChallenge() -> Challenge? {
        lock.lock(); defer { lock.unlock() }
        guard let activeCode, let expiryDate, uptime() < expiryUptime else { return nil }
        return Challenge(code: activeCode, expiresAt: expiryDate)
    }

    func pair(code candidate: String, clientID: String) -> SharePairingOutcome {
        lock.lock(); defer { lock.unlock() }
        guard let activeCode else { return .expired }
        guard uptime() < expiryUptime else {
            self.activeCode = nil; expiryDate = nil
            return .expired
        }
        let failures = failedAttemptsByClient[clientID, default: 0]
        guard failures < maximumAttemptsPerClient, failedAttemptsTotal < maximumAttemptsPerCode else { return .rateLimited }
        guard Self.constantTimeEqual(candidate, activeCode) else {
            failedAttemptsByClient[clientID] = failures + 1
            failedAttemptsTotal += 1
            return failures + 1 >= maximumAttemptsPerClient || failedAttemptsTotal >= maximumAttemptsPerCode ? .rateLimited : .invalid
        }

        let token = tokenGenerator()
        var hashes = store.loadTokenHashes()
        hashes.append(Self.tokenHash(token))
        store.saveTokenHashes(hashes)
        self.activeCode = nil
        expiryDate = nil
        failedAttemptsByClient.removeAll(keepingCapacity: false)
        failedAttemptsTotal = 0
        return .paired(token: token)
    }

    func recognizes(token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return store.loadTokenHashes().contains(Self.tokenHash(token))
    }

    func pairedDeviceCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return Set(store.loadTokenHashes()).count
    }

    func forgetAllDevices() {
        lock.lock(); defer { lock.unlock() }
        store.saveTokenHashes([])
    }

    func clearChallenge() {
        lock.lock(); defer { lock.unlock() }
        activeCode = nil; expiryDate = nil; failedAttemptsByClient.removeAll(); failedAttemptsTotal = 0
    }

    static func tokenHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var difference = UInt64(left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= UInt64(a ^ b)
        }
        return difference == 0
    }

    private static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        }
        return bytes
    }

    private static func secureSixDigitCode() -> String {
        // Rejection sampling avoids modulo bias while retaining leading zeroes.
        let acceptedMaximum = UInt32.max - (UInt32.max % 1_000_000)
        var value: UInt32 = 0
        repeat {
            let bytes = randomBytes(count: 4)
            value = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
        } while value >= acceptedMaximum
        return String(format: "%06u", value % 1_000_000)
    }

    private static func secureDeviceToken() -> String {
        Data(randomBytes(count: 32)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Bounded HTTP parsing

struct ShareHTTPRequest {
    let method: String
    let target: String
    let path: String
    let headers: [String: String]
    let body: Data

    var cookies: [String: String] {
        guard let value = headers["cookie"] else { return [:] }
        var result: [String: String] = [:]
        for item in value.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1] }
        }
        return result
    }
}

enum ShareHTTPParseResult {
    case incomplete
    case request(ShareHTTPRequest)
    case error(Int, String)
}

enum ShareHTTPParser {
    static let maximumHeaderBytes = 16 * 1024
    static let maximumBodyBytes = 64 * 1024
    private static let separator = Data("\r\n\r\n".utf8)

    static func parse(_ data: Data) -> ShareHTTPParseResult {
        guard let separatorRange = data.range(of: separator) else {
            return data.count > maximumHeaderBytes ? .error(431, "Request headers are too large.") : .incomplete
        }
        guard separatorRange.lowerBound <= maximumHeaderBytes else { return .error(431, "Request headers are too large.") }
        let headerData = data.subdata(in: 0..<separatorRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return .error(400, "Request headers are not valid UTF-8.") }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .error(400, "The request line is missing.") }
        let requestParts = first.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard requestParts.count == 3, requestParts[2] == "HTTP/1.1", requestParts[1].hasPrefix("/") else {
            return .error(400, "Only origin-form HTTP/1.1 requests are supported.")
        }

        var headerLists: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { return .error(400, "A request header is malformed.") }
            let name = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .error(400, "A request header name is empty.") }
            headerLists[name, default: []].append(value)
        }
        guard headerLists["host"]?.count == 1 else { return .error(400, "A single Host header is required.") }
        if headerLists["transfer-encoding"] != nil { return .error(400, "Transfer-Encoding is not supported.") }
        if let lengths = headerLists["content-length"], lengths.count != 1 { return .error(400, "A duplicate Content-Length was rejected.") }

        let contentLength: Int
        if let raw = headerLists["content-length"]?.first {
            guard let parsed = Int(raw), parsed >= 0 else { return .error(400, "Content-Length is invalid.") }
            contentLength = parsed
        } else { contentLength = 0 }
        guard contentLength <= maximumBodyBytes else { return .error(413, "The request body is too large.") }
        let bodyStart = separatorRange.upperBound
        let expectedSize = bodyStart + contentLength
        guard data.count >= expectedSize else { return .incomplete }
        let headers = headerLists.mapValues { $0.joined(separator: ", ") }
        let target = requestParts[1]
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
        let lowerPath = path.lowercased()
        guard !lowerPath.contains(".."), !lowerPath.contains("%2e") else { return .error(400, "Path traversal was rejected.") }
        return .request(ShareHTTPRequest(
            method: requestParts[0].uppercased(),
            target: target,
            path: path,
            headers: headers,
            body: data.subdata(in: bodyStart..<expectedSize)
        ))
    }
}

struct ShareHTTPResponse {
    let status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func html(_ status: Int = 200, _ html: String, headers: [String: String] = [:]) -> ShareHTTPResponse {
        var response = ShareHTTPResponse(status: status, headers: headers, body: Data(html.utf8))
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        return response
    }

    static func text(_ status: Int, _ text: String) -> ShareHTTPResponse {
        ShareHTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }
}

// MARK: - LAN listener and authenticated routes

final class LocalShareServer {
    typealias SnapshotProvider = () -> ShareProjectSnapshot?

    private struct LANIPv4Interface: Equatable {
        let name: String
        let address: String
        let addressValue: UInt32
        let networkValue: UInt32
        let netmaskValue: UInt32

        func contains(_ candidate: UInt32) -> Bool {
            (candidate & netmaskValue) == networkValue
        }
    }

    var onStateChange: ((LocalShareServerState) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return stateCallback }
        set { stateLock.lock(); stateCallback = newValue; let value = cachedState; stateLock.unlock(); if let newValue { DispatchQueue.main.async { newValue(value) } } }
    }

    private let queue = DispatchQueue(label: "NetVistaStudio.LocalShareServer", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stateCallback: ((LocalShareServerState) -> Void)?
    private var cachedState = LocalShareServerState()
    private let authority: SharePairingAuthority
    private let snapshotProvider: SnapshotProvider
    private let advertisesBonjour: Bool
    private var listener: NWListener?
    private var pathMonitor: NWPathMonitor?
    private var connections: [UUID: NWConnection] = [:]
    private var activeMediaStreams = 0
    private var port: NWEndpoint.Port?
    private var activeLANInterface: LANIPv4Interface?
    private var allowedHostHeaders = Set<String>()
    private let maximumConnections = 16
    private let maximumMediaStreams = 4

    init(
        authority: SharePairingAuthority = SharePairingAuthority(),
        advertisesBonjour: Bool = true,
        snapshotProvider: @escaping SnapshotProvider
    ) {
        self.authority = authority
        self.advertisesBonjour = advertisesBonjour
        self.snapshotProvider = snapshotProvider
        cachedState.pairedDeviceCount = authority.pairedDeviceCount()
    }

    deinit { listener?.cancel(); pathMonitor?.cancel(); connections.values.forEach { $0.cancel() } }

    func currentState() -> LocalShareServerState {
        stateLock.lock(); defer { stateLock.unlock() }
        var result = cachedState
        if authority.activeChallenge() == nil { result.pairingCode = nil; result.pairingExpiresAt = nil }
        result.pairedDeviceCount = authority.pairedDeviceCount()
        return result
    }

    /// Pressing Share always rotates the temporary challenge while retaining
    /// trusted devices, matching the user's “press it again if too slow” flow.
    func startWithNewCode() {
        queue.async { [weak self] in
            guard let self else { return }
            let challenge = authority.issueCode()
            if listener == nil { createListener(challenge: challenge) }
            else { refreshLANState(challenge: challenge) }
        }
    }

    func issueNewCode() {
        queue.async { [weak self] in
            guard let self else { return }
            let challenge = authority.issueCode()
            listener == nil ? createListener(challenge: challenge) : refreshLANState(challenge: challenge)
        }
    }

    func forgetAllDevices() {
        queue.async { [weak self] in
            guard let self else { return }
            authority.forgetAllDevices()
            refreshLANState(challenge: authority.activeChallenge())
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            listener?.cancel(); listener = nil; port = nil
            pathMonitor?.cancel(); pathMonitor = nil
            activeLANInterface = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll(); activeMediaStreams = 0
            authority.clearChallenge(); allowedHostHeaders.removeAll()
            publish(LocalShareServerState(phase: .stopped, pairedDeviceCount: authority.pairedDeviceCount()))
        }
    }

    private func createListener(challenge: SharePairingAuthority.Challenge) {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: .any)
            if advertisesBonjour {
                listener.service = NWListener.Service(name: "NetVista Studio", type: "_netvista-share._tcp")
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                guard self.listener === listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port
                    if self.configureAddresses() {
                        self.publishRunning(challenge: self.authority.activeChallenge())
                    } else {
                        self.publishWaitingForLAN()
                    }
                case .waiting(let error):
                    self.publishFailure("Sharing is waiting for local-network access: \(error.localizedDescription)", stillRunning: true)
                case .failed(let error):
                    self.listener = nil; self.port = nil
                    self.pathMonitor?.cancel(); self.pathMonitor = nil
                    self.activeLANInterface = nil
                    self.publishFailure("Could not start local sharing: \(error.localizedDescription)", stillRunning: false)
                case .cancelled:
                    break
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            self.listener = listener
            publish(LocalShareServerState(
                phase: .starting,
                pairingCode: challenge.code,
                pairingExpiresAt: challenge.expiresAt,
                pairedDeviceCount: authority.pairedDeviceCount()
            ))
            startPathMonitor()
            listener.start(queue: queue)
        } catch {
            publishFailure("Could not create the local server: \(error.localizedDescription)", stillRunning: false)
        }
    }

    @discardableResult
    private func configureAddresses() -> Bool {
        guard let port else { return false }
        let portText = String(port.rawValue)
        guard let interface = Self.preferredLANIPv4Interface() else {
            activeLANInterface = nil
            allowedHostHeaders.removeAll()
            updateCachedAddresses(primary: nil, alternate: nil)
            return false
        }

        let networkChanged = activeLANInterface.map {
            $0.addressValue != interface.addressValue || $0.networkValue != interface.networkValue || $0.netmaskValue != interface.netmaskValue
        } ?? false
        activeLANInterface = interface
        if networkChanged {
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
            activeMediaStreams = 0
        }
        let primary = URL(string: "http://\(interface.address):\(portText)/")
        allowedHostHeaders = [
            interface.address.lowercased(),
            "\(interface.address.lowercased()):\(portText)",
            "localhost:\(portText)",
            "127.0.0.1:\(portText)"
        ]
        updateCachedAddresses(primary: primary, alternate: nil)
        return primary != nil
    }

    private func refreshLANState(challenge: SharePairingAuthority.Challenge?) {
        if configureAddresses() { publishRunning(challenge: challenge) }
        else { publishWaitingForLAN() }
    }

    private func startPathMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self, weak monitor] _ in
            guard let self, let monitor, self.pathMonitor === monitor else { return }
            guard self.listener != nil, self.port != nil else { return }
            self.refreshLANState(challenge: self.authority.activeChallenge())
        }
        pathMonitor = monitor
        monitor.start(queue: queue)
    }

    private func publishWaitingForLAN() {
        let challenge = authority.activeChallenge()
        publish(LocalShareServerState(
            phase: .starting,
            pairingCode: challenge?.code,
            pairingExpiresAt: challenge?.expiresAt,
            pairedDeviceCount: authority.pairedDeviceCount(),
            errorMessage: "Connect this Mac to the same private Wi-Fi or LAN as the other device, then try again. Local sharing never uses localhost or the internet."
        ))
    }

    private func publishRunning(challenge: SharePairingAuthority.Challenge?) {
        let addresses = currentAddresses()
        publish(LocalShareServerState(
            phase: listener == nil ? .stopped : (port == nil ? .starting : .ready),
            primaryURL: addresses.0,
            alternateURL: addresses.1,
            pairingCode: challenge?.code,
            pairingExpiresAt: challenge?.expiresAt,
            pairedDeviceCount: authority.pairedDeviceCount()
        ))
    }

    private func publishFailure(_ message: String, stillRunning: Bool) {
        let addresses = currentAddresses()
        let challenge = authority.activeChallenge()
        publish(LocalShareServerState(
            phase: stillRunning ? .starting : .failed,
            primaryURL: addresses.0,
            alternateURL: addresses.1,
            pairingCode: challenge?.code,
            pairingExpiresAt: challenge?.expiresAt,
            pairedDeviceCount: authority.pairedDeviceCount(),
            errorMessage: message
        ))
    }

    private func updateCachedAddresses(primary: URL?, alternate: URL?) {
        stateLock.lock(); cachedState.primaryURL = primary; cachedState.alternateURL = alternate; stateLock.unlock()
    }

    private func currentAddresses() -> (URL?, URL?) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (cachedState.primaryURL, cachedState.alternateURL)
    }

    private func publish(_ state: LocalShareServerState) {
        stateLock.lock(); cachedState = state; let callback = stateCallback; stateLock.unlock()
        if let callback { DispatchQueue.main.async { callback(state) } }
    }

    private func accept(_ connection: NWConnection) {
        guard connectionIsOnActiveLAN(connection) else {
            connection.start(queue: queue)
            send(ShareHTTPResponse.text(403, "This device is not on the same local Wi-Fi or LAN as NetVista Studio."), over: connection, connectionID: nil)
            return
        }
        guard connections.count < maximumConnections else {
            connection.start(queue: queue)
            send(ShareHTTPResponse.text(503, "The local server is busy."), over: connection, connectionID: nil)
            return
        }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { receive(on: connection, id: id, buffer: Data()) }
            if case .failed = state { finishConnection(id) }
            if case .cancelled = state { finishConnection(id) }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            guard let self, let connection, self.connections[id] != nil else { return }
            connection.cancel(); self.finishConnection(id)
        }
    }

    private func receive(on connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] content, _, complete, error in
            guard let self else { return }
            var next = buffer
            if let content { next.append(content) }
            switch ShareHTTPParser.parse(next) {
            case .incomplete:
                if complete || error != nil { send(.text(400, "The HTTP request ended early."), over: connection, connectionID: id) }
                else { receive(on: connection, id: id, buffer: next) }
            case .error(let status, let message):
                send(.text(status, message), over: connection, connectionID: id)
            case .request(let request):
                route(request, from: connection, id: id)
            }
        }
    }

    private func route(_ request: ShareHTTPRequest, from connection: NWConnection, id: UUID) {
        guard ["GET", "HEAD", "POST"].contains(request.method) else {
            send(.text(405, "Method not allowed."), over: connection, connectionID: id, extraHeaders: ["Allow": "GET, HEAD, POST"]); return
        }
        guard let host = request.headers["host"]?.lowercased(), allowedHostHeaders.contains(host) else {
            send(.text(400, "Use the exact NetVista Studio sharing address shown on the Mac."), over: connection, connectionID: id); return
        }
        let token = request.cookies["nv_device"]
        let authenticated = token.map(authority.recognizes) ?? false

        switch (request.method, request.path) {
        case ("GET", "/"), ("HEAD", "/"):
            let response: ShareHTTPResponse
            if authenticated, let snapshot = snapshotProvider() { response = .html(200, dashboardHTML(snapshot: snapshot)) }
            else {
                var headers: [String: String] = [:]
                if token != nil { headers["Set-Cookie"] = expiredCookie }
                response = .html(200, pairingHTML(message: nil), headers: headers)
            }
            let declaredLength = request.method == "HEAD" ? response.body.count : nil
            send(request.method == "HEAD" ? withoutBody(response) : response, over: connection, connectionID: id, declaredLength: declaredLength)

        case ("POST", "/pair"):
            if let origin = request.headers["origin"], !originMatchesHost(origin, host: host) {
                send(.text(403, "The pairing request came from a different origin."), over: connection, connectionID: id); return
            }
            let form = Self.formValues(request.body)
            let candidate = form["code"]?.filter(\.isNumber) ?? ""
            guard candidate.count == 6 else {
                send(.html(401, pairingHTML(message: "Enter the six-digit code shown on your Mac.")), over: connection, connectionID: id); return
            }
            switch authority.pair(code: candidate, clientID: Self.clientID(for: connection)) {
            case .paired(let token):
                publishRunning(challenge: nil)
                send(ShareHTTPResponse(status: 303, headers: [
                    "Location": "/",
                    "Set-Cookie": "nv_device=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000"
                ]), over: connection, connectionID: id)
            case .invalid:
                send(.html(401, pairingHTML(message: "That code is incorrect or has expired. Check the Mac and try again.")), over: connection, connectionID: id)
            case .expired:
                publishRunning(challenge: nil)
                send(.html(410, pairingHTML(message: "That code expired. Press Share on the Mac again for a new code.")), over: connection, connectionID: id)
            case .rateLimited:
                send(.html(429, pairingHTML(message: "Too many attempts. Press Share on the Mac to create a new code."), headers: ["Retry-After": "60"]), over: connection, connectionID: id)
            }

        case ("GET", "/manifest"), ("HEAD", "/manifest"):
            guard authenticated, let snapshot = snapshotProvider() else { sendUnauthorized(over: connection, id: id, headOnly: request.method == "HEAD"); return }
            var response = ShareHTTPResponse(status: 200, headers: [
                "Content-Type": "application/json",
                "Content-Disposition": "attachment; filename=\"\(Self.safeFilename(snapshot.manifestFilename))\""
            ], body: snapshot.manifestData)
            if request.method == "HEAD" { response.body = Data() }
            send(response, over: connection, connectionID: id, declaredLength: request.method == "HEAD" ? snapshot.manifestData.count : nil)

        case ("GET", let path) where path.hasPrefix("/media/"):
            guard authenticated, let snapshot = snapshotProvider() else { sendUnauthorized(over: connection, id: id); return }
            let rawID = String(path.dropFirst("/media/".count))
            guard let mediaID = UUID(uuidString: rawID), let item = snapshot.media.first(where: { $0.id == mediaID }) else {
                send(.text(404, "That shared media item was not found."), over: connection, connectionID: id); return
            }
            sendMedia(item, request: request, over: connection, id: id)

        case ("HEAD", let path) where path.hasPrefix("/media/"):
            guard authenticated, let snapshot = snapshotProvider() else { sendUnauthorized(over: connection, id: id, headOnly: true); return }
            let rawID = String(path.dropFirst("/media/".count))
            guard let mediaID = UUID(uuidString: rawID), let item = snapshot.media.first(where: { $0.id == mediaID }) else {
                send(.text(404, "That shared media item was not found."), over: connection, connectionID: id); return
            }
            sendMedia(item, request: request, over: connection, id: id)

        case ("GET", "/favicon.ico"), ("HEAD", "/favicon.ico"):
            send(ShareHTTPResponse(status: 204), over: connection, connectionID: id)

        default:
            let response = ShareHTTPResponse.text(404, "Not found.")
            send(request.method == "HEAD" ? withoutBody(response) : response, over: connection, connectionID: id, declaredLength: request.method == "HEAD" ? response.body.count : nil)
        }
    }

    private var expiredCookie: String { "nv_device=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" }

    private func sendUnauthorized(over connection: NWConnection, id: UUID, headOnly: Bool = false) {
        let response = ShareHTTPResponse.html(401, pairingHTML(message: "Pair this device before opening shared project data."), headers: ["Set-Cookie": expiredCookie])
        send(headOnly ? withoutBody(response) : response, over: connection, connectionID: id, declaredLength: headOnly ? response.body.count : nil)
    }

    private func send(_ response: ShareHTTPResponse, over connection: NWConnection, connectionID: UUID?, extraHeaders: [String: String] = [:], declaredLength: Int? = nil) {
        var headers = securityHeaders
        response.headers.forEach { headers[$0.key] = $0.value }
        extraHeaders.forEach { headers[$0.key] = $0.value }
        headers["Content-Length"] = String(declaredLength ?? response.body.count)
        headers["Connection"] = "close"
        let reason = Self.reasonPhrase(response.status)
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        for key in headers.keys.sorted() { head += "\(key): \(headers[key]!)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8); payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            if let connectionID { self?.queue.async { self?.finishConnection(connectionID) } }
        })
    }

    private func sendMedia(_ item: ShareMediaResource, request: ShareHTTPRequest, over connection: NWConnection, id: UUID) {
        guard activeMediaStreams < maximumMediaStreams else { send(.text(503, "Too many media streams are open."), over: connection, connectionID: id); return }
        guard item.fileURL.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: item.fileURL.path),
              let sizeNumber = attributes[.size] as? NSNumber else {
            send(.text(404, "The original media file is no longer available on the Mac."), over: connection, connectionID: id); return
        }
        let size = sizeNumber.uint64Value
        guard size > 0 else { send(.text(404, "The shared media file is empty."), over: connection, connectionID: id); return }

        let rangeResult = Self.parseRange(request.headers["range"], fileSize: size)
        guard case .valid(let start, let end, let partial) = rangeResult else {
            send(ShareHTTPResponse(status: 416, headers: ["Content-Range": "bytes */\(size)"]), over: connection, connectionID: id); return
        }
        let length = end - start + 1
        let mime = UTType(filenameExtension: item.fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var headers = securityHeaders
        headers["Content-Type"] = mime
        headers["Accept-Ranges"] = "bytes"
        headers["Content-Length"] = String(length)
        headers["Content-Disposition"] = "inline; filename=\"\(Self.safeFilename(item.name))\""
        headers["Connection"] = "close"
        if partial { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
        let status = partial ? 206 : 200
        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
        for key in headers.keys.sorted() { head += "\(key): \(headers[key]!)\r\n" }
        head += "\r\n"
        if request.method == "HEAD" {
            connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in connection.cancel(); self?.queue.async { self?.finishConnection(id) } })
            return
        }
        guard let file = try? FileHandle(forReadingFrom: item.fileURL) else { send(.text(404, "The media file could not be opened."), over: connection, connectionID: id); return }
        do { try file.seek(toOffset: start) } catch { try? file.close(); send(.text(500, "The media stream could not seek."), over: connection, connectionID: id); return }
        activeMediaStreams += 1
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { try? file.close(); return }
            queue.async {
                if error != nil { self.finishMedia(file: file, connection: connection, id: id) }
                else { self.pumpMedia(file: file, remaining: length, connection: connection, id: id) }
            }
        })
    }

    private func pumpMedia(file: FileHandle, remaining: UInt64, connection: NWConnection, id: UUID) {
        guard remaining > 0 else { finishMedia(file: file, connection: connection, id: id); return }
        let count = Int(min(remaining, 128 * 1024))
        guard let chunk = try? file.read(upToCount: count), !chunk.isEmpty else { finishMedia(file: file, connection: connection, id: id); return }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { try? file.close(); return }
            queue.async {
                if error != nil { self.finishMedia(file: file, connection: connection, id: id) }
                else { self.pumpMedia(file: file, remaining: remaining - UInt64(chunk.count), connection: connection, id: id) }
            }
        })
    }

    private func finishMedia(file: FileHandle, connection: NWConnection, id: UUID) {
        try? file.close(); connection.cancel(); activeMediaStreams = max(0, activeMediaStreams - 1); finishConnection(id)
    }

    private func finishConnection(_ id: UUID) { connections.removeValue(forKey: id) }

    private var securityHeaders: [String: String] {
        [
            "Cache-Control": "no-store",
            "Content-Security-Policy": "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; media-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
            "Cross-Origin-Resource-Policy": "same-origin",
            "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "DENY"
        ]
    }

    private func pairingHTML(message: String?) -> String {
        let challenge = authority.activeChallenge()
        let remaining = challenge.map { max(0, Int($0.expiresAt.timeIntervalSinceNow.rounded(.down))) } ?? 0
        let notice = message.map { "<div class=\"notice\">\(Self.escapeHTML($0))</div>" } ?? ""
        let availability = challenge == nil
            ? "<p class=\"muted\">No active code. Press <b>Share</b> on the Mac again.</p>"
            : "<p class=\"muted\">The code expires in <strong id=\"countdown\">\(remaining)s</strong>.</p>"
        let disabled = challenge == nil ? " disabled" : ""
        return pageShell(title: "Pair with NetVista Studio", body: """
            <main class="pair-card">
              <div class="mark">NV</div>
              <p class="eyebrow">NETVISTA STUDIO · LOCAL SHARE</p>
              <h1>Pair this device</h1>
              <p>Enter the six-digit code shown in NetVista Studio on the Mac.</p>
              \(notice)
              <form method="post" action="/pair">
                <input name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" placeholder="000000" aria-label="Six-digit pairing code" required\(disabled)>
                <button type="submit"\(disabled)>Pair device</button>
              </form>
              \(availability)
              <p class="trust">Use this only on a trusted private Wi-Fi network.</p>
            </main>
            <script>
              let n=\(remaining), e=document.getElementById('countdown');
              if(e){setInterval(()=>{n=Math.max(0,n-1);e.textContent=n?n+'s':'expired';},1000);}
            </script>
        """)
    }

    private func dashboardHTML(snapshot: ShareProjectSnapshot) -> String {
        let duration = Self.formatDuration(snapshot.timelineDuration)
        let cards = snapshot.media.prefix(24).map { item -> String in
            let name = Self.escapeHTML(item.name)
            let source = "/media/\(item.id.uuidString)"
            let player = item.kind == "audio"
                ? "<audio controls preload=\"metadata\" src=\"\(source)\"></audio>"
                : "<video controls playsinline preload=\"metadata\" src=\"\(source)\"></video>"
            return "<article class=\"media-card\">\(player)<div><b>\(name)</b><span>\(Self.formatDuration(item.duration))</span></div></article>"
        }.joined()
        let mediaSection = cards.isEmpty ? "<p class=\"empty\">No playable media is in this project yet.</p>" : "<section class=\"media-grid\">\(cards)</section>"
        return pageShell(title: snapshot.title, body: """
            <header class="top"><div><p class="eyebrow">NETVISTA STUDIO · PAIRED</p><h1>\(Self.escapeHTML(snapshot.title))</h1></div><span class="online">● Connected</span></header>
            <section class="stats">
              <div><strong>\(snapshot.clipCount)</strong><span>Timeline clips</span></div>
              <div><strong>\(snapshot.mediaCount)</strong><span>Media items</span></div>
              <div><strong>\(snapshot.sceneCount)</strong><span>3D scenes</span></div>
              <div><strong>\(duration)</strong><span>Timeline length</span></div>
            </section>
            <section class="actions"><a class="button" href="/manifest">Download share summary</a><a class="secondary" href="/">Refresh</a></section>
            <h2>Shared media</h2>
            \(mediaSection)
            <footer>The Mac must remain awake with Share running. Use trusted private Wi-Fi.</footer>
        """)
    }

    private func pageShell(title: String, body: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>\(Self.escapeHTML(title)) · NetVista Studio</title>
        <style>
        :root{color-scheme:dark;--bg:#0d1015;--card:#181d25;--card2:#202733;--line:#303a49;--text:#f5f7fb;--muted:#9aa7b8;--blue:#4c8dff;--teal:#43d7c2;--red:#f05b5e}*{box-sizing:border-box}body{margin:0;min-height:100vh;background:radial-gradient(circle at 20% 0,#17223a 0,transparent 42%),var(--bg);color:var(--text);font:16px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;padding:max(24px,env(safe-area-inset-top)) max(18px,env(safe-area-inset-right)) max(32px,env(safe-area-inset-bottom)) max(18px,env(safe-area-inset-left))}main,.top,.stats,.actions,h2,.media-grid,footer{max-width:1050px;margin-left:auto;margin-right:auto}.pair-card{max-width:520px;margin:8vh auto 0;background:rgba(24,29,37,.94);border:1px solid var(--line);border-radius:24px;padding:34px;box-shadow:0 28px 80px #0008;text-align:center}.mark{display:grid;place-items:center;width:58px;height:58px;margin:0 auto 18px;border-radius:16px;background:linear-gradient(145deg,var(--blue),var(--teal));font-weight:900}.eyebrow{color:var(--teal);font-size:12px;font-weight:800;letter-spacing:.12em}h1{font-size:clamp(30px,6vw,48px);line-height:1.05;margin:8px 0 12px}h2{margin-top:34px}.muted,.trust,footer{color:var(--muted);font-size:14px}.trust{margin-top:28px}.notice{background:#3d2528;border:1px solid #754047;color:#ffd9dc;padding:12px;border-radius:12px;margin:18px 0}form{display:flex;gap:10px;margin-top:22px}input{min-width:0;flex:1;background:#0c0f14;border:1px solid var(--line);border-radius:12px;color:white;font:700 28px ui-monospace,SFMono-Regular,monospace;letter-spacing:.18em;text-align:center;padding:13px}button,.button,.secondary{border:0;border-radius:12px;padding:14px 18px;font-weight:750;text-decoration:none;cursor:pointer}button,.button{background:var(--blue);color:white}button:disabled,input:disabled{opacity:.45}.top{display:flex;align-items:center;justify-content:space-between;gap:20px;padding:18px 0}.online{color:var(--teal);white-space:nowrap}.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}.stats div{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px}.stats strong{display:block;font-size:25px}.stats span,.media-card span{display:block;color:var(--muted);font-size:13px;margin-top:4px}.actions{display:flex;gap:10px;margin-top:18px}.secondary{background:var(--card2);color:var(--text)}.media-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:14px}.media-card{overflow:hidden;background:var(--card);border:1px solid var(--line);border-radius:16px}.media-card video{display:block;width:100%;aspect-ratio:16/9;background:#000}.media-card audio{display:block;width:calc(100% - 24px);margin:18px 12px}.media-card div{padding:12px}.empty{max-width:1050px;margin:0 auto;color:var(--muted);background:var(--card);padding:22px;border-radius:16px}footer{margin-top:34px;border-top:1px solid var(--line);padding-top:18px}@media(max-width:700px){.stats{grid-template-columns:1fr 1fr}.top{align-items:flex-start;flex-direction:column}.pair-card{padding:24px}form{flex-direction:column}}
        </style></head><body>\(body)</body></html>
        """
    }

    private func originMatchesHost(_ origin: String, host: String) -> Bool {
        guard let url = URL(string: origin), url.scheme == "http", let originHost = url.host else { return false }
        let authority = url.port.map { "\(originHost.lowercased()):\($0)" } ?? originHost.lowercased()
        return authority == host
    }

    private func withoutBody(_ response: ShareHTTPResponse) -> ShareHTTPResponse {
        ShareHTTPResponse(status: response.status, headers: response.headers, body: Data())
    }

    private static func clientID(for connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint { return String(describing: host) }
        return String(describing: connection.endpoint)
    }

    private static func formValues(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for field in text.split(separator: "&") {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2 else { continue }
            let key = pair[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? pair[0]
            let value = pair[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? pair[1]
            result[key] = value
        }
        return result
    }

    private enum ByteRangeResult { case valid(UInt64, UInt64, Bool); case invalid }
    private static func parseRange(_ header: String?, fileSize: UInt64) -> ByteRangeResult {
        guard let header else { return .valid(0, fileSize - 1, false) }
        guard header.hasPrefix("bytes="), !header.contains(",") else { return .invalid }
        let value = String(header.dropFirst(6))
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return .invalid }
        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { return .invalid }
            let length = min(suffix, fileSize)
            return .valid(fileSize - length, fileSize - 1, true)
        }
        guard let start = UInt64(parts[0]), start < fileSize else { return .invalid }
        let end: UInt64
        if parts[1].isEmpty { end = fileSize - 1 }
        else { guard let parsed = UInt64(parts[1]), parsed >= start else { return .invalid }; end = min(parsed, fileSize - 1) }
        return .valid(start, end, true)
    }

    private func connectionIsOnActiveLAN(_ connection: NWConnection) -> Bool {
        guard let interface = activeLANInterface else { return false }
        guard case .hostPort(let host, _) = connection.endpoint else { return false }
        let hostText = String(describing: host).split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
        if hostText == "127.0.0.1" || hostText == "localhost" { return true }
        guard let value = Self.ipv4Value(hostText) else { return false }
        return interface.contains(value)
    }

    private static func preferredLANIPv4Interface() -> LANIPv4Interface? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var values: [LANIPv4Interface] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let info = current.pointee
            if let address = info.ifa_addr,
               let netmask = info.ifa_netmask,
               address.pointee.sa_family == UInt8(AF_INET),
               netmask.pointee.sa_family == UInt8(AF_INET) {
                let flags = Int32(info.ifa_flags)
                if flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 {
                    let name = String(cString: info.ifa_name)
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let length = socklen_t(address.pointee.sa_len)
                    if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let addressText = String(cString: host)
                        if let addressValue = ipv4Value(addressText), isPrivateLANAddress(addressValue) {
                            let maskValue = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                            }
                            guard maskValue != 0 else { pointer = info.ifa_next; continue }
                            values.append(LANIPv4Interface(
                                name: name,
                                address: addressText,
                                addressValue: addressValue,
                                networkValue: addressValue & maskValue,
                                netmaskValue: maskValue
                            ))
                        }
                    }
                }
            }
            pointer = info.ifa_next
        }
        return values.sorted { lhs, rhs in
            let left = interfacePriority(lhs.name), right = interfacePriority(rhs.name)
            return left == right ? lhs.name < rhs.name : left < right
        }.first
    }

    private static func interfacePriority(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name.hasPrefix("en") { return 10 }
        if name.hasPrefix("bridge") { return 20 }
        return 100
    }

    private static func ipv4Value(_ text: String) -> UInt32? {
        var address = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func isPrivateLANAddress(_ value: UInt32) -> Bool {
        let first = UInt8((value >> 24) & 0xff)
        let second = UInt8((value >> 16) & 0xff)
        return first == 10
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || (first == 169 && second == 254)
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 303: return "See Other"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 410: return "Gone"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Response"
        }
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        let filtered = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return String(filtered.prefix(120)).replacingOccurrences(of: "\"", with: "_")
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
