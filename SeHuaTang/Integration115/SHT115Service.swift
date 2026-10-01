import Foundation

public actor SHT115Service {
    private let http: SHT115HTTP
    private let storeURL: URL
    private var records: [SHT115Resource]
    private var operating = false
    public init(storeURL: URL? = nil, session: URLSession? = nil) throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.storeURL = storeURL ?? base.appendingPathComponent("SeHuaTang/115-resources-v1.json")
        self.http = SHT115HTTP(session: session)
        if FileManager.default.fileExists(atPath: self.storeURL.path) {
            do { records = try JSONDecoder().decode([SHT115Resource].self, from: Data(contentsOf: self.storeURL)) }
            catch { throw SHT115Error.persistence }
        } else { records = [] }
        for r in records.indices {
            for t in records[r].tasks.indices where records[r].tasks[t].state == .submitting { records[r].tasks[t].state = .unknown }
        }
    }
    public func resources() -> [SHT115Resource] { records }
    private func begin() throws {
        guard !operating else { throw SHT115Error.busy }
        operating = true
    }
    private func save() throws {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: storeURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        } catch { throw SHT115Error.persistence }
    }
    private func index(_ id: String, _ settings: SHT115Settings) throws -> Int {
        try settings.validate()
        guard let i = records.firstIndex(where: { $0.id == id }) else { throw SHT115Error.invalidInput }
        guard records[i].account == settings.account else { throw SHT115Error.accountMismatch }
        return i
    }
    private func sign(_ settings: SHT115Settings) async throws -> [(String, String)] {
        let obj = try await http.json("https://115.com/?ct=offline&ac=space&_=" + String(Int(Date().timeIntervalSince1970 * 1000)), settings: settings)
        let sign = SHT115HTTP.string(obj["sign"]), time = SHT115HTTP.string(obj["time"])
        guard !sign.isEmpty, !time.isEmpty else { throw SHT115Error.rejected }
        return [("sign", sign), ("time", time)]
    }
    public func validateSettings(_ settings: SHT115Settings) async throws {
        try begin(); defer { operating = false }
        try settings.validate()
        try await http.verify(cid: settings.parentCID, parent: nil, settings: settings)
        _ = try await sign(settings)
    }
    public static func directoryName(tid: String, title: String) throws -> String {
        guard !tid.isEmpty, tid.count <= 64, tid.utf8.allSatisfy({ (48...57).contains($0) }) else { throw SHT115Error.invalidInput }
        let normalized = title.precomposedStringWithCanonicalMapping
        let illegal = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        let clean = normalized.unicodeScalars.map { illegal.contains($0) ? " " : String($0) }.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let safe = String((clean.isEmpty ? "资源" : clean).prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return "tid-" + tid + "_" + safe + "_" + SHT115Digest(normalized).prefix(8)
    }
    public func createOrReuseResource(tid: String, title: String, settings: SHT115Settings) async throws -> SHT115Resource {
        try begin(); defer { operating = false }
        try settings.validate()
        let name = try Self.directoryName(tid: tid, title: title)
        let id = SHT115Digest(settings.account + ":" + settings.parentCID + ":" + name)
        if !records.contains(where: { $0.id == id }) {
            records.append(SHT115Resource(id: id, account: settings.account, tid: tid, directoryName: name, parentCID: settings.parentCID, directoryCID: nil, directoryWritePending: false, tasks: [])); try save()
        }
        let i = try index(id, settings)
        if let cid = records[i].directoryCID {
            try await http.verify(cid: cid, parent: records[i].parentCID, settings: settings)
            records[i].directoryWritePending = false; try save(); return records[i]
        }
        try await http.verify(cid: settings.parentCID, parent: nil, settings: settings)
        let children = try await http.allEntries(cid: settings.parentCID, settings: settings)
        let matches = children.filter { $0.isDirectory && $0.name == name }
        guard matches.count <= 1 else { throw SHT115Error.ambiguousDirectory }
        if let existing = matches.first {
            try await http.verify(cid: existing.id, parent: settings.parentCID, settings: settings)
            records[i].directoryCID = existing.id; records[i].directoryWritePending = false; try save(); return records[i]
        }
        guard !records[i].directoryWritePending else { throw SHT115Error.uncertainWrite }
        records[i].directoryWritePending = true; try save()
        do {
            let obj = try await http.json("https://webapi.115.com/files/add", settings: settings, fields: [("pid", settings.parentCID), ("cname", name)])
            if ["0", "false"].contains(SHT115HTTP.string(obj["state"])) {
                records[i].directoryWritePending = false; try save(); throw SHT115Error.rejected
            }
            guard SHT115HTTP.success(obj) else { throw SHT115Error.uncertainWrite }
            let nested = obj["data"] as? [String: Any] ?? [:]
            let cid = SHT115HTTP.string(obj["cid"] ?? obj["category_id"] ?? nested["cid"] ?? nested["category_id"])
            guard SHT115Settings.isCID(cid), cid != settings.parentCID, cid != "0" else { throw SHT115Error.uncertainWrite }
            records[i].directoryCID = cid; try save()
            try await http.verify(cid: cid, parent: settings.parentCID, settings: settings)
            records[i].directoryWritePending = false; try save(); return records[i]
        } catch SHT115Error.rejected { throw SHT115Error.rejected }
          catch { throw SHT115Error.uncertainWrite }
    }
    public func submit(urls: [String], resourceID: String, settings: SHT115Settings) async throws -> SHT115Resource {
        try begin(); defer { operating = false }
        let i = try index(resourceID, settings)
        let links = Array(Set(urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
        guard !links.isEmpty, links.count <= 50, links.allSatisfy({ link in
            guard !link.contains("\n"), !link.contains("\r"), let url = URL(string: link), let scheme = url.scheme else { return false }
            return ["magnet", "ed2k", "http", "https"].contains(scheme.lowercased())
        }), let cid = records[i].directoryCID, !records[i].directoryWritePending else { throw SHT115Error.invalidInput }
        let prior = records[i].tasks.flatMap { $0.state == .rejected ? [] : $0.urls }
        guard links.allSatisfy({ !prior.contains($0) }) else { throw SHT115Error.uncertainWrite }
        try await http.verify(cid: cid, parent: records[i].parentCID, settings: settings)
        let signature = try await sign(settings)
        records[i].tasks.append(SHT115Task(id: UUID(), urls: links, state: .submitting, progress: [], updatedAt: Date())); try save()
        let t = records[i].tasks.count - 1
        let fields = signature + [("wp_path_id", cid)] + links.enumerated().map { (links.count == 1 ? "url" : "url[\($0.offset)]", $0.element) }
        do {
            let action = links.count == 1 ? "add_task_url" : "add_task_urls"
            let obj = try await http.json("https://115.com/web/lixian/?ct=lixian&ac=" + action, settings: settings, fields: fields)
            if SHT115HTTP.success(obj) { records[i].tasks[t].state = .accepted }
            else if ["0", "false"].contains(SHT115HTTP.string(obj["state"])), links.count == 1 { records[i].tasks[t].state = .rejected }
            else { records[i].tasks[t].state = .unknown }
            records[i].tasks[t].updatedAt = Date(); try save()
        } catch {
            records[i].tasks[t].state = .unknown; records[i].tasks[t].updatedAt = Date(); try save(); throw SHT115Error.uncertainWrite
        }
        if records[i].tasks[t].state == .unknown { throw SHT115Error.uncertainWrite }
        if records[i].tasks[t].state == .rejected { throw SHT115Error.rejected }
        return records[i]
    }
    public func listVideos(resourceID: String, settings: SHT115Settings, maxDepth: Int = 3) async throws -> SHT115VideoListing {
        try begin(); defer { operating = false }
        return try await scan(resourceID: resourceID, settings: settings, maxDepth: maxDepth)
    }
    private func scan(resourceID: String, settings: SHT115Settings, maxDepth: Int) async throws -> SHT115VideoListing {
        let i = try index(resourceID, settings)
        guard let root = records[i].directoryCID else { throw SHT115Error.invalidInput }
        try await http.verify(cid: root, parent: records[i].parentCID, settings: settings)
        let depthLimit = max(0, min(5, maxDepth))
        var queue = [(root, 0)], visited = Set<String>(), videos: [SHT115Video] = [], archives: [SHT115Archive] = []
        var truncated = false
        let videoExtensions = Set(["mp4", "m4v", "mov", "mkv", "avi", "wmv", "ts", "m2ts", "webm", "flv", "mpg", "mpeg"])
        let archiveExtensions = Set(["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "001"])
        while !queue.isEmpty {
            if visited.count >= 100 { truncated = true; break }
            let (cid, depth) = queue.removeFirst()
            guard visited.insert(cid).inserted else { truncated = true; continue }
            let entries: [SHT115Entry]
            do { entries = try await http.allEntries(cid: cid, settings: settings) }
            catch SHT115Error.unsafeListing { truncated = true; continue }
            for entry in entries {
                if entry.isDirectory {
                    if depth < depthLimit { queue.append((entry.id, depth + 1)) } else { truncated = true }
                } else {
                    let ext = (entry.name as NSString).pathExtension.lowercased()
                    if videoExtensions.contains(ext), !entry.pickCode.isEmpty {
                        videos.append(SHT115Video(id: entry.id, resourceID: resourceID, directoryCID: cid, name: entry.name, pickCode: entry.pickCode, size: entry.size))
                    } else if archiveExtensions.contains(ext) { archives.append(SHT115Archive(id: entry.id, name: entry.name, directoryCID: cid)) }
                }
            }
        }
        return SHT115VideoListing(videos: videos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, archives: archives, truncated: truncated)
    }
    public func inspect(resourceID: String, settings: SHT115Settings) async throws -> SHT115Inspection {
        try begin(); defer { operating = false }
        let i = try index(resourceID, settings)
        guard let target = records[i].directoryCID else { throw SHT115Error.invalidInput }
        var remote: [[String: Any]] = [], seen = Set<String>(), truncated = true
        for page in 1...20 {
            let obj = try await http.json("https://115.com/web/lixian/?ct=lixian&ac=task_lists&page=\(page)", settings: settings)
            guard SHT115HTTP.success(obj) else { throw SHT115Error.rejected }
            let data = obj["data"] as? [String: Any] ?? [:]
            guard let tasks = (obj["tasks"] as? [[String: Any]]) ?? (data["tasks"] as? [[String: Any]]) else { throw SHT115Error.unsafeListing }
            let signature = tasks.map { SHT115HTTP.string($0["info_hash"] ?? $0["url"]) }.joined(separator: "|")
            if tasks.isEmpty { truncated = false; break }
            if !seen.insert(signature).inserted { break }
            remote += tasks
            let pageCount = Int(SHT115HTTP.string(obj["page_count"] ?? data["page_count"]))
            if let pageCount = pageCount, page >= pageCount { truncated = false; break }
        }
        for t in records[i].tasks.indices {
            var matches: [SHT115Progress] = []
            for link in records[i].tasks[t].urls {
                let hash = Self.infoHash(link)
                if let task = remote.first(where: {
                    SHT115HTTP.string($0["wp_path_id"]) == target &&
                    (SHT115HTTP.string($0["url"] ?? $0["url_string"]) == link || (!hash.isEmpty && SHT115HTTP.string($0["info_hash"] ?? $0["hash"]).lowercased() == hash))
                }) {
                    matches.append(SHT115Progress(url: link, infoHash: SHT115HTTP.string(task["info_hash"] ?? task["hash"]), status: Int(SHT115HTTP.string(task["status"])) ?? -999, percent: Double(SHT115HTTP.string(task["percentDone"] ?? task["percent"])) ?? 0))
                }
            }
            records[i].tasks[t].progress = matches
            if matches.count == records[i].tasks[t].urls.count { records[i].tasks[t].state = .accepted }
            records[i].tasks[t].updatedAt = Date()
        }
        try save()
        let listing = try await scan(resourceID: resourceID, settings: settings, maxDepth: 3)
        return SHT115Inspection(resource: records[i], listing: listing, taskPagesTruncated: truncated)
    }
    private static func infoHash(_ link: String) -> String {
        guard let components = URLComponents(string: link), let xt = components.queryItems?.first(where: { $0.name == "xt" })?.value, xt.lowercased().hasPrefix("urn:btih:") else { return "" }
        let raw = String(xt.dropFirst(9)).lowercased()
        if raw.count == 40, raw.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { return raw }
        return ""
    }
    public func resolvePlayback(video: SHT115Video, settings: SHT115Settings) async throws -> [SHT115PlaybackSource] {
        try begin(); defer { operating = false }
        let listing = try await scan(resourceID: video.resourceID, settings: settings, maxDepth: 5)
        guard listing.videos.contains(where: { $0.id == video.id && $0.pickCode == video.pickCode && $0.directoryCID == video.directoryCID }), video.pickCode.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw SHT115Error.invalidInput }
        let headers = SHT115HTTP.headers(settings)
        let endpoint = "https://115.com/api/video/m3u8/" + video.pickCode + ".m3u8"
        if let (data, base) = try? await http.data(endpoint, settings: settings), let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var result: [SHT115PlaybackSource] = [], attributes: String?
            for line in lines {
                if line.hasPrefix("#EXT-X-STREAM-INF:") { attributes = line; continue }
                if let info = attributes, !line.isEmpty, !line.hasPrefix("#") {
                    if let url = URL(string: line, relativeTo: base)?.absoluteURL, ["http", "https"].contains(url.scheme ?? "") {
                        let bandwidth = Self.attribute("BANDWIDTH", in: info).flatMap(Int.init) ?? 0
                        let resolution = Self.attribute("RESOLUTION", in: info) ?? "转码"
                        result.append(SHT115PlaybackSource(label: resolution, url: url, bandwidth: bandwidth, headers: headers))
                    }
                    attributes = nil
                }
            }
            if !result.isEmpty { return result.sorted { $0.bandwidth > $1.bandwidth } }
            if !text.contains("#EXT-X-STREAM-INF"), text.contains("#EXTINF") { return [SHT115PlaybackSource(label: "HLS", url: base, bandwidth: 0, headers: headers)] }
        }
        for host in ["115vod.com", "webapi.115.com"] {
            let path = host == "115vod.com" ? "/webapi/files/video" : "/files/video"
            if let obj = try? await http.json("https://" + host + path + "?pickcode=" + video.pickCode + "&local=1", settings: settings) {
                let data = obj["data"] as? [String: Any] ?? [:]
                let raw = SHT115HTTP.string(obj["download_url"] ?? obj["video_url"] ?? obj["url"] ?? data["download_url"] ?? data["video_url"] ?? data["url"])
                if let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") { return [SHT115PlaybackSource(label: "原文件（原生播放器可能不支持容器）", url: url, bandwidth: 0, headers: headers)] }
            }
        }
        throw SHT115Error.playbackUnavailable
    }
    private static func attribute(_ key: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?:[:,])" + key + "=([^,]+)"), let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    public func requestExtraction(archive: SHT115Archive, resourceID: String, settings: SHT115Settings, confirmed: Bool) async throws -> SHT115ExtractionResult {
        let listing = try await listVideos(resourceID: resourceID, settings: settings)
        guard listing.archives.contains(where: { $0.id == archive.id && $0.directoryCID == archive.directoryCID }) else { throw SHT115Error.invalidInput }
        if !confirmed { return SHT115ExtractionResult(state: .awaitingConfirmation, message: "压缩包尚未解压。云解压属于账号写操作，需要用户明确确认。") }
        return SHT115ExtractionResult(state: .unsupported, message: "当前版本尚未验证完整云解压协议，未发送解压请求。请在115将此包解压到当前资源目录，然后手动刷新；不删除原包，不绕过密码。")
    }
}
