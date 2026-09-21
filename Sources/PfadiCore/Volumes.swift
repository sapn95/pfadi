import Foundation

/// What is mounted, and which of it can be put down again.
///
/// A share is two clicks away in the sidebar and there was no way back out of
/// one: no Eject anywhere in the application, so the only ways to let go of a
/// filer were Finder and `umount`.
public enum Volumes {
    /// The volume something is on, or nil when it cannot be asked.
    ///
    /// Through the resource key rather than by matching the mount table, so a
    /// share mounted at `/Volumes/share` gives itself and not `/` for the file
    /// inside it.
    public static func containing(_ url: URL) -> URL? {
        (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    /// What the volume is called, for saying which one is going.
    ///
    /// The name the volume gives, not the folder it is mounted at: they usually
    /// agree, and where they do not the name is the one somebody recognises.
    public static func name(of volume: URL) -> String {
        let named = (try? volume.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        guard let named, !named.isEmpty else { return volume.lastPathComponent }
        return named
    }

    /// The facts that decide whether a volume can be ejected.
    ///
    /// Apart from the asking, so the rule can be checked without a filer, a USB
    /// stick and a disk image to hand.
    public struct Traits: Equatable, Sendable {
        public let isRootFileSystem: Bool
        public let isLocal: Bool
        public let isEjectable: Bool
        public let isRemovable: Bool

        public init(
            isRootFileSystem: Bool,
            isLocal: Bool,
            isEjectable: Bool,
            isRemovable: Bool
        ) {
            self.isRootFileSystem = isRootFileSystem
            self.isLocal = isLocal
            self.isEjectable = isEjectable
            self.isRemovable = isRemovable
        }
    }

    public static func traits(of volume: URL) -> Traits? {
        let keys: Set<URLResourceKey> = [
            .volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeIsEjectableKey,
            .volumeIsRemovableKey,
        ]
        guard let values = try? volume.resourceValues(forKeys: keys) else { return nil }
        return Traits(
            isRootFileSystem: values.volumeIsRootFileSystem ?? false,
            isLocal: values.volumeIsLocal ?? true,
            isEjectable: values.volumeIsEjectable ?? false,
            isRemovable: values.volumeIsRemovable ?? false
        )
    }

    /// Whether a volume with these traits can be sent away.
    ///
    /// The share is the case that matters and it says none of the obvious
    /// things: an SMB mount reports ejectable false and removable false, and the
    /// one thing that marks it out is that it is not local. A disk image and a
    /// USB stick do say so themselves. The boot volume says nothing useful at
    /// all, so it is excluded for being what it is.
    public static func canEject(_ traits: Traits) -> Bool {
        guard !traits.isRootFileSystem else { return false }
        return !traits.isLocal || traits.isEjectable || traits.isRemovable
    }

    public static func canEject(_ volume: URL) -> Bool {
        traits(of: volume).map(canEject) ?? false
    }

    /// Whether nothing on this volume can be changed.
    ///
    /// The other half of the question a share raised. A mounted disk image and a
    /// share mounted for reading answer this before anything is attempted, the
    /// same way the missing trash does, so New Folder, Rename and the rest can
    /// be off rather than offered and then refused.
    ///
    /// False when it cannot be asked: a volume that will not say is treated as
    /// writable and the attempt gives the real answer, which is better than
    /// greying out a command on a guess.
    public static func isReadOnly(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    /// Whether this URL is a volume's own root rather than something on it.
    ///
    /// A sidebar row for `/Volumes/share` may be ejected; a row for a favourite
    /// folder that happens to live on that share may not, because ejecting the
    /// filer is not what "remove this folder" means anywhere else.
    public static func isVolumeRoot(_ url: URL) -> Bool {
        guard let volume = containing(url) else { return false }
        return volume.standardizedFileURL.path == url.standardizedFileURL.path
    }
}
