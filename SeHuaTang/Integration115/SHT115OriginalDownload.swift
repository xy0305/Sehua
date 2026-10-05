import Foundation

extension SHT115HTTP {
    /// Download metadata POST is read-only. No archive/offline mutation or URL persistence.
    func originalSource(video: SHT115Video, settings: SHT115Settings) async throws -> SHT115PlaybackSource {
        let payload = try JSONSerialization.data(withJSONObject: ["pickcode": video.pickCode, "user_id": settings.uid])
        let encrypted = try SHT115DownloadCipher.encrypt(payload)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        let download = URLSession(configuration: config, delegate: SHT115DownloadRedirectGuard(), delegateQueue: nil)
        defer { download.invalidateAndCancel() }
        for endpoint in ["https://webapi.115.com/files/download", "https://proapi.115.com/app/chrome/downurl"] {
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: endpoint)!)
            Self.headers(settings).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.form([("data", encrypted)]).utf8)
            try await SHT115RequestPacer.shared.wait()
            guard let (data, response) = try? await download.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Self.success(object) else { continue }
            var decoded = object["data"] as? [String: Any]
            if let cipher = object["data"] as? String, let plain = try? SHT115DownloadCipher.decrypt(cipher) {
                decoded = try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
            }
            guard let body = decoded else { continue }
            let entries = (body["url"] != nil || body["file_url"] != nil) ? [body] : body.values.compactMap { $0 as? [String: Any] }
            guard entries.count == 1, let entry = entries.first,
                  let url = SHT115PlaybackRouting.originalURL(["data": entry])
                    ?? (entry["url"] as? String).flatMap(SHT115PlaybackRouting.directURL) else { continue }
            let name = Self.string(entry["file_name"] ?? entry["fn"])
            let fid = Self.string(entry["file_id"] ?? entry["fid"])
            let size = Int64(Self.string(entry["file_size"] ?? entry["fs"])) ?? 0
            guard name.isEmpty || name == video.name, fid.isEmpty || fid == video.id,
                  size == 0 || video.size == 0 || size == video.size else { continue }
            let headers = SHT115PlaybackRouting.downloadHeaders(url: url, response: http, userAgent: Self.safariUA)
            var probe = URLRequest(url: url)
            probe.timeoutInterval = 8
            probe.httpShouldHandleCookies = false
            headers.forEach { probe.setValue($0.value, forHTTPHeaderField: $0.key) }
            probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            try await SHT115RequestPacer.shared.wait()
            guard let (bytes, reply) = try? await download.bytes(for: probe),
                  let range = reply as? HTTPURLResponse, range.statusCode == 206,
                  !((range.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("mpegurl")) else { continue }
            var iterator = bytes.makeAsyncIterator()
            guard (try? await iterator.next()) != nil else { continue }
            return SHT115PlaybackSource(label: "原文件（源文件直链）", url: url, bandwidth: 0, headers: headers)
        }
        throw SHT115Error.playbackUnavailable
    }
}
