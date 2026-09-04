import AppKit

/// Top bar for the Notes surface: back button + centered title + Note/Transcribe
/// segments. Lives inside `MeetingsContentController` so both the Settings tab
/// and the standalone window get the same chrome. Colors come from
/// `MacSettingsTheme.NS`.
@MainActor
final class NotesTopBar: NSView {
    enum Mode { case list, editor }

    var onBack: (() -> Void)?
    var onSelectTab: ((Int) -> Void)?  // 0 = Note, 1 = Transcribe

    private let backButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let segment = NSSegmentedControl(
        labels: ["Note", "Transcribe"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    /// Left inset so the back button clears window traffic lights when the host
    /// window is full-size-content (Settings). Standalone passes a small inset.
    init(leadingInset: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true

        backButton.isBordered = false
        backButton.bezelStyle = .regularSquare
        backButton.imagePosition = .imageLeading
        backButton.font = .systemFont(ofSize: 13, weight: .semibold)
        backButton.contentTintColor = MacSettingsTheme.NS.text
        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = MacSettingsTheme.NS.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        segment.target = self
        segment.action = #selector(segmentChanged)
        segment.selectedSegment = 0
        segment.translatesAutoresizingMaskIntoConstraints = false

        addSubview(backButton)
        addSubview(titleLabel)
        addSubview(segment)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            segment.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            segment.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: segment.leadingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("NotesTopBar is programmatic only.") }

    func configure(mode: Mode, title: String, currentTab: Int, transcribeEnabled: Bool) {
        switch mode {
        case .list:
            backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
            backButton.title = " Settings"
            titleLabel.stringValue = "Notes"
            titleLabel.isHidden = false
            segment.isHidden = true
        case .editor:
            backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back to list")
            backButton.title = " Back"
            // Title is shown as the note's H1 (meeting name) right below — keep
            // the bar uncluttered: just Back (left) + Note/Transcribe (right).
            titleLabel.stringValue = ""
            titleLabel.isHidden = true
            segment.isHidden = false
            segment.selectedSegment = currentTab
            segment.setEnabled(true, forSegment: 0)
            segment.setEnabled(transcribeEnabled, forSegment: 1)
        }
    }

    @objc private func backTapped() { onBack?() }
    @objc private func segmentChanged() { onSelectTab?(segment.selectedSegment) }
}
