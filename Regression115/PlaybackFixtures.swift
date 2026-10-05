import Foundation

@main struct PlaybackFixtures {
    static func main() throws {
        precondition(SHT115PlaybackRouting.originalURL(["data": ["url": ["url": "https://cdn.example/movie.mkv?sign=fixture"]]])?.path == "/movie.mkv")
        precondition(SHT115PlaybackRouting.originalURL(["video_url": "https://cdn.example/movie.mp4"]) == nil)
        precondition(SHT115PlaybackRouting.originalURL(["download_url": "https://cdn.example/master.m3u8"]) == nil)
        precondition(SHT115PlaybackRouting.originalURL(["state": false, "download_url": "https://cdn.example/movie.mp4"]) == nil)
        let response = HTTPURLResponse(url: URL(string: "https://webapi.115.com/files/download")!, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": String(repeating: "a", count: 32) + "=" + String(repeating: "b", count: 32) + "; Path=/"])!
        let headers = SHT115PlaybackRouting.downloadHeaders(url: URL(string: "https://cdn.115cdn.com/movie.mkv")!, response: response, userAgent: "same-agent")
        precondition(headers["User-Agent"] == "same-agent" && headers["Referer"] == "https://115.com/" && headers["Cookie"] != nil)
        precondition(SHT115PlaybackRouting.downloadHeaders(url: URL(string: "https://115cdn.com.evil.example/movie")!, response: response, userAgent: "same-agent")["Cookie"] == nil)
        precondition(SHT115PlaybackRouting.downloadHeaders(url: URL(string: "http://cdn.115cdn.com/movie")!, response: response, userAgent: "same-agent")["Cookie"] == nil)
        let service = try String(contentsOfFile: "SeHuaTang/Integration115/SHT115Service.swift", encoding: .utf8)
        let playback = String(service.components(separatedBy: "public func resolvePlayback")[1].components(separatedBy: "private static func attribute")[0])
        precondition(playback.contains("scan(resourceID:") && playback.contains("originalSource(video:") && !playback.contains("m3u8"))
        let player = try String(contentsOfFile: "SeHuaTang/Views/Pan115InlinePlayer.swift", encoding: .utf8)
        precondition(player.contains("loadGeneration == generation") && player.contains(".id(source.url)") && player.contains("coordinator.onFinish"))
        let source = try String(contentsOfFile: "SeHuaTang/Integration115/SHT115OriginalDownload.swift", encoding: .utf8)
        precondition(source.contains("SHT115RequestPacer.shared.wait()") && source.contains("range.statusCode == 206") && source.contains("entries.count == 1"))
        for forbidden in ["print(", "absoluteString", "UserDefaults", "write(to:", "localizedDescription"] { precondition(!source.contains(forbidden)) }
        let encrypted = try SHT115DownloadCipher.encrypt(Data("{\"pickcode\":\"fixture\"}".utf8))
        precondition(encrypted.count > 100)
        let app = try String(contentsOfFile: "SeHuaTang/SeHuaTangApp.swift", encoding: .utf8)
        precondition(app.contains("KSOptions.logger = SilentPlaybackLog()"))
        do { _ = try SHT115DownloadCipher.decrypt("not-a-cipher"); preconditionFailure() } catch {}
        print("PASS source-only routing, provenance, headers, RSA, errors, episode isolation and no URL persistence/logging")
    }
}
