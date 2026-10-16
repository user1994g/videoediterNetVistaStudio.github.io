import UIKit

@MainActor final class StudioWorkspaceCard: UIView {
    var onOpen: (() -> Void)?
    private let artwork = UIImageView(), titleLabel: UILabel, detailLabel: UILabel
    let button: UIButton
    init(title: String, detail: String, artworkName: String, symbol: String, identifier: String) {
        titleLabel = MobileTheme.label(title, size: 22, weight: .semibold)
        detailLabel = MobileTheme.label(detail, size: 12)
        button = MobileTheme.button("Open editor", symbol: symbol, action: {})
        super.init(frame: .zero)
        backgroundColor = MobileTheme.panel; layer.cornerRadius = 7; clipsToBounds = true
        artwork.image = UIImage(named: artworkName); artwork.contentMode = .scaleAspectFill; artwork.clipsToBounds = true
        detailLabel.textColor = MobileTheme.secondary; detailLabel.numberOfLines = 2
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
        for item in [artwork, titleLabel, detailLabel, button] { addSubview(item) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layoutSubviews() {
        super.layoutSubviews(); let imageHeight = max(0, bounds.height - 138), width = bounds.width
        artwork.frame = CGRect(x: 0, y: 0, width: width, height: imageHeight)
        titleLabel.frame = CGRect(x: 18, y: imageHeight + 14, width: width - 36, height: 30)
        detailLabel.frame = CGRect(x: 18, y: imageHeight + 46, width: width - 36, height: 34)
        button.frame = CGRect(x: 18, y: imageHeight + 84, width: 140, height: 44)
    }
}
