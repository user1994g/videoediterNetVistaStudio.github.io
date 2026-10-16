import UIKit
import CoreImage

/// A virtualized layer list: navigation never opens a modal, folders can be
/// folded independently of the document, and only visible image tips render.
@MainActor
final class PhotoLayerPanelView: UIView, UITableViewDataSource, UITableViewDelegate {
    var onSelect: ((UUID) -> Void)?
    var onVisibility: ((UUID) -> Void)?
    var onActions: ((UUID) -> Void)?
    private(set) var visibleLayers: [PhotoLayerSnapshot] = []
    private(set) var renderedThumbnailCount = 0
    var cachedThumbnailCount: Int { thumbnails.count }
    private let table = UITableView(frame: .zero, style: .plain)
    private var layers: [PhotoLayerSnapshot] = [], selectedID: UUID?
    private var collapsed = Set<UUID>(), byID: [UUID: PhotoLayerSnapshot] = [:]
    private var thumbnails: [UUID: UIImage] = [:], cacheOrder: [UUID] = [], failed = Set<UUID>()
    private var revision: UInt64?, generation = 0, rendering = false
    private let queue = DispatchQueue(label: "com.netvistastudio.photo.layer-thumbnails", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    override init(frame: CGRect) {
        super.init(frame: frame)
        table.backgroundColor = MobileTheme.panel; table.separatorColor = MobileTheme.line
        table.dataSource = self; table.delegate = self; table.rowHeight = 64
        table.accessibilityIdentifier = "photo.layers.list"
        table.register(PhotoLayerCell.self, forCellReuseIdentifier: "layer")
        addSubview(table)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layoutSubviews() { super.layoutSubviews(); table.frame = bounds; table.layoutIfNeeded(); requestVisibleThumbnail() }
    override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { requestVisibleThumbnail() } }
    func setLayers(_ layers: [PhotoLayerSnapshot], selectedID: UUID?, revision: UInt64) {
        if self.revision != revision {
            generation += 1; thumbnails.removeAll(); cacheOrder.removeAll(); failed.removeAll()
        }
        self.revision = revision; self.layers = layers; self.selectedID = selectedID
        byID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        collapsed.formIntersection(Set(layers.filter { $0.extras.isGroup }.map(\.id)))
        rebuild()
    }
    private func ancestors(_ layer: PhotoLayerSnapshot) -> [UUID] {
        var result: [UUID] = [], parent = layer.extras.groupID
        while let id = parent, !result.contains(id), let folder = byID[id], result.count < layers.count {
            result.append(id); parent = folder.extras.groupID
        }
        return result
    }
    private func rebuild() {
        visibleLayers = layers.filter { !ancestors($0).contains(where: { collapsed.contains($0) }) }
        table.reloadData(); setNeedsLayout()
    }
    func toggleFolder(_ id: UUID) {
        guard byID[id]?.extras.isGroup == true else { return }
        if !collapsed.insert(id).inserted { collapsed.remove(id) }
        rebuild()
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visibleLayers.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "layer", for: indexPath) as! PhotoLayerCell
        let snapshot = visibleLayers[indexPath.row]
        cell.configure(snapshot, selected: snapshot.id == selectedID, depth: ancestors(snapshot).count,
                       collapsed: collapsed.contains(snapshot.id), tip: cached(snapshot.id))
        cell.onEye = { [weak self] in self?.onVisibility?(snapshot.id) }
        cell.onActions = { [weak self] in self?.onActions?(snapshot.id) }
        cell.onFolder = { [weak self] in self?.toggleFolder(snapshot.id) }
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard visibleLayers.indices.contains(indexPath.row) else { return }
        onSelect?(visibleLayers[indexPath.row].id)
    }
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) { requestVisibleThumbnail() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { requestVisibleThumbnail() }
    private func cached(_ id: UUID) -> UIImage? {
        guard let result = thumbnails[id] else { return nil }
        cacheOrder.removeAll { $0 == id }; cacheOrder.append(id); return result
    }
    private func requestVisibleThumbnail() {
        guard !rendering, window != nil, !isHidden else { return }
        let paths = (table.indexPathsForVisibleRows ?? []).sorted { $0.row < $1.row }
        guard let path = paths.first(where: { path in
            guard visibleLayers.indices.contains(path.row) else { return false }
            let layer = visibleLayers[path.row]
            return !layer.extras.isGroup && !layer.extras.isAdjustment && thumbnails[layer.id] == nil && !failed.contains(layer.id)
        }) else { return }
        let layer = visibleLayers[path.row], id = layer.id, ticket = generation, context = context
        rendering = true
        queue.async { [weak self] in
            // Preserve colour, flips and mask preview, but exclude document
            // placement/opacity so a hidden or transparent layer stays readable.
            var extra = layer.extras; extra.groupID = nil; extra.skew = 0
            let snapshot = PhotoLayerSnapshot(id: id, name: layer.name, sourceURL: nil,
                sourceImage: layer.sourceImage, thumbnail: nil, isVisible: true, isLocked: false,
                opacity: 1, blendMode: .normal, position: .zero, scale: 1, rotation: 0,
                adjustments: layer.adjustments, extras: extra, maskPreview: layer.maskPreview)
            let image = PhotoRenderEngine.composite([snapshot], documentSize: layer.sourceImage.extent.size,
                maxSide: 40, bypassAdjustments: false, opaqueBackground: false)
            let cg = image.flatMap { context.createCGImage($0, from: $0.extent) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.rendering = false
                if self.generation == ticket {
                    self.renderedThumbnailCount += 1
                    if let cg {
                        let image = UIImage(cgImage: cg); self.thumbnails[id] = image
                        self.cacheOrder.removeAll { $0 == id }; self.cacheOrder.append(id)
                        while self.cacheOrder.count > 64 { self.thumbnails.removeValue(forKey: self.cacheOrder.removeFirst()) }
                        for case let cell as PhotoLayerCell in self.table.visibleCells where cell.representedID == id { cell.setTip(image) }
                    } else { self.failed.insert(id) }
                }
                self.requestVisibleThumbnail()
            }
        }
    }
}

@MainActor private final class PhotoLayerCell: UITableViewCell {
    var onEye: (() -> Void)?, onActions: (() -> Void)?, onFolder: (() -> Void)?
    private(set) var representedID: UUID?
    private let tip = UIImageView(), name = MobileTheme.label("", size: 12, weight: .medium)
    private let detail = MobileTheme.label("", size: 10), eye = UIButton(type: .system)
    private let more = UIButton(type: .system), folder = UIButton(type: .system)
    private var depth = 0, isFolder = false
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none; tip.contentMode = .scaleAspectFit; tip.backgroundColor = MobileTheme.control
        tip.layer.cornerRadius = 3; tip.clipsToBounds = true
        detail.textColor = MobileTheme.secondary
        for item in [tip, name, detail, eye, more, folder] { contentView.addSubview(item) }
        eye.addAction(UIAction { [weak self] _ in self?.onEye?() }, for: .touchUpInside)
        more.addAction(UIAction { [weak self] _ in self?.onActions?() }, for: .touchUpInside)
        folder.addAction(UIAction { [weak self] _ in self?.onFolder?() }, for: .touchUpInside)
        more.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        for button in [eye, more, folder] { button.tintColor = MobileTheme.secondary }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func prepareForReuse() { super.prepareForReuse(); representedID = nil; onEye = nil; onActions = nil; onFolder = nil; tip.image = nil }
    func configure(_ layer: PhotoLayerSnapshot, selected: Bool, depth: Int, collapsed: Bool, tip: UIImage?) {
        representedID = layer.id; self.depth = min(2, depth); isFolder = layer.extras.isGroup
        backgroundColor = selected ? MobileTheme.control : MobileTheme.panel
        name.text = layer.name; name.textColor = layer.isVisible ? .white : MobileTheme.secondary
        detail.text = "\(layer.blendMode.rawValue) · \(Int(layer.opacity * 100))%\(layer.isLocked ? " · Locked" : "")\(layer.extras.maskPNG == nil ? "" : " · Mask")"
        self.tip.image = tip ?? UIImage(systemName: isFolder ? "folder" : layer.extras.isAdjustment ? "slider.horizontal.3" : "photo")
        self.tip.tintColor = MobileTheme.secondary; self.tip.accessibilityIdentifier = "photo.layer.tip.\(layer.id)"
        eye.setImage(UIImage(systemName: layer.isVisible ? "eye" : "eye.slash"), for: .normal)
        eye.accessibilityIdentifier = "photo.layer.eye.\(layer.id)"; eye.accessibilityLabel = layer.isVisible ? "Hide \(layer.name)" : "Show \(layer.name)"
        more.accessibilityIdentifier = "photo.layer.actions.\(layer.id)"; more.accessibilityLabel = "Actions for \(layer.name)"
        folder.isHidden = !isFolder; folder.setImage(UIImage(systemName: collapsed ? "chevron.right" : "chevron.down"), for: .normal)
        folder.accessibilityIdentifier = "photo.layer.folder.\(layer.id)"; folder.accessibilityLabel = collapsed ? "Expand \(layer.name)" : "Collapse \(layer.name)"
        accessibilityIdentifier = "photo.layer.\(layer.id)"; setNeedsLayout()
    }
    func setTip(_ image: UIImage) { tip.image = image }
    override func layoutSubviews() {
        super.layoutSubviews()
        let indent = CGFloat(depth) * 12, w = contentView.bounds.width
        tip.frame = CGRect(x: 8 + indent, y: 12, width: 40, height: 40)
        folder.frame = CGRect(x: 8 + indent, y: 12, width: 40, height: 40)
        if isFolder { tip.isHidden = true } else { tip.isHidden = false }
        eye.frame = CGRect(x: w - 76, y: 10, width: 36, height: 44)
        more.frame = CGRect(x: w - 40, y: 10, width: 36, height: 44)
        name.frame = CGRect(x: tip.frame.maxX + 8, y: 12, width: max(1, eye.frame.minX - tip.frame.maxX - 12), height: 20)
        detail.frame = CGRect(x: name.frame.minX, y: 33, width: name.frame.width, height: 20)
    }
}
