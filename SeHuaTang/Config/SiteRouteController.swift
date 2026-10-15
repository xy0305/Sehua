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
    var ready: Bool = true
}

/// No cookie snapshots, domain rewriting, or plaintext credential persistence.
/// WebKit alone stores cookies and enforces their original Domain/path scope.
@MainActor
final class SiteRouteController {
    static let shared = SiteRouteController()
    private let defaults: UserDefaults
    private var store: SiteRouteStore

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        store = SiteRouteStore.load(data: defaults.data(forKey: SiteRouteStore.storageKey),
                                    legacyHost: defaults.string(forKey: SiteRouteStore.legacyHostKey))
        // Purge the insecure legacy export; never re-import or copy its secrets.
        defaults.removeObject(forKey: RouteCookieLedger.storageKey)
        persist()
    }

    var selectedHost: String { store.selectedHost }
    var routes: [SiteRouteRecord] { store.routes }
    var enabledHosts: [String] { store.enabledHosts }

    func add(_ raw: String) -> Result<Void, SiteRoutePolicy.Rejection> {
        switch store.adding(raw) {
        case .failure(let error): return .failure(error)
        case .success(let next): store = next; persist(); return .success(())
        }
    }
    func setEnabled(_ host: String, _ enabled: Bool) {
        store = store.settingEnabled(host, enabled); persist()
    }
    func remove(_ host: String) { store = store.removing(host); persist() }
    func select(_ host: String) { store = store.selecting(host); persist() }

    func clearAllRouteCookies() {
        defaults.removeObject(forKey: RouteCookieLedger.storageKey)
        let dataStore = WKWebsiteDataStore.default()
        // Explicit cookie deletion also covers hosts absent from the route list.
        dataStore.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies { dataStore.httpCookieStore.delete(cookie) }
        }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.removeData(ofTypes: types, modifiedSince: .distantPast) {}
    }

    func prepareMigration(from source: String, to target: String) async -> RouteSwitchOutcome {
        guard enabledHosts.contains(target) else {
            return RouteSwitchOutcome(migrated: false, notice: "线路未启用", ready: false)
        }
        // First contact is entirely anonymous. Do not let an automatic redirect
        // visit a different entry point with that entry point's existing login.
        let probe = await Self.readOnlyProbe(host: target)
        guard !probe.ageGateUncertain,
              probe.finalHost == target || SiteRoutePolicy.sameSiteDirect(probe.finalHost, target) else {
            return RouteSwitchOutcome(migrated: false,
                notice: "匿名 HTTPS 检查未确认最终目标，未使用该线路已有 Cookie。请稍后重试或独立打开已知入口。", ready: false)
        }
        select(target)
        let notice = SiteRoutePolicy.sameSiteDirect(source, target)
            ? "已切换到 \(target)。仅按原 Cookie Domain 自然共享；host-only Cookie 不复制，必要时独立登录。"
            : "已切换到 \(target)。内置入口不代表共同归属；跨域不复制原 Cookie，请独立登录（可使用该域自身已有登录）。"
        return RouteSwitchOutcome(migrated: false, notice: notice)
    }

    private func persist() {
        defaults.set(store.persistedJSON(), forKey: SiteRouteStore.storageKey)
        defaults.set(store.selectedHost, forKey: SiteRouteStore.legacyHostKey)
        defaults.removeObject(forKey: RouteCookieLedger.storageKey)
    }

    static func readOnlyProbe(host: String, configuration supplied: URLSessionConfiguration? = nil) async -> RouteMigration.Probe {
        guard case .success(let normalized) = SiteRoutePolicy.normalize(host),
              let url = URL(string: "https://\(normalized)/") else {
            return .init(finalHost: host, challenged: false, ageGateUncertain: true, siteMarker: false, redirects: 0)
        }
        let configuration = supplied ?? URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: AnonymousRouteRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var current = url
        var count = 0
        do {
            while count <= RouteMigration.maxRedirects {
                var request = URLRequest(url: current, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
                request.httpShouldHandleCookies = false
                // No Cookie or Authorization header, including across redirects.
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { break }
                if (300..<400).contains(http.statusCode) {
                    guard count < RouteMigration.maxRedirects,
                          let location = http.value(forHTTPHeaderField: "Location"),
                          let next = URL(string: location, relativeTo: current)?.absoluteURL,
                          SiteRoutePolicy.permitsNavigation(next, selectedHost: normalized) else { break }
                    current = next; count += 1; continue
                }
                guard (200..<500).contains(http.statusCode), http.url?.scheme == "https",
                      let final = http.url?.host?.lowercased(),
                      final == normalized || SiteRoutePolicy.sameSiteDirect(final, normalized) else { break }
                // Text, challenge, and age-gate markers never grant trust.
                return .init(finalHost: final, challenged: http.statusCode == 403,
                             ageGateUncertain: false, siteMarker: false, redirects: count)
            }
        } catch { }
        return .init(finalHost: current.host ?? normalized, challenged: false,
                     ageGateUncertain: true, siteMarker: false, redirects: count)
    }
}

/// URLSession's default redirect-following would bypass the manual HTTPS check.
private final class AnonymousRouteRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
