import Foundation

@main struct CleanupBenchmark {
    static func main() {
        let installed = (0..<1000).map {
            CleanupApplication(url: URL(fileURLWithPath: "/fixture/App-\($0).app"), bundleID: "com.fixture.app\($0)", name: "App \($0)")
        }
        let selected = [installed[0]], start = ProcessInfo.processInfo.systemUptime
        #if BASELINE
        let match: (String) -> CleanupMatch? = {
            AppCleanupRules.match(name: $0, category: .caches, selected: selected, installed: installed)
        }
        #else
        let matcher = AppCleanupRules.Matcher(selected: selected, installed: installed)
        let match: (String) -> CleanupMatch? = { matcher.match(name: $0, category: .caches) }
        #endif
        var matches = 0
        for i in 0..<1000 { if match(i == 0 ? "com.fixture.app0" : "unrelated-\(i)") != nil { matches += 1 } }
        precondition(matches == 1)
        print(
            "Cleanup matching 1000 candidates / 1000 installed apps: \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms (\(matches) match)")
    }
}
