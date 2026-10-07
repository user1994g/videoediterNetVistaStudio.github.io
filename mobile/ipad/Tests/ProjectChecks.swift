import Foundation

@main struct ProjectChecks {
    static func main() throws {
        var movie = MobileProject()
        movie.clips = [MobileClip(name: "First", file: "first.mov", duration: 5, outPoint: 5),
                       MobileClip(name: "Second", file: "second.mov", duration: 3, outPoint: 3)]
        try movie.trim(0, start: 1, end: 4)
        precondition(movie.totalDuration == 6)
        let history = MobileHistory(); history.record(movie)
        movie.move(1, to: 0); precondition(movie.clips[0].name == "Second")
        let before = history.undo(movie)!; precondition(before.clips[0].name == "First")
        precondition(history.redo(before) == movie)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try movie.write(temporary); let loaded = try MobileProject.read(temporary); precondition(loaded == movie)
        try FileManager.default.removeItem(at: temporary)
        for bad in [Double.nan, Double.infinity, -1, 5] {
            do { try movie.trim(0, start: bad, end: 3); fatalError("Invalid trim accepted") } catch {}
        }
        var traversal = movie; traversal.clips[0].file = "../secret"; do { try traversal.validate(); fatalError("Traversal accepted") } catch {}
        var duplicate = movie; duplicate.clips.append(movie.clips[0]); do { try duplicate.validate(); fatalError("Duplicate ID accepted") } catch {}
        print("PASS: Mobile project trim, ordering, undo/redo, portable metadata and validation")
    }
}
