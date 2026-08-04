import AppKit
import PfadiCore

/// The dialogs and the progress bar around a copy or a move.
final class TransferController {
    private var runner: TransferRunner?

    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()
    private lazy var strip: NSStackView = makeStrip()

    var isRunning: Bool { runner != nil }

    /// The row of controls to put in the window while something is running.
    var view: NSView { strip }

    /// Asks about collisions, then runs.
    ///
    /// Every question is asked before any work starts. Being interrupted by a
    /// dialog halfway through a long copy, with no idea what has already
    /// happened, is the thing that makes people distrust a file manager.
    func start(
        _ plan: Transfer.Plan,
        in window: NSWindow?,
        onFinish: @escaping (TransferRunner.Outcome) -> Void
    ) {
        guard !plan.isEmpty else { return }

        resolve(plan.conflicts, in: window) { [weak self] resolutions in
            guard let self, let resolutions else { return }
            run(plan, resolutions: resolutions, onFinish: onFinish)
        }
    }

    private func run(
        _ plan: Transfer.Plan,
        resolutions: [URL: Transfer.Resolution],
        onFinish: @escaping (TransferRunner.Outcome) -> Void
    ) {
        let runner = TransferRunner()
        self.runner = runner

        strip.isHidden = false
        bar.doubleValue = 0
        label.stringValue = "starting…"

        // assumeIsolated rather than another hop: TransferRunner already
        // delivers both of these on the main queue, and dispatching again
        // would put the final state one runloop behind the work.
        let finish = UncheckedBox(onFinish)
        runner.run(plan, resolutions: resolutions) { [weak self] progress in
            MainActor.assumeIsolated {
                self?.bar.doubleValue = progress.fraction * 100
                self?.label.stringValue = progress.currentName
            }
        } completion: { [weak self] outcome in
            MainActor.assumeIsolated {
                self?.strip.isHidden = true
                self?.runner = nil
                finish.value(outcome)
            }
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        // Stops between two files rather than mid-file, so nothing is left
        // half-written. What is already copied stays, and is reported.
        runner?.cancel()
        label.stringValue = "stopping…"
    }

    /// One question per colliding item, or one for all of them.
    private func resolve(
        _ conflicts: [URL],
        in window: NSWindow?,
        then use: @escaping ([URL: Transfer.Resolution]?) -> Void
    ) {
        guard let first = conflicts.first else {
            use([:])
            return
        }

        let alert = NSAlert()
        alert.messageText =
            conflicts.count == 1
            ? "\"\(first.lastPathComponent)\" is already there"
            : "\(conflicts.count) items are already there"
        alert.informativeText =
            "Replacing puts the existing "
            + (conflicts.count == 1 ? "item" : "items")
            + " in the trash first, so nothing is lost outright."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            let resolution: Transfer.Resolution
            switch response {
            case .alertFirstButtonReturn: resolution = .keepBoth
            case .alertSecondButtonReturn: resolution = .replace
            case .alertThirdButtonReturn: resolution = .skip
            default:
                use(nil)
                return
            }
            use(Dictionary(uniqueKeysWithValues: conflicts.map { ($0, resolution) }))
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func makeStrip() -> NSStackView {
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.controlSize = .small

        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle

        cancelButton.title = "Stop"
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))

        let strip = NSStackView(views: [bar, label, cancelButton])
        strip.orientation = .horizontal
        strip.spacing = 8
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.isHidden = true
        bar.widthAnchor.constraint(equalToConstant: 120).isActive = true
        return strip
    }
}

/// Carries a main-thread closure through a Sendable boundary that the compiler
/// cannot see is a main-queue hop.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
