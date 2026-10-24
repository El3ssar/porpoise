import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct CloudOperationSidecarTests {
    @Test func directoryEnumerationCanResolveTheStagingRootAlias() throws {
        let scratch = try Scratch(), fm = FileManager.default
        let root = scratch.url.appendingPathComponent("staging"), alias = scratch.url.appendingPathComponent("alias")
        let folder = root.appendingPathComponent("recovery")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: root)
        let partial = alias.appendingPathComponent("recovery/.partial")
        let owner = CloudOperationSidecar(partial: partial, account: "fixture", legacy: partial.appendingPathExtension("legacy"))
        let operation = try owner.operation()
        let enumerated = try #require(fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
            .appendingPathComponent(".partial")
        #expect(partial != enumerated)
        let recovered = CloudOperationSidecar(partial: enumerated, account: "fixture", legacy: enumerated.appendingPathExtension("legacy"))
        #expect(try recovered.existing() == operation)
        let foreign = root.appendingPathComponent("foreign")
        try fm.copyItem(at: enumerated.appendingPathExtension("cloud-operation"), to: foreign.appendingPathExtension("cloud-operation"))
        let other = CloudOperationSidecar(partial: foreign, account: "fixture", legacy: foreign.appendingPathExtension("legacy"))
        #expect(throws: CloudContentError.changed) { try other.existing() }
        try recovered.remove()
        #expect(try owner.existing() == nil)
    }

    @Test(arguments: [".operation", "old.dropbox-operation"])
    func importsLegacyUUIDAndBindsItToThePartial(_ name: String) throws {
        let scratch = try Scratch(), id = UUID(), partial = scratch.url.appendingPathComponent("bytes")
        let legacy = scratch.url.appendingPathComponent(name)
        try JSONEncoder().encode(id).write(to: legacy)
        let item = CloudRemoteItem(ref: .init(account: "fixture", item: "opaque/id"), name: "same-name", revision: "rev")
        let owner = CloudOperationSidecar(partial: partial, account: "fixture", legacy: legacy, item: item)
        #expect(try owner.existing() == id)
        #expect(try owner.operation() == id && owner.existing() == id)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let canonical = partial.appendingPathExtension("cloud-operation")
        let mode = try FileManager.default.attributesOfItem(atPath: canonical.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let foreign = CloudOperationSidecar(partial: partial, account: "other", legacy: legacy)
        #expect(throws: CloudContentError.changed) { try foreign.existing() }
        #expect(throws: CloudContentError.changed) { try foreign.remove() }
        #expect(FileManager.default.fileExists(atPath: canonical.path))
        var changed = item; changed.revision = "new-rev"
        #expect(throws: CloudContentError.changed) {
            try CloudOperationSidecar(partial: partial, account: "fixture", legacy: legacy, item: changed).operation()
        }
        try owner.remove(); #expect(try owner.existing() == nil)
    }

    @Test func concurrentCallersKeepOneOwnerAndCorruptLegacyIsPreserved() throws {
        let scratch = try Scratch(), partial = scratch.url.appendingPathComponent("bytes")
        let legacy = scratch.url.appendingPathComponent(".operation")
        let owner = CloudOperationSidecar(partial: partial, account: "fixture", legacy: legacy)
        let lock = NSLock(); var ids: [UUID] = []
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do { let id = try owner.operation(); lock.withLock { ids.append(id) } } catch { Issue.record(error) }
        }
        #expect(ids.count == 12 && Set(ids).count == 1)
        try owner.remove()
        try Data("broken record".utf8).write(to: legacy)
        #expect(throws: (any Error).self) { try owner.operation() }
        #expect(try Data(contentsOf: legacy) == Data("broken record".utf8))
    }
}
