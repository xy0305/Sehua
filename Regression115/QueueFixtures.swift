import Foundation

final class QueueMock: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> String)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let text = try Self.handler(request)
            if text == "PENDING_PARSE" { return }
            let deliver = { [self] in
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(text.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            // Do not block URLProtocol's serial loading queue while snapshot runs.
            if request.url?.absoluteString.contains("ac=space") == true {
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.5, execute: DispatchWorkItem(block: deliver))
            } else { deliver() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct QueueFixtures {
    static func run(_ mode: String) async throws {
        defer { UserDefaults.standard.removeObject(forKey: SHT115ExtractionPolicy.enabledKey) }
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
        var submitted = false, released = false, deletes = 0, parses = 0, taskReads = 0
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
                taskReads += 1
                if mode == "downloadingFirst", taskReads == 1 {
                    return "{\"state\":true,\"page_count\":1,\"tasks\":[{\"info_hash\":\"\(hash)\",\"wp_path_id\":20,\"status\":1,\"percentDone\":50}]}"
                }
                let fid = mode == "noFileID" ? "" : (mode == "targetCIDFileID" ? ",\"file_id\":20" : ",\"file_id\":21")
                let taskHash = mode == "taskHashMismatch" ? String(repeating: "e", count: 32) : hash
                return "{\"state\":true,\"page_count\":1,\"tasks\":[{\"info_hash\":\"\(taskHash)\",\"wp_path_id\":20,\"status\":2,\"percentDone\":100\(fid)}]}"
            }
            if path == "/files/push_extract" {
                if request.httpMethod == "POST" {
                    parses += 1
                    if mode == "slowParse" { return "PENDING_PARSE" }
                    if mode == "parseTimeout" { throw URLError(.timedOut) }
                    return "{\"state\":true}"
                }
                return "{\"state\":true,\"data\":{\"extract_status\":{\"unzip_status\":4,\"progress\":100}}}"
            }
            if path == "/files/extract_info" {
                let sha = mode == "noOutputHash" ? "" : ",\"sha1\":\"\(outputSHA)\""
                return "{\"state\":true,\"data\":{\"count\":1,\"next_marker\":\"\",\"list\":[{\"file_name\":\"movie.mp4\",\"size\":42,\"ico\":\"mp4\"\(sha)}]}}"
            }
            if path == "/files/add_extract_file" {
                if request.httpMethod == "POST" { released = true; return "{\"state\":true,\"data\":{\"extract_id\":900}}" }
                if mode == "disabledBeforeRecycle" { UserDefaults.standard.set(false, forKey: SHT115ExtractionPolicy.enabledKey) }
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
        if ["largeBaseline", "duplicateBaseline"].contains(mode) {
            precondition(saved[0].extractionQueue?.first?.sourceProofMissing == true)
        }
        if mode == "cancelled", let item = saved[0].extractionQueue?.first {
            try await restored.cancelExtractionQueue(resourceID: "q", queueID: item.id, settings: settings)
        }
        let input = mode == "otherAccount" ? SHT115Settings(cookie: "UID=456_A1; CID=fake; SEID=fake", parentCID: "10") :
            mode == "otherParent" ? SHT115Settings(cookie: settings.cookie, parentCID: "11") : settings
        let now = Date()
        if mode == "downloadingFirst" {
            try await restored.runExtractionQueue(settings: settings, now: now)
            let waiting = await restored.resources()[0].extractionQueue!.first!
            precondition(waiting.state == .waiting && parses == 0 && deletes == 0)
            precondition(waiting.nextAttempt.timeIntervalSince(now) == 20)
            let due = await restored.nextExtractionDue(settings: settings)
            precondition(due == waiting.nextAttempt)
            try await restored.runExtractionQueue(settings: settings, now: now.addingTimeInterval(1))
            precondition(taskReads == 1, "not due: zero HTTP requests, no busy polling")
            let driver = await SHT115ExtractionDriver()
            await driver.kick(eligible: { true }, next: { await restored.nextExtractionDue(settings: settings) }, run: {
                try! await restored.runExtractionQueue(settings: settings)
            })
            // No second kick, no scene transition: production timer resumes the queue.
            for _ in 0..<1000 {
                if await restored.resources()[0].extractionQueue!.first!.state == .recycled { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            await driver.stop()
            let final = await restored.resources()[0].extractionQueue!.first!.state
            precondition(final == .recycled)
            precondition(parses == 1 && deletes == 1 && taskReads >= 2)
            print("PASS foreground: first download incomplete, 20s due timer resumes without kick/background, single parse/release/recycle")
            return
        }
        if mode == "slowParse" {
            let worker = Task { try await restored.runExtractionQueue(settings: input, now: now) }
            for _ in 0..<400 {
                if parses == 1 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            precondition(parses == 1, "production worker must reach real pending parse POST")
            let start = Date()
            let pushed = try await restored.submit(urls: ["ed2k://|file|next.zip|43|" + String(repeating: "d", count: 32) + "|/"], resourceID: "q", settings: settings)
            precondition(pushed.tasks.last?.state == .accepted && pushed.tasks.first?.state == .accepted)
            precondition(Date().timeIntervalSince(start) < 8 && !released && deletes == 0, "pending parse cannot block push or authorize cleanup")
            worker.cancel(); _ = try? await worker.value
            let restart = try SHT115Service(storeURL: store, session: session)
            let recovered = await restart.resources()[0]
            precondition(recovered.extractionQueue?.first?.source?.id == "21", "persist source before parse")
            precondition(recovered.extractions?["21"] == .unknown, "interrupted parse locked on restart")
            try await restart.runExtractionQueue(settings: settings, now: now.addingTimeInterval(301))
            precondition(parses == 1 && deletes == 0)
            print("PASS queue: slowParse; push accepted while parse pending; restart source restored; unknown not replayed; no delete")
            return
        }
        try await restored.runExtractionQueue(settings: input, now: now)
        try await restored.runExtractionQueue(settings: input, now: now.addingTimeInterval(301))
        let again = try SHT115Service(storeURL: store, session: session)
        try await again.runExtractionQueue(settings: input, now: now.addingTimeInterval(602))
        let shouldExtract = ["disabledBeforeRecycle", "complete", "noFileID", "noOutputHash", "deleteTimeout", "outputHashMismatch", "targetCIDFileID"].contains(mode)
        precondition(parses == (shouldExtract || mode == "parseTimeout" ? 1 : 0), mode + " parse")
        precondition(deletes == (["complete", "noFileID", "targetCIDFileID", "deleteTimeout"].contains(mode) ? 1 : 0), mode + " recycle")
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
        if ["existingSource", "outputHashMismatch", "taskHashMismatch"].contains(mode) {
            precondition(final[0].extractionQueue?.first?.state == .exhausted)
        }
        if mode == "parseTimeout" {
            precondition(final[0].tasks.first?.state == .accepted && final[0].extractionQueue?.first?.state == .retained)
            let next = try await again.submit(urls: ["ed2k://|file|next.zip|43|" + String(repeating: "d", count: 32) + "|/"], resourceID: "q", settings: settings)
            precondition(next.tasks.last?.state == .accepted && deletes == 0 && parses == 1)
        }
        print("PASS queue: " + mode)
    }
    @MainActor static func driverGuards() async throws {
        let driver = SHT115ExtractionDriver()
        var count = 0, enabled = true, due: Date? = Date()
        let operation: @MainActor () async -> Void = {
            count += 1
            due = Date().addingTimeInterval(300)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        driver.kick(eligible: { enabled }, next: { due }, run: operation)
        try await Task.sleep(nanoseconds: 50_000_000)
        due = Date() // new accepted queue during an old pass
        driver.kick(eligible: { enabled }, next: { due }, run: operation)
        try await Task.sleep(nanoseconds: 500_000_000)
        precondition(count == 2, "kick during pass must wake new due queue")
        due = Date()
        driver.kick(eligible: { enabled }, next: { due }, run: operation)
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(count == 3, "kick must wake sleeping worker")
        due = Date()
        enabled = false
        driver.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(count == 3, "stop prevents later requests")
        enabled = true
        driver.kick(eligible: { enabled }, next: { due }, run: {
            count += 1 // simulate failing pass that leaves a stale/past due date
        })
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(count == 4, "stale due must back off, never busy loop")
        driver.stop()
        print("PASS driver: kick during pass and sleep, cancellation/account-switch eligibility, stale-due backoff")
    }
    static func main() async throws {
        try await driverGuards()
        for mode in ["downloadingFirst", "slowParse", "parseTimeout", "disabledBeforeRecycle", "complete", "noFileID", "targetCIDFileID", "existingSource", "noOutputHash", "cancelled", "otherAccount", "otherParent", "legacy", "unknownSubmission", "deleteTimeout", "outputHashMismatch", "largeBaseline", "duplicateBaseline", "taskHashMismatch"] { try await run(mode) }
    }
}
