import Foundation

/// Production HTTP/Service + URLProtocol; no real 115 writes or credentials.
final class PushLatencyProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String] = []
    nonisolated(unsafe) static var starts: [Date] = []
    nonisolated(unsafe) static var slowSnapshot = false
    nonisolated(unsafe) static var signatureDelay = 0.05
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let isSnapshot = q.contains { $0.name == "o" }
        let route = q.contains { $0.name == "ac" && $0.value == "task_lists" } ? "taskGET" : request.httpMethod == "POST" ? "POST" : url.path == "/files" ? (isSnapshot ? "snapshot" : "identity") : "signature"
        Self.routes.append(route); Self.starts.append(Date())
        if route == "taskGET" || (isSnapshot && Self.slowSnapshot) { return } // indefinitely pending read
        let text: String
        if route == "POST" { text = "{\"state\":true}" }
        else if route == "signature" { text = "{\"state\":true,\"sign\":\"fixture\",\"time\":1}" }
        else { text = "{\"state\":true,\"count\":0,\"data\":[],\"path\":[{\"cid\":\"0\"},{\"cid\":\"10\"}],\"offset\":0,\"limit\":100,\"order\":\"file_name\",\"is_asc\":1,\"fc_mix\":1}" }
        DispatchQueue.global().asyncAfter(deadline: .now() + (route == "signature" ? Self.signatureDelay : 0.05)) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
actor GrantLog {
    var values: [String] = []
    func add(_ s: String) { values.append(s) }
}
@main struct PushLatencyFixtures {
    static func main() async throws {
        // Isolated production pacer: never interrupt a granted request; prioritize
        // pending interactive requests, FIFO within class, bounded background wait.
        let pacer = SHT115RequestPacer(), log = GrantLog()
        try await pacer.wait()
        let bg = Task { try await pacer.wait(); await log.add("background") }
        try await Task.sleep(nanoseconds: 50_000_000)
        var fg: [Task<Void, Error>] = []
        for n in 1...4 {
            fg.append(Task { try await pacer.wait(interactive: true); await log.add("i\(n)") })
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let cancelled = Task { try await pacer.wait(interactive: true); preconditionFailure("cancelled waiter granted") }
        try await Task.sleep(nanoseconds: 30_000_000); cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("cancellation") } catch is CancellationError {}
        try await bg.value; for item in fg { try await item.value }
        let grants = await log.values
        precondition(grants == ["i1", "i2", "i3", "background", "i4"], "priority/FIFO/fairness: \(grants)")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PushLatencyProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let settings = SHT115Settings(cookie: "UID=123_A; CID=fixture; SEID=fixture", parentCID: "10")
        let link = "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)
        let http = SHT115HTTP(session: session)
        try await http.verify(cid: "10", parent: nil, settings: settings)
        var elapsed: [Double] = []
        for combined in [false, true] {
            let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: store) }
            let service = try SHT115Service(storeURL: store, session: session)
            PushLatencyProtocol.routes = []; PushLatencyProtocol.starts = []
            let start = Date()
            let result: SHT115Resource
            if combined {
                result = try await service.prepareAndSubmitManual(urls: [link], settings: settings, targetCID: "10")
            } else {
                let prepared = try await service.prepareManualResource(settings: settings)
                result = try await service.submit(urls: [link], resourceID: prepared.id, settings: settings)
            }
            elapsed.append(Date().timeIntervalSince(start))
            precondition(result.tasks.first?.state == .accepted)
            precondition(PushLatencyProtocol.routes == (combined ? ["identity", "signature", "POST"] : ["identity", "identity", "signature", "POST"]))
            for pair in zip(PushLatencyProtocol.starts, PushLatencyProtocol.starts.dropFirst()) {
                precondition(pair.1.timeIntervalSince(pair.0) >= 1.08, "1.1s safety pacing must remain")
            }
            print("PASS controlled \(combined ? "new" : "old") routes=\(PushLatencyProtocol.routes) seconds=\(elapsed.last!)")
        }
        precondition(elapsed[0] - elapsed[1] > 0.7)
        PushLatencyProtocol.slowSnapshot = true
        PushLatencyProtocol.signatureDelay = 1.3
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let service = try SHT115Service(storeURL: store, session: session)
        PushLatencyProtocol.routes = []
        let start = Date()
        let result = try await service.prepareAndSubmitManual(urls: [link], settings: settings, targetCID: "10", autoExtraction: true)
        precondition(result.tasks.first?.state == .accepted && (result.extractionQueue ?? []).isEmpty)
        precondition(Date().timeIntervalSince(start) < 6, "pending snapshot must not block accepted feedback")
        precondition(PushLatencyProtocol.routes.contains("snapshot"), "slow snapshot must really have started before POST")
        precondition(!PushLatencyProtocol.routes.contains("taskGET"))
        let writes = PushLatencyProtocol.routes.filter { $0 == "POST" }.count
        do { _ = try await service.submit(urls: [link], resourceID: result.id, settings: settings); preconditionFailure("duplicate") } catch {}
        precondition(PushLatencyProtocol.routes.filter { $0 == "POST" }.count == writes)
        let readOnly = Task { try? await service.inspect(resourceID: result.id, settings: settings, includeFiles: false) }
        try await Task.sleep(nanoseconds: 2_700_000_000)
        precondition(PushLatencyProtocol.routes.contains("taskGET"), "slow task GET must really start after acceptance")
        readOnly.cancel()
        _ = await readOnly.value
        PushLatencyProtocol.slowSnapshot = false; PushLatencyProtocol.signatureDelay = 0.05
        PushLatencyProtocol.routes = []
        let other = SHT115Settings(cookie: "UID=456_A; CID=fixture; SEID=fixture", parentCID: "10")
        let foreign = try await service.prepareAndSubmitManual(urls: [link], settings: other, targetCID: "10")
        precondition(foreign.account != result.account && foreign.id != result.id)
        precondition(PushLatencyProtocol.routes == ["identity", "signature", "POST"], "account change must obtain new identity/signature")
        PushLatencyProtocol.routes = []
        do { _ = try await service.prepareAndSubmitManual(urls: [link], settings: settings, targetCID: "20"); preconditionFailure("mismatched target accepted") } catch {}
        precondition(PushLatencyProtocol.routes == ["identity"], "target mismatch must stop before signature/write")
        print("PASS account/target isolation: no cross-account proof cache; wrong target denied before POST")
        print("PASS production pending snapshot/task GET: accepted feedback preceded never-ending reads; no post-submit snapshot authorization, no extraction queue; duplicate blocked; FIFO priority/fairness/cancellation passed")
    }
}
