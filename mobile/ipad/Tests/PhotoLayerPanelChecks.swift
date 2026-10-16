import UIKit
import CoreImage

@MainActor enum PhotoLayerPanelChecks {
    static func run(in root: UIView) async throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw PhotoBrushError.invalid("Layer panel: " + message) }
        }
        let panel = PhotoLayerPanelView(frame: CGRect(x: 5, y: 5, width: 300, height: 260))
        root.addSubview(panel); defer { panel.removeFromSuperview() }
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: red.extent)
        func layer(_ name: String, image: CIImage = red, id: UUID = UUID(), group: UUID? = nil, folder: Bool = false) -> PhotoLayerSnapshot {
            var extras = PhotoLayerExtras(); extras.groupID = group; extras.isGroup = folder
            return PhotoLayerSnapshot(id: id, name: name, sourceURL: nil, sourceImage: image, thumbnail: nil,
                isVisible: true, isLocked: false, opacity: 1, blendMode: .normal, position: .zero,
                scale: 1, rotation: 0, adjustments: PhotoAdjustments(), extras: extras)
        }
        let folder = layer("Folder", folder: true), child = layer("Child", group: folder.id)
        let nested = layer("Nested", group: folder.id, folder: true), grandchild = layer("Grandchild", group: nested.id)
        let outside = layer("Outside")
        panel.setLayers([folder, child, nested, grandchild, outside], selectedID: child.id, revision: 1)
        panel.layoutIfNeeded()
        guard let table = panel.subviews.first as? UITableView else { throw PhotoBrushError.invalid("Missing real layer table") }
        var selected: UUID?, visible: UUID?, actions: UUID?
        panel.onSelect = { selected = $0 }; panel.onVisibility = { visible = $0 }; panel.onActions = { actions = $0 }
        panel.tableView(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        try check(selected == child.id && actions == nil, "Selecting a layer does not open an actions modal")
        try PhotoWorkspaceChecks.button(panel, "photo.layer.eye.\(child.id)").sendActions(for: .touchUpInside)
        try PhotoWorkspaceChecks.button(panel, "photo.layer.actions.\(child.id)").sendActions(for: .touchUpInside)
        try check(visible == child.id && actions == child.id, "Visibility and explicit actions target the represented layer")
        try PhotoWorkspaceChecks.button(panel, "photo.layer.folder.\(folder.id)").sendActions(for: .touchUpInside)
        try check(panel.visibleLayers.map(\.id) == [folder.id, outside.id], "Collapse hides descendants, not unrelated layers")
        panel.toggleFolder(folder.id); panel.toggleFolder(nested.id)
        try check(panel.visibleLayers.map(\.id) == [folder.id, child.id, nested.id, outside.id], "Nested folder collapse is independent")
        panel.setLayers([folder, child, nested, grandchild, outside], selectedID: outside.id, revision: 2)
        try check(panel.visibleLayers.count == 4, "Edits keep navigation folder state")
        panel.toggleFolder(nested.id)

        let many = (0..<100).map { layer("Image \($0)") }
        panel.setLayers(many, selectedID: many[0].id, revision: 3); panel.layoutIfNeeded()
        for _ in 0..<30 {
            if panel.cachedThumbnailCount > 0 { break }
            await PhotoWorkspaceChecks.pause()
        }
        try check(panel.cachedThumbnailCount > 0 && panel.cachedThumbnailCount <= 64 && panel.renderedThumbnailCount < 20,
                  "Image thumbnails are bounded and visible-only, not all 100 layers")
        // Replace an in-flight image with the same layer id. The previous
        // generation must not paint its red result into the new blue row.
        let changed = layer("Changed", image: blue, id: many[0].id)
        panel.setLayers([changed], selectedID: changed.id, revision: 4); panel.layoutIfNeeded()
        var result: [UInt8] = []
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        for _ in 0..<30 {
            if panel.cachedThumbnailCount > 0,
               let tip = PhotoWorkspaceChecks.views(panel).first(where: { $0.accessibilityIdentifier == "photo.layer.tip.\(changed.id)" }) as? UIImageView,
               let cg = tip.image?.cgImage {
                try check(cg.width <= 40 && cg.height <= 40, "Thumbnail does not allocate source-resolution pixels")
                result = [UInt8](repeating: 0, count: 4)
                context.render(CIImage(cgImage: cg), toBitmap: &result, rowBytes: 4,
                               bounds: CGRect(x: 16, y: 16, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
                break
            }
            await PhotoWorkspaceChecks.pause()
        }
        try check(result.count == 4 && result[0] < 5 && result[2] > 250 && result[3] == 255,
                  "Row displays actual current blue layer pixels, never a stale red thumbnail")
        try check(panel.cachedThumbnailCount <= 64, "Thumbnail cache remains bounded after replacement")
    }
}
