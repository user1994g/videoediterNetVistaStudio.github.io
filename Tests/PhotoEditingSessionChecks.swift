#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreImage

#if !NETVISTA_SHARED_CORE_QA
@main
#endif
struct PhotoEditingSessionChecks {
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    static let size = CGSize(width: 16, height: 16)
    static func image(_ color: CIColor, size: CGSize = size) -> CIImage { CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size)) }
    static func pixel(_ image: CIImage, x: Int = 8, y: Int = 8) -> [Float] {
        var result = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &result, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return result
    }
    static func near(_ actual: Float, _ expected: Float, _ reason: String, tolerance: Float = 0.03) {
        precondition(actual.isFinite && abs(actual - expected) <= tolerance, "\(reason): \(actual), expected \(expected)")
    }
    static func reject(_ reason: String, _ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected rejected edit: " + reason) } catch { }
    }
    static func main() throws {
        precondition(pixel(image(.red))[0] > 0.99, "Native Core Image must render real pixels")
        try editingAndHistory()
        try groupingAndLocks()
        try translatingGroupsAndHistory()
        try atomicTextAndResizedMask()
        try liftingAndSelectionMaskPixels()
        try maskCropAndAdjustmentPixels()
        try projectRoundTrip()
        try rejectionAndHistoryBudget()
        try paintEraseHistory()
        print("PASS: shared photo session blank canvas, full layer commands, groups/locks, masks/crop/adjustment pixels, coalesced immutable multi-step history, v1/v2 native project round trip, atomic rejection and bounded history")
    }

    static func paintEraseHistory() throws {
        let doc = try PhotoEditingSession(size: CGSize(width: 128, height: 96), background: nil)
        let id = doc.selectedLayerID!
        let stroke = PhotoRasterStroke(base: doc.selectedLayer!.sourceImage, brush: PhotoBrush.defaults[1], size: 40,
            hardness: 0, opacity: 1, flow: 1, color: .black, erase: false, selection: nil)!
        stroke.append(CGPoint(x: 40, y: 48)); stroke.append(CGPoint(x: 88, y: 48))
        try doc.replacePixels(id, image: PhotoPixels.frozen(stroke.image(), context: context))
        precondition(doc.undo() && doc.redo())
        let erase = PhotoRasterStroke(base: doc.selectedLayer!.sourceImage, brush: PhotoBrush.defaults[1], size: 40,
            hardness: 0, opacity: 1, flow: 1, color: .black, erase: true, selection: nil)!
        erase.append(CGPoint(x: 64, y: 48))
        try doc.replacePixels(id, image: PhotoPixels.frozen(erase.image(), context: context))
        precondition(pixel(doc.render()!, x: 64, y: 48)[3] < 0.14, "Eraser keeps document extent and removes painted alpha after undo/redo")
    }

    static func editingAndHistory() throws {
        let session = try PhotoEditingSession(size: size, background: nil)
        let initialID = session.selectedLayerID!
        precondition(session.layers.count == 1 && session.documentSize == size && !session.canUndo)
        near(pixel(session.render()!)[3], 0, "New transparent canvas is blank")
        let blue = try session.addRaster(image(.blue), name: "Blue")
        let red = try session.addRaster(image(.red), name: "Red")
        near(pixel(session.render()!)[0], 1, "New layers added above selection")
        let unchanged = session.state
        var retainedMutableLayer: PhotoLayer?
        try session.mutateLayer(red, label: "Opacity") { retainedMutableLayer = $0; $0.opacity = 0.5 }
        retainedMutableLayer?.opacity = 0 // Must not alias the published value snapshot.
        precondition(session.selectedLayer?.opacity == 0.5 && unchanged.layers.first?.opacity == 1)
        near(pixel(session.render()!)[0], 0.5, "Opacity modifies actual rendering")
        near(pixel(session.render()!)[2], 0.5, "Opacity reveals the lower layer")
        precondition(session.undo()); near(pixel(session.render()!)[0], 1, "Undo restores layer opacity")
        precondition(session.redo()); near(pixel(session.render()!)[0], 0.5, "Redo restores blend pixels")
        let historyCount = session.undoCount
        try session.beginTransaction("Drag opacity")
        for value in [0.2, 0.3, 0.4, 0.75] { try session.setOpacity(red, to: value) }
        precondition(session.undoCount == historyCount, "Gesture must not add per-tick history")
        session.finishTransaction()
        precondition(session.undoCount == historyCount + 1)
        precondition(session.undo()); near(pixel(session.render()!)[0], 0.5, "One undo restores gesture start")
        let redoCount = session.redoCount
        try session.beginTransaction("Cancelled drag"); try session.setOpacity(red, to: 0.1); session.cancelTransaction()
        precondition(session.redoCount == redoCount && session.selectedLayer?.opacity == 0.5)
        precondition(session.redo()); near(pixel(session.render()!)[0], 0.75, "Cancel keeps existing redo")
        let noOpHistory = session.undoCount
        try session.setOpacity(red, to: 0.75)
        precondition(session.undoCount == noOpHistory, "No-op commands must not erase useful Undo")

        try session.setVisibility(red, to: false)
        near(pixel(session.render()!)[2], 1, "Visibility actually hides layer")
        try session.setVisibility(red, to: true)
        try session.setBlendMode(red, to: .multiply)
        near(pixel(session.render()!)[2], 0.25, "Shared multiply with opacity")
        try session.reorder(red, by: 1)
        near(pixel(session.render()!)[2], 1, "Reorder affects visual stacking")
        try session.rename(red, to: "  Subject  ")
        precondition(session.layers.first { $0.id == red }?.name == "Subject")
        let copy = try session.duplicate(red)
        precondition(session.selectedLayerID == copy && session.layers.first { $0.id == copy }?.name == "Subject copy")
        try session.remove(copy); precondition(session.layers.count == 3)
        try session.remove(red); try session.remove(blue); try session.remove(initialID)
        precondition(session.layers.isEmpty && session.selectedLayerID == nil)
        near(pixel(session.render()!)[3], 0, "Empty layer stack is transparent")
        precondition(session.undo()); precondition(session.layers.count == 1)

        let paint = try session.addBlankLayer(name: "Paint")
        try session.replacePixels(paint, image: image(.green))
        let captured = session.state
        try session.replacePixels(paint, image: image(.red))
        let offMainCapture = try PhotoEditingSession(snapshot: captured)
        near(pixel(offMainCapture.render()!)[1], 1, "Detached snapshot retains prior pixels")
        precondition(session.undo()); near(pixel(session.render()!)[1], 1, "Pixel replacement is undoable")
    }

    static func groupingAndLocks() throws {
        let session = try PhotoEditingSession(size: size, background: .blue)
        let background = session.selectedLayerID!
        let red = try session.addRaster(image(.red), name: "Subject")
        let group = try session.group([red], name: "Foreground")
        precondition(session.selectedLayerID == group && session.layers.first { $0.id == red }?.extras.groupID == group)
        try session.setOpacity(group, to: 0.5)
        near(pixel(session.render()!)[0], 0.5, "Group opacity is composited")
        try session.setVisibility(group, to: false)
        near(pixel(session.render()!)[2], 1, "Group visibility hides children")
        try session.setVisibility(group, to: true); try session.setLocked(group, to: true)
        reject("Parent lock") { try session.setOpacity(red, to: 0.1) }
        reject("Locked group add") { _ = try session.addBlankLayer() }
        reject("Locked group delete") { try session.remove(group) }
        reject("Locked group reparent") { try session.moveToGroup(red, groupID: nil) }
        try session.setLocked(group, to: false)
        let duplicate = try session.duplicate(group)
        precondition(session.layers.filter { $0.extras.groupID == duplicate }.count == 1)
        precondition(session.layers.first { $0.extras.groupID == duplicate }?.id != red)
        try session.remove(duplicate)
        precondition(session.layers.count == 3, "Deleting duplicate folder must remove only its children")
        try session.ungroup(group)
        precondition(session.layers.count == 2 && session.layers.first { $0.id == red }?.extras.groupID == nil)
        let other = try session.group([red], name: "Other")
        try session.moveToGroup(background, groupID: other)
        precondition(session.layers.filter { $0.extras.groupID == other }.count == 2)
        try session.reorder(background, by: 1)
        precondition(session.layers.last?.id == background)
        reject("Nested group") { _ = try session.group([other]) }
        try session.moveToGroup(background, groupID: nil)
        precondition(session.layers.first?.id == background)
        try session.setLocked(red, to: true)
        reject("Locked image pixels") { try session.replacePixels(red, image: image(.green)) }
        try session.setVisibility(red, to: false) // Eye/lock controls remain available.
        precondition(session.layers.first { $0.id == red }?.isVisible == false)
    }

    static func translatingGroupsAndHistory() throws {
        let session = try PhotoEditingSession(size: size, background: nil)
        let tile = CGSize(width: 4, height: 4)
        let red = try session.addRaster(image(.red, size: tile), name: "Red", fit: false)
        try session.mutateLayer(red) { $0.position = CGPoint(x: -4, y: 0) }
        let green = try session.addRaster(image(.green, size: tile), name: "Green", fit: false)
        try session.mutateLayer(green) { $0.position = CGPoint(x: 0, y: 4) }
        let blue = try session.addRaster(image(.blue, size: tile), name: "Locked blue", fit: false)
        try session.mutateLayer(blue) { $0.position = CGPoint(x: 4, y: -4) }
        let adjustment = try session.addAdjustmentLayer()
        let folder = try session.group([red, green, blue, adjustment])
        try session.setLocked(blue, to: true)
        near(pixel(session.render()!, x: 3, y: 8)[0], 1, "Group source starts at its original pixel position")
        let history = session.undoCount
        try session.beginTransaction("Drag folder")
        try session.translate(folder, by: CGPoint(x: 1, y: -1))
        try session.translate(folder, by: CGPoint(x: 2, y: -1))
        precondition(session.undoCount == history, "Moving folder children must not add one history entry per drag tick")
        session.finishTransaction()
        precondition(session.undoCount == history + 1)
        precondition(session.layers.first { $0.id == red }?.position == CGPoint(x: -1, y: -2))
        precondition(session.layers.first { $0.id == green }?.position == CGPoint(x: 3, y: 2))
        precondition(session.layers.first { $0.id == blue }?.position == CGPoint(x: 4, y: -4), "Locked folder children stay fixed")
        precondition(session.layers.first { $0.id == adjustment }?.position == .zero, "Adjustment children do not accumulate phantom transforms")
        precondition(session.layers.first { $0.id == folder }?.position == .zero, "Group movement belongs to its rendered children")
        let moved = session.render()!
        near(pixel(moved, x: 3, y: 8)[3], 0, "Folder motion removes the old rendered source position")
        near(pixel(moved, x: 6, y: 6)[0], 1, "Folder motion translates real red pixels")
        near(pixel(moved, x: 10, y: 10)[1], 1, "Folder children preserve their relative position")
        near(pixel(moved, x: 12, y: 4)[2], 1, "Locked child pixels stay in place")
        precondition(session.undo())
        near(pixel(session.render()!, x: 3, y: 8)[0], 1, "One Undo restores the entire folder drag")
        near(pixel(session.render()!, x: 7, y: 12)[1], 1, "Undo restores every moved child together")
        precondition(session.redo())
        near(pixel(session.render()!, x: 6, y: 6)[0], 1, "Redo restores actual translated pixels")

        let beforeNoOp = session.undoCount, beforeRevision = session.revision
        try session.translate(folder, by: .zero)
        reject("Adjustment-layer movement") { try session.translate(adjustment, by: CGPoint(x: 1, y: 1)) }
        reject("Locked raster movement") { try session.translate(blue, by: CGPoint(x: 1, y: 1)) }
        reject("Nonfinite movement") { try session.translate(folder, by: CGPoint(x: CGFloat.nan, y: 1)) }
        reject("Infinite movement") { try session.translate(folder, by: CGPoint(x: 1, y: CGFloat.infinity)) }
        precondition(session.undoCount == beforeNoOp && session.revision == beforeRevision, "Rejected or zero moves create no phantom history")

        try session.setLocked(red, to: true); try session.setLocked(green, to: true)
        let lockedHistory = session.undoCount, lockedRevision = session.revision
        reject("Folder without movable children") { try session.translate(folder, by: CGPoint(x: 1, y: 1)) }
        precondition(session.undoCount == lockedHistory && session.revision == lockedRevision)
        try session.setLocked(red, to: false); try session.setLocked(green, to: false)
        try session.mutateLayer(red) { $0.position.x = 999_999 }
        let positions = session.layers.map(\.position), atomicHistory = session.undoCount, atomicRevision = session.revision
        reject("Atomic folder position boundary") { try session.translate(folder, by: CGPoint(x: 2, y: 0)) }
        precondition(session.layers.map(\.position) == positions && session.undoCount == atomicHistory && session.revision == atomicRevision,
            "A rejected folder translation must keep every child and history unchanged")

        let raster = try PhotoEditingSession(size: size, background: nil)
        let rasterID = try raster.addRaster(image(.red, size: tile), fit: false)
        try raster.translate(rasterID, by: CGPoint(x: -3, y: -3))
        near(pixel(raster.render()!, x: 4, y: 4)[0], 1, "Direct raster translation moves source pixels")
        near(pixel(raster.render()!, x: 8, y: 8)[3], 0, "Direct raster translation clears its former position")
        precondition(raster.undo())
        near(pixel(raster.render()!, x: 8, y: 8)[0], 1, "Direct raster movement is reversible")
    }

    static func atomicTextAndResizedMask() throws {
        let session = try PhotoEditingSession(size: size, background: nil)
        let originalHistory = session.undoCount, originalLayers = session.layers.count
        let small = CGSize(width: 4, height: 4)
        let id = try session.setTextRaster(image: image(.red, size: small), existingID: nil, text: "Small",
            fontName: "Helvetica", fontSize: 18, color: [1, 0, 0, 1], position: CGPoint(x: 1, y: -1), context: context)
        precondition(session.undoCount == originalHistory + 1, "Text creation publishes pixels and metadata in one Undo step")
        precondition(session.selectedLayer?.extras.text == "Small" && session.selectedLayer?.extras.fontSize == 18)
        precondition(session.undo() && session.layers.count == originalLayers, "One Undo removes a newly created text layer completely")
        precondition(session.redo() && session.selectedLayerID == id && session.selectedLayer?.extras.text == "Small")
        let oldMask = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 2, width: 2, height: 2))
            .composited(over: image(.white, size: small))
        try session.setMask(id, image: oldMask, context: context)
        let folder = try session.group([id], name: "Typography")
        try session.mutateLayer(id) { $0.opacity = 0.75; $0.blendMode = .screen; $0.rotation = 12; $0.scale = 1.5; $0.extras.hue = 15 }
        let original = session.layers.first { $0.id == id }!, beforeUpdate = session.undoCount
        try session.setTextRaster(image: image(.green, size: CGSize(width: 8, height: 8)), existingID: id,
            text: "Larger text", fontName: "Helvetica-Bold", fontSize: 24, color: [0, 1, 0, 1], position: nil, context: context)
        let changed = session.layers.first { $0.id == id }!
        precondition(session.undoCount == beforeUpdate + 1, "A masked text resize is one atomic Undo step")
        precondition(changed.sourceImage.extent.size == CGSize(width: 8, height: 8) && changed.extras.text == "Larger text")
        precondition(changed.extras.fontName == "Helvetica-Bold" && changed.extras.fontSize == 24 && changed.extras.textColor == [0, 1, 0, 1])
        precondition(changed.name == original.name && changed.position == original.position && changed.opacity == original.opacity &&
            changed.blendMode == original.blendMode && changed.rotation == original.rotation && changed.scale == original.scale &&
            changed.extras.groupID == folder && changed.extras.hue == 15, "Updating text preserves the layer's transform, folder, and grading metadata")
        let resizedMask = CIImage(data: changed.extras.maskPNG!)!
        precondition(resizedMask.extent.size == CGSize(width: 8, height: 8))
        near(pixel(resizedMask, x: 0, y: 7)[0], 0, "Resized text mask retains the old hidden area at the top-left")
        near(pixel(resizedMask, x: 3, y: 7)[0], 1, "Resized text mask preserves old revealed pixels")
        near(pixel(resizedMask, x: 7, y: 7)[0], 1, "New text width is revealed")
        near(pixel(resizedMask, x: 0, y: 0)[0], 1, "New text height is revealed")
        precondition(session.undo())
        let restored = session.layers.first { $0.id == id }!
        precondition(restored.sourceImage.extent.size == small && restored.extras.text == "Small" && restored.extras.maskPNG == original.extras.maskPNG,
            "One Undo restores the original text, raster, and mask together")
        precondition(session.redo())
        try session.setLocked(folder, to: true)
        let lockedHistory = session.undoCount, lockedRevision = session.revision
        reject("Locked folder text update") {
            try session.setTextRaster(image: image(.red, size: small), existingID: id, text: "Locked", fontName: "Helvetica",
                fontSize: 18, color: [1, 0, 0, 1], position: nil, context: context)
        }
        reject("Text insertion into locked folder") {
            try session.setTextRaster(image: image(.red, size: small), existingID: nil, text: "Blocked", fontName: "Helvetica",
                fontSize: 18, color: [1, 0, 0, 1], position: nil, context: context)
        }
        precondition(session.undoCount == lockedHistory && session.revision == lockedRevision, "Rejected text edits keep current state and history unchanged")
    }

    static func liftingAndSelectionMaskPixels() throws {
        let document = CGSize(width: 32, height: 32)
        let session = try PhotoEditingSession(size: document, background: nil)
        let id = try session.addRaster(image(.red), name: "Subject", sourceURL: URL(fileURLWithPath: "/original.png"), fit: false)
        let crop = CGRect(x: 2, y: 4, width: 4, height: 4)
        let patterned = CIImage(color: .green).cropped(to: crop).composited(over: image(.red))
        try session.mutateLayer(id) { $0.sourceImage = patterned; $0.adjustments.mirrored = true; $0.rotation = 90; $0.position = CGPoint(x: 2, y: -1); $0.opacity = 0.8; $0.extras.hue = 15 }
        let oldMask = CIImage(color: .black).cropped(to: CGRect(x: 10, y: 4, width: 2, height: 4)).composited(over: image(.white))
        try session.setMask(id, image: oldMask, context: context)
        let folder = try session.group([id], name: "Subject folder")
        let original = session.layers.first { $0.id == id }!
        let mapping = PhotoRenderEngine.pixelTransform(size: size, position: original.position, scale: original.scale,
            rotation: original.rotation, skew: original.extras.skew, mirrored: true, document: document)
        let selection = CIImage(color: .white).cropped(to: crop).composited(over: image(.black)).transformed(by: mapping)
            .composited(over: image(.black, size: document)).cropped(to: CGRect(origin: .zero, size: document))
        let before = session.render()!, history = session.undoCount
        let liftedID = try session.liftSelection(mask: selection, layerID: id, context: context)
        let lifted = session.layers.first { $0.id == liftedID }!, remaining = session.layers.first { $0.id == id }!
        precondition(session.undoCount == history + 1 && session.selectedLayerID == liftedID, "Lift creates one complete Undo step")
        precondition(lifted.sourceImage.extent.size == crop.size && lifted.sourceURL == nil, "Lifted pixels use their own cropped source bounds")
        precondition(lifted.scale == original.scale && lifted.rotation == 90 && lifted.opacity == 0.8 && lifted.adjustments.mirrored &&
            lifted.extras.groupID == folder && lifted.extras.hue == 15, "Lift keeps transforms, flip, grading, opacity and folder membership")
        near(pixel(remaining.sourceImage, x: 3, y: 5)[3], 0, "Lift cuts selected source pixels out")
        near(pixel(remaining.sourceImage, x: 10, y: 10)[0], 1, "Lift leaves unrelated original source pixels intact")
        near(pixel(lifted.sourceImage, x: 1, y: 1)[1], 1, "Lift retains actual green source pixels")
        let croppedMask = CIImage(data: lifted.extras.maskPNG!)!
        near(pixel(croppedMask, x: 0, y: 1)[0], 0, "A flipped lift crops the corresponding post-flip hidden mask area")
        near(pixel(croppedMask, x: 3, y: 1)[0], 1, "A flipped lift preserves the mask's revealed side")
        let after = session.render()!
        for sample in [CGPoint(x: 3, y: 6), CGPoint(x: 5, y: 6), CGPoint(x: 10, y: 10)] {
            let point = sample.applying(mapping), a = pixel(before, x: Int(floor(point.x)), y: Int(floor(point.y))), b = pixel(after, x: Int(floor(point.x)), y: Int(floor(point.y)))
            for channel in 0..<4 { near(b[channel], a[channel], "Lift preserves transformed rendered pixels and masks") }
        }
        precondition(session.undo() && !session.layers.contains { $0.id == liftedID })
        precondition(session.layers.first { $0.id == id }?.sourceImage === original.sourceImage && session.layers.first { $0.id == id }?.extras.maskPNG == original.extras.maskPNG,
            "One Undo restores the entire uncut source and original mask")
        precondition(session.redo() && session.layers.contains { $0.id == liftedID })
        let revision = session.revision, count = session.undoCount
        reject("No selected pixels to lift") { _ = try session.liftSelection(mask: image(.black, size: document), layerID: id, context: context) }
        precondition(session.revision == revision && session.undoCount == count)

        let masks = try PhotoEditingSession(size: document, background: nil)
        let mirrored = try masks.addRaster(image(.red), fit: false)
        try masks.mutateLayer(mirrored) { $0.adjustments.mirrored = true }
        let left = CIImage(color: .white).cropped(to: CGRect(x: 8, y: 8, width: 8, height: 16)).composited(over: image(.black, size: document))
        try masks.maskSelection(mirrored, mask: left, reveal: true, context: context)
        near(pixel(masks.render()!, x: 11, y: 16)[3], 1, "Reveal selection uses post-flip mask coordinates")
        near(pixel(masks.render()!, x: 21, y: 16)[3], 0, "Reveal selection masks the unselected side")
        let stroke = PhotoRasterStroke(base: CIImage(data: masks.selectedLayer!.extras.maskPNG!)!, brush: PhotoBrush.defaults[0],
            size: 4, hardness: 1, opacity: 1, flow: 1, color: .black, erase: false, selection: nil)!
        stroke.append(CGPoint(x: 3, y: 8)); try masks.setMask(mirrored, image: stroke.image(), context: context)
        near(pixel(masks.render()!, x: 11, y: 16)[3], 0, "Painting a mask on a flipped image affects the displayed cursor side")
        precondition(masks.undo())
        try masks.maskSelection(mirrored, mask: left, reveal: false, context: context)
        near(pixel(masks.render()!, x: 11, y: 16)[3], 0, "Hide selection conceals selected pixels")
        near(pixel(masks.render()!, x: 21, y: 16)[3], 1, "Hide selection reveals remaining pixels")
        try masks.invertMask(mirrored, context: context)
        near(pixel(masks.render()!, x: 11, y: 16)[3], 1, "Invert restores selected revealed pixels")
        near(pixel(masks.render()!, x: 21, y: 16)[3], 0, "Invert hides the previous revealed side")
    }

    static func maskCropAndAdjustmentPixels() throws {
        let session = try PhotoEditingSession(size: size, background: nil)
        let red = try session.addRaster(image(.red), name: "Masked subject")
        try session.addMask(red, reveal: false, context: context)
        near(pixel(session.render()!)[3], 0, "Hide-all mask actually hides source pixels")
        precondition(session.layers.first { $0.id == red }?.sourceImage === session.selectedLayer?.sourceImage)
        try session.removeMask(red)
        near(pixel(session.render()!)[0], 1, "Removing mask recovers original pixels")
        let mask = image(.black).composited(over: image(.white))
        let leftWhite = image(.white, size: CGSize(width: 8, height: 16)).composited(over: mask)
        try session.setMask(red, image: leftWhite, context: context)
        near(pixel(session.render()!, x: 2)[3], 1, "Mask keeps white side")
        near(pixel(session.render()!, x: 12)[3], 0, "Mask hides black side")
        try session.mutateLayer(red, label: "Transform") { $0.position = CGPoint(x: 2, y: -1); $0.scale = 0.5; $0.rotation = 90; $0.extras.skew = 0.2 }
        precondition(session.selectedLayer?.rotation == 90 && session.selectedLayer?.extras.skew == 0.2)
        precondition(session.undo())
        let adjustment = try session.addAdjustmentLayer()
        try session.mutateLayer(adjustment, label: "Desaturate") { $0.adjustments.saturation = 0 }
        let gray = pixel(session.render()!, x: 2)
        near(gray[0], gray[1], "Adjustment layer changes lower source colours")
        near(gray[1], gray[2], "Adjustment layer produces true grey")
        try session.addMask(adjustment, reveal: true, context: context)
        let previousPixels = pixel(session.render()!, x: 2, y: 5)
        try session.crop(to: CGRect(x: 1, y: 2, width: 6, height: 10), context: context)
        precondition(session.documentSize == CGSize(width: 6, height: 10))
        let cropped = pixel(session.render()!, x: 1, y: 3)
        near(cropped[0], previousPixels[0], "Crop retains original document pixels")
        near(cropped[3], previousPixels[3], "Crop retains alpha without flattening")
        precondition(session.layers.first { $0.id == red }?.sourceImage.extent.size == size)
        precondition(session.layers.first { $0.id == adjustment }?.sourceImage.extent.size == CGSize(width: 6, height: 10))
        let encoded = try session.encodedProject(context: context)
        let reopened = try PhotoEditingSession(); try reopened.load(data: encoded)
        near(pixel(reopened.render()!, x: 1, y: 3)[0], cropped[0], "Cropped masks survive native project save")
        precondition(session.undo()); precondition(session.documentSize == size)
    }

    static func projectRoundTrip() throws {
        let session = try PhotoEditingSession(size: size, name: "Layers", background: .blue, dpi: 300)
        let red = try session.addRaster(image(.red), name: "Embedded subject", sourceURL: URL(fileURLWithPath: "/missing-source.png"))
        try session.mutateLayer(red) {
            $0.opacity = 0.7; $0.blendMode = .screen; $0.position = CGPoint(x: 1, y: 2); $0.scale = 0.8; $0.rotation = 15
            $0.adjustments.exposure = 0.5; $0.adjustments.mirrored = true; $0.extras.hue = 40; $0.extras.noise = 0
            $0.extras.text = "Editable text"; $0.extras.fontName = "Helvetica"; $0.extras.fontSize = 22; $0.extras.textColor = [1, 0, 0, 1]
            $0.extras.black = 0.1; $0.extras.white = 0.9; $0.extras.curveShadows = 0.3; $0.extras.midtone = 0.55; $0.extras.curveHighlights = 0.8
        }
        try session.addMask(red, context: context)
        let folder = try session.group([red], name: "Folder")
        try session.setLocked(folder, to: true)
        let data = try session.encodedProject(context: context)
        let schema = try JSONDecoder().decode(PhotoProjectFile.self, from: data)
        precondition(schema.version == 2 && schema.format == "NetVista Photo Project" && schema.dpi == 300)
        precondition(schema.layers.allSatisfy { $0.pixels != nil })
        let loaded = try PhotoEditingSession(); try loaded.load(data: data)
        precondition(loaded.layers.count == session.layers.count && loaded.selectedLayerID == folder && loaded.dpi == 300)
        let subject = loaded.layers.first { $0.id == red }!
        precondition(subject.extras.text == "Editable text" && subject.extras.fontName == "Helvetica" && subject.extras.fontSize == 22)
        precondition(subject.extras.groupID == folder && subject.extras.maskPNG != nil && subject.sourceURL?.path == "/missing-source.png")
        precondition(subject.opacity == 0.7 && subject.rotation == 15 && subject.scale == 0.8 && subject.adjustments.mirrored)
        precondition(!loaded.canUndo && !loaded.canRedo)
        let expected = pixel(session.render()!), actual = pixel(loaded.render()!)
        for component in 0..<4 { near(actual[component], expected[component], "Full project rendered component \(component)") }

        // Legacy external-reference projects resolve through the host's native
        // picker/security-scope adapter. Embedded pixels never require old paths.
        let legacyLayer = PhotoProjectLayerData(id: UUID(), name: "Legacy", sourcePath: "/legacy.png", isVisible: true, isLocked: false,
            opacity: 1, blendMode: "Normal", positionX: 0, positionY: 0, scale: 1, rotation: 0, adjustments: PhotoProjectAdjustmentData(PhotoAdjustments()))
        let legacy = PhotoProjectFile(format: "NetVista Photo Project", version: 1, canvasWidth: 16, canvasHeight: 16, selectedLayerID: legacyLayer.id, layers: [legacyLayer])
        let legacyData = try JSONEncoder().encode(legacy)
        try loaded.load(data: legacyData, imageResolver: { url in precondition(url.path == "/legacy.png"); return image(.green) })
        near(pixel(loaded.render()!)[1], 1, "Native legacy project image resolver")
        precondition(loaded.dpi == 72)
        let migrated = try JSONDecoder().decode(PhotoProjectFile.self, from: loaded.encodedProject(context: context))
        precondition(migrated.version == 2 && migrated.layers[0].pixels != nil)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netvista-photo-session-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Shared.netvistaphoto")
        try loaded.save(to: url, context: context)
        precondition(loaded.projectURL == url && loaded.documentName == "Shared.netvistaphoto")
        let disk = try PhotoEditingSession(); try disk.load(data: Data(contentsOf: url), projectURL: url)
        near(pixel(disk.render()!)[1], 1, "Atomic disk save keeps actual embedded pixels")
        let lastSavedURL = loaded.projectURL
        reject("Failed filesystem save") { try loaded.save(to: directory.appendingPathComponent("absent/nested.netvistaphoto"), context: context) }
        precondition(loaded.projectURL == lastSavedURL)
    }

    static func rejectionAndHistoryBudget() throws {
        reject("Fractional canvas") { _ = try PhotoEditingSession(size: CGSize(width: 4.5, height: 8)) }
        reject("Infinite canvas") { _ = try PhotoEditingSession(size: CGSize(width: CGFloat.infinity, height: 8)) }
        let session = try PhotoEditingSession(size: size, maximumHistorySteps: 3)
        let id = session.selectedLayerID!
        for number in 0..<10 { try session.rename(id, to: "Layer \(number)") }
        precondition(session.undoCount == 3, "History step bound is enforced")
        let previous = session.state, revision = session.revision, history = session.undoCount
        reject("Invalid opacity") { try session.setOpacity(id, to: .nan) }
        reject("Invalid transform") { try session.mutateLayer(id) { $0.scale = -1 } }
        reject("Invalid colour") { try session.mutateLayer(id) { $0.adjustments.temperature = .infinity } }
        reject("Wrong mask dimensions") { try session.setMask(id, image: image(.white, size: CGSize(width: 4, height: 4)), context: context) }
        reject("No raw folder mutation") { try session.mutateLayer(id) { $0.extras.groupID = UUID() } }
        reject("Unknown ID") { try session.setOpacity(UUID(), to: 0.5) }
        reject("Empty name") { try session.rename(id, to: "  ") }
        precondition(session.revision == revision && session.undoCount == history && session.selectedLayer?.name == previous.layers[0].name)
        let data = try session.encodedProject(context: context)
        var malformed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var savedLayers = malformed["layers"] as! [[String: Any]]
        savedLayers[0]["scale"] = -1; malformed["layers"] = savedLayers
        let corrupt = try JSONSerialization.data(withJSONObject: malformed)
        reject("Atomic load transform validation") { try session.load(data: corrupt) }
        precondition(session.revision == revision && session.undoCount == history)
        savedLayers[0]["scale"] = 1; savedLayers.append(savedLayers[0]); malformed["layers"] = savedLayers
        reject("Duplicate file IDs") { try session.load(data: JSONSerialization.data(withJSONObject: malformed)) }
        precondition(session.layers.count == 1 && session.undoCount == history)
        precondition(session.undo()); let redo = session.redoCount
        reject("Rejected edit preserves redo") { try session.setOpacity(id, to: 2) }
        precondition(session.redoCount == redo)

        let bounded = try PhotoEditingSession(size: size, background: nil, historyByteBudget: 1500)
        let paint = bounded.selectedLayerID!
        for value in 0..<10 { try bounded.replacePixels(paint, image: image(CIColor(red: CGFloat(value) / 10, green: 0, blue: 0))) }
        precondition(bounded.undoCount == 1, "History must not retain unbounded distinct pixel buffers")
        precondition(bounded.undo()); near(pixel(bounded.render()!)[0], 0.8, "Budget keeps the most recent reversible stroke")
        let metadataOnly = try PhotoEditingSession(size: size, background: .white, maximumHistorySteps: 10, historyByteBudget: 1)
        for number in 0..<8 { try metadataOnly.rename(metadataOnly.selectedLayerID!, to: "Metadata \(number)") }
        precondition(metadataOnly.undoCount == 8, "Metadata snapshots sharing pixels must not be charged as full raster copies")
    }
}
