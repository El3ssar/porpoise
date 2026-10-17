import Foundation

/// Shared file-error categories for retry, authentication, browser privacy guidance, and error rows.
public enum FileErrorKind: Sendable {
    case permission, privacy, noSpace, nameTooLong, locked, network, notFound, unknown

    /// Structured errors take precedence over the fallback for command-line providers' text errors.
    /// Supply readability only when listing a local folder: EPERM, or a denied but readable folder, indicates TCC.
    public static func classify(_ error: Error, readable: Bool? = nil) -> FileErrorKind {
        var current: NSError? = error as NSError
        var permission: FileErrorKind?
        var seen: Set<ObjectIdentifier> = []
        while let value = current, seen.insert(ObjectIdentifier(value)).inserted {
            if value.domain == NSPOSIXErrorDomain {
                switch value.code {
                case Int(EPERM): return readable == nil ? .permission : .privacy
                case Int(EACCES): return readable == true ? .privacy : .permission
                case Int(ENOSPC): return .noSpace
                case Int(ENAMETOOLONG): return .nameTooLong
                case Int(EBUSY), Int(ETXTBSY): return .locked
                case Int(ENOENT), Int(ENOTDIR): return .notFound
                case Int(ENETDOWN), Int(ENETUNREACH), Int(ECONNABORTED), Int(ECONNRESET), Int(ENOTCONN), Int(ETIMEDOUT), Int(EHOSTUNREACH):
                    return .network
                default: break
                }
            }
            if value.domain == NSCocoaErrorDomain {
                switch value.code {
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                    // Continue through wrappers: an underlying EPERM distinguishes privacy from ordinary denial.
                    permission = readable == true ? .privacy : .permission
                case NSFileWriteOutOfSpaceError: return .noSpace
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound
                default: break
                }
            }
            if value.domain == NSURLErrorDomain {
                switch value.code {
                case NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                    NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet:
                    return .network
                default: break
                }
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return permission ?? classify(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    /// Legacy Activity records and command-line providers carry descriptions rather than NSError codes.
    public static func classify(message: String) -> FileErrorKind {
        let lower = message.lowercased()
        if lower.contains("no such file") || lower.contains("no longer there") { return .notFound }
        if lower.contains("permission denied") || lower.contains("operation not permitted")
            || lower.contains("don’t have permission") || lower.contains("don't have permission")
        {
            return .permission
        }
        if lower.contains("name too long") { return .nameTooLong }
        if lower.contains("no space left") || lower.contains("disk full") { return .noSpace }
        if lower.contains("locked") || lower.contains("resource busy") { return .locked }
        if lower.contains("connection") || lower.contains("network") || lower.contains("timed out") { return .network }
        return .unknown
    }

    public var reason: String? {
        switch self {
        case .permission: return "Permission denied"
        case .privacy: return "macOS protects this folder"
        case .noSpace: return "Disk full"
        case .nameTooLong: return "Name too long for this disk"
        case .locked: return "File is locked"
        case .network: return "Lost connection"
        case .notFound: return "No longer exists"
        case .unknown: return nil
        }
    }
}
