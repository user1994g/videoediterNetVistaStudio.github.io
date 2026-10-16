import UIKit

/// Exercises the reusable native browser with a full 1,024-tip pack, including
/// the final tip, while checking visible-cell allocation and thumbnail bounds.
@MainActor enum PhotoBrushLibraryChecks {
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw PhotoBrushError.invalid("Brush browser check: " + message) }
    }
    private static func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }
    static func run(in host: UIView) async throws {
        let browser = PhotoBrushLibraryView(frame: CGRect(x: 8, y: 8, width: 280, height: 320))
        host.addSubview(browser); defer { browser.removeFromSuperview() }
        let tips = (0..<1024).map { PhotoBrush(name: "Studio brush \($0)", kind: "round", hardness: Double($0 % 5) / 4,
                                              diameter: Double(20 + $0 % 80)) }
        browser.setBrushes(tips, selectedIndex: 1); browser.setNeedsLayout(); browser.layoutIfNeeded(); await settle()
        guard let collection = browser.subviews.compactMap({ $0 as? UICollectionView }).first,
              let search = browser.subviews.compactMap({ $0 as? UISearchBar }).first else {
            throw PhotoBrushError.invalid("Missing native brush collection/search controls")
        }
        try check(collection.numberOfItems(inSection: 0) == 1024, "Every imported tip is available")
        try check(!collection.visibleCells.isEmpty && collection.visibleCells.count <= 12, "Only viewport cells are allocated")
        try check(browser.renderedTipCount > 0 && browser.renderedTipCount <= 12, "Thumbnails are generated lazily for visible cells")
        let first = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.frame
        let second = collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))!.frame
        let third = collection.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))!.frame
        try check(first.minY == second.minY && second.minX > first.minX && third.minY > first.minY, "Library uses two native columns")

        var selected: Int?
        browser.onSelect = { selected = $0 }
        search.text = "Studio brush 1023"; browser.searchBar(search, textDidChange: search.text!)
        browser.layoutIfNeeded(); await settle()
        try check(collection.numberOfItems(inSection: 0) == 1 && browser.filteredIndices == [1023], "Search finds the last imported tip")
        browser.collectionView(collection, didSelectItemAt: IndexPath(item: 0, section: 0))
        try check(selected == 1023 && browser.selectedIndex == 1023, "Selecting a search result preserves its original pack index")
        guard let lastCell = collection.visibleCells.first else { throw PhotoBrushError.invalid("Last brush cell did not appear") }
        try check(lastCell.accessibilityIdentifier == "photo.brush.1023" && lastCell.accessibilityTraits.contains(.selected), "Selected tip is visible and accessible")
        let tipImages = lastCell.contentView.subviews.compactMap { ($0 as? UIImageView)?.image?.cgImage }
        try check(tipImages.count == 1 && tipImages.allSatisfy { $0.width <= 48 && $0.height <= 48 }, "Imported tips use bounded 48px thumbnails")

        search.text = ""; browser.searchBar(search, textDidChange: ""); browser.layoutIfNeeded()
        collection.setContentOffset(CGPoint(x: 0, y: 960), animated: false); collection.layoutIfNeeded(); await settle()
        let scroll = collection.contentOffset
        browser.removeFromSuperview(); host.addSubview(browser); browser.setSelectedIndex(1023); browser.layoutIfNeeded()
        try check(collection.contentOffset == scroll && search.text == "", "Inspector rebuilds preserve library scroll/search state")
        for row in 0..<24 {
            collection.setContentOffset(CGPoint(x: 0, y: row * 188), animated: false); collection.layoutIfNeeded(); await settle()
            try check(browser.cachedTipCount <= 64 && collection.visibleCells.count <= 12, "Scrolling keeps cache and native cells bounded")
        }

        // A replacement library may arrive while an old thumbnail is running.
        // Old results must never update the new cell or populate its tip cache.
        browser.setBrushes([PhotoBrush(name: "Obsolete round", kind: "round", hardness: 1)], selectedIndex: 0)
        collection.setContentOffset(.zero, animated: false); browser.layoutIfNeeded()
        let nativeTip = PhotoBrush(name: "Replacement", kind: "sample", hardness: 0.7, width: 8, height: 8,
            samples: Data(repeating: 255, count: 64), spacing: 0.25, angle: 23, roundness: 0.7, diameter: 73)
        let encodedTip = try JSONEncoder().encode(nativeTip)
        let reopenedTip = try JSONDecoder().decode(PhotoBrush.self, from: encodedTip)
        try check(reopenedTip.isValid && reopenedTip.samples == nativeTip.samples && reopenedTip.hardness == 0.7 &&
                  reopenedTip.spacing == 0.25 && reopenedTip.angle == 23 && reopenedTip.roundness == 0.7 && reopenedTip.diameter == 73,
                  "Desktop .netvistabrush JSON keeps sampled pixels and ordinary brush settings")
        browser.setBrushes([reopenedTip], selectedIndex: 0)
        collection.setContentOffset(.zero, animated: false); browser.layoutIfNeeded(); await settle()
        try check(browser.brushCount == 1 && collection.numberOfItems(inSection: 0) == 1 && browser.cachedTipCount <= 1,
                  "Library replacement drops old cached thumbnails")
        try check(collection.visibleCells.first?.accessibilityLabel == "Replacement", "Reused cells show current library metadata")
        let replacementTips = collection.visibleCells.first?.contentView.subviews.compactMap { ($0 as? UIImageView)?.image?.cgImage } ?? []
        try check(replacementTips.count == 1 && replacementTips[0].width == 8 && replacementTips[0].height == 8,
                  "An obsolete 48px round thumbnail cannot overwrite the replacement 8px sampled tip")
    }
}
