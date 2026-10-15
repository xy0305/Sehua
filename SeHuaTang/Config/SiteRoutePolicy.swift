import Foundation

/// HTTPS site-route policy. Pure and side-effect free so production and
/// regressions share one parser. Credentials are never part of a route.
enum SiteRoutePolicy {
    static var builtinHosts: [String] { SiteConfig.mirrors }
    static let orgFamily: Set<String> = ["www.sehuatang.org", "sehuatang.org"]
    /// Built-in entry points only; this list is NOT an ownership or account trust claim.
    static let confirmedFamily: Set<String> = [
        "www.sehuatang.org", "sehuatang.org", "www.sehuatang.net", "98tang.com"
    ]

    struct Rejection: Error, Equatable, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// Lowercase site host, or a rejection. No userinfo, IP, port, or non-site host.
    static func normalize(_ raw: String) -> Result<String, Rejection> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.init(reason: "线路不能为空")) }
        if trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) {
            return .failure(.init(reason: "线路不能包含空白"))
        }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate) else {
            return .failure(.init(reason: "线路地址无法解析"))
        }
        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "https" else {
            return .failure(.init(reason: "只允许 HTTPS 站点"))
        }
        if components.user != nil || components.password != nil {
            return .failure(.init(reason: "线路不能包含账号或密码"))
        }
        if let port = components.port, port != 443 {
            return .failure(.init(reason: "不接受非标准端口"))
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            return .failure(.init(reason: "缺少站点主机名"))
        }
        if host.contains("@") || host.contains(":") || host.contains("\\") {
            return .failure(.init(reason: "主机名不合法"))
        }
        if isIPAddress(host) {
            return .failure(.init(reason: "不接受 IP 地址线路"))
        }
        let path = components.path
        let hasExtra = !(path.isEmpty || path == "/")
            || components.query != nil
            || components.fragment != nil
        if hasExtra {
            return .failure(.init(reason: "线路只能是站点主机，不能带路径或参数"))
        }
        guard isPublicHostname(host) else {
            return .failure(.init(reason: "只接受合法公网域名，不接受本地、私有或保留域名"))
        }
        return .success(host)
    }

    static func isSiteHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return confirmedFamily.contains(host)
    }

    static func isPublicHostname(_ host: String) -> Bool {
        guard host.count <= 253, host.utf8.allSatisfy({ $0 < 128 }), !host.contains("%") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter && $0.isASCII }) else { return false }
        let reserved: Set<String> = ["localhost", "local", "internal", "lan", "home", "test", "invalid", "example", "onion", "arpa"]
        guard !reserved.contains(String(tld)), host != "example.com", host != "example.net", host != "example.org" else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// Navigation remains on the explicitly selected host. Only the known org
    /// parent/subdomain pair may share cookies under native Cookie Domain rules.
    static func permitsNavigation(_ url: URL, selectedHost: String) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == selectedHost || sameSiteDirect(host, selectedHost)
    }

    static func isIPAddress(_ host: String) -> Bool {
        let host = host.lowercased()
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ part in
            guard let n = Int(part), (0...255).contains(n), String(n) == part || part == "0" else { return false }
            return true
        }) else { return false }
        return true
    }

    /// org and bare sehuatang.org are the same site and may migrate immediately.
    static func sameSiteDirect(_ source: String, _ target: String) -> Bool {
        orgFamily.contains(source.lowercased()) && orgFamily.contains(target.lowercased())
    }

    static func requiresReadOnlyVerification(_ source: String, _ target: String) -> Bool {
        let source = source.lowercased()
        let target = target.lowercased()
        guard source != target, isSiteHost(source), isSiteHost(target) else { return false }
        return !sameSiteDirect(source, target)
    }
}

struct SiteRouteRecord: Codable, Equatable, Identifiable, Sendable {
    var host: String
    var enabled: Bool
    var builtin: Bool
    var id: String { host }
}

/// Route list persisted without credentials. Login cookies live in a separate
/// per-host store and are never written into this configuration.
struct SiteRouteStore: Equatable, Sendable {
    static let storageKey = "sht.routes.v1"
    static let legacyHostKey = "sht.host"
    var routes: [SiteRouteRecord]
    var selectedHost: String

    static func fresh() -> SiteRouteStore {
        SiteRouteStore(
            routes: SiteRoutePolicy.builtinHosts.map {
                SiteRouteRecord(host: $0, enabled: true, builtin: true)
            },
            selectedHost: SiteConfig.defaultHost
        )
    }

    func normalized() -> SiteRouteStore {
        var seen = Set<String>()
        var kept: [SiteRouteRecord] = []
        for host in SiteRoutePolicy.builtinHosts where seen.insert(host).inserted {
            let existing = routes.first { $0.host == host }
            kept.append(SiteRouteRecord(host: host, enabled: existing?.enabled ?? true, builtin: true))
        }
        for route in routes {
            guard case .success(let host) = SiteRoutePolicy.normalize(route.host), seen.insert(host).inserted else { continue }
            kept.append(SiteRouteRecord(host: host, enabled: route.enabled, builtin: false))
        }
        if !kept.contains(where: { $0.enabled }), let index = kept.firstIndex(where: { $0.host == SiteConfig.defaultHost }) {
            kept[index].enabled = true
        }
        let selected = kept.first { $0.host == selectedHost && $0.enabled }?.host
            ?? kept.first { $0.enabled }?.host
            ?? SiteConfig.defaultHost
        return SiteRouteStore(routes: kept, selectedHost: selected)
    }

    func adding(_ raw: String) -> Result<SiteRouteStore, SiteRoutePolicy.Rejection> {
        switch SiteRoutePolicy.normalize(raw) {
        case .failure(let error):
            return .failure(error)
        case .success(let host):
            var next = normalized()
            if let index = next.routes.firstIndex(where: { $0.host == host }) {
                next.routes[index].enabled = true
            } else {
                next.routes.append(SiteRouteRecord(host: host, enabled: true, builtin: false))
            }
            return .success(next)
        }
    }

    func settingEnabled(_ host: String, _ enabled: Bool) -> SiteRouteStore {
        var next = normalized()
        guard let index = next.routes.firstIndex(where: { $0.host == host }) else { return next }
        next.routes[index].enabled = enabled
        if !enabled, next.selectedHost == host {
            next.selectedHost = next.routes.first { $0.enabled && $0.host != host }?.host ?? SiteConfig.defaultHost
        }
        return next.normalized()
    }

    func removing(_ host: String) -> SiteRouteStore {
        var next = normalized()
        guard let index = next.routes.firstIndex(where: { $0.host == host }), !next.routes[index].builtin else { return next }
        next.routes.remove(at: index)
        if next.selectedHost == host {
            next.selectedHost = next.routes.first { $0.enabled }?.host ?? SiteConfig.defaultHost
        }
        return next.normalized()
    }

    var enabledHosts: [String] { normalized().routes.filter(\.enabled).map(\.host) }

    func persistedJSON() -> Data {
        let clean = normalized()
        let payload = Persisted(routes: clean.routes, selectedHost: clean.selectedHost)
        return (try? JSONEncoder().encode(payload)) ?? Data()
    }

    static func load(data: Data?, legacyHost: String?) -> SiteRouteStore {
        if let data, let persisted = try? JSONDecoder().decode(Persisted.self, from: data) {
            return SiteRouteStore(routes: persisted.routes, selectedHost: persisted.selectedHost).normalized()
        }
        var store = fresh()
        if let legacyHost, case .success(let host) = SiteRoutePolicy.normalize(legacyHost) {
            store.selectedHost = host
            if let index = store.routes.firstIndex(where: { $0.host == host }) {
                store.routes[index].enabled = true
            }
        }
        return store.normalized()
    }

    private struct Persisted: Codable {
        var routes: [SiteRouteRecord]
        var selectedHost: String
    }
}

private extension Result where Failure == SiteRoutePolicy.Rejection {
    var success: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}

struct ScopedCookie: Codable, Equatable, Sendable {
    var name: String
    var value: String
    var path: String
    var secure: Bool
    var expires: Date?
}

/// Login cookies keyed by the host they were adapted for. Switching never
/// copies them until same-site migration is confirmed.
struct RouteCookieLedger: Equatable, Sendable {
    static let storageKey = "sht.routeCookies.v1"
    var scopes: [String: [ScopedCookie]]

    static func load(data: Data?) -> RouteCookieLedger {
        guard let data, let decoded = try? JSONDecoder().decode([String: [ScopedCookie]].self, from: data) else {
            return RouteCookieLedger(scopes: [:])
        }
        var clean: [String: [ScopedCookie]] = [:]
        for (host, cookies) in decoded {
            guard case .success(let normalized) = SiteRoutePolicy.normalize(host) else { continue }
            clean[normalized] = cookies.filter { !$0.name.isEmpty && !$0.value.isEmpty }
        }
        return RouteCookieLedger(scopes: clean)
    }

    func persistedJSON() -> Data {
        (try? JSONEncoder().encode(scopes)) ?? Data()
    }

    func clearingAll() -> RouteCookieLedger { RouteCookieLedger(scopes: [:]) }

    /// Adapt names/values onto the target host. Domain is the target only.
    func migrating(from source: String, to target: String) -> RouteCookieLedger? {
        guard source == target else { return nil }
        guard let cookies = scopes[source], !cookies.isEmpty else { return self }
        var next = self
        next.scopes[target] = cookies.map {
            ScopedCookie(name: $0.name, value: $0.value, path: $0.path.isEmpty ? "/" : $0.path, secure: true, expires: $0.expires)
        }
        return next
    }
}

enum RouteMigrationDecision: Equatable, Sendable {
    case direct
    case verified
    case rejected(String)
    case noCookies
}

struct RouteRedirectStep: Equatable, Sendable {
    var status: Int
    var location: String?
}

enum RouteMigration {
    static let maxRedirects = 5

    struct Probe: Equatable, Sendable {
        var finalHost: String
        var challenged: Bool
        var ageGateUncertain: Bool
        var siteMarker: Bool
        var redirects: Int
    }

    static func decision(source: String, target: String, hasCookies: Bool, probe: Probe?) -> RouteMigrationDecision {
        guard hasCookies else { return .noCookies }
        if source == target || SiteRoutePolicy.sameSiteDirect(source, target) { return .direct }
        // HTTPS and forum-looking text cannot establish common ownership.
        // No automatic cross-domain credential transfer, even after a probe.
        return .rejected("跨域线路需独立登录，未复制原登录 Cookie")
    }

    /// Follow a bounded HTTPS redirect chain without sending cookies.
    static func probe(startHost: String, steps: [RouteRedirectStep], bodyHost: String, body: String) -> Probe {
        var host = startHost.lowercased()
        var count = 0
        var challenged = false
        var uncertain = false
        for step in steps {
            guard (300..<400).contains(step.status), let location = step.location, count < maxRedirects else { break }
            guard let url = URL(string: location, relativeTo: URL(string: "https://\(host)/")),
                  url.scheme?.lowercased() == "https",
                  let next = url.host?.lowercased(),
                  url.port == nil || url.port == 443,
                  url.user == nil else {
                uncertain = true
                break
            }
            host = next
            count += 1
            if !SiteRoutePolicy.isSiteHost(next) {
                uncertain = true
                break
            }
        }
        let marker = siteMarker(body)
        if looksChallenged(body) { challenged = true }
        if looksAgeGate(body) && !marker { uncertain = true }
        let final = bodyHost.isEmpty ? host : bodyHost.lowercased()
        return Probe(finalHost: final, challenged: challenged, ageGateUncertain: uncertain, siteMarker: marker, redirects: count)
    }

    static func siteMarker(_ html: String) -> Bool {
        let text = html.lowercased()
        if looksChallenged(text) { return false }
        return text.contains("discuz") || text.contains("forum.php") || text.contains("sehuatang")
            || text.contains("色花堂") || text.contains("98堂") || text.contains("n5_bbsbk")
    }

    static func looksChallenged(_ html: String) -> Bool {
        let text = html.lowercased()
        return text.contains("just a moment") || text.contains("cf-challenge") || text.contains("checking your browser")
            || text.contains("cf-browser-verification") || text.contains("attention required")
    }

    static func looksAgeGate(_ html: String) -> Bool {
        html.contains("满18岁") || html.lowercased().contains("enter-btn")
    }
}
