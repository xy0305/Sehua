import Foundation

public actor SHT115Service {
    private let http: SHT115HTTP
    private let storeURL: URL
    private var records: [SHT115Resource]
    private var operating = false
    private var interactiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []
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
            for (key, value) in records[r].extractions ?? [:] where value == .submitting { records[r].extractions?[key] = .unknown }
        }
    }
    public func resources() -> [SHT115Resource] { records }
    // Hold the permit across actor reentrancy. Interactive FIFO wins at each
    // operation boundary; background reads/extraction never reject a push as busy.
    private func begin(background: Bool = false) async throws {
        try Task.checkCancellation()
        if operating {
            await withCheckedContinuation { continuation in
                if background { backgroundWaiters.append(continuation) }
                else { interactiveWaiters.append(continuation) }
            }
        } else { operating = true }
        // A cancelled waiter must hand its granted permit on before leaving.
        if Task.isCancelled { end(); throw CancellationError() }
    }
    private func end() {
        if !interactiveWaiters.isEmpty { interactiveWaiters.removeFirst().resume() }
        else if !backgroundWaiters.isEmpty { backgroundWaiters.removeFirst().resume() }
        else { operating = false }
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
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let obj = try await http.json("https://115.com/?ct=offline&ac=space&_=" + timestamp, settings: settings)
        let sign = SHT115HTTP.string(obj["sign"])
        let returnedTime = SHT115HTTP.string(obj["time"])
        guard !sign.isEmpty else { throw SHT115Diagnostic(stage: "signature", outcome: "未提交：签名为空", code: SHT115Diagnostic.apiCode(obj)) }
        // Same fallback as tang115 and Pan115Client; keep server time when present.
        return [("sign", sign), ("time", returnedTime.isEmpty ? timestamp : returnedTime)]
    }
    public func validateSettings(_ settings: SHT115Settings) async throws {
        try await begin(); defer { end() }
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
        return (safe.isEmpty ? "资源" : safe) + "_tid-" + tid
    }
    public func createOrReuseResource(tid: String, title: String, settings: SHT115Settings) async throws -> SHT115Resource {
        try await begin(); defer { end() }
        try settings.validate()
        let name = try Self.directoryName(tid: tid, title: title)
        // Reuse this account's historical tid record, including incorrectly named folders.
        // Never rename/delete it or create a second folder merely because title parsing changed.
        let id = records.first(where: { $0.account == settings.account && $0.parentCID == settings.parentCID && $0.tid == tid })?.id
            ?? SHT115Digest(settings.account + ":" + settings.parentCID + ":" + name)
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
        let matches = children.filter { $0.isDirectory && $0.name == records[i].directoryName }
        guard matches.count <= 1 else { throw SHT115Error.ambiguousDirectory }
        if let existing = matches.first {
            try await http.verify(cid: existing.id, parent: settings.parentCID, settings: settings)
            records[i].directoryCID = existing.id; records[i].directoryWritePending = false; try save(); return records[i]
        }
        guard !records[i].directoryWritePending else { throw SHT115Error.uncertainWrite }
        records[i].directoryWritePending = true; try save()
        do {
            let obj = try await http.json("https://webapi.115.com/files/add", settings: settings, fields: [("pid", settings.parentCID), ("cname", records[i].directoryName)])
            if ["0", "false"].contains(SHT115HTTP.string(obj["state"])) {
                records[i].directoryWritePending = false; try save(); throw SHT115Diagnostic(stage: "directory-create", outcome: "API明确拒绝（未创建）", code: SHT115Diagnostic.apiCode(obj))
            }
            guard SHT115HTTP.success(obj) else { throw SHT115Error.uncertainWrite }
            let nested = obj["data"] as? [String: Any] ?? [:]
            let cid = SHT115HTTP.string(obj["cid"] ?? obj["category_id"] ?? nested["cid"] ?? nested["category_id"])
            guard SHT115Settings.isCID(cid), cid != settings.parentCID, cid != "0" else { throw SHT115Error.uncertainWrite }
            records[i].directoryCID = cid; try save()
            try await http.verify(cid: cid, parent: settings.parentCID, settings: settings)
            records[i].directoryWritePending = false; try save(); return records[i]
        } catch let error as SHT115Diagnostic { throw error }
          catch SHT115Error.persistence { throw SHT115Error.persistence }
          catch let error as URLError {
              throw SHT115Diagnostic(stage: "directory-create", outcome: "结果未知：传输失败，不自动重发", code: String(error.code.rawValue))
          }
          catch { throw SHT115Diagnostic(stage: "directory-create", outcome: "结果未知：响应或路径无法确认，不自动重发", code: "") }
    }
    /// 115 web API uses url for a single link, url[n] (not urls[n]) for a batch.
    static func submissionFields(links: [String], cid: String, uid: String, signature: [(String, String)]) -> [(String, String)] {
        signature + [("uid", uid), ("wp_path_id", cid)] + links.enumerated().map {
            (links.count == 1 ? "url" : "url[\($0.offset)]", $0.element)
        }
    }
    static func submissionState(_ obj: [String: Any], count: Int) -> SHT115SubmissionState {
        let rows = (obj["result"] as? [[String: Any]]) ?? (obj["data"] as? [[String: Any]]) ?? (obj["tasks"] as? [[String: Any]])
        if let rows {
            guard rows.count == count else { return .unknown }
            if rows.allSatisfy({ SHT115HTTP.success($0) }) { return .accepted }
            if rows.allSatisfy({ ["0", "false"].contains(SHT115HTTP.string($0["state"]).lowercased()) }) { return .rejected }
            return .unknown // partial acceptance must never resend the batch
        }
        if SHT115HTTP.success(obj) { return .accepted }
        if ["0", "false"].contains(SHT115HTTP.string(obj["state"]).lowercased()) { return .rejected }
        return .unknown
    }
    public func submit(urls: [String], resourceID: String, settings: SHT115Settings) async throws -> SHT115Resource {
        try await begin(); defer { end() }
        let i = try index(resourceID, settings)
        let links = Array(Set(urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
        guard !links.isEmpty, links.count <= 50, links.allSatisfy({ link in
            guard !link.contains("\n"), !link.contains("\r") else { return false }
            // Raw ed2k pipes/spaces are valid payload, not an HTTP URL to navigate.
            // Foundation URL parsing differs across OS versions; do not block the POST on it.
            if link.lowercased().hasPrefix("ed2k://|file|") {
                let parts = link.components(separatedBy: "|")
                guard parts.count >= 6, !parts[2].isEmpty, let size = UInt64(parts[3]), size > 0 else { return false }
                return parts[4].count == 32 && parts[4].utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } && parts.last == "/"
            }
            guard let url = URL(string: link), let scheme = url.scheme else { return false }
            return ["magnet", "http", "https"].contains(scheme.lowercased())
        }), let cid = records[i].directoryCID, !records[i].directoryWritePending else { throw SHT115Error.invalidInput }
        let prior = records[i].tasks.flatMap { $0.state == .rejected ? [] : $0.urls }
        guard links.allSatisfy({ !prior.contains($0) }) else {
            if records[i].tasks.contains(where: { ($0.state == .unknown || $0.state == .submitting) && !$0.urls.filter(links.contains).isEmpty }) { throw SHT115Error.uncertainWrite }
            throw SHT115Error.alreadySubmitted
        }
        do { try await http.verify(cid: cid, parent: records[i].parentCID, settings: settings) }
        catch { throw SHT115Diagnostic(stage: "verify-before-submit", outcome: "未提交：目标路径无法验证", code: "") }
        let signature: [(String, String)]
        do { signature = try await sign(settings) }
        catch let error as SHT115Diagnostic { throw error }
        catch { throw SHT115Diagnostic(stage: "signature", outcome: "未提交：签名请求失败", code: "") }
        records[i].tasks.append(SHT115Task(id: UUID(), urls: links, state: .submitting, progress: [], updatedAt: Date())); try save()
        let t = records[i].tasks.count - 1
        let fields = Self.submissionFields(links: links, cid: cid, uid: settings.uid, signature: signature)
        var apiCode = ""
        do {
            let action = links.count == 1 ? "add_task_url" : "add_task_urls"
            let obj = try await http.json("https://115.com/web/lixian/?ct=lixian&ac=" + action, settings: settings, fields: fields)
            apiCode = SHT115Diagnostic.apiCode(obj)
            records[i].tasks[t].state = Self.submissionState(obj, count: links.count)
            records[i].tasks[t].updatedAt = Date(); try save()
        } catch {
            records[i].tasks[t].state = .unknown; records[i].tasks[t].updatedAt = Date(); try save()
            throw SHT115Diagnostic(stage: "submit", outcome: "结果未知：传输或响应无法确认", code: "")
        }
        if records[i].tasks[t].state == .unknown { throw SHT115Diagnostic(stage: "submit", outcome: "结果未知：响应未确认完整受理", code: apiCode) }
        if records[i].tasks[t].state == .rejected { throw SHT115Diagnostic(stage: "submit", outcome: "API明确拒绝", code: apiCode) }
        return records[i]
    }
    public func listVideos(resourceID: String, settings: SHT115Settings, maxDepth: Int = 3, background: Bool = false) async throws -> SHT115VideoListing {
        try await begin(background: background); defer { end() }
        return try await scan(resourceID: resourceID, settings: settings, maxDepth: maxDepth)
    }
    private func scan(resourceID: String, settings: SHT115Settings, maxDepth: Int) async throws -> SHT115VideoListing {
        let i = try index(resourceID, settings)
        guard let root = records[i].directoryCID else { throw SHT115Error.invalidInput }
        try await http.verify(cid: root, parent: records[i].parentCID, settings: settings)
        let depthLimit = max(0, min(5, maxDepth))
        var queue = [(root, 0, records[i].parentCID)], visited = Set<String>(), videos: [SHT115Video] = [], archives: [SHT115Archive] = []
        var truncated = false
        let videoExtensions = Set(["mp4", "m4v", "mov", "mkv", "avi", "wmv", "ts", "m2ts", "webm", "flv", "mpg", "mpeg"])
        let archiveExtensions = Set(["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "001"])
        while !queue.isEmpty {
            if visited.count >= 100 { truncated = true; break }
            let (cid, depth, parent) = queue.removeFirst()
            guard visited.insert(cid).inserted else { truncated = true; continue }
            let entries: [SHT115Entry]
            do {
                try await http.verify(cid: cid, parent: parent, settings: settings)
                entries = try await http.allEntries(cid: cid, settings: settings)
            }
            catch SHT115Error.unsafeListing { truncated = true; continue }
            for entry in entries {
                if entry.isDirectory {
                    if depth < depthLimit { queue.append((entry.id, depth + 1, cid)) } else { truncated = true }
                } else {
                    let ext = (entry.name as NSString).pathExtension.lowercased()
                    if videoExtensions.contains(ext), !entry.pickCode.isEmpty {
                        videos.append(SHT115Video(id: entry.id, resourceID: resourceID, directoryCID: cid, name: entry.name, pickCode: entry.pickCode, size: entry.size))
                    } else if archiveExtensions.contains(ext) { archives.append(SHT115Archive(id: entry.id, name: entry.name, directoryCID: cid, pickCode: entry.pickCode)) }
                }
            }
        }
        return SHT115VideoListing(videos: videos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, archives: archives, truncated: truncated)
    }
    public func inspect(resourceID: String, settings: SHT115Settings, background: Bool = false) async throws -> SHT115Inspection {
        try await begin(background: background); defer { end() }
        let i = try index(resourceID, settings)
        guard let target = records[i].directoryCID else { throw SHT115Error.invalidInput }
        // Directory availability is independent of the account's offline task history.
        let listing = try await scan(resourceID: resourceID, settings: settings, maxDepth: 3)
        var remote: [[String: Any]] = [], truncated = false
        let hashes = Array(Set(records[i].tasks.flatMap { $0.urls }.map(Self.infoHash).filter { !$0.isEmpty })).sorted()
        for hash in hashes.prefix(32) {
            do {
                let obj = try await http.json("https://115.com/web/lixian/?ct=lixian&ac=task_lists&page=1&info_hash=" + hash, settings: settings)
                guard SHT115HTTP.success(obj) else { throw SHT115Error.rejected }
                let data = obj["data"] as? [String: Any] ?? [:]
                guard let rows = (obj["tasks"] as? [[String: Any]]) ?? (data["tasks"] as? [[String: Any]]) else { throw SHT115Error.unsafeListing }
                remote += rows
            } catch { truncated = true }
        }
        if hashes.count > 32 { truncated = true }
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
        return SHT115Inspection(resource: records[i], listing: listing, taskPagesTruncated: truncated)
    }
    static func infoHash(_ link: String) -> String {
        if link.lowercased().hasPrefix("ed2k://|file|") {
            let parts = link.components(separatedBy: "|")
            if parts.count > 4 {
                let hash = parts[4].lowercased()
                if hash.count == 32 && hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { return hash }
            }
            return ""
        }
        guard let components = URLComponents(string: link), let xt = components.queryItems?.first(where: { $0.name == "xt" })?.value, xt.lowercased().hasPrefix("urn:btih:") else { return "" }
        let raw = String(xt.dropFirst(9)).lowercased()
        if raw.count == 40, raw.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { return raw }
        return ""
    }
    public func resolvePlayback(video: SHT115Video, settings: SHT115Settings) async throws -> [SHT115PlaybackSource] {
        try await begin(); defer { end() }
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
    /// One persisted write intent per archive and phase. Unknown writes are never replayed.
    public func requestExtraction(archive: SHT115Archive, resourceID: String, settings: SHT115Settings, confirmed: Bool, background: Bool = false) async throws -> SHT115ExtractionResult {
        try await begin(background: background); defer { end() }
        let i = try index(resourceID, settings)
        guard confirmed else { return SHT115ExtractionResult(state: .awaitingConfirmation, message: "尚未授权云解压") }
        guard let target = records[i].directoryCID else { throw SHT115Error.invalidInput }
        let listing = try await scan(resourceID: resourceID, settings: settings, maxDepth: 3)
        guard !listing.truncated, let current = listing.archives.first(where: { $0.id == archive.id && $0.directoryCID == archive.directoryCID }),
              let pick = current.pickCode, !pick.isEmpty, pick.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw SHT115Error.unsafeListing }
        let key = archive.id
        var state = records[i].extractions?[key]
        if let state, [.accepted, .unknown, .rejected, .passwordRequired].contains(state) {
            return SHT115ExtractionResult(state: state, message: "云解压状态：" + state.rawValue + "；不重复发送，不删除原包")
        }
        func persist(_ value: SHT115ExtractionState) throws {
            if records[i].extractions == nil { records[i].extractions = [:] }
            records[i].extractions?[key] = value
            try save()
        }
        if state == nil {
            try persist(.submitting)
            do {
                let obj = try await http.json("https://webapi.115.com/files/push_extract", settings: settings, fields: [("pick_code", pick), ("secret", "")])
                guard SHT115HTTP.success(obj) else {
                    let explicit = ["0", "false"].contains(SHT115HTTP.string(obj["state"]))
                    try persist(explicit ? .rejected : .unknown)
                    return SHT115ExtractionResult(state: explicit ? .rejected : .unknown, message: "解析未确认成功；停止自动写入，请在115核对密码与状态")
                }
                try persist(.parsing); state = .parsing
            } catch { try persist(.unknown); throw SHT115Error.uncertainWrite }
        }
        let obj = try await http.json("https://webapi.115.com/files/push_extract?pick_code=" + pick, settings: settings)
        guard SHT115HTTP.success(obj) else { throw SHT115Error.rejected }
        let data = obj["data"] as? [String: Any] ?? [:]
        let status = data["extract_status"] as? [String: Any] ?? [:]
        guard SHT115HTTP.string(status["unzip_status"]) == "4", (Double(SHT115HTTP.string(status["progress"])) ?? 0) >= 100 else {
            return SHT115ExtractionResult(state: .parsing, message: "压缩包解析中；前台刷新继续查询，不重发解析请求")
        }
        let info = try await http.json("https://webapi.115.com/files/extract_info?" + SHT115HTTP.form([("pick_code", pick), ("file_name", ""), ("paths", "文件"), ("page_count", "999")]), settings: settings)
        let contents = info["data"] as? [String: Any] ?? [:]
        guard SHT115HTTP.success(info), let entries = contents["list"] as? [[String: Any]], !entries.isEmpty, entries.count < 999 else { throw SHT115Error.unsafeListing }
        if let total = Int(SHT115HTTP.string(contents["count"])), total != entries.count { throw SHT115Error.unsafeListing }
        var fields = [("pick_code", pick), ("to_pid", target), ("paths", "文件")]
        var names = Set<String>()
        for entry in entries {
            let name = SHT115HTTP.string(entry["file_name"] ?? entry["name"] ?? entry["n"])
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), names.insert(name).inserted else { throw SHT115Error.unsafeListing }
            let directory = SHT115HTTP.string(entry["size"]) == "0" && SHT115HTTP.string(entry["ico"]).isEmpty
            fields.append((directory ? "extract_dir[]" : "extract_file[]", name))
        }
        // Revalidate destination immediately before the only extraction write.
        try await http.verify(cid: target, parent: records[i].parentCID, settings: settings)
        try persist(.submitting)
        do {
            let result = try await http.json("https://webapi.115.com/files/add_extract_file", settings: settings, fields: fields)
            if SHT115HTTP.success(result) { try persist(.accepted) }
            else if ["0", "false"].contains(SHT115HTTP.string(result["state"])) { try persist(.rejected) }
            else { try persist(.unknown) }
        } catch { try persist(.unknown); throw SHT115Error.uncertainWrite }
        return SHT115ExtractionResult(state: records[i].extractions?[key] ?? .unknown, message: "已记录云解压结果；接受不代表完成，保留原包，等待目录出现视频")
    }
}
