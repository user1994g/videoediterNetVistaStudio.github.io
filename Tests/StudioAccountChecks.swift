import Foundation

private final class MemoryStore: StudioSessionStore {
    var data: Data?
    var failSave = false
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { if failSave { throw URLError(.cannotWriteToFile) }; self.data = data }
    func clear() throws { data = nil }
}
private func sessionData(expiry: TimeInterval, refresh: String = "refresh-1") -> Data {
    try! JSONSerialization.data(withJSONObject: ["access_token":"access", "refresh_token":refresh,
        "expires_at":expiry, "expires_in":3600, "user":["id":"user-1", "email":"test@example.invalid"]])
}
@main struct StudioAccountChecks {
    static func main() throws {
        let store = MemoryStore()
        var time = Date(timeIntervalSince1970: 10_000)
        var calls: [URLRequest] = []
        var replies: [Result<Data, Error>] = []
        let user = Data(#"{"id":"user-1","email":"test@example.invalid"}"#.utf8)
        let account = StudioAccount(store: store, now: { time }, transport: { request, reply in
            calls.append(request); precondition(!replies.isEmpty, "Unexpected request: \(request.url!)")
            precondition(request.url?.scheme == "https")
            reply(replies.removeFirst())
        })
        account.start()
        precondition(calls.isEmpty)
        replies = [.success(sessionData(expiry: 20_000)), .success(user)]
        account.signIn(email: " test@example.invalid ", password: "test-password", remember: true)
        precondition(account.session != nil && account.lastVerified == time && store.data != nil)
        precondition(!String(data: store.data!, encoding: .utf8)!.contains("test-password"))
        precondition(calls[0].httpMethod == "POST" && !calls[0].url!.absoluteString.contains("test-password"))
        precondition(calls.last!.url!.path == "/auth/v1/user")
        let count = calls.count
        time += 1499; account.checkIfDue(); precondition(calls.count == count)
        time += 1; replies = [.success(user)]; account.checkIfDue()
        precondition(calls.count == count + 1 && account.lastVerified == time)
        print("PASS: sign-in, secure session persistence, server user check, exact 25-minute boundary")

        replies = [.failure(URLError(.notConnectedToInternet))]; account.check(force: true)
        precondition(account.session != nil && store.data != nil)
        time += 59; account.checkIfDue(); precondition(replies.isEmpty)
        time += 1; replies = [.success(user)]; account.checkIfDue(); precondition(replies.isEmpty)
        replies = [.failure(StudioAuthFailure(status: 503, code: ""))]; account.check(force: true)
        precondition(account.session != nil)
        replies = [.failure(StudioAuthFailure(status: 429, code: "over_request_rate_limit"))]; account.check(force: true)
        precondition(account.session != nil)
        print("PASS: offline/server/rate-limit errors preserve work and session; bounded retry")

        time = Date(timeIntervalSince1970: 20_001)
        replies = [.success(sessionData(expiry: 30_000, refresh: "rotated")), .success(user)]
        account.checkIfDue()
        precondition(account.session?.refresh_token == "rotated")
        precondition(String(data: store.data!, encoding: .utf8)!.contains("rotated"))
        precondition(calls.suffix(2).first!.url!.query == "grant_type=refresh_token")
        print("PASS: expired access token refreshes without a password; rotated token saved")

        var invalidations = 0; account.onInvalidated = { invalidations += 1 }
        replies = [.failure(StudioAuthFailure(status: 403, code: "user_not_found"))]
        account.check(force: true)
        precondition(account.session == nil && store.data == nil && invalidations == 1)
        account.checkIfDue(); precondition(invalidations == 1)
        print("PASS: deleted account clears session and notifies exactly once")

        replies = [.success(sessionData(expiry: 30_000)), .success(user)]
        account.signIn(email: "test@example.invalid", password: "another", remember: false)
        precondition(store.data == nil)
        replies = [.failure(StudioAuthFailure(status: 401, code: "bad_jwt")),
                   .failure(StudioAuthFailure(status: 400, code: "refresh_token_not_found"))]
        account.check(force: true); precondition(account.session == nil)

        var pending: StudioAccount.Reply?
        let racing = StudioAccount(store: MemoryStore(), transport: { _, reply in pending = reply })
        racing.signIn(email: "test@example.invalid", password: "secret", remember: true)
        racing.signOut(); pending?(.success(sessionData(expiry: 30_000)))
        precondition(racing.session == nil)
        print("PASS: session-only sign-in, revoked refresh, late sign-in cannot undo sign-out")

        let restoredStore = MemoryStore(); restoredStore.data = sessionData(expiry: 50_000)
        let restored = StudioAccount(store: restoredStore, now: { time }, transport: { request, reply in
            precondition(request.url!.path == "/auth/v1/user"); reply(.success(user))
        })
        restored.start(); precondition(restored.lastVerified == time)
        print("PASS: restart restores saved session and verifies against server immediately")
    }
}
