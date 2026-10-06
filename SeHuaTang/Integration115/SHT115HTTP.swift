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
        guard var text = String(data: data, encoding: .utf8) else { throw SHT115Diagnostic(stage: "directory-path", outcome: "路径或直属父目录无法验证，已停止写入", code: "") }
        let regex = try NSRegularExpression(pattern: "(\"(?:cid|pid|parent_id|category_id|folder_id|file_id|fid|id|wp_path_id)\"\\s*:\\s*)([0-9]+)(?=\\s*[,}])")
        text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1\"$2\"")
        let obj: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw SHT115Diagnostic(stage: "directory-path", outcome: "路径或直属父目录无法验证，已停止写入", code: "") }
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
    var endpoint: String? = nil
    var offset: Int = 0
    var pageLimit: Int = 100
}
extension SHT115HTTP {
    func page(cid: String, offset: Int, settings: SHT115Settings, endpoint pinnedEndpoint: String? = nil) async throws -> SHT115Page {
        let query = Self.form([("aid", "1"), ("cid", cid), ("offset", String(offset)), ("limit", "100"), ("show_dir", "1"), ("format", "json"), ("o", "file_name"), ("asc", "1"), ("custom_order", "1"), ("fc_mix", "1")])
        // Read-only compatibility routes used by XXXClub/avdb115. Only a transport
        // failure can switch endpoints; API rejection/unsafe data must stop closed.
        var obj: [String: Any] = [:]
        let endpoints = pinnedEndpoint.map { [$0] } ?? ["https://webapi.115.com/files", "https://proapi.115.com/android/2.0/ufile/files"]
        var selectedEndpoint = endpoints[0]
        for (index, endpoint) in endpoints.enumerated() {
            do { obj = try await json(endpoint + "?" + query, settings: settings); selectedEndpoint = endpoint; break }
            catch let error as SHT115Diagnostic {
                guard error.stage == "http-read", Int(error.code).map({ $0 <= -1000 && $0 != -999 }) == true, index < endpoints.count - 1 else { throw error }
            }
        }
        guard Self.success(obj) else { throw SHT115Diagnostic(stage: "directory-list", outcome: "读取被API拒绝", code: SHT115Diagnostic.apiCode(obj)) }
        let nested = obj["data"] as? [String: Any] ?? [:]
        guard let raw = (obj["data"] as? [[String: Any]]) ?? (nested["list"] as? [[String: Any]]) ?? (obj["files"] as? [[String: Any]]) else { throw SHT115Diagnostic(stage: "directory-path", outcome: "路径或直属父目录无法验证，已停止写入", code: "") }
        let entries = try Self.entries(raw)
        let countValue = obj["count"] ?? nested["count"]
        let total = Int(Self.string(countValue))
        if countValue != nil, total == nil || (total ?? -1) < 0 { throw Self.listingFailure("count", "总数字段无效") }
        // Some compatibility fixtures/legacy responses omit metadata. Never accept
        // a partially supplied or conflicting paging contract.
        func value(_ key: String) -> Any? { obj[key] ?? nested[key] }
        let hasMetadata = ["offset", "limit", "order", "is_asc"].contains { value($0) != nil }
        var effectiveLimit = 100
        guard hasMetadata else { throw Self.listingFailure("pagination", "缺少分页与排序回显，不能证明完整") }
        if hasMetadata {
            guard Int(Self.string(value("offset"))) == offset,
                  let limit = Int(Self.string(value("limit"))), (1...100).contains(limit),
                  Self.string(value("order")) == "file_name",
                  Self.string(value("is_asc")) == "1",
                  value("fc_mix") == nil || Self.string(value("fc_mix")) == "1" else {
                throw Self.listingFailure("pagination", "分页位置、页长或排序回显不符")
            }
            effectiveLimit = limit
        }
        guard entries.count <= effectiveLimit else { throw Self.listingFailure("pagination", "返回超过有效页长") }
        return SHT115Page(entries: entries, total: total, path: (obj["path"] as? [[String: Any]]) ?? (nested["path"] as? [[String: Any]]) ?? [], endpoint: selectedEndpoint, offset: offset, pageLimit: effectiveLimit)
    }
    static func entries(_ raw: [[String: Any]]) throws -> [SHT115Entry] {
        try raw.map { item -> SHT115Entry in
            let fid = Self.string(item["fid"] ?? item["file_id"])
            let directory = fid.isEmpty || fid == "0"
            let id = directory ? Self.string(item["cid"] ?? item["category_id"] ?? item["folder_id"]) : fid
            guard SHT115Settings.isCID(id), id != "0" else { throw Self.listingFailure("list", "条目标识无效") }
            let name = Self.string(item["n"] ?? item["name"] ?? item["file_name"] ?? item["category_name"])
            guard !name.isEmpty else { throw Self.listingFailure("list", "条目名称缺失，不能证明不存在") }
            return SHT115Entry(id: id, name: name, isDirectory: directory,
                pickCode: Self.string(item["pc"] ?? item["pick_code"] ?? item["pickcode"]), size: Int64(Self.string(item["s"] ?? item["file_size"] ?? item["size"])) ?? 0)
        }
    }
    static func verifiedPath(_ path: [[String: Any]], cid: String, parent: String?) throws {
        let ids = path.map { string($0["cid"] ?? $0["category_id"] ?? $0["folder_id"]) }
        guard ids.first == "0", ids.last == cid, ids.allSatisfy(SHT115Settings.isCID), Set(ids).count == ids.count else { throw SHT115Diagnostic(stage: "directory-path", outcome: "路径或直属父目录无法验证，已停止写入", code: "") }
        if let parent {
            guard ids.count >= 2, ids[ids.count - 2] == parent, cid != parent else { throw SHT115Diagnostic(stage: "directory-path", outcome: "路径或直属父目录无法验证，已停止写入", code: "") }
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
    /// Full bounded enumeration is the only absence proof; /files search_value
    /// is not a search contract and may silently return an ordinary first page.
    func allEntries(cid: String, settings: SHT115Settings, firstPage: SHT115Page? = nil) async throws -> [SHT115Entry] {
        var entries: [SHT115Entry] = [], seen = Set<String>()
        var initial: SHT115Page?
        for index in 0..<500 {
            let current: SHT115Page
            if index == 0, let firstPage { current = firstPage }
            else { current = try await page(cid: cid, offset: entries.count, settings: settings, endpoint: initial?.endpoint) }
            guard current.offset == entries.count else { throw Self.listingFailure("pagination", "分页位置不符") }
            try Self.verifiedPath(current.path, cid: cid, parent: nil)
            if let initial {
                guard current.endpoint == initial.endpoint, current.pageLimit == initial.pageLimit else { throw Self.listingFailure("pagination", "分页端点或有效页长变化") }
                guard current.total == initial.total else { throw Self.listingFailure("count", "分页总数变化") }
                let ids = current.path.map { Self.string($0["cid"] ?? $0["category_id"] ?? $0["folder_id"]) }
                let old = initial.path.map { Self.string($0["cid"] ?? $0["category_id"] ?? $0["folder_id"]) }
                guard ids == old else { throw Self.listingFailure("path", "分页路径变化") }
            } else { initial = current }
            if let total = current.total, total > 50_000 { throw Self.listingFailure("cap", "总数超过500页只读上限") }
            guard current.entries.count <= 100 else { throw Self.listingFailure("list", "返回超过请求页长") }
            let ids = current.entries.map { ($0.isDirectory ? "d" : "f") + $0.id }
            guard Set(ids).count == ids.count, ids.allSatisfy({ !seen.contains($0) }) else { throw Self.listingFailure("duplicate", "分页条目重复") }
            seen.formUnion(ids); entries += current.entries
            if let total = current.total {
                guard total >= 0, entries.count <= total else { throw Self.listingFailure("count", "累计条目与总数冲突") }
                if entries.count == total { return entries }
                guard !current.entries.isEmpty else { throw Self.listingFailure("count", "未达到总数却返回空页") }
            } else if current.entries.isEmpty { return entries }
        }
        throw Self.listingFailure("cap", "达到500页只读上限，尚不能证明完整")
    }
    static func listingFailure(_ stage: String, _ reason: String) -> SHT115Diagnostic {
        SHT115Diagnostic(stage: "directory-" + stage, outcome: reason + "，已停止写入", code: "")
    }
    func matchingDirectories(name: String, parentCID: String, parentPage: SHT115Page, settings: SHT115Settings) async throws -> [SHT115Entry] {
        let entries = try await allEntries(cid: parentCID, settings: settings, firstPage: parentPage)
        let matches = entries.filter { $0.isDirectory && $0.name == name }
        for match in matches {
            let candidate = try await verifiedPage(cid: match.id, parent: parentCID, settings: settings)
            let leafName = Self.string(candidate.path.last?["name"] ?? candidate.path.last?["n"])
            guard !leafName.isEmpty, leafName == name else {
                throw Self.listingFailure("path", "候选目录名称缺失或已变化；不能视为不存在")
            }
        }
        return matches
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
