import Foundation
import PfadiCore

/// Which volumes can be put down, and what happens where there is no trash.
enum VolumeSuites {
    static func run() {
        ejecting()
        asking()
        trashing()
    }

    private static func traits(
        root: Bool = false,
        local: Bool = true,
        ejectable: Bool = false,
        removable: Bool = false
    ) -> Volumes.Traits {
        Volumes.Traits(
            isRootFileSystem: root, isLocal: local, isEjectable: ejectable,
            isRemovable: removable)
    }

    private static func ejecting() {
        Harness.suite("volumes: a share can be ejected even though it says it cannot") {
            // The whole reason this rule is not one resource key: an SMB mount
            // reports ejectable false and removable false. Not being local is
            // the only thing that gives it away.
            Harness.expect(
                Volumes.canEject(traits(local: false)),
                "a network mount goes, on the strength of being a network mount")
            Harness.expect(
                Volumes.canEject(traits(ejectable: true)), "a disk image says so itself")
            Harness.expect(
                Volumes.canEject(traits(removable: true)), "and so does a USB stick")
        }

        Harness.suite("volumes: the boot disk is not on offer") {
            Harness.expect(
                !Volumes.canEject(traits(root: true)),
                "the volume everything is running from stays")
            Harness.expect(
                !Volumes.canEject(traits(root: true, local: false)),
                "a netbooted one too, root wins over every other trait")
            Harness.expect(
                !Volumes.canEject(traits()),
                "and an ordinary local volume that claims nothing is left alone")
        }
    }

    private static func asking() {
        Harness.suite("volumes: what the filesystem answers") {
            let root = URL(fileURLWithPath: "/")
            Harness.expectEqual(
                Volumes.containing(FileManager.default.homeDirectoryForCurrentUser)?.path,
                "/",
                "home is on the boot volume")
            Harness.expect(Volumes.isVolumeRoot(root), "/ is a volume root")
            Harness.expect(
                !Volumes.isVolumeRoot(FileManager.default.homeDirectoryForCurrentUser),
                "a folder on a volume is not")
            Harness.expect(!Volumes.canEject(root), "and it cannot be ejected")
            Harness.expect(!Volumes.name(of: root).isEmpty, "it has a name to put in a menu")
            Harness.expect(
                Volumes.containing(URL(fileURLWithPath: "/no/such/place")) == nil,
                "somewhere that does not exist is on no volume, rather than on /")
        }
    }

    private static func trashing() {
        Harness.suite("trash: the system is asked before anything is attempted") {
            let file = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pfadi-trash-question.txt")
            try? Data("x".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            Harness.expect(
                FileOperations.hasTrash(for: file),
                "a file on the boot volume has somewhere to go")
            Harness.expect(
                !FileOperations.hasTrash(for: file, fileManager: TrashlessFileManager()),
                "one on a share does not, and says so without trying")
        }

        Harness.suite("trash: undoing a New Folder works where there is no trash") {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pfadi-discard-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let made = root.appendingPathComponent("untitled folder")
            try? FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)

            // The bug: ⌘Z after New Folder on a share reported that the volume
            // has no trash and left the folder sitting there.
            let landed = try? FileOperations.discard(made, fileManager: TrashlessFileManager())
            Harness.expect(landed == nil, "nothing landed in a trash, because there was none")
            Harness.expect(
                !FileManager.default.fileExists(atPath: made.path), "but the folder has gone")
        }

        Harness.suite("trash: a folder macOS keeps is never deleted to honour an undo") {
            // A fake home, so the reserved names are reserved here without
            // touching the real ~/Documents.
            let home = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pfadi-home-\(UUID().uuidString)")
            let documents = home.appendingPathComponent("Documents")
            try? FileManager.default.createDirectory(
                at: documents, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }

            var threw = false
            do {
                _ = try FileOperations.discard(
                    documents, home: home, fileManager: TrashlessFileManager())
            } catch {
                threw = true
            }
            Harness.expect(threw, "it refuses rather than falling back to deleting it")
            Harness.expect(
                FileManager.default.fileExists(atPath: documents.path),
                "and the folder is still there")
        }
    }
}

/// A FileManager with no trash, which is what a share looks like from here.
///
/// Both halves of it: the question `trashLocation` asks and the attempt
/// `trashItem` makes, because the code now depends on the two agreeing.
final class TrashlessFileManager: FileManager {
    override func url(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?,
        create shouldCreate: Bool
    ) throws -> URL {
        guard directory != .trashDirectory else {
            throw CocoaError(.featureUnsupported)
        }
        return try super.url(
            for: directory, in: domain, appropriateFor: url, create: shouldCreate)
    }

    override func trashItem(
        at url: URL,
        resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        throw CocoaError(
            .featureUnsupported,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\u{201C}\(url.lastPathComponent)\u{201D} couldn\u{2019}t be moved to the "
                    + "trash because the volume \u{201C}share\u{201D} doesn\u{2019}t have one."
            ])
    }
}
