import Foundation

// This wire model deliberately has no AppKit/SceneKit dependency. Remote edits
// touch only primary colour controls or one object's transform, never replace a
// project, scene document, node graph, asset URL, or animation track.
enum ShareCollaborationDomain: String, Codable, CaseIterable { case colour, scene }

struct ShareColourValues: Codable, Equatable {
    var exposure = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var temperature = 6_500.0
    var tint = 0.0
    var vibrance = 0.0

    var isValid: Bool {
        Self.contains(exposure, -3...3) && Self.contains(contrast, 0.25...2)
            && Self.contains(saturation, 0...2) && Self.contains(temperature, 2_000...10_000)
            && Self.contains(tint, -100...100) && Self.contains(vibrance, -1...1)
    }

    fileprivate static func contains(_ value: Double, _ range: ClosedRange<Double>) -> Bool {
        value.isFinite && range.contains(value)
    }

    fileprivate var finiteSnapshot: Self {
        var copy = self
        if !copy.exposure.isFinite { copy.exposure = 0 }
        if !copy.contrast.isFinite { copy.contrast = 1 }
        if !copy.saturation.isFinite { copy.saturation = 1 }
        if !copy.temperature.isFinite { copy.temperature = 6_500 }
        if !copy.tint.isFinite { copy.tint = 0 }
        if !copy.vibrance.isFinite { copy.vibrance = 0 }
        return copy
    }
}

struct ShareVector3: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0

    fileprivate func isValid(in range: ClosedRange<Double>) -> Bool {
        ShareColourValues.contains(x, range) && ShareColourValues.contains(y, range)
            && ShareColourValues.contains(z, range)
    }

    fileprivate var finiteSnapshot: Self {
        .init(x: x.isFinite ? x : 0, y: y.isFinite ? y : 0, z: z.isFinite ? z : 0)
    }
}

struct ShareObjectTransform: Codable, Equatable {
    var position = ShareVector3()
    /// Euler angles in degrees, matching SceneObjectRecord.rotation.
    var rotation = ShareVector3()
    var scale = ShareVector3(x: 1, y: 1, z: 1)

    var isValid: Bool {
        position.isValid(in: -100_000...100_000)
            && rotation.isValid(in: -360_000...360_000)
            && scale.isValid(in: 0.001...1_000)
    }

    fileprivate var finiteSnapshot: Self {
        .init(position: position.finiteSnapshot, rotation: rotation.finiteSnapshot,
              scale: scale.finiteSnapshot)
    }
}

struct ShareColourClip: Codable, Equatable {
    var id: UUID
    var name: String
    var mediaID: UUID? = nil
    var values = ShareColourValues()
    var duration: Double = 0
    /// Assigned by the host, independently of every other clip/object.
    var revision: Int = 0
    var editable = true
}

struct ShareSceneObject: Codable, Equatable {
    var id: UUID
    var name: String
    var kind: String
    var transform = ShareObjectTransform()
    var revision: Int = 0
    var editable = true
    /// Optional digest of the full native object. Never include raw asset URLs
    /// or serialized documents; this detects local rig/material/animation edits
    /// before a destructive deletion as well as transform-only changes.
    var changeToken: String? = nil
}

struct ShareSceneState: Codable, Equatable {
    var id: UUID
    var name: String
    var objects: [ShareSceneObject]
    var revision: Int = 0
    var duration: Double = 5
    var editable = true
}

/// The provider returns persisted host state, not floating-window preview drafts.
struct ShareCollaborationProject: Equatable {
    var projectID: UUID
    var title: String
    var clips: [ShareColourClip]
    var scenes: [ShareSceneState]
}

struct ShareCollaborationSession: Codable, Equatable {
    var id: UUID
    var deviceName: String
    var domain: ShareCollaborationDomain
    /// Unix seconds. Heartbeat every five seconds; abandoned leases last 30s.
    var expiresAt: Double
}

struct ShareCollaborationSnapshot: Codable, Equatable {
    var version = 1
    var projectID: UUID?
    var title: String
    var clips: [ShareColourClip]
    var scenes: [ShareSceneState]
    var sessions: [ShareCollaborationSession]
}

enum ShareCollaborationCommandKind: String, Codable {
    case join, heartbeat, leave, colour, transform, addObject, deleteObject
}

struct ShareCollaborationCommand: Codable, Equatable {
    var id = UUID()
    var kind: ShareCollaborationCommandKind
    var projectID: UUID? = nil
    var sessionID: UUID? = nil
    var domain: ShareCollaborationDomain? = nil
    /// A clip ID for colour commands; an object ID for transform commands.
    var targetID: UUID? = nil
    var sceneID: UUID? = nil
    var expectedRevision: Int? = nil
    var colour: ShareColourValues? = nil
    var transform: ShareObjectTransform? = nil
    var objectKind: String? = nil
}

enum ShareCollaborationStatus: String, Codable {
    case ok, invalid, conflict, busy, unavailable, unauthorized, failed
}

struct ShareCollaborationResult: Codable, Equatable {
    var commandID: UUID
    var status: ShareCollaborationStatus
    var message: String
    var sessionID: UUID?
    var snapshot: ShareCollaborationSnapshot
}

/// Host-authoritative collaboration, confined to the main thread. Authentication
/// belongs to the HTTP server: deviceID must come from its authenticated device,
/// never an untrusted clientID field in JSON. Reads return value snapshots.
/// Callbacks must update persisted state synchronously, preserve unsupported
/// fields, and return false if a native unsaved draft would be overwritten.
final class ShareCollaborationHost {
    static let leaseDuration: TimeInterval = 30
    static let maxCommandBytes = 8_192
    static let maximumSceneObjects = 1_000
    static let primitiveKinds: Set<String> = ["cube", "sphere", "cylinder", "plane"]
    private static let maximumRevision = 9_007_199_254_740_991

    private struct ObjectKey: Hashable { var sceneID: UUID; var objectID: UUID }
    private struct ObjectMembership: Equatable { var id: UUID; var kind: String }
    private struct ObjectValue: Equatable {
        var transform: ShareObjectTransform
        var name: String
        var kind: String
        var changeToken: String?
    }
    private struct Revision<Value: Equatable> {
        var value: Value?
        var editable: Bool
        var number: Int
    }
    private struct Lease {
        var session: ShareCollaborationSession
        var deviceID: String
    }
    private struct ReceiptKey: Hashable { var deviceID: String; var commandID: UUID }
    private struct Receipt {
        var command: ShareCollaborationCommand
        var status: ShareCollaborationStatus
        var message: String
        var sessionID: UUID?
    }

    private let provider: () -> ShareCollaborationProject?
    private let applyColour: (UUID, ShareColourValues) -> Bool
    private let applyTransform: (UUID, UUID, ShareObjectTransform) -> Bool
    private let applyAddObject: ((UUID, UUID, String) -> Bool)?
    private let applyDeleteObject: ((UUID, UUID) -> Bool)?
    private let now: () -> Date
    private var projectID: UUID?
    private var clipRevisions: [UUID: Revision<ShareColourValues>] = [:]
    private var objectRevisions: [ObjectKey: Revision<ObjectValue>] = [:]
    private var sceneRevisions: [UUID: Revision<[ObjectMembership]>] = [:]
    private var leases: [ShareCollaborationDomain: Lease] = [:]
    private var receipts: [ReceiptKey: Receipt] = [:]
    private var receiptOrder: [ReceiptKey] = []

    init(provider: @escaping () -> ShareCollaborationProject?,
         applyColour: @escaping (UUID, ShareColourValues) -> Bool,
         applyTransform: @escaping (UUID, UUID, ShareObjectTransform) -> Bool,
         applyAddObject: ((UUID, UUID, String) -> Bool)? = nil,
         applyDeleteObject: ((UUID, UUID) -> Bool)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.applyColour = applyColour
        self.applyTransform = applyTransform
        self.applyAddObject = applyAddObject
        self.applyDeleteObject = applyDeleteObject
        self.now = now
    }

    /// Invalidate collaboration when sharing stops, devices are revoked, or the
    /// host switches projects. Active HTTP requests cannot reuse old leases.
    func reset() {
        precondition(Thread.isMainThread)
        projectID = nil
        clipRevisions.removeAll()
        objectRevisions.removeAll()
        sceneRevisions.removeAll()
        leases.removeAll()
        receipts.removeAll()
        receiptOrder.removeAll()
    }

    func snapshot() -> ShareCollaborationSnapshot {
        precondition(Thread.isMainThread)
        expireLeases()
        guard var project = provider() else {
            if projectID != nil { reset() }
            return .init(projectID: nil, title: "No shared project", clips: [], scenes: [], sessions: [])
        }
        if project.projectID != projectID {
            reset()
            projectID = project.projectID
        }

        // Duplicate IDs cannot identify a unique mutation target. Retain one
        // display row but disable editing; the native provider must resolve it.
        let duplicateClips = Self.duplicates(project.clips.map(\.id))
        let duplicateScenes = Self.duplicates(project.scenes.map(\.id))
        var seenClips = Set<UUID>()
        var seenObjects = Set<ObjectKey>()
        project.clips = project.clips.filter { seenClips.insert($0.id).inserted }.map { clip in
            var copy = clip
            copy.editable = clip.editable && clip.values.isValid && !duplicateClips.contains(clip.id)
            let value = clip.values.finiteSnapshot
            copy.revision = update(value: value, editable: copy.editable, key: clip.id, in: &clipRevisions)
            copy.values = value
            copy.name = Self.displayName(clip.name)
            copy.duration = Self.duration(clip.duration)
            return copy
        }
        var seenScenes = Set<UUID>()
        project.scenes = project.scenes.filter { seenScenes.insert($0.id).inserted }.map { scene in
            var copy = scene
            copy.editable = scene.editable && !duplicateScenes.contains(scene.id)
            let duplicates = Self.duplicates(scene.objects.map(\.id))
            var ids = Set<UUID>()
            copy.objects = scene.objects.filter { ids.insert($0.id).inserted }.map { object in
                var row = object
                let key = ObjectKey(sceneID: scene.id, objectID: object.id)
                seenObjects.insert(key)
                row.editable = copy.editable && object.editable && object.transform.isValid
                    && !duplicateScenes.contains(scene.id) && !duplicates.contains(object.id)
                let value = object.transform.finiteSnapshot
                row.revision = update(value: ObjectValue(transform: value, name: object.name,
                    kind: object.kind, changeToken: object.changeToken),
                    editable: row.editable, key: key, in: &objectRevisions)
                row.transform = value
                row.name = Self.displayName(object.name)
                row.kind = Self.displayName(object.kind)
                row.changeToken = object.changeToken.map { Self.displayName($0, maximum: 128) }
                return row
            }
            copy.name = Self.displayName(scene.name)
            copy.duration = Self.duration(scene.duration)
            copy.revision = update(value: copy.objects.map { ObjectMembership(id: $0.id, kind: $0.kind) },
                editable: copy.editable, key: scene.id, in: &sceneRevisions)
            return copy
        }
        tombstoneMissing(seenClips, in: &clipRevisions)
        tombstoneMissing(seenObjects, in: &objectRevisions)
        tombstoneMissing(seenScenes, in: &sceneRevisions)
        return .init(projectID: project.projectID, title: Self.displayName(project.title),
                     clips: project.clips, scenes: project.scenes,
                     sessions: leases.values.map(\.session).sorted { $0.domain.rawValue < $1.domain.rawValue })
    }

    func process(_ command: ShareCollaborationCommand, deviceID: String,
                 deviceName: String) -> ShareCollaborationResult {
        precondition(Thread.isMainThread)
        let current = snapshot()
        func result(_ status: ShareCollaborationStatus, _ message: String,
                    sessionID: UUID? = nil, snapshot: ShareCollaborationSnapshot? = nil) -> ShareCollaborationResult {
            .init(commandID: command.id, status: status, message: message,
                  sessionID: sessionID, snapshot: snapshot ?? current)
        }
        guard !deviceID.isEmpty, deviceID.utf8.count <= 512 else {
            return result(.unauthorized, "An authenticated paired device is required.")
        }
        guard current.projectID != nil else { return result(.unavailable, "No shared project is open.") }
        let key = ReceiptKey(deviceID: deviceID, commandID: command.id)
        if let receipt = receipts[key] {
            guard receipt.command == command else {
                return result(.invalid, "A command ID cannot be reused for a different request.")
            }
            return result(receipt.status, receipt.message, sessionID: receipt.sessionID)
        }
        let output: ShareCollaborationResult
        if !isValidShape(command) {
            output = result(.invalid, "Malformed or unsupported collaboration command.")
        } else if [.join, .colour, .transform, .addObject, .deleteObject].contains(command.kind), command.projectID != current.projectID {
            output = result(.conflict, "The shared project changed. Refresh before editing.")
        } else if command.kind == .join {
            let domain = command.domain!
            if let lease = leases[domain], lease.deviceID != deviceID {
                output = result(.busy, "\(lease.session.deviceName) is editing \(domain == .colour ? "Colour" : "3D").")
            } else {
                var lease = leases[domain] ?? Lease(session: .init(id: UUID(),
                    deviceName: Self.displayName(deviceName, maximum: 80), domain: domain,
                    expiresAt: 0), deviceID: deviceID)
                lease.session.expiresAt = now().timeIntervalSince1970 + Self.leaseDuration
                leases[domain] = lease
                output = result(.ok, "Editing session ready.", sessionID: lease.session.id, snapshot: snapshot())
            }
        } else if let entry = leases.first(where: { $0.value.session.id == command.sessionID }),
                  entry.value.deviceID == deviceID {
            let domain = entry.key
            var lease = entry.value
            switch command.kind {
            case .heartbeat:
                lease.session.expiresAt = now().timeIntervalSince1970 + Self.leaseDuration
                leases[domain] = lease
                output = result(.ok, "Session renewed.", sessionID: lease.session.id, snapshot: snapshot())
            case .leave:
                leases.removeValue(forKey: domain)
                output = result(.ok, "Editing session released.", snapshot: snapshot())
            case .colour:
                if domain != .colour {
                    output = result(.unauthorized, "This session does not own the Colour workspace.")
                } else if let clip = current.clips.first(where: { $0.id == command.targetID }) {
                    if !clip.editable {
                        output = result(.busy, "This clip cannot be edited remotely while the host is editing it.")
                    } else if clip.revision != command.expectedRevision {
                        output = result(.conflict, "The host changed this clip grade. Refresh before applying.")
                    } else if clip.values == command.colour! {
                        output = result(.ok, "Grade is already current.", sessionID: lease.session.id)
                    } else if applyColour(clip.id, command.colour!) {
                        let applied = snapshot()
                        let persisted = applied.projectID == current.projectID
                            && applied.clips.first(where: { $0.id == clip.id })?.values == command.colour
                        output = result(persisted ? .ok : .failed,
                            persisted ? "Colour applied on the host." : "The host could not persist this grade.",
                            sessionID: lease.session.id, snapshot: applied)
                    } else {
                        output = result(.failed, "The host has an active draft or could not apply this grade.", snapshot: snapshot())
                    }
                } else {
                    output = result(.unavailable, "That clip no longer exists.")
                }
            case .transform:
                if domain != .scene {
                    output = result(.unauthorized, "This session does not own the 3D workspace.")
                } else if let scene = current.scenes.first(where: { $0.id == command.sceneID }),
                          let object = scene.objects.first(where: { $0.id == command.targetID }) {
                    if !object.editable {
                        output = result(.busy, "This object cannot be edited remotely while the host is editing it.")
                    } else if object.revision != command.expectedRevision {
                        output = result(.conflict, "The host changed this object's transform. Refresh before applying.")
                    } else if object.transform == command.transform! {
                        output = result(.ok, "Transform is already current.", sessionID: lease.session.id)
                    } else if applyTransform(scene.id, object.id, command.transform!) {
                        let applied = snapshot()
                        let persisted = applied.projectID == current.projectID
                            && applied.scenes.first(where: { $0.id == scene.id })?
                                .objects.first(where: { $0.id == object.id })?.transform == command.transform
                        output = result(persisted ? .ok : .failed,
                            persisted ? "Object transform applied on the host." : "The host could not persist this transform.",
                            sessionID: lease.session.id, snapshot: applied)
                    } else {
                        output = result(.failed, "The host has an active draft or could not apply this transform.", snapshot: snapshot())
                    }
                } else {
                    output = result(.unavailable, "That scene object no longer exists.")
                }
            case .addObject:
                if domain != .scene {
                    output = result(.unauthorized, "This session does not own the 3D workspace.")
                } else if let scene = current.scenes.first(where: { $0.id == command.sceneID }) {
                    if !scene.editable {
                        output = result(.busy, "This scene cannot be edited remotely while the host is editing it.")
                    } else if scene.revision != command.expectedRevision {
                        output = result(.conflict, "The host changed this scene's objects. Refresh before adding.")
                    } else if scene.objects.count >= Self.maximumSceneObjects {
                        output = result(.invalid, "Remote scenes are limited to \(Self.maximumSceneObjects) objects.")
                    } else if scene.objects.contains(where: { $0.id == command.targetID }) {
                        output = result(.conflict, "That object ID already exists. Refresh before adding.")
                    } else if let applyAddObject, applyAddObject(scene.id, command.targetID!, command.objectKind!) {
                        let applied = snapshot()
                        let persisted = applied.projectID == current.projectID
                            && applied.scenes.first(where: { $0.id == scene.id })?
                                .objects.first(where: { $0.id == command.targetID })?.kind == command.objectKind
                        output = result(persisted ? .ok : .failed,
                            persisted ? "Primitive added on the host." : "The host could not persist this primitive.",
                            sessionID: lease.session.id, snapshot: applied)
                    } else {
                        output = result(.failed, "The host could not add this primitive.", snapshot: snapshot())
                    }
                } else {
                    output = result(.unavailable, "That scene no longer exists.")
                }
            case .deleteObject:
                if domain != .scene {
                    output = result(.unauthorized, "This session does not own the 3D workspace.")
                } else if let scene = current.scenes.first(where: { $0.id == command.sceneID }),
                          let object = scene.objects.first(where: { $0.id == command.targetID }) {
                    if !object.editable {
                        output = result(.busy, "This object cannot be deleted remotely while the host is editing it.")
                    } else if object.revision != command.expectedRevision {
                        output = result(.conflict, "The host changed this object. Refresh before deleting.")
                    } else if let applyDeleteObject, applyDeleteObject(scene.id, object.id) {
                        let applied = snapshot()
                        let persisted = applied.projectID == current.projectID
                            && applied.scenes.first(where: { $0.id == scene.id })
                                .map { !$0.objects.contains(where: { $0.id == object.id }) } == true
                        output = result(persisted ? .ok : .failed,
                            persisted ? "Object deleted on the host." : "The host could not delete this object.",
                            sessionID: lease.session.id, snapshot: applied)
                    } else {
                        output = result(.failed, "The host could not delete this object.", snapshot: snapshot())
                    }
                } else {
                    output = result(.unavailable, "That scene object no longer exists.")
                }
            case .join:
                output = result(.invalid, "Malformed session request.")
            }
        } else {
            output = result(.unauthorized, "The editing session expired or belongs to another device. Join again.")
        }
        receipts[key] = Receipt(command: command, status: output.status,
                                message: output.message, sessionID: output.sessionID)
        receiptOrder.append(key)
        if receiptOrder.count > 256 { receipts.removeValue(forKey: receiptOrder.removeFirst()) }
        return output
    }

    private func expireLeases() {
        let timestamp = now().timeIntervalSince1970
        leases = leases.filter { $0.value.session.expiresAt > timestamp }
    }

    private func isValidShape(_ command: ShareCollaborationCommand) -> Bool {
        switch command.kind {
        case .join:
            return command.projectID != nil && command.domain != nil && command.sessionID == nil
                && command.targetID == nil && command.sceneID == nil && command.expectedRevision == nil
                && command.colour == nil && command.transform == nil && command.objectKind == nil
        case .heartbeat, .leave:
            return command.sessionID != nil && command.domain == nil && command.targetID == nil
                && command.sceneID == nil && command.expectedRevision == nil && command.colour == nil
                && command.transform == nil && command.objectKind == nil
        case .colour:
            return command.projectID != nil && command.sessionID != nil && command.domain == nil
                && command.targetID != nil && command.sceneID == nil && validRevision(command.expectedRevision)
                && command.colour?.isValid == true && command.transform == nil && command.objectKind == nil
        case .transform:
            return command.projectID != nil && command.sessionID != nil && command.domain == nil
                && command.targetID != nil && command.sceneID != nil && validRevision(command.expectedRevision)
                && command.transform?.isValid == true && command.colour == nil && command.objectKind == nil
        case .addObject:
            return command.projectID != nil && command.sessionID != nil && command.domain == nil
                && command.targetID != nil && command.sceneID != nil && validRevision(command.expectedRevision)
                && command.objectKind.map { Self.primitiveKinds.contains($0) } == true
                && command.transform == nil && command.colour == nil
        case .deleteObject:
            return command.projectID != nil && command.sessionID != nil && command.domain == nil
                && command.targetID != nil && command.sceneID != nil && validRevision(command.expectedRevision)
                && command.objectKind == nil && command.transform == nil && command.colour == nil
        }
    }

    private func validRevision(_ value: Int?) -> Bool {
        guard let value else { return false }
        return (1...Self.maximumRevision).contains(value)
    }

    private func update<Key: Hashable, Value: Equatable>(value: Value, editable: Bool, key: Key,
        in revisions: inout [Key: Revision<Value>]) -> Int {
        var revision = revisions[key] ?? Revision(value: value, editable: editable, number: 1)
        if revision.value != value || revision.editable != editable {
            revision.number = min(Self.maximumRevision, revision.number + 1)
            revision.value = value
            revision.editable = editable
        }
        revisions[key] = revision
        return revision.number
    }

    private func tombstoneMissing<Key: Hashable, Value: Equatable>(_ seen: Set<Key>,
        in revisions: inout [Key: Revision<Value>]) {
        for key in Array(revisions.keys) where !seen.contains(key) {
            guard var revision = revisions[key], revision.value != nil else { continue }
            revision.value = nil
            revision.editable = false
            revision.number = min(Self.maximumRevision, revision.number + 1)
            revisions[key] = revision
        }
    }

    private static func duplicates(_ ids: [UUID]) -> Set<UUID> {
        var seen = Set<UUID>(), duplicates = Set<UUID>()
        for id in ids where !seen.insert(id).inserted { duplicates.insert(id) }
        return duplicates
    }

    private static func displayName(_ value: String, maximum: Int = 256) -> String {
        let printable = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(printable)).prefix(maximum).description
    }

    private static func duration(_ value: Double) -> Double {
        value.isFinite ? min(31_536_000, max(0, value)) : 0
    }
}
