import Foundation

final class ListingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var scenario = "normal"
    nonisolated(unsafe) static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.httpMethod != "POST", "listing must never write")
        Self.calls += 1
        let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let offset = Int(q.first { $0.name == "offset" }!.value!)!
        let cid = q.first { $0.name == "cid" }!.value!
        let mode = Self.scenario
        var total = mode == "large" ? 2051 : 101
        if mode == "cap" { total = 50001 }
        if mode == "changing" && offset > 0 { total = 102 }
        let count = mode == "no-total" ? "" : "\"count\":\(total),"
        var path: [[String: String]] = [["cid":"0"], ["cid":"10"]]
        var rows: [[String: String]] = []
        if cid == "900" {
            path += [["cid":"900", "name":"wanted"]]
            if mode == "foreign" { path = [["cid":"0"],["cid":"99"],["cid":"900","name":"wanted"]] }
            if mode == "leaf-name" { path[path.count - 1].removeValue(forKey: "name") }
        } else {
            let end = min(offset + 100, total)
            if offset < end { rows = (offset..<end).map { ["fid":String($0 + 1000), "n":"file"] } }
            if mode == "duplicate" && offset > 0 { rows = [["fid":"1000","n":"file"]] }
            if mode == "path" && offset > 0 { path = [["cid":"0"],["cid":"99"]] }
            if mode == "missing-name" { rows = [["cid":"900","n":""]] }
            if ["ignored-search", "foreign", "leaf-name"].contains(mode) && offset > 0 { rows = [["cid":"900","n":"wanted"]] }
        }
        let data = try! JSONSerialization.data(withJSONObject: rows)
        let ancestry = try! JSONSerialization.data(withJSONObject: path)
        let body = "{\"state\":true,\(count)\"data\":\(String(data:data,encoding:.utf8)!),\"path\":\(String(data:ancestry,encoding:.utf8)!)}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: pagingFixtureData(body)); client?.urlProtocolDidFinishLoading(self)
    }

    private func pagingFixtureData(_ text: String) -> Data {
        let data = Data(text.utf8)
        guard let url = request.url, let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let offset = q.first(where: { $0.name == "offset" })?.value,
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["path"] != nil else { return data }
        obj["offset"] = Int(offset)!; obj["limit"] = 100
        obj["order"] = "file_name"; obj["is_asc"] = 1; obj["fc_mix"] = 1
        return try! JSONSerialization.data(withJSONObject: obj)
    }
    override func stopLoading() {}
}
@main struct ListingFixtures {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ListingProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let http = SHT115HTTP(session: session)
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        for mode in ["normal", "no-total", "large", "changing", "duplicate", "path", "cap", "missing-name", "ignored-search", "foreign", "leaf-name"] {
            #if BASELINE_LISTING
            if mode == "cap" { continue } // avoid hundreds of paced requests on old code
            #endif
            ListingProtocol.scenario = mode; ListingProtocol.calls = 0
            let expected = ["changing":"directory-count", "duplicate":"directory-duplicate", "path":"directory-path", "cap":"directory-cap", "foreign":"directory-path", "leaf-name":"directory-path"][mode]
            do {
                #if BASELINE_LISTING
                #if VERSION54
                if ["ignored-search", "foreign", "leaf-name", "no-total"].contains(mode) {
                    let first = try await http.verifiedPage(cid: "10", parent: nil, settings: settings)
                    let result = try await http.matchingDirectories(name: "wanted", parentCID: "10", parentPage: first, settings: settings)
                    print("COMPARE baseline " + mode + " matches=" + String(result.count))
                    continue
                }
                #endif
                let result = try await http.allEntries(cid: "10", settings: settings)
                print("COMPARE baseline " + mode + " accepted=" + String(result.count))
                continue
                #else
                if ["ignored-search", "foreign", "leaf-name"].contains(mode) {
                    let first = try await http.verifiedPage(cid: "10", parent: nil, settings: settings)
                    let result = try await http.matchingDirectories(name: "wanted", parentCID: "10", parentPage: first, settings: settings)
                    precondition(result.count == 1)
                } else {
                    let result = try await http.allEntries(cid: "10", settings: settings)
                    precondition(result.count == (mode == "large" ? 2051 : 101))
                }
                precondition(expected == nil, "unsafe fixture accepted: " + mode)
                #endif
            } catch {
                #if BASELINE_LISTING
                print("COMPARE baseline " + mode + " refused")
                continue
                #else
                guard let error = error as? SHT115Diagnostic else { throw error }
                precondition(error.stage == expected, "unexpected stage: " + mode + " " + error.stage)
                #endif
            }
            if mode == "cap" { precondition(ListingProtocol.calls == 1) }
            print("PASS listing " + mode)
        }
    }
}
