import Foundation

private final class MemoryAccountStore: StudioSessionStore {
    var data: Data?
    var writes = 0
    func load() throws -> Data? { data }
    func save(_ value: Data) throws { writes += 1; data = value }
    func clear() throws { data = nil }
}
@main struct MobileAccountChecks {
    static func main() throws {
        let anonymous = Data(#"{"id":"fixture","is_anonymous":true}"#.utf8)
        if case .success = MobileAccount.checkedResponse(.success(anonymous)) { fatalError("Anonymous fresh user passed") }
        let nested = Data(#"{"user":{"id":"fixture","is_anonymous":true}}"#.utf8)
        if case .success = MobileAccount.checkedResponse(.success(nested)) { fatalError("Anonymous token user passed") }
        let real = Data(#"{"id":"fixture","email":"fixture@example.invalid","is_anonymous":false}"#.utf8)
        let valid = try MobileAccount.checkedResponse(.success(real)).get(); precondition(valid == real)
        let store = MemoryAccountStore(); var paths: [String] = []
        var replies: [Data] = []
        let account = StudioAccount(store: store, transport: { request, reply in
            paths.append(request.url!.path)
            reply(MobileAccount.checkedResponse(.success(replies.removeFirst())))
        })
        account.start(); precondition(paths.isEmpty && store.writes == 0)
        let session = Data(#"{"access_token":"fixture-token","refresh_token":"fixture-refresh","expires_in":3600,"user":{"id":"fixture","email":"fixture@example.invalid","is_anonymous":false}}"#.utf8)
        replies = [session, real]
        account.signIn(email: "fixture@example.invalid", password: "not-a-real-password", remember: true)
        precondition(account.lastVerified != nil && paths.last == "/auth/v1/user")
        precondition(!String(data: store.data!, encoding: .utf8)!.contains("not-a-real-password"))
        replies = [anonymous]; account.check(force: true)
        precondition(account.session == nil && store.data == nil && account.lastVerified == nil)
        print("PASS: native mobile auth startup does not persist, fresh user gate, no password storage and anonymous account rejection")
    }
}
