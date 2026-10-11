import Foundation

final class QueueMock: URLProtocol, @unchecked Sendable {
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

@main struct QueueFixtures {
    static func run(_ mode: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueMock.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        let resource = SHT115Resource(id: "q", account: settings.account, tid: "1", directoryName: "fixture", parentCID: "10", directoryCID: "20", directoryWritePending: false, tasks: [])
        try JSONEncoder().encode([resource]).write(to: store)
        let hash = String(repeating: "a", count: 32)
        let sha = String(repeating: "b", count: 40)
        let outputSHA = String(repeating: "c", count: 40)
        var submitted = false, released = false, deletes = 0, parses = 0
        QueueMock.handler = { request in
            let url = request.url!, path = url.path
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func query(_ key: String) -> String { q.first(where: { $0.name == key })?.value ?? "" }
            if query("ac") == "space" { return "{\"sign\":\"fake\",\"time\":1}" }
            if query("ac") == "add_task_url" {
                submitted = true
                if mode == "unknownSubmission" { throw URLError(.timedOut) }
                return "{\"state\":true}"
            }
            if query("ac") == "task_lists" {
                let fid = mode == "noFileID" ? "" : ",\"file_id\":21"
                return "{\"state\":true,\"page_count\":1,\"tasks\":[{\"info_hash\":\"\(hash)\",\"wp_path_id\":20,\"status\":2,\"percentDone\":100\(fid)}]}"
            }
            if path == "/files/push_extract" {
                if request.httpMethod == "POST" { parses += 1; return "{\"state\":true}" }
                return "{\"state\":true,\"data\":{\"extract_status\":{\"unzip_status\":4,\"progress\":100}}}"
            }
            if path == "/files/extract_info" {
                let sha = mode == "noOutputHash" ? "" : ",\"sha1\":\"\(outputSHA)\""
                return "{\"state\":true,\"data\":{\"count\":1,\"next_marker\":\"\",\"list\":[{\"file_name\":\"movie.mp4\",\"size\":42,\"ico\":\"mp4\"\(sha)}]}}"
            }
            if path == "/files/add_extract_file" {
                if request.httpMethod == "POST" { released = true; return "{\"state\":true,\"data\":{\"extract_id\":900}}" }
                return "{\"state\":true,\"data\":{\"percent\":100}}"
            }
            if path == "/rb/delete" {
                deletes += 1
                precondition(request.httpMethod == "POST")
                if mode == "deleteTimeout" { throw URLError(.timedOut) }
                return "{\"state\":true}"
            }
            precondition(path == "/files", "unexpected API: " + path)
            var entries = [[String: Any]]()
            if submitted || mode == "existingSource" || mode == "duplicateBaseline" {
                entries.append(["fid": "21", "n": "fixture.zip", "s": 42, "pc": "sourcePC", "sha": sha])
            }
            if mode == "duplicateBaseline" && !submitted { let duplicate = entries; entries.append(contentsOf: duplicate) }
            if released { entries.append(["fid": "22", "n": "movie.mp4", "s": 42, "pc": "outputPC", "sha": mode == "outputHashMismatch" ? String(repeating: "d", count: 40) : outputSHA]) }
            let json: [String: Any] = ["state": true, "count": mode == "largeBaseline" && !submitted ? 101 : entries.count, "data": entries,
                "path": [["cid": "0"], ["cid": "10"], ["cid": "20"]], "offset": Int(query("offset")) ?? 0,
                "limit": 100, "order": "file_name", "is_asc": 1, "fc_mix": 1]
            return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        }
        let service = try SHT115Service(storeURL: store, session: session)
        do {
            _ = try await service.submit(urls: ["ed2k://|file|fixture.zip|42|\(hash)|/"], resourceID: "q", settings: settings, autoExtraction: mode != "legacy")
            precondition(mode != "unknownSubmission")
        } catch { precondition(mode == "unknownSubmission") }
        let restored = try SHT115Service(storeURL: store, session: session)
        let saved = await restored.resources()
        if ["largeBaseline", "duplicateBaseline"].contains(mode) { precondition(saved[0].extractionQueue == nil) }
        if mode == "cancelled", let item = saved[0].extractionQueue?.first {
            try await restored.cancelExtractionQueue(resourceID: "q", queueID: item.id, settings: settings)
        }
        let input = mode == "otherAccount" ? SHT115Settings(cookie: "UID=456_A1; CID=fake; SEID=fake", parentCID: "10") :
            mode == "otherParent" ? SHT115Settings(cookie: settings.cookie, parentCID: "11") : settings
        let now = Date()
        try await restored.runExtractionQueue(settings: input, now: now)
        try await restored.runExtractionQueue(settings: input, now: now.addingTimeInterval(301))
        let again = try SHT115Service(storeURL: store, session: session)
        try await again.runExtractionQueue(settings: input, now: now.addingTimeInterval(602))
        let shouldExtract = ["complete", "noOutputHash", "deleteTimeout", "outputHashMismatch"].contains(mode)
        precondition(parses == (shouldExtract ? 1 : 0), mode + " parse")
        precondition(deletes == (["complete", "deleteTimeout"].contains(mode) ? 1 : 0), mode + " recycle")
        // A future launch only reads/marks exhausted; no unbounded retry or replay.
        try await again.runExtractionQueue(settings: input, now: now.addingTimeInterval(90_000))
        precondition(deletes <= 1)
        let final = await again.resources()
        if mode == "complete", let item = final[0].extractionQueue?.first {
            precondition(item.state == .recycled)
            try await again.cancelExtractionQueue(resourceID: "q", queueID: item.id, settings: settings)
            let afterCancel = await again.resources()
            precondition(afterCancel[0].extractionQueue?.first?.state == .recycled)
        }
        if ["noFileID", "existingSource", "outputHashMismatch"].contains(mode) {
            precondition(final[0].extractionQueue?.first?.state == .exhausted)
        }
        print("PASS queue: " + mode)
    }
    static func main() async throws {
        for mode in ["complete", "noFileID", "existingSource", "noOutputHash", "cancelled", "otherAccount", "otherParent", "legacy", "unknownSubmission", "deleteTimeout", "outputHashMismatch", "largeBaseline", "duplicateBaseline"] { try await run(mode) }
    }
}
