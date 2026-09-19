import Foundation

struct NetVistaUpdateRecovery: Codable {
    let id: UUID
    var video = false
    var photo = false
    var photoOriginalURL: URL?
    var photoName: String?
    static var root: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("NetVista Studio/Update Recovery").standardizedFileURL.resolvingSymlinksInPath()
    }
    var directory: URL { Self.root.appendingPathComponent(id.uuidString) }
    var manifestURL: URL { directory.appendingPathComponent("session.json") }
    var videoURL: URL { directory.appendingPathComponent("Video project.netvistastudio") }
    var photoURL: URL { directory.appendingPathComponent("Photo project.netvistaphoto") }
    func write() throws { try JSONEncoder().encode(self).write(to:manifestURL,options:.atomic) }
    static func load(_ url: URL) throws -> NetVistaUpdateRecovery {
        guard url.lastPathComponent == "session.json", url.deletingLastPathComponent().deletingLastPathComponent().path == root.path,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw NetVistaUpdateError.invalidResponse }
        let result = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        guard result.manifestURL == url else { throw NetVistaUpdateError.invalidResponse }
        return result
    }
}
