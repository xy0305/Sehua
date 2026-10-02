import Foundation

/// macOS: swiftc Integration115/{SHT115Models,SHT115Diagnostic,SHT115HTTP,SHT115Service}.swift Regression115/SequenceFixtures.swift -o /tmp/sequence115 && /tmp/sequence115
/// Mock only. Production pacer remains enabled (allow about 90 seconds).
final class SequenceProtocol: URLProtocol, @unchecked Sendable {
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
@main struct SequenceFixtures {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SequenceProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        let a = SHT115Resource(id: "a", account: settings.account, tid: "1", directoryName: "A_tid-1", parentCID: "10", directoryCID: "20", directoryWritePending: false, tasks: [])
        let b = SHT115Resource(id: "b", account: settings.account, tid: "2", directoryName: "B_tid-2", parentCID: "10", directoryCID: "30", directoryWritePending: false, tasks: [])
        try JSONEncoder().encode([a,b]).write(to: store)
        let service = try SHT115Service(storeURL: store, session: session)
        let lock = NSLock()
        var creates = 0, submits = 0, parses = 0
        var starts: [UInt64] = []
        SequenceProtocol.handler = { request in
            lock.lock(); defer { lock.unlock() }
            let now = DispatchTime.now().uptimeNanoseconds
            if let last = starts.last { precondition(now - last >= 900_000_000, "HTTP gap missing") }
            starts.append(now)
            let url = request.url!
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if url.path == "/files/add" { creates += 1; return "{\"state\":true,\"cid\":40}" }
            if url.path == "/files/push_extract" {
                if request.httpMethod == "POST" { parses += 1; throw URLError(.networkConnectionLost) }
                return "{\"state\":true,\"data\":{\"extract_status\":{\"unzip_status\":1,\"progress\":1}}}"
            }
            if q.contains(where: { $0.name == "ac" && $0.value == "space" }) { return "{\"sign\":\"mock\",\"time\":1}" }
            if q.contains(where: { $0.name == "ac" && $0.value == "add_task_url" }) { submits += 1; return "{\"state\":true}" }
            if url.path == "/files" {
                let cid = q.first { $0.name == "cid" }!.value!
                let path = cid == "10" ? "[{\"cid\":0},{\"cid\":10}]" : "[{\"cid\":0},{\"cid\":10},{\"cid\":\(cid)}]"
                let data = cid == "20" ? "[{\"fid\":50,\"cid\":20,\"n\":\"a.zip\",\"pc\":\"pickA\"}]" : "[]"
                return "{\"state\":true,\"data\":\(data),\"count\":\(cid == "20" ? 1 : 0),\"path\":\(path)}"
            }
            return "{\"state\":true,\"tasks\":[]}"
        }
        let first = Task { try await service.listVideos(resourceID: "a", settings: settings, background: true) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let background = Task { try await service.inspect(resourceID: "b", settings: settings, background: true) }
        let push = Task {
            let c = try await service.createOrReuseResource(tid: "3", title: "C", settings: settings)
            return try await service.submit(urls: ["magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)], resourceID: c.id, settings: settings)
        }
        let listing = try await first.value
        _ = try await background.value
        let c = try await push.value
        precondition(c.tasks.first?.state == .accepted)
        let archive = listing.archives.first!
        let extraction = Task { try await service.requestExtraction(archive: archive, resourceID: "a", settings: settings, confirmed: true, background: true) }
        let next = Task { try await service.submit(urls: ["magnet:?xt=urn:btih:" + String(repeating: "b", count: 40)], resourceID: "b", settings: settings) }
        do { _ = try await extraction.value; preconditionFailure("lost POST should be unknown") }
        catch SHT115Error.uncertainWrite { }
        _ = try await next.value
        async let ra = service.inspect(resourceID: "a", settings: settings, background: true)
        async let rb = service.inspect(resourceID: "b", settings: settings, background: true)
        _ = try await (ra, rb)
        let outcome = try await service.requestExtraction(archive: archive, resourceID: "a", settings: settings, confirmed: true, background: true)
        precondition(outcome.state == .unknown)
        precondition(creates == 1 && submits == 2 && parses == 1, "unknown POST replayed")
        let cancelled = Task { try await service.inspect(resourceID: "a", settings: settings, background: true) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancel ignored") } catch is CancellationError { }
        _ = try await service.listVideos(resourceID: "b", settings: settings)
        print("PASS: multi-resource refresh/create/submit/extraction interleaving; unknown POST once; pacing; cancellation permit release")
    }
}
