import AppKit

/// A strip across the top of the list that says something went wrong.
///
/// The status line at the bottom is eleven points of secondary grey, and it is
/// where everything routine belongs: how many items, how many match the filter.
/// It is the wrong place for "that did not happen". Refusing to trash a folder
/// and then reporting it down there reads, from where anybody is actually
/// looking, as nothing happening at all.
///
/// So a refusal or a failure gets a band you cannot miss, and it stays until it
/// is dismissed or until you go somewhere else. Anything merely informative
/// keeps the status line and does not interrupt.
final class NoticeBanner: NSView {
    enum Kind {
        case warning
        case failure

        var symbol: String {
            switch self {
            case .warning: return "exclamationmark.triangle.fill"
            case .failure: return "xmark.octagon.fill"
            }
        }

        var tint: NSColor {
            switch self {
            case .warning: return .systemOrange
            case .failure: return .systemRed
            }
        }
    }

    /// Told when the band is shown or hidden, so the layout can make room.
    var onVisibilityChanged: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let dismiss = NSButton()

    /// What it currently says, for the checks. Empty when it is not showing.
    var message: String { isHidden ? "" : label.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 6
        isHidden = true

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        // Wrapped rather than truncated: a refusal that says which folder and
        // why is worth two lines, and the middle of it is not optional.
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dismiss.translatesAutoresizingMaskIntoConstraints = false
        dismiss.bezelStyle = .inline
        dismiss.isBordered = false
        dismiss.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "Dismiss this message")
        dismiss.target = self
        dismiss.action = #selector(dismissClicked)
        dismiss.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(icon)
        addSubview(label)
        addSubview(dismiss)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),

            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dismiss.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("pfadi builds its views in code")
    }

    func show(_ text: String, kind: Kind) {
        label.stringValue = text
        label.textColor = .labelColor
        icon.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
        icon.contentTintColor = kind.tint
        layer?.backgroundColor = kind.tint.withAlphaComponent(0.14).cgColor

        guard isHidden else {
            needsLayout = true
            return
        }
        isHidden = false
        onVisibilityChanged?()
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        label.stringValue = ""
        onVisibilityChanged?()
    }

    @objc private func dismissClicked() {
        hide()
    }
}
