import AppKit
import PfadiCore

/// Letting go of a volume: a share, a USB stick, a disk image.
///
/// The counterpart to the connect sheet, which had none. Mounting a filer was a
/// click and unmounting it was a trip to Finder.
enum Eject {
    /// Sends the volume away. Nil when it went, the reason when it did not.
    ///
    /// `unmountAndEjectDevice` rather than `unmount(2)`, because it goes through
    /// disk arbitration: an application holding a file open on the volume gets
    /// asked, and the answer comes back as an error rather than as a kernel
    /// refusal nobody can act on.
    static func send(_ volume: URL) -> String? {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            return nil
        } catch {
            // Without the leading volume name, which the sentence saying what
            // could not be ejected has already given.
            return FileOperations.withoutLeadingName(error.localizedDescription)
        }
    }

    /// What the menu item says, so the volume going away is named in it.
    ///
    /// Finder's wording. "Eject" on its own in a list of volumes is a question
    /// about which one.
    static func title(for volume: URL) -> String {
        "Eject \u{201C}\(Volumes.name(of: volume))\u{201D}"
    }
}
