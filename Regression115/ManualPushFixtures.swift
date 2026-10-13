import Foundation

final class ManualProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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
                precondition(url.path == "/web/lixian/") // never create folders, extract, delete or play
                writes += 1
                let payload = body(request)
                precondition(payload.contains("wp_path_id=" + cid))
                precondition(!payload.contains("cname="))
                // Journal must already be durable before transport starts.
                let saved = try JSONDecoder().decode([SHT115Resource].self, from: Data(contentsOf: store))
                precondition(saved[0].tasks.last?.state == .submitting)
                if mode == "transport" { throw URLError(.timedOut) }
                if mode == "partial" { obj = ["state": true, "data": [["state": true, "url": ed]]] }
                else if mode == "wrong-identity" { obj = ["state": true, "data": [["state": true, "url": ed], ["state": true, "url": "magnet:?xt=urn:btih:" + String(repeating: "f", count: 40)]]] }
                else if mode == "accepted" { obj = ["state": true, "data": [["state": true, "url": ed], ["state": true, "url": magnet]]] }
                else { obj = ["state": false, "errno": 10008] }
            } else if url.path == "/" {
                obj = ["state": true, "sign": "fake-sign", "time": "1"]
            } else {
                reads += 1
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                precondition(q.first { $0.name == "cid" }?.value == cid)
                obj = ["state": true, "count": 0, "data": [], "path": [["cid": "0"], ["cid": mode == "bad-path" ? "9" : cid]], "offset": 0, "limit": 100, "order": "file_name", "is_asc": 1, "fc_mix": 1]
            }
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
        let otherSettings = SHT115Settings(cookie: settings.cookie, parentCID: "99")
        do { _ = try await service.submit(urls: [ed], resourceID: resource.id, settings: otherSettings); preconditionFailure("path changed") } catch {}
        for invalid in [[], ["https://example.invalid/password"], ["magnet:?xt=invalid"]] {
            do { _ = try await service.submit(urls: invalid, resourceID: resource.id, settings: settings); preconditionFailure("invalid") } catch {}
        }
        precondition(writes == 0)
        do { _ = try await service.submit(urls: [ed, ed, magnet], resourceID: resource.id, settings: settings, autoExtraction: true) }
        catch { precondition(mode != "accepted") }
        var saved = await service.resources().first!
        precondition(writes == 1 && saved.tasks.count == 1 && saved.tasks[0].urls.count == 2)
        precondition(saved.tasks[0].state == (mode == "accepted" ? .accepted : mode == "rejected" ? .rejected : .unknown))
        precondition((saved.extractionQueue ?? []).count == (mode == "accepted" ? 2 : 0))
        if mode != "rejected" {
            do { _ = try await service.submit(urls: [ed], resourceID: resource.id, settings: settings); preconditionFailure("repeated") } catch {}
            precondition(writes == 1)
            let restarted = try SHT115Service(storeURL: store, session: session)
            let restored = try await restarted.prepareManualResource(settings: settings)
            precondition(restored.id == resource.id)
            do { _ = try await restarted.submit(urls: [magnet], resourceID: restored.id, settings: settings); preconditionFailure("restart repeated") } catch {}
            precondition(writes == 1)
            // Read-only reconciliation does not clear unknown task locks.
            _ = try await restarted.reconcileDirectory(resourceID: restored.id, settings: settings)
            saved = await restarted.resources().first!
            precondition(saved.tasks[0].state == (mode == "accepted" ? .accepted : .unknown))
            // A post record cannot bypass a manual unknown/accepted task lock either.
            var post = SHT115Resource(id: "post", account: settings.account, tid: "123", directoryName: "test_tid-123", parentCID: cid, directoryCID: "77", directoryWritePending: false, tasks: [])
            post.directoryJournal = []
            try JSONEncoder().encode([saved, post]).write(to: store, options: .atomic)
            let mixed = try SHT115Service(storeURL: store, session: session)
            do { _ = try await mixed.submit(urls: [ed], resourceID: post.id, settings: settings); preconditionFailure("post bypass") } catch {}
            precondition(writes == 1)
        }
        precondition(reads >= 3)
    }
    static func main() async throws {
        precondition(ResourceLinkExtractor.links(in: "").isEmpty)
        precondition(ResourceLinkExtractor.links(in: "https://example.invalid password magnet:?xt=bad").isEmpty)
        let links = ResourceLinkExtractor.links(in: "mixed\n" + ed + "\n" + magnet + "\n" + ed)
        precondition(links == [ed, magnet])
        precondition(links[1].contains("a%26b"))
        let base32 = "magnet:?xt=urn:btih:" + String(repeating: "A", count: 32)
        precondition(ResourceLinkExtractor.links(in: base32).count == 1)
        for mode in ["accepted", "partial", "wrong-identity", "transport", "rejected", "bad-path"] { try await run(mode: mode) }
        print("manual input extraction / durable journal / request identity / unknown / restart / parent CID fixtures passed")
    }
}
