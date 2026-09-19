import Foundation
import Security

// Only the public client key belongs in a distributed application.
enum StudioAuthConfig {
    static let baseURL = URL(string: "https://tsitgxafmtzjgtmiczsq.supabase.co/auth/v1/")!
    static let publishableKey = "sb_publishable__tAdP-Xsu5Gh2ImdKvOHnw_WVujAfJh"
    static let accountURL = URL(string: "https://video.netvistastudio.com/account/")!
    static let checkInterval: TimeInterval = 25 * 60
}

struct StudioAuthUser: Codable { let id: String; let email: String? }
struct StudioAuthSession: Codable {
    let access_token: String
    let refresh_token: String
    var expires_at: TimeInterval?
    let expires_in: TimeInterval?
    var user: StudioAuthUser
}

protocol StudioSessionStore {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func clear() throws
}

struct StudioKeychainStore: StudioSessionStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.netvistastudio.account",
         kSecAttrAccount as String: "supabase-session"]
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    func load() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status); return result as? Data
    }
    func save(_ data: Data) throws {
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}

struct StudioAuthFailure: Error {
    let status: Int
    let code: String
    // Only explicit auth rejection invalidates a session. Offline, rate limiting,
    // server errors and malformed responses must not be treated as deletion.
    var rejectsSession: Bool {
        ["user_not_found", "user_banned", "session_not_found", "session_expired",
         "refresh_token_not_found", "refresh_token_already_used", "bad_jwt"].contains(code)
        || status == 401 || status == 403
    }
}

final class StudioAccount {
    typealias Reply = (Result<Data, Error>) -> Void
    typealias Transport = (URLRequest, @escaping Reply) -> Void
    private let store: StudioSessionStore
    private let transport: Transport
    private let now: () -> Date
    private var timer: Timer?
    private var generation = 0
    private var remember = true
    private var lastAttempt: Date?
    private var retryAt: Date?
    private var storageWarning = false
    private(set) var session: StudioAuthSession?
    private(set) var busy = false
    private(set) var lastVerified: Date?
    private(set) var status = "Sign in with your NetVista account. Your projects stay on this computer."
    var onChange: (() -> Void)?
    var onInvalidated: (() -> Void)?
    var email: String? { session?.user.email }

    init(store: StudioSessionStore = StudioKeychainStore(), now: @escaping () -> Date = Date.init,
         transport: @escaping Transport = StudioAccount.send) {
        self.store = store; self.now = now; self.transport = transport
    }
    deinit { timer?.invalidate() }

    static func send(_ request: URLRequest, completion: @escaping Reply) {
        // Ephemeral networking avoids a disk cache of auth responses. Redirects
        // are not followed: credentials must only go to the configured origin.
        let client = URLSession(configuration: .ephemeral, delegate: StudioAuthNoRedirect(), delegateQueue: nil)
        client.dataTask(with: request) { data, response, error in
            let result: Result<Data, Error>
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result = .success(data ?? Data())
            } else {
                let payload = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
                result = .failure(StudioAuthFailure(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                    code: payload?["error_code"] as? String ?? payload?["error"] as? String ?? ""))
            }
            client.finishTasksAndInvalidate()
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func request(_ path: String, body: [String: String]? = nil, token: String? = nil, completion: @escaping Reply) {
        var request = URLRequest(url: URL(string: path, relativeTo: StudioAuthConfig.baseURL)!.absoluteURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(StudioAuthConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        transport(request, completion)
    }

    func start() {
        guard timer == nil else { return }
        do {
            if let data = try store.load() { session = try JSONDecoder().decode(StudioAuthSession.self, from: data) }
        } catch { status = "Saved sign-in could not be read. Please sign in again." }
        timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(timer!, forMode: .common)
        onChange?()
        check(force: true)
    }

    func checkIfDue() {
        guard let session, !busy else { return }
        if let retryAt, now() < retryAt { return }
        if lastAttempt == nil || now().timeIntervalSince(lastAttempt!) >= StudioAuthConfig.checkInterval
            || (session.expires_at ?? 0) <= now().timeIntervalSince1970 + 60 { check(force: true) }
    }

    func signIn(email: String, password: String, remember: Bool) {
        guard !busy else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !password.isEmpty else { status = "Enter your email address and password."; onChange?(); return }
        generation += 1; let ticket = generation
        self.remember = remember; busy = true; status = "Signing in securely…"; onChange?()
        request("token?grant_type=password", body: ["email": email, "password": password]) { [weak self] result in
            guard let self, ticket == self.generation else { return }
            do {
                self.session = try self.decodeSession(result.get())
                self.persist(); self.busy = false; self.check(force: true)
            } catch {
                self.busy = false
                if let failure = error as? StudioAuthFailure {
                    self.status = failure.code == "email_not_confirmed" ? "Confirm your email before signing in. You can manage your account on the website."
                        : failure.status == 429 ? "Too many attempts. Please wait a moment and try again."
                        : "Could not sign in. Check your email and password, then try again."
                } else { self.status = "Could not reach NetVista. Check your connection and try again." }
                self.onChange?()
            }
        }
    }

    private func decodeSession(_ data: Data) throws -> StudioAuthSession {
        var value = try JSONDecoder().decode(StudioAuthSession.self, from: data)
        guard !value.access_token.isEmpty, !value.refresh_token.isEmpty, !value.user.id.isEmpty else { throw URLError(.cannotParseResponse) }
        if value.expires_at == nil { value.expires_at = now().timeIntervalSince1970 + (value.expires_in ?? 3600) }
        return value
    }

    private func persist() {
        do {
            if remember, let session { try store.save(JSONEncoder().encode(session)) }
            else { try store.clear() }
            storageWarning = false
        } catch {
            // Keep editing in this session but never fall back to plaintext storage.
            storageWarning = true
        }
    }

    func check(force: Bool = false) {
        guard session != nil, !busy else { return }
        if !force { checkIfDue(); return }
        busy = true; lastAttempt = now(); retryAt = nil
        status = "Checking your account…"; onChange?()
        let ticket = generation
        if (session?.expires_at ?? 0) <= now().timeIntervalSince1970 + 60 { refresh(ticket: ticket) }
        else { fetchUser(ticket: ticket, mayRefresh: true) }
    }

    private func refresh(ticket: Int) {
        guard let old = session else { return }
        request("token?grant_type=refresh_token", body: ["refresh_token": old.refresh_token]) { [weak self] result in
            guard let self, ticket == self.generation else { return }
            do {
                let renewed = try self.decodeSession(result.get())
                guard renewed.user.id == old.user.id else { throw StudioAuthFailure(status: 401, code: "user_not_found") }
                self.session = renewed; self.persist()
                self.fetchUser(ticket: ticket, mayRefresh: false)
            } catch { self.failedCheck(error) }
        }
    }

    private func fetchUser(ticket: Int, mayRefresh: Bool) {
        guard let current = session else { return }
        request("user", token: current.access_token) { [weak self] result in
            guard let self, ticket == self.generation else { return }
            do {
                let user = try JSONDecoder().decode(StudioAuthUser.self, from: result.get())
                guard user.id == current.user.id else { throw StudioAuthFailure(status: 401, code: "user_not_found") }
                self.session?.user = user; self.persist()
                self.busy = false; self.lastVerified = self.now()
                self.status = self.storageWarning ? "Account verified. Keychain is unavailable; sign-in may not survive a restart."
                    : "Account verified. We'll check again in 25 minutes—no password needed."
                self.onChange?()
            } catch {
                if mayRefresh, let failure = error as? StudioAuthFailure, failure.status == 401,
                   failure.code != "user_not_found", failure.code != "session_not_found" {
                    self.refresh(ticket: ticket)
                } else { self.failedCheck(error) }
            }
        }
    }

    private func failedCheck(_ error: Error) {
        busy = false
        if let failure = error as? StudioAuthFailure, failure.rejectsSession {
            generation += 1; session = nil; lastVerified = nil
            do { try store.clear(); status = "Your account or session is no longer available. Please sign in again. Your open projects are safe." }
            catch { status = "Your session is no longer valid. Saved sign-in could not be removed from Keychain. Your projects are safe." }
            onChange?(); onInvalidated?()
        } else {
            retryAt = now().addingTimeInterval(60)
            // lastAttempt ensures a failed retry does not hammer the server.
            lastAttempt = now().addingTimeInterval(60 - StudioAuthConfig.checkInterval)
            status = "Account check postponed: connection unavailable. Your work is safe; we'll retry automatically."
            onChange?()
        }
    }

    func signOut() {
        let token = session?.access_token
        generation += 1; session = nil; busy = false; lastVerified = nil; retryAt = nil; lastAttempt = nil
        do { try store.clear(); status = "Signed out on this device. You can continue editing locally." }
        catch { status = "Signed out for now, but Keychain could not be cleared. Remove NetVista's saved session in Keychain Access before sharing this Mac." }
        onChange?()
        if let token { request("logout?scope=local", body: [:], token: token) { _ in } }
    }
}

private final class StudioAuthNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
