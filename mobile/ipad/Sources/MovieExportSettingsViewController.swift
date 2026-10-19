import UIKit

/// One native settings page before rendering starts. Resolution and frame rate
/// are chosen together, not in a second prompt after the destination picker.
@MainActor
final class MovieExportSettingsViewController: UIViewController {
    let resolutions = UISegmentedControl(items: ["720p", "1080p", "4K"])
    let frameRates = UISegmentedControl(items: ["24", "25", "30", "50", "60"])
    let summary = UILabel()
    let exportButton = UIButton(type: .system)
    let cancelButton = UIButton(type: .system)
    private let scroll = UIScrollView()
    private let content = UIStackView()
    private var completing = false
    var permitsExport: () -> Bool = { false }
    var onExport: ((Int, Int) -> Void)?
    var height: Int { [720, 1080, 2160][max(0, min(2, resolutions.selectedSegmentIndex))] }
    var fps: Int { [24, 25, 30, 50, 60][max(0, min(4, frameRates.selectedSegmentIndex))] }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = MobileTheme.window
        view.accessibilityIdentifier = "movie.export.settings"
        title = "Export movie"
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .vertical; content.spacing = 16
        view.addSubview(scroll); scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        content.addArrangedSubview(text("Export movie", size: 24, weight: .semibold))
        content.addArrangedSubview(text("Choose your delivery settings before rendering. The file is saved to Files when rendering finishes.", size: 14))
        content.addArrangedSubview(text("RESOLUTION", size: 11, weight: .semibold))
        resolutions.selectedSegmentIndex = 1; resolutions.accessibilityIdentifier = "movie.export.resolution"
        resolutions.accessibilityLabel = "Movie resolution"
        content.addArrangedSubview(resolutions)
        content.addArrangedSubview(text("FRAME RATE · FPS", size: 11, weight: .semibold))
        frameRates.selectedSegmentIndex = 2; frameRates.accessibilityIdentifier = "movie.export.fps"
        frameRates.accessibilityLabel = "Movie frames per second"
        content.addArrangedSubview(frameRates)
        summary.numberOfLines = 0; summary.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        summary.textColor = .white; summary.accessibilityIdentifier = "movie.export.summary"
        content.addArrangedSubview(summary)
        content.addArrangedSubview(text("MP4 · H.264/AAC · 16:9\nAll source videos fit the frame without cropping. Motion, opacity, colour and animation use the same saved settings as the monitor.", size: 13))
        content.addArrangedSubview(text("4K and high frame rates need more memory, storage and rendering time. Keep NetVista in the foreground. 8K/16K delivery is not supported by this mobile renderer yet.", size: 12))
        exportButton.setTitle("Render movie", for: .normal); exportButton.accessibilityIdentifier = "movie.export.render"
        exportButton.backgroundColor = MobileTheme.accent; exportButton.tintColor = .white; exportButton.layer.cornerRadius = 8
        cancelButton.setTitle("Cancel", for: .normal); cancelButton.accessibilityIdentifier = "movie.export.cancel"
        cancelButton.backgroundColor = MobileTheme.control; cancelButton.layer.cornerRadius = 8
        content.addArrangedSubview(exportButton); content.addArrangedSubview(cancelButton)
        for control in [resolutions, frameRates, exportButton, cancelButton] {
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        resolutions.addTarget(self, action: #selector(updateSummary), for: .valueChanged)
        frameRates.addTarget(self, action: #selector(updateSummary), for: .valueChanged)
        exportButton.addAction(UIAction { [weak self] _ in self?.render() }, for: .touchUpInside)
        cancelButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        updateSummary()
    }
    private func text(_ value: String, size: CGFloat, weight: UIFont.Weight = .regular) -> UILabel {
        let label = UILabel(); label.text = value; label.numberOfLines = 0
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = size >= 20 ? .white : MobileTheme.secondary
        return label
    }
    @objc func updateSummary() {
        summary.text = "\(height * 16 / 9) × \(height) pixels · \(fps) fps"
        exportButton.isEnabled = !completing && permitsExport()
        exportButton.alpha = exportButton.isEnabled ? 1 : 0.45
    }
    private func render() {
        guard !completing, permitsExport(), view.window != nil else { updateSummary(); return }
        let height = self.height, fps = self.fps, callback = onExport
        completing = true
        exportButton.isEnabled = false
        dismiss(animated: true) { callback?(height, fps) }
    }
}
