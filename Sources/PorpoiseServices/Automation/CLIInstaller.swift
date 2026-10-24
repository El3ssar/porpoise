import Foundation

public enum CLIInstaller {
    public enum Failure: Error, LocalizedError {
        case missingExecutable, occupied, cannotInstall
        public var errorDescription: String? {
            switch self {
            case .missingExecutable: return "This copy of Porpoise does not contain the command-line tool."
            case .occupied: return "A different file already exists at the installation path. Move it aside before installing."
            case .cannotInstall: return "The command-line link could not be created. Check the installation folder’s permissions and free space."
            }
        }
    }
    public static var destination: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/porpoise") }

    /// User-local only; no shell startup files, administrator prompts or replacement of unrelated files.
    public static func install(executable: URL, destination: URL = destination) throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable.path) else { throw Failure.missingExecutable }
        if let existing = try? fm.destinationOfSymbolicLink(atPath: destination.path), existing == executable.path { return }
        do { try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
            throw Failure.cannotInstall
        }
        // createSymbolicLink is exclusive, including dangling links. Never remove a pre-existing destination.
        do { try fm.createSymbolicLink(at: destination, withDestinationURL: executable) } catch { throw Failure.occupied }
    }
}
