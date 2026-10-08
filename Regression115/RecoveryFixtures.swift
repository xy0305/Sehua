import Foundation

final class RecoveryProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var rows: [[String: Any]] = []
    nonisolated(unsafe) static var leaf = "fixture_tid-12"
    nonisolated(unsafe) static var posts = 0
    nonisolated(unsafe) static var createSuccess = false
    nonisolated(unsafe) static var incomplete = false
    nonisolated(unsafe) static var postReadFailure = false
    nonisolated(unsafe) static var badPath = false
    nonisolated(unsafe) static var failureMode = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.httpMethod != "GET" {
            Self.posts += 1
            if !Self.failureMode.isEmpty {
                let body = Self.failureMode == "large" ? "{\"state\":true,\"cid\":3535200293442553007}" : (Self.failureMode == "json" ? "SECRET_COOKIE_URL_BODY" : (Self.failureMode == "cid" ? "{\"state\":true,\"cid\":\"SECRET_NAME\"}" : "{\"state\":false,\"errno\":7}"))
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.failureMode == "http" ? 503 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
                return
            }
            if Self.createSuccess {
                let data = try! JSONSerialization.data(withJSONObject: ["state":true,"cid":"20"])
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } else { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
            return
        }
        let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let cid = q.first { $0.name == "cid" }!.value!
        if cid != "10" && Self.postReadFailure {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let offset = Int(q.first { $0.name == "offset" }!.value!)!
        var path: [[String: Any]] = [["cid":"0"], ["cid":"10"]]
        if cid != "10" { path.append(["cid":cid, "name":Self.leaf]) }
        let rows = cid == "10" ? Self.rows : []
        if Self.badPath { path = [["cid":"0"], ["cid":"99"]] }
        let obj: [String: Any] = ["state":true,"count":Self.incomplete ? rows.count + 1 : rows.count,"data":rows,"path":path,"offset":offset,"limit":100,"order":"file_name","is_asc":1,"fc_mix":1]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct RecoveryFixtures {
    static func run(cid: String? = nil, rows: [[String: Any]], leaf: String = "fixture_tid-12", success: Bool, unknownTask: Bool = false) async throws {
        RecoveryProtocol.rows = rows; RecoveryProtocol.leaf = leaf; RecoveryProtocol.posts = 0
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecoveryProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        let link = "https://example.invalid/private-body"
        let task = SHT115Task(id: UUID(), urls: [link], state: .unknown, progress: [], updatedAt: Date())
        let record = SHT115Resource(id: "fixture", account: settings.account, tid: "12", directoryName: "fixture_tid-12", parentCID: "10", directoryCID: cid, directoryWritePending: true, tasks: unknownTask ? [task] : [])
        try JSONEncoder().encode([record]).write(to: store)
        let service = try SHT115Service(storeURL: store, session: session)
        do {
            let recovered = try await service.reconcileDirectory(resourceID: record.id, settings: settings)
            precondition(success && recovered.directoryCID == "20" && !recovered.directoryWritePending)
        } catch { precondition(!success) }
        let saved = await service.resources()
        precondition(saved[0].directoryWritePending == !success)
        if unknownTask {
            precondition(saved[0].tasks[0].state == .unknown)
            do { _ = try await service.submit(urls: [link], resourceID: record.id, settings: settings); preconditionFailure("unknown task must not replay") }
            catch let error as SHT115Diagnostic { precondition(error.stage == "offline-reconcile") }
        }
        if !success {
            do { _ = try await service.createOrReuseResource(tid: "12", title: "fixture", settings: settings); preconditionFailure("pending must not replay") } catch {}
        }
        let diagnostic = await service.safeDiagnostic(tid: "12", settings: settings)
        precondition(!diagnostic.contains("fake") && !diagnostic.contains(link) && !diagnostic.contains("UID=") && diagnostic.contains("父CID=10"))
        precondition(RecoveryProtocol.posts == 0, "recovery and duplicate guards must issue no POST")
    }
    static func rebuild(rows: [[String: Any]] = [], success: Bool = false, taskState: SHT115SubmissionState? = nil, incomplete: Bool = false, badPath: Bool = false, wrong: String = "", leaf: String = "fixture_tid-12") async throws {
        RecoveryProtocol.rows = rows; RecoveryProtocol.leaf = leaf; RecoveryProtocol.posts = 0
        RecoveryProtocol.createSuccess = success; RecoveryProtocol.incomplete = incomplete; RecoveryProtocol.badPath = badPath
        RecoveryProtocol.postReadFailure = success && leaf == "post-read-failure"
        defer { RecoveryProtocol.postReadFailure = false; RecoveryProtocol.createSuccess = false; RecoveryProtocol.incomplete = false; RecoveryProtocol.badPath = false }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecoveryProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        let tasks = taskState.map { [SHT115Task(id: UUID(), urls: ["https://example.invalid/private"], state: $0, progress: [], updatedAt: Date())] } ?? []
        let record = SHT115Resource(id: "fixture", account: settings.account, tid: "12", directoryName: "fixture_tid-12", parentCID: "10", directoryCID: nil, directoryWritePending: true, tasks: tasks)
        try JSONEncoder().encode([record]).write(to: store)
        let service = try SHT115Service(storeURL: store, session: session)
        let authorization = UUID()
        let input = SHT115Settings(cookie: wrong == "account" ? "UID=456_A1; CID=fake; SEID=fake" : settings.cookie, parentCID: wrong == "parent" ? "11" : "10")
        let blocked = taskState != nil || incomplete || badPath || !wrong.isEmpty || leaf.isEmpty || rows.count > 1
        var recovered = false
        do {
            let result = try await service.confirmDirectoryRebuild(resourceID: record.id, tid: wrong == "tid" ? "13" : "12", settings: input, authorization: authorization)
            recovered = true
            precondition(!blocked && (success || !rows.isEmpty) && result.directoryCID == "20" && !result.directoryWritePending)
        } catch { precondition(blocked || !success || RecoveryProtocol.postReadFailure) }
        let saved = await service.resources()
        precondition(saved[0].tasks.count == tasks.count)
        let expected = blocked || !rows.isEmpty ? 0 : 1
        precondition(RecoveryProtocol.posts == expected)
        if expected == 1 {
            precondition(saved[0].directoryJournal?.count == 1 && saved[0].directoryJournal?[0].historicalPending == true)
            precondition(saved[0].directoryJournal?[0].state == (success ? .accepted : .unknown))
            if RecoveryProtocol.postReadFailure {
                precondition(saved[0].directoryCID == "20" && saved[0].directoryWritePending && saved[0].directoryCreatedAwaitingPath)
                precondition(saved[0].directoryRecoveryOnly == true)
                let evidence = saved[0].directoryJournal?[0].evidence
                precondition(evidence?.httpStatus == 200 && evidence?.response == "success-state" && evidence?.cid == "20" && evidence?.path == "pending" && evidence?.pathError == "http-read")
            }
            precondition(saved[0].manualRecoveryLocked == !success)
        } else { precondition(saved[0].directoryJournal == nil, "historical pending must not gain invented attempts") }
        // Restart from the real production persistence file; both same and new authorization must not replay an unknown recovery.
        let restarted = try SHT115Service(storeURL: store, session: session)
        if expected == 1 {
            for id in [authorization, UUID()] {
                do { _ = try await restarted.confirmDirectoryRebuild(resourceID: record.id, tid: "12", settings: settings, authorization: id); preconditionFailure("recovery replay") } catch {}
            }
        }
        precondition(RecoveryProtocol.posts == expected)
        let afterRestart = await restarted.resources()
        precondition(afterRestart[0].directoryWritePending == !recovered)
        let diagnostic = await restarted.safeDiagnostic(tid: "12", settings: settings)
        precondition(!diagnostic.contains("fixture_tid") && !diagnostic.contains("fake") && !diagnostic.contains("example.invalid"))
        if RecoveryProtocol.postReadFailure {
            RecoveryProtocol.postReadFailure = false
            RecoveryProtocol.leaf = "wrong-name"
            do { _ = try await restarted.reconcileDirectory(resourceID: record.id, settings: settings); preconditionFailure("identity weakened") } catch {}
            let stillLocked = await restarted.resources()
            precondition(stillLocked[0].directoryWritePending && stillLocked[0].directoryJournal?[0].state == .accepted)
            RecoveryProtocol.leaf = "fixture_tid-12"
            let verified = try await restarted.reconcileDirectory(resourceID: record.id, settings: settings)
            precondition(!verified.directoryWritePending && verified.directoryJournal?[0].evidence?.path == "verified")
            let again = try SHT115Service(storeURL: store, session: session)
            let finalRecords = await again.resources()
            precondition(!finalRecords[0].directoryWritePending && RecoveryProtocol.posts == 1)
        }
    }
    static func restartSubmitting() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        var record = SHT115Resource(id: "fixture", account: settings.account, tid: "12", directoryName: "fixture_tid-12", parentCID: "10", directoryCID: nil, directoryWritePending: true, tasks: [])
        record.directoryJournal = [SHT115DirectoryAttempt(authorization: UUID(), authorizedAt: Date(), manualRecovery: true, historicalPending: true, state: .submitting)]
        try JSONEncoder().encode([record]).write(to: store)
        let restarted = try SHT115Service(storeURL: store)
        let records = await restarted.resources()
        precondition(records[0].directoryJournal?[0].state == .unknown && records[0].directoryWritePending && records[0].manualRecoveryLocked)
        let persisted = try JSONDecoder().decode([SHT115Resource].self, from: Data(contentsOf: store))
        precondition(persisted[0].directoryJournal?[0].state == .unknown && persisted[0].directoryWritePending)
    }
    static func evidenceFailures() async throws {
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        for (mode, phase, status) in [("http", "http", 503), ("json", "response-json", 200), ("cid", "cid", 200), ("rejected", "response", 200)] {
            RecoveryProtocol.failureMode = mode; RecoveryProtocol.rows = []; RecoveryProtocol.posts = 0
            defer { RecoveryProtocol.failureMode = "" }
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecoveryProtocol.self]
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: store) }
            let service = try SHT115Service(storeURL: store, session: session)
            do { _ = try await service.createOrReuseResource(tid: "12", title: "fixture", settings: settings); preconditionFailure("unsafe response") } catch {}
            let records = await service.resources()
            let attempt = records[0].directoryJournal![0]
            precondition(attempt.state == (mode == "rejected" ? .rejected : .unknown))
            precondition(attempt.evidence?.failurePhase == phase && attempt.evidence?.httpStatus == status && attempt.evidence?.cid == nil)
            let encoded = String(data: try JSONEncoder().encode(attempt), encoding: .utf8)!
            precondition(!encoded.contains("SECRET") && !encoded.contains("fixture") && !encoded.contains("fake"))
            precondition(RecoveryProtocol.posts == 1)
            let restarted = try SHT115Service(storeURL: store, session: session)
            let afterRestart = await restarted.resources()
            precondition(afterRestart[0].directoryJournal?[0].evidence?.failurePhase == phase)
            if mode != "rejected" {
                do { _ = try await restarted.createOrReuseResource(tid: "12", title: "fixture", settings: settings); preconditionFailure("unknown replay") } catch {}
                precondition(RecoveryProtocol.posts == 1)
            }
        }
        var poisoned = SHT115DirectoryEvidence()
        poisoned.request = "SECRET_URL"; poisoned.response = "SECRET_BODY"; poisoned.pathError = "SECRET_COOKIE"; poisoned.cid = "SECRET_NAME"
        precondition(!poisoned.safeSummary.contains("SECRET"))
    }
    static func largeAcknowledgedCID() async throws {
        RecoveryProtocol.failureMode = "large"; RecoveryProtocol.posts = 0; RecoveryProtocol.rows = []
        defer { RecoveryProtocol.failureMode = "" }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecoveryProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        let service = try SHT115Service(storeURL: store, session: session)
        let resource = try await service.createOrReuseResource(tid: "12", title: "fixture", settings: settings)
        precondition(resource.directoryCID == "3535200293442553007" && !resource.directoryWritePending)
        precondition(resource.directoryJournal?[0].state == .accepted && resource.directoryJournal?[0].evidence?.cid == resource.directoryCID && resource.directoryJournal?[0].evidence?.path == "verified")
        let restarted = try SHT115Service(storeURL: store, session: session)
        let saved = await restarted.resources()
        precondition(saved[0].directoryCID == resource.directoryCID && !saved[0].directoryWritePending && RecoveryProtocol.posts == 1)
    }
    static func main() async throws {
        try await largeAcknowledgedCID()
        try await evidenceFailures()
        try await restartSubmitting()
        let named: [String: Any] = ["cid":"20", "pid":"10", "n":"fixture_tid-12"]
        try await run(rows: [], success: false) // old pending, no directory
        try await run(rows: [named], success: true) // created, response lost
        try await run(cid: "20", rows: [], success: true) // known CID, fresh ancestry
        try await run(rows: [["cid":"20","pid":"10","n":""]], success: true) // blank listing, verified leaf
        try await run(rows: [["cid":"20","pid":"10","n":""]], leaf: "", success: false)
        try await run(rows: [named, ["cid":"21","pid":"10","n":"fixture_tid-12"]], success: false)
        try await run(rows: [named], success: true, unknownTask: true)
        try await rebuild(rows: [named]) // unique reuse: zero POST
        try await rebuild(success: true) // explicit recovery: single POST, fresh CID verified
        try await rebuild(success: true, leaf: "post-read-failure") // acknowledged POST stays accepted through read failure/restart
        try await rebuild() // timeout: durable unknown, same/new authority cannot replay
        for state in [SHT115SubmissionState.unknown, .submitting, .accepted] { try await rebuild(taskState: state) }
        try await rebuild(incomplete: true)
        try await rebuild(badPath: true)
        try await rebuild(rows: [["cid":"20","pid":"10","n":""]], leaf: "")
        try await rebuild(rows: [named, ["cid":"21","pid":"10","n":"fixture_tid-12"]])
        for wrong in ["account", "parent", "tid"] { try await rebuild(wrong: wrong) }
        print("PASS explicit rebuild: zero-POST reuse, single-POST create, durable unknown no replay, offline history blocks, incomplete/name/path/duplicate/identity blocks, restart and safe diagnostics")
        print("PASS read-only recovery: old pending/lost response/known CID/blank names/duplicate names/offline unknown; zero POST, sanitized diagnostics")
    }
}
