import Foundation

final class ManualProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated(unsafe) static var neverFinishSnapshot = false
    override func startLoading() {
        if Self.neverFinishSnapshot, URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "limit" && $0.value == "100" }) == true { return }
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct ManualPushFixtures {
    static let cid = "1234567890123456789"
    static let ed = "ed2k://|file|a.zip|123|0123456789abcdef0123456789abcdef|/"
    static let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=a%26b"
    static func body(_ request: URLRequest) -> String {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n))
            }
        }
        return String(data: data, encoding: .utf8)!
    }
    static func run(mode: String) async throws {
        ManualProtocol.neverFinishSnapshot = mode == "pending-snapshot"
        defer { ManualProtocol.neverFinishSnapshot = false }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ManualProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let settings = SHT115Settings(cookie: "UID=123_A; CID=fake; SEID=fake", parentCID: cid)
        let service = try SHT115Service(storeURL: store, session: session)
        var writes = 0
        var reads = 0
        ManualProtocol.handler = { request in
            let url = request.url!
            precondition(request.value(forHTTPHeaderField: "Cookie") == settings.cookie)
            var obj: [String: Any]
            if request.httpMethod == "POST" {
                precondition(url.absoluteString == "https://115.com/web/lixian/?ct=lixian&ac=add_task_urls") // never create folders, extract, delete or play
                writes += 1
                let payload = body(request)
                precondition(payload.contains("wp_path_id=" + cid))
                let fields = Dictionary(uniqueKeysWithValues: payload.split(separator: "&").map { part -> (String, String) in
                    let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    return (String(pair[0]).removingPercentEncoding!, String(pair[1]).removingPercentEncoding!)
                })
                precondition(fields["uid"] == "123" && fields["sign"] == "fake-sign")
                precondition(fields["url[0]"] == ed && fields["url[1]"] == magnet && fields["urls[0]"] == nil)
                precondition(!payload.contains("cname="))
                // Journal must already be durable before transport starts.
                let saved = try JSONDecoder().decode([SHT115Resource].self, from: Data(contentsOf: store))
                precondition(saved[0].tasks.last?.state == .submitting)
                if mode == "transport" { throw URLError(.timedOut) }
                if mode == "partial" { obj = ["state": true, "data": [["state": true, "url": ed]]] }
                else if mode == "wrong-identity" { obj = ["state": true, "data": [["state": true, "url": ed], ["state": true, "url": "magnet:?xt=urn:btih:" + String(repeating: "f", count: 40)]]] }
                else if ["accepted", "bad-snapshot", "pending-snapshot"].contains(mode) { obj = ["state": true, "data": [["state": true, "url": ed], ["state": true, "url": magnet]]] }
                else { obj = ["state": false, "errno": 10008] }
            } else if url.path == "/" {
                obj = ["state": true, "sign": "fake-sign", "time": "1"]
            } else {
                reads += 1
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                precondition(q.first { $0.name == "cid" }?.value == cid)
                obj = ["state": true, "count": 0, "data": [], "path": [["cid": "0"], ["cid": mode == "bad-path" ? "9" : cid]], "offset": 0, "limit": 100, "order": "file_name", "is_asc": 1, "fc_mix": 1]
            }
            if mode == "bad-snapshot", url.path == "/files" { obj.removeValue(forKey: "offset"); obj.removeValue(forKey: "limit"); obj.removeValue(forKey: "order"); obj.removeValue(forKey: "is_asc") }
            return try JSONSerialization.data(withJSONObject: obj)
        }
        if mode == "bad-path" {
            do { _ = try await service.prepareManualResource(settings: settings); preconditionFailure("bad path") } catch {}
            precondition(writes == 0)
            return
        }
        let resource = try await service.prepareManualResource(settings: settings)
        precondition(resource.manualInput == true && resource.tid.isEmpty && resource.directoryCID == cid)
        precondition(writes == 0)
        let again = try await service.prepareManualResource(settings: settings)
        precondition(again.id == resource.id)
        let otherSettings = SHT115Settings(cookie: "UID=456_A; CID=fake; SEID=fake", parentCID: "99")
        do { _ = try await service.submit(urls: [ed], resourceID: resource.id, settings: otherSettings); preconditionFailure("path changed") } catch {}
        for invalid in [[], ["https://example.invalid/password"], ["magnet:?xt=invalid"], [magnet.replacingOccurrences(of: "magnet:", with: "https://example.invalid/")], [ed.replacingOccurrences(of: "|/", with: "|bad|/")]] {
            do { _ = try await service.submit(urls: invalid, resourceID: resource.id, settings: settings); preconditionFailure("invalid") } catch {}
        }
        precondition(writes == 0)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await service.submit(urls: [ed, magnet], resourceID: resource.id, settings: settings); preconditionFailure("cancelled write") }
            catch is CancellationError {} catch { preconditionFailure("expected cancellation") }
        }
        await cancelled.value
        let afterCancel = await service.resources()
        precondition(writes == 0 && afterCancel.first!.tasks.isEmpty)
        let start = Date()
        do { _ = try await service.submit(urls: [ed, ed, magnet], resourceID: resource.id, settings: settings, autoExtraction: true) }
        catch { precondition(mode != "accepted") }
        if mode == "pending-snapshot" { precondition(Date().timeIntervalSince(start) < 8, "unfinished snapshot must not block POST") }
        var saved = await service.resources().first!
        precondition(writes == 1 && saved.tasks.count == 1 && saved.tasks[0].urls.count == 2)
        precondition(saved.tasks[0].state == (["accepted", "bad-snapshot", "pending-snapshot"].contains(mode) ? .accepted : mode == "rejected" ? .rejected : .unknown))
        precondition((saved.extractionQueue ?? []).count == (mode == "accepted" ? 2 : 0))
        if mode != "rejected" {
            do { _ = try await service.submit(urls: [ed], resourceID: resource.id, settings: settings); preconditionFailure("repeated") } catch {}
            precondition(writes == 1)
            let renamed = ed.replacingOccurrences(of: "a.zip", with: "renamed.zip").replacingOccurrences(of: "|123|", with: "|999|")
            let tracker = magnet + "&tr=https%3A%2F%2Ftracker.invalid%2Fa"
            let hybrid = "magnet:?xt=urn:btmh:1220" + String(repeating: "a", count: 64) + "&xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
            for variant in [renamed, tracker, hybrid] {
                do { _ = try await service.submit(urls: [variant], resourceID: resource.id, settings: settings); preconditionFailure("identity bypass") } catch {}
                precondition(writes == 1)
            }
            let restarted = try SHT115Service(storeURL: store, session: session)
            let restored = try await restarted.prepareManualResource(settings: settings)
            precondition(restored.id == resource.id)
            do { _ = try await restarted.submit(urls: [magnet], resourceID: restored.id, settings: settings); preconditionFailure("restart repeated") } catch {}
            precondition(writes == 1)
            // Read-only reconciliation does not clear unknown task locks.
            _ = try await restarted.reconcileDirectory(resourceID: restored.id, settings: settings)
            saved = await restarted.resources().first!
            precondition(saved.tasks[0].state == (["accepted", "bad-snapshot", "pending-snapshot"].contains(mode) ? .accepted : .unknown))
            // A post record cannot bypass a manual unknown/accepted task lock either.
            var post = SHT115Resource(id: "post", account: settings.account, tid: "123", directoryName: "test_tid-123", parentCID: cid, directoryCID: "77", directoryWritePending: false, tasks: [])
            post.directoryJournal = []
            try JSONEncoder().encode([saved, post]).write(to: store, options: .atomic)
            let mixed = try SHT115Service(storeURL: store, session: session)
            do { _ = try await mixed.submit(urls: [ed], resourceID: post.id, settings: settings); preconditionFailure("post bypass") } catch {}
            precondition(writes == 1)
            // Original post locks survive entering a fresh manual record.
            post.tasks = saved.tasks
            saved.tasks = []; saved.extractionQueue = []
            try JSONEncoder().encode([saved, post]).write(to: store, options: .atomic)
            let originalLocked = try SHT115Service(storeURL: store, session: session)
            do { _ = try await originalLocked.submit(urls: [ed], resourceID: saved.id, settings: settings); preconditionFailure("manual bypass of original post") } catch {}
            precondition(writes == 1)
            // Different hashes are not blocked by a same-name/same-size resource.
            // A different account's old task is not a lock on this account either.
            ManualProtocol.handler = { request in
                precondition(request.httpMethod != "POST")
                throw URLError(.notConnectedToInternet)
            }
            let different = ed.replacingOccurrences(of: "0123456789abcdef0123456789abcdef", with: String(repeating: "f", count: 32))
            do { _ = try await originalLocked.submit(urls: [different], resourceID: saved.id, settings: settings); preconditionFailure("mock read should stop") }
            catch let error as SHT115Diagnostic { precondition(error.stage == "verify-before-submit") }
            let foreignAccount = SHT115Settings(cookie: "UID=456_A; CID=fake; SEID=fake", parentCID: cid).account
            let foreign = SHT115Resource(id: post.id, account: foreignAccount, tid: post.tid, directoryName: post.directoryName, parentCID: post.parentCID, directoryCID: post.directoryCID, directoryWritePending: false, tasks: post.tasks)
            try JSONEncoder().encode([saved, foreign]).write(to: store, options: .atomic)
            let isolated = try SHT115Service(storeURL: store, session: session)
            do { _ = try await isolated.submit(urls: [ed], resourceID: saved.id, settings: settings); preconditionFailure("mock read should stop") }
            catch let error as SHT115Diagnostic { precondition(error.stage == "verify-before-submit") }
            precondition(writes == 1)
        }
        precondition(reads >= 3)
    }
    static func targetAndFolder() async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [ManualProtocol.self]
        let session = URLSession(configuration: cfg); defer { session.invalidateAndCancel() }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let settings = SHT115Settings(cookie: "UID=123_A; CID=fake; SEID=fake", parentCID: "10")
        let service = try SHT115Service(storeURL: store, session: session)
        var posts = 0
        ManualProtocol.handler = { req in
            let u = req.url!
            let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let cid = q.first { $0.name == "cid" }?.value ?? ""
            var obj: [String: Any]
            if req.httpMethod == "POST" {
                precondition(u.path == "/files/add")
                posts += 1
                precondition(body(req).contains("pid=20") && body(req).contains("cname=Archive"))
                let saved = try JSONDecoder().decode([SHT115Resource].self, from: Data(contentsOf: store))
                precondition(saved.last?.directoryJournal?.last?.state == .submitting)
                obj = ["state": true, "cid": "30"]
            } else {
                var path: [[String: Any]] = [["cid": "0", "name": "root"], ["cid": "20", "name": "mine"]]
                if cid == "30" { path.append(["cid": "30", "name": "Archive"]) }
                obj = ["state": true, "path": path, "data": [["cid": "30", "n": "Archive"]], "count": 1, "offset": 0, "limit": 100, "order": "file_name", "is_asc": 1]
            }
            return try JSONSerialization.data(withJSONObject: obj)
        }
        let selected = try await service.prepareManualResource(settings: settings, targetCID: "20")
        precondition(selected.directoryCID == "20" && selected.parentCID == "10" && selected.manualActualParentCID == "0")
        precondition(settings.parentCID == "10" && posts == 0)
        let page = try await service.browseFolders(cid: "20", settings: settings)
        precondition(page.entries.first?.isDirectory == true && page.entries.first?.id == "30")
        let authorization = UUID()
        let folder = try await service.createManualFolder(name: "Archive", parentCID: "20", authorization: authorization, settings: settings)
        precondition(folder.directoryCID == "30" && !folder.directoryWritePending && posts == 1)
        _ = try await service.createManualFolder(name: "Archive", parentCID: "20", authorization: authorization, settings: settings)
        precondition(posts == 1, "same authorization may only reverify, never replay creation")
        print("PASS independent manual target, paged existing folders, explicit single creation journal + fresh name/parent proof; global parent unchanged")
    }
    static func main() async throws {
        try await targetAndFolder()
        precondition(ResourceLinkExtractor.links(in: "").isEmpty)
        precondition(ResourceLinkExtractor.links(in: "https://example.invalid password magnet:?xt=bad").isEmpty)
        let links = ResourceLinkExtractor.links(in: "mixed\n" + ed + "\n" + magnet + "\n" + ed)
        precondition(links == [ed, magnet])
        precondition(links[1].contains("a%26b"))
        let base32 = "magnet:?xt=urn:btih:" + String(repeating: "A", count: 32)
        precondition(ResourceLinkExtractor.links(in: base32).count == 1)
        let zero = "magnet:?xt=urn:btih:" + String(repeating: "0", count: 40)
        precondition(SHT115Service.replayIdentities(base32) == SHT115Service.replayIdentities(zero))
        let renamed = ed.replacingOccurrences(of: "a.zip", with: "new.zip")
        precondition(SHT115Service.uniqueResources([ed, renamed, magnet, magnet + "&tr=x"]) == [ed, magnet])
        let btmh = "magnet:?xt=urn:btmh:1220" + String(repeating: "a", count: 64)
        let hybrid = btmh + "&xt=urn:btih:" + String(repeating: "0", count: 40)
        precondition(SHT115Service.uniqueResources([zero, btmh, hybrid]) == [hybrid])
        precondition(!SHT115Service.replayIdentities(hybrid).isDisjoint(with: SHT115Service.replayIdentities(zero)))
        precondition(!SHT115Service.replayIdentities(hybrid).isDisjoint(with: SHT115Service.replayIdentities(btmh)))
        precondition(SHT115Service.uniqueResources([ed, ed.replacingOccurrences(of: "0123456789abcdef0123456789abcdef", with: String(repeating: "f", count: 32))]).count == 2)
        for invalid in [ed.replacingOccurrences(of: "|123|", with: "|0|"), ed.replacingOccurrences(of: "|123|", with: "|-1|"), "magnet:?xt=urn:btih:abc", "magnet:?xt=urn:btmh:1220ff", "https://example.invalid/"] {
            precondition(ResourceLinkExtractor.links(in: invalid).isEmpty)
        }
        var draft = ed + "\n" + magnet
        precondition(ResourceLinkExtractor.links(in: draft).count == 2)
        draft = ""
        precondition(ResourceLinkExtractor.links(in: draft).isEmpty)
        for mode in ["accepted", "bad-snapshot", "pending-snapshot", "partial", "wrong-identity", "transport", "rejected", "bad-path"] { try await run(mode: mode) }
        print("manual input extraction / durable journal / request identity / unknown / restart / parent CID fixtures passed")
    }
}
