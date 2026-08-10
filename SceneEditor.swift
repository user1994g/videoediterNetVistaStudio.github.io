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

    public init(enabled: Bool = false, color: SceneRGBA = SceneRGBA(red: 0.05, green: 0.95, blue: 0.10), threshold: Double = 0.25, softness: Double = 0.12) {
        self.enabled = enabled
        self.color = color
        self.threshold = threshold
        self.softness = softness
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
        chromaKey: SceneChromaKey = .init()
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
    }
}

public struct NetVistaSceneDocument: Codable, Equatable {
    public var formatVersion: Int = 1
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
    public var objects: [SceneObjectRecord] = []

    public init() {}
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
    private let ambientSlider = NSSlider(value: 420, minValue: 0, maxValue: 2_000, target: nil, action: nil)
    private let keySlider = NSSlider(value: 1_200, minValue: 0, maxValue: 4_000, target: nil, action: nil)
    private let exposureSlider = NSSlider(value: 0, minValue: -4, maxValue: 4, target: nil, action: nil)
    private var transformFields: [TransformField: NSTextField] = [:]
    private var selectedObjectID: UUID?
    private var objectNodes: [UUID: SCNNode] = [:]
    private var players: [UUID: AVQueuePlayer] = [:]
    private var playerLoopers: [UUID: AVPlayerLooper] = [:]
    private var scene: SCNScene = SCNScene()
    private var cameraNode = SCNNode()
    private var ambientNode = SCNNode()
    private var keyLightNode = SCNNode()
    private var isRendering = false

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
        players.values.forEach { $0.pause() }
    }

    // MARK: Public document and render API

    public func replaceDocument(_ newDocument: NetVistaSceneDocument, sourceURL: URL? = nil) {
        if !isViewLoaded { _ = view }
        document = newDocument
        documentURL = sourceURL
        selectedObjectID = document.objects.first?.id
        rebuildRuntimeScene()
        refreshControlsFromDocument()
    }

    /// Captures camera movement and inspector edits before the parent project
    /// is saved, even when the user has not rendered the scene again yet.
    public func snapshotDocument() -> NetVistaSceneDocument {
        if !isViewLoaded { _ = view }
        syncDocumentFromScene()
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
        let loaded = try JSONDecoder().decode(NetVistaSceneDocument.self, from: Data(contentsOf: url))
        guard loaded.formatVersion == 1 else {
            throw SceneEditorError.unsupportedDocumentVersion(loaded.formatVersion)
        }
        document = loaded
        documentURL = url
        selectedObjectID = nil
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
        documentView.addArrangedSubview(labeledRow("Threshold", chromaThreshold))
        documentView.addArrangedSubview(labeledRow("Softness", chromaSoftness))

        documentView.addArrangedSubview(separator(horizontal: true))
        documentView.addArrangedSubview(sectionLabel("SCENE & LIGHTING"))
        configureSlider(ambientSlider, action: #selector(applyEnvironment(_:)))
        configureSlider(keySlider, action: #selector(applyEnvironment(_:)))
        configureSlider(exposureSlider, action: #selector(applyEnvironment(_:)))
        documentView.addArrangedSubview(labeledRow("Ambient", ambientSlider))
        documentView.addArrangedSubview(labeledRow("Key light", keySlider))
        documentView.addArrangedSubview(labeledRow("Exposure", exposureSlider))

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

    // MARK: Scene construction

    @objc private func createNewScene(_ sender: Any?) {
        document = NetVistaSceneDocument()
        document.objects = [
            SceneObjectRecord(name: "Hero Cube", kind: .cube, position: SceneVector3(x: 0, y: 0.5, z: 0))
        ]
        documentURL = nil
        selectedObjectID = document.objects.first?.id
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
        scene.background.contents = document.backgroundColor.color

        let floor = SCNFloor()
        floor.reflectivity = 0.18
        floor.reflectionFalloffEnd = 12
        floor.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.12, alpha: 1)
        floor.firstMaterial?.roughness.contents = 0.7
        let floorNode = SCNNode(geometry: floor)
        floorNode.name = "__floor"
        scene.rootNode.addChildNode(floorNode)

        let grid = GridGeometry.makeNode()
        scene.rootNode.addChildNode(grid)

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
        return node
    }

    private func applyChroma(_ chroma: SceneChromaKey, to material: SCNMaterial) {
        material.blendMode = chroma.enabled ? .alpha : .replace
        material.transparencyMode = .dualLayer
        material.shaderModifiers = [.surface: ChromaShader.source]
        material.setValue(chroma.enabled ? 1.0 : 0.0, forKey: "chromaEnabled")
        material.setValue(chroma.threshold, forKey: "chromaThreshold")
        material.setValue(chroma.softness, forKey: "chromaSoftness")
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
        for index in document.objects.indices {
            guard let node = objectNodes[document.objects[index].id] else { continue }
            document.objects[index].position = SceneVector3(node.position)
            document.objects[index].rotation = SceneVector3(
                x: Double(node.eulerAngles.x) * 180 / .pi,
                y: Double(node.eulerAngles.y) * 180 / .pi,
                z: Double(node.eulerAngles.z) * 180 / .pi
            )
            document.objects[index].scale = SceneVector3(node.scale)
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
        document.objects[index] = record

        node.position = record.position.scn
        node.eulerAngles = SCNVector3(record.rotation.x * .pi / 180, record.rotation.y * .pi / 180, record.rotation.z * .pi / 180)
        node.scale = record.scale.scn
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
        document.ambientLightIntensity = ambientSlider.doubleValue
        document.keyLightIntensity = keySlider.doubleValue
        document.exposure = exposureSlider.doubleValue
        ambientNode.light?.intensity = document.ambientLightIntensity
        keyLightNode.light?.intensity = document.keyLightIntensity
        cameraNode.camera?.exposureOffset = document.exposure
    }

    private func refreshObjectInspector() {
        guard let id = selectedObjectID, let record = document.objects.first(where: { $0.id == id }) else {
            nameField.stringValue = ""
            setInspectorEnabled(false)
            return
        }
        setInspectorEnabled(true)
        nameField.stringValue = record.name
        setVector(record.position, keys: [.positionX, .positionY, .positionZ])
        setVector(record.rotation, keys: [.rotationX, .rotationY, .rotationZ])
        setVector(record.scale, keys: [.scaleX, .scaleY, .scaleZ])
        colorWell.color = record.color.color
        chromaEnabled.state = record.chromaKey.enabled ? .on : .off
        chromaColorWell.color = record.chromaKey.color.color
        chromaThreshold.doubleValue = record.chromaKey.threshold
        chromaSoftness.doubleValue = record.chromaKey.softness
        let isMedia = record.kind == .mediaPlane
        chromaEnabled.isEnabled = isMedia
        chromaColorWell.isEnabled = isMedia
        chromaThreshold.isEnabled = isMedia
        chromaSoftness.isEnabled = isMedia
    }

    private func refreshControlsFromDocument() {
        durationField.doubleValue = document.duration
        if document.canvasWidth >= 3_840 { resolutionPopup.selectItem(at: 2) }
        else if document.canvasWidth >= 1_920 { resolutionPopup.selectItem(at: 1) }
        else { resolutionPopup.selectItem(at: 0) }
        ambientSlider.doubleValue = document.ambientLightIntensity
        keySlider.doubleValue = document.keyLightIntensity
        exposureSlider.doubleValue = document.exposure
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
    float3 chromaColor;
    #pragma body
    float keyDistance = distance(_surface.diffuse.rgb, chromaColor);
    float keyedAlpha = smoothstep(chromaThreshold, chromaThreshold + chromaSoftness, keyDistance);
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
            .assetDirectoryURLs: [url.deletingLastPathComponent()]
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
        guard let writer = try? AVAssetWriter(outputURL: stagingURL, fileType: .mov) else {
            throw SceneEditorError.cannotCreateWriter
        }
        let width = max(320, document.canvasWidth)
        let height = max(180, document.canvasHeight)
        let fps = min(60, max(1, document.framesPerSecond))
        let settings: [String: Any] = [
            // ProRes has a dependable system encoder and produces a robust
            // intermediate clip for the main timeline. The final Delivery
            // page can then create a compact H.264 or HEVC MP4.
            AVVideoCodecKey: AVVideoCodecType.proRes422,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw SceneEditorError.cannotCreateWriter }
        writer.add(input)
        guard writer.startWriting() else {
            throw SceneEditorError.cannotStartWriter(writer.error.map { String(describing: $0) } ?? "Unknown error")
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
                runtime.updateMediaFrames(at: seconds)
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
    private var media: [(generator: AVAssetImageGenerator, material: SCNMaterial, duration: Double, chroma: SceneChromaKey)] = []

    init(document: NetVistaSceneDocument) {
        scene.background.contents = document.backgroundColor.color
        let floor = SCNFloor()
        floor.reflectivity = 0.18
        floor.reflectionFalloffEnd = 12
        floor.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.12, alpha: 1)
        floor.firstMaterial?.roughness.contents = 0.7
        scene.rootNode.addChildNode(SCNNode(geometry: floor))

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
                material.setValue(NSValue(scnVector3: SCNVector3(record.chromaKey.color.red, record.chromaKey.color.green, record.chromaKey.color.blue)), forKey: "chromaColor")
                media.append((generator, material, duration, record.chromaKey))
            }
            scene.rootNode.addChildNode(node)
        }
    }

    func updateMediaFrames(at seconds: Double) {
        for item in media {
            let local = seconds.truncatingRemainder(dividingBy: item.duration)
            if let cgImage = try? item.generator.copyCGImage(at: CMTime(seconds: local, preferredTimescale: 600), actualTime: nil) {
                item.material.diffuse.contents = cgImage
            }
        }
    }
}
