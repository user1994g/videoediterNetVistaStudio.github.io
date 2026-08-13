import Cocoa
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import CoreImage

extension NSPasteboard.PasteboardType {
    static let netVistaAsset = NSPasteboard.PasteboardType("local.netvista-studio.media-asset")
}

enum MediaKind: String, Codable { case video, audio }

enum KeyframeInterpolation: String, Codable, CaseIterable { case hold, linear, easeInOut }

enum AnimatableProperty: String, Codable, CaseIterable {
    case positionX, positionY, scale, rotation, opacity
    case brightness, contrast, saturation, gamma, temperature, tint, exposure, highlights, shadows, vibrance, hue
    case blurRadius, sharpenAmount, vignetteIntensity, monochromeAmount, sepiaAmount
    case cropLeft, cropRight, cropTop, cropBottom
    case ultraKeyTolerance, ultraKeySoftness, ultraKeyChoke, ultraKeySpill
    case volume

    var title: String {
        switch self {
        case .positionX: return "Position X"
        case .positionY: return "Position Y"
        case .scale: return "Scale"
        case .rotation: return "Rotation"
        case .opacity: return "Opacity"
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .saturation: return "Saturation"
        case .gamma: return "Gamma"
        case .temperature: return "Temperature"
        case .tint: return "Tint"
        case .exposure: return "Exposure"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .vibrance: return "Vibrance"
        case .hue: return "Hue"
        case .blurRadius: return "Blur"
        case .sharpenAmount: return "Sharpen"
        case .vignetteIntensity: return "Vignette"
        case .monochromeAmount: return "Monochrome"
        case .sepiaAmount: return "Sepia"
        case .cropLeft: return "Crop Left"
        case .cropRight: return "Crop Right"
        case .cropTop: return "Crop Top"
        case .cropBottom: return "Crop Bottom"
        case .ultraKeyTolerance: return "Ultra Key Tolerance"
        case .ultraKeySoftness: return "Ultra Key Soften"
        case .ultraKeyChoke: return "Ultra Key Choke"
        case .ultraKeySpill: return "Ultra Key Spill"
        case .volume: return "Volume"
        }
    }
}

struct ScalarKeyframe: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var time: Double
    var value: Double
    var interpolation: KeyframeInterpolation = .linear
}

struct AnimationChannel: Codable, Equatable {
    var property: AnimatableProperty
    var keyframes: [ScalarKeyframe] = []
}

struct ClipAnimation: Codable, Equatable {
    var channels: [AnimationChannel] = []

    func value(for property: AnimatableProperty, at localTime: Double, fallback: Double) -> Double {
        guard let channel = channels.first(where: { $0.property == property }) else { return fallback }
        let frames = channel.keyframes.sorted { $0.time < $1.time }
        guard let previous = frames.last(where: { $0.time <= localTime + (1.0 / 60.0) }) else { return frames.first?.value ?? fallback }
        guard let following = frames.first(where: { $0.time > previous.time + (1.0 / 60.0) }) else { return previous.value }
        let span = following.time - previous.time
        guard span > 0 else { return following.value }
        let linear = min(1, max(0, (localTime - previous.time) / span))
        switch previous.interpolation {
        case .hold: return previous.value
        case .linear: return previous.value + (following.value - previous.value) * linear
        case .easeInOut:
            let eased = linear * linear * (3 - 2 * linear)
            return previous.value + (following.value - previous.value) * eased
        }
    }

    mutating func setKeyframe(property: AnimatableProperty, time: Double, value: Double, interpolation: KeyframeInterpolation = .linear) {
        let snappedTime = max(0, (time * 30).rounded() / 30)
        if let index = channels.firstIndex(where: { $0.property == property }) {
            if let frame = channels[index].keyframes.firstIndex(where: { abs($0.time - snappedTime) < (1.0 / 60.0) }) {
                channels[index].keyframes[frame].value = value
                channels[index].keyframes[frame].interpolation = interpolation
            } else {
                channels[index].keyframes.append(ScalarKeyframe(time: snappedTime, value: value, interpolation: interpolation))
                channels[index].keyframes.sort { $0.time < $1.time }
            }
        } else {
            channels.append(AnimationChannel(property: property, keyframes: [ScalarKeyframe(time: snappedTime, value: value, interpolation: interpolation)]))
        }
    }

    mutating func removeKeyframe(property: AnimatableProperty, near time: Double) {
        guard let index = channels.firstIndex(where: { $0.property == property }) else { return }
        channels[index].keyframes.removeAll { abs($0.time - time) < (1.0 / 60.0) }
        if channels[index].keyframes.isEmpty { channels.remove(at: index) }
    }
}

struct ClipTransform: Codable, Equatable {
    var positionX: Double = 0
    var positionY: Double = 0
    var scale: Double = 1
    var rotation: Double = 0
    var opacity: Double = 1
}

/// A single three-way color-wheel correction. Channel values are signed color
/// offsets while `master` is the matching tonal (luma) adjustment. Keeping the
/// RGB channels explicit makes saved grades deterministic and lets the native
/// preview/export paths use the exact same values.
struct ColorWheelAdjustment: Codable, Equatable {
    var red: Double = 0
    var green: Double = 0
    var blue: Double = 0
    var master: Double = 0

    init(red: Double = 0, green: Double = 0, blue: Double = 0, master: Double = 0) {
        self.red = red; self.green = green; self.blue = blue; self.master = master
    }
}

struct ColorExtras: Codable, Equatable {
    var exposure: Double = 0
    var tint: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var vibrance: Double = 0
    var hue: Double = 0
    var lift: ColorWheelAdjustment = .init()
    var midtones: ColorWheelAdjustment = .init()
    var gain: ColorWheelAdjustment = .init()
    var cubeLUT: ClipLUTSettings?

    init(exposure: Double = 0, tint: Double = 0, highlights: Double = 0, shadows: Double = 0, vibrance: Double = 0, hue: Double = 0, lift: ColorWheelAdjustment = .init(), midtones: ColorWheelAdjustment = .init(), gain: ColorWheelAdjustment = .init(), cubeLUT: ClipLUTSettings? = nil) {
        self.exposure = exposure; self.tint = tint; self.highlights = highlights; self.shadows = shadows; self.vibrance = vibrance; self.hue = hue
        self.lift = lift; self.midtones = midtones; self.gain = gain
        self.cubeLUT = cubeLUT
    }

    private enum CodingKeys: String, CodingKey { case exposure, tint, highlights, shadows, vibrance, hue, lift, midtones, gain, cubeLUT }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        lift = try c.decodeIfPresent(ColorWheelAdjustment.self, forKey: .lift) ?? .init()
        midtones = try c.decodeIfPresent(ColorWheelAdjustment.self, forKey: .midtones) ?? .init()
        gain = try c.decodeIfPresent(ColorWheelAdjustment.self, forKey: .gain) ?? .init()
        cubeLUT = try c.decodeIfPresent(ClipLUTSettings.self, forKey: .cubeLUT)
    }
}

struct ClipCrop: Codable, Equatable {
    var left = 0.0
    var right = 0.0
    var top = 0.0
    var bottom = 0.0
}

enum ClipBlendMode: String, Codable, CaseIterable {
    case normal, multiply, screen, overlay, softLight, add
    var title: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .overlay: return "Overlay"
        case .softLight: return "Soft Light"
        case .add: return "Linear Dodge (Add)"
        }
    }
}

struct ClipEffects: Codable, Equatable {
    var blurRadius: Double = 0
    var sharpenAmount: Double = 0
    var vignetteIntensity: Double = 0
    var monochromeAmount: Double = 0
    var sepiaAmount: Double = 0
    var crop = ClipCrop()
    var ultraKey = UltraKeySettings()
    var blendMode: ClipBlendMode = .normal

    private enum CodingKeys: String, CodingKey {
        case blurRadius, sharpenAmount, vignetteIntensity, monochromeAmount, sepiaAmount, crop, ultraKey, blendMode
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blurRadius = try c.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 0
        sharpenAmount = try c.decodeIfPresent(Double.self, forKey: .sharpenAmount) ?? 0
        vignetteIntensity = try c.decodeIfPresent(Double.self, forKey: .vignetteIntensity) ?? 0
        monochromeAmount = try c.decodeIfPresent(Double.self, forKey: .monochromeAmount) ?? 0
        sepiaAmount = try c.decodeIfPresent(Double.self, forKey: .sepiaAmount) ?? 0
        crop = try c.decodeIfPresent(ClipCrop.self, forKey: .crop) ?? .init()
        ultraKey = try c.decodeIfPresent(UltraKeySettings.self, forKey: .ultraKey) ?? .init()
        blendMode = try c.decodeIfPresent(ClipBlendMode.self, forKey: .blendMode) ?? .normal
    }
}

/// Transient values used by the floating Color Studio window.  They deliberately
/// stay separate from the saved model until the user presses Apply.
struct ColorControlValues: Equatable {
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var gamma = 1.0
    var temperature = 6500.0
    var exposure = 0.0
    var tint = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var vibrance = 0.0
    var hue = 0.0
    var lift = ColorWheelAdjustment()
    var midtones = ColorWheelAdjustment()
    var gain = ColorWheelAdjustment()
    var cubeLUT: ClipLUTSettings?

    init() {}
    init(_ clip: TimelineClip) {
        brightness = clip.brightness; contrast = clip.contrast; saturation = clip.saturation; gamma = clip.gamma; temperature = clip.temperature
        exposure = clip.colorExtras.exposure; tint = clip.colorExtras.tint; highlights = clip.colorExtras.highlights; shadows = clip.colorExtras.shadows; vibrance = clip.colorExtras.vibrance; hue = clip.colorExtras.hue
        lift = clip.colorExtras.lift; midtones = clip.colorExtras.midtones; gain = clip.colorExtras.gain
        cubeLUT = clip.colorExtras.cubeLUT
    }
}

/// Builds a smooth three-way tonal curve. Lift has its strongest influence at
/// black, midtones peak around 50%, and gain has its strongest influence near
/// white. The polynomial form is fast enough for the live Core Image preview.
func applyingThreeWayColorWheels(to image: CIImage, extras: ColorExtras) -> CIImage {
    let wheels = [extras.lift, extras.midtones, extras.gain]
    guard wheels.contains(where: { abs($0.red) > 0.000_01 || abs($0.green) > 0.000_01 || abs($0.blue) > 0.000_01 || abs($0.master) > 0.000_01 }) else { return image }

    func coefficients(_ channel: KeyPath<ColorWheelAdjustment, Double>) -> CIVector {
        let lift = extras.lift[keyPath: channel] + extras.lift.master
        let middle = extras.midtones[keyPath: channel] + extras.midtones.master
        let gain = extras.gain[keyPath: channel] + extras.gain.master
        // x + lift(1-x)^2 + middle(4x(1-x)) + gain(x^2)
        return CIVector(x: lift, y: 1 - 2 * lift + 4 * middle, z: lift - 4 * middle + gain, w: 0)
    }

    return image.applyingFilter("CIColorPolynomial", parameters: [
        "inputRedCoefficients": coefficients(\.red),
        "inputGreenCoefficients": coefficients(\.green),
        "inputBlueCoefficients": coefficients(\.blue),
        "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0)
    ])
}

/// A lock-protected grade snapshot read by AVFoundation's render queue. Wheel
/// drags update this value in place, avoiding an expensive AVPlayerItem rebuild
/// for every mouse event while keeping Core Image rendering thread-safe.
private final class LiveGradePreviewState: @unchecked Sendable {
    let sourceURL: URL
    let clipID: UUID
    private let lock = NSLock()
    private var storedClip: TimelineClip

    init(sourceURL: URL, clip: TimelineClip) {
        self.sourceURL = sourceURL.standardizedFileURL
        clipID = clip.id
        storedClip = clip
    }

    func update(_ clip: TimelineClip) {
        lock.lock(); storedClip = clip; lock.unlock()
    }

    func clip() -> TimelineClip {
        lock.lock(); defer { lock.unlock() }; return storedClip
    }
}

/// Transient transform/effect values for the floating Effects Studio window.
struct EffectControlValues: Equatable {
    var transform = ClipTransform()
    var effects = ClipEffects()

    init() {}
    init(_ clip: TimelineClip) { transform = clip.transform; effects = clip.effects }
}

struct MediaAsset: Codable, Equatable {
    let id: UUID
    var name: String
    var url: URL
    var kind: MediaKind
    var duration: Double
    var hasAudio: Bool
    init(id: UUID = UUID(), name: String, url: URL, kind: MediaKind = .video, duration: Double = 6, hasAudio: Bool = true) { self.id = id; self.name = name; self.url = url; self.kind = kind; self.duration = duration; self.hasAudio = hasAudio }
    enum CodingKeys: String, CodingKey { case id, name, url, kind, duration, hasAudio }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name); url = try c.decode(URL.self, forKey: .url); kind = try c.decodeIfPresent(MediaKind.self, forKey: .kind) ?? .video; duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 6; hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? true }
}

struct TimelineClip: Codable, Equatable {
    var id: UUID
    let assetID: UUID
    var name: String
    var url: URL
    var inPoint: Double
    var outPoint: Double
    var timelineStart: Double
    var track: Int
    var brightness: Double
    var contrast: Double
    var saturation: Double
    var gamma: Double
    var temperature: Double
    var volume: Double
    var transform: ClipTransform
    var colorExtras: ColorExtras
    var effects: ClipEffects
    var animation: ClipAnimation
    var kind: MediaKind
    var groupID: UUID?
    /// Links a rendered proxy clip back to its fully editable native 3D scene.
    var sceneID: UUID?

    init(id: UUID = UUID(), assetID: UUID, name: String, url: URL, inPoint: Double = 0, outPoint: Double = 0, timelineStart: Double = 0, track: Int = 0, brightness: Double = 0, contrast: Double = 1, saturation: Double = 1, gamma: Double = 1, temperature: Double = 6500, volume: Double = 1, transform: ClipTransform = .init(), colorExtras: ColorExtras = .init(), effects: ClipEffects = .init(), animation: ClipAnimation = .init(), kind: MediaKind = .video, groupID: UUID? = nil, sceneID: UUID? = nil) {
        self.id = id; self.assetID = assetID; self.name = name; self.url = url; self.inPoint = inPoint; self.outPoint = outPoint; self.timelineStart = timelineStart; self.track = track; self.brightness = brightness; self.contrast = contrast; self.saturation = saturation; self.gamma = gamma; self.temperature = temperature; self.volume = volume; self.transform = transform; self.colorExtras = colorExtras; self.effects = effects; self.animation = animation; self.kind = kind; self.groupID = groupID; self.sceneID = sceneID
    }
    enum CodingKeys: String, CodingKey { case id, assetID, name, url, inPoint, outPoint, timelineStart, track, brightness, contrast, saturation, gamma, temperature, volume, transform, colorExtras, effects, animation, kind, groupID, sceneID }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); assetID = try c.decode(UUID.self, forKey: .assetID); name = try c.decode(String.self, forKey: .name); url = try c.decode(URL.self, forKey: .url)
        inPoint = try c.decodeIfPresent(Double.self, forKey: .inPoint) ?? 0; outPoint = try c.decodeIfPresent(Double.self, forKey: .outPoint) ?? 0; timelineStart = try c.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0; track = try c.decodeIfPresent(Int.self, forKey: .track) ?? 0; brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0; contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1; saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1; gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1; temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 6500; volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1; transform = try c.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? .init(); colorExtras = try c.decodeIfPresent(ColorExtras.self, forKey: .colorExtras) ?? .init(); effects = try c.decodeIfPresent(ClipEffects.self, forKey: .effects) ?? .init(); animation = try c.decodeIfPresent(ClipAnimation.self, forKey: .animation) ?? .init(); kind = try c.decodeIfPresent(MediaKind.self, forKey: .kind) ?? .video; groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID); sceneID = try c.decodeIfPresent(UUID.self, forKey: .sceneID)
    }
}

extension TimelineClip {
    func localTime(at timelineTime: Double) -> Double { max(0, timelineTime - timelineStart) }

    func baseValue(for property: AnimatableProperty) -> Double {
        switch property {
        case .positionX: return transform.positionX
        case .positionY: return transform.positionY
        case .scale: return transform.scale
        case .rotation: return transform.rotation
        case .opacity: return transform.opacity
        case .brightness: return brightness
        case .contrast: return contrast
        case .saturation: return saturation
        case .gamma: return gamma
        case .temperature: return temperature
        case .tint: return colorExtras.tint
        case .exposure: return colorExtras.exposure
        case .highlights: return colorExtras.highlights
        case .shadows: return colorExtras.shadows
        case .vibrance: return colorExtras.vibrance
        case .hue: return colorExtras.hue
        case .blurRadius: return effects.blurRadius
        case .sharpenAmount: return effects.sharpenAmount
        case .vignetteIntensity: return effects.vignetteIntensity
        case .monochromeAmount: return effects.monochromeAmount
        case .sepiaAmount: return effects.sepiaAmount
        case .cropLeft: return effects.crop.left
        case .cropRight: return effects.crop.right
        case .cropTop: return effects.crop.top
        case .cropBottom: return effects.crop.bottom
        case .ultraKeyTolerance: return effects.ultraKey.tolerance
        case .ultraKeySoftness: return effects.ultraKey.soften
        case .ultraKeyChoke: return effects.ultraKey.choke
        case .ultraKeySpill: return effects.ultraKey.spill
        case .volume: return volume
        }
    }

    mutating func setBaseValue(_ value: Double, for property: AnimatableProperty) {
        switch property {
        case .positionX: transform.positionX = value
        case .positionY: transform.positionY = value
        case .scale: transform.scale = value
        case .rotation: transform.rotation = value
        case .opacity: transform.opacity = value
        case .brightness: brightness = value
        case .contrast: contrast = value
        case .saturation: saturation = value
        case .gamma: gamma = value
        case .temperature: temperature = value
        case .tint: colorExtras.tint = value
        case .exposure: colorExtras.exposure = value
        case .highlights: colorExtras.highlights = value
        case .shadows: colorExtras.shadows = value
        case .vibrance: colorExtras.vibrance = value
        case .hue: colorExtras.hue = value
        case .blurRadius: effects.blurRadius = value
        case .sharpenAmount: effects.sharpenAmount = value
        case .vignetteIntensity: effects.vignetteIntensity = value
        case .monochromeAmount: effects.monochromeAmount = value
        case .sepiaAmount: effects.sepiaAmount = value
        case .cropLeft: effects.crop.left = value
        case .cropRight: effects.crop.right = value
        case .cropTop: effects.crop.top = value
        case .cropBottom: effects.crop.bottom = value
        case .ultraKeyTolerance: effects.ultraKey.tolerance = value
        case .ultraKeySoftness: effects.ultraKey.soften = value
        case .ultraKeyChoke: effects.ultraKey.choke = value
        case .ultraKeySpill: effects.ultraKey.spill = value
        case .volume: volume = value
        }
    }

    func value(for property: AnimatableProperty, at timelineTime: Double) -> Double {
        animation.value(for: property, at: localTime(at: timelineTime), fallback: baseValue(for: property))
    }

    /// Keeps animation attached to the visible picture when a clip is cut.  Keyframes
    /// are clip-local, so the right hand side is rebased to zero seconds.
    func splitAnimation(at localCut: Double) -> (left: ClipAnimation, right: ClipAnimation) {
        var left = ClipAnimation()
        var right = ClipAnimation()
        let cut = max(0, localCut)
        for channel in animation.channels {
            let valueAtCut = animation.value(for: channel.property, at: cut, fallback: baseValue(for: channel.property))
            var leftFrames = channel.keyframes.filter { $0.time < cut - (1.0 / 60.0) }
            leftFrames.append(ScalarKeyframe(time: cut, value: valueAtCut, interpolation: .linear))
            leftFrames.sort { $0.time < $1.time }

            var rightFrames = channel.keyframes
                .filter { $0.time > cut + (1.0 / 60.0) }
                .map { frame -> ScalarKeyframe in
                    var rebased = frame
                    rebased.id = UUID()
                    rebased.time -= cut
                    return rebased
                }
            rightFrames.insert(ScalarKeyframe(time: 0, value: valueAtCut, interpolation: .linear), at: 0)
            left.channels.append(AnimationChannel(property: channel.property, keyframes: leftFrames))
            right.channels.append(AnimationChannel(property: channel.property, keyframes: rightFrames))
        }
        return (left, right)
    }
}

struct StoredScene: Codable, Equatable, Identifiable {
    var id: UUID
    var document: NetVistaSceneDocument
    /// A rendered movie is optional. Editable scenes can live in a project
    /// before (or without ever) becoming timeline clips.
    var renderedURL: URL?
    var mediaAssetID: UUID

    init(id: UUID = UUID(), document: NetVistaSceneDocument, renderedURL: URL? = nil, mediaAssetID: UUID = UUID()) {
        self.id = id
        self.document = document
        self.renderedURL = renderedURL
        self.mediaAssetID = mediaAssetID
    }
}

struct ProjectFile: Codable {
    var schemaVersion: Int
    var title: String
    var media: [MediaAsset]
    var timeline: [TimelineClip]
    var scenes: [StoredScene]

    init(title: String, media: [MediaAsset], timeline: [TimelineClip], scenes: [StoredScene]) {
        // Schema 5 adds crop and native Ultra Key settings. Custom decoders
        // preserve projects made before those effects existed.
        schemaVersion = 5
        self.title = title
        self.media = media
        self.timeline = timeline
        self.scenes = scenes
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, title, media, timeline, scenes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        title = try c.decode(String.self, forKey: .title)
        media = try c.decodeIfPresent([MediaAsset].self, forKey: .media) ?? []
        timeline = try c.decodeIfPresent([TimelineClip].self, forKey: .timeline) ?? []
        scenes = try c.decodeIfPresent([StoredScene].self, forKey: .scenes) ?? []
        if schemaVersion < 4 {
            // Earlier projects encoded A1/A2 as tracks 2/3. In schema 4 each
            // media type has its own zero-based track namespace.
            for index in timeline.indices where timeline[index].kind == .audio {
                timeline[index].track = max(0, timeline[index].track - 2)
            }
        }
    }
}

private final class FlippedWorkspaceDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class EditorController: NSViewController {
    private var media: [MediaAsset] = []
    private var timelineClips: [TimelineClip] = []
    private var storedScenes: [StoredScene] = []
    private var selectedAssetID: UUID?
    private var selectedClipID: UUID?
    private var selectedClipIDs = Set<UUID>()
    private let player = AVPlayer()
    private let mediaList = NSStackView()
    private let timelineView = ProfessionalTimelineView()
    private let workspaceStack = NSStackView()
    private let previewView = AVPlayerView()
    private let programGuideOverlay = ProgramGuideOverlayView()
    private let viewerContainer = NSView()
    private let emptyPreviewLabel = NSTextField(labelWithString: "Import a video to start editing")
    private let statusLabel = NSTextField(labelWithString: "Import media or drag files from Finder onto Video 1.")
    private let pageLabel = NSTextField(labelWithString: "EDIT WORKSPACE")
    private let selectionLabel = NSTextField(labelWithString: "No timeline clip selected")
    private let inField = NSTextField(string: "0")
    private let outField = NSTextField(string: "0")
    private let brightnessSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let contrastSlider = NSSlider(value: 1, minValue: 0.25, maxValue: 2, target: nil, action: nil)
    private let saturationSlider = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let gammaSlider = NSSlider(value: 1, minValue: 0.4, maxValue: 2.5, target: nil, action: nil)
    private let temperatureSlider = NSSlider(value: 6500, minValue: 2000, maxValue: 10000, target: nil, action: nil)
    private let exposureSlider = NSSlider(value: 0, minValue: -3, maxValue: 3, target: nil, action: nil)
    private let tintSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    private let highlightsSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let shadowsSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let vibranceSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let hueSlider = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    private let blurSlider = NSSlider(value: 0, minValue: 0, maxValue: 20, target: nil, action: nil)
    private let sharpenSlider = NSSlider(value: 0, minValue: 0, maxValue: 4, target: nil, action: nil)
    private let vignetteSlider = NSSlider(value: 0, minValue: 0, maxValue: 1.5, target: nil, action: nil)
    private let monochromeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let sepiaSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let positionXSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let positionYSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let scaleSlider = NSSlider(value: 1, minValue: 0.25, maxValue: 3, target: nil, action: nil)
    private let rotationSlider = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let audioVolumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let dynamicInspector = NSStackView()
    private let projectTitle = NSTextField(string: "Untitled Project")
    private let playheadLabel = NSTextField(labelWithString: "00:00:00:00")
    private let projectUndoManager = UndoManager()
    private var pageButtons: [StudioPage: NSButton] = [:]
    private var currentPage: StudioPage = .edit
    private var bladeToolActive = false
    private var selectLinkedPairs = true
    private weak var timelineModeLabel: NSTextField?
    private weak var timelineLinkedButton: NSButton?
    private weak var timelineSnapButton: NSButton?
    private var timelinePreviewComposition: AVComposition?
    private var timelinePreviewVideoComposition: AVMutableVideoComposition?
    private var timelinePreviewAudioMix: AVMutableAudioMix?
    private var timelinePreviewItem: AVPlayerItem?
    private var timelinePreviewDuration: Double = 0
    private var timelinePreviewNeedsRebuild = true
    private var timelinePreviewSkippedNames: [String] = []
    private struct TimelinePreviewVideoRange {
        let clipID: UUID
        let logicalStart: Double
        let resolvedStart: Double
        let end: Double
        let track: Int
    }
    private var timelinePreviewVideoRanges: [TimelinePreviewVideoRange] = []
    private var timelineSeekGeneration = 0
    private struct PendingTimelineSeek {
        let item: AVPlayerItem
        let requestedTime: Double
        let renderTime: Double
        let playWhenReady: Bool
        let generation: Int
        let showsPreparingOverlay: Bool
    }
    private var pendingTimelineSeek: PendingTimelineSeek?
    private var timelineItemStatusObservation: NSKeyValueObservation?
    private var playerFailureObserver: NSObjectProtocol?
    private var previewingTimeline = false
    private var liveGradePreviewState: LiveGradePreviewState?
    private var playerTimeObserver: Any?
    private var playerEndObserver: NSObjectProtocol?
    private var activeKeyframeProperty: AnimatableProperty = .opacity
    private var colorStudioWindow: NSWindow?
    private var colorStudioController: ColorStudioViewController?
    private var liftColorControl = ColorWheelAdjustment()
    private var midtoneColorControl = ColorWheelAdjustment()
    private var gainColorControl = ColorWheelAdjustment()
    private var cubeLUTColorControl: ClipLUTSettings?
    private var advancedEffectControl = ClipEffects()
    private var effectsStudioWindow: NSWindow?
    private var effectsStudioController: EffectsStudioViewController?
    private var shareWindow: NSWindow?
    private var sharePanelController: SharePanelViewController?
    private var shareServer: LocalShareServer?
    private let appUpdateService = AppUpdateService()
    private weak var updateButton: NSButton?
    private var updateRequestActive = false
    private var exportWorkspaceController: ExportWorkspaceViewController?
    private var activeExportJob: TimelineExportJob?
    private var sceneEditorWindow: SceneEditorWindowController?
    private var activeSceneID: UUID?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(hex: "17191E").cgColor
        buildInterface()
        timelineView.controller = self
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        installPlayerTimeObserver()
    }

    deinit {
        shareServer?.stop()
        timelineItemStatusObservation?.invalidate()
        if let playerTimeObserver { player.removeTimeObserver(playerTimeObserver) }
        if let playerEndObserver { NotificationCenter.default.removeObserver(playerEndObserver) }
        if let playerFailureObserver { NotificationCenter.default.removeObserver(playerFailureObserver) }
    }

    private func buildInterface() {
        let root = NSStackView()
        root.orientation = .vertical; root.spacing = 0; root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor), root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        root.addArrangedSubview(header())

        let body = NSStackView(); body.orientation = .horizontal; body.spacing = 0
        body.addArrangedSubview(mediaPool())
        body.addArrangedSubview(divider())
        body.addArrangedSubview(centerWorkspace())
        body.addArrangedSubview(divider())
        body.addArrangedSubview(inspector())
        root.addArrangedSubview(body)
        root.addArrangedSubview(pageDock())
        root.addArrangedSubview(statusBar())
        body.setHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func header() -> NSView {
        let bar = NSStackView(); bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false; bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor(hex: "111317").cgColor
        bar.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let brand = NSTextField(labelWithString: "NetVista")
        brand.font = .systemFont(ofSize: 17, weight: .bold); brand.textColor = .white
        let accent = NSTextField(labelWithString: "STUDIO")
        accent.font = .systemFont(ofSize: 10, weight: .bold); accent.textColor = NSColor(hex: "F05B5E")
        projectTitle.placeholderString = "Project title"; projectTitle.font = .systemFont(ofSize: 12); projectTitle.textColor = .white; projectTitle.backgroundColor = NSColor(hex: "242A33"); projectTitle.isBordered = false; projectTitle.focusRingType = .none; projectTitle.widthAnchor.constraint(equalToConstant: 220).isActive = true
        bar.addArrangedSubview(brand); bar.addArrangedSubview(accent)
        bar.addArrangedSubview(spacer()); bar.addArrangedSubview(projectTitle)
        bar.addArrangedSubview(button("↶", #selector(undoEdit)))
        bar.addArrangedSubview(button("↷", #selector(redoEdit)))
        bar.addArrangedSubview(button("Open", #selector(openProjectPicker)))
        let share = button("Share", #selector(openShareStudio)); share.contentTintColor = NSColor(hex: "43D7C2"); bar.addArrangedSubview(share)
        let update = button("Update", #selector(checkForUpdates)); update.toolTip = "Check GitHub for a newer NetVista Studio beta"; bar.addArrangedSubview(update); updateButton = update
        let save = button("Save your work", #selector(saveProject)); save.contentTintColor = .systemBlue; bar.addArrangedSubview(save)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        return bar
    }

    private func pageDock() -> NSView {
        let rail = NSStackView(); rail.orientation = .horizontal; rail.alignment = .centerY; rail.spacing = 14; rail.wantsLayer = true; rail.layer?.backgroundColor = NSColor(hex: "111317").cgColor
        rail.heightAnchor.constraint(equalToConstant: 42).isActive = true
        rail.addArrangedSubview(spacer())
        for page in StudioPage.allCases {
            let item = NSButton(title: "\(page.icon)  \(page.rawValue)", target: self, action: #selector(changePage(_:)))
            item.identifier = NSUserInterfaceItemIdentifier(page.rawValue); item.bezelStyle = .texturedRounded; item.alignment = .center; item.font = .systemFont(ofSize: 11, weight: .medium); item.widthAnchor.constraint(equalToConstant: 78).isActive = true
            rail.addArrangedSubview(item); pageButtons[page] = item
        }
        rail.addArrangedSubview(spacer())
        rail.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
        selectPage(.edit)
        return rail
    }

    private func mediaPool() -> NSView {
        let panel = NSStackView(); panel.orientation = .vertical; panel.spacing = 0; panel.wantsLayer = true; panel.layer?.backgroundColor = NSColor(hex: "20232A").cgColor; panel.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let title = NSStackView(); title.orientation = .horizontal; title.alignment = .centerY; title.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10); title.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let label = NSTextField(labelWithString: "MEDIA POOL"); label.font = .systemFont(ofSize: 11, weight: .bold); title.addArrangedSubview(label); title.addArrangedSubview(spacer()); title.addArrangedSubview(button("Add all", #selector(addAllMediaToTimeline))); title.addArrangedSubview(button("Import", #selector(importMedia)))
        panel.addArrangedSubview(title); panel.addArrangedSubview(divider())
        mediaList.orientation = .vertical; mediaList.spacing = 5; mediaList.alignment = .width; mediaList.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = mediaList
        NSLayoutConstraint.activate([
            mediaList.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            mediaList.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            mediaList.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            mediaList.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),
            mediaList.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        panel.addArrangedSubview(scroll)
        panel.addArrangedSubview(divider())
        let footer = NSStackView(); footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 7; footer.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8); footer.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let remove = button("Remove selected media", #selector(removeSelectedMedia)); remove.contentTintColor = .systemRed
        footer.addArrangedSubview(remove)
        panel.addArrangedSubview(footer)
        return panel
    }

    private func centerWorkspace() -> NSView {
        let center = NSStackView(); center.orientation = .vertical; center.spacing = 0; center.wantsLayer = true; center.layer?.backgroundColor = NSColor(hex: "181B21").cgColor
        let info = NSStackView(); info.orientation = .horizontal; info.alignment = .centerY; info.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12); info.heightAnchor.constraint(equalToConstant: 36).isActive = true
        pageLabel.font = .systemFont(ofSize: 11, weight: .bold); pageLabel.textColor = .secondaryLabelColor; info.addArrangedSubview(pageLabel); info.addArrangedSubview(spacer())
        center.addArrangedSubview(info)
        workspaceStack.orientation = .vertical; workspaceStack.spacing = 0
        timelineView.translatesAutoresizingMaskIntoConstraints = false
        timelineView.setContentHuggingPriority(.defaultLow, for: .vertical)
        timelineView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let timelineMinimum = timelineView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        timelineMinimum.priority = .init(999)
        let timelineIdeal = timelineView.heightAnchor.constraint(equalToConstant: 300)
        timelineIdeal.priority = .init(750)
        NSLayoutConstraint.activate([timelineMinimum, timelineIdeal])
        center.addArrangedSubview(workspaceStack)
        rebuildWorkspace()
        return center
    }
    private func rebuildWorkspace() {
        workspaceStack.arrangedSubviews.forEach { workspaceStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        timelineView.bladeMode = bladeToolActive
        timelineView.selectsLinkedPairs = selectLinkedPairs
        // Keep the program monitor visible on every workspace so an edit is
        // never hidden just because the user changes tools.
        workspaceStack.addArrangedSubview(configuredViewer())
        workspaceStack.addArrangedSubview(transportBar())
        if currentPage == .export { workspaceStack.addArrangedSubview(scrollableWorkspacePanel(configuredExportWorkspace())) }
        else if currentPage == .scene3D { workspaceStack.addArrangedSubview(scrollableWorkspacePanel(sceneLaunchWorkspace())) }
        workspaceStack.addArrangedSubview(timelineBar())
        workspaceStack.addArrangedSubview(timelineView)
    }
    /// Page-specific controls can be much taller than a laptop window. Keeping
    /// them in one compact native scroller leaves both the real-time viewer and
    /// timeline usable on every page without breaking AppKit constraints.
    private func scrollableWorkspacePanel(_ content: NSView) -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(hex: "171B22")
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let document = FlippedWorkspaceDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document

        let minimum = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 72)
        minimum.priority = .init(999)
        let ideal = scroll.heightAnchor.constraint(equalToConstant: 96)
        ideal.priority = .init(750)
        NSLayoutConstraint.activate([
            minimum, ideal,
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        return scroll
    }
    private func configuredExportWorkspace() -> NSView {
        if exportWorkspaceController == nil {
            let controller = ExportWorkspaceViewController()
            controller.onStartExport = { [weak self] options in self?.beginNativeExport(options: options) }
            controller.onCancelExport = { [weak self] in self?.cancelNativeExport() }
            addChild(controller)
            exportWorkspaceController = controller
        }
        return exportWorkspaceController!.view
    }
    private func sceneLaunchWorkspace() -> NSView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .centerX
        card.spacing = 10
        card.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(hex: "171B22").cgColor
        let icon = NSTextField(labelWithString: "◇")
        icon.font = .systemFont(ofSize: 31, weight: .light)
        icon.textColor = .systemTeal
        let title = NSTextField(labelWithString: "Native 3D Scene Workspace")
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.textColor = .white
        let detail = NSTextField(wrappingLabelWithString: "Build with imported 3D models, video planes, cameras, lighting, shadows and green-screen removal. Save editable scenes inside your project at any time. Rendering a timeline clip is optional.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 3
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        let open = button("Continue Current Scene", #selector(open3DSceneEditor))
        open.contentTintColor = .systemTeal
        actions.addArrangedSubview(open)
        let newScene = button("New 3D Scene", #selector(startNew3DScene))
        newScene.contentTintColor = .systemBlue
        actions.addArrangedSubview(newScene)
        let saveScene = button("Save Scene in Project…", #selector(saveProject))
        saveScene.contentTintColor = .systemGreen
        actions.addArrangedSubview(saveScene)
        let selected = button("Edit selected 3D clip", #selector(editSelected3DScene))
        selected.isEnabled = selectedSceneID() != nil
        actions.addArrangedSubview(selected)
        card.addArrangedSubview(icon)
        card.addArrangedSubview(title)
        card.addArrangedSubview(detail)
        card.addArrangedSubview(actions)
        if storedScenes.isEmpty {
            let empty = NSTextField(labelWithString: "No editable scenes saved in this project yet.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            card.addArrangedSubview(empty)
        } else {
            let savedTitle = NSTextField(labelWithString: "SAVED EDITABLE SCENES")
            savedTitle.font = .systemFont(ofSize: 10, weight: .bold)
            savedTitle.textColor = .secondaryLabelColor
            card.addArrangedSubview(savedTitle)
            card.addArrangedSubview(savedSceneListView())
        }
        return card
    }

    /// Compact, scrollable project-scene list used by the 3D workspace. The
    /// list is independent of timeline clips, so unrendered scenes remain easy
    /// to find and reopen.
    private func savedSceneListView() -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .width
        list.spacing = 5
        list.translatesAutoresizingMaskIntoConstraints = false
        for stored in storedScenes {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor(hex: "222832").cgColor
            row.layer?.cornerRadius = 6

            let name = NSTextField(labelWithString: stored.document.title)
            name.font = .systemFont(ofSize: 11, weight: .medium)
            name.textColor = .white
            name.lineBreakMode = .byTruncatingTail
            row.addArrangedSubview(name)
            row.addArrangedSubview(spacer())

            let state = NSTextField(labelWithString: stored.renderedURL == nil ? "EDITABLE" : "EDITABLE + CLIP")
            state.font = .systemFont(ofSize: 9, weight: .bold)
            state.textColor = stored.renderedURL == nil ? .systemTeal : .systemGreen
            row.addArrangedSubview(state)

            let open = button("Open", #selector(openSavedScene(_:)))
            open.identifier = NSUserInterfaceItemIdentifier(stored.id.uuidString)
            row.addArrangedSubview(open)
            list.addArrangedSubview(row)
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: min(112, max(42, CGFloat(storedScenes.count) * 39))).isActive = true
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }
    private func configuredViewer() -> NSView {
        if viewerContainer.subviews.isEmpty {
            viewerContainer.wantsLayer = true; viewerContainer.layer?.backgroundColor = NSColor.black.cgColor
            viewerContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
            viewerContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            let viewerMinimum = viewerContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
            viewerMinimum.priority = .init(999)
            let viewerIdeal = viewerContainer.heightAnchor.constraint(equalToConstant: 280)
            viewerIdeal.priority = .init(500)
            NSLayoutConstraint.activate([viewerMinimum, viewerIdeal])
            previewView.translatesAutoresizingMaskIntoConstraints = false; previewView.controlsStyle = .floating; previewView.videoGravity = .resizeAspect
            programGuideOverlay.translatesAutoresizingMaskIntoConstraints = false
            emptyPreviewLabel.translatesAutoresizingMaskIntoConstraints = false; emptyPreviewLabel.font = .systemFont(ofSize: 14, weight: .medium); emptyPreviewLabel.textColor = NSColor(hex: "9DA6B5"); emptyPreviewLabel.alignment = .center
            viewerContainer.addSubview(previewView); viewerContainer.addSubview(programGuideOverlay); viewerContainer.addSubview(emptyPreviewLabel)
            NSLayoutConstraint.activate([
                previewView.leadingAnchor.constraint(equalTo: viewerContainer.leadingAnchor), previewView.trailingAnchor.constraint(equalTo: viewerContainer.trailingAnchor), previewView.topAnchor.constraint(equalTo: viewerContainer.topAnchor), previewView.bottomAnchor.constraint(equalTo: viewerContainer.bottomAnchor),
                programGuideOverlay.leadingAnchor.constraint(equalTo: viewerContainer.leadingAnchor), programGuideOverlay.trailingAnchor.constraint(equalTo: viewerContainer.trailingAnchor), programGuideOverlay.topAnchor.constraint(equalTo: viewerContainer.topAnchor), programGuideOverlay.bottomAnchor.constraint(equalTo: viewerContainer.bottomAnchor),
                emptyPreviewLabel.centerXAnchor.constraint(equalTo: viewerContainer.centerXAnchor), emptyPreviewLabel.centerYAnchor.constraint(equalTo: viewerContainer.centerYAnchor)
            ])
        }
        previewView.player = player
        return viewerContainer
    }
    private func installPlayerTimeObserver() {
        guard playerTimeObserver == nil else { return }
        let interval = CMTime(value: 1, timescale: 30)
        playerTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, self.previewingTimeline else { return }
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite, seconds >= 0 else { return }
            self.timelineView.updatePlaybackPlayhead(seconds)
            self.timelinePlayheadMoved(to: seconds)
            self.keepPlayheadVisible()
        }
    }
    private func keepPlayheadVisible() {
        timelineView.keepPlayheadVisible()
    }
    private func clearTimelineItemObservers() {
        pendingTimelineSeek = nil
        if let playerEndObserver { NotificationCenter.default.removeObserver(playerEndObserver) }
        playerEndObserver = nil
        if let playerFailureObserver { NotificationCenter.default.removeObserver(playerFailureObserver) }
        playerFailureObserver = nil
        timelineItemStatusObservation?.invalidate()
        timelineItemStatusObservation = nil
    }
    private func observeTimelineItem(_ item: AVPlayerItem) {
        clearTimelineItemObservers()
        playerEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            guard let self, let item, self.player.currentItem === item, self.previewingTimeline else { return }
            self.player.pause()
            self.timelineView.updatePlaybackPlayhead(self.timelinePreviewDuration)
            self.timelinePlayheadMoved(to: self.timelinePreviewDuration)
            self.status("Reached the end of the timeline.")
        }
        playerFailureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self, weak item] note in
            guard let self, let item, self.player.currentItem === item, self.previewingTimeline else { return }
            self.pendingTimelineSeek = nil
            let failure = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error) ?? item.error
            self.player.pause()
            self.emptyPreviewLabel.stringValue = "Timeline preview failed\n\(failure?.localizedDescription ?? "The media decoder stopped.")"
            self.emptyPreviewLabel.isHidden = false
            self.status("Timeline preview failed: \(failure?.localizedDescription ?? "the media decoder stopped").")
        }
        timelineItemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            DispatchQueue.main.async {
                guard let self, let item, self.player.currentItem === item, self.previewingTimeline else { return }
                switch item.status {
                case .readyToPlay:
                    if self.pendingTimelineSeek?.item === item {
                        self.performPendingTimelineSeekIfReady(for: item)
                    } else {
                        self.emptyPreviewLabel.isHidden = true
                    }
                case .failed:
                    self.pendingTimelineSeek = nil
                    self.player.pause()
                    let reason = item.error?.localizedDescription ?? "The media could not be decoded."
                    self.emptyPreviewLabel.stringValue = "Timeline preview failed\n\(reason)"
                    self.emptyPreviewLabel.isHidden = false
                    self.status("Timeline preview failed: \(reason)")
                case .unknown:
                    self.emptyPreviewLabel.stringValue = "Preparing timeline preview…"
                    self.emptyPreviewLabel.isHidden = false
                @unknown default:
                    break
                }
            }
        }
    }
    private func transportBar() -> NSView {
        let bar = NSStackView(); bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 7; bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor(hex: "15181D").cgColor; bar.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let monitor = NSTextField(labelWithString: "PROGRAM MONITOR"); monitor.font = .systemFont(ofSize: 10, weight: .bold); monitor.textColor = .secondaryLabelColor
        playheadLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); playheadLabel.textColor = .white
        bar.addArrangedSubview(monitor); bar.addArrangedSubview(spacer())
        bar.addArrangedSubview(button("‹", #selector(stepBackward)))
        let play = button("Play", #selector(togglePlayback)); play.contentTintColor = .systemBlue; bar.addArrangedSubview(play)
        bar.addArrangedSubview(button("Stop", #selector(stopPlayback)))
        bar.addArrangedSubview(button("›", #selector(stepForward)))
        bar.addArrangedSubview(spacer()); bar.addArrangedSubview(playheadLabel)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        return bar
    }
    private func timelineBar() -> NSView {
        let bar = NSStackView(); bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 6; bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor(hex: "1C2027").cgColor; bar.heightAnchor.constraint(equalToConstant: 34).isActive = true
        func tool(_ title: String, _ action: Selector, _ help: String) -> NSButton {
            let item = button(title, action)
            item.toolTip = help
            return item
        }
        let name = NSTextField(labelWithString: "TIMELINE 1"); name.font = .systemFont(ofSize: 10, weight: .bold); name.textColor = .white
        let mode = NSTextField(labelWithString: bladeToolActive ? "C  BLADE" : "V  SELECT"); mode.font = .systemFont(ofSize: 9, weight: .bold); mode.textColor = bladeToolActive ? .systemOrange : .systemBlue
        timelineModeLabel = mode
        bar.addArrangedSubview(name); bar.addArrangedSubview(divider()); bar.addArrangedSubview(mode)
        bar.addArrangedSubview(tool("V", #selector(selectTool), "Selection Tool (V)"))
        bar.addArrangedSubview(tool("C", #selector(activateBladeTool), "Blade Tool (C)"))
        let linked = tool(selectLinkedPairs ? "Link" : "Solo", #selector(toggleSelectionMode), "Toggle linked video and audio selection"); linked.contentTintColor = selectLinkedPairs ? .systemBlue : .secondaryLabelColor; timelineLinkedButton = linked; bar.addArrangedSubview(linked)
        let snap = tool(timelineView.snappingEnabled ? "Snap" : "No Snap", #selector(toggleTimelineSnapping), "Toggle timeline snapping (S)"); snap.contentTintColor = timelineView.snappingEnabled ? .systemBlue : .secondaryLabelColor; timelineSnapButton = snap; bar.addArrangedSubview(snap)
        bar.addArrangedSubview(spacer())
        bar.addArrangedSubview(tool("−", #selector(zoomTimelineOut), "Zoom out around the playhead"))
        bar.addArrangedSubview(tool("Fit", #selector(fitTimeline), "Fit the whole edit; press again to restore the previous zoom"))
        bar.addArrangedSubview(tool("+", #selector(zoomTimelineIn), "Zoom in around the playhead"))
        bar.addArrangedSubview(tool("H−", #selector(decreaseTimelineTrackHeight), "Make video and audio tracks shorter"))
        bar.addArrangedSubview(tool("H+", #selector(increaseTimelineTrackHeight), "Make video and audio tracks taller"))
        let delete = tool("⌫", #selector(removeClip), "Delete selected timeline clips"); delete.contentTintColor = .systemRed; bar.addArrangedSubview(delete)
        switch currentPage {
        case .media:
            let importButton = tool("Import", #selector(importMedia), "Import media and add it to the timeline"); importButton.contentTintColor = .systemBlue; bar.addArrangedSubview(importButton)
        case .cut, .edit:
            let cut = tool("Cut", #selector(cutAtPlayhead), "Cut selected clips at the playhead"); cut.contentTintColor = .systemOrange; bar.addArrangedSubview(cut)
        case .effects:
            let studio = tool("Effects", #selector(openEffectsStudio), "Open Effect Controls"); studio.contentTintColor = .systemPurple; bar.addArrangedSubview(studio)
        case .color:
            let studio = tool("Color", #selector(openColorStudio), "Open Color Studio"); studio.contentTintColor = .systemOrange; bar.addArrangedSubview(studio)
        case .audio:
            let volume = tool("Volume", #selector(applyAudioVolume), "Apply the Inspector volume to selected audio"); volume.contentTintColor = .systemGreen; bar.addArrangedSubview(volume)
        case .scene3D:
            let scene = tool("3D", #selector(open3DSceneEditor), "Open the native 3D Scene Editor"); scene.contentTintColor = .systemTeal; bar.addArrangedSubview(scene)
        case .export:
            let render = tool("Export", #selector(exportFromCurrentSettings), "Choose a file and export the timeline"); render.contentTintColor = .systemBlue; bar.addArrangedSubview(render)
        }
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        return bar
    }
    private func updateTimelineToolbarState() {
        timelineModeLabel?.stringValue = bladeToolActive ? "C  BLADE" : "V  SELECT"
        timelineModeLabel?.textColor = bladeToolActive ? .systemOrange : .systemBlue
        timelineLinkedButton?.title = selectLinkedPairs ? "Link" : "Solo"
        timelineLinkedButton?.contentTintColor = selectLinkedPairs ? .systemBlue : .secondaryLabelColor
        timelineSnapButton?.title = timelineView.snappingEnabled ? "Snap" : "No Snap"
        timelineSnapButton?.contentTintColor = timelineView.snappingEnabled ? .systemBlue : .secondaryLabelColor
    }
    private func workspaceCard(title: String, body: String) -> NSView {
        let card = NSStackView(); card.orientation = .vertical; card.alignment = .leading; card.spacing = 12; card.wantsLayer = true; card.layer?.backgroundColor = NSColor(hex: "202833").cgColor
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 15, weight: .bold); heading.textColor = .white
        let text = NSTextField(wrappingLabelWithString: body); text.font = .systemFont(ofSize: 12); text.textColor = .secondaryLabelColor
        card.addArrangedSubview(heading); card.addArrangedSubview(text); card.addArrangedSubview(spacer()); card.edgeInsets = NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)
        return card
    }

    private func inspector() -> NSView {
        let panel = NSStackView(); panel.orientation = .vertical; panel.alignment = .leading; panel.spacing = 8; panel.wantsLayer = true; panel.layer?.backgroundColor = NSColor(hex: "20232A").cgColor; panel.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let title = NSTextField(labelWithString: "INSPECTOR"); title.font = .systemFont(ofSize: 11, weight: .bold); panel.addArrangedSubview(title)
        panel.addArrangedSubview(divider())
        selectionLabel.font = .systemFont(ofSize: 12, weight: .semibold); selectionLabel.lineBreakMode = .byTruncatingMiddle; selectionLabel.maximumNumberOfLines = 2; panel.addArrangedSubview(selectionLabel)
        dynamicInspector.orientation = .vertical; dynamicInspector.alignment = .width; dynamicInspector.spacing = 8
        dynamicInspector.translatesAutoresizingMaskIntoConstraints = false
        let inspectorScroll = NSScrollView(); inspectorScroll.drawsBackground = false; inspectorScroll.hasVerticalScroller = true; inspectorScroll.autohidesScrollers = true; inspectorScroll.documentView = dynamicInspector
        panel.addArrangedSubview(inspectorScroll)
        NSLayoutConstraint.activate([
            dynamicInspector.leadingAnchor.constraint(equalTo: inspectorScroll.contentView.leadingAnchor),
            dynamicInspector.trailingAnchor.constraint(equalTo: inspectorScroll.contentView.trailingAnchor),
            dynamicInspector.topAnchor.constraint(equalTo: inspectorScroll.contentView.topAnchor),
            dynamicInspector.bottomAnchor.constraint(greaterThanOrEqualTo: inspectorScroll.contentView.bottomAnchor),
            dynamicInspector.widthAnchor.constraint(equalTo: inspectorScroll.contentView.widthAnchor)
        ])
        let note = NSTextField(wrappingLabelWithString: "Drop clips on the same track to place them side-by-side, or use V2/V3 for an overlay. ⌘-click selects more than one; Delete removes the visible selection."); note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor; panel.addArrangedSubview(note)
        panel.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        rebuildInspector()
        return panel
    }

    private func statusBar() -> NSView { let bar = NSStackView(); bar.orientation = .horizontal; bar.alignment = .centerY; bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor(hex: "111317").cgColor; bar.heightAnchor.constraint(equalToConstant: 26).isActive = true; statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor; bar.addArrangedSubview(statusLabel); bar.addArrangedSubview(spacer()); bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12); return bar }
    private func divider() -> NSView { let line = NSView(); line.wantsLayer = true; line.layer?.backgroundColor = NSColor(hex: "363B46").cgColor; line.widthAnchor.constraint(equalToConstant: 1).isActive = true; return line }
    private func spacer() -> NSView { let v = NSView(); v.setContentHuggingPriority(.defaultLow, for: .horizontal); v.setContentHuggingPriority(.defaultLow, for: .vertical); return v }
    private func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; b.font = .systemFont(ofSize: 11, weight: .medium); return b }
    private func fieldLabel(_ text: String) -> NSTextField { let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: 9, weight: .bold); l.textColor = .secondaryLabelColor; return l }
    private func replaceTimeline(_ next: [TimelineClip], action: String, selection requestedSelection: Set<UUID>? = nil, primary requestedPrimary: UUID? = nil, playhead requestedPlayhead: Double? = nil) {
        TimelineLiveEffectStore.shared.clear()
        let previous = timelineClips
        let previousSelection = selectedClipIDs
        let previousPrimary = selectedClipID
        let previousPlayhead = timelineView.currentPlayheadTime
        timelineClips = next
        let validIDs = Set(next.map(\.id))
        if let requestedSelection {
            selectedClipIDs = requestedSelection.intersection(validIDs)
            selectedClipID = requestedPrimary.flatMap { selectedClipIDs.contains($0) ? $0 : nil } ?? selectedClipIDs.first
            updateSelectionLabel()
        } else {
            selectedClipIDs.formIntersection(validIDs)
            if let selectedClipID, !selectedClipIDs.contains(selectedClipID) { self.selectedClipID = selectedClipIDs.first }
            if selectedClipIDs.isEmpty { selectedClipID = nil }
        }
        if let requestedPlayhead {
            timelineView.updatePlaybackPlayhead(max(0, requestedPlayhead))
            timelinePlayheadMoved(to: max(0, requestedPlayhead))
        }
        timelinePreviewNeedsRebuild = true
        timelinePreviewComposition = nil
        timelinePreviewVideoComposition = nil
        timelinePreviewAudioMix = nil
        timelinePreviewItem = nil
        timelinePreviewDuration = 0
        timelinePreviewSkippedNames = []
        timelinePreviewVideoRanges = []
        timelineSeekGeneration += 1
        clearTimelineItemObservers()
        if previewingTimeline { player.pause(); previewingTimeline = false }
        projectUndoManager.registerUndo(withTarget: self) { target in
            target.replaceTimeline(previous, action: action, selection: previousSelection, primary: previousPrimary, playhead: previousPlayhead)
        }
        projectUndoManager.setActionName(action)
        reloadTimeline()
        if !next.isEmpty {
            let end = next.map { $0.timelineStart + clipDuration($0) }.max() ?? 0
            previewTimeline(at: min(requestedPlayhead ?? previousPlayhead, end))
        } else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            emptyPreviewLabel.stringValue = "Import media or drag a clip onto the timeline"
            emptyPreviewLabel.isHidden = false
        }
    }
    @objc private func undoEdit() { guard projectUndoManager.canUndo else { status("Nothing to undo."); return }; projectUndoManager.undo(); rebuildInspector(); status("Undid last edit.") }
    @objc private func redoEdit() { guard projectUndoManager.canRedo else { status("Nothing to redo."); return }; projectUndoManager.redo(); rebuildInspector(); status("Redid last edit.") }

    private func rebuildInspector() {
        dynamicInspector.arrangedSubviews.forEach { dynamicInspector.removeArrangedSubview($0); $0.removeFromSuperview() }
        switch currentPage {
        case .edit, .cut:
            dynamicInspector.addArrangedSubview(button("Select Tool", #selector(selectTool)))
            if currentPage == .cut { let blade = button("Blade Tool", #selector(activateBladeTool)); blade.contentTintColor = .systemOrange; dynamicInspector.addArrangedSubview(blade) }
            dynamicInspector.addArrangedSubview(fieldLabel("IN POINT (SECONDS)")); dynamicInspector.addArrangedSubview(inField)
            dynamicInspector.addArrangedSubview(fieldLabel("OUT POINT (0 = END)")); dynamicInspector.addArrangedSubview(outField)
            dynamicInspector.addArrangedSubview(button("Apply trim", #selector(applyTrim)))
            let cut = button("Cut at playhead", #selector(cutAtPlayhead)); cut.contentTintColor = .systemOrange; dynamicInspector.addArrangedSubview(cut)
            let remove = button("Remove selected clip", #selector(removeClip)); remove.contentTintColor = .systemRed; dynamicInspector.addArrangedSubview(remove)
        case .color:
            dynamicInspector.addArrangedSubview(NSTextField(wrappingLabelWithString: "Color controls now open in their own resizable native Color Studio window, so every setting stays on screen."))
            let studio = button("Open Color Studio", #selector(openColorStudio)); studio.contentTintColor = .systemOrange; dynamicInspector.addArrangedSubview(studio)
            dynamicInspector.addArrangedSubview(fieldLabel("The studio changes the selected video clip or every ⌘-selected video clip."))
            dynamicInspector.addArrangedSubview(button("Reset grade", #selector(resetColorGrade)))
        case .audio:
            dynamicInspector.addArrangedSubview(NSTextField(wrappingLabelWithString: "Use Selection: Single in the timeline bar (or ⌥-click) to move only sound. Use Linked to move video and sound together. Drag audio vertically to A1, A2, A3 or any new audio layer you need."))
            audioVolumeSlider.target = self; audioVolumeSlider.action = #selector(previewAudioVolume)
            dynamicInspector.addArrangedSubview(sliderRow("VOLUME", audioVolumeSlider))
            let apply = button("Apply volume", #selector(applyAudioVolume)); apply.contentTintColor = .systemGreen; dynamicInspector.addArrangedSubview(apply)
            dynamicInspector.addArrangedSubview(button("Mute selected audio", #selector(muteSelectedAudio)))
            let detach = button("Detach selected audio", #selector(detachSelectedAudio)); detach.contentTintColor = .systemOrange; dynamicInspector.addArrangedSubview(detach)
            dynamicInspector.addArrangedSubview(button("Select all timeline audio", #selector(selectAllTimeline)))
        case .effects:
            dynamicInspector.addArrangedSubview(NSTextField(wrappingLabelWithString: "Transforms, effects, and clip-local keyframes now open in their own resizable native Effects Studio window."))
            let studio = button("Open Effects Studio", #selector(openEffectsStudio)); studio.contentTintColor = .systemPurple; dynamicInspector.addArrangedSubview(studio)
            let keyStatus = NSTextField(wrappingLabelWithString: keyframeSummary()); keyStatus.font = .systemFont(ofSize: 10); keyStatus.textColor = .secondaryLabelColor; dynamicInspector.addArrangedSubview(keyStatus)
            dynamicInspector.addArrangedSubview(button("Reset selected effects", #selector(resetSelectedGrades)))
        case .media:
            dynamicInspector.addArrangedSubview(NSTextField(wrappingLabelWithString: "Import adds clips to the Media Pool and the timeline. Select any Media Pool clip and add another copy whenever you need it."))
            let add = button("Add selected to timeline", #selector(addSelectedAssetToTimeline)); add.contentTintColor = .systemBlue; dynamicInspector.addArrangedSubview(add)
            dynamicInspector.addArrangedSubview(button("Add all to timeline", #selector(addAllMediaToTimeline)))
        case .scene3D:
            dynamicInspector.addArrangedSubview(NSTextField(wrappingLabelWithString: "3D scenes are saved as editable data inside your NetVista Studio project. You can import your own models and keep working without rendering. Render Clip is only needed when you want the scene on the video timeline."))
            let open = button("Continue Current Scene", #selector(open3DSceneEditor)); open.contentTintColor = .systemTeal; dynamicInspector.addArrangedSubview(open)
            let newScene = button("New 3D Scene", #selector(startNew3DScene)); newScene.contentTintColor = .systemBlue; dynamicInspector.addArrangedSubview(newScene)
            let saveScene = button("Save Editable Scene in Project…", #selector(saveProject)); saveScene.contentTintColor = .systemGreen; dynamicInspector.addArrangedSubview(saveScene)
            let edit = button("Edit selected 3D scene", #selector(editSelected3DScene)); edit.isEnabled = selectedSceneID() != nil; dynamicInspector.addArrangedSubview(edit)
            dynamicInspector.addArrangedSubview(fieldLabel("SCENES IN THIS PROJECT: \(storedScenes.count)"))
            if storedScenes.isEmpty {
                let empty = NSTextField(wrappingLabelWithString: "Your first scene will appear here when you save the project. No video render is required.")
                empty.font = .systemFont(ofSize: 10)
                empty.textColor = .tertiaryLabelColor
                dynamicInspector.addArrangedSubview(empty)
            } else {
                for stored in storedScenes {
                    let suffix = stored.renderedURL == nil ? " — editable only" : " — timeline-ready"
                    let sceneButton = button("Open \(stored.document.title)\(suffix)", #selector(openSavedScene(_:)))
                    sceneButton.identifier = NSUserInterfaceItemIdentifier(stored.id.uuidString)
                    dynamicInspector.addArrangedSubview(sceneButton)
                }
            }
        case .export:
            dynamicInspector.addArrangedSubview(NSTextField(wrappingLabelWithString: "The native renderer supports 1080p, 4K and 8K with MP4 or MOV. It includes timeline placement, trims, layers, transform keyframes and mixed audio without requiring FFmpeg."))
            let export = button("Choose File and Export", #selector(exportFromCurrentSettings)); export.contentTintColor = .systemBlue; dynamicInspector.addArrangedSubview(export)
            let cancel = button("Cancel active export", #selector(cancelNativeExport)); cancel.isEnabled = activeExportJob != nil; dynamicInspector.addArrangedSubview(cancel)
        }
    }
    private let transformKeyframeProperties: [AnimatableProperty] = [.positionX, .positionY, .scale, .rotation, .opacity]
    private var activeKeyframeInterpolation: KeyframeInterpolation = .easeInOut
    private func inspectorHeading(_ text: String) -> NSTextField { let label = fieldLabel(text); label.textColor = NSColor(hex: "7FA9FF"); label.font = .systemFont(ofSize: 10, weight: .bold); return label }
    private func sliderRow(_ title: String, _ slider: NSSlider) -> NSStackView { let row = NSStackView(); row.orientation = .vertical; row.alignment = .width; row.spacing = 3; row.addArrangedSubview(fieldLabel(title)); row.addArrangedSubview(slider); return row }
    private func compactButtonRow(_ buttons: [NSButton]) -> NSStackView { let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 5; buttons.forEach { row.addArrangedSubview($0) }; return row }

    @objc private func changePage(_ sender: NSButton) { if let name = sender.identifier?.rawValue, let page = StudioPage(rawValue: name) { selectPage(page) } }
    private func selectPage(_ page: StudioPage) {
        currentPage = page
        pageLabel.stringValue = "\(page.rawValue.uppercased()) WORKSPACE"
        bladeToolActive = page == .cut
        timelineView.bladeMode = bladeToolActive
        for (key, button) in pageButtons { button.contentTintColor = key == page ? .systemBlue : .secondaryLabelColor }
        rebuildInspector(); rebuildWorkspace(); status("\(page.rawValue) workspace opened.")
        if page == .color || page == .effects || page == .scene3D {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if page == .color { self.openColorStudio() }
                else if page == .effects { self.openEffectsStudio() }
                else { self.open3DSceneEditor() }
            }
        }
    }

    @objc private func importMedia() {
        let panel = NSOpenPanel(); panel.title = "Import media and add it to the timeline"; panel.allowsMultipleSelection = true; panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie]
        setDownloadsAsInitialDirectory(for: panel)
        guard panel.runModal() == .OK else { return }; addMedia(panel.urls, addToTimeline: true)
    }
    @objc private func addAllMediaToTimeline() {
        guard !media.isEmpty else { status("Import media first."); return }
        addAssetsToTimeline(media, at: nextTimelineStart(for: 0, kind: .video), track: 0, action: "Add All Clips")
    }
    @objc private func addSelectedAssetToTimeline() {
        guard let id = selectedAssetID, let asset = media.first(where: { $0.id == id }) else { status("Select a Media Pool clip first."); return }
        addAssetsToTimeline([asset], at: nil, track: 0, action: "Add Clip")
    }
    @objc private func selectTool() {
        bladeToolActive = false
        timelineView.bladeMode = false
        updateTimelineToolbarState()
        status("Select Tool active. Drag a clip to move it.")
    }
    private func changeTimelineZoom(to scale: CGFloat, fit: Bool = false) {
        if fit { timelineView.toggleFit() }
        else { timelineView.setZoom(scale, anchorTime: timelineView.currentPlayheadTime) }
        status(fit ? "Timeline fitted to the available width." : "Timeline zoom: \(Int((timelineView.zoomScale / 40 * 100).rounded()))%")
    }
    @objc private func zoomTimelineIn() { changeTimelineZoom(to: timelineView.zoomScale * 1.35) }
    @objc private func zoomTimelineOut() { changeTimelineZoom(to: timelineView.zoomScale / 1.35) }
    @objc private func fitTimeline() {
        changeTimelineZoom(to: timelineView.fittedZoom(for: timelineView.bounds.width), fit: true)
    }
    @objc private func toggleTimelineSnapping() {
        timelineView.snappingEnabled.toggle()
        updateTimelineToolbarState()
        status(timelineView.snappingEnabled ? "Timeline snapping is on." : "Timeline snapping is off; edits still stay frame-accurate.")
    }
    @objc private func decreaseTimelineTrackHeight() { timelineView.adjustTrackHeight(by: -8) }
    @objc private func increaseTimelineTrackHeight() { timelineView.adjustTrackHeight(by: 8) }
    func timelineSelectToolRequested() { selectTool() }
    func timelineBladeToolRequested() { activateBladeTool() }
    func timelineSnappingRequested() { toggleTimelineSnapping() }
    func timelinePlaybackRequested() { togglePlayback() }
    @objc private func toggleSelectionMode() {
        selectLinkedPairs.toggle()
        timelineView.selectsLinkedPairs = selectLinkedPairs
        updateTimelineToolbarState()
        status(selectLinkedPairs ? "Linked selection active. Clicking a video or its sound selects both." : "Single selection active. Clicking selects only that video or sound clip.")
    }
    @objc private func activateBladeTool() {
        bladeToolActive = true
        timelineView.bladeMode = true
        updateTimelineToolbarState()
        status("Blade Tool active. Click a clip to split it.")
    }
    func addMedia(_ urls: [URL], addToTimeline: Bool, at timelineStart: Double? = nil, track: Int = 0, dropKind: MediaKind? = nil) {
        let requestedURLs = urls.filter(\.isFileURL)
        guard !requestedURLs.isEmpty else { status("Choose one or more media files."); return }
        let knownAssets = Dictionary(uniqueKeysWithValues: media.map { ($0.url, $0) })
        let newURLs = requestedURLs.filter { knownAssets[$0] == nil }
        if newURLs.isEmpty {
            guard addToTimeline else { status("Those files are already in the Media Pool."); return }
            let existing = requestedURLs.compactMap { knownAssets[$0] }
            addAssetsToTimeline(existing, at: timelineStart, track: track, dropKind: dropKind, action: "Add Existing Media")
            return
        }
        status("Reading \(newURLs.count) media file(s)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let assets = newURLs.map { self?.describeAsset($0) }.compactMap { $0 }
            DispatchQueue.main.async { self?.finishImport(assets, requestedURLs: requestedURLs, knownAssets: knownAssets, addToTimeline: addToTimeline, at: timelineStart, track: track, dropKind: dropKind) }
        }
    }
    private func finishImport(_ assets: [MediaAsset], requestedURLs: [URL], knownAssets: [URL: MediaAsset], addToTimeline: Bool, at timelineStart: Double?, track: Int, dropKind: MediaKind?) {
        let newAssets = assets.filter { asset in !media.contains(where: { $0.url == asset.url }) }
        media.append(contentsOf: newAssets)
        if let first = newAssets.first { selectedAssetID = first.id; if !addToTimeline { preview(first.url) } }
        var resolvedAssets = knownAssets
        for asset in newAssets { resolvedAssets[asset.url] = asset }
        let placement = requestedURLs.compactMap { resolvedAssets[$0] }
        if addToTimeline {
            addAssetsToTimeline(placement, at: timelineStart, track: track, dropKind: dropKind, action: "Import Clips")
        }
        reloadMedia()
        if addToTimeline { status("Imported \(newAssets.count) new file(s) and added \(placement.count) clip(s) to the timeline.") }
        else { status("Imported \(newAssets.count) file(s) to the Media Pool.") }
    }
    private func nextTimelineStart(for track: Int, kind: MediaKind) -> Double {
        timelineClips.filter { $0.kind == kind && $0.track == track }.map { $0.timelineStart + clipDuration($0) }.max() ?? 0
    }
    private func clipDuration(_ clip: TimelineClip) -> Double { clip.outPoint > clip.inPoint ? clip.outPoint - clip.inPoint : 6 }
    private func placementIntervals(in layout: [TimelineClip]) -> [TimelineLaneInterval] {
        layout.map { clip in
            TimelineLaneInterval(kind: clip.kind, track: clip.track, start: clip.timelineStart, duration: clipDuration(clip))
        }
    }
    private func resolvedPlacementStart(
        requested: Double,
        duration: Double,
        kind: MediaKind,
        track: Int,
        in layout: [TimelineClip]
    ) -> Double {
        TimelineLanePlacement.nearestStart(
            requested: requested,
            duration: duration,
            kind: kind,
            track: track,
            stationary: placementIntervals(in: layout)
        )
    }
    private func firstAvailableTrack(
        kind: MediaKind,
        preferredTrack: Int,
        start: Double,
        duration: Double,
        in layout: [TimelineClip]
    ) -> Int {
        let stationary = placementIntervals(in: layout)
        let highest = layout.filter { $0.kind == kind }.map(\.track).max() ?? -1
        let upper = max(preferredTrack, highest + 1)
        for candidate in max(0, preferredTrack)...max(0, upper) {
            let moving = [TimelineLaneInterval(kind: kind, track: candidate, start: start, duration: duration)]
            if TimelineLanePlacement.isAvailable(moving, among: stationary, delta: 0) { return candidate }
        }
        return max(0, upper + 1)
    }
    private func describeAsset(_ url: URL) -> MediaAsset {
        let asset = AVURLAsset(url: url)
        let durationValue = CMTimeGetSeconds(asset.duration)
        let duration = durationValue.isFinite && durationValue > 0 ? durationValue : 6
        let isAudio = asset.tracks(withMediaType: .video).isEmpty
        let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty
        return MediaAsset(name: url.lastPathComponent, url: url, kind: isAudio ? .audio : .video, duration: duration, hasAudio: hasAudio)
    }
    private func addAssetsToTimeline(_ assets: [MediaAsset], at start: Double? = nil, track: Int = 0, dropKind: MediaKind? = nil, action: String) {
        guard !assets.isEmpty else { status("There are no usable clips to add."); return }
        var next = timelineClips
        var trackCursors: [String: Double] = [:]
        var createdIDs = Set<UUID>()
        var firstCreatedVideo: TimelineClip?
        for asset in assets {
            // Finder can contain audio-only MOV/MP4 files. If asynchronous media
            // inspection disagrees with the lane preview, use that media type's
            // first track instead of silently placing A/V on an unrelated number.
            let actualTrack = max(0, dropKind == nil || dropKind == asset.kind ? track : 0)
            let cursorKey = "\(asset.kind.rawValue)-\(actualTrack)"
            let requestedPosition = trackCursors[cursorKey] ?? (start ?? nextTimelineStart(for: actualTrack, kind: asset.kind))
            let duration = max(1 / TimelineLanePlacement.frameRate, asset.duration)
            let position = resolvedPlacementStart(
                requested: requestedPosition,
                duration: duration,
                kind: asset.kind,
                track: actualTrack,
                in: next
            )
            let group = asset.kind == .video && asset.hasAudio ? UUID() : nil
            let clip = TimelineClip(assetID: asset.id, name: asset.name, url: asset.url, outPoint: asset.duration, timelineStart: position, track: actualTrack, kind: asset.kind, groupID: group)
            next.append(clip); createdIDs.insert(clip.id)
            if firstCreatedVideo == nil, clip.kind == .video { firstCreatedVideo = clip }
            if let group {
                // Keep picture timing exactly where the user dropped it. If A1
                // is occupied by an intentional video overlay, place its linked
                // sound on the first free audio layer instead of shifting the
                // video away from the requested V2/V3 overlay.
                let audioTrack = firstAvailableTrack(kind: .audio, preferredTrack: 0, start: position, duration: duration, in: next)
                let linkedAudio = TimelineClip(assetID: asset.id, name: asset.name, url: asset.url, outPoint: asset.duration, timelineStart: position, track: audioTrack, kind: .audio, groupID: group)
                next.append(linkedAudio); createdIDs.insert(linkedAudio.id)
            }
            trackCursors[cursorKey] = position + max(0.5, duration)
        }
        let primary = firstCreatedVideo ?? next.first(where: { createdIDs.contains($0.id) })
        replaceTimeline(
            next,
            action: action,
            selection: createdIDs,
            primary: primary?.id,
            playhead: primary?.timelineStart ?? timelineView.currentPlayheadTime
        )
        // Revealing is intentional for a new import only. Generic selection and
        // move commits never queue a later scroll underneath an active drag.
        if let primary { timelineView.revealClip(primary.id) }
        if timelinePreviewSkippedNames.isEmpty {
            status("Added \(assets.count) media clip\(assets.count == 1 ? "" : "s") to the timeline.")
        } else {
            status("Added the clips, but the preview could not read: \(timelinePreviewSkippedNames.joined(separator: ", ")).")
        }
    }
    func addAsset(at index: Int, at start: Double? = nil, track: Int = 0) { guard media.indices.contains(index) else { return }; addAssetsToTimeline([media[index]], at: start, track: track, action: "Add Clip") }
    func mediaKind(at index: Int) -> MediaKind? { media.indices.contains(index) ? media[index].kind : nil }
    func resolvedDropStart(forAssetAt index: Int, requested: Double, track: Int) -> Double? {
        guard media.indices.contains(index) else { return nil }
        let asset = media[index]
        return resolvedPlacementStart(
            requested: requested,
            duration: max(1 / TimelineLanePlacement.frameRate, asset.duration),
            kind: asset.kind,
            track: max(0, track),
            in: timelineClips
        )
    }
    func commitTimelineLayout(_ layout: [TimelineClip], selected: Set<UUID>, primary: UUID? = nil) {
        commitTimelineEdit(layout, selected: selected, primary: primary, action: "Move Clips")
    }
    func commitTimelineEdit(_ layout: [TimelineClip], selected: Set<UUID>, primary requestedPrimary: UUID? = nil, action: String) {
        guard layout != timelineClips else { reloadTimeline(); return }
        let primary = requestedPrimary.flatMap { id in layout.first(where: { $0.id == id && selected.contains(id) }) }
            ?? layout.first(where: { selected.contains($0.id) })
        replaceTimeline(
            layout,
            action: action,
            selection: selected,
            primary: primary?.id,
            playhead: timelineView.currentPlayheadTime
        )
        status("\(action) applied to \(selected.count) clip\(selected.count == 1 ? "" : "s").")
    }
    func timelinePlayheadMoved(to time: Double) {
        let totalFrames = Int((max(0, time) * 30).rounded())
        let frames = totalFrames % 30
        let seconds = (totalFrames / 30) % 60
        let minutes = (totalFrames / 1800) % 60
        let hours = totalFrames / 108000
        playheadLabel.stringValue = String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
        if let clip = primarySelectedVideo(), time >= clip.timelineStart, time <= clip.timelineStart + clipDuration(clip) {
            effectsStudioController?.updatePlayhead(localTime: clip.localTime(at: time))
        }
    }
    /// Called only for an intentional ruler/canvas click.  Periodic player updates
    /// use `timelinePlayheadMoved`, so this never creates a seek feedback loop.
    func timelinePlayheadSelected(to time: Double) {
        timelinePlayheadMoved(to: time)
        guard previewingTimeline, let item = timelinePreviewItem, player.currentItem === item else { return }
        player.pause()
        requestTimelineSeek(
            on: item,
            requestedTime: time,
            playWhenReady: false,
            showsPreparingOverlay: isTimelineCut(time)
        )
    }
    @discardableResult
    func cutTimelineClips(_ ids: Set<UUID>, at time: Double, includeLinked: Bool = true) -> Bool {
        guard !ids.isEmpty else { status("Select a clip, then place the playhead where you want to cut."); return false }
        let groupIDs = includeLinked ? Set(timelineClips.filter { ids.contains($0.id) }.compactMap(\.groupID)) : []
        let targetIDs = includeLinked
            ? ids.union(timelineClips.filter { clip in clip.groupID.map { groupIDs.contains($0) } ?? false }.map(\.id))
            : ids
        var newGroups: [UUID: UUID] = [:]
        var rightIDs = Set<UUID>()
        var result: [TimelineClip] = []
        var splitCount = 0
        for clip in timelineClips {
            let duration = clipDuration(clip)
            let clipEnd = clip.timelineStart + duration
            guard targetIDs.contains(clip.id), time > clip.timelineStart + (1.0 / 30.0), time < clipEnd - (1.0 / 30.0) else {
                result.append(clip); continue
            }
            let sourceCut = clip.inPoint + (time - clip.timelineStart)
            let animationSplit = clip.splitAnimation(at: time - clip.timelineStart)
            var left = clip
            left.outPoint = sourceCut
            left.animation = animationSplit.left
            var right = clip
            right.id = UUID()
            right.inPoint = sourceCut
            right.timelineStart = time
            right.animation = animationSplit.right
            if let oldGroup = clip.groupID {
                let newGroup = newGroups[oldGroup] ?? UUID()
                newGroups[oldGroup] = newGroup
                right.groupID = newGroup
            }
            result.append(left); result.append(right)
            rightIDs.insert(right.id)
            splitCount += 1
        }
        guard splitCount > 0 else { status("Put the playhead inside a selected clip before cutting."); return false }
        let primary = result.first(where: { rightIDs.contains($0.id) })
        replaceTimeline(
            result,
            action: "Cut Clips",
            selection: rightIDs,
            primary: primary?.id,
            playhead: primary?.timelineStart ?? time
        )
        if let primary {
            if currentPage == .color { preview(primary.url, grade: primary) }
        }
        status("Cut \(splitCount) clip\(splitCount == 1 ? "" : "s") at the playhead.")
        return true
    }

    private func reloadMedia() {
        mediaList.arrangedSubviews.forEach { mediaList.removeArrangedSubview($0); $0.removeFromSuperview() }
        if media.isEmpty { let empty = NSTextField(wrappingLabelWithString: "No media yet.\n\nClick Import or drop files on Video 1."); empty.textColor = .secondaryLabelColor; empty.alignment = .center; mediaList.addArrangedSubview(empty); return }
        for (index, asset) in media.enumerated() { let row = MediaRowButton(asset: asset, index: index, controller: self); row.state = selectedAssetID == asset.id ? .on : .off; mediaList.addArrangedSubview(row) }
    }
    private func replaceMedia(_ next: [MediaAsset], action: String, selection requestedSelection: UUID?) {
        let previous = media
        let previousSelection = selectedAssetID
        media = next
        selectedAssetID = requestedSelection.flatMap { id in next.contains(where: { $0.id == id }) ? id : nil }
        projectUndoManager.registerUndo(withTarget: self) { target in
            target.replaceMedia(previous, action: action, selection: previousSelection)
        }
        projectUndoManager.setActionName(action)
        reloadMedia()
    }
    @objc private func removeSelectedMedia() {
        guard let assetID = selectedAssetID, let asset = media.first(where: { $0.id == assetID }) else {
            status("Select a Media Pool item before removing it.")
            return
        }
        let timelineUseCount = timelineClips.filter { $0.assetID == assetID }.count
        let belongsToScene = storedScenes.contains { $0.mediaAssetID == assetID }
        guard timelineUseCount == 0, !belongsToScene else {
            NSSound.beep()
            let location = belongsToScene ? "an editable 3D scene" : "\(timelineUseCount) timeline clip\(timelineUseCount == 1 ? "" : "s")"
            status("Cannot remove \(asset.name): it is still used by \(location). Delete those timeline clips first; no source files were changed.")
            return
        }
        let remaining = media.filter { $0.id != assetID }
        replaceMedia(remaining, action: "Remove Media", selection: remaining.first?.id)
        player.pause()
        timelineSeekGeneration += 1
        clearTimelineItemObservers()
        player.replaceCurrentItem(with: nil)
        previewingTimeline = false
        emptyPreviewLabel.stringValue = "Select a Media Pool clip or timeline clip"
        emptyPreviewLabel.isHidden = false
        status("Removed \(asset.name) from the Media Pool. The original file remains safely on disk.")
    }
    func selectAsset(at index: Int) { guard media.indices.contains(index) else { return }; selectedAssetID = media[index].id; selectedClipID = nil; selectedClipIDs.removeAll(); preview(media[index].url); reloadTimeline(); status("Selected \(media[index].name). Drag it onto Video 1 to edit it.") }
    func selectTimeline(index: Int, additive: Bool = false, solo: Bool = false) {
        // A floating Effect Controls window may be holding an unapplied live
        // preview. Never let that transient snapshot follow the user to a
        // different timeline selection.
        TimelineLiveEffectStore.shared.clear()
        guard timelineClips.indices.contains(index) else { return }
        let clip = timelineClips[index]
        let linkedIDs = Set(timelineClips.filter { candidate in candidate.groupID != nil && candidate.groupID == clip.groupID }.map(\.id))
        let clickSelection = solo ? Set([clip.id]) : (linkedIDs.isEmpty ? Set([clip.id]) : linkedIDs)
        var nextSelection = selectedClipIDs
        if additive {
            if nextSelection.contains(clip.id) { nextSelection.subtract(clickSelection) } else { nextSelection.formUnion(clickSelection) }
        } else { nextSelection = clickSelection }
        selectTimelineClips(nextSelection, primary: nextSelection.contains(clip.id) ? clip.id : nextSelection.first)
    }
    func selectTimelineClips(_ requestedIDs: Set<UUID>, primary requestedPrimary: UUID?) {
        let validIDs = Set(timelineClips.map(\.id))
        let nextIDs = requestedIDs.intersection(validIDs)
        let nextPrimary = requestedPrimary.flatMap { nextIDs.contains($0) ? $0 : nil }
            ?? timelineClips.first(where: { nextIDs.contains($0.id) })?.id
        // A mouse-down on the current selection must not rebuild the inspector,
        // timeline geometry and player before the drag has even started.
        guard nextIDs != selectedClipIDs || nextPrimary != selectedClipID else { return }

        TimelineLiveEffectStore.shared.clear()
        selectedClipIDs = nextIDs
        selectedClipID = nextPrimary
        if selectedClipIDs.isEmpty {
            selectedClipID = nil
            updateSelectionLabel()
            if currentPage == .effects || currentPage == .scene3D { rebuildInspector() }
            reloadTimeline()
            status("Timeline selection cleared.")
            return
        }
        guard let primary = timelineClips.first(where: { $0.id == selectedClipID }) else { return }
        selectedAssetID = primary.assetID
        selectionLabel.stringValue = selectedClipIDs.count > 1 ? "\(selectedClipIDs.count) clips selected" : primary.name
        inField.stringValue = String(format: "%.2f", primary.inPoint); outField.stringValue = String(format: "%.2f", primary.outPoint)
        loadEditingControls(from: primary)
        if currentPage == .effects || currentPage == .scene3D { rebuildInspector() }
        // Selection must never jump the playhead. If the Media Pool/source
        // viewer was active, return to the program timeline at its existing
        // position; otherwise leave the current player item untouched.
        if !previewingTimeline { previewTimeline(at: timelineView.currentPlayheadTime) }
        reloadTimeline()
        status(selectedClipIDs.count > 1 ? "\(selectedClipIDs.count) timeline clips selected." : "Selected \(primary.name) in Timeline 1.")
    }
    private func preview(_ url: URL, grade: TimelineClip? = nil) {
        emptyPreviewLabel.isHidden = true
        let wasTimelinePreview = previewingTimeline
        previewingTimeline = false
        timelineSeekGeneration += 1
        clearTimelineItemObservers()
        if let grade, !wasTimelinePreview,
           let state = liveGradePreviewState,
           state.sourceURL == url.standardizedFileURL,
           state.clipID == grade.id,
           player.currentItem != nil {
            state.update(grade)
            // Playback naturally picks up the new grade on its next frame. A
            // zero-distance seek refreshes a paused viewer without replacing
            // its item or jumping back to the beginning.
            if player.rate == 0 {
                let current = player.currentTime()
                player.seek(to: current, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return
        }
        let item = AVPlayerItem(url: url)
        if let grade {
            let asset = AVURLAsset(url: url)
            let state = LiveGradePreviewState(sourceURL: url, clip: grade)
            liveGradePreviewState = state
            item.videoComposition = AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
                // This source-only viewer intentionally uses the same visual
                // pipeline as timeline playback and final delivery. Convert the
                // asset clock to the clip's timeline clock so local keyframes
                // remain aligned with the visible trimmed media.
                let grade = state.clip()
                let timelineTime = grade.timelineStart + max(0, request.compositionTime.seconds - grade.inPoint)
                let image = NativeTimelineVisualPipeline.applyGrade(
                    to: request.sourceImage,
                    clip: grade,
                    timelineTime: timelineTime
                )
                request.finish(with: image, context: nil)
            })
        } else {
            liveGradePreviewState = nil
        }
        player.replaceCurrentItem(with: item)
        if let grade, grade.inPoint > 0 {
            player.seek(to: CMTime(seconds: grade.inPoint, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
    private func timelineVideoStarting(at time: Double) -> TimelinePreviewVideoRange? {
        let tolerance = 1.0 / 300.0
        let candidates = timelinePreviewVideoRanges.filter { range in
            abs(range.logicalStart - time) <= tolerance || abs(range.resolvedStart - time) <= tolerance
        }
        if let selectedClipID, let selected = candidates.first(where: { $0.clipID == selectedClipID }) { return selected }
        return candidates.max { left, right in
            if left.track != right.track { return left.track < right.track }
            return left.resolvedStart < right.resolvedStart
        }
    }
    private func isTimelineCut(_ time: Double) -> Bool {
        timelineVideoStarting(at: time) != nil
    }
    /// A paused custom composition can receive no decoded source frame exactly
    /// on a hard cut. Render one frame inside the new clip while keeping the
    /// visible playhead at the user's requested edit point.
    private func stabilizedTimelineRenderTime(for requestedTime: Double) -> Double {
        let requested = min(max(0, requestedTime), timelinePreviewDuration)
        if timelinePreviewDuration > (1.0 / 30.0), requested >= timelinePreviewDuration - (1.0 / 600.0) {
            // Composition time ranges are end-exclusive; asking for the exact
            // duration has no source frame and is expected to render black.
            return max(0, timelinePreviewDuration - (1.0 / 30.0))
        }
        guard let startingClip = timelineVideoStarting(at: requested) else { return requested }
        let duration = max(1.0 / 600.0, startingClip.end - startingClip.resolvedStart)
        let clipEnd = min(timelinePreviewDuration, startingClip.end)
        let latestInside = clipEnd - (1.0 / 600.0)
        guard latestInside > startingClip.resolvedStart else { return requested }
        let inset = min(1.0 / 30.0, max(1.0 / 600.0, duration * 0.2))
        return min(latestInside, max(requested, startingClip.resolvedStart + inset))
    }
    private func requestTimelineSeek(
        on item: AVPlayerItem,
        requestedTime: Double,
        playWhenReady: Bool,
        showsPreparingOverlay: Bool
    ) {
        let requested = min(max(0, requestedTime), timelinePreviewDuration)
        let renderTime = playWhenReady ? requested : stabilizedTimelineRenderTime(for: requested)
        timelineSeekGeneration += 1
        let generation = timelineSeekGeneration
        pendingTimelineSeek = PendingTimelineSeek(
            item: item,
            requestedTime: requested,
            renderTime: renderTime,
            playWhenReady: playWhenReady,
            generation: generation,
            showsPreparingOverlay: showsPreparingOverlay
        )
        previewingTimeline = true
        if showsPreparingOverlay {
            emptyPreviewLabel.stringValue = "Updating timeline preview…"
            emptyPreviewLabel.isHidden = false
        }
        timelineView.updatePlaybackPlayhead(requested)
        timelinePlayheadMoved(to: requested)

        if item.status == .readyToPlay {
            performPendingTimelineSeekIfReady(for: item)
        } else if item.status == .failed {
            pendingTimelineSeek = nil
            let reason = item.error?.localizedDescription ?? "The media could not be decoded."
            emptyPreviewLabel.stringValue = "Timeline preview failed\n\(reason)"
            emptyPreviewLabel.isHidden = false
            status("Timeline preview failed: \(reason)")
        }
    }
    private func performPendingTimelineSeekIfReady(for item: AVPlayerItem) {
        guard item.status == .readyToPlay,
              let request = pendingTimelineSeek,
              request.item === item,
              request.generation == timelineSeekGeneration,
              player.currentItem === item,
              previewingTimeline else { return }
        pendingTimelineSeek = nil
        item.cancelPendingSeeks()
        let destination = CMTime(seconds: request.renderTime, preferredTimescale: 600)
        let toleranceAfter = CMTime(value: 1, timescale: 30)
        player.seek(to: destination, toleranceBefore: .zero, toleranceAfter: toleranceAfter) { [weak self, weak item] finished in
            DispatchQueue.main.async {
                guard let self, let item, finished,
                      request.generation == self.timelineSeekGeneration,
                      self.previewingTimeline,
                      self.player.currentItem === item else { return }
                if request.playWhenReady {
                    self.emptyPreviewLabel.isHidden = true
                    self.timelineView.updatePlaybackPlayhead(request.renderTime)
                    self.timelinePlayheadMoved(to: request.renderTime)
                    self.player.play()
                    self.status("Playing the timeline sequence.")
                    return
                }
                if !request.showsPreparingOverlay {
                    self.emptyPreviewLabel.isHidden = true
                    self.timelineView.updatePlaybackPlayhead(request.requestedTime)
                    self.timelinePlayheadMoved(to: request.requestedTime)
                    return
                }

                // A distinct second paused seek forces AVPlayer to ask the
                // compositor for a fresh frame. Without it, a transiently
                // missing decoder frame at a cut can remain black forever.
                let refreshTime = min(self.timelinePreviewDuration, request.renderTime + (1.0 / 600.0))
                let refreshDestination = CMTime(seconds: refreshTime, preferredTimescale: 600)
                self.player.seek(to: refreshDestination, toleranceBefore: .zero, toleranceAfter: toleranceAfter) { [weak self, weak item] _ in
                    DispatchQueue.main.async {
                        guard let self, let item,
                              request.generation == self.timelineSeekGeneration,
                              self.previewingTimeline,
                              self.player.currentItem === item else { return }
                        self.emptyPreviewLabel.isHidden = true
                        self.timelineView.updatePlaybackPlayhead(request.requestedTime)
                        self.timelinePlayheadMoved(to: request.requestedTime)
                    }
                }
            }
        }
    }
    private func previewTimeline(at timelineTime: Double, playWhenReady: Bool = false) {
        guard !timelineClips.isEmpty else { return }
        if timelinePreviewNeedsRebuild || timelinePreviewComposition == nil {
            guard let preview = buildTimelinePreviewComposition() else {
                player.pause()
                timelineSeekGeneration += 1
                clearTimelineItemObservers()
                player.replaceCurrentItem(with: nil)
                timelinePreviewItem = nil
                previewingTimeline = false
                emptyPreviewLabel.stringValue = "Timeline preview unavailable\nOne or more video tracks could not be read."
                emptyPreviewLabel.isHidden = false
                status("The timeline preview could not read one of the selected media files.")
                return
            }
            timelinePreviewComposition = preview.composition
            timelinePreviewVideoComposition = preview.videoComposition
            timelinePreviewAudioMix = preview.audioMix
            timelinePreviewDuration = preview.duration
            timelinePreviewSkippedNames = preview.skippedNames
            timelinePreviewItem = nil
            timelinePreviewNeedsRebuild = false
        }
        guard let composition = timelinePreviewComposition, timelinePreviewDuration > 0 else { return }

        let item: AVPlayerItem
        var createdFreshItem = false
        if let cached = timelinePreviewItem, player.currentItem === cached {
            item = cached
        } else {
            createdFreshItem = true
            player.pause()
            emptyPreviewLabel.stringValue = "Preparing timeline preview…"
            emptyPreviewLabel.isHidden = false
            let freshItem = AVPlayerItem(asset: composition)
            freshItem.videoComposition = timelinePreviewVideoComposition
            freshItem.audioMix = timelinePreviewAudioMix
            freshItem.forwardPlaybackEndTime = CMTime(seconds: timelinePreviewDuration, preferredTimescale: 600)
            freshItem.seekingWaitsForVideoCompositionRendering = true
            freshItem.preferredForwardBufferDuration = 0.25
            timelinePreviewItem = freshItem
            previewingTimeline = true
            player.replaceCurrentItem(with: freshItem)
            observeTimelineItem(freshItem)
            item = freshItem
        }

        // Seeking and playing in separate turns stops AVPlayer from beginning a
        // new item at zero while an asynchronous seek is still in flight.
        let requested = min(max(0, timelineTime), timelinePreviewDuration)
        let restartFromZero = playWhenReady && requested >= timelinePreviewDuration - (1.0 / 30.0)
        let seconds = restartFromZero ? 0 : requested
        requestTimelineSeek(
            on: item,
            requestedTime: seconds,
            playWhenReady: playWhenReady,
            showsPreparingOverlay: createdFreshItem || (!playWhenReady && isTimelineCut(seconds))
        )
    }
    private func buildTimelinePreviewComposition() -> (composition: AVComposition, videoComposition: AVMutableVideoComposition?, audioMix: AVMutableAudioMix?, duration: Double, skippedNames: [String])? {
        timelinePreviewVideoRanges = []
        let composition = AVMutableComposition()
        var videoSources: [(clip: TimelineClip, outputTrack: AVMutableCompositionTrack, sourceTrack: AVAssetTrack, timelineStart: Double, duration: Double)] = []
        var audioSources: [(clip: TimelineClip, outputTrack: AVMutableCompositionTrack, timelineStart: Double, duration: Double)] = []
        var skippedNames: [String] = []
        var failedVideoGroups = Set<UUID>()
        func recordSkip(_ clip: TimelineClip) {
            if !skippedNames.contains(clip.name) { skippedNames.append(clip.name) }
            if clip.kind == .video, let groupID = clip.groupID { failedVideoGroups.insert(groupID) }
        }
        let ordered = timelineClips.enumerated().sorted { lhs, rhs in
            if lhs.element.timelineStart == rhs.element.timelineStart { return lhs.offset < rhs.offset }
            return lhs.element.timelineStart < rhs.element.timelineStart
        }.map(\.element)
        for clip in ordered {
            let sourceAsset = AVURLAsset(url: clip.url)
            let mediaType: AVMediaType = clip.kind == .video ? .video : .audio
            guard let sourceTrack = sourceAsset.tracks(withMediaType: mediaType).first else {
                recordSkip(clip)
                continue
            }
            guard let resolved = NativeTimelineMediaRangeResolver.resolve(
                clip: clip,
                sourceTrack: sourceTrack,
                assetDuration: sourceAsset.duration.seconds
            ), let outputTrack = composition.addMutableTrack(
                withMediaType: mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                recordSkip(clip)
                continue
            }
            do {
                try outputTrack.insertTimeRange(
                    resolved.sourceRange,
                    of: sourceTrack,
                    at: CMTime(seconds: resolved.timelineStart, preferredTimescale: 600)
                )
                if clip.kind == .video {
                    videoSources.append((clip, outputTrack, sourceTrack, resolved.timelineStart, resolved.duration))
                } else {
                    audioSources.append((clip, outputTrack, resolved.timelineStart, resolved.duration))
                }
            } catch {
                composition.removeTrack(outputTrack)
                recordSkip(clip)
            }
        }

        // A linked audio edit must never make a failed video edit look valid.
        // If its matching picture track could not be inserted, remove that
        // audio track too and surface the media name instead of showing black.
        if !failedVideoGroups.isEmpty {
            audioSources.removeAll { source in
                guard let groupID = source.clip.groupID, failedVideoGroups.contains(groupID) else { return false }
                composition.removeTrack(source.outputTrack)
                return true
            }
        }

        let timelineContainsVideo = ordered.contains(where: { $0.kind == .video })
        guard !videoSources.isEmpty || (!timelineContainsVideo && !audioSources.isEmpty) else { return nil }
        let duration = (videoSources.map { $0.timelineStart + $0.duration }
            + audioSources.map { $0.timelineStart + $0.duration }).max() ?? 0
        guard duration > (1.0 / 600.0) else { return nil }
        timelinePreviewVideoRanges = videoSources.map { source in
            TimelinePreviewVideoRange(
                clipID: source.clip.id,
                logicalStart: source.clip.timelineStart,
                resolvedStart: source.timelineStart,
                end: source.timelineStart + source.duration,
                track: source.clip.track
            )
        }
        let audioMix: AVMutableAudioMix? = audioSources.isEmpty ? nil : {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioSources.map { source in
                let parameters = AVMutableAudioMixInputParameters(track: source.outputTrack)
                parameters.setVolume(Float(source.clip.volume), at: CMTime(seconds: source.timelineStart, preferredTimescale: 600))
                return parameters
            }
            return mix
        }()
        let videoComposition = videoSources.isEmpty ? nil : buildVideoComposition(for: videoSources, duration: duration)
        guard let playbackComposition = composition.copy() as? AVComposition else { return nil }
        return (playbackComposition, videoComposition, audioMix, duration, skippedNames)
    }
    private func buildVideoComposition(for sources: [(clip: TimelineClip, outputTrack: AVMutableCompositionTrack, sourceTrack: AVAssetTrack, timelineStart: Double, duration: Double)], duration: Double) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = NSSize(width: 1280, height: 720)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.renderScale = 1
        composition.customVideoCompositorClass = NativeTimelineVideoCompositor.self

        // The custom compositor evaluates transforms, opacity, grading and
        // effects for every frame. Instructions therefore only need to change
        // when the active layer set changes, keeping playback responsive while
        // matching the native export engine exactly.
        let timelineTimescale: CMTimeScale = 600
        var timePointTicks = Set<Int64>([0, Int64((duration * Double(timelineTimescale)).rounded())])
        for source in sources {
            timePointTicks.insert(Int64((source.timelineStart * Double(timelineTimescale)).rounded()))
            timePointTicks.insert(Int64(((source.timelineStart + source.duration) * Double(timelineTimescale)).rounded()))
        }
        let finalTick = Int64((duration * Double(timelineTimescale)).rounded())
        let points = Array(Set(timePointTicks.map { max(0, min(finalTick, $0)) })).sorted()
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for index in 0..<(max(0, points.count - 1)) {
            let startTick = points[index]
            let endTick = points[index + 1]
            guard endTick > startTick else { continue }
            let startTime = CMTime(value: startTick, timescale: timelineTimescale)
            let endTime = CMTime(value: endTick, timescale: timelineTimescale)
            let range = CMTimeRange(start: startTime, duration: CMTimeSubtract(endTime, startTime))
            let start = startTime.seconds
            let end = endTime.seconds
            let active = sources.filter { source in
                source.timelineStart < end - (1.0 / 1200.0) && source.timelineStart + source.duration > start + (1.0 / 1200.0)
            }
            let layers = active.sorted {
                if $0.clip.track != $1.clip.track { return $0.clip.track > $1.clip.track }
                if $0.clip.timelineStart != $1.clip.timelineStart { return $0.clip.timelineStart > $1.clip.timelineStart }
                return $0.clip.id.uuidString > $1.clip.id.uuidString
            }.map { source in
                NativeTimelineLayerPlan(
                    clip: source.clip,
                    trackID: source.outputTrack.trackID,
                    naturalSize: source.sourceTrack.naturalSize,
                    preferredTransform: source.sourceTrack.preferredTransform
                )
            }
            instructions.append(NativeTimelineVideoInstruction(
                timeRange: range,
                layers: layers,
                renderSize: composition.renderSize,
                usesLivePreviewOverrides: true
            ))
        }
        composition.instructions = instructions
        return composition
    }
    private func renderTransform(for clip: TimelineClip, sourceTrack: AVAssetTrack, at timelineTime: Double) -> CGAffineTransform {
        // AVFoundation's preferred transform only fixes rotation.  Without this
        // fit-and-centre pass, large camera frames are clipped by our 1280×720
        // program canvas and look like an accidental zoom.
        let renderSize = CGSize(width: 1280, height: 720)
        let sourceBounds = CGRect(origin: .zero, size: sourceTrack.naturalSize)
        let orientedBounds = sourceBounds.applying(sourceTrack.preferredTransform)
        let orientedWidth = abs(orientedBounds.width)
        let orientedHeight = abs(orientedBounds.height)
        guard orientedWidth > 0, orientedHeight > 0 else { return sourceTrack.preferredTransform }
        let fitScale = min(renderSize.width / orientedWidth, renderSize.height / orientedHeight)
        let fit = CGAffineTransform(scaleX: fitScale, y: fitScale)
        let scaledBounds = orientedBounds.applying(fit)
        let centre = CGAffineTransform(
            translationX: (renderSize.width - scaledBounds.width) / 2 - scaledBounds.minX,
            y: (renderSize.height - scaledBounds.height) / 2 - scaledBounds.minY
        )
        let fittedSource = sourceTrack.preferredTransform.concatenating(fit).concatenating(centre)

        let scale = CGFloat(clip.value(for: .scale, at: timelineTime))
        let rotation = CGFloat(clip.value(for: .rotation, at: timelineTime) * .pi / 180)
        let x = CGFloat(clip.value(for: .positionX, at: timelineTime)) * 640
        let y = CGFloat(clip.value(for: .positionY, at: timelineTime)) * 360
        let adjustment = CGAffineTransform(translationX: 640 + x, y: 360 + y)
            .rotated(by: rotation)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -640, y: -360)
        return fittedSource.concatenating(adjustment)
    }
    private func reloadTimeline(resetTrackStructure: Bool = false) {
        timelineView.applySnapshot(
            clips: timelineClips,
            selectedIDs: selectedClipIDs,
            sourceDurations: Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0.duration) }),
            resetTrackStructure: resetTrackStructure
        )
    }
    private func updateSelectionLabel() {
        guard !selectedClipIDs.isEmpty else {
            selectionLabel.stringValue = "No timeline clip selected"
            return
        }
        if selectedClipIDs.count > 1 {
            selectionLabel.stringValue = "\(selectedClipIDs.count) clips selected"
        } else if let id = selectedClipIDs.first, let clip = timelineClips.first(where: { $0.id == id }) {
            selectionLabel.stringValue = clip.name
        } else {
            selectionLabel.stringValue = "No timeline clip selected"
        }
    }
    @objc private func applyTrim() {
        guard let id = selectedClipID, let index = timelineClips.firstIndex(where: { $0.id == id }) else { status("Select a timeline clip before trimming."); return }
        let primary = timelineClips[index]
        let sourceDuration = media.first(where: { $0.id == primary.assetID })?.duration ?? primary.outPoint
        let sourceIn = max(0, Double(inField.stringValue) ?? primary.inPoint)
        let enteredOut = Double(outField.stringValue) ?? primary.outPoint
        let sourceOut = enteredOut <= 0 ? sourceDuration : min(sourceDuration, enteredOut)
        guard sourceOut > sourceIn + (1.0 / 30.0) else { status("The out point must be after the in point."); return }
        let linkedIDs = Set(timelineClips.filter { $0.groupID != nil && $0.groupID == primary.groupID }.map(\.id))
        let affectedIDs = linkedIDs.isEmpty ? Set([id]) : linkedIDs
        let requestedVisibleDuration = sourceOut - sourceIn
        var visibleDuration = requestedVisibleDuration
        for clip in timelineClips where affectedIDs.contains(clip.id) {
            let nextStart = timelineClips.lazy.filter { candidate in
                !affectedIDs.contains(candidate.id)
                    && candidate.kind == clip.kind
                    && candidate.track == clip.track
                    && candidate.timelineStart >= clip.timelineStart - 0.000_001
            }.map(\.timelineStart).min()
            if let nextStart {
                let freeDuration = floor(max(0, nextStart - clip.timelineStart) * TimelineLanePlacement.frameRate)
                    / TimelineLanePlacement.frameRate
                visibleDuration = min(visibleDuration, freeDuration)
            }
        }
        guard visibleDuration >= 1 / TimelineLanePlacement.frameRate else {
            status("There is no free room to extend this clip on its current layer.")
            return
        }
        let effectiveOut = sourceIn + visibleDuration
        let wasClampedBesideNeighbour = visibleDuration < requestedVisibleDuration - 0.000_001
        var updated = timelineClips
        for position in updated.indices where affectedIDs.contains(updated[position].id) {
            updated[position].inPoint = sourceIn
            updated[position].outPoint = effectiveOut
            updated[position].animation.channels = updated[position].animation.channels.compactMap { channel in
                let visibleFrames = channel.keyframes.filter { $0.time <= visibleDuration + (1.0 / 60.0) }
                return visibleFrames.isEmpty ? nil : AnimationChannel(property: channel.property, keyframes: visibleFrames)
            }
        }
        replaceTimeline(
            updated,
            action: "Trim Clip",
            selection: affectedIDs,
            primary: id,
            playhead: updated[index].timelineStart
        )
        inField.stringValue = String(format: "%.2f", sourceIn); outField.stringValue = String(format: "%.2f", effectiveOut)
        if wasClampedBesideNeighbour {
            status("Trim stopped at the next clip so both remain side-by-side on this layer.")
        } else {
            status("Trim applied to \(affectedIDs.count) linked clip\(affectedIDs.count == 1 ? "" : "s").")
        }
    }
    @objc private func cutAtPlayhead() { _ = cutTimelineClips(selectedClipIDs, at: timelineView.currentPlayheadTime) }
    @objc private func togglePlayback() {
        if player.timeControlStatus == .playing { player.pause(); status("Playback paused.") }
        else {
            if previewingTimeline {
                let current = CMTimeGetSeconds(player.currentTime())
                if current.isFinite, current >= timelinePreviewDuration - (1.0 / 30.0) {
                    previewTimeline(at: 0, playWhenReady: true)
                } else {
                    player.play()
                    status("Playing the timeline sequence.")
                }
            } else if (currentPage == .color || currentPage == .effects), player.currentItem != nil {
                player.play()
                status("Playing the selected source clip.")
            } else if !timelineClips.isEmpty {
                previewTimeline(at: timelineView.currentPlayheadTime, playWhenReady: true)
            } else {
                player.play()
            }
        }
    }
    @objc private func stopPlayback() {
        player.pause()
        if previewingTimeline, let item = timelinePreviewItem, player.currentItem === item {
            requestTimelineSeek(on: item, requestedTime: 0, playWhenReady: false, showsPreparingOverlay: isTimelineCut(0))
        } else {
            timelineSeekGeneration += 1
            pendingTimelineSeek = nil
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        status("Playback stopped.")
    }
    @objc private func stepBackward() { stepPlayer(by: -1.0 / 30.0) }
    @objc private func stepForward() { stepPlayer(by: 1.0 / 30.0) }
    private func stepPlayer(by seconds: Double) {
        let playerSeconds = CMTimeGetSeconds(player.currentTime())
        let current = previewingTimeline ? timelineView.currentPlayheadTime : playerSeconds
        let rawDestination = max(0, current.isFinite ? current + seconds : 0)
        let destination = previewingTimeline ? min(rawDestination, timelinePreviewDuration) : rawDestination
        player.pause()
        if previewingTimeline, let item = timelinePreviewItem, player.currentItem === item {
            requestTimelineSeek(
                on: item,
                requestedTime: destination,
                playWhenReady: false,
                showsPreparingOverlay: isTimelineCut(destination) || destination >= timelinePreviewDuration - (1.0 / 600.0)
            )
        } else {
            timelineSeekGeneration += 1
            pendingTimelineSeek = nil
            player.seek(to: CMTime(seconds: destination, preferredTimescale: 600))
        }
        status("Stepped \(seconds < 0 ? "back" : "forward") one frame.")
    }
    @objc private func removeClip() { deleteSelectedTimelineClips() }
    func deleteSelectedTimelineClips() {
        // Selection already contains linked video/audio partners in Linked mode.
        // Single mode and Option-click intentionally put only the clicked clip
        // in this set, so deleting exactly these IDs mirrors the white outlines.
        let validSelection = selectedClipIDs.intersection(Set(timelineClips.map(\.id)))
        guard !validSelection.isEmpty else {
            status("Select one or more timeline clips before deleting.")
            return
        }
        let removed = timelineClips.filter { validSelection.contains($0.id) }
        let removedGroupIDs = Set(removed.compactMap(\.groupID))
        var remaining = timelineClips.filter { !validSelection.contains($0.id) }
        // A single/Option delete can remove only one half of a linked pair.
        // Detaching the survivor prevents later clicks or moves from behaving
        // as though a missing partner still exists.
        for index in remaining.indices where remaining[index].groupID.map({ removedGroupIDs.contains($0) }) ?? false {
            remaining[index].groupID = nil
        }
        let remainingEnd = remaining.map { $0.timelineStart + clipDuration($0) }.max() ?? 0
        let nextPlayhead = remaining.isEmpty ? 0 : min(timelineView.currentPlayheadTime, remainingEnd)
        replaceTimeline(remaining, action: "Delete Timeline Clips", selection: [], primary: nil, playhead: nextPlayhead)
        rebuildInspector()
        let linkedPairs = Set(removed.compactMap(\.groupID)).count
        let linkedDetail = linkedPairs > 0 && removed.count > 1 ? " including linked video and sound" : ""
        status("Deleted \(removed.count) selected timeline clip\(removed.count == 1 ? "" : "s")\(linkedDetail). Source media remains in the Media Pool; use Undo to restore.")
    }
    private func primarySelectedVideo(in clips: [TimelineClip]? = nil) -> TimelineClip? {
        let source = clips ?? timelineClips
        if let id = selectedClipID, let clip = source.first(where: { $0.id == id && $0.kind == .video }) { return clip }
        return source.first { selectedClipIDs.contains($0.id) && $0.kind == .video }
    }
    @objc private func openShareStudio() {
        let server: LocalShareServer
        if let existing = shareServer {
            server = existing
        } else {
            server = LocalShareServer { [weak self] in
                guard let self else { return nil }
                if Thread.isMainThread { return self.currentShareSnapshot() }
                return DispatchQueue.main.sync { self.currentShareSnapshot() }
            }
            let controller = SharePanelViewController(server: server)
            controller.onStatus = { [weak self] message in self?.status(message) }
            let window = studioWindow(title: "Share to a Device", size: NSSize(width: 700, height: 690), controller: controller)
            window.minSize = NSSize(width: 580, height: 610)
            shareServer = server
            sharePanelController = controller
            shareWindow = window
        }
        shareWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        sharePanelController?.beginNewPairing()
        status("Starting local Share. Open the address on your iPad, then enter the temporary code.")
    }
    @objc private func openColorStudio() {
        let clip = primarySelectedVideo()
        if colorStudioController == nil {
            let controller = ColorStudioViewController()
            controller.onPreview = { [weak self] values in self?.receiveColorStudioPreview(values) }
            controller.onApply = { [weak self] values in self?.receiveColorStudioApply(values) }
            let window = studioWindow(title: "Color Studio", size: NSSize(width: 940, height: 820), controller: controller)
            window.minSize = NSSize(width: 760, height: 560)
            colorStudioController = controller; colorStudioWindow = window
        }
        colorStudioController?.load(clip.map(ColorControlValues.init) ?? ColorControlValues(), selectionName: clip?.name ?? "No video clip selected")
        colorStudioWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openEffectsStudio() {
        let clip = primarySelectedVideo()
        if effectsStudioController == nil {
            let controller = EffectsStudioViewController()
            controller.onPreview = { [weak self] values in self?.receiveEffectsStudioPreview(values) }
            controller.onApplyTransform = { [weak self] values in self?.receiveEffectsStudioTransform(values) }
            controller.onApplyEffects = { [weak self] values in self?.receiveEffectsStudioEffects(values) }
            controller.onApplyAll = { [weak self] values in self?.receiveEffectsStudioApplyAll(values) }
            controller.onKeyframe = { [weak self] values, property, interpolation in self?.receiveEffectsStudioKeyframe(values, property: property, interpolation: interpolation) }
            controller.onRemoveKeyframe = { [weak self] values, property in self?.receiveEffectsStudioRemoveKeyframe(values, property: property) }
            controller.onClearKeyframes = { [weak self] values, property in self?.receiveEffectsStudioClearKeyframes(values, property: property) }
            controller.onMoveKeyframe = { [weak self] property, id, time in self?.moveEffectsKeyframe(property: property, id: id, to: time) }
            controller.onSeekLocalTime = { [weak self] time in self?.seekEffectsPlayhead(to: time) }
            controller.onOverlayOptions = { [weak self] thirds, safe, bounds in
                self?.programGuideOverlay.showsThirds = thirds
                self?.programGuideOverlay.showsSafeMargins = safe
                self?.programGuideOverlay.showsTransformBounds = bounds
            }
            controller.onCancelPreview = { [weak self] in self?.cancelEffectsPreview() }
            controller.onReset = { [weak self] in self?.resetSelectedGrades() }
            let window = studioWindow(title: "Effect Controls", size: NSSize(width: 1080, height: 800), controller: controller)
            window.minSize = NSSize(width: 900, height: 600)
            effectsStudioController = controller; effectsStudioWindow = window
        }
        effectsStudioController?.load(clip.map(EffectControlValues.init) ?? EffectControlValues(), selectionName: clip?.name ?? "No video clip selected", property: activeKeyframeProperty, interpolation: activeKeyframeInterpolation, keyframeText: keyframeSummary(), clip: clip, timelineTime: timelineView.currentPlayheadTime)
        effectsStudioWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func studioWindow(title: String, size: NSSize, controller: NSViewController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.minSize = NSSize(width: 360, height: 480); window.isReleasedWhenClosed = false; window.contentViewController = controller; window.center()
        return window
    }
    private func receiveColorStudioPreview(_ values: ColorControlValues) { setColorControls(values); previewGrade() }
    private func receiveColorStudioApply(_ values: ColorControlValues) { setColorControls(values); applyColorGrade() }
    private func receiveEffectsStudioPreview(_ values: EffectControlValues) { setEffectControls(values); previewEffects() }
    private func receiveEffectsStudioTransform(_ values: EffectControlValues) { setEffectControls(values); applyTransform() }
    private func receiveEffectsStudioEffects(_ values: EffectControlValues) { setEffectControls(values); applyEffects() }
    private func receiveEffectsStudioApplyAll(_ values: EffectControlValues) {
        setEffectControls(values)
        let count = mutateSelectedVideoClips(action: "Effect Controls") { clip in
            self.applyTransformControls(to: &clip)
            self.applyEffectControls(to: &clip)
        }
        guard count > 0 else { return }
        if let primary = primarySelectedVideo() { loadEditingControls(from: primary) }
        status("Applied Motion, Opacity and effects to \(count) selected clip\(count == 1 ? "" : "s").")
    }
    private func receiveEffectsStudioKeyframe(_ values: EffectControlValues, property: AnimatableProperty, interpolation: KeyframeInterpolation) {
        setEffectControls(values); activeKeyframeProperty = property; activeKeyframeInterpolation = interpolation; addKeyframeAtPlayhead()
    }
    private func receiveEffectsStudioRemoveKeyframe(_ values: EffectControlValues, property: AnimatableProperty) {
        setEffectControls(values); activeKeyframeProperty = property; removeKeyframeAtPlayhead()
    }
    private func receiveEffectsStudioClearKeyframes(_ values: EffectControlValues, property: AnimatableProperty) {
        setEffectControls(values); activeKeyframeProperty = property; clearSelectedKeyframes()
    }
    private func cancelEffectsPreview() {
        TimelineLiveEffectStore.shared.clear()
        guard !timelineClips.isEmpty else { return }
        previewTimeline(at: timelineView.currentPlayheadTime)
        status("Live effects preview reverted to the saved clip settings.")
    }
    private func seekEffectsPlayhead(to localTime: Double) {
        guard let clip = primarySelectedVideo() else { return }
        let duration = max(1.0 / 30.0, clipDuration(clip))
        let absolute = clip.timelineStart + min(duration, max(0, localTime))
        timelineView.updatePlaybackPlayhead(absolute)
        timelinePlayheadSelected(to: absolute)
    }
    private func moveEffectsKeyframe(property: AnimatableProperty, id: UUID, to localTime: Double) {
        guard let clipID = primarySelectedVideo()?.id,
              let clipIndex = timelineClips.firstIndex(where: { $0.id == clipID }),
              let channelIndex = timelineClips[clipIndex].animation.channels.firstIndex(where: { $0.property == property }),
              let frameIndex = timelineClips[clipIndex].animation.channels[channelIndex].keyframes.firstIndex(where: { $0.id == id }) else { return }
        var updated = timelineClips
        let duration = clipDuration(updated[clipIndex])
        updated[clipIndex].animation.channels[channelIndex].keyframes[frameIndex].time = min(duration, max(0, (localTime * 30).rounded() / 30))
        updated[clipIndex].animation.channels[channelIndex].keyframes.sort { $0.time < $1.time }
        activeKeyframeProperty = property
        replaceTimeline(
            updated,
            action: "Move Keyframe",
            selection: selectedClipIDs,
            primary: selectedClipID,
            playhead: timelineView.currentPlayheadTime
        )
        if let clip = primarySelectedVideo() { loadEditingControls(from: clip) }
    }
    private func setColorControls(_ values: ColorControlValues) {
        brightnessSlider.doubleValue = values.brightness; contrastSlider.doubleValue = values.contrast; saturationSlider.doubleValue = values.saturation; gammaSlider.doubleValue = values.gamma; temperatureSlider.doubleValue = values.temperature
        exposureSlider.doubleValue = values.exposure; tintSlider.doubleValue = values.tint; highlightsSlider.doubleValue = values.highlights; shadowsSlider.doubleValue = values.shadows; vibranceSlider.doubleValue = values.vibrance; hueSlider.doubleValue = values.hue
        liftColorControl = values.lift; midtoneColorControl = values.midtones; gainColorControl = values.gain
        cubeLUTColorControl = values.cubeLUT
    }
    private func setEffectControls(_ values: EffectControlValues) {
        advancedEffectControl = values.effects
        positionXSlider.doubleValue = values.transform.positionX; positionYSlider.doubleValue = values.transform.positionY; scaleSlider.doubleValue = values.transform.scale; rotationSlider.doubleValue = values.transform.rotation; opacitySlider.doubleValue = values.transform.opacity
        blurSlider.doubleValue = values.effects.blurRadius; sharpenSlider.doubleValue = values.effects.sharpenAmount; vignetteSlider.doubleValue = values.effects.vignetteIntensity; monochromeSlider.doubleValue = values.effects.monochromeAmount; sepiaSlider.doubleValue = values.effects.sepiaAmount
    }
    @discardableResult
    private func mutateSelectedVideoClips(action: String, _ change: (inout TimelineClip) -> Void) -> Int {
        guard !selectedClipIDs.isEmpty else { status("Select one or more video clips first."); return 0 }
        var updated = timelineClips
        var count = 0
        for index in updated.indices where selectedClipIDs.contains(updated[index].id) && updated[index].kind == .video {
            change(&updated[index])
            count += 1
        }
        guard count > 0 else { status("Select a video clip before using this control."); return 0 }
        replaceTimeline(
            updated,
            action: action,
            selection: selectedClipIDs,
            primary: selectedClipID,
            playhead: timelineView.currentPlayheadTime
        )
        return count
    }
    private func loadEditingControls(from clip: TimelineClip) {
        setColorControls(ColorControlValues(clip)); setEffectControls(EffectControlValues(clip))
        audioVolumeSlider.doubleValue = clip.volume
        colorStudioController?.load(ColorControlValues(clip), selectionName: clip.name)
        effectsStudioController?.load(EffectControlValues(clip), selectionName: clip.name, property: activeKeyframeProperty, interpolation: activeKeyframeInterpolation, keyframeText: keyframeSummary(), clip: clip, timelineTime: timelineView.currentPlayheadTime)
    }
    private func applyColorControls(to clip: inout TimelineClip) {
        clip.brightness = brightnessSlider.doubleValue; clip.contrast = contrastSlider.doubleValue; clip.saturation = saturationSlider.doubleValue; clip.gamma = gammaSlider.doubleValue; clip.temperature = temperatureSlider.doubleValue
        clip.colorExtras.exposure = exposureSlider.doubleValue; clip.colorExtras.tint = tintSlider.doubleValue; clip.colorExtras.highlights = highlightsSlider.doubleValue; clip.colorExtras.shadows = shadowsSlider.doubleValue; clip.colorExtras.vibrance = vibranceSlider.doubleValue; clip.colorExtras.hue = hueSlider.doubleValue
        clip.colorExtras.lift = liftColorControl; clip.colorExtras.midtones = midtoneColorControl; clip.colorExtras.gain = gainColorControl
        clip.colorExtras.cubeLUT = cubeLUTColorControl
    }
    private func applyEffectControls(to clip: inout TimelineClip) {
        advancedEffectControl.blurRadius = blurSlider.doubleValue
        advancedEffectControl.sharpenAmount = sharpenSlider.doubleValue
        advancedEffectControl.vignetteIntensity = vignetteSlider.doubleValue
        advancedEffectControl.monochromeAmount = monochromeSlider.doubleValue
        advancedEffectControl.sepiaAmount = sepiaSlider.doubleValue
        clip.effects = advancedEffectControl
    }
    private func applyTransformControls(to clip: inout TimelineClip) {
        clip.transform.positionX = positionXSlider.doubleValue; clip.transform.positionY = positionYSlider.doubleValue; clip.transform.scale = scaleSlider.doubleValue; clip.transform.rotation = rotationSlider.doubleValue; clip.transform.opacity = opacitySlider.doubleValue
    }
    private func controlValue(for property: AnimatableProperty) -> Double {
        switch property {
        case .positionX: return positionXSlider.doubleValue
        case .positionY: return positionYSlider.doubleValue
        case .scale: return scaleSlider.doubleValue
        case .rotation: return rotationSlider.doubleValue
        case .opacity: return opacitySlider.doubleValue
        case .brightness: return brightnessSlider.doubleValue
        case .contrast: return contrastSlider.doubleValue
        case .saturation: return saturationSlider.doubleValue
        case .gamma: return gammaSlider.doubleValue
        case .temperature: return temperatureSlider.doubleValue
        case .tint: return tintSlider.doubleValue
        case .exposure: return exposureSlider.doubleValue
        case .highlights: return highlightsSlider.doubleValue
        case .shadows: return shadowsSlider.doubleValue
        case .vibrance: return vibranceSlider.doubleValue
        case .hue: return hueSlider.doubleValue
        case .blurRadius: return blurSlider.doubleValue
        case .sharpenAmount: return sharpenSlider.doubleValue
        case .vignetteIntensity: return vignetteSlider.doubleValue
        case .monochromeAmount: return monochromeSlider.doubleValue
        case .sepiaAmount: return sepiaSlider.doubleValue
        case .cropLeft: return advancedEffectControl.crop.left
        case .cropRight: return advancedEffectControl.crop.right
        case .cropTop: return advancedEffectControl.crop.top
        case .cropBottom: return advancedEffectControl.crop.bottom
        case .ultraKeyTolerance: return advancedEffectControl.ultraKey.tolerance
        case .ultraKeySoftness: return advancedEffectControl.ultraKey.soften
        case .ultraKeyChoke: return advancedEffectControl.ultraKey.choke
        case .ultraKeySpill: return advancedEffectControl.ultraKey.spill
        case .volume: return audioVolumeSlider.doubleValue
        }
    }
    @objc private func applyColorGrade() {
        let count = mutateSelectedVideoClips(action: "Color Grade") { self.applyColorControls(to: &$0) }
        guard count > 0 else { return }
        if let primary = primarySelectedVideo() { preview(primary.url, grade: primary) }
        status("Applied color grade to \(count) video clip\(count == 1 ? "" : "s").")
    }
    @objc private func previewGrade() {
        guard var previewClip = primarySelectedVideo() else { status("Select a video clip to preview a grade."); return }
        applyColorControls(to: &previewClip)
        preview(previewClip.url, grade: previewClip)
    }
    @objc private func resetColorGrade() {
        brightnessSlider.doubleValue = 0; contrastSlider.doubleValue = 1; saturationSlider.doubleValue = 1; gammaSlider.doubleValue = 1; temperatureSlider.doubleValue = 6500
        exposureSlider.doubleValue = 0; tintSlider.doubleValue = 0; highlightsSlider.doubleValue = 0; shadowsSlider.doubleValue = 0; vibranceSlider.doubleValue = 0; hueSlider.doubleValue = 0
        liftColorControl = .init(); midtoneColorControl = .init(); gainColorControl = .init()
        cubeLUTColorControl = nil
        colorStudioController?.resetWheels()
        colorStudioController?.resetLUT()
        applyColorGrade()
    }
    @objc private func previewEffects() {
        let overrides = timelineClips.compactMap { saved -> TimelineClip? in
            guard selectedClipIDs.contains(saved.id), saved.kind == .video else { return nil }
            var previewClip = saved
            applyEffectControls(to: &previewClip)
            applyTransformControls(to: &previewClip)
            return previewClip
        }
        guard !overrides.isEmpty else { status("Select a video or rendered 3D clip to preview effects."); return }
        TimelineLiveEffectStore.shared.replace(with: overrides)
        player.pause()
        previewTimeline(at: timelineView.currentPlayheadTime)
        status("Live effects preview — Apply to save these controls.")
    }
    @objc private func applyTransform() {
        let count = mutateSelectedVideoClips(action: "Transform") { self.applyTransformControls(to: &$0) }
        guard count > 0 else { return }
        status("Applied transform to \(count) video clip\(count == 1 ? "" : "s").")
    }
    @objc private func applyEffects() {
        let count = mutateSelectedVideoClips(action: "Effects") { self.applyEffectControls(to: &$0) }
        guard count > 0 else { return }
        status("Applied effects to \(count) video clip\(count == 1 ? "" : "s").")
    }
    @objc private func applyBlackAndWhite() { monochromeSlider.doubleValue = 1; saturationSlider.doubleValue = 0; applyEffects(); applyColorGrade() }
    @objc private func applyVividEffect() { contrastSlider.doubleValue = 1.18; saturationSlider.doubleValue = 1.25; vibranceSlider.doubleValue = 0.35; applyColorGrade() }
    @objc private func applyWarmLook() { temperatureSlider.doubleValue = 7800; tintSlider.doubleValue = 12; exposureSlider.doubleValue = 0.08; saturationSlider.doubleValue = 1.08; applyColorGrade() }
    @objc private func applyCoolLook() { temperatureSlider.doubleValue = 4600; tintSlider.doubleValue = -8; exposureSlider.doubleValue = -0.03; saturationSlider.doubleValue = 0.96; applyColorGrade() }
    @objc private func applyCinemaLook() { contrastSlider.doubleValue = 1.18; saturationSlider.doubleValue = 0.88; shadowsSlider.doubleValue = 0.18; highlightsSlider.doubleValue = 0.16; vibranceSlider.doubleValue = 0.14; applyColorGrade() }
    @objc private func applySoftGlow() { blurSlider.doubleValue = 0.8; vignetteSlider.doubleValue = 0.25; applyEffects() }
    @objc private func applyVintageLook() { sepiaSlider.doubleValue = 0.55; vignetteSlider.doubleValue = 0.48; saturationSlider.doubleValue = 0.82; contrastSlider.doubleValue = 0.92; applyEffects(); applyColorGrade() }
    @objc private func resetSelectedGrades() {
        let count = mutateSelectedVideoClips(action: "Reset Effects") { clip in clip.effects = .init(); clip.transform = .init(); clip.animation.channels.removeAll() }
        guard count > 0 else { return }
        if let primary = primarySelectedVideo() { loadEditingControls(from: primary) }
        rebuildInspector()
        status("Reset effects, transforms, and transform keyframes on \(count) video clip\(count == 1 ? "" : "s").")
    }
    @objc private func changeActiveKeyframeProperty(_ sender: NSPopUpButton) {
        guard transformKeyframeProperties.indices.contains(sender.indexOfSelectedItem) else { return }
        activeKeyframeProperty = transformKeyframeProperties[sender.indexOfSelectedItem]
        rebuildInspector()
    }
    @objc private func changeKeyframeInterpolation(_ sender: NSPopUpButton) {
        let choices: [KeyframeInterpolation] = [.easeInOut, .linear, .hold]
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        activeKeyframeInterpolation = choices[sender.indexOfSelectedItem]
    }
    @objc private func addKeyframeAtPlayhead() {
        let time = timelineView.currentPlayheadTime
        let value = controlValue(for: activeKeyframeProperty)
        let count = mutateSelectedVideoClips(action: "Add Keyframe") { clip in
            clip.setBaseValue(value, for: self.activeKeyframeProperty)
            clip.animation.setKeyframe(property: self.activeKeyframeProperty, time: clip.localTime(at: time), value: value, interpolation: self.activeKeyframeInterpolation)
        }
        guard count > 0 else { return }
        rebuildInspector()
        if let clip = primarySelectedVideo() { loadEditingControls(from: clip) }
        status("Keyframe added for \(activeKeyframeProperty.title) at \(formattedTime(time)).")
    }
    @objc private func removeKeyframeAtPlayhead() {
        let time = timelineView.currentPlayheadTime
        let count = mutateSelectedVideoClips(action: "Remove Keyframe") { clip in clip.animation.removeKeyframe(property: self.activeKeyframeProperty, near: clip.localTime(at: time)) }
        guard count > 0 else { return }
        rebuildInspector()
        if let clip = primarySelectedVideo() { loadEditingControls(from: clip) }
        status("Removed \(activeKeyframeProperty.title) keyframe at the playhead.")
    }
    @objc private func clearSelectedKeyframes() {
        let count = mutateSelectedVideoClips(action: "Clear Keyframes") { clip in clip.animation.channels.removeAll { $0.property == self.activeKeyframeProperty } }
        guard count > 0 else { return }
        rebuildInspector()
        if let clip = primarySelectedVideo() { loadEditingControls(from: clip) }
        status("Cleared \(activeKeyframeProperty.title) keyframes on \(count) selected clip\(count == 1 ? "" : "s").")
    }
    private func formattedTime(_ time: Double) -> String {
        let frames = Int((max(0, time) * 30).rounded())
        return String(format: "%02d:%02d:%02d", frames / 1800, (frames / 30) % 60, frames % 30)
    }
    private func keyframeSummary() -> String {
        guard let clip = primarySelectedVideo() else { return "Select a video clip to add transform keyframes." }
        let visibleDuration = clipDuration(clip)
        let frames = clip.animation.channels
            .flatMap { channel in
                channel.keyframes
                    .filter { $0.time >= 0 && $0.time <= visibleDuration + (1.0 / 60.0) }
                    .map { (channel.property, $0) }
            }
            .sorted { $0.1.time < $1.1.time }
        guard !frames.isEmpty else { return "No keyframes on this clip yet. Set a value, move the playhead, then add a keyframe." }
        let text = frames.prefix(8).map { "♦ \($0.0.title) · \(formattedTime(clip.timelineStart + $0.1.time))" }.joined(separator: "\n")
        return frames.count > 8 ? text + "\n+ \(frames.count - 8) more" : text
    }
    @objc private func previewAudioVolume() { player.volume = Float(audioVolumeSlider.doubleValue) }
    @objc private func applyAudioVolume() {
        let audioIDs = Set(timelineClips.filter { selectedClipIDs.contains($0.id) && $0.kind == .audio }.map(\.id))
        guard !audioIDs.isEmpty else { status("Select one or more audio clips before changing volume."); return }
        var updated = timelineClips
        for index in updated.indices where audioIDs.contains(updated[index].id) { updated[index].volume = audioVolumeSlider.doubleValue }
        replaceTimeline(updated, action: "Audio Volume")
        player.volume = Float(audioVolumeSlider.doubleValue)
        status("Applied volume to \(audioIDs.count) audio clip\(audioIDs.count == 1 ? "" : "s").")
    }
    @objc private func detachSelectedAudio() {
        let audioIDs = Set(timelineClips.filter { selectedClipIDs.contains($0.id) && $0.kind == .audio }.map(\.id))
        guard !audioIDs.isEmpty else { status("Select a linked audio clip in A1 or A2 before detaching it."); return }
        var updated = timelineClips
        for index in updated.indices where audioIDs.contains(updated[index].id) { updated[index].groupID = nil }
        let primary = updated.first(where: { audioIDs.contains($0.id) })
        replaceTimeline(
            updated,
            action: "Detach Audio",
            selection: audioIDs,
            primary: primary?.id,
            playhead: timelineView.currentPlayheadTime
        )
        status("Audio detached. Drag it independently in time or onto Audio 1 / Audio 2.")
    }
    @objc private func muteSelectedAudio() { audioVolumeSlider.doubleValue = 0; applyAudioVolume() }
    @objc private func selectAllTimeline() {
        let audio = timelineClips.filter { $0.kind == .audio }
        selectedClipIDs = Set(audio.map(\.id)); selectedClipID = audio.first?.id
        if let first = audio.first { audioVolumeSlider.doubleValue = first.volume }
        reloadTimeline(); status(audio.isEmpty ? "There are no audio clips on A1 yet." : "Selected \(audio.count) audio clip(s) on A1.")
    }
    private func selectedSceneID() -> UUID? {
        if let selectedClipID, let sceneID = timelineClips.first(where: { $0.id == selectedClipID })?.sceneID { return sceneID }
        return timelineClips.first(where: { selectedClipIDs.contains($0.id) && $0.sceneID != nil })?.sceneID
    }

    private func ensureSceneEditor() -> SceneEditorWindowController {
        if let sceneEditorWindow { return sceneEditorWindow }
        let controller = SceneEditorWindowController { [weak self] renderedClip in
            self?.receiveRenderedScene(renderedClip)
        }
        sceneEditorWindow = controller
        return controller
    }

    @objc private func open3DSceneEditor() {
        ensureSceneEditor().showSceneEditor()
        status("3D Scene Editor opened. Save your project to keep editable work; Render Clip is optional.")
    }

    @objc private func startNew3DScene() {
        if let editor = sceneEditorWindow?.sceneEditor {
            let snapshot = editor.snapshotDocument()
            let existingID = snapshot.projectSceneID ?? sceneIDFromEditor(editor)
            if existingID != nil || snapshot != NetVistaSceneDocument() {
                _ = syncOpenSceneIntoProject()
            }
        }

        let sceneID = UUID()
        var document = NetVistaSceneDocument()
        document.projectSceneID = sceneID
        document.title = "3D Scene \(storedScenes.count + 1)"
        storedScenes.append(StoredScene(id: sceneID, document: document))
        activeSceneID = sceneID

        let window = ensureSceneEditor()
        window.sceneEditor.replaceDocument(document, sourceURL: sceneMarkerURL(sceneID))
        window.showSceneEditor()
        refresh3DProjectUI()
        status("Created \(document.title). It is editable project data; rendering is optional.")
    }

    @objc private func openSavedScene(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let sceneID = UUID(uuidString: value) else {
            status("That saved 3D scene could not be identified.")
            return
        }
        openSceneClip(sceneID: sceneID)
    }

    @objc private func editSelected3DScene() {
        guard let sceneID = selectedSceneID(), let stored = storedScenes.first(where: { $0.id == sceneID }) else {
            status("Select a rendered 3D scene clip first.")
            return
        }
        openSceneClip(sceneID: stored.id)
    }

    private func sceneMarkerURL(_ sceneID: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("netvista-studio-scene-\(sceneID.uuidString)")
            .appendingPathExtension("netvistascene")
    }

    func openSceneClip(sceneID: UUID) {
        if let editor = sceneEditorWindow?.sceneEditor {
            let snapshot = editor.snapshotDocument()
            let currentID = snapshot.projectSceneID ?? sceneIDFromEditor(editor)
            if currentID == sceneID {
                activeSceneID = sceneID
                ensureSceneEditor().showSceneEditor()
                status("Continuing 3D scene: \(snapshot.title)")
                return
            }
            if currentID != sceneID && (currentID != nil || snapshot != NetVistaSceneDocument()) {
                _ = syncOpenSceneIntoProject()
            }
        }
        guard let stored = storedScenes.first(where: { $0.id == sceneID }) else {
            status("The editable scene data is missing from this project.")
            return
        }
        if currentPage != .scene3D { selectPage(.scene3D) }
        activeSceneID = sceneID
        var document = stored.document
        document.projectSceneID = sceneID
        if let index = storedScenes.firstIndex(where: { $0.id == sceneID }) { storedScenes[index].document = document }
        let window = ensureSceneEditor()
        window.sceneEditor.replaceDocument(document, sourceURL: sceneMarkerURL(sceneID))
        window.showSceneEditor()
        status("Editing 3D scene: \(stored.document.title)")
    }

    private func refresh3DProjectUI() {
        guard currentPage == .scene3D else { return }
        rebuildInspector()
        rebuildWorkspace()
    }

    private func sceneIDFromEditor(_ editor: SceneEditorViewController) -> UUID? {
        guard let name = editor.documentURL?.deletingPathExtension().lastPathComponent else { return nil }
        let compatiblePrefixes = ["netvista-studio-scene-", "swift-editer-scene-"]
        guard let prefix = compatiblePrefixes.first(where: { name.hasPrefix($0) }) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count)))
    }

    private func receiveRenderedScene(_ rendered: SceneRenderedClip) {
        guard let editor = sceneEditorWindow?.sceneEditor else { return }
        var document = editor.snapshotDocument()
        let sceneID = document.projectSceneID ?? sceneIDFromEditor(editor) ?? UUID()
        document.projectSceneID = sceneID
        if let sceneIndex = storedScenes.firstIndex(where: { $0.id == sceneID }) {
            let oldDuration = storedScenes[sceneIndex].document.duration
            let assetID = storedScenes[sceneIndex].mediaAssetID
            storedScenes[sceneIndex].document = document
            storedScenes[sceneIndex].renderedURL = rendered.url
            if let assetIndex = media.firstIndex(where: { $0.id == assetID }) {
                media[assetIndex].name = rendered.suggestedName
                media[assetIndex].url = rendered.url
                media[assetIndex].duration = rendered.duration
            } else {
                media.append(MediaAsset(id: assetID, name: rendered.suggestedName, url: rendered.url, kind: .video, duration: rendered.duration, hasAudio: false))
            }
            var updated = timelineClips
            var updatedSceneClip = false
            for index in updated.indices where updated[index].sceneID == sceneID {
                updatedSceneClip = true
                updated[index].name = rendered.suggestedName
                updated[index].url = rendered.url
                if abs(updated[index].outPoint - oldDuration) < (1.0 / 30.0) {
                    updated[index].outPoint = rendered.duration
                } else {
                    updated[index].outPoint = min(rendered.duration, max(updated[index].inPoint + (1.0 / 30.0), updated[index].outPoint))
                }
            }
            if !updatedSceneClip {
                let restored = TimelineClip(assetID: assetID, name: rendered.suggestedName, url: rendered.url, outPoint: rendered.duration, timelineStart: nextTimelineStart(for: 0, kind: .video), track: 0, kind: .video, sceneID: sceneID)
                updated.append(restored)
            }
            activeSceneID = sceneID
            let sceneSelection = updated.filter { $0.sceneID == sceneID }.map(\.id)
            let primary = updated.first { $0.sceneID == sceneID }
            replaceTimeline(
                updated,
                action: "Update 3D Scene",
                selection: Set(sceneSelection),
                primary: primary?.id,
                playhead: primary?.timelineStart ?? timelineView.currentPlayheadTime
            )
            reloadMedia()
            refresh3DProjectUI()
            status("Updated the editable 3D scene and every matching timeline clip.")
            return
        }

        let stored = StoredScene(id: sceneID, document: document, renderedURL: rendered.url)
        storedScenes.append(stored)
        let asset = MediaAsset(id: stored.mediaAssetID, name: rendered.suggestedName, url: rendered.url, kind: .video, duration: rendered.duration, hasAudio: false)
        media.append(asset)
        let clip = TimelineClip(
            assetID: asset.id,
            name: asset.name,
            url: asset.url,
            outPoint: rendered.duration,
            timelineStart: nextTimelineStart(for: 0, kind: .video),
            track: 0,
            kind: .video,
            sceneID: sceneID
        )
        selectedAssetID = asset.id
        activeSceneID = sceneID
        // Mark this newly rendered document as project-backed so another
        // render updates it instead of creating a duplicate scene entry.
        editor.replaceDocument(document, sourceURL: sceneMarkerURL(sceneID))
        replaceTimeline(
            timelineClips + [clip],
            action: "Add 3D Scene",
            selection: [clip.id],
            primary: clip.id,
            playhead: clip.timelineStart
        )
        reloadMedia()
        refresh3DProjectUI()
        status("Rendered 3D scene added to the Media Pool and timeline. Double-click it to edit again.")
    }

    private func currentProjectFile() -> ProjectFile {
        syncOpenSceneIntoProject()
        let title = projectTitle.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProjectFile(title: title.isEmpty ? "Untitled Project" : title, media: media, timeline: timelineClips, scenes: storedScenes)
    }

    /// Creates a path-free, immutable view of the live project for the LAN
    /// companion. Original file URLs never leave this controller; the server
    /// receives only approved media IDs mapped to files it may stream.
    private func currentShareSnapshot() -> ShareProjectSnapshot? {
        dispatchPrecondition(condition: .onQueue(.main))
        let project = currentProjectFile()
        let finite: (Double) -> Double = { $0.isFinite ? max(0, $0) : 0 }
        let duration = project.timeline.map { finite($0.timelineStart) + finite($0.outPoint > $0.inPoint ? $0.outPoint - $0.inPoint : 6) }.max() ?? 0
        let fileManager = FileManager.default
        let sharedMedia: [ShareMediaResource] = project.media.compactMap { asset in
            var isDirectory: ObjCBool = false
            guard asset.url.isFileURL,
                  fileManager.fileExists(atPath: asset.url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return ShareMediaResource(
                id: asset.id,
                name: asset.name,
                kind: asset.kind.rawValue,
                duration: finite(asset.duration),
                fileURL: asset.url
            )
        }
        let sharedIDs = Set(sharedMedia.map(\.id))
        let mediaSummary: [[String: Any]] = project.media.map { asset in
            [
                "id": asset.id.uuidString,
                "name": asset.name,
                "kind": asset.kind.rawValue,
                "duration": finite(asset.duration),
                "hasAudio": asset.hasAudio,
                "availableToThisDevice": sharedIDs.contains(asset.id)
            ]
        }
        let timelineSummary: [[String: Any]] = project.timeline.map { clip in
            [
                "id": clip.id.uuidString,
                "assetID": clip.assetID.uuidString,
                "name": clip.name,
                "kind": clip.kind.rawValue,
                "track": max(0, clip.track),
                "timelineStart": finite(clip.timelineStart),
                "inPoint": finite(clip.inPoint),
                "outPoint": finite(clip.outPoint),
                "duration": finite(clip.outPoint > clip.inPoint ? clip.outPoint - clip.inPoint : 6),
                "keyframeCount": clip.animation.channels.reduce(0) { $0 + $1.keyframes.count }
            ]
        }
        let sceneSummary: [[String: Any]] = project.scenes.map { scene in
            [
                "id": scene.id.uuidString,
                "title": scene.document.title,
                "duration": finite(scene.document.duration),
                "framesPerSecond": max(1, scene.document.framesPerSecond),
                "objectCount": scene.document.objects.count,
                "objects": scene.document.objects.map { ["id": $0.id.uuidString, "name": $0.name, "kind": $0.kind.rawValue] }
            ]
        }
        let manifest: [String: Any] = [
            "format": "NetVista Studio Share Summary",
            "version": 1,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "project": [
                "title": project.title,
                "mediaCount": project.media.count,
                "timelineClipCount": project.timeline.count,
                "sceneCount": project.scenes.count,
                "timelineDuration": finite(duration)
            ],
            "media": mediaSummary,
            "timeline": timelineSummary,
            "scenes": sceneSummary
        ]
        guard let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return ShareProjectSnapshot(
            title: project.title,
            mediaCount: project.media.count,
            clipCount: project.timeline.count,
            sceneCount: project.scenes.count,
            timelineDuration: duration,
            manifestData: manifestData,
            manifestFilename: "\(project.title) Share Summary.json",
            media: sharedMedia
        )
    }

    @objc private func saveProject() {
        let panel = NSSavePanel()
        panel.title = "Save NetVista Studio Project"
        setDownloadsAsInitialDirectory(for: panel)
        panel.nameFieldStringValue = "\(projectTitle.stringValue).netvistastudio"
        panel.allowedContentTypes = [UTType(filenameExtension: "netvistastudio")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let project = currentProjectFile()
            try JSONEncoder().encode(project).write(to: url, options: .atomic)
            status("Saved \(url.lastPathComponent), including \(storedScenes.count) editable 3D scene(s).")
            refresh3DProjectUI()
        } catch {
            status("Could not save: \(error.localizedDescription)")
        }
    }

    /// Captures the live native scene directly into project data. A render URL
    /// is deliberately not required: the reserved media ID becomes useful only
    /// if the user later chooses Render Clip.
    @discardableResult
    private func syncOpenSceneIntoProject() -> UUID? {
        guard let editor = sceneEditorWindow?.sceneEditor else { return nil }
        var document = editor.snapshotDocument()
        let sceneID = document.projectSceneID ?? sceneIDFromEditor(editor) ?? UUID()
        let needsIdentityInjection = document.projectSceneID != sceneID
        document.projectSceneID = sceneID
        if let index = storedScenes.firstIndex(where: { $0.id == sceneID }) {
            storedScenes[index].document = document
        } else {
            storedScenes.append(StoredScene(id: sceneID, document: document))
        }
        activeSceneID = sceneID
        if needsIdentityInjection {
            editor.replaceDocument(document, sourceURL: sceneMarkerURL(sceneID))
        }
        return sceneID
    }

    @objc private func openProjectPicker() {
        let panel = NSOpenPanel()
        panel.title = "Open NetVista Studio Project"
        setDownloadsAsInitialDirectory(for: panel)
        panel.allowedContentTypes = ["netvistastudio", "swiftediter"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    func openProject(at url: URL) {
        do {
            let project = try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: url))
            // A listener is deliberately scoped to the project the user chose
            // to share. Opening another project requires pressing Share again.
            shareServer?.stop()
            sceneEditorWindow?.close()
            sceneEditorWindow = nil
            projectTitle.stringValue = project.title
            media = project.media
            timelineClips = project.timeline
            storedScenes = project.scenes.map { stored in
                var compatible = stored
                if compatible.document.projectSceneID == nil { compatible.document.projectSceneID = compatible.id }
                return compatible
            }
            activeSceneID = nil
            player.pause()
            timelineSeekGeneration += 1
            clearTimelineItemObservers()
            player.replaceCurrentItem(with: nil)
            previewingTimeline = false
            timelinePreviewNeedsRebuild = true
            timelinePreviewComposition = nil
            timelinePreviewVideoComposition = nil
            timelinePreviewAudioMix = nil
            timelinePreviewItem = nil
            timelinePreviewDuration = 0
            timelinePreviewSkippedNames = []
            timelinePreviewVideoRanges = []
            selectedClipID = timelineClips.first?.id
            if let id = selectedClipID { selectedClipIDs = [id] } else { selectedClipIDs.removeAll() }
            selectedAssetID = timelineClips.first?.assetID ?? media.first?.id
            reloadMedia()
            reloadTimeline(resetTrackStructure: true)
            if !timelineClips.isEmpty {
                selectTimeline(index: 0)
            } else {
                emptyPreviewLabel.stringValue = "Import media or drag a clip onto the timeline"
                emptyPreviewLabel.isHidden = false
            }
            // Undo history belongs to the project it was created in. Keeping
            // it here could reinsert clips or media from the previously open
            // project into this one.
            projectUndoManager.removeAllActions()
            refresh3DProjectUI()
            status("Opened \(url.lastPathComponent) with \(storedScenes.count) editable 3D scene(s).")
        } catch {
            status("Could not open: \(error.localizedDescription)")
        }
    }

    func openScene(at url: URL) {
        let window = ensureSceneEditor()
        do {
            try window.sceneEditor.loadScene(from: url)
            activeSceneID = window.sceneEditor.document.projectSceneID
            if currentPage != .scene3D { selectPage(.scene3D) }
            window.showSceneEditor()
            status("Opened 3D scene \(url.lastPathComponent).")
        } catch {
            status("Could not open 3D scene: \(error.localizedDescription)")
        }
    }

    @objc private func exportFromCurrentSettings() {
        let options = exportWorkspaceController?.selectedOptions ?? TimelineExportOptions()
        beginNativeExport(options: options)
    }

    private func beginNativeExport(options: TimelineExportOptions) {
        guard activeExportJob == nil else { status("An export is already running."); return }
        guard timelineClips.contains(where: { $0.kind == .video }) else { status("Add a video or rendered 3D scene to the timeline before exporting."); return }
        let panel = NSSavePanel()
        panel.title = "Export \(options.resolution.title) \(options.container.title)"
        setDownloadsAsInitialDirectory(for: panel)
        panel.nameFieldStringValue = "\(projectTitle.stringValue).\(options.container.fileExtension)"
        panel.allowedContentTypes = [options.container == .mp4 ? .mpeg4Movie : .quickTimeMovie]
        guard panel.runModal() == .OK, let output = panel.url else { return }
        exportWorkspaceController?.beginExport()
        status("Preparing \(options.resolution.title) export…")
        activeExportJob = NativeTimelineExportEngine.export(
            clips: timelineClips,
            to: output,
            options: options,
            progress: { [weak self] progress in
                self?.exportWorkspaceController?.update(progress: progress)
                self?.status("Exporting \(options.resolution.title)… \(progress.percent)%")
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.activeExportJob = nil
                switch result {
                case .success(let url):
                    self.exportWorkspaceController?.finishExport(message: "Complete — \(url.lastPathComponent)", succeeded: true)
                    self.status("Export complete: \(url.lastPathComponent)")
                case .failure(let error):
                    let message = error.localizedDescription
                    self.exportWorkspaceController?.finishExport(message: message, succeeded: false)
                    self.status(message)
                }
                self.rebuildInspector()
            }
        )
        rebuildInspector()
    }

    @objc private func cancelNativeExport() {
        guard let activeExportJob else { status("There is no active export to cancel."); return }
        activeExportJob.cancel()
        status("Cancelling export…")
    }

    /// Opens save panels in the user's Downloads folder without changing the
    /// URL they choose in the panel. This keeps common saves easy to find while
    /// still allowing projects and exports to be stored anywhere on the Mac.
    private func setDownloadsAsInitialDirectory(for panel: NSSavePanel) {
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    @objc private func checkForUpdates() {
        guard !updateRequestActive else { return }
        updateRequestActive = true
        updateButton?.isEnabled = false
        status("Checking GitHub for a NetVista Studio update…")
        appUpdateService.checkForUpdate { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateRequestActive = false
                self.updateButton?.isEnabled = true
                switch result {
                case .success(nil):
                    self.status("NetVista Studio \(self.appUpdateService.currentTag) is up to date.")
                    let alert = NSAlert()
                    alert.messageText = "You have the newest beta"
                    alert.informativeText = "NetVista Studio \(self.appUpdateService.currentTag) is the newest version currently published on GitHub."
                    alert.addButton(withTitle: "Done")
                    alert.runModal()
                case .success(.some(let update)):
                    self.presentAvailableUpdate(update)
                case .failure(let error):
                    self.status("Update check failed: \(error.localizedDescription)")
                    let alert = NSAlert(error: error)
                    alert.messageText = "Could not check for updates"
                    alert.informativeText = "Check your internet connection and try the Update button again.\n\n\(error.localizedDescription)"
                    alert.runModal()
                }
            }
        }
    }

    private func presentAvailableUpdate(_ update: NetVistaAvailableUpdate) {
        status("NetVista Studio \(update.release.tag) is available.")
        let alert = NSAlert()
        alert.messageText = "A newer NetVista Studio beta is available"
        alert.informativeText = "Installed: \(appUpdateService.currentTag)\nAvailable: \(update.release.tag)\n\nThis is beta software. Save your project before installing an update. The app will download the verified macOS package to Downloads; you choose when to quit and replace the current app."
        alert.addButton(withTitle: "Download update")
        alert.addButton(withTitle: "View release notes")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            downloadUpdate(update)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(update.release.pageURL)
        default:
            break
        }
    }

    private func downloadUpdate(_ update: NetVistaAvailableUpdate) {
        guard !updateRequestActive else { return }
        updateRequestActive = true
        updateButton?.isEnabled = false
        status("Downloading \(update.asset.name) to Downloads…")
        appUpdateService.download(update) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateRequestActive = false
                self.updateButton?.isEnabled = true
                switch result {
                case .success(let url):
                    self.status("Update downloaded and verified: \(url.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    let alert = NSAlert()
                    alert.messageText = "Update ready in Downloads"
                    alert.informativeText = "\(url.lastPathComponent) passed its size and SHA-256 safety checks. Save your work, quit NetVista Studio, open the ZIP, and move the new app into Applications."
                    alert.addButton(withTitle: "Done")
                    alert.runModal()
                case .failure(let error):
                    self.status("Update download failed: \(error.localizedDescription)")
                    let alert = NSAlert(error: error)
                    alert.messageText = "Could not download the update"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    private func status(_ text: String) { statusLabel.stringValue = text }
}

enum StudioPage: String, CaseIterable {
    case media = "Media", cut = "Cut", edit = "Edit", effects = "Effects", color = "Color", audio = "Audio", scene3D = "3D Scene", export = "Export"
    var icon: String {
        switch self {
        case .media: return "▦"
        case .cut: return "✂"
        case .edit: return "✣"
        case .effects: return "✧"
        case .color: return "◉"
        case .audio: return "♫"
        case .scene3D: return "◇"
        case .export: return "⇧"
        }
    }
}

/// Native, GPU-free interaction surface for a professional three-way color
/// wheel. The puck stores opponent-color RGB offsets; its luma control lives in
/// the surrounding panel so color and brightness can be adjusted separately.
final class ColorWheelControl: NSControl {
    var adjustment = ColorWheelAdjustment() { didSet { needsDisplay = true } }
    let chromaLimit: Double

    init(chromaLimit: Double = 0.24) {
        self.chromaLimit = chromaLimit
        super.init(frame: .zero)
        toolTip = "Drag toward a color to tint this tonal range. Double-click to center the color puck."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 174, height: 174) }

    private var wheelRect: NSRect {
        let side = max(20, min(bounds.width, bounds.height) - 10)
        return NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = wheelRect
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let circle = NSBezierPath(ovalIn: rect)

        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        let steps = 180
        for index in 0..<steps {
            let first = CGFloat(index) / CGFloat(steps) * 2 * .pi
            let second = CGFloat(index + 1) / CGFloat(steps) * 2 * .pi
            let path = NSBezierPath()
            path.move(to: centre)
            path.line(to: NSPoint(x: centre.x + cos(first) * radius * 1.03, y: centre.y - sin(first) * radius * 1.03))
            path.line(to: NSPoint(x: centre.x + cos(second) * radius * 1.03, y: centre.y - sin(second) * radius * 1.03))
            path.close()
            NSColor(calibratedHue: CGFloat(index) / CGFloat(steps), saturation: 0.92, brightness: 0.96, alpha: 1).setFill()
            path.fill()
        }
        if let wash = NSGradient(colorsAndLocations: (NSColor.white, 0), (NSColor.white.withAlphaComponent(0), 1)) {
            wash.draw(fromCenter: centre, radius: 0, toCenter: centre, radius: radius, options: [])
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.16).setStroke()
        circle.lineWidth = 1.5; circle.stroke()
        for fraction in [0.5, 0.75] {
            let guide = NSBezierPath(ovalIn: rect.insetBy(dx: radius * (1 - fraction), dy: radius * (1 - fraction)))
            guide.lineWidth = 0.5; guide.stroke()
        }
        let axes = NSBezierPath()
        axes.move(to: NSPoint(x: centre.x - radius, y: centre.y)); axes.line(to: NSPoint(x: centre.x + radius, y: centre.y))
        axes.move(to: NSPoint(x: centre.x, y: centre.y - radius)); axes.line(to: NSPoint(x: centre.x, y: centre.y + radius))
        axes.lineWidth = 0.5; axes.stroke()

        let mean = (adjustment.red + adjustment.green + adjustment.blue) / 3
        let red = adjustment.red - mean
        let green = adjustment.green - mean
        let blue = adjustment.blue - mean
        var x = (2 * red - green - blue) / (3 * chromaLimit)
        var y = (green - blue) / (sqrt(3) * chromaLimit)
        let length = sqrt(x * x + y * y)
        if length > 1 { x /= length; y /= length }
        let puck = NSPoint(x: centre.x + CGFloat(x) * radius, y: centre.y - CGFloat(y) * radius)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(ovalIn: NSRect(x: puck.x - 7, y: puck.y - 7, width: 14, height: 14)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: puck.x - 4.5, y: puck.y - 4.5, width: 9, height: 9)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount > 1 {
            adjustment.red = 0; adjustment.green = 0; adjustment.blue = 0
            sendAction(action, to: target); return
        }
        updatePuck(with: event)
    }
    override func mouseDragged(with event: NSEvent) { updatePuck(with: event) }

    private func updatePuck(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = wheelRect
        let radius = rect.width / 2
        guard radius > 0 else { return }
        var x = Double((point.x - rect.midX) / radius)
        var y = Double((rect.midY - point.y) / radius)
        let length = sqrt(x * x + y * y)
        if length > 1 { x /= length; y /= length }
        adjustment.red = chromaLimit * x
        adjustment.green = chromaLimit * (-0.5 * x + sqrt(3) / 2 * y)
        adjustment.blue = chromaLimit * (-0.5 * x - sqrt(3) / 2 * y)
        sendAction(action, to: target)
    }
}

final class ColorWheelPanel: NSView, NSTextFieldDelegate {
    var onChange: (() -> Void)?
    private let titleText: String
    private let detailText: String
    private let wheel: ColorWheelControl
    private let master = NSSlider(value: 0, minValue: -0.35, maxValue: 0.35, target: nil, action: nil)
    private let redField = NSTextField(string: "0.000")
    private let greenField = NSTextField(string: "0.000")
    private let blueField = NSTextField(string: "0.000")
    private let masterField = NSTextField(string: "0.000")

    var value: ColorWheelAdjustment {
        var result = wheel.adjustment
        result.master = master.doubleValue
        return result
    }

    init(title: String, detail: String, chromaLimit: Double) {
        titleText = title; detailText = detail; wheel = ColorWheelControl(chromaLimit: chromaLimit)
        super.init(frame: .zero)
        buildInterface()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ adjustment: ColorWheelAdjustment) {
        wheel.adjustment = adjustment
        master.doubleValue = adjustment.master
        updateFields()
    }

    private func buildInterface() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: "242932").cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10

        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 7; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 210)
        ])

        let title = NSTextField(labelWithString: titleText.uppercased()); title.font = .systemFont(ofSize: 12, weight: .semibold); title.textColor = .white; stack.addArrangedSubview(title)
        let detail = NSTextField(labelWithString: detailText); detail.font = .systemFont(ofSize: 9); detail.textColor = NSColor(hex: "A7AFBC"); stack.addArrangedSubview(detail)
        stack.addArrangedSubview(wheel)
        NSLayoutConstraint.activate([wheel.widthAnchor.constraint(equalToConstant: 174), wheel.heightAnchor.constraint(equalToConstant: 174)])
        wheel.target = self; wheel.action = #selector(wheelChanged)

        let masterTitle = NSTextField(labelWithString: "LUMA / MASTER"); masterTitle.font = .systemFont(ofSize: 8, weight: .bold); masterTitle.textColor = NSColor(hex: "A7AFBC"); stack.addArrangedSubview(masterTitle)
        master.target = self; master.action = #selector(masterChanged); master.isContinuous = true; stack.addArrangedSubview(master)
        master.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true

        let numbers = NSStackView(); numbers.orientation = .horizontal; numbers.spacing = 5; numbers.distribution = .fillEqually
        let numericFields: [(String, NSTextField)] = [("R", redField), ("G", greenField), ("B", blueField), ("M", masterField)]
        for (label, field) in numericFields {
            field.alignment = .right; field.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            field.textColor = .labelColor; field.backgroundColor = NSColor.black.withAlphaComponent(0.18); field.isBezeled = true
            field.target = self; field.action = #selector(numberChanged); field.delegate = self
            let column = NSStackView(); column.orientation = .vertical; column.alignment = .width; column.spacing = 2
            let caption = NSTextField(labelWithString: label); caption.alignment = .center; caption.font = .systemFont(ofSize: 8, weight: .bold); caption.textColor = NSColor(hex: "A7AFBC")
            column.addArrangedSubview(caption); column.addArrangedSubview(field); numbers.addArrangedSubview(column)
        }
        stack.addArrangedSubview(numbers); numbers.widthAnchor.constraint(greaterThanOrEqualToConstant: 188).isActive = true
        let reset = NSButton(title: "Reset \(titleText)", target: self, action: #selector(resetPanel)); reset.bezelStyle = .rounded; reset.font = .systemFont(ofSize: 10, weight: .medium); stack.addArrangedSubview(reset)
    }

    @objc private func wheelChanged() { updateFields(); onChange?() }
    @objc private func masterChanged() { wheel.adjustment.master = master.doubleValue; updateFields(); onChange?() }
    func controlTextDidEndEditing(_ obj: Notification) { numberChanged() }
    @objc private func numberChanged() {
        func number(_ field: NSTextField, fallback: Double, range: ClosedRange<Double>) -> Double {
            let parsed = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")) ?? fallback
            return min(range.upperBound, max(range.lowerBound, parsed))
        }
        var adjustment = wheel.adjustment
        let channelRange = (-wheel.chromaLimit)...wheel.chromaLimit
        adjustment.red = number(redField, fallback: adjustment.red, range: channelRange)
        adjustment.green = number(greenField, fallback: adjustment.green, range: channelRange)
        adjustment.blue = number(blueField, fallback: adjustment.blue, range: channelRange)
        adjustment.master = number(masterField, fallback: master.doubleValue, range: -0.35...0.35)
        wheel.adjustment = adjustment; master.doubleValue = adjustment.master
        updateFields(); onChange?()
    }
    @objc private func resetPanel() { load(.init()); onChange?() }

    private func updateFields() {
        let adjustment = value
        redField.stringValue = String(format: "%+.3f", adjustment.red)
        greenField.stringValue = String(format: "%+.3f", adjustment.green)
        blueField.stringValue = String(format: "%+.3f", adjustment.blue)
        masterField.stringValue = String(format: "%+.3f", adjustment.master)
    }
}

final class ColorStudioViewController: NSViewController {
    var onPreview: ((ColorControlValues) -> Void)?
    var onApply: ((ColorControlValues) -> Void)?

    private let selectionLabel = NSTextField(labelWithString: "No video clip selected")
    private let brightness = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let contrast = NSSlider(value: 1, minValue: 0.25, maxValue: 2, target: nil, action: nil)
    private let saturation = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let gamma = NSSlider(value: 1, minValue: 0.4, maxValue: 2.5, target: nil, action: nil)
    private let temperature = NSSlider(value: 6500, minValue: 2000, maxValue: 10000, target: nil, action: nil)
    private let exposure = NSSlider(value: 0, minValue: -3, maxValue: 3, target: nil, action: nil)
    private let tint = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    private let highlights = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let shadows = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let vibrance = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let hue = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    private let liftPanel = ColorWheelPanel(title: "Lift", detail: "Shadows & black point", chromaLimit: 0.18)
    private let midtonePanel = ColorWheelPanel(title: "Gamma", detail: "Midtones", chromaLimit: 0.16)
    private let gainPanel = ColorWheelPanel(title: "Gain", detail: "Highlights & white point", chromaLimit: 0.20)
    private let lutNameLabel = NSTextField(labelWithString: "No 3D LUT applied")
    private let lutDetailLabel = NSTextField(labelWithString: "Import a .cube file to add a creative look.")
    private let lutStrength = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let lutPercentLabel = NSTextField(labelWithString: "100%")
    private let removeLUTButton = NSButton(title: "Remove LUT", target: nil, action: nil)
    private var selectedLUT: ClipLUTSettings?

    var currentValues: ColorControlValues { values() }

    override func loadView() {
        view = NSView(); view.appearance = NSAppearance(named: .darkAqua); view.wantsLayer = true; view.layer?.backgroundColor = NSColor(hex: "181C22").cgColor
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), root.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)])

        let header = NSStackView(); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 10
        let title = NSTextField(labelWithString: "COLOR STUDIO"); title.font = .systemFont(ofSize: 16, weight: .bold); title.textColor = .white; header.addArrangedSubview(title)
        let live = NSTextField(labelWithString: "LIVE PREVIEW"); live.font = .systemFont(ofSize: 9, weight: .bold); live.textColor = NSColor(hex: "FFB75D"); header.addArrangedSubview(live)
        header.addArrangedSubview(NSView()); root.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        selectionLabel.font = .systemFont(ofSize: 11, weight: .medium); selectionLabel.textColor = NSColor(hex: "A7AFBC"); selectionLabel.lineBreakMode = .byTruncatingMiddle; root.addArrangedSubview(selectionLabel)
        selectionLabel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let hint = NSTextField(wrappingLabelWithString: "Drag each puck toward a color. Use Master for brightness in that tonal range, or type exact RGB/M values. Changes preview immediately; Apply writes the grade to every selected video clip."); hint.font = .systemFont(ofSize: 11); hint.textColor = NSColor(hex: "A7AFBC"); root.addArrangedSubview(hint); hint.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let document = NSStackView(); document.orientation = .vertical; document.alignment = .leading; document.spacing = 10; document.translatesAutoresizingMaskIntoConstraints = false
        addHeading("THREE-WAY COLOR WHEELS", to: document)
        let wheels = NSStackView(); wheels.orientation = .horizontal; wheels.alignment = .top; wheels.spacing = 10; wheels.distribution = .fillEqually
        wheels.addArrangedSubview(liftPanel); wheels.addArrangedSubview(midtonePanel); wheels.addArrangedSubview(gainPanel); document.addArrangedSubview(wheels); wheels.widthAnchor.constraint(equalTo: document.widthAnchor).isActive = true
        liftPanel.onChange = { [weak self] in self?.preview() }; midtonePanel.onChange = { [weak self] in self?.preview() }; gainPanel.onChange = { [weak self] in self?.preview() }

        addHeading("3D LUT (.CUBE)", to: document)
        let lutCard = NSStackView(); lutCard.orientation = .vertical; lutCard.alignment = .leading; lutCard.spacing = 8; lutCard.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 12)
        lutCard.wantsLayer = true; lutCard.layer?.backgroundColor = NSColor(hex: "242932").cgColor; lutCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor; lutCard.layer?.borderWidth = 1; lutCard.layer?.cornerRadius = 9
        let lutHeader = NSStackView(); lutHeader.orientation = .horizontal; lutHeader.alignment = .centerY; lutHeader.spacing = 8
        let importLUTButton = makeButton("Import .cube LUT…", #selector(importCubeLUT)); importLUTButton.contentTintColor = NSColor(hex: "7FA9FF")
        removeLUTButton.target = self; removeLUTButton.action = #selector(removeCubeLUT); removeLUTButton.bezelStyle = .rounded; removeLUTButton.font = .systemFont(ofSize: 11, weight: .medium)
        lutNameLabel.font = .systemFont(ofSize: 12, weight: .semibold); lutNameLabel.textColor = .white; lutNameLabel.lineBreakMode = .byTruncatingMiddle
        lutHeader.addArrangedSubview(lutNameLabel); lutHeader.addArrangedSubview(NSView()); lutHeader.addArrangedSubview(importLUTButton); lutHeader.addArrangedSubview(removeLUTButton)
        lutCard.addArrangedSubview(lutHeader); lutHeader.widthAnchor.constraint(equalTo: lutCard.widthAnchor, constant: -24).isActive = true
        lutDetailLabel.font = .systemFont(ofSize: 10); lutDetailLabel.textColor = NSColor(hex: "A7AFBC"); lutDetailLabel.lineBreakMode = .byTruncatingMiddle
        lutCard.addArrangedSubview(lutDetailLabel); lutDetailLabel.widthAnchor.constraint(equalTo: lutCard.widthAnchor, constant: -24).isActive = true
        let mixRow = NSStackView(); mixRow.orientation = .horizontal; mixRow.alignment = .centerY; mixRow.spacing = 9
        let mixTitle = NSTextField(labelWithString: "LUT MIX"); mixTitle.font = .systemFont(ofSize: 9, weight: .bold); mixTitle.textColor = NSColor(hex: "C0C6D0")
        lutStrength.target = self; lutStrength.action = #selector(lutStrengthChanged); lutStrength.isContinuous = true
        lutPercentLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); lutPercentLabel.alignment = .right; lutPercentLabel.textColor = .white
        mixRow.addArrangedSubview(mixTitle); mixRow.addArrangedSubview(lutStrength); mixRow.addArrangedSubview(lutPercentLabel)
        lutStrength.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true; lutPercentLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        lutCard.addArrangedSubview(mixRow); mixRow.widthAnchor.constraint(equalTo: lutCard.widthAnchor, constant: -24).isActive = true
        document.addArrangedSubview(lutCard); lutCard.widthAnchor.constraint(equalTo: document.widthAnchor).isActive = true
        updateLUTDisplay()

        addHeading("QUICK LOOKS", to: document)
        let looks = NSStackView(); looks.orientation = .horizontal; looks.spacing = 7
        [makeButton("Warm", #selector(warm)), makeButton("Cool", #selector(cool)), makeButton("Cinema", #selector(cinema))].forEach { looks.addArrangedSubview($0) }
        looks.addArrangedSubview(NSView()); document.addArrangedSubview(looks)

        [brightness, contrast, saturation, gamma, temperature, exposure, tint, highlights, shadows, vibrance, hue].forEach { $0.target = self; $0.action = #selector(preview); $0.isContinuous = true }
        addHeading("PRIMARY & TONE", to: document)
        let columns = NSStackView(); columns.orientation = .horizontal; columns.alignment = .top; columns.spacing = 18; columns.distribution = .fillEqually
        columns.addArrangedSubview(sliderColumn([("Exposure", exposure), ("Contrast", contrast), ("Brightness", brightness), ("Shadows", shadows), ("Highlights", highlights)]))
        columns.addArrangedSubview(sliderColumn([("Temperature", temperature), ("Tint", tint), ("Saturation", saturation), ("Vibrance", vibrance), ("Gamma curve", gamma), ("Hue", hue)]))
        document.addArrangedSubview(columns); columns.widthAnchor.constraint(equalTo: document.widthAnchor).isActive = true

        let scroll = scrolling(document); root.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let actions = NSStackView(); actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 8
        actions.addArrangedSubview(makeButton("Preview", #selector(preview)))
        let apply = makeButton("Apply Grade to Selected", #selector(apply)); apply.contentTintColor = .systemOrange; actions.addArrangedSubview(apply)
        actions.addArrangedSubview(makeButton("Reset All", #selector(reset)))
        actions.addArrangedSubview(NSView()); root.addArrangedSubview(actions); actions.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    func load(_ values: ColorControlValues, selectionName: String) {
        selectionLabel.stringValue = "Selected: \(selectionName)"
        brightness.doubleValue = values.brightness; contrast.doubleValue = values.contrast; saturation.doubleValue = values.saturation; gamma.doubleValue = values.gamma; temperature.doubleValue = values.temperature
        exposure.doubleValue = values.exposure; tint.doubleValue = values.tint; highlights.doubleValue = values.highlights; shadows.doubleValue = values.shadows; vibrance.doubleValue = values.vibrance; hue.doubleValue = values.hue
        liftPanel.load(values.lift); midtonePanel.load(values.midtones); gainPanel.load(values.gain)
        selectedLUT = values.cubeLUT; lutStrength.doubleValue = values.cubeLUT?.strength ?? 1; updateLUTDisplay()
    }

    func resetWheels() { liftPanel.load(.init()); midtonePanel.load(.init()); gainPanel.load(.init()) }
    func resetLUT() { selectedLUT = nil; lutStrength.doubleValue = 1; updateLUTDisplay() }

    private func values() -> ColorControlValues {
        var values = ColorControlValues(); values.brightness = brightness.doubleValue; values.contrast = contrast.doubleValue; values.saturation = saturation.doubleValue; values.gamma = gamma.doubleValue; values.temperature = temperature.doubleValue
        values.exposure = exposure.doubleValue; values.tint = tint.doubleValue; values.highlights = highlights.doubleValue; values.shadows = shadows.doubleValue; values.vibrance = vibrance.doubleValue; values.hue = hue.doubleValue
        values.lift = liftPanel.value; values.midtones = midtonePanel.value; values.gain = gainPanel.value
        values.cubeLUT = selectedLUT
        return values
    }

    @objc private func importCubeLUT() {
        let panel = NSOpenPanel(); panel.title = "Import 3D .cube LUT"; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let strength = selectedLUT?.strength ?? lutStrength.doubleValue
            selectedLUT = try ClipLUTSettings(embeddingFileAt: url, strength: strength)
            lutStrength.doubleValue = selectedLUT?.strength ?? 1
            updateLUTDisplay(); preview()
        } catch {
            NSSound.beep(); lutNameLabel.stringValue = "LUT could not be imported"; lutNameLabel.textColor = .systemRed
            lutDetailLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func removeCubeLUT() { resetLUT(); preview() }

    @objc private func lutStrengthChanged() {
        guard var current = selectedLUT else { return }
        current.strength = min(1, max(0, lutStrength.doubleValue)); selectedLUT = current
        updateLUTDisplay(); preview()
    }

    private func updateLUTDisplay() {
        let percent = Int(((selectedLUT?.strength ?? lutStrength.doubleValue) * 100).rounded())
        lutPercentLabel.stringValue = "\(percent)%"
        lutStrength.isEnabled = selectedLUT != nil; removeLUTButton.isEnabled = selectedLUT != nil
        guard let selectedLUT else {
            lutNameLabel.stringValue = "No 3D LUT applied"; lutNameLabel.textColor = .white
            lutDetailLabel.stringValue = "Import a .cube file to add a creative look. LUT data is embedded when you save your project."
            return
        }
        do {
            let lut = try CubeLUTCache.shared.lut(for: selectedLUT)
            let title = lut.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            lutNameLabel.stringValue = (title?.isEmpty == false ? title! : selectedLUT.fileURL.deletingPathExtension().lastPathComponent)
            lutNameLabel.textColor = .white
            let portability = selectedLUT.embeddedSource == nil ? "Linked to original file" : "Embedded in project save"
            lutDetailLabel.stringValue = "\(selectedLUT.fileURL.lastPathComponent)  •  \(lut.dimension)×\(lut.dimension)×\(lut.dimension)  •  \(portability)"
            lutDetailLabel.textColor = NSColor(hex: "A7AFBC")
        } catch {
            lutNameLabel.stringValue = selectedLUT.fileURL.lastPathComponent; lutNameLabel.textColor = .systemRed
            lutDetailLabel.stringValue = error.localizedDescription; lutDetailLabel.textColor = .systemRed
        }
    }

    @objc private func preview() { onPreview?(values()) }
    @objc private func apply() { onApply?(values()) }
    @objc private func reset() { load(ColorControlValues(), selectionName: selectionLabel.stringValue.replacingOccurrences(of: "Selected: ", with: "")); onApply?(values()) }
    @objc private func warm() { temperature.doubleValue = 7800; tint.doubleValue = 12; exposure.doubleValue = 0.08; saturation.doubleValue = 1.08; preview() }
    @objc private func cool() { temperature.doubleValue = 4600; tint.doubleValue = -8; exposure.doubleValue = -0.03; saturation.doubleValue = 0.96; preview() }
    @objc private func cinema() { contrast.doubleValue = 1.18; saturation.doubleValue = 0.88; shadows.doubleValue = 0.18; highlights.doubleValue = 0.16; vibrance.doubleValue = 0.14; preview() }

    private func sliderColumn(_ controls: [(String, NSSlider)]) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        controls.forEach {
            let controlRow = colorSliderRow($0.0, $0.1)
            stack.addArrangedSubview(controlRow)
            controlRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }
    private func colorSliderRow(_ title: String, _ slider: NSSlider) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        let label = NSTextField(labelWithString: title.uppercased()); label.font = .systemFont(ofSize: 9, weight: .bold); label.textColor = NSColor(hex: "C0C6D0")
        stack.addArrangedSubview(label); stack.addArrangedSubview(slider)
        slider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
    private func makeButton(_ title: String, _ action: Selector) -> NSButton { let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 11, weight: .medium); return button }
}

final class LegacyEffectsStudioViewController: NSViewController {
    var onPreview: ((EffectControlValues) -> Void)?
    var onApplyTransform: ((EffectControlValues) -> Void)?
    var onApplyEffects: ((EffectControlValues) -> Void)?
    var onKeyframe: ((EffectControlValues, AnimatableProperty, KeyframeInterpolation) -> Void)?
    var onRemoveKeyframe: ((EffectControlValues, AnimatableProperty) -> Void)?
    var onClearKeyframes: ((EffectControlValues, AnimatableProperty) -> Void)?
    var onReset: (() -> Void)?

    private let properties: [AnimatableProperty] = [.positionX, .positionY, .scale, .rotation, .opacity]
    private let selectionLabel = NSTextField(labelWithString: "No video clip selected")
    private let keyframeLabel = NSTextField(wrappingLabelWithString: "No keyframes on this clip yet.")
    private let positionX = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let positionY = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let scale = NSSlider(value: 1, minValue: 0.25, maxValue: 3, target: nil, action: nil)
    private let rotation = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    private let opacity = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let blur = NSSlider(value: 0, minValue: 0, maxValue: 20, target: nil, action: nil)
    private let sharpen = NSSlider(value: 0, minValue: 0, maxValue: 4, target: nil, action: nil)
    private let vignette = NSSlider(value: 0, minValue: 0, maxValue: 1.5, target: nil, action: nil)
    private let monochrome = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let sepia = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let propertyPicker = NSPopUpButton()
    private let curvePicker = NSPopUpButton()

    override func loadView() {
        view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = NSColor(hex: "1C2027").cgColor
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .width; root.spacing = 10; root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), root.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)])
        let title = NSTextField(labelWithString: "EFFECTS & KEYFRAMES"); title.font = .systemFont(ofSize: 15, weight: .bold); title.textColor = .white; root.addArrangedSubview(title)
        selectionLabel.font = .systemFont(ofSize: 11, weight: .medium); selectionLabel.textColor = .secondaryLabelColor; selectionLabel.lineBreakMode = .byTruncatingMiddle; root.addArrangedSubview(selectionLabel)

        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 9; stack.translatesAutoresizingMaskIntoConstraints = false
        addHeading("TRANSFORM", to: stack)
        [positionX, positionY, scale, rotation, opacity, blur, sharpen, vignette, monochrome, sepia].forEach { $0.target = self; $0.action = #selector(preview) }
        stack.addArrangedSubview(row("Position X", positionX)); stack.addArrangedSubview(row("Position Y", positionY)); stack.addArrangedSubview(row("Scale", scale)); stack.addArrangedSubview(row("Rotation", rotation)); stack.addArrangedSubview(row("Opacity", opacity))
        let transform = makeButton("Apply transform to selected", #selector(applyTransform)); transform.contentTintColor = .systemBlue; stack.addArrangedSubview(transform)
        addHeading("KEYFRAMES", to: stack)
        properties.forEach { propertyPicker.addItem(withTitle: $0.title) }; stack.addArrangedSubview(propertyPicker)
        [KeyframeInterpolation.easeInOut, .linear, .hold].forEach { curvePicker.addItem(withTitle: $0 == .easeInOut ? "Smooth curve" : $0.rawValue.capitalized) }; stack.addArrangedSubview(curvePicker)
        let add = makeButton("♦ Add / update at playhead", #selector(addKeyframe)); add.contentTintColor = .systemOrange; stack.addArrangedSubview(add)
        let keyActions = NSStackView(); keyActions.orientation = .horizontal; keyActions.spacing = 6; keyActions.addArrangedSubview(makeButton("Remove here", #selector(removeKeyframe))); keyActions.addArrangedSubview(makeButton("Clear property", #selector(clearKeyframes))); stack.addArrangedSubview(keyActions)
        keyframeLabel.font = .systemFont(ofSize: 10); keyframeLabel.textColor = .secondaryLabelColor; stack.addArrangedSubview(keyframeLabel)
        addHeading("LOOKS & EFFECTS", to: stack)
        stack.addArrangedSubview(row("Blur", blur)); stack.addArrangedSubview(row("Sharpen", sharpen)); stack.addArrangedSubview(row("Vignette", vignette)); stack.addArrangedSubview(row("Monochrome mix", monochrome)); stack.addArrangedSubview(row("Sepia mix", sepia))
        let apply = makeButton("Apply effects to selected", #selector(applyEffects)); apply.contentTintColor = .systemPurple; stack.addArrangedSubview(apply)
        let looks = NSStackView(); looks.orientation = .horizontal; looks.spacing = 6; looks.addArrangedSubview(makeButton("B&W", #selector(blackAndWhite))); looks.addArrangedSubview(makeButton("Soft glow", #selector(softGlow))); looks.addArrangedSubview(makeButton("Vintage", #selector(vintage))); stack.addArrangedSubview(looks)
        let scroll = scrolling(stack); root.addArrangedSubview(scroll)
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 8; actions.addArrangedSubview(makeButton("Preview", #selector(preview))); actions.addArrangedSubview(makeButton("Reset selected", #selector(reset))); root.addArrangedSubview(actions)
    }
    func load(_ values: EffectControlValues, selectionName: String, property: AnimatableProperty, interpolation: KeyframeInterpolation, keyframeText: String) {
        selectionLabel.stringValue = "Selected: \(selectionName)"; keyframeLabel.stringValue = keyframeText
        positionX.doubleValue = values.transform.positionX; positionY.doubleValue = values.transform.positionY; scale.doubleValue = values.transform.scale; rotation.doubleValue = values.transform.rotation; opacity.doubleValue = values.transform.opacity
        blur.doubleValue = values.effects.blurRadius; sharpen.doubleValue = values.effects.sharpenAmount; vignette.doubleValue = values.effects.vignetteIntensity; monochrome.doubleValue = values.effects.monochromeAmount; sepia.doubleValue = values.effects.sepiaAmount
        propertyPicker.selectItem(at: properties.firstIndex(of: property) ?? 0)
        curvePicker.selectItem(at: [KeyframeInterpolation.easeInOut, .linear, .hold].firstIndex(of: interpolation) ?? 0)
    }
    private func values() -> EffectControlValues {
        var values = EffectControlValues(); values.transform.positionX = positionX.doubleValue; values.transform.positionY = positionY.doubleValue; values.transform.scale = scale.doubleValue; values.transform.rotation = rotation.doubleValue; values.transform.opacity = opacity.doubleValue
        values.effects.blurRadius = blur.doubleValue; values.effects.sharpenAmount = sharpen.doubleValue; values.effects.vignetteIntensity = vignette.doubleValue; values.effects.monochromeAmount = monochrome.doubleValue; values.effects.sepiaAmount = sepia.doubleValue
        return values
    }
    private var selectedProperty: AnimatableProperty { properties[properties.indices.contains(propertyPicker.indexOfSelectedItem) ? propertyPicker.indexOfSelectedItem : 0] }
    private var selectedCurve: KeyframeInterpolation { let choices: [KeyframeInterpolation] = [.easeInOut, .linear, .hold]; return choices[choices.indices.contains(curvePicker.indexOfSelectedItem) ? curvePicker.indexOfSelectedItem : 0] }
    @objc private func preview() { onPreview?(values()) }
    @objc private func applyTransform() { onApplyTransform?(values()) }
    @objc private func applyEffects() { onApplyEffects?(values()) }
    @objc private func addKeyframe() { onKeyframe?(values(), selectedProperty, selectedCurve); keyframeLabel.stringValue = "Keyframe updated at the timeline playhead." }
    @objc private func removeKeyframe() { onRemoveKeyframe?(values(), selectedProperty); keyframeLabel.stringValue = "Removed keyframe at the timeline playhead." }
    @objc private func clearKeyframes() { onClearKeyframes?(values(), selectedProperty); keyframeLabel.stringValue = "Cleared \(selectedProperty.title) keyframes." }
    @objc private func reset() { let fresh = EffectControlValues(); load(fresh, selectionName: selectionLabel.stringValue.replacingOccurrences(of: "Selected: ", with: ""), property: selectedProperty, interpolation: selectedCurve, keyframeText: "Effects and transform keyframes reset."); onReset?() }
    @objc private func blackAndWhite() { monochrome.doubleValue = 1; preview() }
    @objc private func softGlow() { blur.doubleValue = 0.8; vignette.doubleValue = 0.25; preview() }
    @objc private func vintage() { sepia.doubleValue = 0.55; vignette.doubleValue = 0.48; preview() }
    private func makeButton(_ title: String, _ action: Selector) -> NSButton { let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 11, weight: .medium); return button }
}

private func scrolling(_ document: NSView) -> NSScrollView {
    let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = document
    NSLayoutConstraint.activate([
        document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        document.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
    ])
    return scroll
}
private func addHeading(_ text: String, to stack: NSStackView) {
    let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 10, weight: .bold); label.textColor = NSColor(hex: "7FA9FF"); stack.addArrangedSubview(label)
}
private func row(_ title: String, _ slider: NSSlider) -> NSStackView {
    let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 3
    let label = NSTextField(labelWithString: title.uppercased()); label.font = .systemFont(ofSize: 9, weight: .bold); label.textColor = .secondaryLabelColor
    stack.addArrangedSubview(label); stack.addArrangedSubview(slider); return stack
}

final class MediaRowButton: NSButton, NSDraggingSource {
    private let index: Int; private weak var controller: EditorController?
    init(asset: MediaAsset, index: Int, controller: EditorController) { self.index = index; self.controller = controller; super.init(frame: .zero); title = "\(asset.kind == .audio ? "♫" : "▶")  \(asset.name)"; toolTip = "Click to preview. Drag to a timeline track."; target = self; action = #selector(choose); bezelStyle = .texturedRounded; alignment = .left; font = .systemFont(ofSize: 11); heightAnchor.constraint(equalToConstant: 34).isActive = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func choose() { controller?.selectAsset(at: index) }
    override func mouseDragged(with event: NSEvent) { let item = NSPasteboardItem(); item.setString(String(index), forType: .netVistaAsset); let drag = NSDraggingItem(pasteboardWriter: item); drag.setDraggingFrame(bounds, contents: snapshot()); beginDraggingSession(with: [drag], event: event, source: self) }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    private func snapshot() -> NSImage { let image = NSImage(size: bounds.size); image.lockFocus(); draw(bounds); image.unlockFocus(); return image }
}


enum ExportService {
    static func export(_ clips: [TimelineClip], to output: URL) -> String {
        let videoClips = clips.filter { $0.kind == .video }.sorted { $0.track == $1.track ? $0.timelineStart < $1.timelineStart : $0.track < $1.track }
        let audioClips = clips.filter { $0.kind == .audio }.sorted { $0.timelineStart < $1.timelineStart }
        let ordered = videoClips + audioClips
        var arguments = ["ffmpeg", "-y"]; var filters: [String] = []
        let totalDuration = ordered.map { $0.timelineStart + ($0.outPoint > $0.inPoint ? $0.outPoint - $0.inPoint : 6) }.max() ?? 6
        for (i, clip) in ordered.enumerated() {
            arguments += ["-ss", String(clip.inPoint), "-i", clip.url.path]
            let duration = clip.outPoint > clip.inPoint ? "=duration=\(clip.outPoint - clip.inPoint)" : ""
            if clip.kind == .video {
                let exposureAdjustedBrightness = clip.brightness + clip.colorExtras.exposure * 0.12
                var chain = "trim\(duration),setpts=PTS-STARTPTS+\(clip.timelineStart)/TB,scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,eq=brightness=\(exposureAdjustedBrightness):contrast=\(clip.contrast):saturation=\(clip.saturation):gamma=\(clip.gamma),colortemperature=temperature=\(clip.temperature)"
                if abs(clip.colorExtras.hue) > 0.001 { chain += ",hue=h=\(clip.colorExtras.hue)" }
                if abs(clip.colorExtras.vibrance) > 0.001 { chain += ",vibrance=intensity=\(clip.colorExtras.vibrance)" }
                if clip.effects.monochromeAmount > 0.001 { chain += ",hue=s=\(max(0, 1 - clip.effects.monochromeAmount))" }
                if clip.effects.sepiaAmount > 0.001 {
                    let amount = min(1, max(0, clip.effects.sepiaAmount))
                    chain += ",colorchannelmixer=rr=\(1 - 0.607 * amount):rg=\(0.769 * amount):rb=\(0.189 * amount):gr=\(0.349 * amount):gg=\(1 - 0.314 * amount):gb=\(0.168 * amount):br=\(0.272 * amount):bg=\(0.534 * amount):bb=\(1 - 0.869 * amount)"
                }
                if clip.effects.blurRadius > 0.001 { chain += ",gblur=sigma=\(clip.effects.blurRadius)" }
                if clip.effects.sharpenAmount > 0.001 { chain += ",unsharp=5:5:\(min(4, clip.effects.sharpenAmount))" }
                if clip.effects.vignetteIntensity > 0.001 { chain += ",vignette=angle=\(max(0.25, 1.5 - clip.effects.vignetteIntensity))" }
                let scale = min(3, max(0.25, clip.transform.scale))
                if abs(scale - 1) > 0.001 { chain += ",scale=trunc(iw*\(scale)/2)*2:trunc(ih*\(scale)/2)*2" }
                if abs(clip.transform.rotation) > 0.001 { chain += ",rotate=\(clip.transform.rotation)*PI/180:ow=rotw(iw):oh=roth(ih):c=black" }
                if clip.transform.opacity < 0.999 { chain += ",format=rgba,colorchannelmixer=aa=\(max(0, clip.transform.opacity))" }
                filters.append("[\(i):v]\(chain)[v\(i)]")
            } else {
                filters.append("[\(i):a]atrim\(duration),asetpts=PTS-STARTPTS+\(clip.timelineStart)/TB,volume=\(clip.volume)[a\(i)]")
            }
        }
        filters.append("color=c=black:s=1280x720:d=\(totalDuration)[base]")
        var canvas = "[base]"
        for i in videoClips.indices {
            let clip = videoClips[i]
            let next = i == videoClips.count - 1 ? "[v]" : "[layer\(i)]"
            let x = "(W-w)/2+\(clip.transform.positionX * 640)"
            let y = "(H-h)/2+\(clip.transform.positionY * 360)"
            filters.append("\(canvas)[v\(i)]overlay=x='\(x)':y='\(y)':eof_action=pass\(next)")
            canvas = next
        }
        if videoClips.isEmpty { filters.append("[base]null[v]") }
        filters.append("anullsrc=r=48000:cl=stereo:d=\(totalDuration)[silence]")
        let audioInputs = "[silence]" + audioClips.indices.map { "[a\(videoClips.count + $0)]" }.joined()
        filters.append("\(audioInputs)amix=inputs=\(audioClips.count + 1):duration=longest[a]")
        arguments += ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-c:a", "aac", "-movflags", "+faststart", output.path]
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = arguments
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 ? "Export complete: \(output.lastPathComponent)" : "Export failed. Check FFmpeg and ensure clips include audio." } catch { return "Export failed. Install FFmpeg with: brew install ffmpeg" }
    }
}

extension NSColor { convenience init(hex: String) { let value = Int(hex, radix: 16) ?? 0; self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1) } }

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var editor: EditorController?
    private var pendingOpenURLs: [URL] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "NetVistaStudio", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "NetVista Studio"; window.minSize = NSSize(width: 1000, height: 650)
        let controller = EditorController(); editor = controller; window.contentViewController = controller
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if !pendingOpenURLs.isEmpty { route(pendingOpenURLs, to: controller); pendingOpenURLs.removeAll() }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let editor { route(urls, to: editor) }
        else { pendingOpenURLs.append(contentsOf: urls) }
    }
    private func route(_ urls: [URL], to editor: EditorController) {
        for url in urls {
            switch url.pathExtension.lowercased() {
            case "netvistastudio", "swiftediter":
                editor.openProject(at: url)
            case "netvistascene", "swiftscene":
                editor.openScene(at: url)
            default:
                editor.addMedia([url], addToTimeline: true)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !NETVISTA_STUDIO_TESTING
@main
private enum NetVistaStudioApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
