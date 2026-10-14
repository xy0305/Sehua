import Foundation

/// Production HTTP/Service + URLProtocol; no real 115 writes or credentials.
final class PushLatencyProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String] = []
    nonisolated(unsafe) static var starts: [Date] = []
    nonisolated(unsafe) static var slowSnapshot = false
    nonisolated(unsafe) static var signatureDelay = 0.05
    nonisolated(unsafe) static var postResponse = "{\"state\":true}"
    nonisolated(unsafe) static var parentCount = 0
    nonisolated(unsafe) static var journalURL: URL? = nil
    nonisolated(unsafe) static var folderName = ""
    nonisolated(unsafe) static var mkdirResponse = "{\"state\":true,\"cid\":\"20\"}"
    nonisolated(unsafe) static var wrongFolderName = false
    static func fields(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n))
            }
        }
        return Dictionary(uniqueKeysWithValues: String(decoding: data, as: UTF8.self).split(separator: "&").map {
            let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(pair[0]).removingPercentEncoding!, String(pair[1]).removingPercentEncoding!)
        })
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let isSnapshot = q.contains { $0.name == "o" }
        let route = q.contains { $0.name == "ac" && $0.value == "task_lists" } ? "taskGET" : url.path == "/files/add" ? "mkdir" : request.httpMethod == "POST" ? "POST" : url.path == "/files" ? (isSnapshot ? "snapshot" : "identity") : "signature"
        Self.routes.append(route); Self.starts.append(Date())
        if route == "taskGET" || (isSnapshot && Self.slowSnapshot) { return } // indefinitely pending read
        let text: String
        if route == "mkdir" {
            let fields = Self.fields(request)
            Self.folderName = fields["cname"]!
            precondition(fields["pid"] == "10")
            if let store = Self.journalURL {
                let saved = try! JSONDecoder().decode([SHT115Resource].self, from: Data(contentsOf: store))
                precondition(saved.contains { $0.directoryWritePending && $0.directoryJournal?.last?.state == .submitting }, "durable mkdir intent before POST")
            }
            if Self.mkdirResponse == "timeout" { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
            text = Self.mkdirResponse
        }
        else if route == "POST" {
            if let store = Self.journalURL {
                let saved = try! JSONDecoder().decode([SHT115Resource].self, from: Data(contentsOf: store))
                precondition(saved.contains { $0.tasks.contains { $0.state == .submitting } }, "durable journal before POST")
                precondition(Self.fields(request)["wp_path_id"] == "20", "offline POST must target new post CID, never parent")
            }
            text = Self.postResponse
        }
        else if route == "signature" { text = "{\"state\":true,\"sign\":\"fixture\",\"time\":1}" }
        else {
            let cid = q.first { $0.name == "cid" }?.value ?? "10"
            if cid == "20", let store = Self.journalURL {
                let saved = try! JSONDecoder().decode([SHT115Resource].self, from: Data(contentsOf: store))
                precondition(saved.contains { $0.directoryCID == "20" && $0.directoryJournal?.last?.state == .accepted }, "accepted mkdir CID must be durable before fresh verification")
            }
            let leaf = cid == "20" ? ",\"name\":\"\(Self.wrongFolderName ? "wrong" : Self.folderName)\"" : ""
            let path = cid == "20" ? "[{\"cid\":\"0\"},{\"cid\":\"10\"},{\"cid\":\"20\"\(leaf)}]" : "[{\"cid\":\"0\"},{\"cid\":\"10\"}]"
            text = "{\"state\":true,\"count\":\(cid == "20" ? 0 : Self.parentCount),\"data\":[],\"path\":\(path),\"offset\":0,\"limit\":100,\"order\":\"file_name\",\"is_asc\":1,\"fc_mix\":1}"
        }
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
        precondition(result.tasks.first?.state == .accepted && result.extractionQueue?.first?.sourceProofMissing == true)
        precondition(Date().timeIntervalSince(start) < 6, "pending snapshot must not block accepted feedback")
        precondition(PushLatencyProtocol.routes.contains("snapshot"), "slow snapshot must really have started before POST")
        precondition(!PushLatencyProtocol.routes.contains("taskGET"))
        let writes = PushLatencyProtocol.routes.filter { $0 == "POST" }.count
        do { _ = try await service.submit(urls: [link], resourceID: result.id, settings: settings); preconditionFailure("duplicate") } catch {}
        precondition(PushLatencyProtocol.routes.filter { $0 == "POST" }.count == writes)
        let readOnly = Task { try? await service.inspect(resourceID: result.id, settings: settings, background: true, includeFiles: false) }
        try await Task.sleep(nanoseconds: 2_700_000_000)
        precondition(PushLatencyProtocol.routes.contains("taskGET"), "slow task GET must really start after acceptance")
        let concurrentStart = Date()
        let concurrentLink = "magnet:?xt=urn:btih:" + String(repeating: "f", count: 40)
        let concurrent = try await service.submit(urls: [concurrentLink], resourceID: result.id, settings: settings)
        precondition(concurrent.tasks.last?.state == .accepted)
        precondition(Date().timeIntervalSince(concurrentStart) < 7, "never-ending background GET must not own push permit")
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
        let directStore = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directStore) }
        var historicalDirect = SHT115Resource(id: "old-direct", account: settings.account, tid: "1278", directoryName: "legacy parent", parentCID: "10", directoryCID: "10", directoryWritePending: false, tasks: [])
        historicalDirect.directInput = true
        try JSONEncoder().encode([historicalDirect]).write(to: directStore)
        let directService = try SHT115Service(storeURL: directStore, session: session)
        PushLatencyProtocol.parentCount = 1278
        PushLatencyProtocol.journalURL = directStore
        PushLatencyProtocol.routes = []; PushLatencyProtocol.starts = []
        let directStart = Date()
        let direct = try await directService.createAndSubmitResource(urls: [link], tid: "1278", title: "post", settings: settings, autoExtraction: true)
        precondition(direct.directInput != true && direct.tid == "1278" && direct.directoryCID == "20" && direct.directoryName == "post_tid-1278")
        precondition(direct.extractionQueue?.count == 1 && direct.extractionQueue?.first?.priorIDs == [] && direct.extractionQueue?.first?.sourceProofMissing == false, "fresh empty creation GET is pre-POST source proof; no later snapshot")
        precondition(PushLatencyProtocol.routes == ["identity", "mkdir", "identity", "signature", "POST"], "0 parent enumeration, 0 task preflight, mkdir exactly once")
        print("PASS post-folder 1278-parent controlled production routes=\(PushLatencyProtocol.routes) seconds=\(Date().timeIntervalSince(directStart))")
        for pair in zip(PushLatencyProtocol.starts, PushLatencyProtocol.starts.dropFirst()) {
            precondition(pair.1.timeIntervalSince(pair.0) >= 1.08)
        }
        PushLatencyProtocol.routes = []
        let reused = try await directService.createOrReuseResource(tid: "1278", title: "post", settings: settings)
        precondition(reused.directoryCID == "20" && PushLatencyProtocol.routes == ["identity"], "existing proven CID reused with fresh name/parent path, no mkdir")
        PushLatencyProtocol.routes = []
        do { _ = try await directService.createAndSubmitResource(urls: [link + "&dn=renamed"], tid: "1279", title: "other", settings: settings); preconditionFailure("cross-post hash lock") } catch {}
        precondition(PushLatencyProtocol.routes.isEmpty, "local hash lock must precede any requests")
        PushLatencyProtocol.postResponse = "{\"state\":true,\"result\":[{\"state\":true},{\"state\":false}]}"
        let b = "magnet:?xt=urn:btih:" + String(repeating: "b", count: 40)
        let c = "magnet:?xt=urn:btih:" + String(repeating: "c", count: 40)
        PushLatencyProtocol.routes = []
        do { _ = try await directService.createAndSubmitResource(urls: [b, c], tid: "1280", title: "partial", settings: settings); preconditionFailure("partial acceptance is unknown") } catch {}
        precondition(PushLatencyProtocol.routes == ["identity", "mkdir", "identity", "signature", "POST"])
        PushLatencyProtocol.routes = []
        let restarted = try SHT115Service(storeURL: directStore, session: session)
        do { _ = try await restarted.createAndSubmitResource(urls: [b], tid: "1281", title: "cross post", settings: settings); preconditionFailure("unknown replay after restart") } catch {}
        precondition(PushLatencyProtocol.routes.isEmpty)
        let oldStore = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: oldStore) }
        let legacy = SHT115Resource(id: "legacy", account: settings.account, tid: "77", directoryName: "old_tid-77", parentCID: "10", directoryCID: "99", directoryWritePending: true, tasks: [SHT115Task(id: UUID(), urls: [b], state: .unknown, progress: [], updatedAt: Date())])
        try JSONEncoder().encode([legacy]).write(to: oldStore)
        let legacyService = try SHT115Service(storeURL: oldStore, session: session)
        do { _ = try await legacyService.createAndSubmitResource(urls: [b], tid: "78", title: "legacy lock", settings: settings); preconditionFailure("legacy unknown bypass") } catch {}
        precondition(PushLatencyProtocol.routes.isEmpty)
        let retained = await legacyService.resources().first { $0.id == "legacy" }
        precondition(retained?.directoryCID == "99" && retained?.directoryWritePending == true && retained?.tasks.first?.state == .unknown)
        let pendingStore = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pendingStore) }
        let pendingDirectory = SHT115Resource(id: "old-unknown", account: settings.account, tid: "950", directoryName: "old_tid-950", parentCID: "10", directoryCID: nil, directoryWritePending: true, tasks: [])
        try JSONEncoder().encode([pendingDirectory]).write(to: pendingStore)
        let pendingService = try SHT115Service(storeURL: pendingStore, session: session)
        PushLatencyProtocol.routes = []
        do { _ = try await pendingService.createAndSubmitResource(urls: [c], tid: "950", title: "changed", settings: settings); preconditionFailure("old directory unknown bypass") } catch {}
        precondition(PushLatencyProtocol.routes.isEmpty, "old directory unknown must not trigger reads, mkdir, sign or offline write")
        PushLatencyProtocol.postResponse = "{\"state\":true}"
        for response in ["{\"state\":false,\"errno\":20004}", "timeout"] {
            let failureStore = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: failureStore) }
            PushLatencyProtocol.journalURL = failureStore; PushLatencyProtocol.mkdirResponse = response
            PushLatencyProtocol.routes = []
            let failed = try SHT115Service(storeURL: failureStore, session: session)
            do { _ = try await failed.createAndSubmitResource(urls: [c], tid: "900", title: "conflict", settings: settings); preconditionFailure("mkdir failure") } catch {}
            precondition(PushLatencyProtocol.routes == ["identity", "mkdir"], "mkdir conflict/timeout must stop before sign/offline POST")
            PushLatencyProtocol.routes = []
            let recovered = try SHT115Service(storeURL: failureStore, session: session)
            do { _ = try await recovered.createAndSubmitResource(urls: [c], tid: "900", title: "renamed", settings: settings); preconditionFailure("mkdir replay") } catch {}
            precondition(PushLatencyProtocol.routes.isEmpty, "conflict and timeout survive restart and changed title without retry")
        }
        PushLatencyProtocol.mkdirResponse = "{\"state\":true,\"cid\":\"20\"}"
        let acceptedStore = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: acceptedStore) }
        PushLatencyProtocol.journalURL = acceptedStore; PushLatencyProtocol.wrongFolderName = true; PushLatencyProtocol.routes = []
        let acceptedService = try SHT115Service(storeURL: acceptedStore, session: session)
        do { _ = try await acceptedService.createAndSubmitResource(urls: [c], tid: "901", title: "accepted", settings: settings); preconditionFailure("wrong mkdir path name") } catch {}
        precondition(PushLatencyProtocol.routes == ["identity", "mkdir", "identity"])
        let acknowledged = await acceptedService.resources()
        precondition(acknowledged[0].directoryCID == "20" && acknowledged[0].directoryJournal?.last?.state == .accepted && acknowledged[0].directoryWritePending)
        PushLatencyProtocol.routes = []
        let wrongAccount = SHT115Settings(cookie: "UID=456_A; CID=fixture; SEID=fixture", parentCID: "10")
        do { _ = try await acceptedService.submit(urls: [c], resourceID: acknowledged[0].id, settings: wrongAccount); preconditionFailure("account mismatch") } catch {}
        precondition(PushLatencyProtocol.routes.isEmpty)
        PushLatencyProtocol.wrongFolderName = false
        let acceptedRestart = try SHT115Service(storeURL: acceptedStore, session: session)
        _ = try await acceptedRestart.createAndSubmitResource(urls: [c], tid: "901", title: "accepted", settings: settings)
        precondition(PushLatencyProtocol.routes == ["identity", "signature", "POST"], "acknowledged creation resumes with fresh path, no second mkdir")
        PushLatencyProtocol.postResponse = "{\"state\":true}"
        PushLatencyProtocol.journalURL = nil
        PushLatencyProtocol.parentCount = 0
        print("PASS post-folder 1278-parent: 0 parent pages/0 task preflight, single durable mkdir, POST to new CID, fresh reuse; conflict/timeout/accepted-read-failure restart and account/hash/partial/legacy locks")
        print("PASS account/target isolation: no cross-account proof cache; wrong target denied before POST")
        print("PASS production pending snapshot/task GET: accepted feedback preceded never-ending reads; durable missing-proof queue forbids write/delete; concurrent push accepted while background GET pending; duplicate blocked; FIFO priority/fairness/cancellation passed")
    }
}
