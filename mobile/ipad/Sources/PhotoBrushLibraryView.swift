import UIKit

/// The full library remains searchable, but only visible cells and one thumbnail
/// job are materialized. Retain this view across inspector rebuilds to preserve
/// search and scroll position while changing brush properties.
@MainActor
final class PhotoBrushLibraryView: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UISearchBarDelegate {
    var onSelect: ((Int) -> Void)?
    private(set) var brushes: [PhotoBrush] = []
    private(set) var selectedIndex = 0
    private(set) var filteredIndices: [Int] = []
    var brushCount: Int { brushes.count }
    var cachedTipCount: Int { tipCache.count }
    private(set) var renderedTipCount = 0
    private let search = UISearchBar()
    private let summary = MobileTheme.label("", size: 11)
    private let collection: UICollectionView
    private let flowLayout: UICollectionViewFlowLayout
    private let tipQueue = DispatchQueue(label: "com.netvistastudio.photo.brush-thumbnails", qos: .userInitiated)
    private var libraryGeneration = 0, displayGeneration = 0, rendering = false
    private var tipCache: [Int: UIImage] = [:], cacheOrder: [Int] = []
    private var failedTips = Set<Int>()
    private let maximumCachedTips = 64

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout(); flowLayout = layout
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        backgroundColor = MobileTheme.panel; layer.cornerRadius = 6; clipsToBounds = true
        search.placeholder = "Search brushes"; search.searchBarStyle = .minimal; search.delegate = self
        search.accessibilityIdentifier = "photo.brush.search"
        search.searchTextField.font = .systemFont(ofSize: 12)
        search.searchTextField.textColor = .white
        summary.textColor = MobileTheme.secondary; summary.accessibilityIdentifier = "photo.brush.summary"
        collection.backgroundColor = MobileTheme.panel; collection.dataSource = self; collection.delegate = self
        collection.alwaysBounceVertical = true; collection.keyboardDismissMode = .onDrag
        collection.accessibilityIdentifier = "photo.brush.library"
        collection.register(PhotoBrushLibraryCell.self, forCellWithReuseIdentifier: "tip")
        flowLayout.minimumInteritemSpacing = 8; flowLayout.minimumLineSpacing = 8
        flowLayout.sectionInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        addSubview(search); addSubview(summary); addSubview(collection)
        heightAnchor.constraint(equalToConstant: 320).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 320) }
    override func layoutSubviews() {
        super.layoutSubviews()
        search.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 48)
        summary.frame = CGRect(x: 8, y: 48, width: max(1, bounds.width - 16), height: 26)
        collection.frame = CGRect(x: 0, y: 78, width: bounds.width, height: max(1, bounds.height - 78))
        let itemSize = CGSize(width: max(44, floor((bounds.width - 16) / 2)), height: 88)
        if flowLayout.itemSize != itemSize { flowLayout.itemSize = itemSize; flowLayout.invalidateLayout() }
        collection.layoutIfNeeded()
        requestVisibleTip()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { requestVisibleTip() } }

    func setBrushes(_ brushes: [PhotoBrush], selectedIndex: Int) {
        libraryGeneration += 1; displayGeneration += 1
        self.brushes = brushes
        self.selectedIndex = max(0, min(max(0, brushes.count - 1), selectedIndex))
        tipCache.removeAll(); cacheOrder.removeAll(); failedTips.removeAll(); renderedTipCount = 0
        rebuildFilter(resetScroll: false)
    }
    func setSelectedIndex(_ index: Int) {
        guard brushes.indices.contains(index) else { return }
        selectedIndex = index; updateSummary()
        for case let cell as PhotoBrushLibraryCell in collection.visibleCells {
            cell.updateSelection(cell.representedIndex == selectedIndex)
        }
    }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { rebuildFilter(resetScroll: true) }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    private func rebuildFilter(resetScroll: Bool) {
        displayGeneration += 1
        let query = (search.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        filteredIndices = brushes.indices.filter { query.isEmpty || brushes[$0].name.localizedCaseInsensitiveContains(query) || brushes[$0].kind.localizedCaseInsensitiveContains(query) }
        updateSummary(); collection.reloadData()
        if resetScroll { collection.setContentOffset(.zero, animated: false) }
        setNeedsLayout()
    }
    private func updateSummary() {
        let active = brushes.indices.contains(selectedIndex) ? " · \(brushes[selectedIndex].name)" : ""
        summary.text = "\(filteredIndices.count) of \(brushes.count) tips\(active)"
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { filteredIndices.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "tip", for: indexPath) as! PhotoBrushLibraryCell
        let index = filteredIndices[indexPath.item]
        cell.configure(brushes[index], index: index, generation: displayGeneration, selected: index == selectedIndex, tip: cachedTip(index))
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) { requestVisibleTip() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { requestVisibleTip() }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard filteredIndices.indices.contains(indexPath.item) else { return }
        let index = filteredIndices[indexPath.item]; setSelectedIndex(index); onSelect?(index)
    }
    private func cachedTip(_ index: Int) -> UIImage? {
        guard let tip = tipCache[index] else { return nil }
        cacheOrder.removeAll { $0 == index }; cacheOrder.append(index); return tip
    }
    private func storeTip(_ image: UIImage, at index: Int) {
        tipCache[index] = image; cacheOrder.removeAll { $0 == index }; cacheOrder.append(index)
        while cacheOrder.count > maximumCachedTips { tipCache.removeValue(forKey: cacheOrder.removeFirst()) }
    }
    private func requestVisibleTip() {
        guard !rendering, window != nil, !isHidden else { return }
        let visible = collection.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        guard let path = visible.first(where: { path in
            guard filteredIndices.indices.contains(path.item) else { return false }
            let index = filteredIndices[path.item]
            return tipCache[index] == nil && !failedTips.contains(index)
        }) else { return }
        let index = filteredIndices[path.item], brush = brushes[index], ticket = libraryGeneration
        rendering = true
        // No per-cell queued tasks. After this task completes, ask for the next
        // currently visible missing tip, skipping cells scrolled out meanwhile.
        tipQueue.async { [weak self] in
            let tip = brush.tip(color: .white, hardness: brush.hardness, maxDimension: 48)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.rendering = false
                if self.libraryGeneration == ticket {
                    self.renderedTipCount += 1
                    if let tip {
                        let image = UIImage(cgImage: tip); self.storeTip(image, at: index)
                        for case let cell as PhotoBrushLibraryCell in self.collection.visibleCells
                        where cell.representedIndex == index && cell.displayGeneration == self.displayGeneration { cell.setTip(image) }
                    } else { self.failedTips.insert(index) }
                }
                self.requestVisibleTip()
            }
        }
    }
}

@MainActor private final class PhotoBrushLibraryCell: UICollectionViewCell {
    private let tip = UIImageView(), name = MobileTheme.label("", size: 11)
    private(set) var representedIndex = -1, displayGeneration = -1
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = MobileTheme.control; contentView.layer.cornerRadius = 5
        contentView.layer.borderWidth = 1
        tip.contentMode = .scaleAspectFit; tip.tintColor = MobileTheme.secondary
        name.numberOfLines = 2; name.textAlignment = .center
        contentView.addSubview(tip); contentView.addSubview(name)
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func prepareForReuse() {
        super.prepareForReuse(); representedIndex = -1; displayGeneration = -1; tip.image = nil; name.text = nil
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        tip.frame = CGRect(x: (bounds.width - 48) / 2, y: 4, width: 48, height: 48)
        name.frame = CGRect(x: 4, y: 52, width: max(1, bounds.width - 8), height: 32)
    }
    func configure(_ brush: PhotoBrush, index: Int, generation: Int, selected: Bool, tip: UIImage?) {
        representedIndex = index; displayGeneration = generation; name.text = brush.name
        self.tip.image = tip ?? UIImage(systemName: "paintbrush.pointed")
        accessibilityLabel = brush.name; accessibilityIdentifier = "photo.brush.\(index)"; updateSelection(selected)
    }
    func updateSelection(_ selected: Bool) {
        contentView.layer.borderColor = (selected ? MobileTheme.accent : MobileTheme.line).cgColor
        accessibilityTraits = selected ? [.button, .selected] : [.button]
    }
    func setTip(_ image: UIImage) { tip.image = image }
}
