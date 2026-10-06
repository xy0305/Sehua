import Foundation

final class Mock115Protocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let text = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
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
    static func run(_ response: String, expected: SHT115SubmissionState, batch: Bool = false, brokenPath: Bool = false, transport: Bool = false) async throws {
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
            precondition(calls == ["create", "verify", "verify", "sign", "submit"])
            if expected != .rejected {
                let count = calls.count
                do { _ = try await service.submit(urls: [ed], resourceID: resource.id, settings: settings); preconditionFailure("must not resubmit") } catch {}
                precondition(calls.count == count)
            }
        }
    }
    static func main() async throws {
        try await run("{\"state\":true}", expected: .accepted)
        try await run("{\"state\":false,\"errcode\":911,\"error_msg\":\"secret must not leak\"}", expected: .rejected)
        try await run("{}", expected: .unknown)
        try await run("not-json", expected: .unknown)
        try await run("{}", expected: .unknown, transport: true)
        try await run("{\"state\":true}", expected: .accepted, batch: true)
        try await run("{\"result\":[{\"state\":true},{\"state\":false}]}", expected: .unknown, batch: true)
        try await run("{\"state\":true}", expected: .accepted, brokenPath: true)
        print("PASS: create → verify → signature → submit; refusal/unknown/batch/safe preflight")
    }
}
