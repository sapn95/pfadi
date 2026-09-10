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

    /// Everything across the band that is not the text: the two margins, the
    /// icon and the dismiss button with the gaps around them.
    ///
    /// Named once and used both in the constraints below and in `layout()`,
    /// because the two have to agree. Read off the wrong number and the wrapping
    /// width is wrong by exactly that much, which shows up as a band one line
    /// taller than the text needs.
    private static let leadingInset: CGFloat = 8
    private static let iconWidth: CGFloat = 14
    private static let iconGap: CGFloat = 6
    private static let dismissGap: CGFloat = 6
    private static let dismissWidth: CGFloat = 16
    private static let trailingInset: CGFloat = 6
    private var chromeWidth: CGFloat {
        Self.leadingInset + Self.iconWidth + Self.iconGap
            + Self.dismissGap + Self.dismissWidth + Self.trailingInset
            // The gap before the button is there either way; the button itself
            // is squeezed to nothing when there is nothing on offer.
            + Self.dismissGap + (offer.isHidden ? 0 : offer.fittingSize.width)
    }

    /// What it currently says, for the checks. Empty when it is not showing.
    var message: String { isHidden ? "" : label.stringValue }

    /// What the band is offering to do about it, for the checks. Empty when it
    /// is offering nothing.
    var offerTitle: String { offer.isHidden ? "" : offer.title }

    /// Runs the offer the way clicking the button does, for the checks.
    @discardableResult
    func takeOffer() -> Bool {
        guard !offer.isHidden, !isHidden else { return false }
        offerClicked()
        return true
    }

    private let offer = NSButton()
    private var onOffer: (() -> Void)?

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

        // A band that says something cannot be done and offers the thing that
        // can. Hidden unless there is one, so an ordinary warning is still a
        // sentence and an X.
        offer.translatesAutoresizingMaskIntoConstraints = false
        offer.bezelStyle = .rounded
        offer.controlSize = .small
        offer.font = .systemFont(ofSize: 11)
        offer.target = self
        offer.action = #selector(offerClicked)
        offer.isHidden = true
        offer.setContentHuggingPriority(.required, for: .horizontal)
        offer.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(icon)
        addSubview(label)
        addSubview(offer)
        addSubview(dismiss)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconWidth),
            icon.heightAnchor.constraint(equalToConstant: Self.iconWidth),

            offer.trailingAnchor.constraint(
                equalTo: dismiss.leadingAnchor, constant: -Self.dismissGap),
            offer.centerYAnchor.constraint(equalTo: centerYAnchor),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.iconGap),
            label.trailingAnchor.constraint(
                equalTo: offer.leadingAnchor, constant: -Self.dismissGap),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),

            dismiss.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.trailingInset),
            dismiss.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: Self.dismissWidth),
        ])

        // Hidden is not the same as gone: a hidden button still has its own
        // width and would take a bite out of the text for the whole time it is
        // offering nothing.
        offerWidth.isActive = true
    }

    /// Zero while there is nothing on offer, off entirely when there is.
    private lazy var offerWidth = offer.widthAnchor.constraint(equalToConstant: 0)

    /// How wide the text is allowed to be, from the band's own width.
    ///
    /// Zero while the band has no width yet, which is a request to leave the
    /// wrapping width alone rather than to wrap at nothing.
    private var textWidth: CGFloat { bounds.width - chromeWidth }

    /// Keeps the wrapping width in step with the window.
    ///
    /// Without this the band rewraps only when the text changes, so widening
    /// the window left a three-line message wrapped for the old width.
    override func layout() {
        super.layout()
        let available = textWidth
        guard available > 0, abs(label.preferredMaxLayoutWidth - available) > 0.5 else { return }
        label.preferredMaxLayoutWidth = available
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("pfadi builds its views in code")
    }

    /// - Parameter offering: a title and what it does, when there is something
    ///   to be done about what the band is reporting. The button sits in the
    ///   band beside the text, which is where somebody is already looking, and
    ///   not in a sheet that has to be dismissed before the message can be read
    ///   again.
    func show(
        _ text: String,
        kind: Kind,
        offering: (title: String, run: () -> Void)? = nil
    ) {
        onOffer = offering?.run
        offer.title = offering?.title ?? ""
        offer.isHidden = offering == nil
        offerWidth.isActive = offering == nil

        // Before the text, not after it. A wrapping label with no wrapping width
        // reports an intrinsic width of the whole message on one line, and a
        // window is not allowed to be smaller than what its content asks for: a
        // refusal naming four files and their reasons asked for 3900 points and
        // the window went and became that wide, ending up a strip across the
        // screen. Setting the width first means the size it asks for is a block
        // of three lines that fits where the band already is.
        //
        // The band is pinned to both edges of the view, so it has a sensible
        // width even while it is hidden and has never been shown.
        let available = textWidth
        if available > 0 { label.preferredMaxLayoutWidth = available }
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
        // The offer goes with the message it belonged to. Left behind, the next
        // warning arrives with a button from the last one still on it, pointing
        // at files that have already been dealt with.
        onOffer = nil
        offer.title = ""
        offer.isHidden = true
        offerWidth.isActive = true
        onVisibilityChanged?()
    }

    @objc private func dismissClicked() {
        hide()
    }

    @objc private func offerClicked() {
        // Taken before it runs, and the band closed first: what it does reports
        // its own outcome, and that report is the next thing to appear here.
        let run = onOffer
        hide()
        run?()
    }
}
