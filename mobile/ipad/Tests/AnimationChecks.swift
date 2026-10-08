import Foundation

/// Pure project/math checks. Pixel checks separately prove that these same
/// curves reach the real Core Image compositor and the encoded MP4.
@main struct AnimationChecks {
    static func near(_ a: Double, _ b: Double, _ text: String) { precondition(abs(a - b) < 0.000_001, "\(text): \(a) != \(b)") }
    static func rejected(_ mutation: (inout MobileClipEffects) -> Void, _ text: String) {
        var effects = MobileClipEffects(); mutation(&effects)
        do { try effects.validate(duration: 8); fatalError("Invalid curve accepted: \(text)") } catch {}
    }
    static func main() throws {
        var effects = MobileClipEffects(opacity: 0.7)
        near(effects.value(for: .opacity, at: 4), 0.7, "Static fallback")
        try effects.upsertKeyframe(for: .opacity, at: 2, value: 0)
        try effects.upsertKeyframe(for: .opacity, at: 6, value: 1)
        near(effects.value(for: .opacity, at: 0), 0, "Before first clamp")
        near(effects.value(for: .opacity, at: 3), 0.25, "Linear quarter")
        near(effects.value(for: .opacity, at: 4), 0.5, "Linear midpoint")
        near(effects.value(for: .opacity, at: 9), 1, "After last clamp")
        near(effects.value(for: .opacity, at: .nan), 0.7, "Nonfinite preview fallback")
        try effects.upsertKeyframe(for: .opacity, at: 2, value: 0, interpolation: .easeIn)
        near(effects.value(for: .opacity, at: 3), 0.0625, "Ease In quarter")
        near(effects.value(for: .opacity, at: 5), 0.5625, "Ease In three quarters")
        try effects.upsertKeyframe(for: .opacity, at: 2, value: 0, interpolation: .easeOut)
        near(effects.value(for: .opacity, at: 3), 0.4375, "Ease Out quarter")
        near(effects.value(for: .opacity, at: 5), 0.9375, "Ease Out three quarters")
        try effects.upsertKeyframe(for: .opacity, at: 2, value: 0, interpolation: .easeInOut)
        near(effects.value(for: .opacity, at: 3), 0.15625, "Smoothstep quarter")
        near(effects.value(for: .opacity, at: 5), 0.84375, "Smoothstep three quarters")
        precondition(MobileKeyframeInterpolation.allCases.count == 5, "All Mac curve choices must remain available")
        for mode in MobileKeyframeInterpolation.allCases {
            var saved = effects; try saved.upsertKeyframe(for: .opacity, at: 2, value: 0, interpolation: mode)
            let encoded = try JSONEncoder().encode(saved)
            let reopened = try JSONDecoder().decode(MobileClipEffects.self, from: encoded)
            precondition(reopened == saved, "Interpolation \(mode.rawValue) failed native persistence")
        }
        try effects.upsertKeyframe(for: .opacity, at: 2, value: 0, interpolation: .hold)
        near(effects.value(for: .opacity, at: 5.999), 0, "Hold before next")
        near(effects.value(for: .opacity, at: 6), 1, "Hold exact next")
        try effects.upsertKeyframe(for: .scale, at: 0, value: 0.5)
        try effects.upsertKeyframe(for: .scale, at: 8, value: 2)
        try effects.upsertKeyframe(for: .positionX, at: 0, value: -1)
        try effects.upsertKeyframe(for: .positionX, at: 8, value: 1)
        try effects.upsertKeyframe(for: .rotation, at: 0, value: -90)
        try effects.upsertKeyframe(for: .rotation, at: 8, value: 90)
        let middle = effects.evaluated(at: 4)
        near(middle.scale, 1.25, "All-property evaluation scale"); near(middle.positionX, 0, "X")
        near(middle.rotation, 0, "Rotation"); precondition(middle.keyframes.isEmpty)
        let before = effects
        for (time, value) in [(Double.nan, 0.5), (Double.infinity, 0.5), (-1, 0.5), (9, Double.nan), (9, 1.1)] {
            do { try effects.upsertKeyframe(for: .opacity, at: time, value: value); fatalError("Invalid edit accepted") } catch {}
            precondition(effects == before, "Rejected edit partially changed curve")
        }
        rejected({ $0.keyframes["unknown"] = [MobileEffectKeyframe(sourceSeconds: 0, value: 1)] }, "Unknown property")
        rejected({ $0.keyframes["opacity"] = [] }, "Empty saved track")
        rejected({ $0.keyframes["opacity"] = [MobileEffectKeyframe(sourceSeconds: 0, value: .infinity)] }, "Infinite value")
        rejected({ $0.keyframes["opacity"] = [MobileEffectKeyframe(sourceSeconds: .nan, value: 0)] }, "NaN time")
        rejected({ $0.keyframes["opacity"] = [MobileEffectKeyframe(sourceSeconds: 9, value: 0)] }, "Beyond source")
        rejected({ $0.keyframes["opacity"] = [MobileEffectKeyframe(sourceSeconds: 1, value: 0), MobileEffectKeyframe(sourceSeconds: 1, value: 1)] }, "Duplicate time")
        rejected({ $0.keyframes["opacity"] = [MobileEffectKeyframe(sourceSeconds: 2, value: 0), MobileEffectKeyframe(sourceSeconds: 1, value: 1)] }, "Unsorted time")
        rejected({ $0.keyframes["opacity"] = [MobileEffectKeyframe(sourceSeconds: 0, value: -0.01)] }, "Out-of-range value")
        rejected({ $0.keyframes["opacity"] = (0...2_000).map { MobileEffectKeyframe(sourceSeconds: Double($0) / 600, value: 1) } }, "Track cap")
        var clip = MobileClip(name: "Animation", file: "source.mov", duration: 8, inPoint: 1, outPoint: 7, effects: effects)
        try clip.validate()
        var project = MobileProject(); project.clips = [clip]
        let history = MobileHistory(); history.record(project)
        try project.split(0, at: 3)
        precondition(project.clips[0].effects == effects && project.clips[1].effects == effects)
        precondition(project.clips[1].inPoint == 4 && project.clips[0].outPoint == 4)
        // A split's left last and right first samples meet in the SAME source curve.
        near(project.clips[0].effects.value(for: .scale, at: 4), project.clips[1].effects.value(for: .scale, at: 4), "Split continuity")
        try project.trim(1, start: 5, end: 7)
        near(project.clips[1].effects.value(for: .scale, at: project.clips[1].inPoint), 1.4375, "Trim does not restart curve")
        var copy = project.clips[1]; copy.id = UUID(); project.clips.append(copy)
        try project.clips[2].effects.upsertKeyframe(for: .scale, at: 5, value: 3)
        precondition(project.clips[1].effects != project.clips[2].effects, "Duplicate animation must be independent value state")
        project.move(2, to: 0)
        near(project.clips[0].effects.value(for: .scale, at: 5), 3, "Move preserves source curve")
        let previous = history.undo(project)!
        precondition(previous.clips.count == 1 && previous.clips[0].effects == effects)
        precondition(history.redo(previous) == project, "Redo lost full keyframe tracks")
        let data = try JSONEncoder().encode(project)
        let loaded = try JSONDecoder().decode(MobileProject.self, from: data)
        precondition(loaded == project, "Save/reopen lost animation")
        var schema2 = try JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as! [String: Any]
        schema2["version"] = 2
        schema2["clips"] = (schema2["clips"] as! [[String: Any]]).map { original in
            var clip = original, effects = clip["effects"] as! [String: Any]; effects.removeValue(forKey: "keyframes"); clip["effects"] = effects; return clip
        }
        let migrated = try JSONDecoder().decode(MobileProject.self, from: JSONSerialization.data(withJSONObject: schema2))
        precondition(migrated.version == 3 && migrated.clips[0].effects.keyframes.isEmpty)
        near(migrated.clips[0].effects.opacity, 0.7, "Schema2 static values unchanged")
        effects.removeKeyframe(for: .opacity, at: 2); precondition(effects.frames(for: .opacity).count == 1)
        effects.removeKeyframe(for: .opacity, at: 6); precondition(effects.keyframes["opacity"] == nil)
        clip.effects = effects; try clip.validate()
        print("PASS: 8-property source-time curves, all 5 Mac interpolation modes, strict validation/caps, split/trim/move/duplicate, undo/redo and schema 2/3 migration")
    }
}
