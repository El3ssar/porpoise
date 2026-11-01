import Foundation
import Testing

@testable import PorpoiseServices

struct GeneratedPathExclusionsTests {
    @Test func componentRulesMatchThePreviousPolicyIncludingUnicodeAndNearMisses() {
        let paths = [
            "/", "/home/project/src/file.swift", "/home/日本語/🐬/file.txt", "/a/.git/objects", "/a/.git/objects/ab/cd",
            "/a/.git//objects", "/a/.git/objects-old", "/a/x.git/objects", "/node_modules", "/a/node_modules/b", "/a/node_modules-old",
            "/a/.build", "/a/.build/debug/file", "/a/DerivedData/a", "/a/DerivedData-old", "/a/build/file", "/a/É/.buildx",
        ]
        for git in [false, true] {
            for modules in [false, true] {
                for build in [false, true] {
                    let matcher = GeneratedPathExclusions(gitObjects: git, nodeModules: modules, buildOutput: build)
                    for path in paths {
                        let previous =
                            (git && (path.hasSuffix("/.git/objects") || path.contains("/.git/objects/")))
                            || (modules && path.split(separator: "/").contains("node_modules"))
                            || (build && [".build", "DerivedData"].contains { path.hasSuffix("/" + $0) || path.contains("/" + $0 + "/") })
                        #expect(matcher.matches(path) == previous, "\(path): git=\(git), modules=\(modules), build=\(build)")
                    }
                }
            }
        }
    }
}
