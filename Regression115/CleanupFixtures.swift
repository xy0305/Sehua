import Foundation

final class CleanupMock: URLProtocol, @unchecked Sendable {
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
@main struct CleanupFixtures {
    static func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }
        return String(decoding: data, as: UTF8.self)
    }
    static func run(_ mode: String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CleanupMock.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        let archive = SHT115Archive(id: "21", name: "fixture.zip", directoryCID: "20", pickCode: "archivePC")
        var resource = SHT115Resource(id: "fixture", account: settings.account, tid: "1", directoryName: "fixture", parentCID: "10", directoryCID: "20", directoryWritePending: false, tasks: [])
        resource.extractions = ["21": mode == "unknownExtraction" ? .unknown : .accepted]
        if mode != "legacy" {
            resource.extractionJobs = ["21": SHT115ExtractionJob(extractID: "900", source: archive, targetCID: "20", outputs: [SHT115ExtractionOutput(name: "movie.mp4", directory: false, size: 42)], priorIDs: mode == "existing" ? ["21", "22"] : ["21"], cleanup: mode == "crash" ? .submitting : .waiting)]
        }
        try JSONEncoder().encode([resource]).write(to: store)
        var deletions = 0
        CleanupMock.handler = { request in
            let url = request.url!
            if url.path == "/files/add_extract_file" {
                precondition(request.httpMethod != "POST" && url.query == "extract_id=900")
                if mode == "failed" { return "{\"state\":false,\"data\":{\"percent\":100}}" }
                if mode == "unknownProgress" { return "{\"state\":true,\"data\":{}}" }
                return "{\"state\":true,\"data\":{\"percent\":" + (mode == "pending" ? "50" : "100") + "}}"
            }
            if url.path == "/rb/delete" {
                precondition(request.httpMethod == "POST")
                precondition(body(request) == "fid%5B0%5D=21&pid=20")
                deletions += 1
                if mode == "timeout" { throw URLError(.timedOut) }
                if mode == "rejected" { return "{\"state\":false}" }
                if mode == "unknownDelete" { return "{}" }
                return "{\"state\":true}"
            }
            precondition(url.path == "/files" && request.httpMethod != "POST")
            let source = mode == "changedSource" ? "otherPC" : "archivePC"
            let output = mode == "missing" ? "" : ",{\"fid\":22,\"n\":\"movie.mp4\",\"pc\":\"moviePC\",\"s\":" + (mode == "sizeMismatch" ? "41" : "42") + "}"
            let count = mode == "missing" ? 1 : 2
            return "{\"state\":true,\"count\":" + String(count) + ",\"path\":[{\"cid\":0},{\"cid\":10},{\"cid\":20}],\"data\":[{\"fid\":21,\"n\":\"fixture.zip\",\"pc\":\"" + source + "\",\"s\":42}" + output + "]}"
        }
        let service = try SHT115Service(storeURL: store, session: session)
        _ = try await service.requestExtraction(archive: archive, resourceID: "fixture", settings: settings, confirmed: true)
        let expected = ["complete", "timeout", "rejected", "unknownDelete"].contains(mode) ? 1 : 0
        precondition(deletions == expected, mode)
        // Repeated call and process restart must never replay any destructive write.
        _ = try await service.requestExtraction(archive: archive, resourceID: "fixture", settings: settings, confirmed: true)
        let restored = try SHT115Service(storeURL: store, session: session)
        _ = try await restored.requestExtraction(archive: archive, resourceID: "fixture", settings: settings, confirmed: true)
        precondition(deletions == expected, "replay: " + mode)
        print("PASS cleanup: " + mode)
    }
    static func main() async throws {
        for mode in ["complete", "pending", "failed", "unknownProgress", "unknownExtraction", "missing", "existing", "sizeMismatch", "changedSource", "legacy", "timeout", "rejected", "unknownDelete", "crash"] { try await run(mode) }
    }
}
