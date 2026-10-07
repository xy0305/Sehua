import Foundation

final class RecoveryProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var rows: [[String: Any]] = []
    nonisolated(unsafe) static var leaf = "fixture_tid-12"
    nonisolated(unsafe) static var posts = 0
    nonisolated(unsafe) static var createSuccess = false
    nonisolated(unsafe) static var incomplete = false
    nonisolated(unsafe) static var badPath = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.httpMethod != "GET" {
            Self.posts += 1
            if Self.createSuccess {
                let data = try! JSONSerialization.data(withJSONObject: ["state":true,"cid":"20"])
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } else { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
            return
        }
        let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let cid = q.first { $0.name == "cid" }!.value!
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
        defer { RecoveryProtocol.createSuccess = false; RecoveryProtocol.incomplete = false; RecoveryProtocol.badPath = false }
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
        } catch { precondition(blocked || !success) }
        let saved = await service.resources()
        precondition(saved[0].tasks.count == tasks.count)
        let expected = blocked || !rows.isEmpty ? 0 : 1
        precondition(RecoveryProtocol.posts == expected)
        if expected == 1 {
            precondition(saved[0].directoryJournal?.count == 1 && saved[0].directoryJournal?[0].historicalPending == true)
            precondition(saved[0].directoryJournal?[0].state == (recovered ? .accepted : .unknown))
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
        precondition(records[0].directoryJournal?[0].state == .unknown && records[0].directoryWritePending)
    }
    static func main() async throws {
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
