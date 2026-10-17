import Foundation
import Testing

@testable import PorpoiseCore

struct FileErrorKindTests {
    @Test func typedErrorsSurviveSeveralWrapperLayers() {
        let cases: [(String, Int, FileErrorKind)] = [
            (NSPOSIXErrorDomain, Int(EACCES), .permission), (NSPOSIXErrorDomain, Int(EPERM), .permission),
            (NSPOSIXErrorDomain, Int(ENOSPC), .noSpace), (NSPOSIXErrorDomain, Int(ENAMETOOLONG), .nameTooLong),
            (NSPOSIXErrorDomain, Int(EBUSY), .locked), (NSPOSIXErrorDomain, Int(ETXTBSY), .locked),
            (NSPOSIXErrorDomain, Int(ENOENT), .notFound), (NSPOSIXErrorDomain, Int(ENOTDIR), .notFound),
            (NSPOSIXErrorDomain, Int(ECONNRESET), .network), (NSPOSIXErrorDomain, Int(ETIMEDOUT), .network),
            (NSCocoaErrorDomain, NSFileReadNoPermissionError, .permission),
            (NSCocoaErrorDomain, NSFileWriteNoPermissionError, .permission),
            (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError, .noSpace),
            (NSCocoaErrorDomain, NSFileNoSuchFileError, .notFound),
            (NSCocoaErrorDomain, NSFileReadNoSuchFileError, .notFound),
            (NSURLErrorDomain, NSURLErrorNetworkConnectionLost, .network),
            (NSURLErrorDomain, NSURLErrorNotConnectedToInternet, .network),
        ]
        for (domain, code, expected) in cases {
            let typed = NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: "opaque description"])
            let wrapped = NSError(domain: "wrapper", code: 0, userInfo: [NSUnderlyingErrorKey: typed])
            let twice = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: wrapped])
            #expect(FileErrorKind.classify(twice) == expected, "\(domain):\(code)")
            #expect(expected.reason != nil)
        }
        // The structured code wins over a misleading file name or command description.
        #expect(
            FileErrorKind.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: [NSLocalizedDescriptionKey: "permission denied"]))
                == .noSpace)
    }

    @Test func privacyRequiresLocalListingContextAndPreservesUnderlyingEPERM() {
        func denied(_ code: Int32) -> NSError {
            NSError(
                domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                userInfo: [
                    NSUnderlyingErrorKey: NSError(
                        domain: "wrapper", code: 0,
                        userInfo: [
                            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                        ])
                ])
        }
        #expect(FileErrorKind.classify(denied(EPERM)) == .permission)
        #expect(FileErrorKind.classify(denied(EPERM), readable: false) == .privacy)
        #expect(FileErrorKind.classify(denied(EACCES), readable: false) == .permission)
        #expect(FileErrorKind.classify(denied(EACCES), readable: true) == .privacy)
        #expect(FileErrorKind.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError), readable: true) == .privacy)
    }

    @Test func commandErrorsAndLegacyRecordsShareOneTextFallback() {
        let cases: [(String, FileErrorKind)] = [
            ("No such file", .notFound), ("No longer there", .notFound),
            ("Permission denied", .permission), ("Operation not permitted", .permission),
            ("You don’t have permission", .permission), ("You don't have permission", .permission),
            ("File name too long", .nameTooLong), ("No space left on device", .noSpace), ("Disk full", .noSpace),
            ("Resource busy", .locked), ("File locked", .locked), ("Connection reset", .network),
            ("Network unavailable", .network), ("Timed out", .network), ("Something else", .unknown),
        ]
        for (message, expected) in cases {
            #expect(FileErrorKind.classify(message: message) == expected)
            #expect(FileErrorKind.classify(FileOperationError.failed(message)) == expected)
        }
        #expect(FileErrorKind.unknown.reason == nil)
        #expect(
            FileErrorKind.classify(NSError(domain: "unrelated", code: NSFileReadNoPermissionError, userInfo: [NSLocalizedDescriptionKey: "unknown"]))
                == .unknown)
        #expect(FileErrorKind.classify(FileOperationError.cancelled) == .unknown)
    }
}
