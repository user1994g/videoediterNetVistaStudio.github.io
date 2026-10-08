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
        var layered = MobileProject()
        var source = MobileClip(name: "Original source", file: "source.mov", duration: 8, outPoint: 8)
        source.effects = MobileClipEffects(scale: 1.5, positionX: 0.25, positionY: -0.5,
            rotation: 90, opacity: 0.4, brightness: 0.1, contrast: 1.3, saturation: 0.7)
        layered.library = [source, MobileClip(name: "Unused source", file: "unused.mov", duration: 4, outPoint: 4)]
        layered.clips = [source]
        try layered.split(0, at: 3)
        precondition(layered.clips.count == 2 && layered.clips[0].id != layered.clips[1].id)
        precondition(layered.clips[0].file == layered.clips[1].file)
        precondition(layered.clips.allSatisfy { $0.effects == source.effects })
        precondition(layered.totalDuration == 8 && layered.clips[1].inPoint == 3)
        let encoded = try JSONEncoder().encode(layered)
        let effectsLoaded = try JSONDecoder().decode(MobileProject.self, from: encoded)
        precondition(effectsLoaded == layered, "Source library or effects did not persist")
        layered.clips.removeAll()
        precondition(layered.library.count == 2, "Deleting timeline instances must not remove imported sources")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy["version"] = 1; legacy.removeValue(forKey: "library")
        legacy["clips"] = (legacy["clips"] as! [[String: Any]]).map { original in var clip = original; clip.removeValue(forKey: "effects"); return clip }
        let migrated = try JSONDecoder().decode(MobileProject.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(migrated.version == 3 && migrated.library.count == 1)
        precondition(migrated.clips.allSatisfy { $0.effects == MobileClipEffects() })
        precondition(migrated.library[0].inPoint == 0 && migrated.library[0].outPoint == 8)
        for bad in [Double.nan, Double.infinity, -1, 31_536_001] {
            var invalid = source; invalid.duration = bad
            do { try invalid.validate(); fatalError("Invalid or unbounded duration accepted") } catch {}
        }
        for bad in [Double.nan, Double.infinity, -0.01, 1.01] {
            var invalid = source; invalid.effects.opacity = bad
            do { try invalid.validate(); fatalError("Invalid opacity accepted") } catch {}
        }
        let bounded = MobileHistory()
        for index in 0..<75 { var next = movie; next.name = "Movie \(index)"; bounded.record(next) }
        precondition(bounded.undo.count == 50 && bounded.undo.first?.name == "Movie 25")
        print("PASS: trims, ordering, 50-step history, shared source library, split effects, legacy migration, portable metadata and validation")
    }
}
