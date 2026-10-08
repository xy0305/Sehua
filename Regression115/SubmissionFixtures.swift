import Foundation

final class Mock115Protocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let text = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: pagingFixtureData(text))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
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

/// Compile with Integration115/*.swift (not the other @main fixtures). No real network.
@main struct SubmissionFixtures {
    static let ed = "ed2k://|file|www.98T.la@[AlinaxMei]%20My%20best%20friend's%20Asian%20girlfriend%20got%20a%20creampie.mp4|1776335157|F9521F774DC30A5FE980E23DCDEF19C7|/"
    static func body(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(contentsOf: buffer.prefix(n))
            }
        }
        let text = String(data: data, encoding: .utf8)!
        return Dictionary(uniqueKeysWithValues: text.split(separator: "&").map {
            let parts = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]).removingPercentEncoding!, String(parts[1]).removingPercentEncoding!)
        })
    }
    static func run(_ response: String, expected: SHT115SubmissionState, batch: Bool = false, brokenPath: Bool = false, transport: Bool = false, afterReadFailure: Bool = false) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Mock115Protocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: store) }
        let settings = SHT115Settings(cookie: "UID=123_A1; CID=fake; SEID=fake", parentCID: "10")
        let service = try SHT115Service(storeURL: store, session: session)
        var calls: [String] = []
        var verified = 0
        Mock115Protocol.handler = { request in
            let url = request.url!
            precondition(request.value(forHTTPHeaderField: "Cookie") == settings.cookie)
            precondition(request.value(forHTTPHeaderField: "Origin") == "https://115.com")
            precondition(request.value(forHTTPHeaderField: "Referer") == "https://115.com/")
            precondition(request.value(forHTTPHeaderField: "User-Agent") == SHT115HTTP.safariUA)
            if url.path == "/files/add" {
                calls.append("create")
                let fields = body(request)
                precondition(request.httpMethod == "POST" && fields["pid"] == "10" && fields["cname"]!.contains("tid-3803873"))
                return "{\"state\":true,\"cid\":20}"
            }
            if ["/files", "/natsort/files.php", "/android/2.0/ufile/files"].contains(url.path) {
                let cid = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "cid" }!.value!
                if cid == "20" {
                    verified += 1; calls.append("verify")
                    if brokenPath && verified == 2 { return "{\"state\":true,\"data\":[],\"path\":[{\"cid\":0},{\"cid\":99},{\"cid\":20}]}" }
                }
                return "{\"state\":true,\"count\":0,\"data\":[],\"path\":[{\"cid\":0},{\"cid\":10}" + (cid == "20" ? ",{\"cid\":20}" : "") + "]}"
            }
            if url.path == "/" {
                calls.append("sign")
                precondition(request.httpMethod == "GET")
                // Missing time is supported by both reference clients.
                return "{\"sign\":\"mock-sign&+\"}"
            }
            precondition(url.absoluteString == "https://115.com/web/lixian/?ct=lixian&ac=" + (batch ? "add_task_urls" : "add_task_url"))
            calls.append("submit")
            precondition(request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=UTF-8")
            precondition(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
            let fields = body(request)
            precondition(fields["uid"] == "123" && fields["wp_path_id"] == "20" && fields["sign"] == "mock-sign&+")
            precondition(Int64(fields["time"]!)! > 0)
            if batch {
                precondition(Set(fields.keys) == Set(["uid", "wp_path_id", "sign", "time", "url[0]", "url[1]"]))
                precondition(fields["url[0]"] == ed && fields["url[1]"] == "https://example.invalid/file?a=1&b=2")
            } else {
                precondition(Set(fields.keys) == Set(["uid", "wp_path_id", "sign", "time", "url"]))
                precondition(fields["url"] == ed, "ed2k must round-trip exactly, including percent escapes")
            }
            if transport { throw URLError(.timedOut) }
            return response
        }
        let resource = try await service.createOrReuseResource(tid: "3803873", title: "fixture", settings: settings)
        precondition(resource.directoryCID == "20" && resource.tasks.isEmpty)
        do {
            _ = try await service.submit(urls: batch ? [ed, "https://example.invalid/file?a=1&b=2"] : [ed], resourceID: resource.id, settings: settings)
            precondition(expected == .accepted && !brokenPath)
        } catch {
            let message = SHT115Settings.safeMessage(error)
            precondition(!message.contains("mock-sign") && !message.contains("fake") && !message.contains(ed))
            precondition(message.contains(brokenPath ? "verify-before-submit" : "submit"))
            precondition(expected != .accepted || brokenPath)
        }
        let saved = await service.resources()
        if brokenPath {
            precondition(saved[0].tasks.isEmpty && !calls.contains("submit") && !calls.contains("sign"))
        } else {
            precondition(saved[0].tasks.last?.state == expected)
            precondition(saved[0].tasks.last?.writeEvidence?.request == (batch ? "batch-offline-post" : "single-offline-post"))
            if expected == .accepted { precondition(saved[0].tasks.last?.writeEvidence?.httpStatus == 200 && saved[0].tasks.last?.writeEvidence?.response == .accepted) }
            precondition(calls == ["create", "verify", "verify", "sign", "submit"])
            if expected != .rejected {
                let count = calls.count
                do { _ = try await service.submit(urls: [ed], resourceID: resource.id, settings: settings); preconditionFailure("must not resubmit") } catch {}
                precondition(calls.count == count)
            }
        }
        if afterReadFailure {
            precondition(!batch && expected == .accepted)
            Mock115Protocol.handler = { request in
                precondition(request.httpMethod == "GET", "read recovery must not POST")
                if request.url!.path.contains("/files") {
                    return "{\"state\":true,\"count\":0,\"data\":[],\"path\":[{\"cid\":0},{\"cid\":10},{\"cid\":20}]}"
                }
                let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let hash = q.first { $0.name == "info_hash" }!.value!
                precondition(hash == SHT115Service.infoHash(ed) && hash == hash.lowercased())
                return "{\"state\":true,\"page_count\":1,\"tasks\":[{\"info_hash\":\"" + hash + "\",\"wp_path_id\":20,\"status\":2,\"percentDone\":100}]}"
            }
            let inspected = try await service.inspect(resourceID: resource.id, settings: settings, includeFiles: false)
            precondition(inspected.resource.tasks[0].state == .accepted && inspected.resource.tasks[0].progress.count == 1)
            precondition(inspected.resource.tasks[0].progress[0].status == 2 && inspected.resource.tasks[0].progress[0].percent == 100)
            Mock115Protocol.handler = { request in
                precondition(request.httpMethod == "GET")
                throw URLError(.secureConnectionFailed)
            }
            do { _ = try await service.inspect(resourceID: resource.id, settings: settings, includeFiles: true); preconditionFailure("file read must fail") } catch {}
            let restarted = try SHT115Service(storeURL: store, session: session)
            let records = await restarted.resources()
            let task = records[0].tasks[0]
            precondition(task.state == .accepted && task.writeEvidence?.response == .accepted && task.writeEvidence?.httpStatus == 200 && task.writeEvidence?.apiCode == "0")
            precondition(task.writeEvidence?.readError == "http-read" && task.writeEvidence?.readErrorCode == "-1200")
            do { _ = try await restarted.submit(urls: [ed], resourceID: resource.id, settings: settings); preconditionFailure("accepted replay") } catch {}
            let diagnostic = await restarted.safeDiagnostic(tid: "3803873", settings: settings)
            precondition(diagnostic.contains("response=accepted") && diagnostic.contains("readError=http-read") && !diagnostic.contains(ed) && !diagnostic.contains("mock-sign") && !diagnostic.contains("fake"))
        }
    }
    static func main() async throws {
        let live = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Regression115/Fixtures/live-single-submission-20261008.json"))) as! [String: Any]
        let response = live["response"] as! [String: Any]
        precondition(response["info_hash"] is String && response["url"] is String && response["tasks"] == nil && response["data"] == nil && response["result"] == nil)
        precondition(SHT115Service.submissionState(response, count: 1) == .accepted)
        let liveResponse = String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)!
        try await run(liveResponse, expected: .accepted, afterReadFailure: true)
        try await run("{\"state\":true}", expected: .accepted)
        try await run("{\"state\":false,\"errcode\":911,\"error_msg\":\"secret must not leak\"}", expected: .rejected)
        try await run("{}", expected: .unknown)
        try await run("not-json", expected: .unknown)
        try await run("{}", expected: .unknown, transport: true)
        let batchLive = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Regression115/Fixtures/live-batch-submission-20261008.json"))) as! [String: Any]
        var batchResponse = batchLive["response"] as! [String: Any]
        var batchRows = batchResponse["result"] as! [[String: Any]]
        precondition(batchRows.count == 2 && batchRows.allSatisfy { $0["url"] is String && $0["info_hash"] is String })
        precondition(SHT115Service.submissionState(batchResponse, count: 2) == .accepted)
        batchRows[0]["url"] = ed
        batchRows[1]["url"] = "https://example.invalid/file?a=1&b=2"
        batchResponse["result"] = batchRows
        precondition(SHT115Service.submissionState(batchResponse, count: 2, links: [ed, "https://example.invalid/wrong"]) == .unknown)
        var duplicate = batchResponse
        duplicate["result"] = [batchRows[0], batchRows[0]]
        precondition(SHT115Service.submissionState(duplicate, count: 2, links: [ed, "https://example.invalid/file?a=1&b=2"]) == .unknown)
        let batchText = String(data: try JSONSerialization.data(withJSONObject: batchResponse), encoding: .utf8)!
        try await run(batchText, expected: .accepted, batch: true)
        try await run("{\"state\":true}", expected: .unknown, batch: true)
        try await run("{\"errcode\":0}", expected: .unknown, batch: true)
        try await run("{\"state\":true,\"errcode\":0,\"result\":[{\"state\":true}]}", expected: .unknown, batch: true)
        try await run("{\"state\":true,\"errcode\":0,\"result\":[{\"state\":true},{\"errcode\":0}]}", expected: .unknown, batch: true)
        try await run("{\"result\":[{\"state\":false},{\"state\":false}]}", expected: .rejected, batch: true)
        try await run("{\"result\":[{\"state\":true},{\"state\":false}]}", expected: .unknown, batch: true)
        try await run("{\"state\":true}", expected: .accepted, brokenPath: true)
        print("PASS: create → verify → signature → submit; refusal/unknown/batch/safe preflight")
    }
}
