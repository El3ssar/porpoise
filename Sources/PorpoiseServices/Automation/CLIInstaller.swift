import Foundation

public enum CLIInstaller {
    public enum Failure: Error, LocalizedError {
        case missingExecutable, occupied
        public var errorDescription: String? {
            switch self {
            case .missingExecutable: return "This copy of Porpoise does not contain the command-line tool."
            case .occupied: return "A different file already exists at the installation path. Move it aside before installing."
            }
        }
    }
    public static var destination: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/porpoise") }

    /// User-local only; no shell startup files, administrator prompts or replacement of unrelated files.
    public static func install(executable: URL, destination: URL = destination) throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable.path) else { throw Failure.missingExecutable }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try? fm.destinationOfSymbolicLink(atPath: destination.path), existing == executable.path { return }
        // createSymbolicLink is exclusive, including dangling links. Never remove a pre-existing destination.
        do { try fm.createSymbolicLink(at: destination, withDestinationURL: executable) } catch { throw Failure.occupied }
    }
}
