import Foundation
import PorpoiseCore
import PorpoiseServices
import PorpoiseTestSupport
import Testing

@Suite struct SystemDefaultsTests {
    @Test func shellUsesTheLocalExecutableProbe() {
        #expect(ShellChoice.zsh.executable(custom: "", environment: ["PATH": "/nonexistent"]) == "/bin/zsh")
    }
    @Test func viewDefaultsUseTheCurrentHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in [".Trash", "Downloads", "Documents"] {
            let folder = home.appendingPathComponent(name)
            #expect(ViewProperties.defaults(for: folder) == ViewProperties.defaults(for: folder, home: home))
        }
    }
}
