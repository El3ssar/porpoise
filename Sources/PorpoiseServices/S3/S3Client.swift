import Foundation
import PorpoiseCore

struct S3Object: Sendable {
    var key: String
    var size: Int64 = 0
    var etag: String = ""
    var operation: String?
    var modified: Date?
    var isFolder: Bool { key.hasSuffix("/") }
}

/// Small XML reader: S3's namespace does not affect local element names. DTDs and external entities are refused.
final class S3XML: NSObject, XMLParserDelegate {
    var values: [String: [String]] = [:]
    var objects: [S3Object] = []
    var prefixes: [String] = []
    private var stack: [String] = [], text = "", fields: [String: String] = [:]
    private var invalid = false
    static func parse(_ data: Data) throws -> S3XML {
        guard !String(decoding: data, as: UTF8.self).contains("<!DOCTYPE") else { throw S3Error.invalidResponse }
        let result = S3XML(), parser = XMLParser(data: data); parser.delegate = result; parser.shouldResolveExternalEntities = false
        guard parser.parse(), !result.invalid else { throw S3Error.invalidResponse }; return result
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(name); text = ""
        if name == "Contents" { fields = [:] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        values[name, default: []].append(text)
        if stack.contains("Contents") { fields[name] = text }
        if name == "Prefix", stack.contains("CommonPrefixes") { prefixes.append(text) }
        if name == "Contents" {
            if let key = fields["Key"], let size = fields["Size"].flatMap(Int64.init), size >= 0,
                let etag = fields["ETag"], !etag.isEmpty
            {
                objects.append(S3Object(key: key, size: size, etag: etag, modified: fields["LastModified"].flatMap(FileFormat.iso8601)))
            } else {
                invalid = true
            }
        }
        _ = stack.popLast(); text = ""
    }
    func first(_ name: String) -> String? { values[name]?.first }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public final class S3Client: @unchecked Sendable {
    public let location: S3Location
    let authorized: CloudAuthorizedClient
    let journal: CloudJournal<S3Operation>
    let legacyJournal: CloudJournal<S3Operation>?
    let multipartCopyThreshold: Int64
    let copyPartSize: Int64
    public init(
        location: S3Location, directory: URL? = nil, transport: CloudHTTPTransport = .init(),
        multipartCopyThreshold: Int64 = 5 * 1024 * 1024 * 1024, copyPartSize: Int64 = 512 << 20
    ) {
        self.multipartCopyThreshold = max(1, multipartCopyThreshold); self.copyPartSize = max(5 << 20, copyPartSize)
        self.location = location
        let identity = S3Signer.hash(Data("\(location.endpoint)|\(location.region)|\(location.bucket)".utf8))
        journal = CloudJournal(
            folder: (directory ?? Settings.supportFolder.appendingPathComponent("S3").appendingPathComponent(location.accountID.uuidString))
                .appendingPathComponent(identity))
        legacyJournal =
            directory == nil
            ? CloudJournal(
                folder: Settings.cachesFolder.appendingPathComponent("S3").appendingPathComponent(location.accountID.uuidString)
                    .appendingPathComponent(identity)) : nil
        authorized = CloudAuthorizedClient(
            transport: transport, token: { _ in "" },
            classify: { body, response, idempotent in
                let code = (try? S3XML.parse(body).first("Code")) ?? "HTTP \(response.statusCode)"
                if (200..<300).contains(response.statusCode) {
                    return .done
                }
                let error = S3Error.service(response.statusCode, code)
                if idempotent, [429, 500, 502, 503, 504].contains(response.statusCode) { return .retry(error) }
                return .fail(error)
            },
            authorize: { request in
                try S3Signer.sign(request, keys: S3Credentials.read(accountID: location.accountID), region: location.region)
            })
    }
    func request(_ method: String, key: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data? = nil) throws
        -> URLRequest
    {
        guard var c = URLComponents(url: location.endpoint, resolvingAgainstBaseURL: false) else { throw S3Error.invalidLocation }
        c.percentEncodedPath = "/" + S3Signer.encode(location.bucket) + "/" + S3Signer.encode(key, slash: true)
        c.percentEncodedQuery = query.sorted { $0.key < $1.key }.map { "\(S3Signer.encode($0.key))=\(S3Signer.encode($0.value))" }.joined(
            separator: "&")
        guard let url = c.url else { throw S3Error.invalidLocation }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
    @discardableResult
    func send(
        _ method: String, key: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data? = nil,
        idempotent: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        try await authorized.send(request(method, key: key, query: query, headers: headers, body: body), idempotent: idempotent)
    }
    func list(prefix: String, recursive: Bool = false) async throws -> [S3Object] {
        var result: [S3Object] = []
        try await CloudPager.each(repeated: S3Error.invalidResponse) { (token: String?) in
            var query = ["list-type": "2", "prefix": prefix, "encoding-type": "url"]
            if !recursive { query["delimiter"] = "/" }
            if let token { query["continuation-token"] = token }
            let xml = try S3XML.parse(await self.send("GET", key: "", query: query).0)
            guard xml.first("Code") == nil, let truncated = xml.first("IsTruncated"), ["true", "false"].contains(truncated) else {
                throw S3Error.invalidResponse
            }
            func decoded(_ key: String) throws -> String {
                guard xml.first("EncodingType") == "url" else { return key }
                // Match the AWS SDK decoder: spaces may be '+', while literal plus keys are percent-escaped.
                guard let decoded = key.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { throw S3Error.invalidResponse }
                return decoded
            }
            result += try xml.objects.map { object in
                var object = object; object.key = try decoded(object.key); return object
            }.filter { $0.key != prefix }
            result += try xml.prefixes.map { S3Object(key: try decoded($0)) }
            if truncated == "true" {
                guard let next = xml.first("NextContinuationToken"), !next.isEmpty else { throw S3Error.invalidResponse }; return next
            }
            return nil
        }
        return result
    }
    func head(_ key: String) async throws -> S3Object {
        let (_, response) = try await send("HEAD", key: key)
        guard let size = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), size >= 0,
            let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty
        else { throw S3Error.invalidResponse }
        return S3Object(key: key, size: size, etag: etag, operation: response.value(forHTTPHeaderField: "x-amz-meta-porpoise-operation"))
    }
    func exists(_ key: String) async throws -> Bool {
        do { _ = try await head(key); return true } catch S3Error.service(404, _) { return false }
    }
    func copy(_ object: S3Object, to key: String, replacing revision: String? = nil, context: CloudTransferContext = .init()) async throws {
        try await context.checkpoint()
        guard object.size >= 0, object.size <= 10000 * (5 * 1024 * 1024 * 1024) else { throw S3Error.invalidLocation }
        let r2 = location.endpoint.host?.hasSuffix(".r2.cloudflarestorage.com") == true
        if r2 && object.size > multipartCopyThreshold {
            throw RemoteError.unsupported("R2 does not support source revision conditions on multipart copies. The source was kept.")
        }
        let occupied = try await exists(key)
        guard (revision != nil || !occupied), try await list(prefix: key + "/", recursive: true).isEmpty else {
            throw RemoteError.exists(key)
        }
        let condition =
            r2
            ? (revision == nil ? "cf-copy-destination-if-none-match" : "cf-copy-destination-if-match")
            : (revision == nil ? "If-None-Match" : "If-Match")
        let sourceHeaders = [
            "x-amz-copy-source": "/" + S3Signer.encode(location.bucket) + "/" + S3Signer.encode(object.key, slash: true),
            "x-amz-copy-source-if-match": object.etag,
        ]
        if object.size > multipartCopyThreshold {
            try await multipartCopy(object, to: key, sourceHeaders: sourceHeaders, revision: revision, context: context)
            return
        }
        var headers = sourceHeaders; headers[condition] = revision ?? "*"
        let (data, _) = try await send("PUT", key: key, headers: headers)
        let xml = try S3XML.parse(data)
        guard xml.first("ETag") != nil, xml.first("Code") == nil else { throw S3Error.invalidResponse }
        context.progress(object.size, object.size)
    }
}
