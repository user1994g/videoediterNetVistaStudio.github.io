import Cocoa
import SceneKit
import SceneKit.ModelIO
import ModelIO
import SpriteKit
import AVFoundation
import UniformTypeIdentifiers
import CoreVideo

// MARK: - Public integration surface

/// A movie produced by the 3D Scene Editor. NetVista Studio can import `url` into
/// its Media Pool and timeline in exactly the same way as a camera clip.
public struct SceneRenderedClip {
    public let url: URL
    public let suggestedName: String
    public let duration: Double
    public let pixelSize: CGSize

    public init(url: URL, suggestedName: String, duration: Double, pixelSize: CGSize) {
        self.url = url
        self.suggestedName = suggestedName
        self.duration = duration
        self.pixelSize = pixelSize
    }
}

public struct SceneVector3: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    fileprivate var scn: SCNVector3 { SCNVector3(x, y, z) }
    fileprivate init(_ value: SCNVector3) { self.init(x: Double(value.x), y: Double(value.y), z: Double(value.z)) }
}

public struct SceneRGBA: Codable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    fileprivate init(_ color: NSColor) {
        let converted = color.usingColorSpace(.deviceRGB) ?? .white
        self.init(red: Double(converted.redComponent), green: Double(converted.greenComponent), blue: Double(converted.blueComponent), alpha: Double(converted.alphaComponent))
    }

    fileprivate var color: NSColor {
        NSColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

public enum SceneKeyframeInterpolation: String, Codable, CaseIterable {
    case hold
    case linear
    case easeInOut
}

public struct SceneTransform: Codable, Equatable {
    public var position: SceneVector3
    public var rotation: SceneVector3
    public var scale: SceneVector3

    public init(
        position: SceneVector3 = .init(),
        rotation: SceneVector3 = .init(),
        scale: SceneVector3 = .init(x: 1, y: 1, z: 1)
    ) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
    }
}

public struct SceneTransformKeyframe: Codable, Equatable, Identifiable {
    public var id: UUID
    public var time: Double
    public var transform: SceneTransform
    public var interpolation: SceneKeyframeInterpolation

    public init(
        id: UUID = UUID(),
        time: Double,
        transform: SceneTransform,
        interpolation: SceneKeyframeInterpolation = .easeInOut
    ) {
        self.id = id
        self.time = time
        self.transform = transform
        self.interpolation = interpolation
    }
}

public struct SceneCameraKeyframe: Codable, Equatable, Identifiable {
    public var id: UUID
    public var time: Double
    public var position: SceneVector3
    public var target: SceneVector3
    public var interpolation: SceneKeyframeInterpolation

    public init(
        id: UUID = UUID(),
        time: Double,
        position: SceneVector3,
        target: SceneVector3,
        interpolation: SceneKeyframeInterpolation = .easeInOut
    ) {
        self.id = id
        self.time = time
        self.position = position
        self.target = target
        self.interpolation = interpolation
    }
}

/// A pose track targets one bone that already exists in an imported skinned
/// model. NetVista Studio deliberately preserves the model's skin weights and
/// skeleton instead of pretending it can automatically rig an arbitrary mesh.
public struct SceneBonePoseKeyframe: Codable, Equatable, Identifiable {
    public var id: UUID
    public var time: Double
    public var rotation: SceneVector3
    public var interpolation: SceneKeyframeInterpolation

    public init(
        id: UUID = UUID(),
        time: Double,
        rotation: SceneVector3,
        interpolation: SceneKeyframeInterpolation = .easeInOut
    ) {
        self.id = id
        self.time = time
        self.rotation = rotation
        self.interpolation = interpolation
    }
}

public struct SceneBonePoseTrack: Codable, Equatable, Identifiable {
    public var id: UUID
    /// Child-index path relative to the imported model's editable root.
    public var bonePath: String
    /// Human-readable fallback for assets whose hierarchy changed slightly.
    public var boneName: String
    public var baseRotation: SceneVector3
    public var keyframes: [SceneBonePoseKeyframe]

    public init(
        id: UUID = UUID(),
        bonePath: String,
        boneName: String,
        baseRotation: SceneVector3,
        keyframes: [SceneBonePoseKeyframe] = []
    ) {
        self.id = id
        self.bonePath = bonePath
        self.boneName = boneName
        self.baseRotation = baseRotation
        self.keyframes = keyframes
    }
}

public enum ScenePhysicsMode: String, Codable, CaseIterable {
    case off
    case `static`
    case dynamic
    case kinematic

    fileprivate var displayName: String {
        switch self {
        case .off: return "Off"
        case .static: return "Static"
        case .dynamic: return "Dynamic"
        case .kinematic: return "Kinematic"
        }
    }
}

public struct ScenePhysicsSettings: Codable, Equatable {
    public var mode: ScenePhysicsMode = .off
    public var mass: Double = 1
    public var affectedByGravity: Bool = true
    public var restitution: Double = 0.15
    public var friction: Double = 0.6

    public init(
        mode: ScenePhysicsMode = .off,
        mass: Double = 1,
        affectedByGravity: Bool = true,
        restitution: Double = 0.15,
        friction: Double = 0.6
    ) {
        self.mode = mode
        self.mass = mass
        self.affectedByGravity = affectedByGravity
        self.restitution = restitution
        self.friction = friction
    }

    private enum CodingKeys: String, CodingKey { case mode, mass, affectedByGravity, restitution, friction }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(ScenePhysicsMode.self, forKey: .mode) ?? .off
        mass = try c.decodeIfPresent(Double.self, forKey: .mass) ?? 1
        affectedByGravity = try c.decodeIfPresent(Bool.self, forKey: .affectedByGravity) ?? true
        restitution = try c.decodeIfPresent(Double.self, forKey: .restitution) ?? 0.15
        friction = try c.decodeIfPresent(Double.self, forKey: .friction) ?? 0.6
    }
}

public enum SceneEnvironmentPreset: String, Codable, CaseIterable {
    case studio
    case daylight
    case sunset
    case night

    fileprivate var displayName: String { rawValue.capitalized }
}

public enum SceneMapPreset: String, Codable, CaseIterable {
    case studioStage
    case cityBlock
    case landscape
    case arena

    fileprivate var displayName: String {
        switch self {
        case .studioStage: return "Studio Stage"
        case .cityBlock: return "City Block"
        case .landscape: return "Landscape"
        case .arena: return "Arena"
        }
    }
}

/// Procedural map settings are small, deterministic, and portable. The map is
/// rebuilt from these values in both the live viewport and offline renderer.
public struct SceneMapSettings: Codable, Equatable {
    public var enabled: Bool = false
    public var preset: SceneMapPreset = .studioStage
    public var size: Double = 20
    public var detail: Int = 8
    public var seed: UInt64 = 1

    public init(
        enabled: Bool = false,
        preset: SceneMapPreset = .studioStage,
        size: Double = 20,
        detail: Int = 8,
        seed: UInt64 = 1
    ) {
        self.enabled = enabled
        self.preset = preset
        self.size = size
        self.detail = detail
        self.seed = seed
    }

    private enum CodingKeys: String, CodingKey { case enabled, preset, size, detail, seed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        preset = try c.decodeIfPresent(SceneMapPreset.self, forKey: .preset) ?? .studioStage
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 20
        detail = try c.decodeIfPresent(Int.self, forKey: .detail) ?? 8
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? 1
    }
}

public enum SceneObjectKind: String, Codable, CaseIterable {
    case cube
    case sphere
    case cylinder
    case plane
    case mediaPlane
    case model

    fileprivate var displayName: String {
        switch self {
        case .cube: return "Cube"
        case .sphere: return "Sphere"
        case .cylinder: return "Cylinder"
        case .plane: return "Plane"
        case .mediaPlane: return "Video Plane"
        case .model: return "Imported Model"
        }
    }
}

public struct SceneChromaKey: Codable, Equatable {
    public var enabled: Bool = false
    public var color = SceneRGBA(red: 0.05, green: 0.95, blue: 0.10)
    public var threshold: Double = 0.25
    public var softness: Double = 0.12
    public var choke: Double = 0
    public var spillSuppression: Double = 0.35

    public init(enabled: Bool = false, color: SceneRGBA = SceneRGBA(red: 0.05, green: 0.95, blue: 0.10), threshold: Double = 0.25, softness: Double = 0.12, choke: Double = 0, spillSuppression: Double = 0.35) {
        self.enabled = enabled
        self.color = color
        self.threshold = threshold
        self.softness = softness
        self.choke = choke
        self.spillSuppression = spillSuppression
    }

    private enum CodingKeys: String, CodingKey { case enabled, color, threshold, softness, choke, spillSuppression }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        color = try c.decodeIfPresent(SceneRGBA.self, forKey: .color) ?? SceneRGBA(red: 0.05, green: 0.95, blue: 0.10)
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.25
        softness = try c.decodeIfPresent(Double.self, forKey: .softness) ?? 0.12
        choke = try c.decodeIfPresent(Double.self, forKey: .choke) ?? 0
        spillSuppression = try c.decodeIfPresent(Double.self, forKey: .spillSuppression) ?? 0.35
    }
}

public struct SceneObjectRecord: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: SceneObjectKind
    public var position: SceneVector3
    /// Euler angles in degrees, which makes hand-editing scene files practical.
    public var rotation: SceneVector3
    public var scale: SceneVector3
    public var color: SceneRGBA
    public var mediaURL: URL?
    /// Absolute reference to the user's original 3D asset. NetVista Studio
    /// never copies, changes, or deletes this file when a scene is saved.
    public var modelURL: URL?
    public var mediaAspectRatio: Double
    public var chromaKey: SceneChromaKey
    public var transformKeyframes: [SceneTransformKeyframe]
    public var bonePoseTracks: [SceneBonePoseTrack]
    public var physics: ScenePhysicsSettings

    public init(
        id: UUID = UUID(),
        name: String,
        kind: SceneObjectKind,
        position: SceneVector3 = .init(),
        rotation: SceneVector3 = .init(),
        scale: SceneVector3 = .init(x: 1, y: 1, z: 1),
        color: SceneRGBA = .init(red: 0.22, green: 0.58, blue: 0.95),
        mediaURL: URL? = nil,
        modelURL: URL? = nil,
        mediaAspectRatio: Double = 16.0 / 9.0,
        chromaKey: SceneChromaKey = .init(),
        transformKeyframes: [SceneTransformKeyframe] = [],
        bonePoseTracks: [SceneBonePoseTrack] = [],
        physics: ScenePhysicsSettings = .init()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.position = position
        self.rotation = rotation
        self.scale = scale
        self.color = color
        self.mediaURL = mediaURL
        self.modelURL = modelURL
        self.mediaAspectRatio = mediaAspectRatio
        self.chromaKey = chromaKey
        self.transformKeyframes = transformKeyframes
        self.bonePoseTracks = bonePoseTracks
        self.physics = physics
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, position, rotation, scale, color, mediaURL, modelURL
        case mediaAspectRatio, chromaKey, transformKeyframes, bonePoseTracks, physics
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Scene Object"
        kind = try c.decodeIfPresent(SceneObjectKind.self, forKey: .kind) ?? .cube
        position = try c.decodeIfPresent(SceneVector3.self, forKey: .position) ?? .init()
        rotation = try c.decodeIfPresent(SceneVector3.self, forKey: .rotation) ?? .init()
        scale = try c.decodeIfPresent(SceneVector3.self, forKey: .scale) ?? .init(x: 1, y: 1, z: 1)
        color = try c.decodeIfPresent(SceneRGBA.self, forKey: .color) ?? .init(red: 0.22, green: 0.58, blue: 0.95)
        mediaURL = try c.decodeIfPresent(URL.self, forKey: .mediaURL)
        modelURL = try c.decodeIfPresent(URL.self, forKey: .modelURL)
        mediaAspectRatio = try c.decodeIfPresent(Double.self, forKey: .mediaAspectRatio) ?? 16.0 / 9.0
        chromaKey = try c.decodeIfPresent(SceneChromaKey.self, forKey: .chromaKey) ?? .init()
        transformKeyframes = try c.decodeIfPresent([SceneTransformKeyframe].self, forKey: .transformKeyframes) ?? []
        bonePoseTracks = try c.decodeIfPresent([SceneBonePoseTrack].self, forKey: .bonePoseTracks) ?? []
        physics = try c.decodeIfPresent(ScenePhysicsSettings.self, forKey: .physics) ?? .init()
    }
}

public struct NetVistaSceneDocument: Codable, Equatable {
    public var formatVersion: Int = 2
    /// Stable identity when the document belongs to a NetVista Studio project.
    /// Optional keeps older standalone scene files compatible.
    public var projectSceneID: UUID?
    public var title: String = "Untitled 3D Scene"
    public var duration: Double = 5
    public var framesPerSecond: Int = 30
    public var canvasWidth: Int = 1920
    public var canvasHeight: Int = 1080
    public var backgroundColor = SceneRGBA(red: 0.025, green: 0.032, blue: 0.045)
    public var ambientLightIntensity: Double = 420
    public var keyLightIntensity: Double = 1_200
    public var exposure: Double = 0
    public var cameraPosition = SceneVector3(x: 0, y: 2.4, z: 7.2)
    public var cameraTarget = SceneVector3(x: 0, y: 0.4, z: 0)
    public var cameraKeyframes: [SceneCameraKeyframe] = []
    public var environmentPreset: SceneEnvironmentPreset = .studio
    public var mapSettings: SceneMapSettings = .init()
    public var physicsGravity = SceneVector3(x: 0, y: -9.8, z: 0)
    public var objects: [SceneObjectRecord] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case formatVersion, projectSceneID, title, duration, framesPerSecond, canvasWidth, canvasHeight
        case backgroundColor, ambientLightIntensity, keyLightIntensity, exposure
        case cameraPosition, cameraTarget, cameraKeyframes, environmentPreset, mapSettings, physicsGravity, objects
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        projectSceneID = try c.decodeIfPresent(UUID.self, forKey: .projectSceneID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled 3D Scene"
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 5
        framesPerSecond = try c.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? 30
        canvasWidth = try c.decodeIfPresent(Int.self, forKey: .canvasWidth) ?? 1920
        canvasHeight = try c.decodeIfPresent(Int.self, forKey: .canvasHeight) ?? 1080
        backgroundColor = try c.decodeIfPresent(SceneRGBA.self, forKey: .backgroundColor) ?? SceneRGBA(red: 0.025, green: 0.032, blue: 0.045)
        ambientLightIntensity = try c.decodeIfPresent(Double.self, forKey: .ambientLightIntensity) ?? 420
        keyLightIntensity = try c.decodeIfPresent(Double.self, forKey: .keyLightIntensity) ?? 1_200
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        cameraPosition = try c.decodeIfPresent(SceneVector3.self, forKey: .cameraPosition) ?? SceneVector3(x: 0, y: 2.4, z: 7.2)
        cameraTarget = try c.decodeIfPresent(SceneVector3.self, forKey: .cameraTarget) ?? SceneVector3(x: 0, y: 0.4, z: 0)
        cameraKeyframes = try c.decodeIfPresent([SceneCameraKeyframe].self, forKey: .cameraKeyframes) ?? []
        environmentPreset = try c.decodeIfPresent(SceneEnvironmentPreset.self, forKey: .environmentPreset) ?? .studio
        mapSettings = try c.decodeIfPresent(SceneMapSettings.self, forKey: .mapSettings) ?? .init()
        physicsGravity = try c.decodeIfPresent(SceneVector3.self, forKey: .physicsGravity) ?? SceneVector3(x: 0, y: -9.8, z: 0)
        objects = try c.decodeIfPresent([SceneObjectRecord].self, forKey: .objects) ?? []
    }
}

/// Native AppKit + SceneKit editor.  It is suitable as a page controller or as
/// the content view controller of a separate resizable window.
public final class SceneEditorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public var onRenderedClip: ((SceneRenderedClip) -> Void)?
    public private(set) var document = NetVistaSceneDocument()
    public private(set) var documentURL: URL?

    private let sceneView = SceneViewportView(frame: .zero)
    private let outliner = NSTableView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let renderProgress = NSProgressIndicator(frame: .zero)
    private let durationField = NSTextField(string: "5.0")
    private let resolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField(string: "")
    private let colorWell = NSColorWell(frame: .zero)
    private let chromaEnabled = NSButton(checkboxWithTitle: "Remove green screen", target: nil, action: nil)
    private let chromaColorWell = NSColorWell(frame: .zero)
    private let chromaThreshold = NSSlider(value: 0.25, minValue: 0.02, maxValue: 0.8, target: nil, action: nil)
    private let chromaSoftness = NSSlider(value: 0.12, minValue: 0.01, maxValue: 0.5, target: nil, action: nil)
    private let chromaChoke = NSSlider(value: 0, minValue: 0, maxValue: 0.8, target: nil, action: nil)
    private let chromaSpill = NSSlider(value: 0.35, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let physicsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let physicsMass = NSTextField(string: "1")
    private let physicsGravity = NSButton(checkboxWithTitle: "Affected by gravity", target: nil, action: nil)
    private let physicsRestitution = NSSlider(value: 0.15, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let physicsFriction = NSSlider(value: 0.6, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let bonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let boneRotationX = NSTextField(string: "0")
    private let boneRotationY = NSTextField(string: "0")
    private let boneRotationZ = NSTextField(string: "0")
    private let ambientSlider = NSSlider(value: 420, minValue: 0, maxValue: 2_000, target: nil, action: nil)
    private let keySlider = NSSlider(value: 1_200, minValue: 0, maxValue: 4_000, target: nil, action: nil)
    private let exposureSlider = NSSlider(value: 0, minValue: -4, maxValue: 4, target: nil, action: nil)
    private let environmentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mapEnabled = NSButton(checkboxWithTitle: "Build procedural map", target: nil, action: nil)
    private let mapPresetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mapSizeSlider = NSSlider(value: 20, minValue: 8, maxValue: 80, target: nil, action: nil)
    private let mapDetailSlider = NSSlider(value: 8, minValue: 3, maxValue: 24, target: nil, action: nil)
    private let mapSeedField = NSTextField(string: "1")
    private let sceneTimeline = SceneTimelineControl(frame: .zero)
    private let scenePlayButton = NSButton(title: "Play", target: nil, action: nil)
    private let sceneTimeLabel = NSTextField(labelWithString: "00:00.000 / 00:05.000")
    private let keyInterpolationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keySummaryLabel = NSTextField(labelWithString: "No keyframes")
    private var transformFields: [TransformField: NSTextField] = [:]
    private var selectedObjectID: UUID?
    private var selectedBonePath: String?
    private var rigBones: [RigBoneReference] = []
    private var objectNodes: [UUID: SCNNode] = [:]
    private var players: [UUID: AVQueuePlayer] = [:]
    private var playerLoopers: [UUID: AVPlayerLooper] = [:]
    private var scene: SCNScene = SCNScene()
    private var cameraNode = SCNNode()
    private var ambientNode = SCNNode()
    private var keyLightNode = SCNNode()
    private var isRendering = false
    private var scenePlayTimer: Timer?
    private var currentSceneTime: Double = 0
    private var isScenePlaying = false

    public convenience init(onRenderedClip: ((SceneRenderedClip) -> Void)?) {
        self.init(nibName: nil, bundle: nil)
        self.onRenderedClip = onRenderedClip
    }

    public convenience init(document: NetVistaSceneDocument, onRenderedClip: ((SceneRenderedClip) -> Void)? = nil) {
        self.init(nibName: nil, bundle: nil)
        self.onRenderedClip = onRenderedClip
        _ = view
        replaceDocument(document)
    }

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1320, height: 820))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.065, alpha: 1).cgColor
        buildInterface()
        createNewScene(nil)
    }

    deinit {
        scenePlayTimer?.invalidate()
        players.values.forEach { $0.pause() }
    }

    // MARK: Public document and render API

    public func replaceDocument(_ newDocument: NetVistaSceneDocument, sourceURL: URL? = nil) {
        if !isViewLoaded { _ = view }
        document = newDocument
        document.formatVersion = 2
        documentURL = sourceURL
        selectedObjectID = document.objects.first?.id
        currentSceneTime = 0
        stopScenePlayback(resetButton: true)
        rebuildRuntimeScene()
        refreshControlsFromDocument()
    }

    /// Captures camera movement and inspector edits before the parent project
    /// is saved, even when the user has not rendered the scene again yet.
    public func snapshotDocument() -> NetVistaSceneDocument {
        if !isViewLoaded { _ = view }
        syncDocumentFromScene()
        document.formatVersion = 2
        return document
    }

    public func saveScene(to url: URL) throws {
        if !isViewLoaded { _ = view }
        syncDocumentFromScene()
        let filenameTitle = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filenameTitle.isEmpty { document.title = filenameTitle }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
        documentURL = url
        setStatus("Saved editable 3D work: \(url.lastPathComponent) — no video rendered")
    }

    public func loadScene(from url: URL) throws {
        if !isViewLoaded { _ = view }
        var loaded = try JSONDecoder().decode(NetVistaSceneDocument.self, from: Data(contentsOf: url))
        guard (1...2).contains(loaded.formatVersion) else {
            throw SceneEditorError.unsupportedDocumentVersion(loaded.formatVersion)
        }
        loaded.formatVersion = 2
        document = loaded
        documentURL = url
        selectedObjectID = nil
        selectedBonePath = nil
        currentSceneTime = 0
        stopScenePlayback(resetButton: true)
        rebuildRuntimeScene()
        refreshControlsFromDocument()
        let missingModels = document.objects.filter {
            $0.kind == .model && objectNodes[$0.id]?.value(forKey: "netVistaMissingModel") != nil
        }
        if missingModels.isEmpty {
            setStatus("Opened \(url.lastPathComponent)")
        } else {
            setStatus("Opened \(url.lastPathComponent) — \(missingModels.count) model file(s) need reconnecting")
        }
    }

    public func renderScene(
        to outputURL: URL,
        completion: @escaping (Result<SceneRenderedClip, Error>) -> Void
    ) {
        if !isViewLoaded { _ = view }
        guard !isRendering else {
            completion(.failure(SceneEditorError.renderAlreadyRunning))
            return
        }
        syncDocumentFromScene()
        let snapshot = document
        isRendering = true
        renderProgress.doubleValue = 0
        renderProgress.isHidden = false
        setStatus("Rendering 3D scene…")

        SceneMovieRenderer.render(document: snapshot, to: outputURL, progress: { [weak self] fraction in
            DispatchQueue.main.async {
                self?.renderProgress.doubleValue = fraction * 100
                self?.setStatus("Rendering 3D scene — \(Int(fraction * 100))%")
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRendering = false
                self.renderProgress.isHidden = true
                switch result {
                case .success:
                    let clip = SceneRenderedClip(
                        url: outputURL,
                        suggestedName: snapshot.title,
                        duration: snapshot.duration,
                        pixelSize: CGSize(width: snapshot.canvasWidth, height: snapshot.canvasHeight)
                    )
                    self.setStatus("Rendered \(outputURL.lastPathComponent)")
                    self.onRenderedClip?(clip)
                    completion(.success(clip))
                case .failure(let error):
                    self.setStatus("Render failed: \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }
        })
    }

    // MARK: Interface

    private func buildInterface() {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        root.addArrangedSubview(makeToolbar())

        let content = NSStackView()
        content.orientation = .horizontal
        content.alignment = .height
        content.spacing = 1
        content.translatesAutoresizingMaskIntoConstraints = false
        let outlinerPanel = makeOutlinerPanel()
        let viewportPanel = makeViewportPanel()
        let inspectorPanel = makeInspectorPanel()
        outlinerPanel.widthAnchor.constraint(equalToConstant: 220).isActive = true
        inspectorPanel.widthAnchor.constraint(equalToConstant: 292).isActive = true
        viewportPanel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        viewportPanel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(outlinerPanel)
        content.addArrangedSubview(viewportPanel)
        content.addArrangedSubview(inspectorPanel)
        root.addArrangedSubview(content)

        root.addArrangedSubview(makeSceneTimelinePanel())

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        renderProgress.isIndeterminate = false
        renderProgress.minValue = 0
        renderProgress.maxValue = 100
        renderProgress.isHidden = true
        renderProgress.widthAnchor.constraint(equalToConstant: 180).isActive = true
        footer.addArrangedSubview(statusLabel)
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(renderProgress)
        footer.heightAnchor.constraint(equalToConstant: 34).isActive = true
        root.addArrangedSubview(footer)

    }

    private func makeToolbar() -> NSView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 7
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1).cgColor

        let title = NSTextField(labelWithString: "3D SCENE EDITOR")
        title.font = .systemFont(ofSize: 12, weight: .bold)
        title.textColor = .secondaryLabelColor
        bar.addArrangedSubview(title)
        bar.addArrangedSubview(separator())
        bar.addArrangedSubview(toolbarButton("New", #selector(createNewScene(_:))))
        bar.addArrangedSubview(toolbarButton("Open", #selector(openScenePanel(_:))))
        let saveWork = toolbarButton("Save 3D Work…", #selector(saveScenePanel(_:)))
        saveWork.toolTip = "Save an editable 3D scene without rendering a video"
        saveWork.contentTintColor = .systemGreen
        bar.addArrangedSubview(saveWork)
        bar.addArrangedSubview(separator())
        bar.addArrangedSubview(toolbarButton("＋ Cube", #selector(addCube(_:))))
        bar.addArrangedSubview(toolbarButton("＋ Sphere", #selector(addSphere(_:))))
        bar.addArrangedSubview(toolbarButton("＋ Cylinder", #selector(addCylinder(_:))))
        bar.addArrangedSubview(toolbarButton("＋ Plane", #selector(addPlane(_:))))
        let media = toolbarButton("＋ Video Plane", #selector(importVideoPlane(_:)))
        media.contentTintColor = .systemTeal
        bar.addArrangedSubview(media)
        let model = toolbarButton("＋ Import Model…", #selector(importModel(_:)))
        model.toolTip = "Add an OBJ, USD/USDZ, DAE, SCN, PLY, STL, or ABC model to this editable scene"
        model.contentTintColor = .systemOrange
        bar.addArrangedSubview(model)
        bar.addArrangedSubview(NSView())
        bar.addArrangedSubview(toolbarButton("Reset Camera", #selector(resetCamera(_:))))
        let render = toolbarButton("Render Clip…", #selector(renderPanel(_:)))
        render.contentTintColor = .systemBlue
        bar.addArrangedSubview(render)
        bar.heightAnchor.constraint(equalToConstant: 50).isActive = true
        return bar
    }

    private func makeOutlinerPanel() -> NSView {
        let panel = NSStackView()
        panel.orientation = .vertical
        panel.spacing = 8
        panel.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 10, right: 10)
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1).cgColor

        let label = sectionLabel("SCENE OBJECTS")
        panel.addArrangedSubview(label)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("object"))
        column.title = "Objects"
        outliner.addTableColumn(column)
        outliner.headerView = nil
        outliner.backgroundColor = .clear
        outliner.rowSizeStyle = .medium
        outliner.selectionHighlightStyle = .sourceList
        outliner.delegate = self
        outliner.dataSource = self
        scroll.documentView = outliner
        panel.addArrangedSubview(scroll)

        let delete = toolbarButton("Delete Selected", #selector(deleteSelected(_:)))
        delete.contentTintColor = .systemRed
        panel.addArrangedSubview(delete)
        return panel
    }

    private func makeViewportPanel() -> NSView {
        let holder = NSView()
        holder.wantsLayer = true
        holder.layer?.backgroundColor = NSColor.black.cgColor
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.backgroundColor = .black
        sceneView.antialiasingMode = .multisampling4X
        sceneView.allowsCameraControl = true
        sceneView.rendersContinuously = true
        sceneView.preferredFramesPerSecond = 60
        sceneView.onNodePicked = { [weak self] node in self?.selectRuntimeNode(node) }
        sceneView.onMediaDropped = { [weak self] url in self?.addMediaPlane(url: url) }
        sceneView.onModelDropped = { [weak self] url in self?.addImportedModel(url: url) }
        holder.addSubview(sceneView)
        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: holder.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: holder.bottomAnchor)
        ])

        let help = NSTextField(labelWithString: "Drag to orbit  •  Two-finger drag to pan  •  Scroll to zoom  •  Drop a movie or 3D model to add it")
        help.textColor = NSColor.white.withAlphaComponent(0.7)
        help.font = .systemFont(ofSize: 11, weight: .medium)
        help.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(help)
        NSLayoutConstraint.activate([
            help.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14),
            help.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -12)
        ])
        return holder
    }

    private func makeInspectorPanel() -> NSView {
        let documentView = NSStackView()
        documentView.orientation = .vertical
        documentView.alignment = .width
        documentView.spacing = 10
        documentView.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 18, right: 12)
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1).cgColor

        documentView.addArrangedSubview(sectionLabel("OBJECT INSPECTOR"))
        nameField.placeholderString = "Select an object"
        nameField.target = self
        nameField.action = #selector(applyObjectInspector(_:))
        documentView.addArrangedSubview(labeledRow("Name", nameField))

        documentView.addArrangedSubview(subsectionLabel("Transform"))
        for group in [("Position", [TransformField.positionX, .positionY, .positionZ]), ("Rotation", [.rotationX, .rotationY, .rotationZ]), ("Scale", [.scaleX, .scaleY, .scaleZ])] {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 5
            let label = NSTextField(labelWithString: group.0)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 10)
            label.widthAnchor.constraint(equalToConstant: 48).isActive = true
            row.addArrangedSubview(label)
            for key in group.1 {
                let field = NSTextField(string: key.defaultText)
                field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                field.alignment = .right
                field.target = self
                field.action = #selector(applyObjectInspector(_:))
                field.toolTip = key.toolTip
                transformFields[key] = field
                row.addArrangedSubview(field)
            }
            documentView.addArrangedSubview(row)
        }

        colorWell.color = NSColor(calibratedRed: 0.22, green: 0.58, blue: 0.95, alpha: 1)
        colorWell.target = self
        colorWell.action = #selector(applyObjectInspector(_:))
        documentView.addArrangedSubview(labeledRow("Material", colorWell))

        documentView.addArrangedSubview(subsectionLabel("Green Screen"))
        chromaEnabled.target = self
        chromaEnabled.action = #selector(applyObjectInspector(_:))
        documentView.addArrangedSubview(chromaEnabled)
        chromaColorWell.color = .systemGreen
        chromaColorWell.target = self
        chromaColorWell.action = #selector(applyObjectInspector(_:))
        documentView.addArrangedSubview(labeledRow("Key colour", chromaColorWell))
        configureSlider(chromaThreshold, action: #selector(applyObjectInspector(_:)))
        configureSlider(chromaSoftness, action: #selector(applyObjectInspector(_:)))
        configureSlider(chromaChoke, action: #selector(applyObjectInspector(_:)))
        configureSlider(chromaSpill, action: #selector(applyObjectInspector(_:)))
        documentView.addArrangedSubview(labeledRow("Threshold", chromaThreshold))
        documentView.addArrangedSubview(labeledRow("Softness", chromaSoftness))
        documentView.addArrangedSubview(labeledRow("Choke", chromaChoke))
        documentView.addArrangedSubview(labeledRow("Spill", chromaSpill))

        documentView.addArrangedSubview(subsectionLabel("Physics"))
        physicsPopup.addItems(withTitles: ScenePhysicsMode.allCases.map(\.displayName))
        physicsPopup.target = self
        physicsPopup.action = #selector(applyObjectInspector(_:))
        documentView.addArrangedSubview(labeledRow("Body", physicsPopup))
        physicsMass.alignment = .right
        physicsMass.target = self
        physicsMass.action = #selector(applyObjectInspector(_:))
        documentView.addArrangedSubview(labeledRow("Mass", physicsMass))
        physicsGravity.target = self
        physicsGravity.action = #selector(applyObjectInspector(_:))
        documentView.addArrangedSubview(physicsGravity)
        configureSlider(physicsRestitution, action: #selector(applyObjectInspector(_:)))
        configureSlider(physicsFriction, action: #selector(applyObjectInspector(_:)))
        documentView.addArrangedSubview(labeledRow("Bounce", physicsRestitution))
        documentView.addArrangedSubview(labeledRow("Friction", physicsFriction))

        documentView.addArrangedSubview(subsectionLabel("Rig Pose · Imported Rigs"))
        bonePopup.target = self
        bonePopup.action = #selector(selectBone(_:))
        documentView.addArrangedSubview(labeledRow("Bone", bonePopup))
        let poseRow = NSStackView()
        poseRow.orientation = .horizontal
        poseRow.spacing = 5
        let poseLabel = NSTextField(labelWithString: "Rotation")
        poseLabel.textColor = .secondaryLabelColor
        poseLabel.font = .systemFont(ofSize: 10)
        poseLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        poseRow.addArrangedSubview(poseLabel)
        for (field, tip) in [(boneRotationX, "Bone X rotation"), (boneRotationY, "Bone Y rotation"), (boneRotationZ, "Bone Z rotation")] {
            field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            field.alignment = .right
            field.target = self
            field.action = #selector(applyBonePose(_:))
            field.toolTip = tip
            poseRow.addArrangedSubview(field)
        }
        documentView.addArrangedSubview(poseRow)

        documentView.addArrangedSubview(separator(horizontal: true))
        documentView.addArrangedSubview(sectionLabel("SCENE & LIGHTING"))
        environmentPopup.addItems(withTitles: SceneEnvironmentPreset.allCases.map(\.displayName))
        environmentPopup.target = self
        environmentPopup.action = #selector(applyEnvironment(_:))
        documentView.addArrangedSubview(labeledRow("Look", environmentPopup))
        configureSlider(ambientSlider, action: #selector(applyEnvironment(_:)))
        configureSlider(keySlider, action: #selector(applyEnvironment(_:)))
        configureSlider(exposureSlider, action: #selector(applyEnvironment(_:)))
        documentView.addArrangedSubview(labeledRow("Ambient", ambientSlider))
        documentView.addArrangedSubview(labeledRow("Key light", keySlider))
        documentView.addArrangedSubview(labeledRow("Exposure", exposureSlider))

        documentView.addArrangedSubview(subsectionLabel("Map Builder"))
        mapEnabled.target = self
        mapEnabled.action = #selector(rebuildMap(_:))
        documentView.addArrangedSubview(mapEnabled)
        mapPresetPopup.addItems(withTitles: SceneMapPreset.allCases.map(\.displayName))
        mapPresetPopup.target = self
        mapPresetPopup.action = #selector(rebuildMap(_:))
        documentView.addArrangedSubview(labeledRow("Preset", mapPresetPopup))
        configureSlider(mapSizeSlider, action: #selector(rebuildMap(_:)))
        configureSlider(mapDetailSlider, action: #selector(rebuildMap(_:)))
        documentView.addArrangedSubview(labeledRow("Map size", mapSizeSlider))
        documentView.addArrangedSubview(labeledRow("Detail", mapDetailSlider))
        mapSeedField.alignment = .right
        mapSeedField.target = self
        mapSeedField.action = #selector(rebuildMap(_:))
        documentView.addArrangedSubview(labeledRow("Seed", mapSeedField))

        documentView.addArrangedSubview(subsectionLabel("Render Settings"))
        durationField.alignment = .right
        durationField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        documentView.addArrangedSubview(labeledRow("Duration", durationField))
        resolutionPopup.addItems(withTitles: ["Preview · 1280 × 720", "HD · 1920 × 1080", "4K · 3840 × 2160"])
        resolutionPopup.selectItem(at: 1)
        documentView.addArrangedSubview(labeledRow("Resolution", resolutionPopup))
        documentView.addArrangedSubview(NSView())

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = documentView
        documentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }

    private func makeSceneTimelinePanel() -> NSView {
        let panel = NSStackView()
        panel.orientation = .horizontal
        panel.alignment = .centerY
        panel.spacing = 8
        panel.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.095, alpha: 1).cgColor

        scenePlayButton.target = self
        scenePlayButton.action = #selector(toggleScenePlayback(_:))
        scenePlayButton.bezelStyle = .texturedRounded
        panel.addArrangedSubview(scenePlayButton)

        let cameraKey = toolbarButton("◆ Camera Key", #selector(addCameraKeyframe(_:)))
        cameraKey.toolTip = "Store the current camera position and target at the playhead"
        panel.addArrangedSubview(cameraKey)
        let objectKey = toolbarButton("◆ Object Key", #selector(addObjectKeyframe(_:)))
        objectKey.toolTip = "Store the selected object's transform at the playhead"
        panel.addArrangedSubview(objectKey)
        let poseKey = toolbarButton("◆ Bone Key", #selector(addBoneKeyframe(_:)))
        poseKey.toolTip = "Store the selected bone pose at the playhead"
        panel.addArrangedSubview(poseKey)
        let remove = toolbarButton("Remove Key", #selector(removeKeyframeAtPlayhead(_:)))
        remove.contentTintColor = .systemRed
        panel.addArrangedSubview(remove)

        keyInterpolationPopup.addItems(withTitles: ["Hold", "Linear", "Ease In/Out"])
        keyInterpolationPopup.selectItem(at: 2)
        panel.addArrangedSubview(keyInterpolationPopup)

        sceneTimeline.translatesAutoresizingMaskIntoConstraints = false
        sceneTimeline.heightAnchor.constraint(equalToConstant: 42).isActive = true
        sceneTimeline.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        sceneTimeline.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sceneTimeline.onScrub = { [weak self] time in self?.setSceneTime(time, userInitiated: true) }
        panel.addArrangedSubview(sceneTimeline)

        sceneTimeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        sceneTimeLabel.alignment = .right
        sceneTimeLabel.widthAnchor.constraint(equalToConstant: 142).isActive = true
        panel.addArrangedSubview(sceneTimeLabel)
        keySummaryLabel.textColor = .secondaryLabelColor
        keySummaryLabel.font = .systemFont(ofSize: 10)
        keySummaryLabel.lineBreakMode = .byTruncatingTail
        keySummaryLabel.widthAnchor.constraint(equalToConstant: 112).isActive = true
        panel.addArrangedSubview(keySummaryLabel)
        panel.heightAnchor.constraint(equalToConstant: 58).isActive = true
        return panel
    }

    // MARK: Scene construction

    @objc private func createNewScene(_ sender: Any?) {
        stopScenePlayback(resetButton: true)
        document = NetVistaSceneDocument()
        document.objects = [
            SceneObjectRecord(name: "Hero Cube", kind: .cube, position: SceneVector3(x: 0, y: 0.5, z: 0))
        ]
        documentURL = nil
        selectedObjectID = document.objects.first?.id
        currentSceneTime = 0
        rebuildRuntimeScene()
        refreshControlsFromDocument()
        setStatus("New 3D scene")
    }

    private func rebuildRuntimeScene() {
        players.values.forEach { $0.pause() }
        players.removeAll()
        playerLoopers.removeAll()
        objectNodes.removeAll()

        scene = SCNScene()
        SceneEnvironment.apply(document.environmentPreset, document: document, to: scene)
        scene.physicsWorld.gravity = document.physicsGravity.scn
        scene.physicsWorld.timeStep = 1.0 / Double(max(1, document.framesPerSecond))

        let floor = SCNFloor()
        floor.reflectivity = 0.18
        floor.reflectionFalloffEnd = 12
        floor.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.12, alpha: 1)
        floor.firstMaterial?.roughness.contents = 0.7
        let floorNode = SCNNode(geometry: floor)
        floorNode.name = "__floor"
        floorNode.physicsBody = .static()
        scene.rootNode.addChildNode(floorNode)

        let grid = GridGeometry.makeNode()
        scene.rootNode.addChildNode(grid)

        if document.mapSettings.enabled {
            scene.rootNode.addChildNode(SceneMapFactory.makeNode(settings: document.mapSettings))
        }

        cameraNode = SCNNode()
        cameraNode.name = "__camera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 48
        cameraNode.camera?.wantsHDR = true
        cameraNode.camera?.exposureOffset = document.exposure
        cameraNode.camera?.zNear = 0.05
        cameraNode.camera?.zFar = 1_000
        cameraNode.position = document.cameraPosition.scn
        cameraNode.look(at: document.cameraTarget.scn)
        scene.rootNode.addChildNode(cameraNode)

        ambientNode = SCNNode()
        ambientNode.name = "__ambient"
        ambientNode.light = SCNLight()
        ambientNode.light?.type = .ambient
        ambientNode.light?.color = NSColor(calibratedWhite: 0.78, alpha: 1)
        ambientNode.light?.intensity = document.ambientLightIntensity
        scene.rootNode.addChildNode(ambientNode)

        keyLightNode = SCNNode()
        keyLightNode.name = "__key"
        keyLightNode.light = SCNLight()
        keyLightNode.light?.type = .omni
        keyLightNode.light?.color = NSColor(calibratedRed: 1, green: 0.92, blue: 0.80, alpha: 1)
        keyLightNode.light?.intensity = document.keyLightIntensity
        keyLightNode.light?.castsShadow = true
        keyLightNode.light?.shadowRadius = 8
        keyLightNode.light?.shadowSampleCount = 16
        keyLightNode.position = SCNVector3(3.5, 5.5, 4.5)
        scene.rootNode.addChildNode(keyLightNode)

        let rim = SCNNode()
        rim.name = "__rim"
        rim.light = SCNLight()
        rim.light?.type = .omni
        rim.light?.color = NSColor(calibratedRed: 0.32, green: 0.52, blue: 1, alpha: 1)
        rim.light?.intensity = 650
        rim.position = SCNVector3(-4, 2.5, -3)
        scene.rootNode.addChildNode(rim)

        for record in document.objects {
            let node = makeNode(for: record, liveVideo: true)
            scene.rootNode.addChildNode(node)
            objectNodes[record.id] = node
        }
        sceneView.scene = scene
        sceneView.pointOfView = cameraNode
        outliner.reloadData()
        restoreOutlinerSelection()
        refreshObjectInspector()
        setSceneTime(currentSceneTime, userInitiated: false)
    }

    private func makeNode(for record: SceneObjectRecord, liveVideo: Bool) -> SCNNode {
        let node = SceneNodeFactory.node(for: record)
        node.setValue(record.id.uuidString, forKey: "netVistaSceneObjectID")
        if record.kind == .mediaPlane,
           let material = node.geometry?.firstMaterial,
           let url = record.mediaURL,
           liveVideo {
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer(playerItem: item)
            player.isMuted = true
            let looper = AVPlayerLooper(player: player, templateItem: item)
            let videoNode = SKVideoNode(avPlayer: player)
            let spriteScene = SKScene(size: CGSize(width: 1_920, height: 1_080))
            spriteScene.backgroundColor = .clear
            spriteScene.scaleMode = .aspectFit
            videoNode.position = CGPoint(x: 960, y: 540)
            videoNode.size = CGSize(width: 1_920, height: 1_080)
            videoNode.yScale = -1
            spriteScene.addChild(videoNode)
            material.diffuse.contents = spriteScene
            applyChroma(record.chromaKey, to: material)
            players[record.id] = player
            playerLoopers[record.id] = looper
            player.play()
            videoNode.play()
        }
        ScenePhysicsFactory.apply(record.physics, to: node)
        return node
    }

    private func applyChroma(_ chroma: SceneChromaKey, to material: SCNMaterial) {
        material.blendMode = chroma.enabled ? .alpha : .replace
        material.transparencyMode = .dualLayer
        material.shaderModifiers = [.surface: ChromaShader.source]
        material.setValue(chroma.enabled ? 1.0 : 0.0, forKey: "chromaEnabled")
        material.setValue(chroma.threshold, forKey: "chromaThreshold")
        material.setValue(chroma.softness, forKey: "chromaSoftness")
        material.setValue(chroma.choke, forKey: "chromaChoke")
        material.setValue(chroma.spillSuppression, forKey: "chromaSpill")
        material.setValue(NSValue(scnVector3: SCNVector3(chroma.color.red, chroma.color.green, chroma.color.blue)), forKey: "chromaColor")
    }

    private func syncDocumentFromScene() {
        document.duration = min(120, max(0.25, durationField.doubleValue))
        switch resolutionPopup.indexOfSelectedItem {
        case 0: document.canvasWidth = 1280; document.canvasHeight = 720
        case 2: document.canvasWidth = 3840; document.canvasHeight = 2160
        default: document.canvasWidth = 1920; document.canvasHeight = 1080
        }
        document.ambientLightIntensity = ambientSlider.doubleValue
        document.keyLightIntensity = keySlider.doubleValue
        document.exposure = exposureSlider.doubleValue
        if !isScenePlaying && currentSceneTime <= (1.0 / 120.0) {
            document.cameraPosition = SceneVector3(cameraNode.position)
            if let pointOfView = sceneView.pointOfView {
            let presentedCamera = pointOfView.presentation
            let worldPosition = presentedCamera.worldPosition
            let worldFront = presentedCamera.worldFront
            let oldPosition = document.cameraPosition
            let oldTarget = document.cameraTarget
            let dx = oldTarget.x - oldPosition.x
            let dy = oldTarget.y - oldPosition.y
            let dz = oldTarget.z - oldPosition.z
            let targetDistance = max(0.25, sqrt(dx * dx + dy * dy + dz * dz))
            document.cameraPosition = SceneVector3(worldPosition)
            document.cameraTarget = SceneVector3(
                x: Double(worldPosition.x) + Double(worldFront.x) * targetDistance,
                y: Double(worldPosition.y) + Double(worldFront.y) * targetDistance,
                z: Double(worldPosition.z) + Double(worldFront.z) * targetDistance
            )
            } else {
                document.cameraPosition = SceneVector3(cameraNode.position)
            }
        }
        for index in document.objects.indices {
            guard let node = objectNodes[document.objects[index].id] else { continue }
            if document.objects[index].transformKeyframes.isEmpty || currentSceneTime <= (1.0 / 120.0) {
                document.objects[index].position = SceneVector3(node.position)
                document.objects[index].rotation = SceneVector3(
                    x: Double(node.eulerAngles.x) * 180 / .pi,
                    y: Double(node.eulerAngles.y) * 180 / .pi,
                    z: Double(node.eulerAngles.z) * 180 / .pi
                )
                document.objects[index].scale = SceneVector3(node.scale)
            }
        }
    }

    // MARK: Object operations and inspector

    @objc private func addCube(_ sender: Any?) { addPrimitive(.cube) }
    @objc private func addSphere(_ sender: Any?) { addPrimitive(.sphere) }
    @objc private func addCylinder(_ sender: Any?) { addPrimitive(.cylinder) }
    @objc private func addPlane(_ sender: Any?) { addPrimitive(.plane) }

    private func addPrimitive(_ kind: SceneObjectKind) {
        let count = document.objects.filter { $0.kind == kind }.count + 1
        let record = SceneObjectRecord(
            name: "\(kind.displayName) \(count)",
            kind: kind,
            position: SceneVector3(x: Double(count - 1) * 0.35, y: kind == .plane ? 0.02 : 0.5, z: 0),
            rotation: kind == .plane ? SceneVector3(x: -90, y: 0, z: 0) : SceneVector3(),
            color: paletteColor(at: document.objects.count)
        )
        document.objects.append(record)
        let node = makeNode(for: record, liveVideo: true)
        scene.rootNode.addChildNode(node)
        objectNodes[record.id] = node
        selectedObjectID = record.id
        outliner.reloadData()
        restoreOutlinerSelection()
        refreshObjectInspector()
        setStatus("Added \(record.name)")
    }

    @objc private func importVideoPlane(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Add Video Plane"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addMediaPlane(url: url)
    }

    private func addMediaPlane(url: URL) {
        let asset = AVURLAsset(url: url)
        let track = asset.tracks(withMediaType: .video).first
        let size = track?.naturalSize ?? CGSize(width: 16, height: 9)
        let ratio = max(0.1, Double(abs(size.width) / max(1, abs(size.height))))
        let count = document.objects.filter { $0.kind == .mediaPlane }.count + 1
        let record = SceneObjectRecord(
            name: url.deletingPathExtension().lastPathComponent,
            kind: .mediaPlane,
            position: SceneVector3(x: 0, y: 1.55, z: -0.5 - Double(count - 1) * 0.2),
            scale: SceneVector3(x: min(2.5, ratio), y: 1, z: 1),
            color: .init(red: 1, green: 1, blue: 1),
            mediaURL: url,
            mediaAspectRatio: ratio
        )
        document.objects.append(record)
        let node = makeNode(for: record, liveVideo: true)
        scene.rootNode.addChildNode(node)
        objectNodes[record.id] = node
        selectedObjectID = record.id
        outliner.reloadData()
        restoreOutlinerSelection()
        refreshObjectInspector()
        setStatus("Added video plane: \(url.lastPathComponent)")
    }

    @objc private func importModel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Import 3D Model"
        panel.message = "Choose an OBJ or another SceneKit-compatible model. The scene keeps a reference to your original file."
        panel.allowedContentTypes = ImportedModelLoader.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addImportedModel(url: url) }
    }

    private func addImportedModel(url: URL) {
        do {
            let importedNode = try ImportedModelLoader.loadNormalizedNode(from: url)
            let record = SceneObjectRecord(
                name: url.deletingPathExtension().lastPathComponent,
                kind: .model,
                position: SceneVector3(x: 0, y: 0, z: 0),
                color: .init(red: 1, green: 1, blue: 1),
                modelURL: url.standardizedFileURL
            )
            document.objects.append(record)
            let node = SceneNodeFactory.node(for: record, importedModel: importedNode)
            node.setValue(record.id.uuidString, forKey: "netVistaSceneObjectID")
            scene.rootNode.addChildNode(node)
            objectNodes[record.id] = node
            selectedObjectID = record.id
            outliner.reloadData()
            restoreOutlinerSelection()
            refreshObjectInspector()
            setStatus("Imported editable model: \(url.lastPathComponent)")
        } catch {
            setStatus("Could not import \(url.lastPathComponent): \(error.localizedDescription)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could Not Import Model"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func deleteSelected(_ sender: Any?) {
        guard let id = selectedObjectID, let index = document.objects.firstIndex(where: { $0.id == id }) else { return }
        let name = document.objects[index].name
        players[id]?.pause()
        players[id] = nil
        playerLoopers[id] = nil
        objectNodes[id]?.removeFromParentNode()
        objectNodes[id] = nil
        document.objects.remove(at: index)
        selectedObjectID = document.objects.first?.id
        outliner.reloadData()
        restoreOutlinerSelection()
        refreshObjectInspector()
        setStatus("Deleted \(name)")
    }

    @objc private func applyObjectInspector(_ sender: Any?) {
        guard let id = selectedObjectID,
              let index = document.objects.firstIndex(where: { $0.id == id }),
              let node = objectNodes[id] else { return }
        var record = document.objects[index]
        if !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record.name = nameField.stringValue
            node.name = record.name
        }
        record.position = vector(from: [.positionX, .positionY, .positionZ])
        record.rotation = vector(from: [.rotationX, .rotationY, .rotationZ])
        record.scale = vector(from: [.scaleX, .scaleY, .scaleZ], minimumMagnitude: 0.01)
        record.color = SceneRGBA(colorWell.color)
        record.chromaKey.enabled = chromaEnabled.state == .on
        record.chromaKey.color = SceneRGBA(chromaColorWell.color)
        record.chromaKey.threshold = chromaThreshold.doubleValue
        record.chromaKey.softness = chromaSoftness.doubleValue
        record.chromaKey.choke = chromaChoke.doubleValue
        record.chromaKey.spillSuppression = chromaSpill.doubleValue
        record.physics.mode = ScenePhysicsMode.allCases[safe: physicsPopup.indexOfSelectedItem] ?? .off
        record.physics.mass = min(10_000, max(0.001, physicsMass.doubleValue))
        record.physics.affectedByGravity = physicsGravity.state == .on
        record.physics.restitution = physicsRestitution.doubleValue
        record.physics.friction = physicsFriction.doubleValue
        document.objects[index] = record

        node.position = record.position.scn
        node.eulerAngles = SCNVector3(record.rotation.x * .pi / 180, record.rotation.y * .pi / 180, record.rotation.z * .pi / 180)
        node.scale = record.scale.scn
        ScenePhysicsFactory.apply(record.physics, to: node)
        if record.kind == .mediaPlane {
            if let material = node.geometry?.firstMaterial { applyChroma(record.chromaKey, to: material) }
        } else if record.kind == .model {
            SceneNodeFactory.applyMaterialTint(record.color.color, to: node)
        } else {
            node.geometry?.firstMaterial?.diffuse.contents = record.color.color
        }
        outliner.reloadData()
    }

    @objc private func applyEnvironment(_ sender: Any?) {
        document.environmentPreset = SceneEnvironmentPreset.allCases[safe: environmentPopup.indexOfSelectedItem] ?? .studio
        document.ambientLightIntensity = ambientSlider.doubleValue
        document.keyLightIntensity = keySlider.doubleValue
        document.exposure = exposureSlider.doubleValue
        ambientNode.light?.intensity = document.ambientLightIntensity
        keyLightNode.light?.intensity = document.keyLightIntensity
        cameraNode.camera?.exposureOffset = document.exposure
        SceneEnvironment.apply(document.environmentPreset, document: document, to: scene)
    }

    private func refreshObjectInspector() {
        guard let id = selectedObjectID, let record = document.objects.first(where: { $0.id == id }) else {
            nameField.stringValue = ""
            setInspectorEnabled(false)
            return
        }
        setInspectorEnabled(true)
        nameField.stringValue = record.name
        let displayed = objectNodes[record.id].map { node in
            SceneTransform(
                position: SceneVector3(node.position),
                rotation: SceneVector3(
                    x: Double(node.eulerAngles.x) * 180 / .pi,
                    y: Double(node.eulerAngles.y) * 180 / .pi,
                    z: Double(node.eulerAngles.z) * 180 / .pi
                ),
                scale: SceneVector3(node.scale)
            )
        } ?? SceneTransform(position: record.position, rotation: record.rotation, scale: record.scale)
        setVector(displayed.position, keys: [.positionX, .positionY, .positionZ])
        setVector(displayed.rotation, keys: [.rotationX, .rotationY, .rotationZ])
        setVector(displayed.scale, keys: [.scaleX, .scaleY, .scaleZ])
        colorWell.color = record.color.color
        chromaEnabled.state = record.chromaKey.enabled ? .on : .off
        chromaColorWell.color = record.chromaKey.color.color
        chromaThreshold.doubleValue = record.chromaKey.threshold
        chromaSoftness.doubleValue = record.chromaKey.softness
        chromaChoke.doubleValue = record.chromaKey.choke
        chromaSpill.doubleValue = record.chromaKey.spillSuppression
        physicsPopup.selectItem(at: ScenePhysicsMode.allCases.firstIndex(of: record.physics.mode) ?? 0)
        physicsMass.doubleValue = record.physics.mass
        physicsGravity.state = record.physics.affectedByGravity ? .on : .off
        physicsRestitution.doubleValue = record.physics.restitution
        physicsFriction.doubleValue = record.physics.friction
        let isMedia = record.kind == .mediaPlane
        chromaEnabled.isEnabled = isMedia
        chromaColorWell.isEnabled = isMedia
        chromaThreshold.isEnabled = isMedia
        chromaSoftness.isEnabled = isMedia
        chromaChoke.isEnabled = isMedia
        chromaSpill.isEnabled = isMedia
        refreshRigBones(record: record)
        refreshTimelineSummary()
    }

    private func refreshControlsFromDocument() {
        durationField.doubleValue = document.duration
        if document.canvasWidth >= 3_840 { resolutionPopup.selectItem(at: 2) }
        else if document.canvasWidth >= 1_920 { resolutionPopup.selectItem(at: 1) }
        else { resolutionPopup.selectItem(at: 0) }
        ambientSlider.doubleValue = document.ambientLightIntensity
        keySlider.doubleValue = document.keyLightIntensity
        exposureSlider.doubleValue = document.exposure
        environmentPopup.selectItem(at: SceneEnvironmentPreset.allCases.firstIndex(of: document.environmentPreset) ?? 0)
        mapEnabled.state = document.mapSettings.enabled ? .on : .off
        mapPresetPopup.selectItem(at: SceneMapPreset.allCases.firstIndex(of: document.mapSettings.preset) ?? 0)
        mapSizeSlider.doubleValue = document.mapSettings.size
        mapDetailSlider.integerValue = document.mapSettings.detail
        mapSeedField.stringValue = String(document.mapSettings.seed)
        sceneTimeline.duration = document.duration
        sceneTimeline.playhead = min(document.duration, currentSceneTime)
        refreshObjectInspector()
    }

    private func setInspectorEnabled(_ enabled: Bool) {
        nameField.isEnabled = enabled
        colorWell.isEnabled = enabled
        transformFields.values.forEach { $0.isEnabled = enabled }
        chromaEnabled.isEnabled = false
        chromaColorWell.isEnabled = false
        chromaThreshold.isEnabled = false
        chromaSoftness.isEnabled = false
        chromaChoke.isEnabled = false
        chromaSpill.isEnabled = false
        physicsPopup.isEnabled = enabled
        physicsMass.isEnabled = enabled
        physicsGravity.isEnabled = enabled
        physicsRestitution.isEnabled = enabled
        physicsFriction.isEnabled = enabled
        bonePopup.isEnabled = false
        boneRotationX.isEnabled = false
        boneRotationY.isEnabled = false
        boneRotationZ.isEnabled = false
    }

    // MARK: Scene animation, rig posing, physics and maps

    private var selectedInterpolation: SceneKeyframeInterpolation {
        switch keyInterpolationPopup.indexOfSelectedItem {
        case 0: return .hold
        case 1: return .linear
        default: return .easeInOut
        }
    }

    private func setSceneTime(_ requested: Double, userInitiated: Bool) {
        if userInitiated { stopScenePlayback(resetButton: true) }
        let duration = max(0.25, durationField.doubleValue > 0 ? durationField.doubleValue : document.duration)
        currentSceneTime = min(duration, max(0, requested))
        sceneTimeline.duration = duration
        sceneTimeline.playhead = currentSceneTime
        SceneAnimationEvaluator.apply(
            document: document,
            time: currentSceneTime,
            objectNodes: objectNodes,
            camera: cameraNode
        )
        if userInitiated || !isScenePlaying { seekSceneMedia(to: currentSceneTime) }
        sceneTimeLabel.stringValue = "\(sceneTimeText(currentSceneTime)) / \(sceneTimeText(duration))"
        refreshAnimatedInspectorValues()
        refreshTimelineSummary()
    }

    private func seekSceneMedia(to time: Double) {
        for player in players.values {
            player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if isScenePlaying { player.play() } else { player.pause() }
        }
    }

    private func sceneTimeText(_ seconds: Double) -> String {
        let safe = max(0, seconds)
        return String(format: "%02d:%06.3f", Int(safe) / 60, safe.truncatingRemainder(dividingBy: 60))
    }

    @objc private func toggleScenePlayback(_ sender: Any?) {
        if isScenePlaying {
            stopScenePlayback(resetButton: true)
            return
        }
        if currentSceneTime >= document.duration - (1.0 / 120.0) { currentSceneTime = 0 }
        isScenePlaying = true
        scenePlayButton.title = "Pause"
        players.values.forEach { $0.play() }
        let interval = 1.0 / Double(min(60, max(24, document.framesPerSecond)))
        scenePlayTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let next = self.currentSceneTime + interval
            if next >= self.document.duration {
                self.setSceneTime(self.document.duration, userInitiated: false)
                self.stopScenePlayback(resetButton: true)
            } else {
                self.setSceneTime(next, userInitiated: false)
            }
        }
    }

    private func stopScenePlayback(resetButton: Bool) {
        scenePlayTimer?.invalidate()
        scenePlayTimer = nil
        isScenePlaying = false
        players.values.forEach { $0.pause() }
        if resetButton { scenePlayButton.title = "Play" }
    }

    @objc private func addObjectKeyframe(_ sender: Any?) {
        guard let id = selectedObjectID,
              let index = document.objects.firstIndex(where: { $0.id == id }),
              let node = objectNodes[id] else {
            setStatus("Select an object before adding an object keyframe.")
            return
        }
        let transform = SceneTransform(
            position: SceneVector3(node.presentation.position),
            rotation: SceneVector3(
                x: Double(node.presentation.eulerAngles.x) * 180 / .pi,
                y: Double(node.presentation.eulerAngles.y) * 180 / .pi,
                z: Double(node.presentation.eulerAngles.z) * 180 / .pi
            ),
            scale: SceneVector3(node.presentation.scale)
        )
        upsertTransformKeyframe(&document.objects[index].transformKeyframes, transform: transform)
        setStatus("Object transform keyframe added at \(sceneTimeText(currentSceneTime)).")
        setSceneTime(currentSceneTime, userInitiated: false)
    }

    @objc private func addCameraKeyframe(_ sender: Any?) {
        let point = sceneView.pointOfView?.presentation ?? cameraNode.presentation
        let position = SceneVector3(point.worldPosition)
        let front = point.worldFront
        let distance = max(0.25, vectorDistance(document.cameraPosition, document.cameraTarget))
        let target = SceneVector3(
            x: position.x + Double(front.x) * distance,
            y: position.y + Double(front.y) * distance,
            z: position.z + Double(front.z) * distance
        )
        if let index = document.cameraKeyframes.firstIndex(where: { abs($0.time - currentSceneTime) < 1.0 / 120.0 }) {
            document.cameraKeyframes[index].position = position
            document.cameraKeyframes[index].target = target
            document.cameraKeyframes[index].interpolation = selectedInterpolation
        } else {
            document.cameraKeyframes.append(SceneCameraKeyframe(time: currentSceneTime, position: position, target: target, interpolation: selectedInterpolation))
        }
        document.cameraKeyframes.sort { $0.time < $1.time }
        setStatus("Camera keyframe added at \(sceneTimeText(currentSceneTime)).")
        setSceneTime(currentSceneTime, userInitiated: false)
    }

    @objc private func addBoneKeyframe(_ sender: Any?) {
        guard let id = selectedObjectID,
              let objectIndex = document.objects.firstIndex(where: { $0.id == id }),
              let path = selectedBonePath,
              let bone = rigBones.first(where: { $0.path == path }) else {
            setStatus("Select a bone in an imported rig before adding a pose keyframe.")
            return
        }
        let rotation = SceneVector3(
            x: Double(bone.node.eulerAngles.x) * 180 / .pi,
            y: Double(bone.node.eulerAngles.y) * 180 / .pi,
            z: Double(bone.node.eulerAngles.z) * 180 / .pi
        )
        let trackIndex: Int
        if let existing = document.objects[objectIndex].bonePoseTracks.firstIndex(where: { $0.bonePath == path }) {
            trackIndex = existing
        } else {
            let track = SceneBonePoseTrack(bonePath: path, boneName: bone.name, baseRotation: bone.baseRotation)
            document.objects[objectIndex].bonePoseTracks.append(track)
            trackIndex = document.objects[objectIndex].bonePoseTracks.count - 1
        }
        var keys = document.objects[objectIndex].bonePoseTracks[trackIndex].keyframes
        if let existing = keys.firstIndex(where: { abs($0.time - currentSceneTime) < 1.0 / 120.0 }) {
            keys[existing].rotation = rotation
            keys[existing].interpolation = selectedInterpolation
        } else {
            keys.append(SceneBonePoseKeyframe(time: currentSceneTime, rotation: rotation, interpolation: selectedInterpolation))
        }
        keys.sort { $0.time < $1.time }
        document.objects[objectIndex].bonePoseTracks[trackIndex].keyframes = keys
        setStatus("Bone pose keyframe added for \(bone.name).")
        setSceneTime(currentSceneTime, userInitiated: false)
    }

    private func upsertTransformKeyframe(_ keys: inout [SceneTransformKeyframe], transform: SceneTransform) {
        if let index = keys.firstIndex(where: { abs($0.time - currentSceneTime) < 1.0 / 120.0 }) {
            keys[index].transform = transform
            keys[index].interpolation = selectedInterpolation
        } else {
            keys.append(SceneTransformKeyframe(time: currentSceneTime, transform: transform, interpolation: selectedInterpolation))
        }
        keys.sort { $0.time < $1.time }
    }

    @objc private func removeKeyframeAtPlayhead(_ sender: Any?) {
        var removed = 0
        let tolerance = 1.0 / 120.0
        let oldCameraCount = document.cameraKeyframes.count
        document.cameraKeyframes.removeAll { abs($0.time - currentSceneTime) < tolerance }
        removed += oldCameraCount - document.cameraKeyframes.count
        if let id = selectedObjectID, let index = document.objects.firstIndex(where: { $0.id == id }) {
            let oldObjectCount = document.objects[index].transformKeyframes.count
            document.objects[index].transformKeyframes.removeAll { abs($0.time - currentSceneTime) < tolerance }
            removed += oldObjectCount - document.objects[index].transformKeyframes.count
            if let path = selectedBonePath,
               let track = document.objects[index].bonePoseTracks.firstIndex(where: { $0.bonePath == path }) {
                let oldBoneCount = document.objects[index].bonePoseTracks[track].keyframes.count
                document.objects[index].bonePoseTracks[track].keyframes.removeAll { abs($0.time - currentSceneTime) < tolerance }
                removed += oldBoneCount - document.objects[index].bonePoseTracks[track].keyframes.count
            }
        }
        setStatus(removed == 0 ? "No selected keyframe at the playhead." : "Removed \(removed) keyframe(s).")
        setSceneTime(currentSceneTime, userInitiated: false)
    }

    private func refreshTimelineSummary() {
        var times = document.cameraKeyframes.map(\.time)
        if let id = selectedObjectID, let record = document.objects.first(where: { $0.id == id }) {
            times += record.transformKeyframes.map(\.time)
            if let path = selectedBonePath,
               let track = record.bonePoseTracks.first(where: { $0.bonePath == path }) {
                times += track.keyframes.map(\.time)
            }
        }
        sceneTimeline.keyTimes = times
        keySummaryLabel.stringValue = times.isEmpty ? "No keyframes" : "\(times.count) visible key(s)"
    }

    private func refreshAnimatedInspectorValues() {
        guard let id = selectedObjectID, let node = objectNodes[id] else { return }
        setVector(SceneVector3(node.position), keys: [.positionX, .positionY, .positionZ])
        setVector(SceneVector3(
            x: Double(node.eulerAngles.x) * 180 / .pi,
            y: Double(node.eulerAngles.y) * 180 / .pi,
            z: Double(node.eulerAngles.z) * 180 / .pi
        ), keys: [.rotationX, .rotationY, .rotationZ])
        setVector(SceneVector3(node.scale), keys: [.scaleX, .scaleY, .scaleZ])
        refreshBonePoseFields()
    }

    private func refreshRigBones(record: SceneObjectRecord) {
        bonePopup.removeAllItems()
        rigBones = []
        guard record.kind == .model, let root = objectNodes[record.id] else {
            selectedBonePath = nil
            bonePopup.addItem(withTitle: "No rig selected")
            return
        }
        rigBones = RigInspector.bones(in: root)
        guard !rigBones.isEmpty else {
            selectedBonePath = nil
            bonePopup.addItem(withTitle: "Model has no imported rig")
            bonePopup.isEnabled = false
            return
        }
        bonePopup.addItems(withTitles: rigBones.map(\.name))
        let selectedIndex = selectedBonePath.flatMap { path in rigBones.firstIndex(where: { $0.path == path }) } ?? 0
        bonePopup.selectItem(at: selectedIndex)
        selectedBonePath = rigBones[selectedIndex].path
        bonePopup.isEnabled = true
        boneRotationX.isEnabled = true
        boneRotationY.isEnabled = true
        boneRotationZ.isEnabled = true
        refreshBonePoseFields()
    }

    @objc private func selectBone(_ sender: Any?) {
        guard rigBones.indices.contains(bonePopup.indexOfSelectedItem) else { return }
        selectedBonePath = rigBones[bonePopup.indexOfSelectedItem].path
        refreshBonePoseFields()
        refreshTimelineSummary()
    }

    private func refreshBonePoseFields() {
        guard let path = selectedBonePath, let bone = rigBones.first(where: { $0.path == path }) else { return }
        boneRotationX.doubleValue = Double(bone.node.eulerAngles.x) * 180 / .pi
        boneRotationY.doubleValue = Double(bone.node.eulerAngles.y) * 180 / .pi
        boneRotationZ.doubleValue = Double(bone.node.eulerAngles.z) * 180 / .pi
    }

    @objc private func applyBonePose(_ sender: Any?) {
        guard let path = selectedBonePath, let bone = rigBones.first(where: { $0.path == path }) else { return }
        bone.node.eulerAngles = SCNVector3(
            boneRotationX.doubleValue * .pi / 180,
            boneRotationY.doubleValue * .pi / 180,
            boneRotationZ.doubleValue * .pi / 180
        )
        setStatus("Posed \(bone.name). Add a Bone Key to animate this pose.")
    }

    @objc private func rebuildMap(_ sender: Any?) {
        document.mapSettings.enabled = mapEnabled.state == .on
        document.mapSettings.preset = SceneMapPreset.allCases[safe: mapPresetPopup.indexOfSelectedItem] ?? .studioStage
        document.mapSettings.size = mapSizeSlider.doubleValue
        document.mapSettings.detail = max(3, mapDetailSlider.integerValue)
        document.mapSettings.seed = UInt64(max(0, mapSeedField.integerValue))
        scene.rootNode.childNode(withName: "__map", recursively: false)?.removeFromParentNode()
        if document.mapSettings.enabled {
            scene.rootNode.addChildNode(SceneMapFactory.makeNode(settings: document.mapSettings))
        }
        setStatus(document.mapSettings.enabled ? "Built \(document.mapSettings.preset.displayName) map." : "Procedural map hidden.")
    }

    private func vectorDistance(_ a: SceneVector3, _ b: SceneVector3) -> Double {
        let x = a.x - b.x, y = a.y - b.y, z = a.z - b.z
        return sqrt(x * x + y * y + z * z)
    }

    private func selectRuntimeNode(_ node: SCNNode) {
        var candidate: SCNNode? = node
        while let current = candidate {
            if let text = current.value(forKey: "netVistaSceneObjectID") as? String, let id = UUID(uuidString: text) {
                selectedObjectID = id
                restoreOutlinerSelection()
                refreshObjectInspector()
                setStatus("Selected \(current.name ?? "object")")
                return
            }
            candidate = current.parent
        }
    }

    @objc private func resetCamera(_ sender: Any?) {
        cameraNode.position = document.cameraPosition.scn
        cameraNode.look(at: document.cameraTarget.scn)
        sceneView.pointOfView = cameraNode
        setStatus("Camera reset")
    }

    // MARK: Panels

    @objc private func saveScenePanel(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "Save Editable 3D Work"
        panel.message = "Saves an editable .netvistascene file. This does not render a video."
        panel.nameFieldStringValue = (document.title.isEmpty ? "3D Scene" : document.title) + ".netvistascene"
        panel.allowedContentTypes = [UTType(filenameExtension: "netvistascene")!]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try saveScene(to: url) }
        catch { setStatus("Could not save: \(error.localizedDescription)") }
    }

    @objc private func openScenePanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open 3D Scene"
        panel.allowedContentTypes = [UTType(filenameExtension: "netvistascene")!, UTType(filenameExtension: "swiftscene")!]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try loadScene(from: url) }
        catch { setStatus("Could not open: \(error.localizedDescription)") }
    }

    @objc private func renderPanel(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "Render 3D Scene Clip"
        panel.message = "Renders a video clip. To keep editing the 3D scene, use Save 3D Work instead."
        panel.nameFieldStringValue = (document.title.isEmpty ? "3D Scene" : document.title) + ".mov"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        renderScene(to: url) { _ in }
    }

    // MARK: Outliner

    public func numberOfRows(in tableView: NSTableView) -> Int { document.objects.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard document.objects.indices.contains(row) else { return nil }
        let record = document.objects[row]
        let identifier = NSUserInterfaceItemIdentifier("SceneObjectCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let created = NSTableCellView()
            created.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            created.textField = label
            created.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: created.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: created.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: created.centerYAnchor)
            ])
            return created
        }()
        let icon: String
        switch record.kind { case .cube: icon = "▣"; case .sphere: icon = "●"; case .cylinder: icon = "⬮"; case .plane: icon = "▱"; case .mediaPlane: icon = "▶"; case .model: icon = "◆" }
        cell.textField?.stringValue = "\(icon)  \(record.name)"
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = outliner.selectedRow
        guard document.objects.indices.contains(row) else { return }
        selectedObjectID = document.objects[row].id
        refreshObjectInspector()
        setStatus("Selected \(document.objects[row].name)")
    }

    private func restoreOutlinerSelection() {
        guard let id = selectedObjectID, let index = document.objects.firstIndex(where: { $0.id == id }) else {
            outliner.deselectAll(nil)
            return
        }
        outliner.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        outliner.scrollRowToVisible(index)
    }

    // MARK: Small UI helpers

    private func toolbarButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.font = .systemFont(ofSize: 11, weight: .medium)
        return button
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func subsectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.9)
        return label
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 10)
        label.widthAnchor.constraint(equalToConstant: 66).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        return row
    }

    private func separator(horizontal: Bool = false) -> NSView {
        let line = NSBox()
        line.boxType = .separator
        if horizontal { line.heightAnchor.constraint(equalToConstant: 1).isActive = true }
        else { line.widthAnchor.constraint(equalToConstant: 1).isActive = true }
        return line
    }

    private func configureSlider(_ slider: NSSlider, action: Selector) {
        slider.target = self
        slider.action = action
        slider.isContinuous = true
    }

    private func vector(from keys: [TransformField], minimumMagnitude: Double? = nil) -> SceneVector3 {
        let values = keys.map { key -> Double in
            let value = transformFields[key]?.doubleValue ?? 0
            if let minimumMagnitude, abs(value) < minimumMagnitude { return minimumMagnitude }
            return value
        }
        return SceneVector3(x: values[0], y: values[1], z: values[2])
    }

    private func setVector(_ vector: SceneVector3, keys: [TransformField]) {
        let values = [vector.x, vector.y, vector.z]
        for (index, key) in keys.enumerated() { transformFields[key]?.doubleValue = values[index] }
    }

    private func paletteColor(at index: Int) -> SceneRGBA {
        let colors: [SceneRGBA] = [
            .init(red: 0.22, green: 0.58, blue: 0.95),
            .init(red: 0.94, green: 0.36, blue: 0.31),
            .init(red: 0.24, green: 0.78, blue: 0.56),
            .init(red: 0.72, green: 0.42, blue: 0.94),
            .init(red: 0.96, green: 0.68, blue: 0.20)
        ]
        return colors[index % colors.count]
    }

    private func setStatus(_ text: String) { statusLabel.stringValue = text }
}

/// Convenience window for applications that want the scene workspace to live
/// beside the editor, like NetVista Studio's Color and Effects studios.
public final class SceneEditorWindowController: NSWindowController {
    public let sceneEditor: SceneEditorViewController

    public init(onRenderedClip: ((SceneRenderedClip) -> Void)? = nil) {
        sceneEditor = SceneEditorViewController(onRenderedClip: onRenderedClip)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NetVista Studio — 3D Scene"
        window.minSize = NSSize(width: 1_060, height: 680)
        window.contentViewController = sceneEditor
        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func showSceneEditor() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Viewport and scene helpers

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

private final class SceneTimelineControl: NSControl {
    var duration: Double = 5 { didSet { duration = max(0.25, duration); needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var keyTimes: [Double] = [] { didSet { needsDisplay = true } }
    var onScrub: ((Double) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = bounds.insetBy(dx: 8, dy: 8)
        NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()

        NSColor(calibratedWhite: 0.24, alpha: 1).setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: CGPoint(x: track.minX, y: track.midY))
        baseline.line(to: CGPoint(x: track.maxX, y: track.midY))
        baseline.lineWidth = 1
        baseline.stroke()

        let safeDuration = max(0.25, duration)
        NSColor.systemTeal.setFill()
        for time in Set(keyTimes.map { min(safeDuration, max(0, $0)) }) {
            let x = track.minX + CGFloat(time / safeDuration) * track.width
            let marker = NSBezierPath()
            marker.move(to: CGPoint(x: x, y: track.midY - 6))
            marker.line(to: CGPoint(x: x + 5, y: track.midY))
            marker.line(to: CGPoint(x: x, y: track.midY + 6))
            marker.line(to: CGPoint(x: x - 5, y: track.midY))
            marker.close()
            marker.fill()
        }

        let x = track.minX + CGFloat(min(safeDuration, max(0, playhead)) / safeDuration) * track.width
        NSColor.systemRed.setStroke()
        let head = NSBezierPath()
        head.move(to: CGPoint(x: x, y: track.minY - 2))
        head.line(to: CGPoint(x: x, y: track.maxY + 2))
        head.lineWidth = 2
        head.stroke()
    }

    override func mouseDown(with event: NSEvent) { scrub(event) }
    override func mouseDragged(with event: NSEvent) { scrub(event) }

    private func scrub(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let track = bounds.insetBy(dx: 8, dy: 8)
        let fraction = Double(min(1, max(0, (point.x - track.minX) / max(1, track.width))))
        onScrub?(fraction * duration)
    }
}

private struct RigBoneReference {
    let path: String
    let name: String
    let node: SCNNode
    let baseRotation: SceneVector3
}

private enum RigInspector {
    static func bones(in root: SCNNode) -> [RigBoneReference] {
        var boneNodes: [SCNNode] = []
        var seen = Set<ObjectIdentifier>()
        let inspect: (SCNNode) -> Void = { node in
            guard let skinner = node.skinner else { return }
            for bone in skinner.bones where seen.insert(ObjectIdentifier(bone)).inserted {
                boneNodes.append(bone)
            }
        }
        inspect(root)
        root.enumerateChildNodes { node, _ in inspect(node) }
        return boneNodes.compactMap { bone in
            let display = bone.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let namedFallback = display.flatMap { $0.isEmpty ? nil : "name:\($0)" }
            guard let stablePath = path(from: root, to: bone) ?? namedFallback else { return nil }
            return RigBoneReference(
                path: stablePath,
                name: display?.isEmpty == false ? display! : "Bone \(stablePath)",
                node: bone,
                baseRotation: degrees(bone.eulerAngles)
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func node(at path: String, in root: SCNNode, fallbackName: String?) -> SCNNode? {
        var current = root
        if !path.isEmpty {
            for component in path.split(separator: "/") {
                guard let index = Int(component), current.childNodes.indices.contains(index) else {
                    return fallbackName.flatMap { root.childNode(withName: $0, recursively: true) }
                }
                current = current.childNodes[index]
            }
        }
        return current
    }

    private static func path(from root: SCNNode, to target: SCNNode) -> String? {
        if root === target { return "" }
        var indices: [Int] = []
        var cursor: SCNNode? = target
        while let node = cursor, node !== root {
            guard let parent = node.parent, let index = parent.childNodes.firstIndex(where: { $0 === node }) else { return nil }
            indices.append(index)
            cursor = parent
        }
        guard cursor === root else { return nil }
        return indices.reversed().map(String.init).joined(separator: "/")
    }

    private static func degrees(_ value: SCNVector3) -> SceneVector3 {
        SceneVector3(x: Double(value.x) * 180 / .pi, y: Double(value.y) * 180 / .pi, z: Double(value.z) * 180 / .pi)
    }
}

private enum SceneAnimationEvaluator {
    static func apply(document: NetVistaSceneDocument, time: Double, objectNodes: [UUID: SCNNode], camera: SCNNode) {
        let cameraPose = evaluateCamera(document: document, time: time)
        camera.position = cameraPose.position.scn
        camera.look(at: cameraPose.target.scn)

        for record in document.objects {
            guard let node = objectNodes[record.id] else { continue }
            let authored = !record.transformKeyframes.isEmpty
            if record.physics.mode != .dynamic || authored || time <= (1.0 / 120.0) {
                let transform = evaluateTransform(record: record, time: time)
                node.position = transform.position.scn
                node.eulerAngles = radians(transform.rotation)
                node.scale = transform.scale.scn
                if record.physics.mode == .dynamic && authored { node.physicsBody?.type = .kinematic }
            }
            for track in record.bonePoseTracks {
                guard let bone = RigInspector.node(at: track.bonePath, in: node, fallbackName: track.boneName) else { continue }
                bone.eulerAngles = radians(evaluateBone(track: track, time: time))
            }
        }
    }

    static func evaluateTransform(record: SceneObjectRecord, time: Double) -> SceneTransform {
        let fallback = SceneTransform(position: record.position, rotation: record.rotation, scale: record.scale)
        return interpolate(
            frames: record.transformKeyframes,
            time: time,
            fallback: fallback,
            frameTime: { $0.time },
            interpolation: { $0.interpolation },
            value: { $0.transform },
            lerp: lerpTransform
        )
    }

    static func evaluateCamera(document: NetVistaSceneDocument, time: Double) -> (position: SceneVector3, target: SceneVector3) {
        let fallback = (document.cameraPosition, document.cameraTarget)
        return interpolate(
            frames: document.cameraKeyframes,
            time: time,
            fallback: fallback,
            frameTime: { $0.time },
            interpolation: { $0.interpolation },
            value: { ($0.position, $0.target) },
            lerp: { a, b, amount in (lerpVector(a.0, b.0, amount), lerpVector(a.1, b.1, amount)) }
        )
    }

    static func evaluateBone(track: SceneBonePoseTrack, time: Double) -> SceneVector3 {
        interpolate(
            frames: track.keyframes,
            time: time,
            fallback: track.baseRotation,
            frameTime: { $0.time },
            interpolation: { $0.interpolation },
            value: { $0.rotation },
            lerp: lerpVector
        )
    }

    private static func interpolate<Frame, Value>(
        frames: [Frame],
        time: Double,
        fallback: Value,
        frameTime: (Frame) -> Double,
        interpolation: (Frame) -> SceneKeyframeInterpolation,
        value: (Frame) -> Value,
        lerp: (Value, Value, Double) -> Value
    ) -> Value {
        let sorted = frames.sorted { frameTime($0) < frameTime($1) }
        guard let first = sorted.first else { return fallback }
        if time <= frameTime(first) { return value(first) }
        guard let previous = sorted.last(where: { frameTime($0) <= time }) else { return value(first) }
        guard let next = sorted.first(where: { frameTime($0) > frameTime(previous) }) else { return value(previous) }
        let span = max(0.000_001, frameTime(next) - frameTime(previous))
        var amount = min(1, max(0, (time - frameTime(previous)) / span))
        switch interpolation(previous) {
        case .hold: amount = 0
        case .linear: break
        case .easeInOut: amount = amount * amount * (3 - 2 * amount)
        }
        return lerp(value(previous), value(next), amount)
    }

    private static func lerpTransform(_ a: SceneTransform, _ b: SceneTransform, _ amount: Double) -> SceneTransform {
        SceneTransform(
            position: lerpVector(a.position, b.position, amount),
            rotation: lerpVector(a.rotation, b.rotation, amount),
            scale: lerpVector(a.scale, b.scale, amount)
        )
    }

    private static func lerpVector(_ a: SceneVector3, _ b: SceneVector3, _ amount: Double) -> SceneVector3 {
        SceneVector3(
            x: a.x + (b.x - a.x) * amount,
            y: a.y + (b.y - a.y) * amount,
            z: a.z + (b.z - a.z) * amount
        )
    }

    private static func radians(_ degrees: SceneVector3) -> SCNVector3 {
        SCNVector3(degrees.x * .pi / 180, degrees.y * .pi / 180, degrees.z * .pi / 180)
    }
}

private enum ScenePhysicsFactory {
    static func apply(_ settings: ScenePhysicsSettings, to node: SCNNode) {
        guard settings.mode != .off else { node.physicsBody = nil; return }
        let shape = SCNPhysicsShape(node: node, options: [.type: SCNPhysicsShape.ShapeType.boundingBox])
        let type: SCNPhysicsBodyType
        switch settings.mode {
        case .off: node.physicsBody = nil; return
        case .static: type = .static
        case .dynamic: type = .dynamic
        case .kinematic: type = .kinematic
        }
        let body = SCNPhysicsBody(type: type, shape: shape)
        body.mass = CGFloat(min(10_000, max(0.001, settings.mass)))
        body.isAffectedByGravity = settings.affectedByGravity
        body.restitution = CGFloat(min(1, max(0, settings.restitution)))
        body.friction = CGFloat(min(1, max(0, settings.friction)))
        body.continuousCollisionDetectionThreshold = 0.5
        node.physicsBody = body
    }
}

private enum SceneEnvironment {
    static func apply(_ preset: SceneEnvironmentPreset, document: NetVistaSceneDocument, to scene: SCNScene) {
        let color: NSColor
        switch preset {
        case .studio: color = document.backgroundColor.color
        case .daylight: color = NSColor(calibratedRed: 0.52, green: 0.70, blue: 0.91, alpha: 1)
        case .sunset: color = NSColor(calibratedRed: 0.42, green: 0.16, blue: 0.12, alpha: 1)
        case .night: color = NSColor(calibratedRed: 0.008, green: 0.014, blue: 0.045, alpha: 1)
        }
        scene.background.contents = color
        scene.lightingEnvironment.contents = color
        scene.lightingEnvironment.intensity = preset == .night ? 0.35 : 0.8
    }
}

private enum SceneMapFactory {
    static func makeNode(settings: SceneMapSettings) -> SCNNode {
        let root = SCNNode()
        root.name = "__map"
        switch settings.preset {
        case .studioStage: addStudio(to: root, settings: settings)
        case .cityBlock: addCity(to: root, settings: settings)
        case .landscape: addLandscape(to: root, settings: settings)
        case .arena: addArena(to: root, settings: settings)
        }
        root.enumerateChildNodes { node, _ in
            guard node.geometry != nil, node.physicsBody == nil else { return }
            node.physicsBody = .static()
        }
        return root
    }

    private static func material(_ color: NSColor, roughness: CGFloat = 0.75) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.roughness.contents = roughness
        return material
    }

    private static func addBox(to root: SCNNode, size: SCNVector3, position: SCNVector3, color: NSColor) {
        let box = SCNBox(width: size.x, height: size.y, length: size.z, chamferRadius: 0.03)
        box.materials = [material(color)]
        let node = SCNNode(geometry: box)
        node.position = position
        root.addChildNode(node)
    }

    private static func addStudio(to root: SCNNode, settings: SceneMapSettings) {
        let size = CGFloat(settings.size)
        addBox(to: root, size: SCNVector3(size, 0.12, size), position: SCNVector3(0, -0.06, 0), color: NSColor(calibratedWhite: 0.18, alpha: 1))
        addBox(to: root, size: SCNVector3(size, size * 0.5, 0.15), position: SCNVector3(0, size * 0.25, -size * 0.5), color: NSColor(calibratedWhite: 0.12, alpha: 1))
    }

    private static func addCity(to root: SCNNode, settings: SceneMapSettings) {
        let extent = max(3, min(12, settings.detail))
        let spacing = CGFloat(settings.size) / CGFloat(extent)
        addBox(to: root, size: SCNVector3(settings.size, 0.08, settings.size), position: SCNVector3(0, -0.04, 0), color: NSColor(calibratedWhite: 0.10, alpha: 1))
        var random = SceneSeededRandom(seed: settings.seed)
        for x in 0..<extent where x != extent / 2 {
            for z in 0..<extent where z != extent / 2 {
                let height = CGFloat(0.7 + random.nextUnit() * 4.8)
                let px = (CGFloat(x) - CGFloat(extent - 1) / 2) * spacing
                let pz = (CGFloat(z) - CGFloat(extent - 1) / 2) * spacing
                addBox(to: root, size: SCNVector3(spacing * 0.68, height, spacing * 0.68), position: SCNVector3(px, height * 0.5, pz), color: NSColor(calibratedWhite: 0.18 + CGFloat(random.nextUnit()) * 0.18, alpha: 1))
            }
        }
    }

    private static func addLandscape(to root: SCNNode, settings: SceneMapSettings) {
        let segments = max(3, min(48, settings.detail))
        let size = Float(settings.size)
        var random = SceneSeededRandom(seed: settings.seed)
        var vertices: [SCNVector3] = []
        for z in 0...segments {
            for x in 0...segments {
                let nx = Float(x) / Float(segments)
                let nz = Float(z) / Float(segments)
                let wave = sin(nx * .pi * 3.2) * cos(nz * .pi * 2.7) * 0.65
                let noise = Float(random.nextUnit() - 0.5) * 0.18
                vertices.append(SCNVector3((nx - 0.5) * size, max(-0.15, wave + noise), (nz - 0.5) * size))
            }
        }
        var indices: [UInt32] = []
        let row = segments + 1
        for z in 0..<segments {
            for x in 0..<segments {
                let a = UInt32(z * row + x), b = a + 1, c = UInt32((z + 1) * row + x), d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        let step = size / Float(segments)
        var normals: [SCNVector3] = []
        for z in 0...segments {
            for x in 0...segments {
                let left = vertices[z * row + max(0, x - 1)].y
                let right = vertices[z * row + min(segments, x + 1)].y
                let back = vertices[max(0, z - 1) * row + x].y
                let front = vertices[min(segments, z + 1) * row + x].y
                let candidate = SCNVector3(left - right, CGFloat(step * 2), back - front)
                let squaredLength = candidate.x * candidate.x + candidate.y * candidate.y + candidate.z * candidate.z
                let length = max(CGFloat(0.000_001), sqrt(squaredLength))
                normals.append(SCNVector3(candidate.x / length, candidate.y / length, candidate.z / length))
            }
        }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        geometry.materials = [material(NSColor(calibratedRed: 0.16, green: 0.31, blue: 0.13, alpha: 1), roughness: 0.92)]
        let terrain = SCNNode(geometry: geometry)
        terrain.physicsBody = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(node: terrain, options: [.type: SCNPhysicsShape.ShapeType.concavePolyhedron]))
        root.addChildNode(terrain)
    }

    private static func addArena(to root: SCNNode, settings: SceneMapSettings) {
        let radius = CGFloat(settings.size) * 0.45
        let floor = SCNCylinder(radius: radius, height: 0.12)
        floor.materials = [material(NSColor(calibratedRed: 0.19, green: 0.20, blue: 0.23, alpha: 1))]
        let floorNode = SCNNode(geometry: floor)
        floorNode.position.y = -0.06
        root.addChildNode(floorNode)
        let count = max(12, settings.detail * 2)
        for index in 0..<count {
            let angle = Double(index) / Double(count) * .pi * 2
            addBox(
                to: root,
                size: SCNVector3(1.2, 1.4, 0.45),
                position: SCNVector3(cos(angle) * Double(radius), 0.7, sin(angle) * Double(radius)),
                color: NSColor(calibratedWhite: 0.22, alpha: 1)
            )
        }
    }
}

private struct SceneSeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func nextUnit() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64.max >> 11)
    }
}

private final class SceneViewportView: SCNView {
    var onNodePicked: ((SCNNode) -> Void)?
    var onMediaDropped: ((URL) -> Void)?
    var onModelDropped: ((URL) -> Void)?

    override init(frame frameRect: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frameRect, options: options)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue]).first {
            onNodePicked?(hit.node)
        }
        super.mouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        supportedURL(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dropped = supportedURL(from: sender.draggingPasteboard) else { return false }
        switch dropped {
        case .movie(let url): onMediaDropped?(url)
        case .model(let url): onModelDropped?(url)
        }
        return true
    }

    private enum DroppedFile {
        case movie(URL)
        case model(URL)
    }

    private func supportedURL(from board: NSPasteboard) -> DroppedFile? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        let movieExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if movieExtensions.contains(ext) { return .movie(url) }
            if ImportedModelLoader.supportedExtensions.contains(ext) { return .model(url) }
        }
        return nil
    }
}

private enum TransformField: Hashable {
    case positionX, positionY, positionZ, rotationX, rotationY, rotationZ, scaleX, scaleY, scaleZ

    var defaultText: String {
        switch self { case .scaleX, .scaleY, .scaleZ: return "1"; default: return "0" }
    }

    var toolTip: String {
        switch self {
        case .positionX, .rotationX, .scaleX: return "X"
        case .positionY, .rotationY, .scaleY: return "Y"
        case .positionZ, .rotationZ, .scaleZ: return "Z"
        }
    }
}

private enum ChromaShader {
    static let source = """
    #pragma arguments
    float chromaEnabled;
    float chromaThreshold;
    float chromaSoftness;
    float chromaChoke;
    float chromaSpill;
    float3 chromaColor;
    #pragma body
    float keyDistance = distance(_surface.diffuse.rgb, chromaColor);
    float adjustedThreshold = max(0.001, chromaThreshold + chromaChoke * 0.20);
    float keyedAlpha = smoothstep(adjustedThreshold, adjustedThreshold + chromaSoftness, keyDistance);
    float edgeStrength = (1.0 - keyedAlpha) * chromaSpill * chromaEnabled;
    float neutralLuma = dot(_surface.diffuse.rgb, float3(0.299, 0.587, 0.114));
    _surface.diffuse.rgb = mix(_surface.diffuse.rgb, float3(neutralLuma), edgeStrength);
    _surface.diffuse.a *= mix(1.0, keyedAlpha, chromaEnabled);
    """
}

/// Builds the editable root node used by both the live viewport and the
/// deterministic movie renderer. Imported assets remain child hierarchies so
/// their meshes, materials, and texture references are preserved.
private enum SceneNodeFactory {
    static func node(for record: SceneObjectRecord, importedModel: SCNNode? = nil) -> SCNNode {
        let node: SCNNode
        if record.kind == .model {
            if let importedModel {
                node = importedModel
            } else if let url = record.modelURL,
                      let loaded = try? ImportedModelLoader.loadNormalizedNode(from: url) {
                node = loaded
            } else {
                node = ImportedModelLoader.missingModelNode()
            }
        } else {
            node = SCNNode(geometry: SceneGeometryFactory.geometry(for: record))
        }

        node.name = record.name
        node.position = record.position.scn
        node.eulerAngles = SCNVector3(
            record.rotation.x * .pi / 180,
            record.rotation.y * .pi / 180,
            record.rotation.z * .pi / 180
        )
        node.scale = record.scale.scn

        if record.kind == .model {
            if node.value(forKey: "netVistaMissingModel") == nil {
                applyMaterialTint(record.color.color, to: node)
            }
        } else if let material = node.geometry?.firstMaterial {
            material.diffuse.contents = record.color.color
            material.roughness.contents = 0.36
            material.metalness.contents = record.kind == .plane || record.kind == .mediaPlane ? 0.05 : 0.15
            material.isDoubleSided = record.kind == .plane || record.kind == .mediaPlane
        }
        return node
    }

    /// Multiplies the model's existing diffuse materials instead of replacing
    /// them, so imported texture maps remain visible while the inspector colour
    /// acts as a non-destructive material tint.
    static func applyMaterialTint(_ color: NSColor, to root: SCNNode) {
        root.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            if geometry.materials.isEmpty {
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased
                geometry.materials = [material]
            }
            for material in geometry.materials {
                material.multiply.contents = color
                material.multiply.intensity = 1
            }
        }
    }
}

private enum ImportedModelLoader {
    private static let modelIOCandidates = ["abc", "obj", "ply", "stl", "usd", "usda", "usdc", "usdz"]
    private static let sceneKitCandidates = ["dae", "scn"]

    static var supportedExtensions: [String] {
        let modelIO = modelIOCandidates.filter { MDLAsset.canImportFileExtension($0) }
        return Array(Set(modelIO + sceneKitCandidates)).sorted()
    }

    static func loadNormalizedNode(from url: URL) throws -> SCNNode {
        let sourceURL = url.standardizedFileURL
        let ext = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw SceneEditorError.unsupportedModelType(ext.isEmpty ? "unknown" : ext)
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw SceneEditorError.modelFileMissing(sourceURL.lastPathComponent)
        }

        let loadedRoot: SCNNode?
        if sceneKitCandidates.contains(ext) {
            loadedRoot = try loadWithSceneKit(from: sourceURL)
        } else {
            loadedRoot = loadWithModelIO(from: sourceURL) ?? (try? loadWithSceneKit(from: sourceURL))
        }
        guard let loadedRoot, hasRenderableGeometry(loadedRoot) else {
            throw SceneEditorError.cannotLoadModel(sourceURL.lastPathComponent)
        }
        return normalize(loadedRoot)
    }

    private static func loadWithModelIO(from url: URL) -> SCNNode? {
        guard MDLAsset.canImportFileExtension(url.pathExtension.lowercased()) else { return nil }
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else { return nil }
        let converted = SCNScene(mdlAsset: asset)
        return hasRenderableGeometry(converted.rootNode) ? converted.rootNode.clone() : nil
    }

    private static func loadWithSceneKit(from url: URL) throws -> SCNNode? {
        let options: [SCNSceneSource.LoadingOption: Any] = [
            .checkConsistency: true,
            .assetDirectoryURLs: [url.deletingLastPathComponent()],
            .preserveOriginalTopology: true,
            .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.doNotPlay
        ]
        guard let source = SCNSceneSource(url: url, options: options) else { return nil }
        let loaded = try source.scene(options: options)
        return hasRenderableGeometry(loaded.rootNode) ? loaded.rootNode.clone() : nil
    }

    private static func hasRenderableGeometry(_ root: SCNNode) -> Bool {
        if root.geometry != nil { return true }
        var found = false
        root.enumerateChildNodes { node, stop in
            if node.geometry != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Centres every imported file and fits its largest dimension into two
    /// scene units. The editable record's own position/rotation/scale remains
    /// on the outer node, so saving and reopening reproduces the same transform.
    private static func normalize(_ sourceRoot: SCNNode) -> SCNNode {
        let assetRoot = sourceRoot.clone()
        let normalizationNode = SCNNode()
        normalizationNode.name = "__importedAsset"
        normalizationNode.addChildNode(assetRoot)
        if let bounds = geometryBounds(in: assetRoot) {
            let width = bounds.max.x - bounds.min.x
            let height = bounds.max.y - bounds.min.y
            let depth = bounds.max.z - bounds.min.z
            let largest = max(width, max(height, depth))
            if largest.isFinite, largest > 0.000_001 {
                let factor = CGFloat(2) / largest
                normalizationNode.scale = SCNVector3(factor, factor, factor)
                normalizationNode.position = SCNVector3(
                    -(bounds.min.x + bounds.max.x) * 0.5 * factor,
                    -bounds.min.y * factor,
                    -(bounds.min.z + bounds.max.z) * 0.5 * factor
                )
            }
        }
        let editableRoot = SCNNode()
        editableRoot.addChildNode(normalizationNode)
        return editableRoot
    }

    private static func geometryBounds(in root: SCNNode) -> (min: SCNVector3, max: SCNVector3)? {
        var combinedMin = SCNVector3(CGFloat.greatestFiniteMagnitude, CGFloat.greatestFiniteMagnitude, CGFloat.greatestFiniteMagnitude)
        var combinedMax = SCNVector3(-CGFloat.greatestFiniteMagnitude, -CGFloat.greatestFiniteMagnitude, -CGFloat.greatestFiniteMagnitude)
        var found = false
        let visit: (SCNNode) -> Void = { node in
            guard node.geometry != nil else { return }
            let localMin = node.boundingBox.min
            let localMax = node.boundingBox.max
            for x in [localMin.x, localMax.x] {
                for y in [localMin.y, localMax.y] {
                    for z in [localMin.z, localMax.z] {
                        let point = root.convertPosition(SCNVector3(x, y, z), from: node)
                        combinedMin.x = min(combinedMin.x, point.x)
                        combinedMin.y = min(combinedMin.y, point.y)
                        combinedMin.z = min(combinedMin.z, point.z)
                        combinedMax.x = max(combinedMax.x, point.x)
                        combinedMax.y = max(combinedMax.y, point.y)
                        combinedMax.z = max(combinedMax.z, point.z)
                        found = true
                    }
                }
            }
        }
        visit(root)
        root.enumerateChildNodes { node, _ in visit(node) }
        return found ? (combinedMin, combinedMax) : nil
    }

    static func missingModelNode() -> SCNNode {
        let geometry = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.04)
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemRed
        material.emission.contents = NSColor.systemRed.withAlphaComponent(0.18)
        material.fillMode = .lines
        material.isDoubleSided = true
        geometry.materials = [material]
        let placeholder = SCNNode(geometry: geometry)
        placeholder.position = SCNVector3(0, 0.5, 0)
        let editableRoot = SCNNode()
        editableRoot.addChildNode(placeholder)
        editableRoot.setValue(true, forKey: "netVistaMissingModel")
        return editableRoot
    }
}

private enum SceneGeometryFactory {
    static func geometry(for record: SceneObjectRecord) -> SCNGeometry {
        let geometry: SCNGeometry
        switch record.kind {
        case .cube:
            geometry = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.06)
        case .sphere:
            geometry = SCNSphere(radius: 0.58)
        case .cylinder:
            geometry = SCNCylinder(radius: 0.5, height: 1.25)
        case .plane:
            geometry = SCNPlane(width: 2, height: 2)
        case .mediaPlane:
            geometry = SCNPlane(width: 2, height: CGFloat(2 / max(0.1, record.mediaAspectRatio)))
        case .model:
            // Imported models are created by SceneNodeFactory. This fallback
            // keeps the switch exhaustive if a broken model must be represented.
            geometry = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.04)
        }
        let material = SCNMaterial()
        material.diffuse.contents = record.color.color
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.36
        geometry.materials = [material]
        return geometry
    }
}

private enum GridGeometry {
    static func makeNode() -> SCNNode {
        var vertices: [SCNVector3] = []
        for value in -10...10 {
            vertices.append(contentsOf: [SCNVector3(Float(value), 0.004, -10), SCNVector3(Float(value), 0.004, 10)])
            vertices.append(contentsOf: [SCNVector3(-10, 0.004, Float(value)), SCNVector3(10, 0.004, Float(value))])
        }
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let indices = Array(0..<vertices.count).map(UInt32.init)
        let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: data, primitiveType: .line, primitiveCount: vertices.count / 2, bytesPerIndex: MemoryLayout<UInt32>.size)
        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedWhite: 0.34, alpha: 0.42)
        material.lightingModel = SCNMaterial.LightingModel.constant
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = "__grid"
        return node
    }
}

public enum SceneEditorError: LocalizedError {
    case unsupportedDocumentVersion(Int)
    case unsupportedModelType(String)
    case modelFileMissing(String)
    case cannotLoadModel(String)
    case renderAlreadyRunning
    case cannotCreateWriter
    case cannotStartWriter(String)
    case cannotCreatePixelBuffer
    case frameAppendFailed(Int, String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedDocumentVersion(let version): return "This scene uses unsupported format version \(version)."
        case .unsupportedModelType(let type): return "The .\(type) model format is not supported on this Mac. Try OBJ, USDZ, USD, DAE, SCN, PLY, STL, or ABC."
        case .modelFileMissing(let name): return "The original model file \(name) could not be found. Move it back to its saved location or import it again."
        case .cannotLoadModel(let name): return "\(name) did not contain a model that SceneKit could read."
        case .renderAlreadyRunning: return "A scene render is already running."
        case .cannotCreateWriter: return "The video encoder could not be created."
        case .cannotStartWriter(let message): return "The video encoder could not start: \(message)"
        case .cannotCreatePixelBuffer: return "The renderer could not allocate a video frame."
        case .frameAppendFailed(let frame, let message): return "Frame \(frame) could not be written: \(message)"
        }
    }
}

// MARK: - Deterministic offline SceneKit renderer

private enum SceneMovieRenderer {
    static func render(
        document: NetVistaSceneDocument,
        to outputURL: URL,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try renderSynchronously(document: document, to: outputURL, progress: progress)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func renderSynchronously(document: NetVistaSceneDocument, to outputURL: URL, progress: (Double) -> Void) throws {
        let base = outputURL.deletingPathExtension().lastPathComponent
        let stagingURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(base).scene-render-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        var committed = false
        defer {
            if !committed { try? FileManager.default.removeItem(at: stagingURL) }
        }
        let width = max(320, document.canvasWidth)
        let height = max(180, document.canvasHeight)
        let fps = min(60, max(1, document.framesPerSecond))
        let averageBitRate = min(80_000_000, max(4_000_000, width * height * fps / 8))
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        // H.264 is preferred for compact timeline intermediates. Some Macs or
        // managed environments expose no H.264 encoder, so Motion JPEG provides
        // a deterministic software fallback instead of making Render Clip fail.
        var selectedWriter: AVAssetWriter?
        var selectedInput: AVAssetWriterInput?
        var selectedAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        var encoderErrors: [String] = []
        let rawCodec = AVVideoCodecType(rawValue: "raw ")
        for codec in [AVVideoCodecType.h264, .jpeg, rawCodec] {
            try? FileManager.default.removeItem(at: stagingURL)
            guard let candidateWriter = try? AVAssetWriter(outputURL: stagingURL, fileType: .mov) else { continue }
            let compression: [String: Any]
            if codec == .h264 {
                compression = [
                    AVVideoAverageBitRateKey: averageBitRate,
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoMaxKeyFrameIntervalKey: fps * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            } else if codec == .jpeg {
                compression = [AVVideoQualityKey: 0.9]
            } else {
                compression = [:]
            }
            var settings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
            if !compression.isEmpty { settings[AVVideoCompressionPropertiesKey] = compression }
            let candidateInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            candidateInput.expectsMediaDataInRealTime = false
            guard candidateWriter.canAdd(candidateInput) else {
                encoderErrors.append("\(codec.rawValue): writer rejected the input")
                continue
            }
            candidateWriter.add(candidateInput)
            let candidateAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: candidateInput, sourcePixelBufferAttributes: attributes)
            if candidateWriter.startWriting() {
                selectedWriter = candidateWriter
                selectedInput = candidateInput
                selectedAdaptor = candidateAdaptor
                break
            }
            encoderErrors.append("\(codec.rawValue): \(candidateWriter.error?.localizedDescription ?? "could not start")")
        }
        guard let writer = selectedWriter, let input = selectedInput, let adaptor = selectedAdaptor else {
            throw SceneEditorError.cannotStartWriter(encoderErrors.joined(separator: "; "))
        }
        writer.startSession(atSourceTime: .zero)

        let runtime = OfflineScene(document: document)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = runtime.scene
        renderer.pointOfView = runtime.camera
        let frameCount = max(1, Int((document.duration * Double(fps)).rounded(.up)))
        let frameSize = CGSize(width: width, height: height)

        for frame in 0..<frameCount {
            if writer.status == .failed || writer.status == .cancelled {
                throw SceneEditorError.frameAppendFailed(frame, writer.error?.localizedDescription ?? "Encoder stopped")
            }
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed || writer.status == .cancelled {
                    throw SceneEditorError.frameAppendFailed(frame, writer.error?.localizedDescription ?? "Encoder stopped")
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            let seconds = Double(frame) / Double(fps)
            let buffer: CVPixelBuffer = try autoreleasepool {
                runtime.update(at: seconds)
                renderer.sceneTime = seconds
                let image = renderer.snapshot(atTime: seconds, with: frameSize, antialiasingMode: .multisampling4X)
                guard let buffer = pixelBuffer(from: image, width: width, height: height) else {
                    throw SceneEditorError.cannotCreatePixelBuffer
                }
                return buffer
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw SceneEditorError.frameAppendFailed(frame, writer.error?.localizedDescription ?? "Append failed")
            }
            if frame % max(1, fps / 4) == 0 { progress(Double(frame + 1) / Double(frameCount)) }
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            throw SceneEditorError.cannotStartWriter(writer.error.map { String(describing: $0) } ?? "Finishing failed")
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: outputURL.path) {
            _ = try manager.replaceItemAt(outputURL, withItemAt: stagingURL)
        } else {
            try manager.moveItem(at: stagingURL, to: outputURL)
        }
        committed = true
        progress(1)
    }

    private static func pixelBuffer(from image: NSImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let options: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, options as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        var rect = NSRect(x: 0, y: 0, width: width, height: height)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}

private final class OfflineScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let document: NetVistaSceneDocument
    private var objectNodes: [UUID: SCNNode] = [:]
    private var media: [(generator: AVAssetImageGenerator, material: SCNMaterial, duration: Double, chroma: SceneChromaKey)] = []

    init(document: NetVistaSceneDocument) {
        self.document = document
        SceneEnvironment.apply(document.environmentPreset, document: document, to: scene)
        scene.physicsWorld.gravity = document.physicsGravity.scn
        scene.physicsWorld.timeStep = 1.0 / Double(max(1, document.framesPerSecond))
        let floor = SCNFloor()
        floor.reflectivity = 0.18
        floor.reflectionFalloffEnd = 12
        floor.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.12, alpha: 1)
        floor.firstMaterial?.roughness.contents = 0.7
        let floorNode = SCNNode(geometry: floor)
        floorNode.physicsBody = .static()
        scene.rootNode.addChildNode(floorNode)
        if document.mapSettings.enabled {
            scene.rootNode.addChildNode(SceneMapFactory.makeNode(settings: document.mapSettings))
        }

        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 48
        camera.camera?.wantsHDR = true
        camera.camera?.exposureOffset = document.exposure
        camera.position = document.cameraPosition.scn
        camera.look(at: document.cameraTarget.scn)
        scene.rootNode.addChildNode(camera)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = document.ambientLightIntensity
        ambient.light?.color = NSColor(calibratedWhite: 0.78, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = document.keyLightIntensity
        key.light?.color = NSColor(calibratedRed: 1, green: 0.92, blue: 0.80, alpha: 1)
        key.light?.castsShadow = true
        key.light?.shadowRadius = 8
        key.light?.shadowSampleCount = 16
        key.position = SCNVector3(3.5, 5.5, 4.5)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .omni
        rim.light?.color = NSColor(calibratedRed: 0.32, green: 0.52, blue: 1, alpha: 1)
        rim.light?.intensity = 650
        rim.position = SCNVector3(-4, 2.5, -3)
        scene.rootNode.addChildNode(rim)

        for record in document.objects {
            let node = SceneNodeFactory.node(for: record)
            ScenePhysicsFactory.apply(record.physics, to: node)
            if record.kind == .mediaPlane,
               let material = node.geometry?.firstMaterial,
               let url = record.mediaURL {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0 / 60, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / 60, preferredTimescale: 600)
                let duration = max(0.01, asset.duration.seconds.isFinite ? asset.duration.seconds : 1)
                material.blendMode = record.chromaKey.enabled ? .alpha : .replace
                material.transparencyMode = .dualLayer
                material.shaderModifiers = [.surface: ChromaShader.source]
                material.setValue(record.chromaKey.enabled ? 1.0 : 0.0, forKey: "chromaEnabled")
                material.setValue(record.chromaKey.threshold, forKey: "chromaThreshold")
                material.setValue(record.chromaKey.softness, forKey: "chromaSoftness")
                material.setValue(record.chromaKey.choke, forKey: "chromaChoke")
                material.setValue(record.chromaKey.spillSuppression, forKey: "chromaSpill")
                material.setValue(NSValue(scnVector3: SCNVector3(record.chromaKey.color.red, record.chromaKey.color.green, record.chromaKey.color.blue)), forKey: "chromaColor")
                media.append((generator, material, duration, record.chromaKey))
            }
            scene.rootNode.addChildNode(node)
            objectNodes[record.id] = node
        }
        SceneAnimationEvaluator.apply(document: document, time: 0, objectNodes: objectNodes, camera: camera)
    }

    func update(at seconds: Double) {
        SceneAnimationEvaluator.apply(document: document, time: seconds, objectNodes: objectNodes, camera: camera)
        for item in media {
            let local = seconds.truncatingRemainder(dividingBy: item.duration)
            if let cgImage = try? item.generator.copyCGImage(at: CMTime(seconds: local, preferredTimescale: 600), actualTime: nil) {
                item.material.diffuse.contents = cgImage
            }
        }
    }
}
