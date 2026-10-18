import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

@Suite struct ServedFileFuzzTests {
    private let cases = 3000
    @Test func servedFileTargets() throws {
        let scratch = try Scratch()
        defer { withExtendedLifetime(scratch) {} }
        try scratch.file("root/stream/index.m3u8", "x")
        try scratch.file("root/.hidden", "x")
        try scratch.file("secret.txt", "x")
        try scratch.symlink("root/stream/out", to: scratch.path("secret.txt").path)
        let root = scratch.path("root").resolvingSymlinksInPath()
        var f = Fuzzer(seed: 9)
        var v = Violations()
        let samples = [
            "/S3CRET/stream/index.m3u8", "/S3CRET/stream/out", "/S3CRET/../secret.txt", "/S3CRET/.hidden",
            "/S3CRET/stream/index.m3u8?x=1", "/S3CRET/stream%2Findex.m3u8",
        ]
        var served = 0
        for _ in 0..<cases {
            let t = f.int(4) == 0 ? f.string(max: 10) : f.mutate(f.pick(samples))
            guard let file = Escaping.servedFile(for: t, root: root, secret: "S3CRET") else { continue }
            served += 1
            v.check(file.path.hasPrefix(root.path + "/") && file.lastPathComponent == "index.m3u8", "\(t.debugDescription) → \(file.path)")
        }
        #expect(served > 0)
        #expect(v.list.isEmpty, "\(v.list)")
    }
}
