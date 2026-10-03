import UIKit

enum SiteLinks {
    static func staysInApp(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "magnet" || scheme == "ed2k" { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        let host = (url.host ?? "").lowercased()
        if host.isEmpty { return true }
        return SiteConfig.mirrors.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func open(_ url: URL) {
        UIApplication.shared.open(url)
    }

    static func links(in html: String, base: URL) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        let hrefs = HTML.elements(in: html, tag: "a").compactMap { HTML.attribute("href", in: $0) }
        for href in hrefs {
            guard let url = HTML.absURL(href, base: base) else { continue }

            let scheme = url.scheme?.lowercased() ?? ""
            guard scheme == "http" || scheme == "https" || scheme == "magnet" || scheme == "ed2k" else { continue }
            if seen.insert(url.absoluteString).inserted {
                out.append(url)
            }

        }
        return out
    }
}
