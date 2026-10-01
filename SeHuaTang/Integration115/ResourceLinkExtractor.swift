import Foundation
import CoreFoundation
#if canImport(WebKit)
import WebKit
#endif

/// Extraction only: never submits a 115 task or writes an attachment to disk.
/// Internal because ThreadDetail / ThreadAttachment are internal app models.
enum ResourceLinkExtractor {
    enum Mode { case automatic, manual }
    enum Source: Equatable {
        case body(postID: String)
        case detailLink
        case attachment(name: String, url: URL)
    }
    struct Link: Equatable {
        let value: String
        var sources: [Source]
    }
    struct Warning: Equatable {
        let attachmentName: String
        let message: String
    }
    struct Result {
        let resources: [Link]
        let warnings: [Warning]
        let usedArchiveGroup: Bool
        var links: [String] { resources.map(\.value) }
    }
    enum ExtractionError: LocalizedError {
        case noValidLinks([Warning])
        case attachment(String)
        var errorDescription: String? {
            switch self {
            case .noValidLinks(let warnings):
                return "未提取到有效磁力或 ed2k 链接。" + warnings.map { "\($0.attachmentName)：\($0.message)" }.joined(separator: "；")
            case .attachment(let message): return message
            }
        }
    }
    typealias TextLoader = (URL, URL) async throws -> String
    static let maximumTextBytes = 4 * 1024 * 1024

    static func extract(detail: ThreadDetail, base: URL) async throws -> [String] {
        try await extractResult(detail: detail, base: base).links
    }

    /// Inject a loader for deterministic, offline tests. base is the page Referer.
    /// Manual mode bypasses both name exclusions and archive preference.
    static func extractResult(detail: ThreadDetail, base: URL, mode: Mode = .automatic,
                              loader: TextLoader = readTextAttachment) async throws -> Result {
        struct Attachment {
            let url: URL
            var name: String
            var excluded: Bool
            var archive: Bool
        }
        var attachments: [Attachment] = []
        func collect(name: String, url: URL) {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
            let names = ([name, url.lastPathComponent] + query.filter { ["filename", "name"].contains($0.name.lowercased()) }.compactMap(\.value))
                .map { entities($0.removingPercentEncoding ?? $0) }.joined(separator: " ")
            guard matches(#"\.txt(?:$|[\s?&#）)])"#, names) || url.path.lowercased().hasSuffix(".txt") else { return }
            let excluded = matches(#"目录[树樹]|目錄[树樹]|封面|说明|說明|readme|(?:directory|file)[ _-]*tree"#, names)
            let archive = matches(#"压缩包|壓縮包|打包|合集[ _-]*[压壓][缩縮]|[压壓][缩縮]合集|(?:^|[\s_.-])(?:archives?|packed|zip|rar|7z)(?:[\s_.-]|$)"#, names)
            if let i = attachments.firstIndex(where: { $0.url == url }) {
                attachments[i].name += " " + name
                attachments[i].excluded = attachments[i].excluded || excluded
                attachments[i].archive = attachments[i].archive || archive
            } else {
                attachments.append(Attachment(url: url, name: name.isEmpty ? url.lastPathComponent : name, excluded: excluded, archive: archive))
            }
        }
        // Include anchor title/download metadata missing from ThreadAttachment.
        for post in detail.posts {
            for anchor in HTML.elements(in: post.htmlBody, tag: "a") {
                guard let href = HTML.attribute("href", in: anchor), let url = HTML.absURL(href, base: base) else { continue }
                let name = [HTML.stripTags(anchor), HTML.attribute("title", in: anchor) ?? "", HTML.attribute("download", in: anchor) ?? ""].joined(separator: " ")
                collect(name: name, url: url)
            }
        }
        for item in detail.attachments { collect(name: item.name, url: item.url) }
        let candidates = attachments.filter { mode == .manual || !$0.excluded }
        var warnings: [Warning] = []
        func read(_ items: [Attachment]) async throws -> [Link] {
            var output: [Link] = []
            for item in items {
                try Task.checkCancellation()
                do {
                    let text = try await loader(item.url, base)
                    try Task.checkCancellation()
                    guard !isHTMLResponse(text) else { throw ExtractionError.attachment("返回登录、验证或权限 HTML，而非 TXT。") }
                    let found = links(in: text)
                    if found.isEmpty { warnings.append(Warning(attachmentName: item.name, message: "TXT 中没有有效资源链接，已允许回退。")) }
                    output += found.map { Link(value: $0, sources: [.attachment(name: item.name, url: item.url)]) }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // Do not leak cookie headers, signed URLs or arbitrary loader error text.
                    try Task.checkCancellation()
                    let message: String
                    if let error = error as? ExtractionError { message = error.localizedDescription }
                    else { message = "附件读取失败，请检查登录、权限或网络；已允许回退。" }
                    warnings.append(Warning(attachmentName: item.name, message: message))
                }
            }
            return output
        }
        let archiveItems = candidates.filter { $0.archive && !$0.excluded }
        let archiveLinks = deduplicate(try await read(archiveItems))
        if mode == .automatic, !archiveLinks.isEmpty {
            return Result(resources: archiveLinks, warnings: warnings, usedArchiveGroup: true)
        }
        var all: [Link] = []
        for post in detail.posts {
            // Raw HTML preserves full href parameters; plain text also finds blockcode.
            all += links(in: post.htmlBody + "\n" + post.plainText).map { Link(value: $0, sources: [.body(postID: post.id)]) }
        }
        for item in detail.magnets + detail.attachments {
            all += links(in: item.url.absoluteString).map { Link(value: $0, sources: [.detailLink]) }
        }
        all += archiveLinks
        all += try await read(candidates.filter { candidate in !archiveItems.contains(where: { $0.url == candidate.url }) })
        all = deduplicate(all)
        if mode == .automatic {
            let archives = all.filter { matches(#"\.(?:zip|rar|7z|tar|tgz|tbz2|txz|gz|bz2|xz|z\d{2}|r\d{2})(?:\.\d{1,4})?$"#, fileName($0.value)) }
            if !archives.isEmpty { all = archives }
        }
        guard !all.isEmpty else { throw ExtractionError.noValidLinks(warnings) }
        return Result(resources: all, warnings: warnings, usedArchiveGroup: false)
    }

    /// Validation and stable exact-string deduplication, without automatic preference.
    /// Do NOT percent-decode a complete magnet: %26 in dn/tr is not a separator.
    static func links(in text: String) -> [String] {
        var text = entities(text)
        for scalar in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"] { text = text.replacingOccurrences(of: scalar, with: "") }
        // Match Foundation-encoded ed2k pipes, but never decode magnet parameters.
        let pattern = #"magnet:\?[^\s<>\"'，。；、]+|ed2k://(?:\||%7c)file(?:\||%7c)[^\r\n<>\"']*?(?:\||%7c)/(?=$|\s|[<>\"'，。；、\])】）)])"#
        var seen = Set<String>()
        return HTML.allMatches(pattern, in: text, group: 0).compactMap { raw in
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.replacingOccurrences(of: #"[)\]】》>，。；;、]+$"#, with: "", options: .regularExpression)
            if value.lowercased().hasPrefix("ed2k://") {
                value = value.replacingOccurrences(of: "%7c", with: "|", options: .caseInsensitive)
                value = value.replacingOccurrences(of: #"\s+"#, with: "%20", options: .regularExpression)
                guard matches(#"^ed2k://\|file\|[^|]+\|\d+\|[a-f0-9]{32}(?:\|[^|]+)*\|/$"#, value) else { return nil }
            } else {
                guard matches(#"[?&]xt=urn:(?:btih:(?:[a-f0-9]{40}|[a-z2-7]{32})|btmh:1220[a-f0-9]{64})(?=&|$)"#, value) else { return nil }
            }
            return seen.insert(value).inserted ? value : nil
        }
    }

    private static func entities(_ value: String) -> String {
        var text = HTML.unescape(value)
        for (name, replacement) in [("&colon;", ":"), ("&sol;", "/"), ("&vert;", "|"), ("&VerticalLine;", "|"), ("&quest;", "?"), ("&equals;", "="), ("&Tab;", "\t"), ("&NewLine;", "\n")] {
            text = text.replacingOccurrences(of: name, with: replacement)
        }
        return text
    }
    private static func matches(_ pattern: String, _ text: String) -> Bool {
        HTML.firstMatch(pattern, in: text, group: 0) != nil
    }
    private static func deduplicate(_ values: [Link]) -> [Link] {
        var output: [Link] = []
        var indices: [String: Int] = [:]
        for item in values {
            if let index = indices[item.value] {
                for source in item.sources where !output[index].sources.contains(source) { output[index].sources.append(source) }
            } else { indices[item.value] = output.count; output.append(item) }
        }
        return output
    }
    private static func fileName(_ link: String) -> String {
        if link.lowercased().hasPrefix("ed2k://") {
            let components = link.components(separatedBy: "|")
            return components.count > 2 ? (components[2].removingPercentEncoding ?? components[2]) : ""
        }
        // URLComponents decodes individual query values exactly once, including dn.
        return URLComponents(string: link)?.queryItems?.first(where: { $0.name.lowercased() == "dn" })?.value ?? ""
    }
    private static func isHTMLResponse(_ text: String) -> Bool {
        matches(#"^\s*(?:<!doctype\s+html|<html\b|<head\b|<body\b)|人机验证|人機驗證"#, text.replacingOccurrences(of: "\u{FEFF}", with: ""))
    }

    /// Same in-memory transport as TextAttachmentView; no UI dependency.
    static func readTextAttachment(_ url: URL, referer: URL) async throws -> String {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw ExtractionError.attachment("不支持的附件协议。") }
        #if canImport(WebKit)
        let cookies = await defaultCookies()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        for cookie in cookies { configuration.httpCookieStorage?.setCookie(cookie) }
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await client.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw ExtractionError.attachment("附件 HTTP 请求失败，请检查登录及下载权限。") }
        guard response.expectedContentLength <= Int64(maximumTextBytes) else { throw ExtractionError.attachment("TXT 超过 4 MB 内存读取上限。") }
        guard response.mimeType?.lowercased().contains("html") != true else { throw ExtractionError.attachment("返回登录、验证或权限 HTML，而非 TXT。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumTextBytes else { throw ExtractionError.attachment("TXT 超过 4 MB 内存读取上限。") }
            data.append(byte)
        }
        try Task.checkCancellation()
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { text = String(data: data, encoding: .utf16) }
        else { text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb18030) }
        guard let text else { throw ExtractionError.attachment("无法识别 TXT 编码。") }
        guard !isHTMLResponse(text) else { throw ExtractionError.attachment("返回登录、验证或权限 HTML，而非 TXT。") }
        return text
        #else
        throw ExtractionError.attachment("当前平台没有 WebKit，请注入离线 TXT loader。")
        #endif
    }
    #if canImport(WebKit)
    @MainActor private static func defaultCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }
    #endif
}
