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
        self.session = session ?? URLSession(configuration: config)
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
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw fields == nil ? SHT115Error.rejected : SHT115Error.uncertainWrite
        }
        return (data, response.url ?? url)
    }
    func json(_ endpoint: String, settings: SHT115Settings, fields: [(String, String)]? = nil) async throws -> [String: Any] {
        let (data, _) = try await data(endpoint, settings: settings, fields: fields)
        // Preserve identifier tokens before Foundation JSON parsing (never Double).
        guard var text = String(data: data, encoding: .utf8) else { throw SHT115Error.unsafeListing }
        let regex = try NSRegularExpression(pattern: "(\"(?:cid|pid|parent_id|category_id|folder_id|file_id|fid|id|wp_path_id)\"\\s*:\\s*)([0-9]+)(?=\\s*[,}])")
        text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1\"$2\"")
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw SHT115Error.unsafeListing }
        return obj
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
        let obj = try await json("https://webapi.115.com/files?" + query, settings: settings)
        guard Self.success(obj) else { throw SHT115Error.rejected }
        let nested = obj["data"] as? [String: Any] ?? [:]
        guard let raw = (obj["data"] as? [[String: Any]]) ?? (nested["list"] as? [[String: Any]]) ?? (obj["files"] as? [[String: Any]]) else { throw SHT115Error.unsafeListing }
        let entries = try raw.map { item -> SHT115Entry in
            let fid = Self.string(item["fid"] ?? item["file_id"])
            let directory = fid.isEmpty || fid == "0"
            let id = directory ? Self.string(item["cid"] ?? item["category_id"] ?? item["folder_id"]) : fid
            guard SHT115Settings.isCID(id), id != "0" else { throw SHT115Error.unsafeListing }
            return SHT115Entry(id: id, name: Self.string(item["n"] ?? item["name"] ?? item["file_name"] ?? item["category_name"]), isDirectory: directory,
                pickCode: Self.string(item["pc"] ?? item["pick_code"] ?? item["pickcode"]), size: Int64(Self.string(item["s"] ?? item["file_size"] ?? item["size"])) ?? 0)
        }
        return SHT115Page(entries: entries, total: Int(Self.string(obj["count"] ?? nested["count"])), path: (obj["path"] as? [[String: Any]]) ?? (nested["path"] as? [[String: Any]]) ?? [])
    }
    static func verifiedPath(_ path: [[String: Any]], cid: String, parent: String?) throws {
        let ids = path.map { string($0["cid"] ?? $0["category_id"] ?? $0["folder_id"]) }
        guard ids.first == "0", ids.last == cid, ids.allSatisfy(SHT115Settings.isCID), Set(ids).count == ids.count else { throw SHT115Error.unsafeListing }
        if let parent {
            guard ids.count >= 2, ids[ids.count - 2] == parent, cid != parent else { throw SHT115Error.unsafeListing }
        }
    }
    func verify(cid: String, parent: String?, settings: SHT115Settings) async throws {
        let page = try await page(cid: cid, offset: 0, settings: settings)
        try Self.verifiedPath(page.path, cid: cid, parent: parent)
    }
    func allEntries(cid: String, settings: SHT115Settings) async throws -> [SHT115Entry] {
        var entries: [SHT115Entry] = [], seen = Set<String>()
        for index in 0..<20 {
            let page = try await page(cid: cid, offset: index * 100, settings: settings)
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
}
