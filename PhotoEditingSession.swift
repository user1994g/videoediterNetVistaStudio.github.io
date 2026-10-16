import Foundation
import CoreImage
import CoreGraphics

/// Native editing commands shared by AppKit/UIKit. Published state contains value
/// snapshots and immutable CIImages, never the mutable PhotoLayer passed to an edit.
/// Call on one owner queue (normally the UI thread); render a captured `state` off it.
final class PhotoEditingSession {
    private(set) var state: PhotoDocumentSnapshot
    private(set) var revision: UInt64 = 0
    private(set) var lastAction = "New document"
    private var undoHistory: [(PhotoDocumentSnapshot, String)] = []
    private var redoHistory: [(PhotoDocumentSnapshot, String)] = []
    private var transaction: (PhotoDocumentSnapshot, String)?
    let maximumHistorySteps: Int
    let historyByteBudget: Double
    static let maximumProjectBytes = 512 * 1024 * 1024

    var layers: [PhotoLayerSnapshot] { state.layers }
    var selectedLayerID: UUID? { state.selectedLayerID }
    var selectedLayer: PhotoLayerSnapshot? { layers.first { $0.id == selectedLayerID } }
    var documentSize: CGSize { state.documentSize }
    var documentName: String { state.documentName }
    var dpi: Double { state.dpi }
    var projectURL: URL? { state.projectURL }
    var canUndo: Bool { !undoHistory.isEmpty || transaction.map { !Self.equal($0.0, state) } == true }
    var canRedo: Bool { transaction == nil && !redoHistory.isEmpty }
    var undoCount: Int { undoHistory.count }
    var redoCount: Int { redoHistory.count }
    var isEditing: Bool { transaction != nil }

    init(size: CGSize = CGSize(width: 1920, height: 1080), name: String = "Untitled photo",
         background: CIColor? = .white, dpi: Double = 72,
         maximumHistorySteps: Int = 80, historyByteBudget: Double = 256_000_000) throws {
        self.maximumHistorySteps = max(1, min(200, maximumHistorySteps))
        self.historyByteBudget = max(1, historyByteBudget.isFinite ? historyByteBudget : 256_000_000)
        state = Self.blank(size: size, name: name, background: background, dpi: dpi)
        try Self.validate(state)
    }

    /// Detached immutable capture for rendering/saving on a worker queue. No UI
    /// controller, history, or mutable layer objects cross the queue boundary.
    init(snapshot: PhotoDocumentSnapshot, maximumHistorySteps: Int = 80, historyByteBudget: Double = 256_000_000) throws {
        self.maximumHistorySteps = max(1, min(200, maximumHistorySteps))
        self.historyByteBudget = max(1, historyByteBudget.isFinite ? historyByteBudget : 256_000_000)
        try Self.validate(snapshot); state = snapshot
    }

    func select(_ id: UUID?) {
        finishTransaction()
        let valid = id.flatMap { candidate in layers.contains { $0.id == candidate } ? candidate : nil }
        guard valid != selectedLayerID else { return }
        state = copyState(selected: valid); revision &+= 1
    }

    func newDocument(size: CGSize, name: String = "Untitled photo", background: CIColor? = .white, dpi: Double = 72) throws {
        finishTransaction()
        try publish(Self.blank(size: size, name: name, background: background, dpi: dpi), label: "New document")
    }

    /// A drag or stroke can update its preview repeatedly, but creates one Undo step.
    func beginTransaction(_ label: String) throws {
        guard transaction == nil else { throw PhotoBrushError.invalid("Finish the current photo edit first.") }
        transaction = (state, label)
    }
    func finishTransaction() {
        guard let before = transaction else { return }
        transaction = nil
        guard !Self.equal(before.0, state) else { return }
        undoHistory.append(before); redoHistory.removeAll(); lastAction = before.1; trimHistory()
    }
    func cancelTransaction() {
        guard let before = transaction else { return }
        transaction = nil; state = before.0; revision &+= 1
    }
    @discardableResult func undo() -> Bool {
        finishTransaction()
        guard let previous = undoHistory.popLast() else { return false }
        redoHistory.append((state, previous.1)); state = previous.0; lastAction = "Undo · " + previous.1; revision &+= 1
        return true
    }
    @discardableResult func redo() -> Bool {
        guard transaction == nil, let next = redoHistory.popLast() else { return false }
        undoHistory.append((state, next.1)); state = next.0; lastAction = "Redo · " + next.1; revision &+= 1; trimHistory()
        return true
    }

    func render(maxSide: CGFloat? = nil, opaqueBackground: Bool = false, bypassAdjustments: Bool = false) -> CIImage? {
        PhotoRenderEngine.composite(layers, documentSize: documentSize, maxSide: maxSide,
                                    bypassAdjustments: bypassAdjustments, opaqueBackground: opaqueBackground)
    }

    /// Copy-on-edit prevents a failed command, a retained closure argument, or an
    /// old UI binding from corrupting history/current state. IDs, not indices, bind edits.
    func mutateLayer(_ id: UUID, label: String = "Layer properties", _ edit: (PhotoLayer) throws -> Void) throws {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { throw PhotoBrushError.invalid("This layer is no longer in the document.") }
        guard isEditable(id) else { throw PhotoBrushError.invalid("Unlock the layer and its folder before editing.") }
        let layer = Self.mutable(layers[index])
        try edit(layer)
        // Folder membership is structural, so use moveToGroup rather than bypassing
        // the ordering/inheritance rules from a generic properties control.
        guard layer.extras.groupID == layers[index].extras.groupID,
              layer.extras.isGroup == layers[index].extras.isGroup else {
            throw PhotoBrushError.invalid("Use the layer folder command to change grouping.")
        }
        var candidate = layers; candidate[index] = Self.snapshot(layer)
        try publish(copyState(layers: candidate), label: label)
    }

    func isEditable(_ id: UUID) -> Bool {
        guard let layer = layers.first(where: { $0.id == id }), !layer.isLocked else { return false }
        return layer.extras.groupID.flatMap { parent in layers.first { $0.id == parent }?.isLocked } != true
    }

    /// Translate source layers in document pixels. Folders render their children
    /// directly, so moving a folder changes its unlocked raster children instead
    /// of storing an unused transform on the folder itself. Repeated calls inside
    /// a transaction produce one reversible drag; failed moves publish nothing.
    func translate(_ id: UUID, by delta: CGPoint) throws {
        guard delta.x.isFinite, delta.y.isFinite else { throw PhotoBrushError.invalid("Use a finite distance to move a layer.") }
        guard let layer = layers.first(where: { $0.id == id }), isEditable(id) else {
            throw PhotoBrushError.invalid("Select an unlocked image layer or folder to move.")
        }
        guard !layer.extras.isAdjustment else { throw PhotoBrushError.invalid("Adjustment layers affect the canvas and cannot be moved.") }
        let targets = layer.extras.isGroup
            ? layers.filter { $0.extras.groupID == id && !$0.extras.isAdjustment && !$0.isLocked }
            : [layer]
        guard !targets.isEmpty else { throw PhotoBrushError.invalid("This folder has no unlocked image layers to move.") }
        guard delta != .zero else { return }
        let identifiers = Set(targets.map(\.id))
        var candidate = layers
        for index in candidate.indices where identifiers.contains(candidate[index].id) {
            let moved = Self.mutable(candidate[index])
            moved.position.x += delta.x; moved.position.y += delta.y
            candidate[index] = Self.snapshot(moved)
        }
        try publish(copyState(layers: candidate), label: layer.extras.isGroup ? "Move folder" : "Move layer")
    }

    @discardableResult func addRaster(_ image: CIImage, name: String = "Image", sourceURL: URL? = nil, fit: Bool = true) throws -> UUID {
        guard Self.validImage(image) else { throw PhotoBrushError.invalid("Choose an image up to 16,000 pixels per side and 64 megapixels.") }
        let layer = PhotoLayer(name: name, sourceURL: sourceURL, sourceImage: PhotoRenderEngine.normalized(image), thumbnail: nil)
        if fit { layer.scale = min(1, min(documentSize.width / image.extent.width, documentSize.height / image.extent.height)) }
        try insert(layer, label: "Import image"); return layer.id
    }
    @discardableResult func addBlankLayer(name: String = "Paint layer") throws -> UUID {
        try addRaster(CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: documentSize)), name: name, fit: false)
    }
    @discardableResult func addAdjustmentLayer(name: String = "Adjustment") throws -> UUID {
        let layer = PhotoLayer(name: name, sourceURL: nil, sourceImage: CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: documentSize)), thumbnail: nil)
        layer.extras.isAdjustment = true; try insert(layer, label: "Add adjustment layer"); return layer.id
    }

    /// Publish a text raster and its editable metadata together. A text resize
    /// retains its old mask relative to the text's top-left corner; newly added
    /// pixels are revealed, and the mask is never left at an invalid old size.
    @discardableResult func setTextRaster(image: CIImage, existingID: UUID?, text: String, fontName: String,
        fontSize: Double, color: [Double], position: CGPoint?, context: CIContext) throws -> UUID {
        guard Self.validImage(image), !text.isEmpty, text.count <= 10_000,
              !fontName.isEmpty, fontName.utf8.count <= 4096, fontSize.isFinite, (1...2000).contains(fontSize),
              color.count == 4, color.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw PhotoBrushError.invalid("Use valid text pixels, a font size from 1 to 2,000, and a valid text colour.")
        }
        let pixels = PhotoRenderEngine.normalized(image)
        let layer: PhotoLayer
        let existingIndex: Int?
        if let existingID {
            guard let index = layers.firstIndex(where: { $0.id == existingID }), isEditable(existingID),
                  layers[index].extras.text != nil, !layers[index].extras.isGroup, !layers[index].extras.isAdjustment else {
                throw PhotoBrushError.invalid("Select an unlocked text layer to edit.")
            }
            existingIndex = index; layer = Self.mutable(layers[index])
            if pixels.extent.size != layer.sourceImage.extent.size,
               let oldMask = layer.maskPreview ?? layer.extras.maskPNG.flatMap({ CIImage(data: $0) }) {
                let alignedMask = PhotoRenderEngine.normalized(oldMask).transformed(by:
                    CGAffineTransform(translationX: 0, y: pixels.extent.height - layer.sourceImage.extent.height))
                let resizedMask = alignedMask.composited(over: CIImage(color: .white).cropped(to: pixels.extent)).cropped(to: pixels.extent)
                layer.extras.maskPNG = try PhotoPixels.png(resizedMask, context: context); layer.maskPreview = nil
            }
        } else {
            existingIndex = nil
            layer = PhotoLayer(name: String(text.prefix(40)), sourceURL: nil, sourceImage: pixels, thumbnail: nil)
        }
        layer.sourceImage = pixels; layer.thumbnail = nil
        layer.extras.text = text; layer.extras.fontName = fontName; layer.extras.fontSize = fontSize; layer.extras.textColor = color
        if let position { layer.position = position }
        if let existingIndex {
            var candidate = layers; candidate[existingIndex] = Self.snapshot(layer)
            // Validate the complete candidate before closing another edit or
            // changing Undo, so malformed updates are wholly atomic.
            let document = copyState(layers: candidate); try Self.validate(document)
            finishTransaction(); try publish(document, label: "Edit text")
        } else { try insert(layer, label: "Add text layer") }
        return layer.id
    }

    func rename(_ id: UUID, to name: String) throws { try mutateLayer(id, label: "Rename layer") { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) } }
    func setOpacity(_ id: UUID, to opacity: Double) throws { try mutateLayer(id, label: "Layer opacity") { $0.opacity = opacity } }
    func setBlendMode(_ id: UUID, to mode: PhotoBlendMode) throws { try mutateLayer(id, label: "Layer blend mode") { $0.blendMode = mode } }
    func setVisibility(_ id: UUID, to visible: Bool) throws { try metadata(id, label: "Layer visibility") { $0.isVisible = visible } }
    func setLocked(_ id: UUID, to locked: Bool) throws { try metadata(id, label: "Layer lock") { $0.isLocked = locked } }
    func replacePixels(_ id: UUID, image: CIImage, label: String = "Paint") throws {
        guard Self.validImage(image) else { throw PhotoBrushError.invalid("Invalid layer image.") }
        try mutateLayer(id, label: label) { $0.sourceImage = PhotoRenderEngine.normalized(image); $0.thumbnail = nil }
    }
    func setMask(_ id: UUID, image: CIImage?, context: CIContext) throws {
        guard let layer = layers.first(where: { $0.id == id }), !layer.extras.isGroup else { throw PhotoBrushError.invalid("Select an image or adjustment layer for a mask.") }
        let pixels: Data?
        if let image {
            guard Self.validImage(image), image.extent.size == layer.sourceImage.extent.size else { throw PhotoBrushError.invalid("The mask must match the layer dimensions.") }
            pixels = try PhotoPixels.png(PhotoRenderEngine.normalized(image), context: context)
        } else { pixels = nil }
        try mutateLayer(id, label: "Layer mask") { $0.extras.maskPNG = pixels; $0.maskPreview = nil }
    }
    func addMask(_ id: UUID, reveal: Bool = true, context: CIContext) throws {
        guard let layer = layers.first(where: { $0.id == id }) else { throw PhotoBrushError.invalid("Select a layer first.") }
        try setMask(id, image: CIImage(color: reveal ? .white : .black).cropped(to: layer.sourceImage.extent), context: context)
    }
    func removeMask(_ id: UUID) throws {
        try mutateLayer(id, label: "Remove layer mask") { $0.extras.maskPNG = nil; $0.maskPreview = nil }
    }
    func maskSelection(_ id: UUID, mask: CIImage, reveal: Bool, context: CIContext) throws {
        guard let layer = layers.first(where: { $0.id == id }), !layer.extras.isGroup, isEditable(id),
              Self.validImage(mask), mask.extent.size == documentSize else { throw PhotoBrushError.invalid("Select pixels and an unlocked image or adjustment layer first.") }
        let mapping = layer.extras.isAdjustment ? CGAffineTransform.identity : PhotoRenderEngine.layerTransform(size: layer.sourceImage.extent.size,
            position: layer.position, scale: layer.scale, rotation: layer.rotation, skew: layer.extras.skew, document: documentSize)
        // Layer masks follow post-flip coordinates, unlike original image pixels.
        var selected = mask.transformed(by: mapping.inverted()).composited(over: CIImage(color: .black).cropped(to: layer.sourceImage.extent)).cropped(to: layer.sourceImage.extent)
        if !reveal { selected = selected.applyingFilter("CIColorInvert") }
        try setMask(id, image: selected, context: context)
    }
    func invertMask(_ id: UUID, context: CIContext) throws {
        guard let layer = layers.first(where: { $0.id == id }), !layer.extras.isGroup, isEditable(id),
              let mask = layer.maskPreview ?? layer.extras.maskPNG.flatMap({ CIImage(data: $0) }) else { throw PhotoBrushError.invalid("Select an unlocked layer with a mask to invert.") }
        try setMask(id, image: mask.applyingFilter("CIColorInvert"), context: context)
    }
    /// Cut selected source pixels into a cropped, independently transformable
    /// layer. Keep the original source's flip, grading and post-flip mask semantics.
    @discardableResult func liftSelection(mask: CIImage, layerID: UUID, context: CIContext) throws -> UUID {
        guard let index = layers.firstIndex(where: { $0.id == layerID }), isEditable(layerID) else { throw PhotoBrushError.invalid("Select an unlocked pixel layer first.") }
        let original = layers[index]
        guard !original.extras.isGroup, !original.extras.isAdjustment, original.extras.text == nil,
              Self.validImage(mask), mask.extent.size == documentSize else { throw PhotoBrushError.invalid("Make a selection on an unlocked pixel layer first.") }
        let mapping = PhotoRenderEngine.pixelTransform(size: original.sourceImage.extent.size, position: original.position, scale: original.scale,
            rotation: original.rotation, skew: original.extras.skew, mirrored: original.adjustments.mirrored, document: documentSize)
        let local = mask.transformed(by: mapping.inverted()).composited(over: CIImage(color: .black).cropped(to: original.sourceImage.extent)).cropped(to: original.sourceImage.extent)
        guard let crop = PhotoPixels.maskBounds(local, context: context)?.intersection(original.sourceImage.extent),
              !crop.isNull, Self.validImage(original.sourceImage.cropped(to: crop)) else { throw PhotoBrushError.invalid("The selection does not contain pixels on this layer.") }
        let clear = CIImage(color: .clear).cropped(to: original.sourceImage.extent)
        let lifted = original.sourceImage.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: local])
        let remaining = clear.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: original.sourceImage, kCIInputMaskImageKey: local])
        let copy = PhotoLayer(name: String((original.name + " selection").prefix(4096)), sourceURL: nil,
            sourceImage: PhotoPixels.frozen(PhotoRenderEngine.normalized(lifted.cropped(to: crop)), context: context), thumbnail: nil)
        copy.isVisible = original.isVisible; copy.opacity = original.opacity; copy.blendMode = original.blendMode
        copy.scale = original.scale; copy.rotation = original.rotation; copy.adjustments = original.adjustments; copy.extras = original.extras
        let center = CGPoint(x: crop.midX, y: crop.midY).applying(mapping)
        copy.position = CGPoint(x: center.x - documentSize.width / 2, y: center.y - documentSize.height / 2)
        if let layerMask = original.maskPreview ?? original.extras.maskPNG.flatMap({ CIImage(data: $0) }) {
            let maskCrop = original.adjustments.mirrored ? CGRect(x: original.sourceImage.extent.width - crop.maxX, y: crop.minY, width: crop.width, height: crop.height) : crop
            copy.extras.maskPNG = try PhotoPixels.png(PhotoRenderEngine.normalized(layerMask.cropped(to: maskCrop)), context: context); copy.maskPreview = nil
        }
        let source = Self.mutable(original); source.sourceImage = PhotoPixels.frozen(remaining, context: context); source.thumbnail = nil
        var candidate = layers; candidate[index] = Self.snapshot(source); candidate.insert(Self.snapshot(copy), at: index)
        let document = copyState(layers: candidate, selected: copy.id); try Self.validate(document)
        finishTransaction(); try publish(document, label: "Lift selection to layer"); return copy.id
    }
    /// Crop the document window without flattening or destroying source pixels.
    /// Image transforms retain their visual positions; adjustment masks follow the
    /// new canvas exactly, matching the existing desktop crop semantics.
    func crop(to rect: CGRect, context: CIContext) throws {
        finishTransaction()
        let crop = rect.standardized.intersection(CGRect(origin: .zero, size: documentSize)).integral
        guard PhotoPixels.validSize(crop.size), crop.width >= 2, crop.height >= 2,
              CGRect(origin: .zero, size: documentSize).contains(crop) else { throw PhotoBrushError.invalid("Make a selection at least 2 by 2 pixels inside the canvas.") }
        guard crop != CGRect(origin: .zero, size: documentSize) else { return }
        let offset = CGPoint(x: documentSize.width / 2 - crop.midX, y: documentSize.height / 2 - crop.midY)
        let candidate = try layers.map { value -> PhotoLayerSnapshot in
            let layer = Self.mutable(value)
            if layer.extras.isAdjustment {
                if let mask = layer.maskPreview ?? layer.extras.maskPNG.flatMap({ CIImage(data: $0) }) {
                    layer.extras.maskPNG = try PhotoPixels.png(PhotoRenderEngine.normalized(mask.cropped(to: crop)), context: context)
                    layer.maskPreview = nil
                }
                layer.sourceImage = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: crop.size))
            } else { layer.position.x += offset.x; layer.position.y += offset.y }
            return Self.snapshot(layer)
        }
        try publish(PhotoDocumentSnapshot(layers: candidate, selectedLayerID: selectedLayerID, documentSize: crop.size,
            documentName: documentName, dpi: dpi, projectURL: projectURL), label: "Crop canvas")
    }

    func remove(_ id: UUID) throws {
        finishTransaction()
        guard layers.contains(where: { $0.id == id }), isEditable(id) else { throw PhotoBrushError.invalid("Select an unlocked layer to delete.") }
        let candidate = layers.filter { $0.id != id && $0.extras.groupID != id }
        let selection = candidate.contains { $0.id == selectedLayerID } ? selectedLayerID : candidate.first?.id
        try publish(copyState(layers: candidate, selected: selection), label: "Delete layer")
    }
    @discardableResult func duplicate(_ id: UUID) throws -> UUID {
        finishTransaction()
        guard let index = layers.firstIndex(where: { $0.id == id }) else { throw PhotoBrushError.invalid("Select a layer to duplicate.") }
        let original = layers[index], duplicateID = UUID()
        let copy = Self.mutable(original, id: duplicateID); copy.name += " copy"
        var block = [Self.snapshot(copy)]
        for child in layers where child.extras.groupID == id {
            let copiedChild = Self.mutable(child, id: UUID()); copiedChild.extras.groupID = duplicateID; block.append(Self.snapshot(copiedChild))
        }
        var candidate = layers; candidate.insert(contentsOf: block, at: index)
        try publish(copyState(layers: candidate, selected: duplicateID), label: "Duplicate layer"); return duplicateID
    }
    /// A group moves as a single block; children move only among their siblings.
    func reorder(_ id: UUID, by offset: Int) throws {
        finishTransaction()
        guard let item = layers.first(where: { $0.id == id }), isEditable(id) else { throw PhotoBrushError.invalid("Select an unlocked layer to reorder.") }
        let siblings = layers.filter { $0.extras.groupID == item.extras.groupID }
        guard let index = siblings.firstIndex(where: { $0.id == id }), offset != 0 else { return }
        let target = max(0, min(siblings.count - 1, index + max(-siblings.count, min(siblings.count, offset))))
        guard target != index else { return }
        let neighbour = siblings[target]
        let block = layers.filter { $0.id == id || $0.extras.groupID == id }
        var candidate = layers.filter { $0.id != id && $0.extras.groupID != id }
        guard let anchor = candidate.firstIndex(where: { $0.id == neighbour.id }) else { return }
        let insertion = target < index ? anchor : (candidate.lastIndex { $0.id == neighbour.id || $0.extras.groupID == neighbour.id } ?? anchor) + 1
        candidate.insert(contentsOf: block, at: insertion)
        try publish(copyState(layers: candidate), label: "Reorder layers")
    }
    @discardableResult func group(_ ids: [UUID], name: String = "Group") throws -> UUID {
        finishTransaction()
        let identifiers = Set(ids)
        guard !identifiers.isEmpty, identifiers.count == ids.count,
              ids.allSatisfy({ id in isEditable(id) && layers.first { $0.id == id }?.extras.isGroup == false }) else {
            throw PhotoBrushError.invalid("Select unlocked image or adjustment layers to group. Nested folders are not supported.")
        }
        let folder = PhotoLayer(name: name, sourceURL: nil, sourceImage: CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)), thumbnail: nil)
        folder.extras.isGroup = true
        let children = layers.filter { identifiers.contains($0.id) }.map { value -> PhotoLayerSnapshot in
            let copy = Self.mutable(value); copy.extras.groupID = folder.id; return Self.snapshot(copy)
        }
        let firstIndex = layers.firstIndex { identifiers.contains($0.id) } ?? 0
        let insertion = layers.prefix(firstIndex).filter { !identifiers.contains($0.id) }.count
        var candidate = layers.filter { !identifiers.contains($0.id) }
        candidate.insert(contentsOf: [Self.snapshot(folder)] + children, at: insertion)
        try publish(copyState(layers: candidate, selected: folder.id), label: "Group layers"); return folder.id
    }
    func moveToGroup(_ id: UUID, groupID: UUID?) throws {
        finishTransaction()
        guard let original = layers.first(where: { $0.id == id }), !original.extras.isGroup, isEditable(id) else { throw PhotoBrushError.invalid("Select an unlocked image or adjustment layer.") }
        if let groupID {
            guard layers.contains(where: { $0.id == groupID && $0.extras.isGroup && !$0.isLocked }) else { throw PhotoBrushError.invalid("Choose an unlocked layer folder.") }
        }
        guard original.extras.groupID != groupID else { return }
        let moved = Self.mutable(original); moved.extras.groupID = groupID
        var candidate = layers.filter { $0.id != id }
        let index = groupID.flatMap { group in candidate.firstIndex { $0.id == group } }.map { $0 + 1 } ?? 0
        candidate.insert(Self.snapshot(moved), at: index)
        try publish(copyState(layers: candidate), label: "Move layer to folder")
    }
    func ungroup(_ id: UUID) throws {
        finishTransaction()
        guard layers.contains(where: { $0.id == id && $0.extras.isGroup }), isEditable(id) else { throw PhotoBrushError.invalid("Select an unlocked layer folder.") }
        let candidate = layers.filter { $0.id != id }.map { value -> PhotoLayerSnapshot in
            guard value.extras.groupID == id else { return value }
            let child = Self.mutable(value); child.extras.groupID = nil; return Self.snapshot(child)
        }
        try publish(copyState(layers: candidate, selected: candidate.first?.id), label: "Ungroup layers")
    }

    func encodedProject(context: CIContext) throws -> Data {
        try Self.validate(state)
        let saved = try layers.map { layer -> PhotoProjectLayerData in
            var extra = layer.extras
            if let preview = layer.maskPreview { extra.maskPNG = try PhotoPixels.png(preview, context: context) }
            return PhotoProjectLayerData(id: layer.id, name: layer.name, sourcePath: layer.sourceURL?.path ?? "",
                isVisible: layer.isVisible, isLocked: layer.isLocked, opacity: layer.opacity, blendMode: layer.blendMode.rawValue,
                positionX: layer.position.x, positionY: layer.position.y, scale: layer.scale, rotation: layer.rotation,
                adjustments: PhotoProjectAdjustmentData(layer.adjustments), pixels: try PhotoPixels.png(layer.sourceImage, context: context), extras: extra)
        }
        let project = PhotoProjectFile(format: "NetVista Photo Project", version: 2, canvasWidth: documentSize.width,
            canvasHeight: documentSize.height, selectedLayerID: selectedLayerID, layers: saved, dpi: dpi)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(project)
        guard data.count <= Self.maximumProjectBytes else { throw PhotoBrushError.invalid("This photo project exceeds the 512 MB save limit.") }
        return data
    }
    func save(to url: URL, context: CIContext) throws {
        finishTransaction()
        try encodedProject(context: context).write(to: url, options: .atomic)
        state = PhotoDocumentSnapshot(layers: layers, selectedLayerID: selectedLayerID, documentSize: documentSize,
            documentName: url.lastPathComponent, dpi: dpi, projectURL: url)
        lastAction = "Save project"; revision &+= 1
    }
    /// Loading is atomic and does not silently drop missing/invalid layers. Legacy
    /// v1 external images may be supplied by a platform security-scoped resolver.
    func load(data: Data, projectURL: URL? = nil, imageResolver: ((URL) -> CIImage?)? = nil) throws {
        guard data.count <= Self.maximumProjectBytes else { throw PhotoBrushError.invalid("This photo project exceeds the 512 MB load limit.") }
        let project = try JSONDecoder().decode(PhotoProjectFile.self, from: data)
        guard project.format == "NetVista Photo Project", (1...2).contains(project.version), project.layers.count <= 1024 else { throw PhotoBrushError.invalid("Unsupported NetVista photo project.") }
        let decoded = try project.layers.map { saved -> PhotoLayerSnapshot in
            let sourceURL = saved.sourcePath.isEmpty ? nil : URL(fileURLWithPath: saved.sourcePath)
            let source: CIImage?
            if let pixels = saved.pixels {
                guard let image = CIImage(data: pixels) else { throw PhotoBrushError.invalid("A saved layer image is damaged.") }
                source = image
            } else if let url = sourceURL {
                source = imageResolver?(url) ?? (imageResolver == nil ? CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) : nil)
            } else { source = nil }
            guard let image = source, Self.validImage(image), let blendMode = PhotoBlendMode(rawValue: saved.blendMode) else {
                throw PhotoBrushError.invalid("The image or blend mode for ‘\(saved.name)’ could not be loaded. No layers were changed.")
            }
            let layer = PhotoLayer(id: saved.id, name: saved.name, sourceURL: sourceURL, sourceImage: PhotoRenderEngine.normalized(image), thumbnail: nil)
            layer.isVisible = saved.isVisible; layer.isLocked = saved.isLocked; layer.opacity = saved.opacity; layer.blendMode = blendMode
            layer.position = CGPoint(x: saved.positionX, y: saved.positionY); layer.scale = saved.scale; layer.rotation = saved.rotation
            layer.adjustments = saved.adjustments.adjustments; layer.extras = saved.extras ?? PhotoLayerExtras()
            return Self.snapshot(layer)
        }
        let selected = project.selectedLayerID.flatMap { id in decoded.contains { $0.id == id } ? id : nil } ?? decoded.first?.id
        let candidate = PhotoDocumentSnapshot(layers: decoded, selectedLayerID: selected,
            documentSize: CGSize(width: project.canvasWidth, height: project.canvasHeight), documentName: projectURL?.lastPathComponent ?? "Untitled photo",
            dpi: project.dpi ?? 72, projectURL: projectURL)
        try Self.validate(candidate)
        transaction = nil; state = candidate; undoHistory.removeAll(); redoHistory.removeAll(); lastAction = "Open project"; revision &+= 1
    }

    private func insert(_ layer: PhotoLayer, label: String) throws {
        let current = selectedLayer
        let parent = current?.extras.isGroup == true ? current?.id : current?.extras.groupID
        if let parent, !isEditable(parent) { throw PhotoBrushError.invalid("Unlock the selected folder before adding a layer.") }
        layer.extras.groupID = parent
        let index = (layers.firstIndex { $0.id == selectedLayerID } ?? 0) + (current?.extras.isGroup == true ? 1 : 0)
        var candidate = layers; candidate.insert(Self.snapshot(layer), at: index)
        let document = copyState(layers: candidate, selected: layer.id)
        try Self.validate(document)
        finishTransaction(); try publish(document, label: label)
    }
    private func metadata(_ id: UUID, label: String, _ edit: (PhotoLayer) -> Void) throws {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { throw PhotoBrushError.invalid("This layer is no longer in the document.") }
        let layer = Self.mutable(layers[index]); edit(layer)
        var candidate = layers; candidate[index] = Self.snapshot(layer)
        try publish(copyState(layers: candidate), label: label)
    }
    private func publish(_ candidate: PhotoDocumentSnapshot, label: String) throws {
        try Self.validate(candidate)
        guard !Self.equal(state, candidate) else { return }
        if transaction == nil { undoHistory.append((state, label)); redoHistory.removeAll() }
        state = candidate; lastAction = label; revision &+= 1
        if transaction == nil { trimHistory() }
    }
    private func copyState(layers: [PhotoLayerSnapshot]? = nil) -> PhotoDocumentSnapshot {
        copyState(layers: layers, selected: selectedLayerID)
    }
    private func copyState(layers: [PhotoLayerSnapshot]? = nil, selected: UUID?) -> PhotoDocumentSnapshot {
        PhotoDocumentSnapshot(layers: layers ?? self.layers, selectedLayerID: selected, documentSize: documentSize,
                              documentName: documentName, dpi: dpi, projectURL: projectURL)
    }
    private static func blank(size: CGSize, name: String, background: CIColor?, dpi: Double) -> PhotoDocumentSnapshot {
        // Validate before constructing a possibly unbounded Core Image crop.
        let safeSize = PhotoPixels.validSize(size) ? size : CGSize(width: 1, height: 1)
        let layer = PhotoLayer(name: background == nil ? "Layer 1" : "Background", sourceURL: nil,
            sourceImage: CIImage(color: background ?? .clear).cropped(to: CGRect(origin: .zero, size: safeSize)), thumbnail: nil)
        return PhotoDocumentSnapshot(layers: [snapshot(layer)], selectedLayerID: layer.id, documentSize: size, documentName: name, dpi: dpi)
    }
    private static func snapshot(_ value: PhotoLayer) -> PhotoLayerSnapshot {
        PhotoLayerSnapshot(id: value.id, name: value.name, sourceURL: value.sourceURL, sourceImage: value.sourceImage,
            thumbnail: value.thumbnail, isVisible: value.isVisible, isLocked: value.isLocked, opacity: value.opacity,
            blendMode: value.blendMode, position: value.position, scale: value.scale, rotation: value.rotation,
            adjustments: value.adjustments, extras: value.extras, maskPreview: value.maskPreview)
    }
    private static func mutable(_ value: PhotoLayerSnapshot, id: UUID? = nil) -> PhotoLayer {
        let layer = PhotoLayer(id: id ?? value.id, name: value.name, sourceURL: value.sourceURL, sourceImage: value.sourceImage, thumbnail: value.thumbnail)
        layer.isVisible = value.isVisible; layer.isLocked = value.isLocked; layer.opacity = value.opacity; layer.blendMode = value.blendMode
        layer.position = value.position; layer.scale = value.scale; layer.rotation = value.rotation; layer.adjustments = value.adjustments
        layer.extras = value.extras; layer.maskPreview = value.maskPreview; return layer
    }
    private static func validImage(_ image: CIImage) -> Bool {
        PhotoPixels.validSize(image.extent.size) && image.extent.origin.x.isFinite && image.extent.origin.y.isFinite &&
        image.extent.width.rounded(.down) == image.extent.width && image.extent.height.rounded(.down) == image.extent.height
    }
    private static func validate(_ document: PhotoDocumentSnapshot) throws {
        guard PhotoPixels.validSize(document.documentSize), document.documentSize.width.rounded(.down) == document.documentSize.width,
              document.documentSize.height.rounded(.down) == document.documentSize.height, (1...1200).contains(document.dpi),
              !document.documentName.isEmpty, document.documentName.utf8.count <= 4096, document.layers.count <= 1024 else {
            throw PhotoBrushError.invalid("Use whole-pixel dimensions up to 16,000 per side / 64 megapixels, 1–1,200 ppi, and at most 1,024 layers.")
        }
        let ids = Set(document.layers.map(\.id))
        guard ids.count == document.layers.count, document.selectedLayerID == nil || ids.contains(document.selectedLayerID!) else { throw PhotoBrushError.invalid("Invalid layer identifiers.") }
        for layer in document.layers {
            guard validImage(layer.sourceImage), !layer.name.isEmpty, layer.name.utf8.count <= 4096,
                  layer.opacity.isFinite, (0...1).contains(layer.opacity), layer.position.x.isFinite, layer.position.y.isFinite,
                  abs(layer.position.x) <= 1_000_000, abs(layer.position.y) <= 1_000_000,
                  layer.scale.isFinite, layer.scale > 0, layer.scale <= 100, layer.rotation.isFinite, abs(layer.rotation) <= 360_000 else { throw PhotoBrushError.invalid("Invalid image or transform for ‘\(layer.name)’ (image bounds \(layer.sourceImage.extent), scale \(layer.scale)).") }
            let a = layer.adjustments
            let values = [a.exposure, a.brightness, a.contrast, a.saturation, a.vibrance, a.highlights, a.shadows, a.temperature, a.tint, a.sharpen, a.blur, a.sepia, a.vignette]
            guard values.allSatisfy({ $0.isFinite }), abs(a.exposure) <= 20, abs(a.brightness) <= 2, (0...10).contains(a.contrast), (0...10).contains(a.saturation),
                  abs(a.vibrance) <= 2, (0...4).contains(a.highlights), abs(a.shadows) <= 4, (1000...40000).contains(a.temperature), abs(a.tint) <= 1000,
                  (0...10).contains(a.sharpen), (0...500).contains(a.blur), (0...1).contains(a.sepia), (0...10).contains(a.vignette) else { throw PhotoBrushError.invalid("Invalid photo adjustment values.") }
            let e = layer.extras
            guard e.skew.isFinite, abs(e.skew) <= 10, e.hue.isFinite, abs(e.hue) <= 360,
                  [e.black, e.white, e.midtone, e.curveShadows, e.curveHighlights, e.noise].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  e.fontSize == nil || (1...2000).contains(e.fontSize!), e.textColor == nil || (e.textColor!.count == 4 && e.textColor!.allSatisfy({ $0.isFinite && (0...1).contains($0) })),
                  !(e.isGroup && e.isAdjustment) else { throw PhotoBrushError.invalid("Invalid layer properties.") }
            if let parent = e.groupID {
                guard !e.isGroup, document.layers.contains(where: { $0.id == parent && $0.extras.isGroup && $0.extras.groupID == nil }) else { throw PhotoBrushError.invalid("Invalid layer folder reference.") }
            }
            if let mask = e.maskPNG {
                guard mask.count <= maximumProjectBytes, let decoded = CIImage(data: mask), validImage(decoded), decoded.extent.size == layer.sourceImage.extent.size else { throw PhotoBrushError.invalid("A layer mask is damaged or has the wrong dimensions.") }
            }
            if let mask = layer.maskPreview, !validImage(mask) || mask.extent.size != layer.sourceImage.extent.size { throw PhotoBrushError.invalid("Invalid layer mask preview.") }
        }
    }
    private static func equal(_ lhs: PhotoDocumentSnapshot, _ rhs: PhotoDocumentSnapshot) -> Bool {
        guard lhs.documentSize == rhs.documentSize, lhs.documentName == rhs.documentName, lhs.dpi == rhs.dpi, lhs.projectURL == rhs.projectURL,
              lhs.selectedLayerID == rhs.selectedLayerID, lhs.layers.count == rhs.layers.count else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return zip(lhs.layers, rhs.layers).allSatisfy { a, b in
            a.id == b.id && a.name == b.name && a.sourceURL == b.sourceURL && a.sourceImage === b.sourceImage &&
            a.maskPreview === b.maskPreview && a.isVisible == b.isVisible && a.isLocked == b.isLocked && a.opacity == b.opacity &&
            a.blendMode == b.blendMode && a.position == b.position && a.scale == b.scale && a.rotation == b.rotation &&
            (try? encoder.encode(PhotoProjectAdjustmentData(a.adjustments))) == (try? encoder.encode(PhotoProjectAdjustmentData(b.adjustments))) &&
            (try? encoder.encode(a.extras)) == (try? encoder.encode(b.extras))
        }
    }
    private func trimHistory() {
        while undoHistory.count > maximumHistorySteps { undoHistory.removeFirst() }
        // Count only extra immutable pixel buffers retained by Undo. Metadata-only
        // changes share CIImages and must not be charged as duplicate full rasters.
        func retainedCost() -> Double {
            var seen = Set(layers.flatMap { [$0.sourceImage, $0.maskPreview].compactMap { $0 }.map(ObjectIdentifier.init) })
            var bytes = 0.0
            for entry in undoHistory {
                for layer in entry.0.layers {
                    for image in [layer.sourceImage, layer.maskPreview].compactMap({ $0 }) where seen.insert(ObjectIdentifier(image)).inserted {
                        bytes += image.extent.width * image.extent.height * 4
                    }
                    bytes += Double(layer.extras.maskPNG?.count ?? 0)
                }
            }
            return bytes
        }
        while undoHistory.count > 1 && retainedCost() > historyByteBudget { undoHistory.removeFirst() }
    }
}
