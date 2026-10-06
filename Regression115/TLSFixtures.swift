import Foundation
final class TLS115Protocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var failAll = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        if Self.failAll || request.httpMethod == "POST" || request.url!.host == "aps.115.com" {
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed)); return
        }
        let searching = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "search_value" } == true
        let body = searching ? "{\"state\":true,\"count\":0,\"data\":[]}" : "{\"state\":true,\"count\":0,\"data\":[],\"path\":[{\"cid\":\"0\"},{\"cid\":\"10\"}]}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct TLSFixtures {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TLS115Protocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let http = SHT115HTTP(session: session)
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        try await http.verify(cid: "10", parent: nil, settings: settings)
        precondition(TLS115Protocol.requests == 2)
        TLS115Protocol.failAll = true
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let service = try SHT115Service(storeURL: store, session: session)
        do { _ = try await service.createOrReuseResource(tid: "12", title: "fixture", settings: settings); preconditionFailure() }
        catch let error as SHT115Diagnostic {
            let text = error.localizedDescription
            precondition(error.stage == "http-read" && text.contains("TLS") && text.contains("可安全重试") && text.contains("读取失败不代表写入结果未知") && !text.contains("fake") && !text.contains("cid="))
        }
        let before = await service.resources(); precondition(before.count == 1 && !before[0].directoryWritePending)
        TLS115Protocol.failAll = false
        let count = TLS115Protocol.requests
        do { _ = try await service.createOrReuseResource(tid: "12", title: "fixture", settings: settings); preconditionFailure() }
        catch let error as SHT115Diagnostic { precondition(error.stage == "http-write" && error.localizedDescription.contains("不自动重发")) }
        let after = await service.resources(); precondition(after[0].directoryWritePending)
        precondition(TLS115Protocol.requests == count + 4)
        let saved = TLS115Protocol.requests
        do { _ = try await service.createOrReuseResource(tid: "12", title: "fixture", settings: settings); preconditionFailure() }
        catch SHT115Error.uncertainWrite {}
        precondition(TLS115Protocol.requests == saved + 2, "must read only, never replay POST")
        print("PASS TLS fixtures: read fallback, safe retry, sanitized TLS UI, persisted unknown write/no replay")
    }
}
