import Foundation

final class Paging115Protocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var mode = "valid"
    nonisolated(unsafe) static var hosts: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.httpMethod != "POST")
        let url = request.url!, host = url.host!
        Self.hosts.append(host)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func v(_ key: String) -> String { q.first { $0.name == key }?.value ?? "" }
        precondition(v("o") == "file_name" && v("asc") == "1" && v("custom_order") == "1" && v("fc_mix") == "1")
        precondition(!q.contains { $0.name == "search_value" })
        let offset = Int(v("offset"))!, mode = Self.mode
        if (mode == "fallback" && host == "webapi.115.com") || (mode == "switch" && offset > 0) {
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed)); return
        }
        let limit = mode == "clamped" ? 2 : 100
        let total = mode == "clamped" ? 5 : 101
        var rows = (offset..<min(offset + limit, total)).map { ["fid": String($0 + 1000), "n": "file"] }
        if mode == "repeat" && offset > 0 { rows = [["fid":"1000", "n":"file"]] }
        if mode == "overlap" && offset > 0 { rows = [["fid":"1099", "n":"file"]] }
        if mode == "mixed" && offset > 0 { rows = [["cid":"1000", "n":"folder"]] }
        var obj: [String: Any] = ["state":true, "count":total, "offset":offset, "limit":limit, "order":"file_name", "is_asc":1, "fc_mix":1, "data":rows, "path":[["cid":"0"],["cid":"10"]]]
        if mode == "offset" && offset > 0 { obj["offset"] = 0 }
        if mode == "count" && offset > 0 { obj["count"] = 102 }
        if mode == "sorting" { obj["order"] = "user_ptime" }
        if mode == "mix" { obj["fc_mix"] = 0 }
        if mode == "limit" && offset > 0 { obj["limit"] = 50 }
        if mode == "no-total" { obj.removeValue(forKey:"count"); if offset > 0 { obj["data"] = [] } else { obj["data"] = [["fid":"1000","n":"file"]] } }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self, didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct PagingFixtures {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Paging115Protocol.self]
        let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
        let http = SHT115HTTP(session:session)
        let settings = SHT115Settings(cookie:"UID=123_A1; CID=fake; SEID=fake",parentCID:"10")
        let expected = ["repeat":"directory-duplicate", "overlap":"directory-duplicate", "offset":"directory-pagination", "count":"directory-count", "sorting":"directory-pagination", "mix":"directory-pagination", "limit":"directory-pagination", "switch":"http-read"]
        for mode in ["valid","clamped","mixed","fallback","repeat","overlap","offset","count","sorting","mix","limit","switch","no-total"] {
            Paging115Protocol.mode = mode; Paging115Protocol.hosts = []
            do {
                let rows = try await http.allEntries(cid:"10",settings:settings)
                precondition(expected[mode] == nil)
                precondition(rows.count == (mode == "clamped" ? 5 : mode == "no-total" ? 1 : 101))
            } catch let error as SHT115Diagnostic { precondition(error.stage == expected[mode], mode + " " + error.stage) }
            if mode == "switch" { precondition(Paging115Protocol.hosts == ["webapi.115.com","webapi.115.com"], "never splice fallback pages") }
            if mode == "fallback" { precondition(Paging115Protocol.hosts == ["webapi.115.com","proapi.115.com","proapi.115.com"]) }
            print("PASS paging " + mode)
        }
    }
}
