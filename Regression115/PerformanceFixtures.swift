import Foundation

/// Controlled URLProtocol latency; compare the old production call sequence
/// with response reuse. No account, cookie, or real server is used.
final class Performance115Protocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Thread.sleep(forTimeInterval: 0.05)
        let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "offset" }!.value!
        let rows = offset == "0" ? (1...100).map { "{\"cid\":\"\($0 + 100)\",\"n\":\"folder\"}" }.joined(separator: ",") : "{\"cid\":\"201\",\"n\":\"last\"}"
        let text = "{\"state\":true,\"count\":101,\"data\":[\(rows)],\"path\":[{\"cid\":\"0\"},{\"cid\":\"10\"}]}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct PerformanceFixtures {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Performance115Protocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let http = SHT115HTTP(session: session)
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        // Warm the shared production pacer so both runs include the same first slot wait.
        try await http.verify(cid: "10", parent: nil, settings: settings)
        Performance115Protocol.requests = 0
        let before = Date()
        try await http.verify(cid: "10", parent: nil, settings: settings)
        let old = try await http.allEntries(cid: "10", settings: settings)
        let baseline = Date().timeIntervalSince(before)
        precondition(Performance115Protocol.requests == 3 && old.count == 101)
        Performance115Protocol.requests = 0
        let after = Date()
        let first = try await http.verifiedPage(cid: "10", parent: nil, settings: settings)
        let new = try await http.allEntries(cid: "10", settings: settings, firstPage: first)
        let optimized = Date().timeIntervalSince(after)
        precondition(Performance115Protocol.requests == 2 && new.map(\.id) == old.map(\.id))
        precondition(baseline - optimized > 0.7, "expected one unchanged 1.1s production pacing slot saved")
        do { _ = try await http.verifiedPage(cid: "10", parent: "99", settings: settings); preconditionFailure("unsafe ancestry accepted") }
        catch SHT115Error.unsafeListing {}
        print(String(format: "PASS performance: parent 101 entries; baseline 3 requests %.3fs; reuse 2 requests %.3fs; identical entries; unsafe ancestry refused", baseline, optimized))
    }
}
