import Foundation

@main struct ShareCollaborationChecks {
    static func main() {
        let projectID = UUID(), clipID = UUID(), sceneID = UUID(), objectID = UUID()
        var time = Date(timeIntervalSince1970: 1000)
        var colourApplies = 0
        var project = ShareCollaborationProject(projectID: projectID, title: "Collaborate", clips: [.init(id: clipID, name: "Clip")],
            scenes: [.init(id: sceneID, name: "Scene", objects: [.init(id: objectID, name: "Cube", kind: "cube")])])
        let host = ShareCollaborationHost(provider: { project }, applyColour: { id, values in
            guard let index = project.clips.firstIndex(where: { $0.id == id }) else { return false }
            project.clips[index].values = values; colourApplies += 1; return true
        }, applyTransform: { scene, id, transform in
            guard scene == sceneID, let index = project.scenes[0].objects.firstIndex(where: { $0.id == id }) else { return false }
            project.scenes[0].objects[index].transform = transform; return true
        }, applyAddObject: { scene, id, kind in
            guard scene == sceneID else { return false }
            project.scenes[0].objects.append(.init(id: id, name: kind, kind: kind)); return true
        }, applyDeleteObject: { scene, id in
            guard scene == sceneID else { return false }
            project.scenes[0].objects.removeAll { $0.id == id }; return true
        }, now: { time })
        let start = host.snapshot()
        let colour = host.process(.init(kind: .join, projectID: projectID, domain: .colour), deviceID: "a", deviceName: "iPad")
        let scene = host.process(.init(kind: .join, projectID: projectID, domain: .scene), deviceID: "b", deviceName: "Laptop")
        precondition(colour.status == .ok && scene.status == .ok && host.snapshot().sessions.count == 2)
        precondition(host.process(.init(kind: .join, projectID: projectID, domain: .colour), deviceID: "c", deviceName: "Other").status == .busy)
        var values = ShareColourValues(); values.exposure = 1
        let change = ShareCollaborationCommand(kind: .colour, projectID: projectID, sessionID: colour.sessionID, targetID: clipID,
            expectedRevision: start.clips[0].revision, colour: values)
        precondition(host.process(change, deviceID: "b", deviceName: "Spoof").status == .unauthorized)
        let result = host.process(change, deviceID: "a", deviceName: "iPad")
        precondition(result.status == .ok && result.snapshot.clips[0].revision > start.clips[0].revision)
        precondition(host.process(change, deviceID: "a", deviceName: "iPad").status == .ok && colourApplies == 1, "Retries must be idempotent")
        var conflictingID = change; conflictingID.colour?.exposure = 2
        precondition(host.process(conflictingID, deviceID: "a", deviceName: "iPad").status == .invalid)
        var stale = change; stale.id = UUID(); stale.colour?.exposure = 2
        precondition(host.process(stale, deviceID: "a", deviceName: "iPad").status == .conflict)
        var transform = ShareObjectTransform(); transform.position.x = 3
        precondition(host.process(.init(kind: .transform, projectID: projectID, sessionID: scene.sessionID, targetID: objectID,
            sceneID: sceneID, expectedRevision: start.scenes[0].objects[0].revision, transform: transform), deviceID: "b", deviceName: "Laptop").status == .ok)
        precondition(project.clips[0].values.exposure == 1 && project.scenes[0].objects[0].transform.position.x == 3)
        project.clips[0].values.exposure = 0.5
        var localConflict = change; localConflict.id = UUID(); localConflict.expectedRevision = result.snapshot.clips[0].revision
        precondition(host.process(localConflict, deviceID: "a", deviceName: "iPad").status == .conflict)
        let current = host.snapshot()
        project.clips[0].editable = false
        var protected = change; protected.id = UUID(); protected.expectedRevision = current.clips[0].revision
        precondition(host.process(protected, deviceID: "a", deviceName: "iPad").status == .busy)
        project.clips[0].editable = true
        var invalid = change; invalid.id = UUID(); invalid.colour?.exposure = .nan
        precondition(host.process(invalid, deviceID: "a", deviceName: "iPad").status == .invalid)
        invalid.id = UUID(); invalid.colour?.exposure = 100
        precondition(host.process(invalid, deviceID: "a", deviceName: "iPad").status == .invalid)
        let membership = host.snapshot(); let addedID = UUID()
        let added = host.process(.init(kind: .addObject, projectID: projectID, sessionID: scene.sessionID, targetID: addedID,
            sceneID: sceneID, expectedRevision: membership.scenes[0].revision, objectKind: "sphere"), deviceID: "b", deviceName: "Laptop")
        precondition(added.status == .ok && project.scenes[0].objects.count == 2)
        let revision = added.snapshot.scenes[0].objects.first { $0.id == addedID }!.revision
        project.scenes[0].objects[1].changeToken = "local-material-change"
        let deletion = ShareCollaborationCommand(kind: .deleteObject, projectID: projectID, sessionID: scene.sessionID,
            targetID: addedID, sceneID: sceneID, expectedRevision: revision)
        precondition(host.process(deletion, deviceID: "b", deviceName: "Laptop").status == .conflict && project.scenes[0].objects.count == 2)
        var freshDelete = deletion; freshDelete.id = UUID(); freshDelete.expectedRevision = host.snapshot().scenes[0].objects[1].revision
        precondition(host.process(freshDelete, deviceID: "b", deviceName: "Laptop").status == .ok && project.scenes[0].objects.count == 1)
        time = time.addingTimeInterval(31)
        precondition(host.snapshot().sessions.isEmpty)
        precondition(host.process(.init(kind: .heartbeat, sessionID: scene.sessionID), deviceID: "b", deviceName: "Laptop").status == .unauthorized)
        project.projectID = UUID()
        precondition(host.process(.init(kind: .join, projectID: projectID, domain: .scene), deviceID: "b", deviceName: "Laptop").status == .conflict)
        host.reset(); precondition(host.snapshot().sessions.isEmpty)
        let html = ShareCompanion.html(csrfToken: "test-csrf")
        let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try! html.write(to: output.appendingPathComponent("companion.html"), atomically: true, encoding: .utf8) }
        let script = html.components(separatedBy: "<script>")[1].components(separatedBy: "</script>")[0]
        if let output { try! script.write(to: output.appendingPathComponent("companion.js"), atomically: true, encoding: .utf8) }
        print("PASS: independent domain leases/revisions, paired-device binding, idempotent commands, stale/local draft protection, finite bounds, 3D primitives/delete conflicts, expiry/project-switch/reset")
    }
}
