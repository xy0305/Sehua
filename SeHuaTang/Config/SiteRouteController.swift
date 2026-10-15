import Foundation
import WebKit

extension SiteRouteStore {
    func selecting(_ host: String) -> SiteRouteStore {
        var next = normalized()
        guard next.routes.contains(where: { $0.host == host && $0.enabled }) else { return next }
        next.selectedHost = host
        return next
    }
}

struct RouteSwitchOutcome: Equatable, Sendable {
    var migrated: Bool
    var notice: String
}

/// Owns route configuration and per-host login cookies. Route JSON never
/// contains account secrets; cookie adaptation happens only after a decision.
@MainActor
final class SiteRouteController {
    static let shared = SiteRouteController()
    private let defaults: UserDefaults
    private var store: SiteRouteStore
    private var ledger: RouteCookieLedger
    private var verifiedTargets = Set<String>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        store = SiteRouteStore.load(
            data: defaults.data(forKey: SiteRouteStore.storageKey),
            legacyHost: defaults.string(forKey: SiteRouteStore.legacyHostKey)
        )
        ledger = RouteCookieLedger.load(data: defaults.data(forKey: RouteCookieLedger.storageKey))
        persist()
    }

    var selectedHost: String { store.selectedHost }
    var routes: [SiteRouteRecord] { store.routes }
    var enabledHosts: [String] { store.enabledHosts }

    func add(_ raw: String) -> Result<Void, SiteRoutePolicy.Rejection> {
        switch store.adding(raw) {
        case .failure(let error):
            return .failure(error)
        case .success(let next):
            store = next
            persist()
            return .success(())
        }
    }

    func setEnabled(_ host: String, _ enabled: Bool) {
        store = store.settingEnabled(host, enabled)
        persist()
    }

    func remove(_ host: String) {
        store = store.removing(host)
        ledger.scopes[host] = nil
        verifiedTargets.remove(host)
        persist()
    }

    func select(_ host: String) {
        store = store.selecting(host)
        persist()
    }

    func rememberCookies(_ cookies: [ScopedCookie], for host: String) {
        guard case .success(let normalized) = SiteRoutePolicy.normalize(host) else { return }
        ledger.scopes[normalized] = cookies.filter { !$0.name.isEmpty }
        persist()
    }

    func cookies(for host: String) -> [ScopedCookie] {
        ledger.scopes[host.lowercased()] ?? []
    }

    func clearAllRouteCookies() {
        ledger = ledger.clearingAll()
        verifiedTargets.removeAll()
        persist()
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            store.removeData(ofTypes: types, for: records) {}
        }
    }

    func prepareMigration(from source: String, to target: String) async -> RouteSwitchOutcome {
        select(target)
        let hasCookies = !(ledger.scopes[source]?.isEmpty ?? true)
        if !hasCookies {
            return RouteSwitchOutcome(migrated: false, notice: "已切换到 \(target)。当前线路没有可迁移的登录 Cookie。")
        }
        if source == target || SiteRoutePolicy.sameSiteDirect(source, target) || verifiedTargets.contains(migrationKey(source, target)) {
            let kind = source == target ? "当前线路" : "同站点"
            return await applyMigration(from: source, to: target, kind: kind)
        }
        guard SiteRoutePolicy.requiresReadOnlyVerification(source, target) else {
            return RouteSwitchOutcome(migrated: false, notice: "未确认同站点，未发送原登录 Cookie。")
        }
        let probe = await Self.readOnlyProbe(host: target)
        let decision = RouteMigration.decision(source: source, target: target, hasCookies: true, probe: probe)
        switch decision {
        case .verified:
            verifiedTargets.insert(migrationKey(source, target))
            return await applyMigration(from: source, to: target, kind: "只读验证通过")
        case .direct, .noCookies:
            return await applyMigration(from: source, to: target, kind: "同站点")
        case .rejected(let reason):
            return RouteSwitchOutcome(migrated: false, notice: "已切换到 \(target)，但\(reason)。请在该线路重新登录。")
        }
    }

    private func migrationKey(_ source: String, _ target: String) -> String { "\(source)->\(target)" }

    private func applyMigration(from source: String, to target: String, kind: String) async -> RouteSwitchOutcome {
        guard let migrated = ledger.migrating(from: source, to: target) else {
            return RouteSwitchOutcome(migrated: false, notice: "未确认同站点，未发送原登录 Cookie。")
        }
        ledger = migrated
        persist()
        await installCookies(ledger.scopes[target] ?? [], host: target)
        return RouteSwitchOutcome(migrated: true, notice: "\(kind)：已把现有登录 Cookie 适配到 \(target)，无需重输账号。")
    }

    private func installCookies(_ cookies: [ScopedCookie], host: String) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in cookies {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: cookie.name,
                .value: cookie.value,
                .domain: host,
                .path: cookie.path.isEmpty ? "/" : cookie.path,
                .secure: "TRUE"
            ]
            if let expires = cookie.expires { properties[.expires] = expires }
            guard let http = HTTPCookie(properties: properties) else { continue }
            await withCheckedContinuation { continuation in
                store.setCookie(http) { continuation.resume() }
            }
        }
    }

    private func persist() {
        defaults.set(store.persistedJSON(), forKey: SiteRouteStore.storageKey)
        defaults.set(store.selectedHost, forKey: SiteRouteStore.legacyHostKey)
        defaults.set(ledger.persistedJSON(), forKey: RouteCookieLedger.storageKey)
    }

    /// Cookie-less GET. Limited HTTPS redirects, then site-marker classification.
    static func readOnlyProbe(host: String) async -> RouteMigration.Probe {
        guard case .success(let normalized) = SiteRoutePolicy.normalize(host),
              let url = URL(string: "https://\(normalized)/forum.php?mod=forumdisplay&fid=36&mobile=2") else {
            return RouteMigration.Probe(finalHost: host, challenged: false, ageGateUncertain: true, siteMarker: false, redirects: 0)
        }
        let session = URLSession(configuration: cookieFreeConfiguration())
        defer { session.invalidateAndCancel() }
        var current = url
        var steps: [RouteRedirectStep] = []
        do {
            for _ in 0..<RouteMigration.maxRedirects {
                var request = URLRequest(url: current, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
                request.httpShouldHandleCookies = false
                request.setValue("no-cookie", forHTTPHeaderField: "Cookie")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    return RouteMigration.Probe(finalHost: current.host ?? normalized, challenged: false, ageGateUncertain: true, siteMarker: false, redirects: steps.count)
                }
                if (300..<400).contains(http.statusCode) {
                    steps.append(RouteRedirectStep(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location")))
                    guard let location = http.value(forHTTPHeaderField: "Location"),
                          let next = URL(string: location, relativeTo: current),
                          next.scheme?.lowercased() == "https",
                          next.user == nil,
                          next.port == nil || next.port == 443,
                          let nextHost = next.host?.lowercased(),
                          SiteRoutePolicy.isSiteHost(nextHost) else {
                        return RouteMigration.probe(startHost: normalized, steps: steps, bodyHost: current.host ?? "", body: "")
                    }
                    current = next
                    continue
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                return RouteMigration.probe(
                    startHost: normalized,
                    steps: steps,
                    bodyHost: http.url?.host ?? current.host ?? normalized,
                    body: body
                )
            }
            return RouteMigration.Probe(finalHost: current.host ?? normalized, challenged: false, ageGateUncertain: true, siteMarker: false, redirects: steps.count)
        } catch {
            return RouteMigration.Probe(finalHost: normalized, challenged: false, ageGateUncertain: true, siteMarker: false, redirects: steps.count)
        }
    }

    private static func cookieFreeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}
