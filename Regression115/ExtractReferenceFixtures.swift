import Foundation

final class ExtractReferenceMock: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> String)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let text = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

// Sanitized protocol shapes derived from uploaded JS lines 2140-2340; never execute that script.
@main struct ExtractReferenceFixtures {
    static func object(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    static func fields(_ request: URLRequest) -> [URLQueryItem] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        return URLComponents(string: "https://fixture.invalid/?" + String(decoding: data, as: UTF8.self))?.queryItems ?? []
    }
    static func run(_ mode: String) async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExtractReferenceMock.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        let resource = SHT115Resource(id: "q", account: settings.account, tid: "1", directoryName: "fixture", parentCID: "10", directoryCID: "20", directoryWritePending: false, tasks: [])
        try JSONEncoder().encode([resource]).write(to: store)
        let hash = String(repeating: "a", count: 32), hash2 = String(repeating: "d", count: 32)
        let sha = String(repeating: "b", count: 40), outputSHA = String(repeating: "c", count: 40)
        let nested = mode.hasPrefix("nested")
        let batch = mode.hasPrefix("batch")
        let size: Int64 = 2_147_483_649
        let outputSize: Int64 = mode == "categoryEmptyFile" ? 0 : 4_294_967_298
        let links = ["ed2k://|file|fixture.zip|\(size)|\(hash)|/"] + (batch ? ["ed2k://|file|\(mode == "batchAmbiguous" ? "fixture.zip" : "other.zip")|\(size)|\(hash2)|/"] : [])
        var submitted = false, released = false, parses = 0, releases = 0, deletes = 0, manifestReads = 0
        ExtractReferenceMock.handler = { request in
            let url = request.url!, path = url.path
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func query(_ key: String) -> String { q.first(where: { $0.name == key })?.value ?? "" }
            let bodyFields = fields(request)
            func form(_ key: String) -> String { bodyFields.first(where: { $0.name == key })?.value ?? "" }
            if query("ac") == "space" { return "{\"sign\":\"fake\",\"time\":1}" }
            if ["add_task_url", "add_task_urls"].contains(query("ac")) { submitted = true; return "{\"state\":true}" }
            if query("ac") == "task_lists" {
                let requested = query("info_hash")
                if requested == hash2 && mode == "batchPartial" { return "{\"state\":true,\"page_count\":1,\"tasks\":[]}" }
                return object(["state": true, "page_count": 1, "tasks": [["info_hash": requested, "wp_path_id": mode == "wrongTarget" ? "30" : "20", "file_id": "20", "status": 2, "percentDone": 100]]])
            }
            if path == "/files/push_extract" {
                if request.httpMethod == "POST" {
                    parses += 1; precondition(form("pick_code") == "sourcePC" && form("secret").isEmpty)
                    if mode == "parseTimeout" { throw URLError(.timedOut) }
                    return "{\"state\":true}"
                }
                return "{\"state\":true,\"data\":{\"extract_status\":{\"unzip_status\":4,\"progress\":100}}}"
            }
            if path == "/files/extract_info" {
                manifestReads += 1
                precondition(query("pick_code") == "sourcePC" && query("page_count") == "999")
                var entry: [String: Any] = ["file_name": "movie.mp4", "size": outputSize, "ico": "mp4", "sha1": outputSHA]
                if mode == "categoryEmptyFile" { entry["file_category"] = 1; entry.removeValue(forKey: "ico") }
                if mode == "deepManifest" { entry = ["file_name": "deep", "size": 0, "file_category": 0] }
                if mode == "noOutputHash" || mode == "nestedNoHash" { entry.removeValue(forKey: "sha1") }
                if mode == "unsafeName" { entry["file_name"] = "../movie.mp4" }
                precondition(query("paths") == "文件")
                if nested && query("file_name").isEmpty { entry = ["file_name": "wrapper", "size": "0", "file_category": 0] }
                if nested && !query("file_name").isEmpty { precondition(query("file_name") == "wrapper") }
                var data: [String: Any] = ["list": [entry]] // script requires neither count nor marker
                if mode == "truncatedManifest" { data["next_marker"] = "more" }
                if mode == "badManifestCount" { data["count"] = 2 }
                if mode == "duplicateManifest" { data["list"] = [entry, entry] }
                return object(["state": true, "data": data])
            }
            if path == "/files/add_extract_file" {
                if request.httpMethod == "POST" {
                    releases += 1
                    precondition(form("to_pid") == "20" && form("paths") == "文件")
                    precondition(form(nested ? "extract_dir[]" : "extract_file[]") == (nested ? "wrapper" : "movie.mp4"))
                    if mode == "releaseTimeout" { throw URLError(.timedOut) }
                    released = true
                    return "{\"state\":true,\"data\":{\"extract_id\":900}}"
                }
                precondition(query("extract_id") == "900")
                return mode == "releasePending" ? "{\"state\":true,\"data\":{\"percent\":50}}" : "{\"state\":true,\"data\":{\"percent\":100}}"
            }
            if path == "/rb/delete" {
                deletes += 1
                precondition(bodyFields.count == 2 && form("fid[0]") == "21" && form("pid") == "20")
                return "{\"state\":true}"
            }
            precondition(path == "/files", "unexpected read " + path)
            var entries: [[String: Any]] = []
            if query("cid") == "23" {
                if mode != "nestedMissing" {
                    entries.append(["fid": "24", "n": "movie.mp4", "s": outputSize, "pc": "outputPC", "sha": mode == "nestedHashMismatch" ? sha : outputSHA])
                }
                if mode == "nestedExtra" { entries.append(["fid": "25", "n": "extra.txt", "s": 1, "pc": "extraPC", "sha": sha]) }
            } else {
                if submitted {
                    entries.append(["fid": "21", "n": "fixture.zip", "s": size, "pc": "sourcePC", "sha": mode == "noSourceHash" ? "" : sha])
                    if mode == "duplicateSource" { entries.append(["fid": "31", "n": "fixture.zip", "s": size, "pc": "otherPC", "sha": sha]) }
                }
                if mode == "targetCollision" || released {
                    entries.append(nested ? ["cid": "23", "n": "wrapper"] : ["fid": "22", "n": "movie.mp4", "s": outputSize, "pc": "outputPC", "sha": outputSHA])
                }
            }
            var pathItems: [[String: String]] = [["cid": "0"], ["cid": "10"], ["cid": "20"]]
            if query("cid") == "23" { pathItems.append(["cid": "23"]) }
            let response: [String: Any] = ["state": true, "count": entries.count, "data": entries,
                "path": pathItems, "offset": Int(query("offset")) ?? 0, "limit": 100,
                "order": "file_name", "is_asc": 1, "fc_mix": 1]
            return object(response)
        }
        let service = try SHT115Service(storeURL: store, session: session)
        _ = try await service.submit(urls: links, resourceID: "q", settings: settings, autoExtraction: true)
        let saved = await service.resources()
        precondition(saved[0].extractionQueue?.count == links.count)
        let now = Date()
        try await service.runExtractionQueue(settings: settings, now: now)
        let resumed = try SHT115Service(storeURL: store, session: session)
        for n in 1...3 { try await resumed.runExtractionQueue(settings: settings, now: now.addingTimeInterval(Double(n * 301))) }
        let shouldParse = !["wrongTarget", "noSourceHash", "duplicateSource", "batchAmbiguous"].contains(mode)
        let shouldRelease = shouldParse && !["parseTimeout", "unsafeName", "truncatedManifest", "badManifestCount", "duplicateManifest", "targetCollision", "deepManifest"].contains(mode)
        let shouldDelete = ["largeFlat", "categoryEmptyFile", "nestedComplete", "batchPartial"].contains(mode)
        precondition(parses == (shouldParse ? 1 : 0), mode + " parse count \(parses)")
        precondition(releases == (shouldRelease ? 1 : 0), mode + " release count \(releases)")
        precondition(deletes == (shouldDelete ? 1 : 0), mode + " recycle count \(deletes)")
        precondition(manifestReads <= (mode == "deepManifest" ? 24 : (nested ? 8 : 4)), "bounded reads")
        if mode == "batchPartial" {
            let final = await resumed.resources()
            precondition(final[0].extractionQueue?.filter { $0.state == .recycled }.count == 1)
            precondition(final[0].extractionQueue?.filter { $0.state == .waiting }.count == 1)
        }
        print("PASS uploaded-reference production protocol: " + mode)
    }
    static func main() async throws {
        for mode in ["largeFlat", "categoryEmptyFile", "deepManifest", "nestedComplete", "nestedMissing", "nestedExtra", "nestedHashMismatch", "nestedNoHash", "noOutputHash", "wrongTarget", "noSourceHash", "duplicateSource", "batchPartial", "batchAmbiguous", "parseTimeout", "releaseTimeout", "releasePending", "unsafeName", "truncatedManifest", "badManifestCount", "duplicateManifest", "targetCollision"] { try await run(mode) }
    }
}
