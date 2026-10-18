import CryptoKit
import Foundation

/// AWS Signature Version 4, using the exact S3 path (never normalizing repeated slashes or dot components).
public enum S3Signer {
    static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    static func hash(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    static func encode(_ text: String, slash: Bool = false) -> String {
        text.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte)
                || (slash && byte == 47)
            {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    public static func sign(_ input: URLRequest, keys: S3AccessKeys, region: String, date: Date = Date()) throws -> URLRequest {
        guard let url = input.url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host else {
            throw S3Error.invalidLocation
        }
        var request = input
        c.percentEncodedPath = encode(c.path.isEmpty ? "/" : c.path, slash: true)
        guard let canonicalURL = c.url else { throw S3Error.invalidLocation }
        request.url = canonicalURL
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .gmt
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: date), day = String(stamp.prefix(8)), payload = hash(request.httpBody ?? Data())
        request.setValue(host + (c.port.map { ":\($0)" } ?? ""), forHTTPHeaderField: "Host")
        request.setValue(stamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payload, forHTTPHeaderField: "x-amz-content-sha256")
        if let token = keys.sessionToken { request.setValue(token, forHTTPHeaderField: "x-amz-security-token") }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where name.lowercased() != "authorization" {
            headers[name.lowercased()] = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let names = headers.keys.sorted(), signed = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()
        var pairs: [(String, String)] = (c.queryItems ?? []).map { (encode($0.name), encode($0.value ?? "")) }
        pairs.sort { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
        let query = pairs.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
        let path = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        let canonical = [request.httpMethod ?? "GET", path, query, canonicalHeaders, signed, payload].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let string = "AWS4-HMAC-SHA256\n\(stamp)\n\(scope)\n\(hash(Data(canonical.utf8)))"
        func hmac(_ key: Data, _ text: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
        }
        let key = hmac(hmac(hmac(hmac(Data(("AWS4" + keys.secretAccessKey).utf8), day), region), "s3"), "aws4_request")
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(keys.accessKeyID)/\(scope), SignedHeaders=\(signed), Signature=\(hex(hmac(key, string)))",
            forHTTPHeaderField: "Authorization")
        return request
    }
}
