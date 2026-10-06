import Foundation

final class ExtractionMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> String)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let text = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// Compile separately from other @main fixtures with Integration115 sources on macOS.
@main struct ExtractionFixtures {
    static func form(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(data: data, encoding: .utf8)! }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }
        return String(data: data, encoding: .utf8)!
    }
    static func run(unknown: Bool = false, unsafe: Bool = false, taskFailure: Bool = false) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExtractionMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        let hash = "c01c8d4ca9f86be02ac7f46ae510c130"
        let link = "ed2k://|file|fixture.zip|42|" + hash.uppercased() + "|/"
        precondition(SHT115Service.infoHash(link) == hash)
        let task = SHT115Task(id: UUID(), urls: [link], state: .accepted, progress: [], updatedAt: Date())
        let resource = SHT115Resource(id: "fixture", account: settings.account, tid: "3802769", directoryName: "fixture", parentCID: "10", directoryCID: "20", directoryWritePending: false, tasks: [task])
        try JSONEncoder().encode([resource]).write(to: store)
        var writes = [String](), reads = [String]()
        ExtractionMockProtocol.handler = { request in
            let url = request.url!, path = request.url!.path == "/natsort/files.php" ? "/files" : request.url!.path
            if request.httpMethod == "POST" { writes.append(path) } else { reads.append(path) }
            if path == "/files" {
                return "{\"state\":true,\"count\":2,\"path\":[{\"cid\":0},{\"cid\":10},{\"cid\":20}],\"data\":[{\"fid\":21,\"n\":\"fixture.zip\",\"pc\":\"archivePC\"},{\"fid\":22,\"n\":\"existing.mp4\",\"pc\":\"videoPC\"}]}"
            }
            if path == "/web/lixian/" || path == "/web/lixian" {
                precondition(url.query!.contains("info_hash=" + hash))
                precondition(!url.query!.contains("page=2"))
                if taskFailure { throw URLError(.timedOut) }
                return "{\"state\":true,\"tasks\":[{\"info_hash\":\"" + hash + "\",\"wp_path_id\":20,\"status\":2,\"percentDone\":100}]}"
            }
            if path == "/files/push_extract" {
                if request.httpMethod == "POST" { precondition(form(request) == "pick_code=archivePC&secret="); return "{\"state\":true}" }
                return "{\"state\":true,\"data\":{\"extract_status\":{\"unzip_status\":4,\"progress\":100}}}"
            }
            if path == "/files/extract_info" {
                let name = unsafe ? "../escape" : "movie.mp4"
                return "{\"state\":true,\"data\":{\"count\":2,\"list\":[{\"file_name\":\"" + name + "\",\"size\":42,\"ico\":\"mp4\"},{\"file_name\":\"folder\",\"size\":0}]}}"
            }
            precondition(path == "/files/add_extract_file", "Unexpected mock endpoint: " + path)
            let body = form(request)
            precondition(body.contains("to_pid=20") && body.contains("extract_file%5B%5D=movie.mp4") && body.contains("extract_dir%5B%5D=folder"))
            precondition(!body.contains("delete") && !body.contains("password"))
            if unknown { throw URLError(.timedOut) }
            return "{\"state\":true}"
        }
        let service = try SHT115Service(storeURL: store, session: session)
        let inspection = try await service.inspect(resourceID: resource.id, settings: settings)
        precondition(inspection.listing.videos.count == 1)
        precondition(inspection.taskPagesTruncated == taskFailure)
        precondition(reads.first == "/files" && writes.isEmpty)
        let archive = inspection.listing.archives[0]
        do {
            let result = try await service.requestExtraction(archive: archive, resourceID: resource.id, settings: settings, confirmed: true)
            precondition(!unknown && !unsafe && result.state == .accepted)
        } catch { precondition(unknown || unsafe) }
        precondition(writes.filter { $0 == "/files/push_extract" }.count == 1)
        precondition(writes.filter { $0 == "/files/add_extract_file" }.count == (unsafe ? 0 : 1))
        if !unsafe {
            let restored = try SHT115Service(storeURL: store, session: session)
            let before = writes.count
            let outcome = try await restored.requestExtraction(archive: archive, resourceID: resource.id, settings: settings, confirmed: true)
            precondition(outcome.state == (unknown ? .unknown : .accepted))
            precondition(writes.count == before)
        }
    }
    static func main() async throws {
        try await run()
        try await run(unknown: true)
        try await run(unsafe: true)
        try await run(taskFailure: true)
        print("PASS: directory independent, lowercase ed2k targeted lookup, extract protocol, target CID, unsafe names blocked, unknown not replayed after restart")
    }
}
