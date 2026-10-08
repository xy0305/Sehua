import Foundation

final class ProgressProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reads = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.httpMethod == "GET", "read-only verification wrote")
        let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let text: String
        if q.contains(where: { $0.name == "ac" && $0.value == "task_lists" }) {
            Self.reads += 1
            precondition(!q.contains(where: { $0.name == "info_hash" }))
            text = "{\"state\":true,\"page_count\":1,\"tasks\":[{\"url\":\"test-A\",\"wp_path_id\":\"20\",\"status\":2,\"percentDone\":100},{\"url\":\"test-B\",\"wp_path_id\":\"30\",\"status\":2}]}"
        } else {
            let offset = q.first(where: { $0.name == "offset" })?.value ?? "0"
            text = "{\"state\":true,\"data\":[],\"count\":0,\"offset\":\(offset),\"limit\":100,\"order\":\"file_name\",\"is_asc\":1,\"fc_mix\":1,\"path\":[{\"cid\":0},{\"cid\":10},{\"cid\":20}]}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct ProgressFixtures {
    static func main() async throws {
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let task = SHT115Task(id: UUID(), urls: ["test-A", "test-B", "test-C"], state: .unknown, progress: [], updatedAt: Date())
        let r = SHT115Resource(id: "r", account: settings.account, tid: "1", directoryName: "fixture_tid-1", parentCID: "10", directoryCID: "20", directoryWritePending: false, tasks: [task])
        try JSONEncoder().encode([r]).write(to: store)
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [ProgressProtocol.self]
        let session = URLSession(configuration: c); defer { session.invalidateAndCancel() }
        let service = try SHT115Service(storeURL: store, session: session)
        let result = try await service.inspect(resourceID: "r", settings: settings, includeFiles: false)
        precondition(result.resource.tasks[0].state == .unknown)
        precondition(result.resource.tasks[0].progress.count == 1)
        precondition(result.verificationSummary.contains("目标目录已证实1项（完成1项）；其他目录1项；未证实1项"))
        precondition(ProgressProtocol.reads == 1)
        precondition(result.listing.videos.isEmpty)
        print("PASS: single task page; target/other/unverified separated; no writes; unknown retained; no file scan")
    }
}
