import Foundation
import PorpoiseCore

extension ShellChoice {
    /// Resolve against this process's environment and the local executable files.
    public func executable(custom: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        executable(custom: custom, environment: environment, isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
