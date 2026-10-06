import Foundation

struct SHT115HTTP {
    let session: URLSession
    static let safariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 40
        self.session = session ?? URLSession(configuration: config, delegate: SHT115APIRedirectGuard(), delegateQueue: nil)
    }
    static func headers(_ settings: SHT115Settings) -> [String: String] {
        ["User-Agent": safariUA, "Cookie": settings.cookie, "Referer": "https://115.com/", "Origin": "https://115.com", "Accept": "*/*"]
    }
    static func form(_ fields: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return fields.map { key, value in
            (key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
    }
    func data(_ endpoint: String, settings: SHT115Settings, fields: [(String, String)]? = nil) async throws -> (Data, URL) {
        guard let url = URL(string: endpoint) else { throw SHT115Error.invalidInput }
        var request = URLRequest(url: url)
        Self.headers(settings).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let fields = fields {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.httpBody = Data(Self.form(fields).utf8)
        }
        try await SHT115RequestPacer.shared.wait()
        try Task.checkCancellation()
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            throw Self.transportDiagnostic(error, url: url, writing: fields != nil)
        }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            throw SHT115Diagnostic(stage: fields == nil ? "http-read" : "http-write", outcome: fields == nil ? "读取失败" : "写入结果未知", code: status.map(String.init) ?? "")
        }
        return (data, response.url ?? url)
    }
    func json(_ endpoint: String, settings: SHT115Settings, fields: [(String, String)]? = nil) async throws -> [String: Any] {
        let (data, _) = try await data(endpoint, settings: settings, fields: fields)
        // Preserve identifier tokens before Foundation JSON parsing (never Double).
        guard var text = String(data: data, encoding: .utf8) else { throw SHT115Error.unsafeListing }
        let regex = try NSRegularExpression(pattern: "(\"(?:cid|pid|parent_id|category_id|folder_id|file_id|fid|id|wp_path_id)\"\\s*:\\s*)([0-9]+)(?=\\s*[,}])")
        text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1\"$2\"")
        let obj: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw SHT115Error.unsafeListing }
            obj = decoded
        } catch {
            throw SHT115Diagnostic(stage: fields == nil ? "json-read" : "json-write", outcome: fields == nil ? "响应不是可验证JSON" : "结果未知：响应不是可验证JSON，不自动重发", code: "")
        }
        return obj
    }
    static func transportDiagnostic(_ error: URLError, url: URL, writing: Bool) -> SHT115Diagnostic {
        let tls = [-1200, -1201, -1202, -1203, -1204, -1205, -1206].contains(error.code.rawValue)
        // Only fixed API routes: never copy failing URLs, query, body or userInfo.
        let routes = ["/files", "/natsort/files.php", "/android/2.0/ufile/files", "/files/add", "/"]
        let hosts = ["webapi.115.com", "aps.115.com", "proapi.115.com", "115.com"]
        let endpoint = (hosts.contains(url.host ?? "") ? url.host! : "115-api") + (routes.contains(url.path) ? url.path : "/api")
        let reason = tls ? "TLS安全连接失败（非Cookie过期证据）；请检查网络、代理、设备时间及证书" : "网络传输失败"
        return SHT115Diagnostic(stage: writing ? "http-write" : "http-read", outcome: reason + "；" + (writing ? "写入结果未知，不自动重发" : "本次只读请求未写入，可安全重试读取") + "；endpoint=" + endpoint, code: String(error.code.rawValue))
    }
    static func string(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }
    static func success(_ obj: [String: Any]) -> Bool { ["1", "true"].contains(string(obj["state"]).lowercased()) }
}
struct SHT115Entry {
    let id: String
    let name: String
    let isDirectory: Bool
    let pickCode: String
    let size: Int64
}
struct SHT115Page {
    let entries: [SHT115Entry]
    let total: Int?
    let path: [[String: Any]]
}
extension SHT115HTTP {
    func page(cid: String, offset: Int, settings: SHT115Settings) async throws -> SHT115Page {
        let query = Self.form([("aid", "1"), ("cid", cid), ("offset", String(offset)), ("limit", "100"), ("show_dir", "1"), ("format", "json")])
        // Read-only compatibility routes used by XXXClub/avdb115. Only a transport
        // failure can switch endpoints; API rejection/unsafe data must stop closed.
        var obj: [String: Any] = [:]
        let endpoints = ["https://aps.115.com/natsort/files.php", "https://proapi.115.com/android/2.0/ufile/files", "https://webapi.115.com/files"]
        for (index, endpoint) in endpoints.enumerated() {
            do { obj = try await json(endpoint + "?" + query, settings: settings); break }
            catch let error as SHT115Diagnostic {
                guard error.stage == "http-read", Int(error.code).map({ $0 <= -1000 && $0 != -999 }) == true, index < endpoints.count - 1 else { throw error }
            }
        }
        guard Self.success(obj) else { throw SHT115Diagnostic(stage: "directory-list", outcome: "读取被API拒绝", code: SHT115Diagnostic.apiCode(obj)) }
        let nested = obj["data"] as? [String: Any] ?? [:]
        guard let raw = (obj["data"] as? [[String: Any]]) ?? (nested["list"] as? [[String: Any]]) ?? (obj["files"] as? [[String: Any]]) else { throw SHT115Error.unsafeListing }
        let entries = try Self.entries(raw)
        return SHT115Page(entries: entries, total: Int(Self.string(obj["count"] ?? nested["count"])), path: (obj["path"] as? [[String: Any]]) ?? (nested["path"] as? [[String: Any]]) ?? [])
    }
    static func entries(_ raw: [[String: Any]]) throws -> [SHT115Entry] {
        try raw.map { item -> SHT115Entry in
            let fid = Self.string(item["fid"] ?? item["file_id"])
            let directory = fid.isEmpty || fid == "0"
            let id = directory ? Self.string(item["cid"] ?? item["category_id"] ?? item["folder_id"]) : fid
            guard SHT115Settings.isCID(id), id != "0" else { throw SHT115Error.unsafeListing }
            return SHT115Entry(id: id, name: Self.string(item["n"] ?? item["name"] ?? item["file_name"] ?? item["category_name"]), isDirectory: directory,
                pickCode: Self.string(item["pc"] ?? item["pick_code"] ?? item["pickcode"]), size: Int64(Self.string(item["s"] ?? item["file_size"] ?? item["size"])) ?? 0)
        }
    }
    static func verifiedPath(_ path: [[String: Any]], cid: String, parent: String?) throws {
        let ids = path.map { string($0["cid"] ?? $0["category_id"] ?? $0["folder_id"]) }
        guard ids.first == "0", ids.last == cid, ids.allSatisfy(SHT115Settings.isCID), Set(ids).count == ids.count else { throw SHT115Error.unsafeListing }
        if let parent {
            guard ids.count >= 2, ids[ids.count - 2] == parent, cid != parent else { throw SHT115Error.unsafeListing }
        }
    }
    func verify(cid: String, parent: String?, settings: SHT115Settings) async throws {
        _ = try await verifiedPage(cid: cid, parent: parent, settings: settings)
    }
    /// Reuse the exact response whose ancestry was checked, not a TTL assumption.
    /// This avoids immediately fetching offset zero again while keeping fresh
    /// pre-write and cleanup verification unchanged.
    func verifiedPage(cid: String, parent: String?, settings: SHT115Settings) async throws -> SHT115Page {
        let page = try await page(cid: cid, offset: 0, settings: settings)
        try Self.verifiedPath(page.path, cid: cid, parent: parent)
        return page
    }
    /// A 20-page cap silently fails on real parent folders larger than 2,000
    /// entries. Keep the identity/count proof, but allow the proven page count.
    func allEntries(cid: String, settings: SHT115Settings, firstPage: SHT115Page? = nil) async throws -> [SHT115Entry] {
        var entries: [SHT115Entry] = [], seen = Set<String>()
        let pageLimit = min(500, max(20, ((firstPage?.total ?? 0) + 99) / 100))
        for index in 0..<pageLimit {
            let page: SHT115Page
            if index == 0, let firstPage { page = firstPage }
            else { page = try await self.page(cid: cid, offset: index * 100, settings: settings) }
            let ids = page.entries.map { ($0.isDirectory ? "d" : "f") + $0.id }
            guard ids.allSatisfy({ !seen.contains($0) }), Set(ids).count == ids.count else { throw SHT115Error.unsafeListing }
            seen.formUnion(ids); entries += page.entries
            if let total = page.total {
                guard total >= entries.count else { throw SHT115Error.unsafeListing }
                if entries.count == total { return entries }
                if page.entries.isEmpty { throw SHT115Error.unsafeListing }
            } else if page.entries.count < 100 { return entries }
        }
        throw SHT115Error.unsafeListing
    }
    /// Locate one exact child without requiring a complete scan of a very large parent.
    /// Search results are not trusted until the candidate's own fresh path verifies it.
    func matchingDirectories(name: String, parentCID: String, parentPage: SHT115Page, settings: SHT115Settings) async throws -> [SHT115Entry] {
        var matches = parentPage.entries.filter { $0.isDirectory && $0.name == name }
        if matches.isEmpty {
            let query = Self.form([("aid", "1"), ("cid", parentCID), ("search_value", name), ("offset", "0"), ("limit", "20"), ("show_dir", "1"), ("format", "json")])
            for endpoint in ["https://webapi.115.com/files", "https://aps.115.com/natsort/files.php"] {
                let obj = try await json(endpoint + "?" + query, settings: settings)
                guard Self.success(obj) else { continue }
                let nested = obj["data"] as? [String: Any] ?? [:]
                let raw = (obj["data"] as? [[String: Any]]) ?? (nested["list"] as? [[String: Any]]) ?? []
                matches += try Self.entries(raw).filter { $0.isDirectory && $0.name == name }
                if !matches.isEmpty { break }
            }
        }
        if matches.isEmpty {
            var narrowed = parentPage
            let pages = min(500, max(1, ((parentPage.total ?? 0) + 99) / 100))
            for index in 1..<pages {
                let page = try await self.page(cid: parentCID, offset: index * 100, settings: settings)
                guard page.total == parentPage.total else { throw SHT115Error.unsafeListing }
                narrowed = SHT115Page(entries: narrowed.entries + page.entries, total: page.total, path: narrowed.path)
                matches = narrowed.entries.filter { $0.isDirectory && $0.name == name }
                if !matches.isEmpty || narrowed.entries.count == parentPage.total { break }
            }
            guard !matches.isEmpty || narrowed.entries.count == parentPage.total else { throw SHT115Error.unsafeListing }
        }
        var verified: [SHT115Entry] = [], seen = Set<String>()
        for match in matches where seen.insert(match.id).inserted {
            let page = try await verifiedPage(cid: match.id, parent: parentCID, settings: settings)
            if page.path.compactMap({ Self.string($0["name"] ?? $0["n"]) }).last == name {
                verified.append(match)
            }
        }
        return verified
    }
}

/// Reserve start slots across all service instances, like tang115 MIN_115_GAP_MS.
/// No automatic retry, especially no retry of an ambiguous POST.
actor SHT115RequestPacer {
    static let shared = SHT115RequestPacer()
    private var lastStart: UInt64 = 0
    func wait() async throws {
        // Recheck after suspension: delayed callers must not bunch into old slots.
        while true {
            try Task.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            let earliest = lastStart + 1_100_000_000
            if now >= earliest {
                lastStart = now
                return
            }
            try await Task.sleep(nanoseconds: earliest - now)
        }
    }
}

/// API redirects are not required by these fixed endpoints. Reject all redirects,
/// especially POST replay, cross-host Cookie forwarding and HTTPS downgrade.
/// Default platform server trust remains untouched.
final class SHT115APIRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
