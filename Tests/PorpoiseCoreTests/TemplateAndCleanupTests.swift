import Foundation
import Testing

@testable import PorpoiseCore

struct TemplateExpansionTests {
    @Test func variablesAreStableAndDoNotRecursivelyExpand() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        let context = TemplateContext(date: date, user: "A🐬{name}", name: "résumé", counter: 7, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(
            TemplateExpansion.expand("{date} {time} {user} {name} {counter} {counter:03}", context: context)
                == "2026-01-02 03-04-05 A🐬{name} résumé 7 007")
        #expect(TemplateExpansion.expand("{\"x\": {}} {unknown}", context: context) == "{\"x\": {}} {unknown}")
    }
    @Test func bodyUsesActualFilenameAndBinaryTemplatesSurvive() throws {
        let template = FileTemplate(title: "Note", filename: "{name}-{counter:2}.txt", contents: Data("{name} by {user}".utf8))
        let rendered = try TemplateExpansion.render(template, context: TemplateContext(user: "me", name: "日本語", counter: 12))
        #expect(rendered.name == "日本語-12.txt")
        #expect(String(data: rendered.contents, encoding: .utf8) == "日本語-12 by me")
        var binary = template; binary.contents = Data([0xff, 0x00, 0xfe])
        #expect(try TemplateExpansion.render(binary, context: TemplateContext(name: "x")).contents == binary.contents)
        binary.contents = Data([0]) + Data("{date}".utf8)
        #expect(try TemplateExpansion.render(binary, context: TemplateContext(name: "x")).contents == binary.contents)
        #expect(throws: (any Error).self) {
            try TemplateExpansion.render(template, filenamePattern: "../escape", context: TemplateContext(name: "x"))
        }
    }
}

struct AppCleanupRulesTests {
    let app = CleanupApplication(
        url: URL(fileURLWithPath: "/Applications/Example.app"), bundleID: "com.test.example", name: "Example",
        groups: ["group.test.private", "group.test.shared"])
    let other = CleanupApplication(
        url: URL(fileURLWithPath: "/Applications/Other.app"), bundleID: "com.test.other", name: "Other", groups: ["group.test.shared"])
    @Test func preparedMatchingPreservesUnicodeAndSelectedOrder() {
        let unicode = CleanupApplication(url: app.url, bundleID: "com.test.CAFÉ", name: "Straße", groups: ["GROUP.café"])
        let second = CleanupApplication(url: other.url, bundleID: unicode.bundleID, name: unicode.name)
        let matcher = AppCleanupRules.Matcher(selected: [unicode, second], installed: [unicode, second])
        #expect(matcher.match(name: "COM.TEST.cafe\u{301}", category: .support)?.application == unicode)
        #expect(matcher.match(name: "STRASSE", category: .support)?.application == unicode)
        #expect(matcher.match(name: "group.CAFE\u{301}", category: .groups)?.application == unicode)
        let shared = AppCleanupRules.Matcher(selected: [unicode], installed: [unicode, second])
        #expect(shared.match(name: "com.test.cafe\u{301}", category: .support) == nil)
    }
    @Test func wholeIdentifiersAndNamesOnly() {
        #expect(
            AppCleanupRules.match(name: "com.test.example.plist", category: .preferences, selected: [app], installed: [app, other])?.reason
                == "Bundle identifier: com.test.example")
        #expect(AppCleanupRules.match(name: "Example", category: .support, selected: [app], installed: [app, other])?.application == app)
        #expect(AppCleanupRules.match(name: "Example Pro", category: .support, selected: [app], installed: [app, other]) == nil)
        #expect(AppCleanupRules.match(name: "com.test.example.helper", category: .caches, selected: [app], installed: [app, other]) == nil)
        #expect(AppCleanupRules.match(name: "Example", category: .containers, selected: [app], installed: [app, other]) == nil)
    }
    @Test func groupsNeedExclusiveVerifiedEntitlements() {
        var variant = other; variant.groups = ["GROUP.TEST.PRIVATE"]
        #expect(AppCleanupRules.match(name: "group.test.private", category: .groups, selected: [app], installed: [app, variant]) == nil)
        #expect(AppCleanupRules.match(name: "group.test.shared", category: .groups, selected: [app], installed: [app, other]) == nil)
        #expect(AppCleanupRules.match(name: "Example", category: .groups, selected: [app], installed: [app]) == nil)
        #expect(AppCleanupRules.match(name: "group.test.private", category: .groups, selected: [app], installed: [app, other]) != nil)
        #expect(
            AppCleanupRules.match(name: "group.test.private", category: .groups, selected: [app], installed: [app], groupOwnershipComplete: false)
                == nil)
        #expect(
            AppCleanupRules.match(
                name: "group.test.shared", identifier: "group.test.private", category: .groups, selected: [app], installed: [app, other]) == nil)
        #expect(AppCleanupRules.match(name: "group.test.shared", category: .groups, selected: [app, other], installed: [app, other]) != nil)
    }
    @Test func otherInstalledCopyAndAmbiguousNamesAreKept() {
        let reserved = CleanupApplication(url: app.url, bundleID: app.bundleID, name: "ByHost")
        #expect(AppCleanupRules.match(name: "ByHost", category: .preferences, selected: [reserved], installed: []) == nil)
        let copy = CleanupApplication(url: URL(fileURLWithPath: "/elsewhere/Example.app"), bundleID: app.bundleID, name: app.name)
        #expect(AppCleanupRules.match(name: "com.test.example", category: .support, selected: [app], installed: [app, copy]) == nil)
        let sameName = CleanupApplication(url: other.url, bundleID: other.bundleID, name: app.name)
        #expect(AppCleanupRules.match(name: "Example", category: .logs, selected: [app], installed: [app, sameName]) == nil)
        #expect(
            AppCleanupRules.match(
                name: "com.test.example.plist", category: .agents, selected: [app], installed: [app, other], associatedBundleIDs: [other.bundleID])
                == nil)
    }
}
